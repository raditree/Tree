import 'dart:async';
import 'dart:convert';
import 'dart:math';

/// 发一条"工具运行超阈值"warning 的落点（会话 `llm_hidden` 提示）。
///
/// 实现方（核心）拿到的是**可读中文文案**，落库口径与 `conversation_service.dart` 的
/// `_sendNotice(..., llmHidden: true)` **完全一致**（`messages.jsonl` 键集不变）。
typedef ToolRunNotice =
    void Function(String agentId, String sessionId, String text);

/// 广播站点位 `system.tool.timeout` 的落点（超阈值时**只发一次**）。
///
/// 载荷 = [ToolRun.timeoutPayload]（冻结键：`handle` / `agent_id` / `session_id` /
/// `tool` / `command` / `elapsed_ms` / `started_at`）；广播站实现方会再补一个
/// `point`（与其它广播载荷同口径）。
typedef ToolRunBroadcast = void Function(Map<String, dynamic> payload);

/// 关闭一次运行时的**进程树终止**落点：返回可读说明（空串 = 由登记表给默认说明）。
///
/// 落点由接线方注入（生产 = 工具层：有本机进程句柄时 `taskkill /T`，见
/// [WorkspaceToolRunner.terminateToolRun]）；**未接线 = 不假装杀成功**，登记表只从
/// 表里移除并把"命令可能仍在跑"如实写进 note。
typedef ToolRunTerminator = Future<String> Function(ToolRun run);

/// 一次**正在执行的工具**的登记项（纯内存，**不跨核心重启存活**）。
///
/// 字段口径（冻结，见 plan §10 D1~D5）：
/// - [handle]：`toolrun_<ms>_<rand>_<n>`——显式句柄是**终止在途工具的唯一路径**
///   （右栏"关闭"按钮 / 执行站 `tool.close`）；停止键/打断的语义一个字都没改；
/// - [command]：命令摘要（单行、去换行、最多 [commandSummaryChars] 字符）；
/// - [startedAt] / [elapsedMs]：epoch 毫秒（与 `messages.jsonl` 的时间戳同口径）。
class ToolRun {
  ToolRun({
    required this.handle,
    required this.tool,
    required this.agentId,
    required this.sessionId,
    required this.command,
    required this.startedAt,
    required this.now,
  });

  /// 命令摘要的字符上限（落进 warning / 广播 / `stuck_tools` 的那一份）。
  static const int commandSummaryChars = 400;

  /// 面板预览的字符上限（REST `command_preview`）。
  static const int commandPreviewChars = 160;

  /// 句柄（`toolrun_<ms>_<rand>_<n>`）。
  final String handle;

  /// 工具名（内置工具名 / `plugin__<id>__<tool>` / `mcp__<服务>__<tool>`）。
  final String tool;

  /// 会话主人 agent id（临时员工跑在发起者会话上，这里就是发起者）。
  final String agentId;

  /// 会话 id。
  final String sessionId;

  /// 命令摘要（terminal = 命令本身；其余工具 = 参数 JSON 摘要，敏感键已打码）。
  final String command;

  /// 开始时间（epoch 毫秒）。
  final int startedAt;

  /// 毫秒时钟（由登记表注入：测试可以给假时钟，`elapsed_ms` 因此可确定性地断言）。
  final int Function() now;

  /// 超阈值 warning 是否已发（**每次运行只发一次**）。
  bool warned = false;

  /// 是否已收尾（收尾后不再登记）。
  bool finished = false;

  /// 超阈值计时器（登记表拥有；`finish` / `shutdown` 会取消它）。
  Timer? warnTimer;

  /// 本机进程 pid（**拿得到时**才登记；本地 `taskkill /T` 的目标）。
  ///
  /// 现在几乎恒为 null：本机同步执行的进程句柄由执行器（`LocalWorkspaceIO.exec`）
  /// 持有，核心这一层看不到；这是"执行器把 pid 交出来"时的接缝（远端则由 SSH 侧
  /// 的软超时/取消接缝负责，见 `tree_local_exec`）。
  int? pid;

  final Completer<String> _closed = Completer<String>();

  /// 运行时长（毫秒；时钟由登记表注入，测试可注入假时钟）。
  int get elapsedMs {
    final int delta = now() - startedAt;
    return delta < 0 ? 0 : delta;
  }

  /// 运行时长（秒，warning 文案用）。
  int get elapsedSeconds => elapsedMs ~/ 1000;

