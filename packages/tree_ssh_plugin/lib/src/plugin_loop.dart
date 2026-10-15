import 'dart:async';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'agent_binary.dart';
import 'bootstrap.dart';
import 'ssh_dialer.dart';
import 'tunnel.dart';
import 'tunnel_manager.dart';
import 'ui_panel.dart';

/// 本插件在 `hello` 里自报的身份（核心只读 `plugin_id` / `name` / `capabilities`）。
///
/// `plugin_id` 直接用协议包里的 `kSshExecutorPluginId`：核心的面板开关、内置目录播种、
/// `sshExecutorLookup()` 的文案都用这**同一个字符串**（核心当前按**能力**认身份，
/// 但另起一个 id 只会在将来埋雷）。
const String kPluginId = kSshExecutorPluginId;
const String kPluginName = 'SSH 执行器中转站';
const String kPluginVersion = '0.1.0';

/// 既有插件协议的**标准方法名**（`hello` / `ping` / `shutdown` / `tools/list`）。
///
/// 说明：`tree_tunnel_protocol` 只收敛**中转站协议**的方法名与错误码（协议 §2 的 5 个
/// `tunnel.*`），标准插件方法不在其中（核心侧同样是字面量，见 `plugin_host.dart` 的
/// `_request('hello')` / `_request('tools/list')`）。所以它们在本文件里定义一次，
/// 全插件只引用常量，不散落字面量。
abstract final class PluginMethods {
  static const String hello = 'hello';
  static const String ping = 'ping';
  static const String toolsList = 'tools/list';
  static const String shutdown = 'shutdown';

  /// 核心**上行**给插件的通知 method（面板动作、工具事件等都在 `params['event']` 上）。
  static const String event = 'event';
}

/// 插件主循环（L1：核心 ⇄ 插件）。
///
/// 铁律（`plugin-development.md` §1）逐条落到代码里：
/// 1. **stdout 只放协议报文**（本类只通过 [send] 出帧，日志走 [log] → stderr）；
/// 2. **必须并发**：每个请求在独立的 Future 里处理，读循环**从不 await 业务**
///    （否则一次 `tunnel.ensure` 就把 `ping` 堵死 ⇒ 被判 degraded）；
/// 3. **心跳必答**：`ping` 是纯内存操作，永远立即回。
///
/// 未知方法**回 `-32601`，不静默**；`shutdown`（请求或通知）都收手退出。
class PluginLoop {
  PluginLoop({
    required SshDialer dialer,
    AgentBinaryLoader? loadBinary,
    TunnelManager? manager,
    required this.send,
    this.log,
    TimerFactory? timerFactory,
    TunnelUiPanel? uiPanel,
    TimerFactory? uiTimerFactory,
    DateTime Function()? now,
    int chunkBytes = kPushChunkBytes,
  }) {
    _manager = manager ??
        TunnelManager(
          dialer: dialer,
          loadBinary: loadBinary ?? AgentBinaryResolver().call,
          timerFactory: timerFactory,
          now: now,
          onEvent: _sendEvent,
          log: log,
          chunkBytes: chunkBytes,
        );
    // 左栏面板（2026-10-11 用户要求）：只读状态 + 两个动作。它**独立**于隧道自己
    // 的那套定时器（`uiTimerFactory` 缺省不复用 `timerFactory`）——面板的 300ms
    // 节流与退避/保活是两件事，混进同一个注入时钟会让"退避节奏"这类断言失真。
    _panel = uiPanel ??
        TunnelUiPanel(
          send: send,
          manager: _manager,
          timerFactory: uiTimerFactory,
          now: now,
          log: log,
        );
  }

  final void Function(Map<String, dynamic> message) send;
  final void Function(String message)? log;

  late final TunnelManager _manager;
  late final TunnelUiPanel _panel;

  final Set<Future<void>> _inFlight = <Future<void>>{};
  Completer<int>? _done;
  StreamSubscription<List<int>>? _input;
  bool _shuttingDown = false;

