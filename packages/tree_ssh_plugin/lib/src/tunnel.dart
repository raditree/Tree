import 'dart:async';
import 'dart:math';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'agent_binary.dart';
import 'agent_client.dart';
import 'backoff.dart';
import 'bootstrap.dart';
import 'keepalive.dart';
import 'login_shell.dart';
import 'ssh_dialer.dart';
import 'tunnel_config.dart';

/// 可注入的定时器（生产用 `dart:async` 的 `Timer`，测试用假时钟）。
///
/// 为什么要这层：退避的**累计上限是 30 分钟**——单测不可能真等它。
abstract class DelayTimer {
  /// 取消（幂等）。
  void cancel();
}

/// 定时器工厂：`(间隔, 到点回调) → 定时器`。
typedef TimerFactory = DelayTimer Function(
  Duration duration,
  void Function() callback,
);

/// 生产实现：包一层 `dart:async` 的 `Timer`。
class RealDelayTimer implements DelayTimer {
  RealDelayTimer(Duration duration, void Function() callback)
      : _timer = Timer(duration, callback);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

/// 默认定时器工厂（生产用；测试注入假实现）。
DelayTimer defaultTimerFactory(Duration duration, void Function() callback) =>
    RealDelayTimer(duration, callback);

/// 一条到某台主机的隧道：**SSH 连接 + agent 常驻通道 + 状态机**。
///
/// 状态（协议 §2）：`connecting → booting → ready ⇄ reconnecting → down`。
/// - 首次建（`connecting`）失败 ⇒ 退避重试，直到 [Backoff.maxTotal] 用尽 ⇒ `down`；
/// - `ready` 之后通道断 ⇒ `reconnecting`（重连 = 重跑 bootstrap ⇒ 天然完成 agent 版本对账）；
/// - **不可调和**的失败（架构不支持 / 握手被拒 / 本机配置不全）⇒ 直接 `down`，
///   不白白退避 30 分钟（`arch_unsupported` 再试一万次也还是不支持）。
///
/// **在途请求**：通道一断，[AgentClient] 就把它们全部以可读错误收口 ⇒ 本层的
/// `request` 如实回失败（**绝不自动重放**：远端命令可能有副作用）。
class Tunnel {
  Tunnel({
    required this.connId,
    required this.config,
    required this.agent,
    required this.dialer,
    required this.loadBinary,
    Backoff? backoff,
    this.timerFactory = defaultTimerFactory,
    this.now = DateTime.now,
    this.onEvent,
    this.log,
    this.chunkBytes = kPushChunkBytes,
    Random? random,
  })  : backoff = backoff ?? Backoff(),
        _random = random ?? Random.secure() {
    _startedAt = now();
  }

  /// 隧道 id（`conn-<递增序号>`，由 [TunnelManager] 分配）。
  final String connId;
  final TunnelConfig config;
  final AgentRequest agent;

  /// 退避节奏（`tunnel.reconnect` 会 `reset()`）。
  final Backoff backoff;

  /// 推送分块大小（测试可改小，用真机无关）。
  final int chunkBytes;

  /// 状态跃迁 / PTY 事件的出口（转成 L1 的 `tunnel/event` 通知）。
  void Function(Map<String, dynamic> event)? onEvent;

  /// SSH 连接工厂（可注入：单测用假 dialer）。
  final SshDialer dialer;

  /// 随包 agent 二进制的装载器（可注入：单测用假字节）。
  final AgentBinaryLoader loadBinary;

  /// 定时器工厂（可注入：单测用假时钟，退避不用真等 30 分钟）。
  final TimerFactory timerFactory;

  /// 当前时间（可注入，便于断言 `elapsed_ms`）。
  final DateTime Function() now;

  final void Function(String message)? log;
  final Random _random;

  SshConnection? _connection;
  AgentClient? _client;
  LoginShell? _loginShell;
  AgentHello? _hello;
  String _root = '';
  String _installPath = '';
  DelayTimer? _retryTimer;
  Future<bool>? _attemptInFlight;
  bool _everReady = false;
  bool _closed = false;
  late final DateTime _startedAt;

  /// agent 保活（自调度：一拍一判，卡死时能连着数拍）。
  DelayTimer? _pingTimer;

  /// 连续无响应的拍数（任何一次成功响应都清零）。
  int _pingMisses = 0;

