import 'dart:async';

import 'package:tree_local_exec/tree_local_exec.dart';

import 'hook_ledger.dart';
import 'tool_run_registry.dart';

/// 一个后台（hook 模式）任务。
class HookTask {
  HookTask({
    required this.id,
    required this.agentId,
    required this.sessionId,
    required this.command,
    required this.logRelative,
    required this.startedAt,
    this.background,
    this.handle,
    this.finalOutput,
    this.remoteLog = false,
    this.detached = false,
    this.note = '',
    this.run,
  });

  final String id;
  final String agentId;
  final String sessionId;
  final String command;

  /// 日志的**工作空间相对路径**（本机 = 本机工作空间；远端 = **远端**工作空间）。
  ///
  /// 日志的读/写一律经 [background]（`readTail` / `appendLog`），因此本机与远端是同一套
  /// 口径，核心只认相对路径。
  final String logRelative;

  /// 后台执行宿主（写结束标记、读日志尾部都经它）。null = 该工作空间后端不支持后台执行
  /// （退化场景：任务仍登记，日志写不进去，不假装写得进去）。
  final BackgroundExecHost? background;

  /// 后台命令句柄。null = 「会话失联后转来的」任务（没有句柄，也拿不到退出码）。
  final BackgroundExecHandle? handle;

  /// 结束前用来补写"完整输出"的取数回调（软超时采纳的进程才有；null = 没有）。
  final String Function()? finalOutput;

  /// 日志在**远端**（SSH）工作空间。
  final bool remoteLog;

  /// 「会话失联后转来的」后台任务（[TerminalHooks.adoptDetached]）。
  final bool detached;

  /// 转后台的原因（给模型看的说明）。
  final String note;

  /// 右栏「正在执行的 tool」的登记项（未接线登记表时为 null）。
  ToolRun? run;

  /// 开始时间（接续来的任务用台账里的原值）。
  final DateTime startedAt;

  /// 退出码（null = 仍在运行）。
  int? exitCode;

  /// 是否被用户/agent 主动取消（发出过终止请求）。
  bool cancelled = false;

  bool get running => exitCode == null;

  /// 命令是不是在**远端**跑（决定"能不能杀、关停杀不杀"的文案与台账）。
  bool get remote => handle?.remote ?? remoteLog;

  /// 运行时长（已结束则取结束时刻）。
  Duration get elapsed => DateTime.now().difference(startedAt);
}

/// 后台长任务管理器（terminal 的 hook 模式）。
///
/// 设计要点（2026-10-04 改造后）：
/// - **本机与远端同一套台账**：后台命令的「起 / 等它结束 / 收尾」全部委托给
///   [BackgroundExecHost]（本机 = 本机进程 + shell 重定向；远端 = `nohup` + 哨兵轮询），
///   本类只管"任务表 + 日志尾部 + 唤醒 + 落盘 + 面板登记"，**不再自己 spawn 进程**；
/// - **日志读写全走 io**（`readTail` / `appendLog`），因此远端的日志也在远端工作空间里，
///   模型 `read` 与 `hook_action=status` 看到的是同一份；
/// - **远端任务落盘**（[HookLedger]）：应用重启后由 [restorePending] 接续，结束时把
///   完成提示投递回**原会话**；
/// - **右栏可见可关**：任务登记进 [ToolRunRegistry]（`watchdog: false`：长任务不判超时；
///   `crossCall: true`：跨工具调用存活；专属 `onClose` 路由到 [cancel]）；
/// - 关停（[close]）：本机杀进程树，**远端不杀**（关应用不该杀掉远端训练），台账保留。
class TerminalHooks {
  TerminalHooks({
    this.log,
    this.maxTailChars = 4000,
    this.ledger,
    this.toolRuns,
    this.ownerOf,
  });

  /// 可读日志。
  final void Function(String message)? log;

  /// status 动作回传的日志尾部字符数。
  final int maxTailChars;

  /// 后台任务台账（null = 不落盘，测试友好）。
  final HookLedger? ledger;

  /// 运行中工具登记表（null = 不登记，面板看不到）。
  final ToolRunRegistry? toolRuns;

  /// 把 agent id 归到**会话主人**（临时员工的登记与 `.self` 分栏同一口径）。
  final String Function(String agentId)? ownerOf;