  /// 是否已超过 [threshold]（REST / `stuck_tools` 的 `over_threshold` 口径）。
  bool overThreshold(Duration threshold) =>
      elapsedMs >= threshold.inMilliseconds;

  /// **显式关闭请求**：完成后第一次工具调用的「收敛」路径生效（见
  /// [WorkspaceToolRunner] 的 `_execute`）——关闭 = 让这次调用交回控制权，
  /// 而不是偷偷改掉停止/打断的语义。
  Future<String> get closeRequested => _closed.future;

  /// 是否已收到显式关闭请求。
  bool get isCloseRequested => _closed.isCompleted;

  String _closeNote = '';

  /// 关闭说明（终止进程树的结论；未关闭时为空串）。
  String get closeNote => _closeNote;

  /// 登记表的关闭落点：记录说明并让在途调用收敛（幂等）。
  void requestClose(String note) {
    if (_closeNote.isEmpty) _closeNote = note;
    if (!_closed.isCompleted) _closed.complete(_closeNote);
  }

  /// 这次调用在"被显式关闭"时应回给模型的那段结果文本。
  String get closedOutcomeText {
    final String note = _closeNote.trim();
    return '【已按显式关闭请求终止】工具 $tool（handle=$handle）已运行 '
        '${elapsedSeconds}s 后被关闭：${note.isEmpty ? '（无说明）' : note}\n'
        '这次调用到此收敛（**不再等待它返回**）：命令若仍在跑，请用 terminal/hook '
        '复查进程与产物，不要直接重跑。';
  }

  /// REST 快照项（`GET /api/tools/running` 的 `runs[]`；冻结字段）。
  Map<String, dynamic> toJson({required Duration threshold}) => <String, dynamic>{
    'handle': handle,
    'agent_id': agentId,
    'session_id': sessionId,
    'tool': tool,
    'command_preview': _preview(command),
    'started_at': startedAt,
    'elapsed_ms': elapsedMs,
    'over_threshold': overThreshold(threshold),
  };

  /// 广播站点位 `system.tool.timeout` 的载荷（冻结键；"point" 由广播站补）。
  Map<String, dynamic> get timeoutPayload => <String, dynamic>{
    'handle': handle,
    'agent_id': agentId,
    'session_id': sessionId,
    'tool': tool,
    'command': command,
    'elapsed_ms': elapsedMs,
    'started_at': startedAt,
  };

  /// `query_status.stuck_tools[]` 项（冻结字段：只含 `over_threshold` 的运行）。
  Map<String, dynamic> stuckJson() => <String, dynamic>{
    'handle': handle,
    'tool': tool,
    'elapsed_ms': elapsedMs,
    'command': command,
    'hint': stuckHint(),
  };

  /// **防呆风险提示**（`stuck_tools[].hint`）：告诉对方"这条命令为什么会卡、怎么收手"。
  String stuckHint() => stuckToolHint(this);

  /// 面板预览（单行、截断）。
  static String _preview(String text) {
    final String single = singleLine(text);
    return single.length <= commandPreviewChars
        ? single
        : '${single.substring(0, commandPreviewChars)}…';
  }
}

/// `stuck_tools[].hint` 的**防呆风险提示**（纯函数，便于单测）。
String stuckToolHint(ToolRun run) {
  final String command = run.command.toLowerCase();
  final String closeWith = 'tool.close（args: {"handle": "${run.handle}"}）';
  // 全根扫描类（现场事故就是它：`find /mnt/space …` 在 25GB 树上永不返回）
  if (RegExp(r'(^|[\s;&|(])(find|du)\s').hasMatch(command)) {
    return '该命令疑似全根扫描（find / du）：确认范围或用 -maxdepth / timeout 限定；'
        '关闭请用 $closeWith';
  }
  if (RegExp(r'(^|[\s;&|(])(grep|rg|ripgrep)\s.*\s-r').hasMatch(command) ||
      command.contains(' -r ')) {
    return '该命令疑似递归检索：确认范围（先判断目录规模）；关闭请用 $closeWith';
  }
  return '该工具已运行 ${run.elapsedSeconds}s 未返回：确认它是否仍在跑'
      '（terminal 可用 hook_action=status 查后台任务）；关闭请用 $closeWith';
}