  /// 上一世 agent 的 pid / 启动时用的一次性 token。
  ///
  /// 通道断时**不清**（它正是"重建前先收掉它"的凭据）：token 只在命令行里出现过，
  /// 32 位 hex 唯一 ⇒ 在目标机 `/proc/<pid>/cmdline` 里核对得上才杀，零误杀。
  int? _lastAgentPid;
  String? _lastAgentToken;

  String _state = TunnelStates.connecting;
  int _attempts = 0;
  String? _lastError;
  String? _lastErrorKind;

  /// 本次尝试的握手 token（只用于**日志脱敏**：它绝不能出现在任何日志里）。
  String? _handshakeToken;

  /// 当前状态（[TunnelStates] 之一）。
  String get state => _state;

  /// 连接尝试次数（含成功与失败；`connecting`/`booting` 期间在涨）。
  int get attempts => _attempts;

  String? get lastError => _lastError;
  String? get lastErrorKind => _lastErrorKind;

  /// agent 握手信息（未就绪时为 null）。
  AgentHello? get hello => _hello;

  /// 权威的远端工作空间根（就绪后来自 `agent.hello`）。
  String get root => _root;

  /// 目标机上这一世 agent 的安装路径（未就绪时为空串）。
  ///
  /// 给**左栏面板**看的（`ui_panel.dart`）：核心的判活面 [`stateJson`] 刻意不含它，
  /// 面板要显示"推过去的二进制落在哪"就得从这里读（只读，不影响任何行为）。
  String get installPath => _installPath;

  bool get isClosed => _closed;

  /// 权威的判活面（协议 §2）：核心每心跳拉一次 `tunnel.state`。
  Map<String, dynamic> stateJson() => <String, dynamic>{
    'conn_id': connId,
    'host': config.host,
    'port': config.port,
    'username': config.username,
    'root': _root,
    'state': _state,
    'attempt': _attempts,
    'elapsed_ms': now().difference(_startedAt).inMilliseconds,
    'last_error': _lastError,
    'agent': _hello?.toJson() ?? const <String, dynamic>{},
  };

  /// 把它建起来（或复用正在跑的那次尝试）。返回是否 `ready`。
  ///
  /// **单飞**：并发的 `ensureReady` 复用同一个在途尝试（不会为一个 key 建两条连接）。
  Future<bool> ensureReady() {
    if (_closed) return Future<bool>.value(false);
    final AgentClient? client = _client;
    if (_state == TunnelStates.ready && client != null && !client.isClosed) {
      return Future<bool>.value(true);
    }
    final Future<bool>? inFlight = _attemptInFlight;
    if (inFlight != null) return inFlight;
    final Future<bool> attempt = _attempt().whenComplete(() {
      _attemptInFlight = null;
    });
    _attemptInFlight = attempt;
    return attempt;
  }

  /// 转发一次 L2 请求。
  ///
  /// 返回 L1 `tunnel.request` 的 result 形态：
  /// `{ok:true, result}` / `{ok:false, error}`（+**链路级失败**才带 `error_kind`；
  /// agent 回的业务错误透传 `error_code` / `error_data`，由核心映射成 `not_found` 这类语义
  /// —— 字段名与 `plugin_tunnel_link.dart` 的读法一致）。
  ///
  /// **`error_kind` 的两种失败必须分清**（协议 §5，2026-10-11 修）：
  /// - [TunnelErrorKinds.tunnelNotReady]：隧道**还没好**（`connecting`/`booting`/`reconnecting`）
  ///   ⇒ 本次请求**没有转发给 agent**（确定未执行）⇒ 核心会**等它回来再发**；
  /// - [TunnelErrorKinds.tunnelDown]：已判死 / 已关闭 / 通道**中途**断
  ///   ⇒ 核心如实失败，**不重发**（中途断无法断言有没有执行到）。
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_closed) {
      return _down('隧道已关闭');
    }
    final AgentClient? client = _client;
    if (_state == TunnelStates.down) {
      return _down(
        '隧道已判死（${_lastErrorKind ?? '未知原因'}）：${_lastError ?? '未提供原因'}',
      );
    }
    if (_state != TunnelStates.ready || client == null || client.isClosed) {
      return _notReady(
        '隧道未就绪（state=$_state）${_lastError == null ? '' : '：$_lastError'}',
      );
    }