  /// 任务结束回调（用于把完成提示注入会话并唤醒 agent）。可以是异步的
  /// （远端要读一次远端日志尾部来拼提示）。
  FutureOr<void> Function(HookTask task, int exitCode)? onFinished;

  final Map<String, HookTask> _tasks = <String, HookTask>{};
  int _seq = 0;

  /// 当前在途任务数。
  int get runningCount =>
      _tasks.values.where((HookTask t) => t.running).length;

  /// 全部任务（含已结束的；自检 / status 查用）。
  List<HookTask> get tasks => List<HookTask>.unmodifiable(_tasks.values);

  /// 按 id 取任务。
  HookTask? task(String id) => _tasks[id];

  /// 启动后台任务并立即返回。
  Future<HookTask> start({
    required WorkspaceIO io,
    required String agentId,
    required String sessionId,
    required String command,
    String? outputFile,
  }) async {
    final String trimmed = command.trim();
    if (trimmed.isEmpty) {
      throw WorkspaceIoException('command 不能为空');
    }
    final BackgroundExecHost host = _hostOf(io);
    final String id = _nextId();
    final String relative = _logRelative(outputFile, id);
    // 越界路径在这里就被拒（与工具层同一条边界；本机与远端共用 `resolve` 语义）。
    io.resolve(relative);
    final BackgroundExecHandle handle = await host.startBackground(
      command: trimmed,
      logRelativePath: relative,
    );
    final HookTask task = _register(
      id: id,
      background: host,
      agentId: agentId,
      sessionId: sessionId,
      command: trimmed,
      logRelative: relative,
      handle: handle,
      remoteLog: handle.remote,
    );
    // 台账先落盘再返回：调用方（工具层）拿到 task_id 时，"这条远端任务在跑"这件事
    // 已经有据可查——否则刚起完就崩溃会丢掉它。
    await _writeLedger(task);
    _attach(task);
    log?.call(
      '后台任务已启动 $id（$trimmed）→ $relative'
      '${handle.remote ? '（远端）' : ''}',
    );
    return task;
  }

  /// 把一个**本机仍在运行**的命令转成后台任务（terminal 的软超时 → hook 模式）。
  ///
  /// 不新起进程、不重跑命令、也不丢输出：进程句柄仍在我们手上，输出订阅还活着，
  /// 退出时补写完整输出并回调 [onFinished]（唤醒 agent）。
  Future<HookTask> adoptRunning({
    required WorkspaceIO io,
    required String agentId,
    required String sessionId,
    required String command,
    required RunningLocalExec running,
    String? outputFile,
    String note = '',
  }) async {
    final String trimmed = command.trim();
    final String id = _nextId();
    final String relative = _logRelative(outputFile, id);
    io.resolve(relative);
    final BackgroundExecHost host = _hostOf(io);
    final HookTask task = _register(
      id: id,
      background: host,
      agentId: agentId,
      sessionId: sessionId,
      command: trimmed,
      logRelative: relative,
      handle: _AdoptedLocalExec(running),
      finalOutput: running.snapshotText,
      note: note,
    );
    await host.appendLog(
      relative,
      '# [terminal hook] $trimmed\n'
      '# ${note.isEmpty ? '同步执行未结束' : note} ⇒ 转后台（hook 模式）\n'
      '# **没有终止进程，也没有重跑命令**\n'
      '# adopted ${task.startedAt.toIso8601String()}  pid=${running.pid}\n'
      '# 以下是采纳时的输出快照；命令结束时会在本文件末尾补写完整输出与退出码\n\n'
      '${running.snapshotText()}\n',
    );
    _attach(task);
    log?.call('同步命令软超时转后台 $id（$trimmed）→ $relative');
    return task;
  }