  // ── 插件 → 核心**主动请求**通道（2026-10-15：订阅 ssh.execute 点位用） ──
  //
  // 旧体系里本插件从不向核心发请求（只是被动接 `tunnel.*`）。迁移到「处理拓展点位」
  // 之后，插件要主动发一条 `station/subscribe` 把 ssh.execute 订上，因此这里补上
  // 「请求 → 等响应」的最小机制：出帧 id 单调递增，响应帧按 id 认领 completer。
  // **无静态超时**（同中转站其它请求）：只有进程收手（[_finish]）才把在途请求以
  // 可读错误收尾，绝不让一次订阅挂死读循环（读循环从不 await 这条链路）。
  final RpcIds _outIds = RpcIds();
  final Map<Object, Completer<Map<String, dynamic>>> _pendingOut =
      <Object, Completer<Map<String, dynamic>>>{};

  /// 是否已经发过 `station/subscribe`（一次握手成功即订上；重复 hello 不再重订）。
  bool _subscribed = false;

  /// 隧道台账（测试用）。
  TunnelManager get manager => _manager;

  /// 左栏面板（测试用）。
  TunnelUiPanel get panel => _panel;

  /// 当前在途的请求处理数（诊断用）。
  int get inFlightCount => _inFlight.length;

  /// 跑读循环；返回进程退出码。**只有** stdin 关闭或收到 `shutdown` 才会返回。
  Future<int> run(Stream<List<int>> input) {
    final Completer<int> done = Completer<int>();
    _done = done;
    // **声明左栏面板**（`ui/manifest` 只发一次）：不依赖 `hello` 的先后顺序——
    // 核心对通知不要求先握手，且它会把最后一个生效的 UI 帧缓存下来补发给后连的前端
    // （`PluginUiCache`）。在这里发的好处是"插件进程一起来，面板就在了"。
    _panel.declare();
    final LineFrameDecoder decoder = LineFrameDecoder(
      onFrame: _onFrame,
      onError: (String reason) => log?.call('核心报文的坏帧（已丢弃）：$reason'),
    );
    _input = input.listen(
      decoder.add,
      onError: (Object error) => _finish(1, '读 stdin 出错：$error'),
      onDone: () => _finish(0, '核心关闭了 stdin'),
      cancelOnError: false,
    );
    return done.future;
  }