/// 把命令 / 参数压成一行的摘要（纯函数，便于单测）。
///
/// - `terminal`：取 `command` 参数本身；
/// - 其余工具：参数 JSON 摘要（`password` / `token` / `api_key` 一类键打码，见
///   核心不变量「密钥不进日志/帧」）；
/// - 全部去换行 + 截断到 [ToolRun.commandSummaryChars]。
String summarizeToolCommand(String tool, Map<String, dynamic>? arguments) {
  final Map<String, dynamic> args = arguments ?? const <String, dynamic>{};
  String raw;
  if (tool == 'terminal') {
    raw = (args['command'] ?? '').toString();
    if (raw.trim().isEmpty) raw = '（terminal 未给 command）';
  } else if (args.isEmpty) {
    raw = '（无参数）';
  } else {
    raw = _encodeMasked(args);
  }
  final String single = singleLine(raw);
  return single.length <= ToolRun.commandSummaryChars
      ? single
      : '${single.substring(0, ToolRun.commandSummaryChars)}…';
}

/// 去掉换行与多余空白（warning / 广播 / 面板都是一行）。
String singleLine(String text) =>
    text.replaceAll(RegExp(r'\s+'), ' ').trim();

String _encodeMasked(Map<String, dynamic> args) {
  try {
    return jsonEncode(_masked(args));
  } catch (error) {
    // 参数里有不可 JSON 化的值（函数 / 循环引用）：如实退化成 toString，
    // 但不能因为"摘要发不出去"影响工具本身。
    return args.toString();
  }
}

/// 敏感键打码（只影响**摘要**，不影响工具收到的参数）。
Map<String, dynamic> _masked(Map<String, dynamic> source) {
  final Map<String, dynamic> out = <String, dynamic>{};
  for (final MapEntry<String, dynamic> entry in source.entries) {
    final String key = entry.key;
    if (_secretKey.hasMatch(key)) {
      out[key] = '***';
      continue;
    }
    final Object? value = entry.value;
    if (value is Map) {
      out[key] = _masked(
        value.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
      );
      continue;
    }
    out[key] = value;
  }
  return out;
}

final RegExp _secretKey = RegExp(
  r'(password|passwd|secret|token|api_?key|authorization|credential)',
  caseSensitive: false,
);

/// 一次 `tool.close`（显式关闭）的结论。
class ToolCloseOutcome {
  const ToolCloseOutcome._({
    required this.closed,
    required this.tool,
    required this.elapsedMs,
    required this.note,
  });

  /// 句柄失效（核心重启过，或这次运行早已结束）：**可读原因**，不假装成功。
  factory ToolCloseOutcome.missing(String handle) => ToolCloseOutcome._(
    closed: false,
    tool: '',
    elapsedMs: 0,
    note:
        '该句柄已失效（${handle.isEmpty ? '未给 handle' : handle}）：'
        '登记表是**纯内存**的——核心重启会清空它，这次运行结束（工具返回）后句柄同样失效。'
        '当前在跑的运行请用 GET /api/tools/running 重新取 handle。',
  );

  /// 是否真的收到了关闭请求并已从登记表移除。
  final bool closed;

  /// 被关闭的工具名（句柄失效时为空串）。
  final String tool;

  /// 关闭时的已运行时长（毫秒）。
  final int elapsedMs;

  /// 可读说明（含"进程是否真的被终止"的如实结论）。
  final String note;

  /// 执行站 `tool.close` 的返回载荷（冻结字段 `closed` / `tool` / `elapsed_ms` / `note`）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'closed': closed,
    'tool': tool,
    'elapsed_ms': elapsedMs,
    'note': note,
  };
}

/// **运行中工具登记表**（内存）：核心侧"工具卡住"的四层可见 + 两个干预点的地基。
///
/// 为什么需要它：工具**没有静态上限**（本地活性 = 进程存活，SSH 侧活性 = 心跳），
/// 一条不返回的命令会让整个工具批永不结束，而引擎把"批中途到来的用户消息"推迟到批
/// 结束之后（见 `.self/recon-arch-stability.md` §2.7）⇒ teammate 永久失联且无日志。
/// 登记表把"正在跑什么、跑了多久、怎么收手"变成**可观测 + 可显式干预**：
///
/// 1. 挂载点：`WorkspaceToolRunner._execute`——内置工具、`plugin__*`、`mcp__*`、
///    站内 `tool.call`（`runFromPlugin`）**走的是同一个入口**，所以一处挂载全覆盖；
/// 2. warning：超过 [threshold]（默认 **300 s**、可配）**每次运行只发一次**——
///    会话 `llm_hidden` 一条 + `core.log` 一行；
/// 3. REST：`snapshot()` 给右栏（只读）；
/// 4. 广播站：超阈值时 `onTimeout` 一次（点位 `system.tool.timeout`）；
/// 5. 显式关闭：`close(handle)`——先尽力终止进程树（[terminate] 落点），再把这次运行
///    从登记表移除，并让在途调用**收敛**（回一段可读结果）。**不自动杀**：超时只
///    warning，关闭必须显式（避免误杀长任务）。
///
/// **不跨进程重启存活**：纯内存；旧句柄一律回"该句柄已失效"。
class ToolRunRegistry {
  ToolRunRegistry({
    Duration? threshold,
    this.log,
    this.notice,
    this.onTimeout,
    this.terminate,
    int Function()? now,
  }) : threshold = threshold ?? defaultThreshold,
       _now = now ?? _systemNow;