  /// 把一个**仍在远端运行**的命令转成后台任务（SSH 软超时 → hook 模式）。
  ///
  /// 不终止、不重跑、也不关通道：远端那条命令照常跑完，[RunningSshExec.result] 完成时
  /// 补写输出与退出码；远端进程**不归本机管**，[cancel] 因此恒为 false（如实）。
  Future<HookTask> adoptRemote({
    required WorkspaceIO io,
    required String agentId,
    required String sessionId,
    required String command,
    required RunningSshExec running,
    String? outputFile,
    String note = '',
  }) async {
    final String trimmed = command.trim();
    final String id = _nextId();
    final String relative = _logRelative(outputFile, id);
    io.resolve(relative);
    final BackgroundExecHost host = _hostOf(io);
    final HookTask task = _register(
      id: id,
      background: host,
      agentId: agentId,
      sessionId: sessionId,
      command: trimmed,
      logRelative: relative,
      handle: _AdoptedRemoteExec(running),
      finalOutput: running.snapshotText,
      remoteLog: true,
      note: note,
    );
    await host.appendLog(
      relative,
      '# [terminal hook] $trimmed\n'
      '# ${note.isEmpty ? '远端命令软超时' : note} ⇒ 转后台（hook 模式）\n'
      '# **没有终止远端进程，也没有重跑命令**（SSH 通道也没关）\n'
      '# adopted ${task.startedAt.toIso8601String()}'
      '（远端进程不归本机管：没有 pid、杀不掉）\n'
      '# 以下是采纳时的输出快照；远端命令结束时会在本文件末尾补写完整输出与退出码\n\n'
      '${running.snapshotText()}\n',
    );
    await _writeLedger(task);
    _attach(task);
    log?.call('远端命令软超时转后台 $id（$trimmed）→ $relative');
    return task;
  }

  /// 把一个**已经不在本机等待**的命令登记为后台任务（SSH 会话失联）。
  ///
  /// 不新起进程、不重跑命令——远端那条可能还在跑，重跑会重复副作用。日志里只记录转后台
  /// 的时间、命令与原因：输出抓不回来了（执行器判失活时只是「不再等它」），所以如实写明，
  /// 不假装有日志可看。
  Future<HookTask> adoptDetached({
    required WorkspaceIO io,
    required String agentId,
    required String sessionId,
    required String command,
    required String reason,
    String? outputFile,
  }) async {
    final String trimmed = command.trim();
    final String id = _nextId();
    final String relative = _logRelative(outputFile, id);
    io.resolve(relative);
    // 会话失联是**错误处理路径**：这里绝不因为"后端不支持写日志"再抛一次错，
    // 拿不到宿主就如实记日志、任务照常登记（只是日志写不进去）。
    final BackgroundExecHost? host = _tryHostOf(io);
    final HookTask task = _register(
      id: id,
      background: host,
      agentId: agentId,
      sessionId: sessionId,
      command: trimmed,
      logRelative: relative,
      detached: true,
      remoteLog: true,
      note: reason,
    );
    if (host == null) {
      log?.call('会话失联转后台：后端不支持写远端日志，$relative 未写入');
    } else {
      await host.appendLog(
        relative,
        '# [terminal hook] 会话失联后转后台（未终止远端进程、未重跑命令）'
        '\n# command: $trimmed'
        '\n# reason: $reason'
        '\n# at ${task.startedAt.toIso8601String()}'
        '\n\n远端命令可能仍在执行；本机已不再等待它，因此拿不到它的退出码与输出。'
        '\n链路恢复后请用 terminal 重新确认远端进程与产物，不要直接重跑。\n',
      );
    }
    log?.call('会话失联：命令转后台 $id（$trimmed）→ $relative');
    return task;
  }

  /// **接续**：核心/应用重启后，把落盘台账里仍未完成的**远端**后台任务重新挂上。
  ///
  /// 语义（用户 2026-10-04 要求）：
  /// - **不重跑、不新起**：远端那条命令照常在跑，这里只重新挂"等它结束"的那条路；
  /// - 挂上后**立刻**探一次哨兵：如果它在应用不在运行时已经跑完，就马上收尾并把完成
  ///   提示**投递回原会话**（台账里的 `agent_id` + `session_id`）；
  /// - agent / 会话已不存在、或工作空间不可用 ⇒ **如实记日志**（台账保留，不再轮询），
  ///   不假装投递成功、也不静默删除。
  ///
  /// 返回"重新接上的任务数"。
  Future<int> restorePending({
    required Future<WorkspaceIO?> Function(String agentId) ioFor,
  }) async {
    final HookLedger? led = ledger;
    if (led == null) return 0;
    final List<HookLedgerEntry> entries = await led.load();
    int resumed = 0;
    for (final HookLedgerEntry entry in entries) {
      if (_tasks.containsKey(entry.id)) continue;
      WorkspaceIO? io;
      try {
        io = await ioFor(entry.agentId);
      } catch (error) {
        log?.call('接续后台任务 ${entry.id} 失败：解析工作空间异常 $error');
        continue;
      }
      if (io == null) {
        log?.call(
          '接续后台任务 ${entry.id} 失败：${entry.agentId} 的工作空间不可用'
          '（agent 已删除 / SSH 配置缺失）——台账保留，不再轮询',
        );
        continue;
      }
      final Object backend = io;
      if (backend is! BackgroundExecHost) {
        log?.call('接续后台任务 ${entry.id} 失败：该工作空间后端不支持后台执行');
        continue;
      }
      BackgroundExecHandle handle;
      try {
        handle = await backend.attachBackground(
          command: entry.command,
          logRelativePath: entry.logRelative,
          pid: entry.pid,
        );
      } catch (error) {
        log?.call('接续后台任务 ${entry.id} 失败：$error');
        continue;
      }
      final HookTask task = _register(
        id: entry.id,
        background: backend,
        agentId: entry.agentId,
        sessionId: entry.sessionId,
        command: entry.command,
        logRelative: entry.logRelative,
        handle: handle,
        remoteLog: true,
        startedAt: entry.startedAt > 0
            ? DateTime.fromMillisecondsSinceEpoch(entry.startedAt)
            : null,
      );
      _attach(task);
      resumed++;
    }
    if (resumed > 0) log?.call('已接续 $resumed 个远端后台任务');
    return resumed;
  }