    Map<String, dynamic> forwarded = params;
    if (method == AgentMethods.execRun) {
      forwarded = await _wrapLoginShell(params);
    }

    try {
      final Map<String, dynamic> result = await client.call(method, forwarded);
      return <String, dynamic>{'ok': true, 'result': result};
    } on AgentChannelClosed catch (error) {
      // 链路级：本次如实失败，并触发重连。
      //
      // **文案刻意不承诺"未执行"**：通道断在请求中途，远端有没有执行到我们无从得知
      // （`exec.run` 那种命令更不能替它断言）——所以核心**不会自动重试**它，
      // 只会如实把失败交上去（协议 §0 红线 3：不自动重放）。
      _onLinkLost('$error');
      return <String, dynamic>{
        'ok': false,
        'error': '隧道通道已断，本次操作**结果未知**（不会自动重试）：$error',
        'error_kind': TunnelErrorKinds.tunnelDown,
      };
    } on RpcException catch (error) {
      // agent 回了错误：链路是好的 ⇒ 如实暴露（核心据 `error_code` 映射业务语义），**不回退**。
      // 字段名与核心侧读法对齐（`plugin_tunnel_link.dart`：`error_code` / `error_data`）。
      return <String, dynamic>{
        'ok': false,
        'error': '${describeRpcCode(error.code)}：${error.message}',
        'error_code': error.code,
        if (error.data != null) 'error_data': error.data,
      };
    } catch (error) {
      return <String, dynamic>{'ok': false, 'error': '转发失败：$error'};
    }
  }

  /// `tunnel.reconnect`：**清零退避并立即重试**（不等退避用完）。
  ///
  /// `ready` **不等于通道真的通**：agent 可能卡死（进程还在、但不回帧），这时老实现直接
  /// 返回（no-op）⇒ 核心每次判失活来重连都撞在空转上，那个卡死的 agent 永远换不掉
  /// （用户 2026-10-11 点名要修）。所以先做一次**带超时的 `agent.ping` 探针**：
  /// - 答得上来说明通道是好的 ⇒ 显式重连只是"不等退避"，**不打散**健康通道；
  /// - 答不上来 ⇒ 当成通道已死，**真的拆掉重建**。
  Future<void> reconnect() async {
    if (_closed) return;
    log?.call('收到显式重连（$connId / ${config.label}）：清零退避并立即重试');
    backoff.reset();
    _cancelRetry();
    final AgentClient? client = _client;
    if (_state == TunnelStates.ready && client != null && !client.isClosed) {
      if (await _pingWithTimeout(kAgentPingTimeout)) {
        return; // 已经好的：显式重连是"不等退避"，不是"强制重建"。
      }
      if (_closed) return;
      log?.call('显式重连时 agent 无响应（$connId）⇒ 强制拆掉重建');
      _onLinkLost('显式重连探针无响应（agent 可能卡死）');
      await ensureReady();
      return;
    }
    await ensureReady();
  }

  /// 收掉这条隧道（幂等）。
  ///
  /// agent 由这条通道拉起（协议 §8：通道断 = agent 退），所以这里关通道 + 关连接就是
  /// "收掉隧道"；**没有**额外 `kill` agent 进程，**更没**碰它托管的后台任务
  /// （`setsid` + 落盘退出码，与隧道无关）。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cancelRetry();
    _cancelPing();
    final AgentClient? client = _client;
    _client = null;
    _loginShell = null;
    _hello = null;
    if (client != null) {
      try {
        await client.close();
      } catch (error) {
        log?.call('关闭 agent 通道时出错（忽略）：$error');
      }
    }
    await _teardownConnection();
  }

  // ───────────────────────── 内部 ─────────────────────────

  Future<bool> _attempt() async {
    if (_closed) return false;
    _cancelRetry();
    _attempts++;
    _setState(_everReady ? TunnelStates.reconnecting : TunnelStates.connecting);
    SshConnection? connection;
    try {
      connection = await dialer(config);
      if (_closed) {
        await connection.close();
        return false;
      }
      _connection = connection;
      _setState(TunnelStates.booting);
      // 上一世 agent 还在的话，**先把它收掉**再推新的（用户 2026-10-11 要的"不累积"）。
      // 双保险：agent 自己也会在静默上限（`--idle-timeout-ms`）后优雅退出，但它察觉断连
      // 需要时间，而这里能在重建之前就把窗口关掉。判据是一次性 token（见 [_reapPreviousAgent]）。
      await _reapPreviousAgent(connection);
      // token 在**外层**生成：这样脱敏清单里有它，任何异常文本都不会把凭据漏进日志。
      final String token = newHandshakeToken(random: _random);
      _handshakeToken = token;
      final BootstrapResult result = await runBootstrap(
        connection: connection,
        config: config,
        agent: agent,
        loadBinary: loadBinary,
        token: token,
        log: log,
        chunkBytes: chunkBytes,
      );
      if (_closed) {
        await result.client.close();
        await _teardownConnection();
        return false;
      }
      _client = result.client
        ..onNotification = _onAgentNotification
        ..onClosed = _onLinkLost;
      _hello = result.hello;
      _root = result.root;
      _installPath = result.installPath;
      _loginShell = result.loginShell;
      // 记下"这一世"的 pid 与启动 token：下一次重建时靠它们精确收掉它。
      _lastAgentPid = result.hello.pid >= 0 ? result.hello.pid : null;
      _lastAgentToken = token;
      _everReady = true;
      backoff.reset();
      _lastError = null;
      _lastErrorKind = null;
      _setState(TunnelStates.ready);
      return true;
    } catch (error) {
      final String kind = error is BootstrapException
          ? error.kind
          : (error is SshConfigException
                ? TunnelErrorKinds.configIncomplete
                : TunnelErrorKinds.agentUnreachable);
      final String message = _sanitize(error.toString());
      await _teardownConnection();
      _recordFailure(kind, message);
      log?.call('隧道建立失败（$connId / ${config.label}）：$kind —— $message');
      if (_isFatal(kind)) {
        backoff.reset();
        _setState(TunnelStates.down);
      } else {
        _scheduleRetry();
      }
      return false;
    }
  }

  void _scheduleRetry() {
    if (_closed) return;
    final Duration? delay = backoff.take();
    if (delay == null) {
      log?.call(
        '退避累计上限（${backoff.maxTotal.inMinutes} 分钟）用尽（$connId）⇒ ${TunnelStates.down}，'
        '核心将回退内置 SSH',
      );
      _setState(TunnelStates.down);
      return;
    }
    log?.call(
      '${delay.inMilliseconds}ms 后重试（$connId，${backoff.describe()}）',
    );
    _setState(TunnelStates.reconnecting);
    _retryTimer = timerFactory(delay, () {
      _retryTimer = null;
      unawaited(ensureReady());
    });
  }

  /// 通道断了 / 关了（[AgentClient] 的回调；也可能来自写了才发现写不进去）。
  void _onLinkLost(String reason) {
    if (_closed) return;
    final String message = _sanitize(reason);
    log?.call('隧道通道断了（$connId / ${config.label}）：$message');
    _cancelPing();
    _client = null;
    _loginShell = null;
    _hello = null;
    unawaited(_teardownConnection());
    _recordFailure(TunnelErrorKinds.tunnelDown, message);
    _scheduleRetry();
  }

  void _onAgentNotification(String method, Map<String, dynamic> params) {
    // PTY 的两条通知是"数据面/退出面"，必须原样转给核心（协议 §2 的 tunnel/event）。
    if (method == AgentMethods.shellData) {
      onEvent?.call(<String, dynamic>{
        'conn_id': connId,
        'kind': TunnelEventKind.shellData,
        if (params['shell_id'] != null) 'shell_id': params['shell_id'],
        if (params['data'] != null) 'data': params['data'],
      });
      return;
    }
    if (method == AgentMethods.shellExit) {
      onEvent?.call(<String, dynamic>{
        'conn_id': connId,
        'kind': TunnelEventKind.shellExit,
        if (params['shell_id'] != null) 'shell_id': params['shell_id'],
        if (params['exit_code'] != null) 'exit_code': params['exit_code'],
      });
      return;
    }
    // 其余通知只记日志（**不静默**，但不污染核心的通知面）。
    log?.call('agent 通知（未转发）：$method ${jsonSummary(params)}');
  }

  Future<Map<String, dynamic>> _wrapLoginShell(
    Map<String, dynamic> params,
  ) async {
    final Object? raw = params['command'];
    final LoginShell? shell = _loginShell;
    if (raw is! String || shell == null) return params;
    final String wrapped = await shell.wrap(raw);
    if (wrapped == raw) return params;
    return <String, dynamic>{...params, 'command': wrapped};
  }

  /// 隧道**已判死 / 已关闭**：别再等了（退避耗尽、不可调和，或隧道已被显式收掉）。
  Map<String, dynamic> _down(String reason) => <String, dynamic>{
    'ok': false,
    'error': reason,
    'error_kind': TunnelErrorKinds.tunnelDown,
    'tunnel_state': _state,
  };

  /// 隧道**还没好**（`connecting` / `booting` / `reconnecting`）：**本次请求没有转发给 agent**。
  ///
  /// 核心拿到它应当**等隧道回来再发**（不是判死、不是回退）——见协议 §5 与
  /// `TunnelErrorKinds.tunnelNotReady` 的注释。
  Map<String, dynamic> _notReady(String reason) => <String, dynamic>{
    'ok': false,
    'error': reason,
    'error_kind': TunnelErrorKinds.tunnelNotReady,
    'tunnel_state': _state,
    'attempt': _attempts,
  };

  Future<void> _teardownConnection() async {
    final SshConnection? connection = _connection;
    _connection = null;
    if (connection == null) return;
    try {
      await connection.close();
    } catch (error) {
      log?.call('关闭 SSH 连接时出错（忽略）：$error');
    }
  }

  void _cancelRetry() {
    final DelayTimer? timer = _retryTimer;
    _retryTimer = null;
    timer?.cancel();
  }

  // ── agent 保活（卡死检测）─────────────────────────────────────────────

  /// 排下一拍保活（**自调度**，不用周期性定时器：一拍一判，卡死时能连着数拍）。
  void _schedulePing() {
    _cancelPing();
    if (_closed || _state != TunnelStates.ready) return;
    _pingTimer = timerFactory(kAgentPingInterval, () {
      _pingTimer = null;
      unawaited(_beatAgent());
    });
  }

  void _cancelPing() {
    final DelayTimer? timer = _pingTimer;
    _pingTimer = null;
    timer?.cancel();
  }

  /// 一拍保活：ping 不通就计数，连续 [kAgentPingMissLimit] 拍 ⇒ 当成通道已死并重建。
  ///
  /// 这条补的是"agent **卡死**（进程还在、但不回帧）"：老实现里 `tunnel.reconnect` 在
  /// `ready` 时直接返回，核心判失活后的每次重连都撞在 no-op 上 ⇒ 那个 agent 永远换不掉。
  Future<void> _beatAgent() async {
    if (_closed || _state != TunnelStates.ready) return;
    final bool ok = await _pingWithTimeout(kAgentPingTimeout);
    if (_closed || _state != TunnelStates.ready) return;
    if (ok) {
      _pingMisses = 0;
      _schedulePing();
      return;
    }
    _pingMisses++;
    log?.call(
      'agent 保活第 $_pingMisses/$kAgentPingMissLimit 拍无响应（$connId / ${config.label}）',
    );
    if (_pingMisses >= kAgentPingMissLimit) {
      // 拆掉重建。**不碰**它托管的后台任务：它们在目标机 `setsid` 独立跑，
      // 退出码与台账都在目标机磁盘上，新 agent 起来后会从台账认领（协议 §3.4）。
      _onLinkLost('agent 连续 $kAgentPingMissLimit 拍无响应（进程可能卡死）');
      return;
    }
    _schedulePing();
  }

  /// 带超时的 `agent.ping`（**保活探针专用**：不改 `AgentClient.call` 的"无静态超时"口径）。
  ///
  /// 注意实现形状：**不能让调用方等那个没有超时的 future**——ping 发出去没人回，
  /// `client.call` 会一直挂着，所以这里把它丢给一个旁路 task，只等 [timeout]。
  Future<bool> _pingWithTimeout(Duration timeout) async {
    final AgentClient? client = _client;
    if (client == null || client.isClosed) return false;
    final Completer<bool> done = Completer<bool>();
    final DelayTimer timer = timerFactory(timeout, () {
      if (!done.isCompleted) done.complete(false);
    });
    unawaited(() async {
      try {
        await client.call(AgentMethods.ping);
        if (!done.isCompleted) done.complete(true);
      } catch (error) {
        if (!done.isCompleted) done.complete(false);
      }
    }());
    final bool ok = await done.future;
    timer.cancel();
    return ok;
  }

  /// 重建之前收掉**上一世 agent**（若它还活着）。
  ///
  /// 判据是启动时那次性 token：agent 的 argv 里带着 `--token <32 位 hex>`，token 只在命令行里
  /// 出现过、每次启动都换新的 ⇒ 在目标机 `/proc/<pid>/cmdline` 里核对得上才杀。
  /// **核对不上（pid 不在了 / 被别的进程复用了 / 读不到）就不杀**，只记日志——
  /// 宁可留一个（它会按静默上限自己退出），也绝不误杀别的进程或别的客户端的 agent。
  Future<void> _reapPreviousAgent(SshConnection connection) async {
    final int? pid = _lastAgentPid;
    final String? token = _lastAgentToken;
    _lastAgentPid = null;
    _lastAgentToken = null;
    if (pid == null || token == null || token.isEmpty) return;
    final String command =
        'if [ -r /proc/$pid/cmdline ]; then '
        'if tr "\\0" " " < /proc/$pid/cmdline | grep -qF -- ${posixSingleQuote(token)}; '
        'then kill $pid 2>/dev/null; sleep 1; '
        // 卡死的 agent（例如被 SIGSTOP 冻住、或死在自己的 read 上）收到 TERM 未必走，
        // 1 秒后仍在就升级 KILL —— 否则"上一世 agent 收不掉"这件事会以最隐蔽的方式回来。
        'if kill -0 $pid 2>/dev/null; then kill -9 $pid 2>/dev/null; echo reaped-kill; '
        'else echo reaped; fi; '
        'else echo not-ours; fi; '
        'else echo gone; fi';
    try {
      final ExecOutcome outcome = await connection.exec(command);
      log?.call(
        '上一世 agent 清理（$connId / pid $pid）：${outcome.stdoutText.trim()}',
      );
    } catch (error) {
      log?.call('上一世 agent 清理失败（忽略；它会按静默上限自己退出）：$error');
    }
  }

  void _recordFailure(String kind, String message) {
    _lastErrorKind = kind;
    _lastError = message;
  }

  /// 不可调和的失败（再试也没意义 ⇒ 直接 `down`，别拿 30 分钟退避骗人）。
  static bool _isFatal(String kind) =>
      kind == TunnelErrorKinds.handshakeFailed ||
      kind == TunnelErrorKinds.archUnsupported ||
      kind == TunnelErrorKinds.configIncomplete;

  void _setState(String next) {
    if (_state == next) return;
    _state = next;
    // 保活只在 `ready` 期间跑：其它状态要么通道还没建（没什么可 ping），
    // 要么已经断了（重建由退避重连负责，别和它打架）。
    if (next == TunnelStates.ready) {
      _pingMisses = 0;
      _schedulePing();
    } else {
      _cancelPing();
    }
    log?.call('隧道状态（$connId / ${config.label}）：$next');
    onEvent?.call(<String, dynamic>{
      'conn_id': connId,
      'kind': TunnelEventKind.state,
      'state': next,
      'attempt': _attempts,
      if (_lastError != null) 'last_error': _lastError,
      if (_installPath.isNotEmpty) 'agent_path': _installPath,
    });
  }

  /// 日志脱敏：把可能出现在异常文本里的凭据片段抹掉（**绝不漏口令/握手 token**）。
  String _sanitize(String message) => sanitizeSecrets(
    message,
    secrets: <String>[
      config.password,
      config.keyPassphrase,
      _handshakeToken ?? '',
    ],
  );
}

/// 把 [secrets] 里非空的值从 [message] 里抹成 `***`（日志安全的最后一道闸）。
String sanitizeSecrets(String message, {List<String> secrets = const <String>[]}) {
  String out = message;
  for (final String secret in secrets) {
    if (secret.isEmpty) continue;
    out = out.replaceAll(secret, '***');
  }
  return out;
}

/// 通知体量小、可读的摘要（避免把 base64 数据面整段写进日志）。
String jsonSummary(Map<String, dynamic> params) {
  final List<String> parts = <String>[];
  params.forEach((String key, Object? value) {
    if (value is String && value.length > 32) {
      parts.add('$key=<${value.length} 字符>');
    } else {
      parts.add('$key=$value');
    }
  });
  return '{${parts.join(', ')}}';
}