  /// 默认阈值：**300 s**（用户 2026-10-03 定夺：与 terminal 的缺省软超时同值——
  /// 于是"warning / `stuck_tools` / 转后台 hook"三件事在同一秒数上一起发生，
  /// 不再出现"120 s 报卡住、300 s 才真的转后台"这种两个口径）。
  static const Duration defaultThreshold = Duration(seconds: 300);

  /// 进程级唯一登记表（核心只有一份"正在执行的工具"）。
  ///
  /// 为什么用全局实例而不是让组合根注入：`core_server.dart` 只能看到引擎手上的
  /// `WorkspaceToolRunner`，而 `TeamService` / REST 面都需要同一份表；全局实例让
  /// "谁都能读同一份真值"，测试仍可显式注入自己的实例。
  static final ToolRunRegistry instance = ToolRunRegistry();

  /// 超阈值（可配：构造时给，或 [attach] 运行期改）。
  Duration threshold;

  /// 可读日志（生产接到 `core.log`）。
  void Function(String message)? log;

  /// 超阈值 warning 的会话落点（一次运行只发一次）。
  ToolRunNotice? notice;

  /// 广播站点位 `system.tool.timeout` 的落点（一次运行只发一次）。
  ToolRunBroadcast? onTimeout;

  /// 进程树终止落点（未接线 = 只移除登记项，并如实说明）。
  ToolRunTerminator? terminate;

  final int Function() _now;
  final Map<String, ToolRun> _runs = <String, ToolRun>{};
  final Random _random = Random();
  int _seq = 0;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  /// 运行期接线（幂等；传 null 的字段保持不变）。
  void attach({
    Duration? threshold,
    void Function(String message)? log,
    ToolRunNotice? notice,
    ToolRunBroadcast? onTimeout,
    ToolRunTerminator? terminate,
  }) {
    if (threshold != null) this.threshold = threshold;
    if (log != null) this.log = log;
    if (notice != null) this.notice = notice;
    if (onTimeout != null) this.onTimeout = onTimeout;
    if (terminate != null) this.terminate = terminate;
  }

  /// 当前在途运行数。
  int get length => _runs.length;

  /// 开始一次运行并登记（句柄 `toolrun_<ms>_<rand>_<n>`）。
  ///
  /// 调用方**必须**在结束时 `finish(handle)`（工具层放在 `finally` 里）；登记项泄漏
  /// 会显示成一个假的"正在执行的工具"。
  ToolRun start({
    required String tool,
    Map<String, dynamic>? arguments,
    required String agentId,
    required String sessionId,
  }) {
    _seq++;
    final int startedAt = _now();
    final ToolRun run = ToolRun(
      handle: 'toolrun_${startedAt}_${_randSuffix()}_$_seq',
      tool: tool,
      agentId: agentId,
      sessionId: sessionId,
      command: summarizeToolCommand(tool, arguments),
      startedAt: startedAt,
      now: _now,
    );
    _runs[run.handle] = run;
    final Duration limit = threshold;
    if (limit > Duration.zero) {
      run.warnTimer = Timer(limit, () => _warnIfNeeded(run));
    }
    return run;
  }

  /// 收尾（幂等）：取消计时器并从登记表移除。
  void finish(Object runOrHandle) {
    final ToolRun? run = runOrHandle is ToolRun
        ? runOrHandle
        : (runOrHandle is String ? _runs[runOrHandle.trim()] : null);
    if (run == null) return;
    run.finished = true;
    run.warnTimer?.cancel();
    run.warnTimer = null;
    _runs.remove(run.handle);
  }