  /// 取消任务（本机杀进程树 / 远端尽力 `kill`）。返回**是否确实发出了终止**。
  ///
  /// 没有句柄的任务（会话失联转来的）与拿不到远端 pid 的任务一律返回 false——
  /// **不假装杀成功**，调用方要把这个 false 如实写给模型/用户。
  Future<bool> cancel(String id) async {
    final HookTask? task = _tasks[id];
    if (task == null) return false;
    if (!task.running) return false;
    final BackgroundExecHandle? handle = task.handle;
    if (handle == null) return false;
    final bool requested = await handle.cancel();
    if (!requested) return false;
    task.cancelled = true;
    await _appendLog(
      task,
      '\n# [terminal hook] 已按显式关闭请求发出终止'
      '（${handle.remote ? '远端尽力 kill（进程/进程组）' : '本机终止进程树'}）\n',
    );
    return true;
  }

  /// 关停：本机杀进程树；**远端不杀**（只停本机轮询，台账保留待下次启动接续）。
  Future<void> close() async {
    for (final HookTask task in _tasks.values.toList()) {
      final BackgroundExecHandle? handle = task.handle;
      if (handle == null) continue;
      task.cancelled = true;
      await handle.close();
    }
    _tasks.clear();
  }

  /// status 动作的回传文本：状态 + 退出码 + 耗时 + 日志尾部。
  Future<String> renderStatus(HookTask task) async {
    final StringBuffer buffer = StringBuffer()..writeln('task_id: ${task.id}');
    final BackgroundExecHandle? handle = task.handle;
    if (task.detached) {
      // 会话失联转来的任务：远端状态本机看不到，如实说清楚，不要假装知道退出码
      buffer
        ..writeln('状态：已转后台（会话失联；远端命令可能仍在运行，本机无法确认也无法终止）')
        ..writeln('原因：${task.note}');
    } else if (task.remote) {
      buffer.writeln(
        '状态：'
        '${task.running ? '远端仍在运行（hook 后台任务：**没有终止远端进程**，本机杀不掉它）' : '已结束（退出码 ${task.exitCode}）'}'
        '｜耗时 ${task.elapsed.inSeconds}s',
      );
    } else {
      buffer.writeln(
        '状态：${task.running ? '运行中' : '已结束'}'
        // 采纳/本机起的进程：运行中也能看到 pid（出事了能自己去 taskkill）
        '${task.running && handle?.pid != null ? '（pid ${handle!.pid}）' : ''}'
        '${task.running ? '' : '（退出码 ${task.exitCode}${task.cancelled ? '，已被取消' : ''}）'}'
        '｜耗时 ${task.elapsed.inSeconds}s',
      );
    }
    buffer.writeln(
      '日志：${task.logRelative}${task.remote ? '（**远端工作空间**内的文件）' : ''}',
    );
    final String? tail = await task.background?.readTail(
      task.logRelative,
      maxTailChars,
    );
    if (tail != null && tail.trim().isNotEmpty) {
      buffer
        ..writeln('--- 日志尾部 ---')
        ..write(tail.trimRight());
    }
    return buffer.toString().trimRight();
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  static BackgroundExecHost _hostOf(WorkspaceIO io) {
    final Object target = io;
    if (target is BackgroundExecHost) return target;
    throw WorkspaceIoException('该工作空间后端不支持后台执行（terminal 的 hook 模式）');
  }

  /// 取后台执行宿主；不支持时返回 null（调用方负责如实记日志，不阻断当前流程）。
  static BackgroundExecHost? _tryHostOf(WorkspaceIO io) {
    final Object target = io;
    return target is BackgroundExecHost ? target : null;
  }

  String _nextId() {
    _seq++;
    return 'hook_${DateTime.now().millisecondsSinceEpoch}_$_seq';
  }

  static String _logRelative(String? outputFile, String id) =>
      (outputFile == null || outputFile.trim().isEmpty)
      ? '.output/$id.log'
      : outputFile.trim();

  HookTask _register({
    required String id,
    required BackgroundExecHost? background,
    required String agentId,
    required String sessionId,
    required String command,
    required String logRelative,
    BackgroundExecHandle? handle,
    String Function()? finalOutput,
    bool remoteLog = false,
    bool detached = false,
    String note = '',
    DateTime? startedAt,
  }) {
    final HookTask task = HookTask(
      id: id,
      agentId: agentId,
      sessionId: sessionId,
      command: command,
      logRelative: logRelative,
      startedAt: startedAt ?? DateTime.now(),
      background: background,
      handle: handle,
      finalOutput: finalOutput,
      remoteLog: remoteLog,
      detached: detached,
      note: note,
    );
    _tasks[id] = task;
    // 右栏「正在执行的 tool」：后台 hook 是**长任务**（不判超时、不刷 warning），
    // 但要让人看得见、关得掉——关闭路由到本类的 [cancel]。
    final ToolRunRegistry? registry = toolRuns;
    if (registry != null) {
      task.run = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': command, 'hook': true},
        agentId: ownerOf?.call(agentId) ?? agentId,
        sessionId: sessionId,
        watchdog: false,
        crossCall: true,
        onClose: () async {
          final bool ok = await cancel(id);
          return ok
              ? '${task.remote ? '已请求终止远端后台命令（尽力 kill）' : '已终止本机后台进程树'}'
                    '（task_id=$id）'
              : '无法终止：${cancelRefusal(task)}';
        },
      );
    }
    return task;
  }