  /// 主动收手（供 `shutdown` / 测试调用）。
  Future<void> shutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    log?.call('收到 shutdown：收掉全部隧道后退出');
    await _manager.closeAll();
    _finish(0, 'shutdown');
  }

  // ───────────────────────── 分发 ─────────────────────────

  void _onFrame(Map<String, dynamic> frame) {
    if (RpcIds.isRequest(frame)) {
      final Object? id = frame['id'];
      final String method = frame['method'] as String;
      final Map<String, dynamic> params = _paramsOf(frame);
      // **并发**：不 await，读循环立刻回到监听（铁律 2）。
      late final Future<void> task;
      task = _handleRequest(id, method, params).whenComplete(() {
        _inFlight.remove(task);
      });
      _inFlight.add(task);
      return;
    }
    if (RpcIds.isNotification(frame)) {
      final String method = frame['method'] as String;
      final Map<String, dynamic> params = _paramsOf(frame);
      if (method == PluginMethods.shutdown) {
        unawaited(shutdown());
      } else if (method == PluginMethods.event &&
          params['event'] == kUiActionEvent) {
        // 面板按钮 / 表单提交（核心上行形状见 `ui_panel.dart` 的 [kUiActionEvent]）。
        // **判据在 `params['event']` 上**，不是 `method`：写成 `method == 'plugin_ui_action'`
        // 永远不命中且不报错（`docs/plugin-development.md` §10 常见坑 ⑥）。
        unawaited(_panel.handleAction(params));
      } else {
        log?.call('核心通知（本插件不消费）：$method');
      }
      return;
    }
    // 响应帧（无 method、有 id）：只可能是**我方主动请求**（station/subscribe）的回包。
    if (RpcIds.isResponse(frame)) {
      final Object? id = frame['id'];
      final Completer<Map<String, dynamic>>? waiting = _pendingOut.remove(id);
      if (waiting != null && !waiting.isCompleted) waiting.complete(frame);
      return;
    }
    // 既非请求/通知、又不是我方在途请求的响应 ⇒ 陈旧/未知帧，留痕不静默。
    log?.call('忽略无法归类的帧（既非请求/通知，也不是我方在途请求的回包）');
  }

  Future<void> _handleRequest(
    Object? id,
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      switch (method) {
        case PluginMethods.hello:
          _reply(id, <String, dynamic>{
            'plugin_id': kPluginId,
            'name': kPluginName,
            'version': kPluginVersion,
            'protocol': kTunnelProtocolVersion,
            // ★ 核心"有没有中转站"的**兼容信号**（旧路径：按能力认，走 `tunnel.*`）。
            // 新路径（订上 ssh.execute 点位）由下面的 `_subscribeSshExecute()` 申报；
            // 两条信号核心 **OR**，因此旧核（不认点位）/ 新核（优先点位）都能工作。
            'capabilities': <String>[kCapabilitySshExecutor],
          });
          // 握手成功后**主动订阅** SSH 执行中转站点位（一次即可；不阻塞读循环）。
          if (!_subscribed) {
            _subscribed = true;
            unawaited(_subscribeSshExecute());
          }
          return;
        case PluginMethods.ping:
          _reply(id, <String, dynamic>{'ok': true});
          return;
        case PluginMethods.toolsList:
          // 执行器是**通道**不是点位：不申报任何工具（协议 §2 的说明）。
          _reply(id, <String, dynamic>{'tools': const <Object>[]});
          return;
        case PluginMethods.shutdown:
          _reply(id, <String, dynamic>{'ok': true});
          await shutdown();
          return;
        case TunnelMethods.ensure:
          // ── `tunnel.*`（兼容层）：只服务「只报 capability、不订点位」的旧核心 ──
          // 新路径是下面的 `StationMethods.request`（ssh.execute 点位）；两条共用同一
          // [_manager] 台账，故行为、失败分类、回退判据完全一致（不做"两条路各一份状态"）。
          _reply(id, await _manager.ensure(params));
          // 面板跟着台账走：**建隧道 / 复用 / 建失败**都把当前态刷一遍（用户正等着看的那一次）。
          _panel.refresh(force: true);
          return;
        case TunnelMethods.request:
          _reply(id, await _handleTunnelRequest(params));
          return;
        case TunnelMethods.state:
          _reply(id, _manager.state(_optionalString(params['conn_id'])));
          return;
        case TunnelMethods.reconnect:
          final String? connId = _requiredString(params['conn_id']);
          if (connId == null) {
            _replyError(id, RpcCodes.invalidParams, 'tunnel.reconnect 需要 conn_id');
            return;
          }
          _reply(id, await _manager.reconnect(connId));
          _panel.refresh(force: true);
          return;
        case TunnelMethods.close:
          final String? connId = _requiredString(params['conn_id']);
          if (connId == null) {
            _replyError(id, RpcCodes.invalidParams, 'tunnel.close 需要 conn_id');
            return;
          }
          _reply(id, await _manager.closeTunnel(connId));
          _panel.refresh(force: true);
          return;
        case StationMethods.request:
          // 「处理拓展点位」的新投递：核心把一次 SSH 操作投成 station/request，
          // payload 里带 `action`（与 tunnel.* 去掉前缀同名）。回包形状必须与
          // `tunnel.*` 一致（{ok, conn_id, ...}），核心 relaySshExecute 原样透传。
          final Map<String, dynamic> payload = _payloadOf(params);
          final Map<String, dynamic> result = await _runAction(payload);
          // 面板跟着台账走（与 tunnel.* 同口径）。
          final String action = (payload['action'] ?? '').toString();
          if (action == SshExecuteStation.ensure ||
              action == SshExecuteStation.reconnect ||
              action == SshExecuteStation.close) {
            _panel.refresh(force: true);
          }
          _reply(id, <String, dynamic>{
            'reply': <String, dynamic>{'payload': result},
          });
          return;
        default:
          // 未知方法**绝不静默**（协议级错误，不是业务级 ok:false）。
          _replyError(
            id,
            RpcCodes.methodNotFound,
            'method not found: $method',
          );
          return;
      }
    } on RpcFailure catch (failure) {
      // 业务侧参数不全 ⇒ 协议级 `-32602`（不是内部错）。
      _replyError(id, failure.code, failure.message);
    } catch (error) {
      _replyError(id, RpcCodes.internalError, '$method 处理异常：$error');
    }
  }

  Future<Map<String, dynamic>> _handleTunnelRequest(
    Map<String, dynamic> params,
  ) async {
    final String? connId = _requiredString(params['conn_id']);
    final String? method = _requiredString(params['method']);
    if (connId == null || method == null) {
      throw RpcFailure(
        RpcCodes.invalidParams,
        'tunnel.request 需要 conn_id 与 method',
      );
    }
    final Object? raw = params['params'];
    final Map<String, dynamic> inner = raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry('$k', v))
        : <String, dynamic>{};
    return _manager.request(connId, method, inner);
  }

  /// 从 `station/request` 的 params 里取出核心投递的载荷（中转站把它放在 `payload`）。
  static Map<String, dynamic> _payloadOf(Map<String, dynamic> params) {
    final Object? raw = params['payload'];
    if (raw is! Map) return <String, dynamic>{};
    return raw.map((dynamic k, dynamic v) => MapEntry('$k', v));
  }

  /// **按 `action` 分发**到 [TunnelManager]（`station/request` 与旧 `tunnel.*` 共用同一套台账）。
  ///
  /// 回包形状与对应 `tunnel.*` 方法**完全一致**（`{ok, conn_id, ...}` / `{ok:false, error, error_kind}`），
  /// 核心的 `relaySshExecute` 原样透传，`StationTunnelLink` 据此翻成 [TunnelUnavailableException]
  /// 或会话数据——因此新旧两条路对目标机的行为、失败分类、回退判据都同一。
  Future<Map<String, dynamic>> _runAction(Map<String, dynamic> payload) async {
    final String action = (payload['action'] ?? '').toString();
    switch (action) {
      case SshExecuteStation.ensure:
        return _manager.ensure(payload);
      case SshExecuteStation.request:
        return _handleTunnelRequest(payload);
      case SshExecuteStation.state:
        return _manager.state(_optionalString(payload['conn_id']));
      case SshExecuteStation.reconnect:
        final String? connId = _requiredString(payload['conn_id']);
        if (connId == null) {
          return <String, dynamic>{
            'ok': false,
            'error': 'ssh.execute(reconnect) 需要 conn_id',
          };
        }
        return _manager.reconnect(connId);
      case SshExecuteStation.close:
        final String? connId = _requiredString(payload['conn_id']);
        if (connId == null) {
          return <String, dynamic>{'ok': false, 'error': 'ssh.execute(close) 需要 conn_id'};
        }
        return _manager.closeTunnel(connId);
      default:
        // 认不出的 action：如实报可读错误（核心据此回退内置，不静默成功）。
        return <String, dynamic>{
          'ok': false,
          'error': '未知的 SSH action：$action',
        };
    }
  }

  /// 主动发一条 JSON-RPC 请求给核心并等它的响应帧（按 id 认领）。
  ///
  /// **无静态超时**：只有进程收手（[_finish]）才把在途请求以可读错误收尾。调用方
  /// （[_subscribeSshExecute]）不 await 进读循环，因此一次订阅永不阻塞 `ping` / 其它请求。
  Future<Map<String, dynamic>> _requestCore(
    String method,
    Map<String, dynamic> params,
  ) {
    final Object id = _outIds.next();
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pendingOut[id] = completer;
    send(rpcRequest(id as int, method, params));
    return completer.future;
  }

  /// 握手后订阅 SSH 执行中转站点位（`station/subscribe`，`point: ssh.execute`）。
  ///
  /// `replace: true`：中转站唯一订阅者，插件重启后把陈旧订阅接管回来（与热切换语义一致）。
  /// 订阅失败（核心不认这个点位 = 旧核心）只记日志——旧路径 `tunnel.*` 仍在，功能不回归。
  Future<void> _subscribeSshExecute() async {
    try {
      final Map<String, dynamic> response = await _requestCore(
        StationMethods.subscribe,
        <String, dynamic>{
          'station': SshExecuteStation.kind,
          'point': SshExecuteStation.alias,
          'replace': true,
        },
      );
      final Map<String, dynamic> result = _resultOf(response);
      final bool ok = result['ok'] == true;
      log?.call(
        ok
            ? '已订阅 SSH 执行中转站点位（${SshExecuteStation.pointId}）'
            : '订阅 SSH 执行点位未成功（旧路径 tunnel.* 继续可用）：'
                '${result['error'] ?? '核心未回 ok'}',
      );
    } catch (error) {
      log?.call('订阅 SSH 执行点位异常（旧路径 tunnel.* 继续可用）：$error');
    }
  }

  static Map<String, dynamic> _resultOf(Map<String, dynamic> frame) {
    final Object? result = frame['result'];
    if (result is Map) {
      return result.map((dynamic k, dynamic v) => MapEntry('$k', v));
    }
    return <String, dynamic>{};
  }

  void _reply(Object? id, Map<String, dynamic> result) {
    send(rpcResult(id ?? 0, result));
  }

  void _replyError(Object? id, int code, String message) {
    send(rpcErrorResult(id ?? 0, code, message));
  }

  void _sendEvent(Map<String, dynamic> event) {
    // 及时性补充（权威面是 tunnel.state）：丢了不致命，所以这里只发不成对。
    send(rpcNotification(TunnelMethods.event, event));
    // 面板只关心**状态跃迁**（PTY 的 shell.data / shell.exit 与面板无关，别刷它）。
    // 刷新走 `ui/update`：核心刻意不把 `tunnel/event` 降级成 plugin_event
    // （它是核心与插件之间的内部数据面），拿它刷面板不会生效。
    if (event['kind'] == TunnelEventKind.state) _panel.refresh();
  }

  void _finish(int code, String reason) {
    final Completer<int>? done = _done;
    if (done == null || done.isCompleted) return;
    log?.call('插件主循环结束（exit=$code）：$reason');
    // 我方在途请求（station/subscribe）再等不到回包：以可读错误显式收尾，
    // 不留悬空 Future（与「进程退出即在途调用显式失败」的总线口径一致）。
    for (final Completer<Map<String, dynamic>> completer
        in _pendingOut.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('插件已收手：$reason'));
      }
    }
    _pendingOut.clear();
    unawaited(_input?.cancel());
    done.complete(code);
  }

  static Map<String, dynamic> _paramsOf(Map<String, dynamic> frame) {
    final Object? raw = frame['params'];
    if (raw is! Map) return <String, dynamic>{};
    return raw.map((dynamic k, dynamic v) => MapEntry('$k', v));
  }

  static String? _requiredString(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    return null;
  }

  static String? _optionalString(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    return null;
  }
}

/// 内部用的"参数非法/业务异常"载体（只在本文件里转成 JSON-RPC error 响应）。
class RpcFailure implements Exception {
  RpcFailure(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => message;
}

/// 把一行帧编码成 UTF-8 字节（bin 层用于写 stdout；**永不写日志进 stdout**）。
List<int> frameBytes(Map<String, dynamic> message) => encodeFrame(message);
