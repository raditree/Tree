import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'local_workspace_io.dart' show WorkspaceIoException;
import 'pty/pty_session.dart' show PtyUnsupportedException;
import 'ssh_liveness.dart';
import 'ssh_shell_channel.dart';
import 'ssh_workspace_io.dart';
import 'tunnel_background.dart';
import 'tunnel_link.dart';

/// [SshTransport] 的**中转站实现**：把接口的每个方法映射成"经插件转发给
/// 目标机 `tree_agent`"的一次 JSON-RPC。
///
/// 为什么做成一个 `SshTransport`（而不是另起一套 IO 接口）：`SshWorkspaceIO` 是**面向
/// `SshTransport` 写的** —— 相对路径约束、行范围读取、唯一匹配编辑、grep 排除规则、
/// 结果截断、软超时交还、后台执行原语、文件面板的结构改动、PTY 透传，**一行都不用改**。
/// 换后端因此是"一个类"的事，而不是"把所有消费方都改一遍"。
///
/// 与 `DartSshTransport` 的关系：**并列的两条后端**，由核心 `sshIoFactory` 选路；
/// 本类不依赖 dartssh2，也不与它共享连接（`close()` 只关自己这条隧道）。
///
/// 活性口径与 `DartSshTransport` **完全一致**（M9 1.1，见 `ssh_liveness.dart`）：
/// - 判据只看**心跳**（本类的心跳 = 每 `heartbeatInterval` 拉一次 `tunnel.state`；
///   数据还在流动即链路活着）；
/// - 判失活**不关**任何东西，只让在途操作以 [SshLinkStaleException] 显式失败，
///   并在跨阈值那一拍触发后台重连（`tunnel.reconnect`）；
/// - **不引入静态总时长上限**：命令跑多久都等（`exec.run` 的软窗口归 `SshWorkspaceIO`）。
///
/// **"判死"与"暂时不可用"是两件事**（2026-10-11 修，用户口径）：
/// - 判死（⇒ 下一次工作空间解析回退内置）**只有两个来源**：心跳快照说 `down`（插件退避耗尽，
///   见 [_beat]）、或插件进程已不可用（本地事实）；
/// - 请求级失败（`tunnel_not_ready`）**绝不判死**：那是"重连中"，此时前台操作**等隧道恢复**
///   再发（`tunnel_not_ready` 的请求**确定未执行** ⇒ 重发不是重放），后台任务照旧"什么都不发"地等；
/// - 请求级 `tunnel_down`（通道断在请求中途）**如实失败**，既不判死也不重放。
class TunnelSshTransport
    implements SshTransport, FallbackableWorkspace, TunnelBackgroundExec {
  /// 私有构造：字段一律用 **位置参数** 初始化（这样私有字段也能走 initializing formal，
  /// 不必写六行 `x = x`）。
  TunnelSshTransport._(
    this._session,
    this.root,
    this._liveness,
    this._heartbeatInterval,
    this._log, [
    this._readyPollInterval = const Duration(seconds: 1),
    this._maxReadyWait = const Duration(minutes: 30),
  ]);

  /// 经中转站建立一条隧道（**唯一入口**）。
  ///
  /// 失败抛 [TunnelUnavailableException]（带 `kind`）：调用方（核心 `sshIoFactory`）
  /// 据此决定"回退内置"还是"如实报错"。
  static Future<TunnelSshTransport> connect(
    TunnelLink link,
    TunnelConnectRequest request, {
    void Function(String message)? log,
    Duration readyPollInterval = const Duration(seconds: 1),
    Duration maxReadyWait = const Duration(minutes: 30),
  }) async {
    if (!link.available) {
      throw TunnelUnavailableException(
        TunnelErrorKinds.agentUnreachable,
        '没有可用的 SSH 中转站（插件缺失 / 未启用 / 未申报 ssh-executor 能力）',
      );
    }
    final TunnelSession session = await link.ensure(request);
    final SshLiveness liveness = SshLiveness(
      interval: request.heartbeatInterval,
      maxMisses: request.maxMissedHeartbeats,
    );
    final TunnelSshTransport transport = TunnelSshTransport._(
      session,
      session.root,
      liveness,
      request.heartbeatInterval,
      log,
      readyPollInterval,
      maxReadyWait,
    );
    // 判失活的那一拍起一次后台重连（与 DartSshTransport 同一挂载点、同一语义）。
    liveness.onStale = transport._handleStale;
    transport._startHeartbeat();
    log?.call(
      '经中转站建立隧道 ${session.connId}：${request.redacted()} root=${session.root}',
    );
    return transport;
  }

  /// 远端工作空间根（绝对路径，由目标机 agent 解析）。
  ///
  /// 注意：**这不是 `SshTransport` 的成员**（那个接口只有字节搬运），是给核心
  /// `sshIoFactory` 用的：它要拿这个 root 构造 `SshWorkspaceIO(root, transport)`。
  final String root;

  final TunnelSession _session;
  final SshLiveness _liveness;
  final Duration _heartbeatInterval;
  final void Function(String message)? _log;

  bool _closed = false;
  bool _tunnelDown = false;
  String _fallbackReason = '';
  Timer? _heartbeatTimer;
  Future<void>? _reconnectInFlight;
  TunnelSnapshot? _lastSnapshot;

  /// 等隧道回到 `ready` 时的轮询节奏（测试注入短值，否则一条用例要等真 1 秒）。
  final Duration _readyPollInterval;

  /// 等隧道恢复的**总预算**（默认 30 min，与中转站的退避累计上限同量级）。
  ///
  /// 为什么要有它：用户口径是"断连期间**等到退避耗尽**再如实失败"，而退避耗尽的权威判据
  /// 是插件自标 `down`（心跳快照）。正常情况下插件一定会在累计上限处标 down，
  /// 这个预算只是**兜底**——防"隧道反复 ready/不 ready 抖动（每次成功都把退避清零）"时
  /// 一次前台调用无限期挂着。不自掐秒表地去猜远端状态，只给自己一个"别等成永恒"的上界。
  final Duration _maxReadyWait;

  // ── FallbackableWorkspace ────────────────────────────────────────────
  //
  // 隧道退避耗尽（插件自标 tunnel_down）之后，核心**必须**撤换这个 IO：
  // 否则 `_ios` 缓存里那条死链路会被一直用下去，"降级只发生在有没有插件这一维"
  // 这条红线就被悄悄破了。

  @override
  bool get tunnelDown => _tunnelDown;

  @override
  String get fallbackReason => _fallbackReason;

  /// 当前隧道快照（诊断 / 日志用；没拉到过时为 null）。
  TunnelSnapshot? get lastSnapshot => _lastSnapshot;

  /// 中转站探明的目标机信息（平台 / 架构 / agent 版本）。
  Map<String, dynamic> get agentInfo => _session.agent;

  // ── SshTransport ────────────────────────────────────────────────────

  @override
  SshLiveness get liveness => _liveness;

  @override
  Future<List<int>> read(String absolutePath) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in readStream(absolutePath)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> write(String absolutePath, List<int> bytes) async {
    if (bytes.isEmpty) {
      await _writeChunk(absolutePath, Uint8List(0), mode: 'write');
      return;
    }
    int offset = 0;
    bool first = true;
    while (offset < bytes.length) {
      final int end = math.min(offset + kReadChunkBytes, bytes.length);
      await _writeChunk(
        absolutePath,
        bytes.sublist(offset, end),
        mode: first ? 'write' : 'append',
      );
      first = false;
      offset = end;
    }
  }

  @override
  Future<int> size(String absolutePath) async {
    final Map<String, dynamic> stat = await _statOf(absolutePath);
    if (stat['type'] == 'missing') {
      throw WorkspaceIoException('远端文件不存在：$absolutePath');
    }
    return (stat['size'] as num?)?.toInt() ?? 0;
  }

  @override
  Stream<List<int>> readStream(
    String absolutePath, {
    int offset = 0,
    int? length,
  }) async* {
    int position = offset < 0 ? 0 : offset;
    int? remaining = length != null && length >= 0 ? length : null;
    while (true) {
      if (remaining != null && remaining <= 0) return;
      final int want = remaining == null
          ? kReadChunkBytes
          : math.min(kReadChunkBytes, remaining);
      final Map<String, dynamic> result = _asMap(
        await _call(AgentMethods.fsRead, <String, dynamic>{
          'path': absolutePath,
          'offset': position,
          'length': want,
        }),
      );
      final List<int> chunk = base64Decode((result['data'] ?? '').toString());
      if (chunk.isEmpty) return; // 空块 = 没有更多（不靠 eof 也能收口）
      yield chunk;
      final int returnedOffset = (result['offset'] as num?)?.toInt() ?? position;
      position = returnedOffset + chunk.length;
      if (remaining != null) remaining -= chunk.length;
      if (result['eof'] == true) return;
    }
  }

  @override
  Future<void> writeStream(String absolutePath, Stream<List<int>> data) async {
    final List<int> buffer = <int>[];
    bool first = true;
    await for (final List<int> chunk in data) {
      buffer.addAll(chunk);
      while (buffer.length >= kReadChunkBytes) {
        final List<int> slice = buffer.sublist(0, kReadChunkBytes);
        buffer.removeRange(0, kReadChunkBytes);
        await _writeChunk(absolutePath, slice, mode: first ? 'write' : 'append');
        first = false;
      }
    }
    if (buffer.isNotEmpty || first) {
      await _writeChunk(absolutePath, buffer, mode: first ? 'write' : 'append');
    }
  }

  @override
  Future<List<String>> listFiles(String absolutePath, {int maxDepth = 2}) async {
    final Map<String, dynamic> result = _asMap(
      await _call(AgentMethods.fsList, <String, dynamic>{
        'path': absolutePath,
        'max_depth': maxDepth,
      }),
    );
    final Object? files = result['files'];
    if (files is! List) return <String>[];
    return files.map((dynamic e) => e.toString()).toList();
  }

  @override
  Future<List<SshFileEntry>> listEntries(
    String absolutePath, {
    int maxEntries = 5000,
  }) async {
    final Map<String, dynamic> result = _asMap(
      await _call(AgentMethods.fsListEntries, <String, dynamic>{
        'path': absolutePath,
        'max_entries': maxEntries,
      }),
    );
    final Object? entries = result['entries'];
    if (entries is! List) return <SshFileEntry>[];
    return entries
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> raw) {
          final Map<String, dynamic> map = raw.map(
            (dynamic k, dynamic v) => MapEntry(k.toString(), v),
          );
          final int? mtime = (map['mtime_ms'] as num?)?.toInt();
          return SshFileEntry(
            name: (map['name'] ?? '').toString(),
            isDirectory: (map['type'] ?? '') == 'dir',
            size: (map['size'] as num?)?.toInt() ?? 0,
            modified: mtime == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(mtime),
          );
        })
        .toList();
  }

  @override
  Future<bool> exists(String absolutePath) async {
    final Map<String, dynamic> result = _asMap(
      await _call(AgentMethods.fsExists, <String, dynamic>{'path': absolutePath}),
    );
    return result['exists'] == true;
  }

  @override
  Future<void> delete(String absolutePath) async {
    await _call(AgentMethods.fsDelete, <String, dynamic>{'path': absolutePath});
  }

  @override
  Future<void> makeDirectory(String absolutePath) async {
    await _call(AgentMethods.fsMkdir, <String, dynamic>{'path': absolutePath});
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    await _call(AgentMethods.fsRename, <String, dynamic>{
      'from': oldPath,
      'to': newPath,
    });
  }

  @override
  Future<void> remove(String absolutePath, {bool recursive = false}) async {
    await _call(AgentMethods.fsRemove, <String, dynamic>{
      'path': absolutePath,
      'recursive': recursive,
    });
  }

  @override
  Future<bool> isDirectory(String absolutePath) async {
    final Map<String, dynamic> result = _asMap(
      await _call(AgentMethods.fsIsDir, <String, dynamic>{'path': absolutePath}),
    );
    return result['is_dir'] == true;
  }

  @override
  Future<SshExecResult> run(
    String command, {
    Duration timeout = Duration.zero,
  }) async {
    // [timeout] **不在这里**兑现：软窗口归 `SshWorkspaceIO.exec`（它用 Future.any 与
    // `SshExecStillRunning` 把仍在跑的命令交出去）。本层透传 `timeout_ms: 0`（永不），
    // 语义与 `DartSshTransport.run` 忽略该参数完全一致——全仓"没有到点自动杀"。
    final Map<String, dynamic> result = _asMap(
      await _call(AgentMethods.execRun, <String, dynamic>{
        'command': command,
        'timeout_ms': 0,
      }),
    );
    return SshExecResult(
      exitCode: (result['exit_code'] as num?)?.toInt() ?? -1,
      stdout: _decodeBytes(result['stdout']),
      stderr: _decodeBytes(result['stderr']),
    );
  }

  @override
  Future<SshShellChannel> openShell({
    required int columns,
    required int rows,
    String command = '',
    String workingDirectory = '',
  }) async {
    final Map<String, dynamic> result;
    try {
      result = _asMap(
        await _call(
          AgentMethods.shellOpen,
          <String, dynamic>{
            'columns': columns,
            'rows': rows,
            if (command.isNotEmpty) 'command': command,
            if (workingDirectory.isNotEmpty) 'cwd': workingDirectory,
          },
          raw: true,
        ),
      );
    } on RpcException catch (error) {
      if (error.code == TunnelErrorCodes.ptyUnsupported) {
        // **绝不静默降级**成无 TTY 的一次性 exec（`tree_local_exec` 不变量 8）：
        // 那会让 vim/top/Ctrl+C 直接坏掉，比明确报错更难排查。
        throw PtyUnsupportedException('目标机不支持伪终端：${error.message}');
      }
      rethrow;
    }
    return _TunnelShellChannel(
      _session,
      (result['shell_id'] ?? '').toString(),
      command.isEmpty ? 'login shell' : command,
      _log,
    );
  }

  // ── TunnelBackgroundExec（后台执行由目标机 agent 托管）────────────────────
  //
  // 为什么这一层要有它：`SshWorkspaceIO.startBackground` 的既有实现是"远端 nohup +
  // 本机按 3s 轮询哨兵文件"。那条路的退出码与进展**依赖本机持续做 SSH 轮询**，
  // 断线 / 重启就会丢对账（用户点名的"跨日级不稳定"就是它）。
  // 走 agent 托管之后：进程 `setsid` 脱离、输出直写文件、退出码与台账都落**目标机磁盘**
  // ⇒ 通道断、核心崩、应用退都不影响，重连后 `exec.list` 重新对账。

  @override
  Future<TunnelBackgroundStart> spawnBackground({
    required String command,
    required String logAbsolutePath,
  }) async {
    final Map<String, dynamic> result = _asMap(
      await _call(AgentMethods.execSpawn, <String, dynamic>{
        'command': command,
        'log_path': logAbsolutePath,
      }),
    );
    return TunnelBackgroundStart(
      id: (result['id'] ?? '').toString(),
      logPath: (result['log_path'] ?? logAbsolutePath).toString(),
      pid: (result['pid'] as num?)?.toInt(),
      pgid: (result['pgid'] as num?)?.toInt(),
    );
  }

  @override
  Future<List<TunnelBackgroundProc>> listBackground() async {
    final Map<String, dynamic> result = _asMap(
      await _call(AgentMethods.execList, const <String, dynamic>{}),
    );
    final Object? procs = result['procs'];
    if (procs is! List) return const <TunnelBackgroundProc>[];
    return procs
        .whereType<Map<dynamic, dynamic>>()
        .map(_procOf)
        .toList(growable: false);
  }

  @override
  Future<TunnelBackgroundProc?> queryBackground(String id) async {
    try {
      final Map<String, dynamic> result = _asMap(
        await _call(AgentMethods.execQuery, <String, dynamic>{'id': id}),
      );
      final Object? proc = result['proc'];
      return proc is Map ? _procOf(proc) : null;
    } on RpcException catch (error) {
      if (error.code == TunnelErrorCodes.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<bool> killBackground(String id) async {
    final Map<String, dynamic> result = _asMap(
      await _call(AgentMethods.execKill, <String, dynamic>{'id': id}),
    );
    // `killed:false` = "拿不到 pid / 远端不认" ⇒ **不假装杀成功**（调用方据此如实回报）。
    return result['killed'] == true;
  }

  static TunnelBackgroundProc _procOf(Map<dynamic, dynamic> raw) {
    final Map<String, dynamic> map = raw.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    );
    return TunnelBackgroundProc(
      id: (map['id'] ?? '').toString(),
      logPath: (map['log_path'] ?? '').toString(),
      state: (map['state'] ?? BackgroundStates.gone).toString(),
      pid: (map['pid'] as num?)?.toInt(),
      pgid: (map['pgid'] as num?)?.toInt(),
      command: (map['command'] ?? '').toString(),
      startedAtMs: (map['started_at_ms'] as num?)?.toInt() ?? 0,
      exitCode: (map['exit_code'] as num?)?.toInt(),
    );
  }

  /// 显式重建（用户的「重连」/ 执行站 `ssh.reconnect`）：**重置退避 + 一次立即尝试**。
  /// 与 `DartSshTransport.reconnect` 同语义：建新连接**成功之后**才 `reset()` 丢失计数，
  /// 失败抛可读异常且**保持失活态**（绝不假装恢复了）；单飞（并发调用复用同一次）。
  @override
  Future<void> reconnect() =>
      _reconnectInFlight ??= _doReconnect().whenComplete(() {
        _reconnectInFlight = null;
      });

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    // 本类自己收掉这条隧道 = 这条链路**真的**没了（本地事实，不是猜远端）：
    // 标判死，让核心下一次工作空间解析重新建/或回退内置，别把一条已关闭的隧道留在缓存里。
    _markDown('隧道已被显式关闭');
    try {
      await _session.close();
    } catch (error) {
      _log?.call('关闭隧道 ${_session.connId} 失败（忽略）：$error');
    }
  }

  // ── 内部 ────────────────────────────────────────────────────────────

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (Timer _) {
      unawaited(_beat());
    });
  }

  /// 一拍心跳：拉一次 `tunnel.state`。**这是权威的判活证据面**（插件的推送只是补充）。
  Future<void> _beat() async {
    if (_closed) return;
    try {
      final TunnelSnapshot snapshot = await _session.snapshot();
      _lastSnapshot = snapshot;
      if (snapshot.down) {
        _markDown(
          '中转站已判隧道不可用（退避耗尽）：'
          '${snapshot.lastError.isEmpty ? '未提供原因' : snapshot.lastError}',
        );
        _liveness.recordMiss();
        return;
      }
      _liveness.recordBeat();
    } catch (error) {
      // 插件进程崩了 / 通道断了：等价于"没有中转站"。
      //
      // 但**只有插件真的不在了**才判死（红线 1：插件缺失/未启用/起不来 ⇒ 回退内置且明示）——
      // 插件还在、只是这条隧道的结果拉不到（网络抖动/隧道重连中）时**不判死**：
      // 那属于"等它回来"，正是用户 2026-10-11 要的口径。
      _log?.call('隧道 ${_session.connId} 心跳失败：$error');
      if (!_session.pluginAvailable) {
        _markDown('中转站插件已不可用（${_session.unavailableReason}）');
      }
      _liveness.recordMiss();
    }
  }

  void _handleStale() {
    if (_closed || _tunnelDown) return;
    _log?.call('隧道 ${_session.connId} 已判失活，开始后台重连（退避由中转站掌握）');
    unawaited(
      reconnect().catchError((Object error) {
        _log?.call('后台重连失败（会由中转站按退避继续）：$error');
      }),
    );
  }

  Future<void> _doReconnect() async {
    await _session.reconnect();
    _liveness.reset();
    _log?.call('隧道 ${_session.connId} 已重建');
  }

  void _markDown(String reason) {
    if (_tunnelDown) return;
    _tunnelDown = true;
    _fallbackReason = reason;
    _log?.call(
      '中转站不可用（$reason）—— 这条连接已判死，下一次工作空间解析将回退内置 dartssh2',
    );
  }

  /// 等隧道回到 `ready`；期间**不判死、不回退**，只看插件的权威快照（用户 2026-10-11 口径）。
  ///
  /// 出口只有三个：
  /// - 回到 `ready` ⇒ 返回，调用方重发那一次"确定未执行"的请求；
  /// - 插件自标 `down`（退避耗尽 / 不可调和）⇒ 判死 + 如实失败；
  /// - 状态都拉不到（插件通道坏了）⇒ 判死 + 如实失败；
  /// 外加一个**兜底预算** [_maxReadyWait]（防"反复 ready/不 ready 抖动"把一次调用挂成永恒）。
  Future<void> _awaitTunnelReadyElseFail() async {
    final Stopwatch waited = Stopwatch()..start();
    while (true) {
      if (_closed) {
        throw SshLinkStaleException('中转站隧道已关闭（本次操作未执行）');
      }
      if (_tunnelDown) {
        throw SshLinkStaleException('中转站已判隧道不可用：$_fallbackReason');
      }
      if (waited.elapsed >= _maxReadyWait) {
        throw SshLinkStaleException(
          '中转站隧道等待超过 ${_maxReadyWait.inMinutes} 分钟仍未恢复（本次操作未执行，如实失败）',
        );
      }
      await Future<void>.delayed(_readyPollInterval);
      final TunnelSnapshot snapshot;
      try {
        snapshot = await _session.snapshot();
      } catch (error) {
        _markDown('中转站状态不可用：$error');
        throw SshLinkStaleException('中转站不可用：$error');
      }
      _lastSnapshot = snapshot;
      if (snapshot.down) {
        _markDown(
          '中转站已判隧道不可用（退避耗尽）：'
          '${snapshot.lastError.isEmpty ? '未提供原因' : snapshot.lastError}',
        );
        throw SshLinkStaleException('中转站已判隧道不可用：$_fallbackReason');
      }
      if (snapshot.state == TunnelStates.ready) return;
    }
  }

  /// 发一次 L2 请求（统一活性守卫与错误翻译）。
  ///
  /// [raw] = true 时把 agent 的**业务错误**（[RpcException]）原样抛出，交给调用方按
  /// 具体 code 处理 —— 只有两处需要：`_statOf`（要认 `not_found`）与 `openShell`
  /// （要认 `pty_unsupported` 并抛 `PtyUnsupportedException`）。
  /// 其余调用方拿到的失败一律是 [WorkspaceIoException]：与 `DartSshTransport` 的口径
  /// 一致，上层（`SshWorkspaceIO` / 工具层 / 文件面板）才能按"IO 失败"统一处置 ——
  /// 漏一个裸 [RpcException] 上去，就等于让上层看见一个它不认识的异常类型（实测踩过）。
  Future<Object?> _call(
    String method,
    Map<String, dynamic> params, {
    bool raw = false,
  }) async {
    _liveness.ensureAlive();
    final Completer<void> stale = _liveness.watchStale();
    try {
      final Object? result = await Future.any<Object?>(<Future<Object?>>[
        _session.request(method, params),
        stale.future.then<Object?>((void _) {
          throw SshLinkStaleException(_liveness.staleMessage);
        }),
      ]);
      _liveness.recordBeat();
      return result;
    } on RpcException catch (error) {
      if (raw) rethrow;
      final Object? where = params['path'] ?? params['from'] ?? params['id'];
      _throwIo(
        error,
        '$method${where == null || '$where'.isEmpty ? '' : '（$where）'} 失败',
      );
    } on TunnelUnavailableException catch (error) {
      if (error.kind == TunnelErrorKinds.tunnelNotReady) {
        // **隧道还没好**（connecting / booting / reconnecting）——不是判死。
        //
        // 插件在"未就绪"时**根本不转发**这条请求 ⇒ 它**确定没被执行过** ⇒ 等隧道回来
        // **重发一次**是安全的（这不是"重放"：重放的定义是"已经发出去过的再发一遍"，
        // 协议 §0 红线 3 禁止的是后者）。
        //
        // 用户 2026-10-11 明确的口径：断连期间**等到退避耗尽**再如实失败，别在抖动里就报失败。
        _log?.call(
          '隧道 ${_session.connId} 暂不可用（${error.message}）⇒ 等它恢复后重发这一次请求',
        );
        await _awaitTunnelReadyElseFail();
        return _call(method, params, raw: raw);
      }
      // 其它不可用：**如实失败、不回退、不重放**。
      //
      // 判死**刻意不在这里**——判死只由两处触发：心跳快照 `snapshot.down`（退避耗尽，见 [_beat]）
      // 与"插件进程已不可用"（[_beat] 的 catch）。把判死绑在"某一次请求失败"上，
      // 正是 2026-10-11 那个"一次网络抖动就判死 + 提前回退内置"的 bug。
      throw SshLinkStaleException('中转站不可用：${error.message}');
    } finally {
      _liveness.unwatchStale(stale);
    }
  }

  Future<void> _writeChunk(
    String path,
    List<int> bytes, {
    required String mode,
  }) async {
    await _call(AgentMethods.fsWrite, <String, dynamic>{
      'path': path,
      'data': base64Encode(bytes),
      'mode': mode,
    });
  }

  Future<Map<String, dynamic>> _statOf(String path) async {
    try {
      return _asMap(
        await _call(
          AgentMethods.fsStat,
          <String, dynamic>{'path': path},
          raw: true,
        ),
      );
    } on RpcException catch (error) {
      if (error.code == TunnelErrorCodes.notFound) {
        return <String, dynamic>{'type': 'missing'};
      }
      _throwIo(error, '读取远端信息失败（$path）');
    }
  }

  Map<String, dynamic> _asMap(Object? raw) {
    if (raw is Map) {
      return raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    }
    throw WorkspaceIoException('中转站返回了非法响应（期望对象，实为 ${raw.runtimeType}）');
  }

  static Never _throwIo(RpcException error, String context) {
    throw WorkspaceIoException(
      '$context：${describeRpcCode(error.code)}（${error.message}）',
    );
  }

  /// agent 的 `stdout` / `stderr` 是 **base64 字节**（协议 §3.3：字节不丢）。
  static String _decodeBytes(Object? raw) {
    if (raw == null) return '';
    final String text = raw.toString();
    if (text.isEmpty) return '';
    try {
      return utf8.decode(base64Decode(text), allowMalformed: true);
    } catch (_) {
      return text;
    }
  }
}