  void _attach(HookTask task) {
    final BackgroundExecHandle? handle = task.handle;
    if (handle == null) return;
    unawaited(
      handle.exitCode.then(
        (int code) => _finish(task, code),
        onError: (Object error) => _fail(task, error),
      ),
    );
  }

  Future<void> _writeLedger(HookTask task) async {
    final HookLedger? led = ledger;
    if (led == null || !task.remote) return;
    await led.save(
      HookLedgerEntry(
        id: task.id,
        agentId: task.agentId,
        sessionId: task.sessionId,
        command: task.command,
        logRelative: task.logRelative,
        pid: task.handle?.pid,
        startedAt: task.startedAt.millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _appendLog(HookTask task, String text) async {
    final BackgroundExecHost? host = task.background;
    if (host == null) return;
    try {
      await host.appendLog(task.logRelative, text);
    } catch (error) {
      log?.call('写 hook 结束标记失败：$error');
    }
  }

  Future<void> _finish(HookTask task, int code) async {
    task.exitCode = code;
    final String? full = task.finalOutput?.call();
    if (full != null && full.trim().isNotEmpty) {
      await _appendLog(task, '\n# （完整输出）\n$full\n');
    }
    await _appendLog(
      task,
      '\n# [terminal hook] 结束：退出码 $code'
      '${task.cancelled ? '（已取消）' : ''}，耗时 ${task.elapsed.inSeconds}s\n',
    );
    await _settle(task);
    log?.call(
      '后台任务结束 ${task.id}：exit=$code elapsed=${task.elapsed.inSeconds}s',
    );
    // 回调放在日志尾部写完之后：消费方（唤醒 agent）读日志尾部时能看到结束标记。
    await onFinished?.call(task, code);
  }

  /// 结束时的收尾（登记表 + 台账）。**任务本身留在 `_tasks` 里**（status 还能查到）。
  Future<void> _settle(HookTask task) async {
    final ToolRun? run = task.run;
    if (run != null) toolRuns?.finish(run);
    // 已收尾的远端任务不再需要接续 ⇒ 删台账（本机任务本来就没有台账）。
    if (task.remote) await ledger?.remove(task.id);
  }

  /// 链路判失活等"拿不到退出码"的收场：**如实**记一个可辨退出码，不假装正常结束。
  Future<void> _fail(HookTask task, Object error) async {
    task.exitCode = remoteFailureExitCode;
    await _appendLog(
      task,
      '\n# [terminal hook] 链路判失活，拿不到退出码与输出：$error\n',
    );
    await _settle(task);
    log?.call('后台任务失联 ${task.id}：$error');
    await onFinished?.call(task, remoteFailureExitCode);
  }

  /// 远端链路失活时的"退出码"（负值：真实退出码不会是它）。
  static const int remoteFailureExitCode = -1;
}

/// 为什么这条任务杀不掉（给模型/用户的可读原因）。纯函数，便于单测。
String cancelRefusal(HookTask task) {
  if (task.detached) {
    return '该任务是会话失联后转的后台任务，本机没有进程句柄，无法终止（远端进程可能仍在运行）。';
  }
  if (task.handle == null) return '该任务没有可终止的句柄，无法终止。';
  if (task.remote) {
    return '该任务是远端后台命令：没有拿到远端 pid（远端进程不归本机管），无法终止；'
        '请用 terminal 复查远端进程与产物。';
  }
  return '没有可供终止的进程句柄，无法终止。';
}

/// 组装「后台任务完成」提示（注入会话并唤醒 agent）。
///
/// 异步：日志尾部可能要从**远端**读（`io.readTail` 走 SFTP）。
Future<String> hookNotice(HookTask task, int exitCode) async {
  final StringBuffer buffer = StringBuffer()
    ..writeln('[terminal hook] 后台命令已结束：${task.command}')
    ..writeln(
      'task_id: ${task.id}｜退出码 $exitCode'
      '${task.cancelled ? '（已按关闭请求终止）' : ''}',
    );
  if (exitCode == BackgroundExecHandle.goneExitCode) {
    buffer.writeln(
      '（远端进程已消失，但没有留下退出码：可能被强制终止或远端重启过——'
      '请复查产物，不要直接重跑）',
    );
  } else if (exitCode == TerminalHooks.remoteFailureExitCode) {
    buffer.writeln(
      '（链路判失活，没拿到远端退出码与输出——请重新确认远端进程与产物，不要直接重跑）',
    );
  }
  buffer.writeln(
    '日志文件：${task.logRelative}（用 read 查看完整输出）'
    '${task.remote ? '｜注意：这是**远端工作空间**里的文件' : ''}',
  );
  final String? tail = await task.background?.readTail(task.logRelative, 1500);
  if (tail != null && tail.trim().isNotEmpty) {
    buffer
      ..writeln('--- 日志尾部 ---')
      ..write(tail.trimRight());
  }
  return buffer.toString().trimRight();
}

/// 本机软超时采纳的进程（[RunningLocalExec]）→ [BackgroundExecHandle]。
///
/// 与 [LocalWorkspaceIO] 自己起的后台进程是**同一套对外语义**：pid 拿得到、退出码实时、
/// [cancel] 杀整棵进程树。
class _AdoptedLocalExec implements BackgroundExecHandle {
  _AdoptedLocalExec(this.running);

  final RunningLocalExec running;

  @override
  int? get pid => running.pid;

  @override
  bool get remote => false;

  @override
  Future<int> get exitCode => running.exitCode;

  @override
  Future<bool> cancel() async {
    await Shell.killProcessTree(running.pid);
    return true;
  }

  @override
  Future<void> close() => Shell.killProcessTree(running.pid);
}

/// 远端软超时采纳的命令（[RunningSshExec]）→ [BackgroundExecHandle]。
///
/// 远端进程不归本机管：没有 pid、也杀不掉（[cancel] 如实返回 false）；输出与退出码等
/// [RunningSshExec.result] 一次性回来。
class _AdoptedRemoteExec implements BackgroundExecHandle {
  _AdoptedRemoteExec(this.running);

  final RunningSshExec running;

  @override
  int? get pid => null;

  @override
  bool get remote => true;

  @override
  Future<int> get exitCode => running.result.then(
    (SshExecResult result) => result.exitCode,
  );

  @override
  Future<bool> cancel() async => false;

  @override
  Future<void> close() async {}
}