  /// 全部在途运行（按开始顺序；副本，调用方改不了登记表）。
  List<ToolRun> list() => List<ToolRun>.unmodifiable(_runs.values);

  /// **只含 `over_threshold` 的在途运行**（`query_status.stuck_tools` 的数据源）。
  List<ToolRun> stuck() =>
      _runs.values.where((ToolRun r) => r.overThreshold(threshold)).toList(
        growable: false,
      );

  /// 某 agent 的 `over_threshold` 运行（`query_status` 按被查成员过滤）。
  List<ToolRun> stuckFor(String agentId) => _runs.values
      .where((ToolRun r) => r.agentId == agentId && r.overThreshold(threshold))
      .toList(growable: false);

  /// REST 只读快照体（`GET /api/tools/running`）。
  Map<String, dynamic> snapshot() => <String, dynamic>{
    'runs': <Map<String, dynamic>>[
      for (final ToolRun run in _runs.values)
        run.toJson(threshold: threshold),
    ],
  };

  /// 超阈值检查（生产由每个运行的计时器触发；测试可直接调用以断言"只发一次"）。
  void checkTimeouts() {
    for (final ToolRun run in _runs.values.toList()) {
      if (run.overThreshold(threshold)) _warnIfNeeded(run);
    }
  }

  /// **显式关闭**一次运行：先尽力终止进程树，再把这次运行从登记表移除，并让在途工具
  /// 调用收敛（右栏"关闭"按钮与执行站 `tool.close` 走**同一个**实现）。
  ///
  /// 句柄失效（不存在 / 核心重启过 / 运行已结束）⇒ `closed: false` + 可读原因。
  Future<ToolCloseOutcome> close(String handle) async {
    final String key = handle.trim();
    final ToolRun? run = _runs[key];
    if (run == null) return ToolCloseOutcome.missing(key);
    final int elapsed = run.elapsedMs;
    String note = '';
    final ToolRunTerminator? killer = terminate;
    if (killer == null) {
      note = '未接线进程终止器：只从登记表移除了这次运行，命令可能仍在跑';
    } else {
      try {
        note = (await killer(run)).trim();
      } catch (error) {
        note = '终止进程树时异常：$error';
      }
    }
    if (note.isEmpty) note = '已从登记表移除这次运行（命令可能仍在跑）';
    run.requestClose(note);
    finish(run);
    log?.call(
      '显式关闭工具运行 ${run.handle}（${run.tool}，已运行 ${elapsed}ms）：$note',
    );
    return ToolCloseOutcome._(
      closed: true,
      tool: run.tool,
      elapsedMs: elapsed,
      note: note,
    );
  }

  /// 关停：取消全部计时器并清空（核心退出前调用，别让待发 warning 的计时器吊住进程）。
  ///
  /// 不假装"杀掉了进程"——进程终止是 [terminate] 落点的事（关停路径由工具层自己的
  /// `close()` 负责，见 `TerminalHooks.close`）。
  void shutdown() {
    for (final ToolRun run in _runs.values) {
      run.warnTimer?.cancel();
      run.warnTimer = null;
    }
    _runs.clear();
  }

  void _warnIfNeeded(ToolRun run) {
    if (run.finished || run.warned) return;
    if (!run.overThreshold(threshold)) return;
    run.warned = true;
    final int seconds = run.elapsedSeconds;
    log?.call(
      '工具运行超阈值：${run.tool} 已运行 ${seconds}s（handle=${run.handle}，'
      'agent=${run.agentId}，session=${run.sessionId}）',
    );
    final ToolRunNotice? noticeSink = notice;
    if (noticeSink != null) {
      final String text =
          '工具 ${run.tool} 已运行 $seconds 秒仍未结束。命令：${run.command}\n'
          '可在右栏「正在执行的 tool」关闭（handle=${run.handle}）。';
      try {
        noticeSink(run.agentId, run.sessionId, text);
      } catch (error) {
        log?.call('工具运行 warning 落会话失败（已忽略）：$error');
      }
    }
    final ToolRunBroadcast? busSink = onTimeout;
    if (busSink != null) {
      try {
        busSink(run.timeoutPayload);
      } catch (error) {
        log?.call('工具超时广播失败（已忽略）：$error');
      }
    }
  }

  String _randSuffix() {
    const String alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 4; i++) {
      buffer.write(alphabet[_random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }
}