/// 经中转站的远端**交互终端**通道（[SshShellChannel] 的实现）。
///
/// 数据面来自插件的 `tunnel/event` 通知（`shell.data` / `shell.exit`）——
/// agent 的 PTY 输出是**推送式**的，与文件 IO 的"拉模型"不同（终端本来就该是推的）。
class _TunnelShellChannel implements SshShellChannel {
  _TunnelShellChannel(this._session, this.shellId, this.shellName, this._log) {
    _subscription = _session.events.listen(_onEvent);
  }

  final TunnelSession _session;
  final String shellId;
  final String shellName;
  final void Function(String message)? _log;

  final StreamController<List<int>> _output =
      StreamController<List<int>>.broadcast();
  final Completer<int> _exit = Completer<int>();
  StreamSubscription<TunnelShellEvent>? _subscription;
  bool _closed = false;

  @override
  Stream<List<int>> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  String get shell => shellName;

  void _onEvent(TunnelShellEvent event) {
    if (event.shellId != shellId) return;
    switch (event.kind) {
      case TunnelEventKind.shellData:
        if (!_output.isClosed && event.data.isNotEmpty) _output.add(event.data);
      case TunnelEventKind.shellExit:
        _completeExit(event.exitCode);
      default:
        break;
    }
  }

  void _completeExit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Future<void> write(List<int> data) async {
    // 契约：会话已结束 / 写不进去**不抛**（终端输入是高频操作，抛只会刷日志）。
    if (_closed || data.isEmpty) return;
    try {
      await _session.request(AgentMethods.shellWrite, <String, dynamic>{
        'shell_id': shellId,
        'data': base64Encode(data),
      });
    } catch (error) {
      _log?.call('远端终端写入失败（忽略）：$error');
    }
  }

  @override
  Future<void> resize(int columns, int rows) async {
    if (_closed) return;
    try {
      final Object? raw = await _session.request(
        AgentMethods.shellResize,
        <String, dynamic>{
          'shell_id': shellId,
          'columns': columns,
          'rows': rows,
        },
      );
      final bool supported =
          raw is Map && raw['supported'] != false; // 缺省视为支持（老 agent）
      if (!supported) {
        // 与 POSIX PTY 后端同口径（不变量 9）：**做不到就说出来**，只记日志不抛。
        _log?.call('远端终端不支持改尺寸（agent 回报 supported=false）');
      }
    } catch (error) {
      _log?.call('远端终端改尺寸失败（忽略）：$error');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _session.request(AgentMethods.shellClose, <String, dynamic>{
        'shell_id': shellId,
      });
    } catch (error) {
      _log?.call('关闭远端终端失败（忽略）：$error');
    }
    await _subscription?.cancel();
    _subscription = null;
    // exitCode **一定收口**（拿不到退出状态给 -1，与 DartSshTransport 同口径）。
    _completeExit(-1);
    if (!_output.isClosed) await _output.close();
  }
}
