import 'dart:async';

import 'package:tree_local_exec/tree_local_exec.dart';

import '../store/tree_store.dart';
import '../tool/builtin_tools.dart';
import '../tool/terminal_hooks.dart';
import '../tool/tool_runner.dart';
import 'station_instance.dart';
import 'station_points.dart';
import 'station_runtime.dart';
import 'station_scope.dart';

/// 工作空间 IO 解析器（按 agent）：local / ssh **都走既有的 [WorkspaceIO] 抽象**
/// （本地 = `LocalWorkspaceIO`，SSH = `SshWorkspaceIO`），挂载位置因此只有一份实现。
typedef StationWorkspaceIoResolver = Future<WorkspaceIO?> Function(
  String agentId,
);

/// 目标 agent 的团队归属（隔离校验用；不存在/无归属返回空串）。
typedef StationAgentTeamResolver = String Function(String agentId);

/// 目标 agent 的**工作空间模式**（local | ssh）。
typedef StationAgentModeResolver = String Function(String agentId);

/// `agent.message` 的投递入口（团队派发 / 会话投递）。
typedef StationAgentMessageSender = Future<Map<String, dynamic>> Function({
  required String agentId,
  required String sessionId,
  required String content,
  String sourcePluginId,
});

/// `agent.stop` 的停止入口（[cascade] = 连同下级子树一起停）。
typedef StationAgentStopper = Future<Map<String, dynamic>> Function(
  String agentId, {
  required bool cascade,
});

/// `agent.compact` 的**手动压缩**入口。
typedef StationAgentCompactor = Future<Map<String, dynamic>> Function(
  String agentId,
  String sessionId,
);

/// `llm.call` 的**一次 LLM 调用**入口（点位化新增）。
///
/// 语义（用户定稿）：**站点处硬设 API 返回形式为 JSON**（`response_format =
/// {"type":"json_object"}`），模型**复用目标 agent 解析出的模型**（成员级覆盖也
/// 生效）；用于"让插件对数据做高级处理"。
///
/// [model] 非空 = 显式覆盖该 agent 的模型（默认不给）。
/// [tools] = OpenAI 形状的工具声明数组，**原样透传**进请求体：压缩插件要复用
/// "与对话同一条前缀"就必须带上同一份 tools（工具定义在聊天模板里渲染在 messages
/// 之前，缺了它前缀从第一个 token 就对不上）。
/// [sessionId] = 这次调用**记在哪个会话名下**（逐调用用量账本按会话分文件；压缩插件
/// 的 `llm.call` 就是在给某个会话做压缩）。与 [StationToolCaller] 的口径一致。
/// 返回 `{ok, json, text, model, usage}` 或 `{error}`（端点不支持 JSON 形式时
/// **如实失败**，不静默去掉 response_format 重试）。
///
/// [responseFormat]（2026-10-04 新增）：`null` / `'json_object'` = 站点缺省的
/// **硬设 JSON 返回形式**（语义与新增前逐字一致）；`'text'` = **不发** `response_format`
/// ——为的是让这次调用的提示词与对话那一轮**逐字一致**从而吃到端点前缀缓存
/// （实测：只加 `{"type":"json_object"}` 就会让端点改写提示词，同一 492 token 前缀的
/// 命中从 384/256 掉到 **0**；见 docs/known-issues.md #27）。
typedef StationLlmCaller = Future<Map<String, dynamic>> Function({
  required String agentId,
  required String sessionId,
  List<Object?>? messages,
  String? prompt,
  String? system,
  String? model,
  double? temperature,
  int? maxTokens,
  List<Object?>? tools,
  String? responseFormat,
});

/// `tool.call` 的**执行任意工具**入口（点位化新增）。
///
/// 走工具层的唯一入口（内置 / MCP / 插件工具统一分派），因此与模型调用工具**同一条
/// 路径、同一份权限**（本仓库没有工具审批层，插件与 agent 同权）。
typedef StationToolCaller = Future<ToolOutcome> Function({
  required String agentId,
  required String sessionId,
  required String tool,
  required Map<String, dynamic> arguments,
  required String sourcePluginId,
  required bool relay,
});

/// `session.rename` 的会话重命名入口（与 REST `PATCH …/sessions/{id}` 同一实现）。
typedef StationSessionRenamer = Future<Map<String, dynamic>> Function({
  required String agentId,
  required String sessionId,
  required String title,
});

/// `tool.close` 的**关闭一次运行中的工具**入口（核心注入；与右栏"关闭"按钮、
/// ToolRunRegistry.close 是同一个实现）。
typedef StationToolCloser = Future<Map<String, dynamic>> Function(
  String handle,
);

/// `ssh.reconnect` 的**重建远端（SSH）链路**入口（核心注入；与 REST
/// `POST /api/agents/{id}/ssh/reconnect`、右栏文件面板「重连」按钮同一实现）。
///
/// [agentId] 是**已解析好的目标 agentId**（`_resolveTarget` 四元组隔离之后的值）。
/// 实现须**如实**表达三种结局（成功 / 该 agent 不是 SSH / 重建失败），不静默降级。
typedef StationSshReconnector = Future<Map<String, dynamic>> Function(
  String agentId,
);

/// `plugin.*` 族的**统一入口**（2026-10-15 插件热重启）：由 `PluginBus` 实现。
///
/// 为什么只给一个入口而不是六条各一个槽：这一族的六条命令共享同一套归属口径
/// （见 [_pluginCommand]），拆成六个参数只会把「谁能动谁的快照」这条判定复制六遍。
///
/// [command] 是命令名（`plugin.list` / `plugin.restart` / `plugin.suspend` /
/// `plugin.state` / `plugin.stateDump` / `plugin.stateFetch`）；
/// [pluginId] 是**已在本层归一化过**的目标插件 id（快照两条 = 发起者自己的 id）；
/// [sourcePluginId] 是下达这条命令的插件 id（空 = 核心自己下的）——实现方据此
/// 钉住「插件只能动自己的快照」；[arguments] 是原始参数（原样透传，不预先消化）。
///
/// 返回值约定与其它槽一致：`{ok: true, ...结论}` 或 `{ok: false, error: 可读中文}`。
/// **不做静默降级**：没接线时本层直接以「未接线」失败（口径见类注释第 15 条）。
typedef StationPluginManager = Future<Map<String, dynamic>> Function({
  required String command,
  required String pluginId,
  required String sourcePluginId,
  Map<String, dynamic>? arguments,
});

/// `station.*` 族的**统一入口**（20261015-hot-restart 阶段 6）：由 `PluginBus` 实现。
///
/// 这一族的实现只能是总线：站点实例表、订阅者、公告板与计数都在它那里，挂载位置层
/// 因此**不拿任何站点状态**，只负责「能不能证明发起者属于这个 team」这一道闸门。
///
/// [teamId] 是**已经在这里证明过**的发起者 team（空串到不了实现）；`station.state`
/// 的目标写在 [arguments] 的 `station_id`（也接受订阅时那套 `point` 别名）。
typedef StationTopologyQuery = Future<Map<String, dynamic>> Function({
  required String command,
  required String teamId,
  Map<String, dynamic>? arguments,
  String sourcePluginId,
});

/// `usage.query` 的**逐调用用量账本**读口（20261015-hot-restart 阶段 6）：由核心实现。
///
/// 为什么这一条不写在挂载位置里：账本落在**数据根**下的会话目录
/// （`<agent>/<session>/usage.jsonl`），路径布局与容错读取都属于存储层；挂载位置
/// 只有 `ioFor`（工作空间抽象），**够不到数据根**——硬接就会在插件层复制一份路径
/// 规则，而那份规则以后一定与 `TreePaths` 漂。
///
/// [tailBytes] `<= 0` = 用实现方的默认上限（与面板同源）。返回值约定与其它槽一致：
/// `{ok: true, session_id, usage_file, count, skipped, calls, summary}` 或
/// `{ok: false, error: 可读中文}`。`calls` 的行形状必须与 `UsageCall.toJson()`
/// **逐字一致**（字段表的唯一出处是账本自己，不在这里另拼一套键）。
typedef StationUsageQuerier = Future<Map<String, dynamic>> Function({
  required String agentId,
  required String sessionId,
  int tailBytes,
});

/// 执行站命令的挂载位置集合（M9 Wave 3-I）。
///
/// 站点体系里「执行器只是执行站的一种挂载位置」：本类就是**系统内置挂载位置**，
/// 把首命令集里除 `ui.push`（由站点中枢复用 4.1 的 card 槽位帧挂载）之外的八条命令
/// 接到核心既有实现上——不再出现「暂无挂载位置」：
///
/// | 命令 | 落到的既有实现 |
/// |---|---|
/// | `fs.read` / `fs.write` / `fs.list` / `fs.grep` | [WorkspaceIO]（local / ssh 同一抽象） |
/// | `terminal.exec` | 既有 `terminal` 工具的执行路径（含 hook 模式语义） |
/// | `terminal.listRuns` / `stopRun` / `log` | [TerminalHooks] 的任务表与 `readTail`：后台任务的**结构化读口与控口**（阶段 6） |
/// | `usage.query` | [StationUsageQuerier]（核心的 `UsageLog.read`：账本在数据根，插件本来够不到） |
/// | `agent.message` | 团队派发 / 会话投递（[StationAgentMessageSender]） |
/// | `agent.stop` | 既有停止路径（含**级联**语义，[StationAgentStopper]） |
/// | `agent.compact` | [StationAgentCompactor]（CompactionService 手动压缩入口） |
///
/// **隔离（plan §1.2，fail-closed）**：每条命令的第一件事都是按四元组解析目标——
/// - `agent_id` 参数与站点 scope 的 agent 不一致 ⇒ 跨 scope 拒绝；
/// - 目标 agent 的 team 与 scope.team_id 不一致 ⇒ 跨 team 拒绝；
/// - 目标 agent 的**工作空间模式**与 scope.mode_key 不一致 ⇒ 跨模式拒绝
///   （否则 SSH 团队的命令会打到本地工作空间）；
/// - 任何一个归属**证明不了**（agent 不存在 / 解析器没接线）⇒ 拒绝并给可读原因。
///
/// 依赖没接线时**不做静默降级**：命令以「未接线」的可读原因失败。
class ExecuteStationMounts {
  ExecuteStationMounts({
    required this.ioFor,
    required this.agentTeamOf,
    required this.agentModeOf,
    // 后台任务管理器：null = 自建一份（见 [_hooks]）；传了就用调用方那一份，
    // 使**插件下发的 hook 任务与 agent 自己起的 hook 任务共用同一张任务表**
    // （M9 Wave 3-I 第 2 条）。注入的实例归注入方所有：它的完成回调与 close
    // 都由注入方负责，本类只管用。
    TerminalHooks? hooks,
    this.onHookFinished,
    this.messageSender,
    this.agentStopper,
    this.compactor,
    this.llmCaller,
    this.toolCaller,
    this.sessionRenamer,
    this.toolCloser,
    this.sshReconnector,
    this.pluginManager,
    this.topologyQuery,
    this.usageQuerier,
    this.log,
  }) : _injectedHooks = hooks;

  /// 便捷构造：直接用核心存储解析 agent 归属（team / 工作空间模式）。
  ///
  /// 生产接线（CLI / CoreServer）用这个工厂，隔离校验因此**永远有依据**，
  /// 不会因为忘了注入解析器而退化成「证明不了归属」。
  factory ExecuteStationMounts.forStore({
    required TreeStore store,
    required StationWorkspaceIoResolver ioFor,
    TerminalHooks? hooks,
    void Function(String agentId, String sessionId, String notice)?
    onHookFinished,
    StationAgentMessageSender? messageSender,
    StationAgentStopper? agentStopper,
    StationAgentCompactor? compactor,
    StationLlmCaller? llmCaller,
    StationToolCaller? toolCaller,
    StationSessionRenamer? sessionRenamer,
    StationToolCloser? toolCloser,
    StationSshReconnector? sshReconnector,
    StationPluginManager? pluginManager,
    StationTopologyQuery? topologyQuery,
    StationUsageQuerier? usageQuerier,
    void Function(String message)? log,
  }) => ExecuteStationMounts(
    ioFor: ioFor,
    // 与 TeamService.teamIdOf / 站点 keying **同口径**：顶层 agent（team_id 为空）
    // 自成一队，否则用它的 team_id。此前这里只读 team_id，导致针对顶层 agent 的
    // 执行站命令一律被判"没有团队归属"（站点却是按 agent.id 预建的）。
    agentTeamOf: (String agentId) {
      final CoreAgent? agent = store.agent(agentId);
      if (agent == null) return '';
      final String team = agent.teamId.trim();
      return team.isEmpty ? agent.id : team;
    },
    agentModeOf: (String agentId) => store.agent(agentId)?.sshConfig != null
        ? StationModeKey.ssh
        : StationModeKey.local,
    hooks: hooks,
    onHookFinished: onHookFinished,
    messageSender: messageSender,
    agentStopper: agentStopper,
    compactor: compactor,
    llmCaller: llmCaller,
    toolCaller: toolCaller,
    sessionRenamer: sessionRenamer,
    toolCloser: toolCloser,
    sshReconnector: sshReconnector,
    pluginManager: pluginManager,
    topologyQuery: topologyQuery,
    usageQuerier: usageQuerier,
    log: log,
  );

  /// 挂载位置 id 前缀（每个命令一个 id：`core.execute.fs.read` …）。
  static const String mountIdPrefix = 'core.execute';

  /// 工作空间 IO 解析器（按 agent；local/ssh 由既有抽象统一）。
  final StationWorkspaceIoResolver ioFor;

  /// 目标 agent → 团队归属（隔离校验）。
  final StationAgentTeamResolver agentTeamOf;

  /// 目标 agent → 工作空间模式（隔离校验）。
  final StationAgentModeResolver agentModeOf;

  /// 后台任务完成回调（`terminal.exec` 的 hook 模式；核心接到会话唤醒）。
  final void Function(String agentId, String sessionId, String notice)?
  onHookFinished;

  /// `agent.message` 的投递入口；null = 该命令显式报「未接线」。
  final StationAgentMessageSender? messageSender;

  /// `agent.stop` 的停止入口；null = 该命令显式报「未接线」。
  final StationAgentStopper? agentStopper;

  /// `agent.compact` 的手动压缩入口；null = 该命令显式报「未接线」。
  final StationAgentCompactor? compactor;

  /// `llm.call`（硬设 JSON 返回形式的 LLM 调用）入口；null = 该命令显式报「未接线」。
  final StationLlmCaller? llmCaller;

  /// `tool.call`（执行任意工具）入口；null = 该命令显式报「未接线」。
  final StationToolCaller? toolCaller;

  /// `session.rename`（会话重命名）入口；null = 该命令显式报「未接线」。
  final StationSessionRenamer? sessionRenamer;

  /// `tool.close`（**显式**关闭一次运行中的工具）入口；null = 该命令显式报
  /// 「未接线」——**不做静默降级**（不假装"已经关掉了"）。
  final StationToolCloser? toolCloser;

  /// `ssh.reconnect`（重建远端 SSH 链路）入口；null = 该命令显式报「未接线」。
  final StationSshReconnector? sshReconnector;

  /// `plugin.*` 族（插件热重启控制面）入口；null = 这些命令显式报「未接线」。
  ///
  /// 这一族的实现只能是 `PluginBus`：插件实例表、generation 计数、快照内存池
  /// 都在它那里，挂载位置层因此不拿任何插件状态、只负责**归属校验 + 分派**。
  final StationPluginManager? pluginManager;

  /// `station.*` 族（站点拓扑，只读）入口；null = 这些命令显式报「未接线」。
  ///
  /// 为什么单独一个槽而不并进 [pluginManager]：两道闸门不同——插件族问的是
  /// 「谁能动谁的快照」，站点族问的是「这个 team 能看见哪些站」。并进一个入口
  /// 就会把两套口径挤在一个 switch 里，而过两年没人记得它们为何不同。
  final StationTopologyQuery? topologyQuery;

  /// `usage.query`（逐调用用量账本，只读）入口；null = 该命令显式报「未接线」。
  ///
  /// 与 [topologyQuery] 同样的理由：数据只在实现方那里（一份在总线站点表，一份在
  /// 核心的存储层），本层只做四元组隔离与参数钳制，不另拿一份路径规则。
  final StationUsageQuerier? usageQuerier;

  final void Function(String message)? log;

  final TerminalHooks? _injectedHooks;
  TerminalHooks? _ownHooks;

  /// `terminal.exec` 用的后台任务管理器。
  ///
  /// 注入了就用注入的那一份（与工具层共用，`hook_action=status/cancel` 因此能查到
  /// agent 自己起的后台任务；完成回调也归注入方，本类不接管）；没注入就自建一份并把
  /// 完成回调接到 [onHookFinished]。两条路径下 `terminal.exec` 的行为一致，
  /// 差别只在**任务表是不是与工具层同一张**。
  TerminalHooks get _hooks {
    final TerminalHooks? injected = _injectedHooks;
    if (injected != null) return injected;
    final TerminalHooks? existing = _ownHooks;
    if (existing != null) return existing;
    final TerminalHooks created = TerminalHooks(log: log);
    // `hookNotice` 是异步的（日志尾部可能要读**远端**）：先取提示文本再回调。
    created.onFinished = (HookTask task, int exitCode) async {
      final String notice = await hookNotice(task, exitCode);
      onHookFinished?.call(task.agentId, task.sessionId, notice);
    };
    _ownHooks = created;
    return created;
  }

  /// 把本点位拥有的命令挂到该执行站；返回 null = 全部成功，否则是可读原因（不静默）。
  ///
  /// 幂等：同 mountId + 同命令会被站点替换（重复调用不会叠加挂载项）。
  ///
  /// **点位化（2026-10-01）**：执行站按命令族拆成多个实例，所以这里只挂
  /// `station.commands`（点位表给出的白名单子集）——给一个点位挂上不属于它的命令
  /// 会被站点自己拒绝，这里不制造那种噪音。
  String? mountInto(ExecuteStation station) {
    final List<String> failed = <String>[];
    for (final String command in station.commands) {
      // ui.push 由站点中枢挂载（复用 4.1 card 槽位帧），不在这里重复挂
      if (command == 'ui.push') continue;
      final String? error = station.mount(
        command: command,
        mountId: '$mountIdPrefix.$command',
        handler: _handle,
      );
      if (error != null) failed.add(error);
    }
    if (failed.isEmpty) return null;
    return failed.join('；');
  }

  /// 释放自建的后台任务管理器（注入的那一份由注入方负责关）。
  Future<void> close() async {
    final TerminalHooks? own = _ownHooks;
    _ownHooks = null;
    if (own != null) await own.close();
  }

  // ── 命令分发 ─────────────────────────────────────────────────────────

  Future<StationCommandOutcome> _handle(StationCommandContext context) async {
    final String command = context.command;
    // 白名单复核（站点已校验过一次；挂载位置不假设调用方一定校验过）
    if (StationPoints.ownerOfCommand(command) == null) {
      return StationCommandOutcome.failed(
        '命令 $command 不在执行站命令白名单内，拒绝执行（挂载位置复核）',
      );
    }
    // **插件族不靠 agent 工作空间归属证明身份**，所以在 `_resolveTarget` 之前分派：
    // 它的闸门是「发起者是谁的快照」与「能不能证明 team」（见 [_pluginCommand]）。
    // 把它塞进四元组解析会造出一个假需求——快照本来就没有目标 agent。
    if (command.startsWith('plugin.')) {
      try {
        return await _pluginCommand(context, command);
      } catch (error) {
        return StationCommandOutcome.failed('命令 $command 执行异常：$error');
      }
    }
    // `station.*` 也不靠 agent 工作空间归属证明身份（看站点拓扑本来就没有目标 agent），
    // 因此同样在 `_resolveTarget` 之前分派。
    if (command.startsWith('station.')) {
      try {
        return await _stationCommand(context, command);
      } catch (error) {
        return StationCommandOutcome.failed('命令 $command 执行异常：$error');
      }
    }
    // **四元组解析目标**：证明不了归属一律拒绝
    final _StationTarget target = _resolveTarget(context);
    if (target.error.isNotEmpty) {
      log?.call('执行站命令 $command 被拒：${target.error}');
      return StationCommandOutcome.failed(target.error);
    }
    try {
      switch (command) {
        case 'fs.read':
          return await _fsRead(context, target);
        case 'fs.write':
          return await _fsWrite(context, target);
        case 'fs.list':
          return await _fsList(context, target);
        case 'fs.grep':
          return await _fsGrep(context, target);
        case 'terminal.exec':
          return await _terminalExec(context, target);
        case 'terminal.listRuns':
          return await _terminalListRuns(context, target);
        case 'terminal.stopRun':
          return await _terminalStopRun(context, target);
        case 'terminal.log':
          return await _terminalLog(context, target);
        case 'usage.query':
          return await _usageQuery(context, target);
        case 'agent.message':
          return await _agentMessage(context, target);
        case 'agent.stop':
          return await _agentStop(context, target);
        case 'agent.compact':
          return await _agentCompact(context, target);
        case 'llm.call':
          return await _llmCall(context, target);
        case 'tool.call':
          return await _toolCall(context, target);
        case 'session.rename':
          return await _sessionRename(context, target);
        case 'tool.close':
          return await _toolClose(context, target);
        case 'ssh.reconnect':
          return await _sshReconnect(context, target);
        default:
          return StationCommandOutcome.failed('命令 $command 尚无挂载实现');
      }
    } on WorkspacePathException catch (error) {
      return StationCommandOutcome.failed(
        '路径非法（${error.relativePath}）：${error.reason}',
      );
    } on SshLinkStaleException catch (error) {
      // M9 §1.1：判据是活性（心跳），不是静态时长——失联要显式说出来
      return StationCommandOutcome.failed('SSH 会话心跳丢失（会话失联）：${error.message}');
    } on WorkspaceIoException catch (error) {
      return StationCommandOutcome.failed('工作空间 IO 失败：${error.message}');
    } catch (error) {
      return StationCommandOutcome.failed('命令 $command 执行异常：$error');
    }
  }

  /// `plugin.*` 族的归属闸门与分派（插件热重启控制面）。
  ///
  /// 两条不同的归属口径，刻意不合并成一条（合并就会一边假严、一边真松）：
  /// - `plugin.stateDump` / `plugin.stateFetch`：**发起者必须是插件**，且只能对
  ///   **自己**的快照下命令（`plugin_id` 与发起者不一致直接拒绝）。它们的闸门是
  ///   「谁在说话」而不是「目标 agent 属于哪个 team」——快照本来就没有 agent；
  /// - 其余四条（list / restart / suspend / state）：控制别人的插件必须有可证明的
  ///   team 归属，`scope.team_id` 为空 ⇒ fail-closed 拒绝（与类注释第 4 条同口径）。
  ///
  /// 本层**不碰插件实例表**：具体做什么全部交给 [pluginManager]（= `PluginBus`），
  /// 没接线时以「未接线」显式失败（不做静默降级，见类注释第 15 条）。
  Future<StationCommandOutcome> _pluginCommand(
    StationCommandContext context,
    String command,
  ) async {
    final StationPluginManager? manager = pluginManager;
    if (manager == null) {
      return StationCommandOutcome.failed(
        '命令 $command 尚无挂载实现（核心未给执行站注入插件管理器：未接线，'
        '不假装已经做过）',
      );
    }
    final String requested = _string(context.arguments['plugin_id']);
    final bool selfSnapshot =
        command == 'plugin.stateDump' || command == 'plugin.stateFetch';
    String target = requested;
    if (selfSnapshot) {
      final String source = context.sourcePluginId.trim();
      if (source.isEmpty) {
        return StationCommandOutcome.failed(
          '命令 $command 必须由插件身份下达（没有 source_plugin_id ⇒ 证明不了快照'
          '归谁）：拒绝执行（fail-closed）',
        );
      }
      if (requested.isNotEmpty && requested != source) {
        return StationCommandOutcome.failed(
          '插件 $source 不能对 $requested 下 $command：只能操作自己的快照'
          '（跨插件读写一律拒绝）',
        );
      }
      target = source;
    } else {
      if (context.scope.teamId.trim().isEmpty) {
        return StationCommandOutcome.failed(
          '命令 $command 的 scope 缺少 team_id：证明不了归属 ⇒ 拒绝执行'
          '（fail-closed）',
        );
      }
      // plugin.list 不带目标 id（它就是「看全部」），其余四条要指名插件
      if (target.isEmpty && command != 'plugin.list') {
        return StationCommandOutcome.failed(
          '命令 $command 需要 arguments.plugin_id（要动哪个插件）',
        );
      }
    }
    final Map<String, dynamic> result = await manager(
      command: command,
      pluginId: target,
      sourcePluginId: context.sourcePluginId,
      arguments: context.arguments,
    );
    return _outcomeOf(result, command);
  }

  /// `station.*` 族的归属闸门与分派（站点拓扑，**只读**）。
  ///
  /// 闸门只有一条：**team 必须证明得了**（与插件族控制面四条同形，但理由不同：
  /// 那里问的是“能不能动它”，这里问的是“能不能看见它”——插件自建站里写着别人的
  /// topic 与配置）。具体可见性过滤在实现方（`PluginBus.handleStationQuery`）里做，
  /// 本层不复制那份规则（复制一次就会两头漂）。
  Future<StationCommandOutcome> _stationCommand(
    StationCommandContext context,
    String command,
  ) async {
    final StationTopologyQuery? query = topologyQuery;
    if (query == null) {
      return StationCommandOutcome.failed(
        '命令 $command 尚无挂载实现（核心未给执行站注入站点拓扑读口：未接线，'
        '不假装已经读过）',
      );
    }
    final String teamId = context.scope.teamId.trim();
    if (teamId.isEmpty) {
      return StationCommandOutcome.failed(
        '命令 $command 的 scope 缺少 team_id：证明不了归属 ⇒ 拒绝执行'
        '（fail-closed）',
      );
    }
    final Map<String, dynamic> result = await query(
      command: command,
      teamId: teamId,
      arguments: context.arguments,
      sourcePluginId: context.sourcePluginId,
    );
    return _outcomeOf(result, command);
  }

  /// 把槽返回的 `{ok, …}` 翻成站点结论（插件族与站点族**共用这一条**口径）。
  ///
  /// 原因的键有两套写法：本层惯例是 `error`，而热重启的结论带的是 `reason`
  /// （`PluginHotRestartResult.toJson`）。只读 error 会把“新一世没起来”这种最要紧
  /// 的失败说成“未给出原因”（不变量 6：失败必须可读）。
  static StationCommandOutcome _outcomeOf(
    Map<String, dynamic> result,
    String command,
  ) {
    final Object? ok = result['ok'];
    if (ok is bool && !ok) {
      final String error = _string(result['error']).isNotEmpty
          ? _string(result['error'])
          : _string(result['reason']);
      return StationCommandOutcome.failed(
        error.isEmpty ? '命令 $command 失败（未给出原因）' : error,
      );
    }
    return StationCommandOutcome.ok(result);
  }

  /// 按站点 scope 四元组解析命令目标（fail-closed）。
  _StationTarget _resolveTarget(StationCommandContext context) {
    final StationScope scope = context.scope;
    if (scope.teamId.trim().isEmpty) {
      return const _StationTarget.rejected(
        '命令 scope 缺少 team_id：拒绝执行（fail-closed）',
      );
    }
    if (!StationModeKey.isValid(scope.modeKey)) {
      return _StationTarget.rejected(
        '命令 scope 的 mode_key=${scope.modeKey} 非法（只能是 local | ssh）：拒绝执行',
      );
    }
    final String explicit = _string(context.arguments['agent_id']);
    final String scoped = scope.agentId.trim();
    if (explicit.isNotEmpty && scoped.isNotEmpty && explicit != scoped) {
      return _StationTarget.rejected(
        '命令 ${context.command} 的目标 agent=$explicit 与站点 scope 的 '
        'agent=$scoped 不一致：跨 scope 拒绝执行',
      );
    }
    final String agentId = explicit.isNotEmpty ? explicit : scoped;
    if (agentId.isEmpty) {
      return _StationTarget.rejected(
        '命令 ${context.command} 需要 agent_id（或本次命令的 scope 里带 agent）：'
        '无法确定目标 agent，拒绝执行',
      );
    }
    final String team = agentTeamOf(agentId).trim();
    if (team.isEmpty) {
      return _StationTarget.rejected(
        '目标 agent $agentId 不存在或没有团队归属：拒绝执行（fail-closed）',
      );
    }
    if (team != scope.teamId) {
      return _StationTarget.rejected(
        '跨 team 拒绝执行：目标 agent $agentId 属于 team=$team，'
        '命令 scope 是 team=${scope.teamId}',
      );
    }
    final String mode = agentModeOf(agentId).trim();
    if (!StationModeKey.isValid(mode)) {
      return _StationTarget.rejected(
        '无法证明目标 agent $agentId 的工作空间模式（解析结果「$mode」）：'
        '拒绝执行（fail-closed）',
      );
    }
    if (mode != scope.modeKey) {
      return _StationTarget.rejected(
        '跨模式拒绝执行：目标 agent $agentId 的工作空间模式是 $mode，'
        '命令 scope 是 ${scope.modeKey}（否则 SSH 团队的命令会打到本地工作空间）',
      );
    }
    return _StationTarget(agentId: agentId, teamId: team, modeKey: mode);
  }

  /// 取目标 agent 的工作空间（local / ssh 同一抽象）；不可用时给可读原因。
  Future<({WorkspaceIO? io, String error})> _workspaceOf(
    _StationTarget target,
  ) async {
    final WorkspaceIO? io = await ioFor(target.agentId);
    if (io == null) {
      return (
        io: null,
        error:
            'agent ${target.agentId} 的工作空间不可用'
            '（未接线 / SSH 配置不完整 / 目录为空，详见核心日志）',
      );
    }
    return (io: io, error: '');
  }

  // ── fs.*：工作空间 IO（local / ssh 既有抽象） ─────────────────────────

  Future<StationCommandOutcome> _fsRead(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final String path = _string(
      context.arguments['path'] ?? context.arguments['file_path'],
    );
    if (path.isEmpty) {
      return const StationCommandOutcome.failed('fs.read 需要 path（工作空间内相对路径）');
    }
    final ({WorkspaceIO? io, String error}) workspace = await _workspaceOf(
      target,
    );
    if (workspace.io == null) {
      return StationCommandOutcome.failed(workspace.error);
    }
    final FileContent content = await workspace.io!.readFile(
      path,
      startLine: _int(context.arguments['start_line']),
      lineCount: _int(context.arguments['line_count']),
    );
    return StationCommandOutcome.ok(<String, dynamic>{
      'agent_id': target.agentId,
      'mode_key': target.modeKey,
      'path': content.path,
      'content': content.text,
      'total_lines': content.totalLines,
      'start_line': content.startLine,
      'truncated': content.truncated,
      if (content.base64 != null) 'base64': content.base64,
    });
  }

  Future<StationCommandOutcome> _fsWrite(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final String path = _string(
      context.arguments['path'] ?? context.arguments['file_path'],
    );
    if (path.isEmpty) {
      return const StationCommandOutcome.failed('fs.write 需要 path（工作空间内相对路径）');
    }
    if (!context.arguments.containsKey('content')) {
      return const StationCommandOutcome.failed('fs.write 需要 content（要写入的文本）');
    }
    final String text = (context.arguments['content'] ?? '').toString();
    final ({WorkspaceIO? io, String error}) workspace = await _workspaceOf(
      target,
    );
    if (workspace.io == null) {
      return StationCommandOutcome.failed(workspace.error);
    }
    final int bytes = await workspace.io!.writeFile(path, text);
    return StationCommandOutcome.ok(<String, dynamic>{
      'agent_id': target.agentId,
      'mode_key': target.modeKey,
      'path': path,
      'bytes_written': bytes,
    });
  }

  Future<StationCommandOutcome> _fsList(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final String path = _string(context.arguments['path']);
    final int maxDepth = _int(context.arguments['max_depth']) ?? 2;
    final int maxEntries = _int(context.arguments['max_entries']) ?? 500;
    final ({WorkspaceIO? io, String error}) workspace = await _workspaceOf(
      target,
    );
    if (workspace.io == null) {
      return StationCommandOutcome.failed(workspace.error);
    }
    final String relative = path.isEmpty ? '.' : path;
    final List<String> entries = await workspace.io!.listFiles(
      relativePath: relative,
      maxDepth: maxDepth < 0 ? 0 : maxDepth,
      maxEntries: maxEntries < 1 ? 1 : maxEntries,
    );
    return StationCommandOutcome.ok(<String, dynamic>{
      'agent_id': target.agentId,
      'mode_key': target.modeKey,
      'path': relative,
      'root': workspace.io!.root,
      'entries': entries,
      'count': entries.length,
      'truncated': entries.length >= maxEntries,
    });
  }

  Future<StationCommandOutcome> _fsGrep(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final String pattern = _string(context.arguments['pattern']);
    if (pattern.isEmpty) {
      return const StationCommandOutcome.failed('fs.grep 需要 pattern');
    }
    final ({WorkspaceIO? io, String error}) workspace = await _workspaceOf(
      target,
    );
    if (workspace.io == null) {
      return StationCommandOutcome.failed(workspace.error);
    }
    final String path = _string(context.arguments['path']);
    final GrepOutcome outcome = await workspace.io!.grep(
      GrepQuery(
        pattern: pattern,
        regex: context.arguments['regex'] == true,
        ignoreCase: context.arguments['ignore_case'] == true,
        relativePath: path.isEmpty ? '.' : path,
        maxDepth: _int(context.arguments['max_depth']) ?? 0,
        maxResults: _int(context.arguments['max_results']) ?? 200,
        exclude: _strings(context.arguments['exclude']),
        // 与内置 grep 工具同一默认口径：隐藏路径（`.[!.]*`）默认不搜。
        includeHidden: context.arguments['include_hidden'] == true,
      ),
    );
    return StationCommandOutcome.ok(<String, dynamic>{
      'agent_id': target.agentId,
      'mode_key': target.modeKey,
      'pattern': pattern,
      'count': outcome.matches.length,
      'matches': <Map<String, dynamic>>[
        for (final GrepMatch match in outcome.matches)
          <String, dynamic>{
            'path': match.path,
            'line': match.lineNumber,
            'text': match.line,
          },
      ],
      'truncated': outcome.truncated,
      'scanned_file_count': outcome.scannedFileCount,
      'scanned_file_paths': outcome.scannedFilePaths,
      'excluded_dirs': outcome.excludedDirs,
    });
  }

  // ── terminal.exec：既有 terminal 工具的执行路径（含 hook 模式语义） ────

  Future<StationCommandOutcome> _terminalExec(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    // 缺参数属于「命令根本没跑起来」，显式失败；非零退出码仍回 payload（带
    // is_error 标志 + 完整输出），因为那正是调用方要看的东西。
    final String command = _string(context.arguments['command']);
    final String hookAction = _string(context.arguments['hook_action'])
        .toLowerCase();
    if (command.isEmpty && hookAction.isEmpty) {
      return const StationCommandOutcome.failed(
        'terminal.exec 需要 command（或 hook_action + task_id 查询后台任务）',
      );
    }
    final ({WorkspaceIO? io, String error}) workspace = await _workspaceOf(
      target,
    );
    if (workspace.io == null) {
      return StationCommandOutcome.failed(workspace.error);
    }
    // 复用**同一个** terminal 工具实现：hook=true 后台执行、hook_action 查询/取消、
    // 会话失联转后台、命令跑多久都等（本地判据 = 进程存活）全部照旧。
    final ToolOutcome outcome = await BuiltinTools.run(
      ToolInvocation(
        id: 'station:${context.stationId}:${context.sourcePluginId}',
        name: BuiltinTools.terminal,
        arguments: <String, dynamic>{
          for (final MapEntry<String, dynamic> entry
              in context.arguments.entries)
            if (entry.key != 'agent_id') entry.key: entry.value,
        },
        agentId: target.agentId,
        sessionId: context.scope.sessionId,
      ),
      workspace.io,
      hooks: _hooks,
    );
    return StationCommandOutcome.ok(<String, dynamic>{
      'agent_id': target.agentId,
      'mode_key': target.modeKey,
      'text': outcome.content,
      'is_error': outcome.isError,
    });
  }

  /// `terminal.listRuns`：目标 agent 的后台（hook）任务，**结构化行**。
  ///
  /// 为什么已有 `hook_action=status` 还要这一条：那条回的是写给模型看的散文，而
  /// 转发/看护类插件要的是能直接消费的字段；`tool.close` 只按 handle 关一次运行，
  /// 也递不出台账里那些（远端 pid / 日志路径 / 接续失败次数）。
  ///
  /// 归属：任务表是**全进程一份**（本机与远端、所有 agent 混在一起），不按目标
  /// agent 过滤就等于把别人跑过什么命令递出去。会话口径**不外推**：给了才筛，
  /// 没给就返回该 agent 的全部——拿默认会话去筛会把别的会话的任务悄悄藏起来。
  Future<StationCommandOutcome> _terminalListRuns(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final String sessionFilter = _string(context.arguments['session_id']);
    final bool onlyRunning = context.arguments['only_running'] == true;
    final List<HookTask> matched =
        _hooks.tasks
            .where(
              (HookTask task) =>
                  task.agentId == target.agentId &&
                  (sessionFilter.isEmpty || task.sessionId == sessionFilter) &&
                  (!onlyRunning || task.running),
            )
            .toList()
          // 新的在前：控制面问的是「现在有什么在跑」，不是台账的考古顺序
          ..sort(
            (HookTask a, HookTask b) => b.startedAt.compareTo(a.startedAt),
          );
    final int limit = _boundedInt(
      context.arguments['limit'],
      fallback: 50,
      min: 1,
      max: 500,
    );
    final List<HookTask> page = matched.take(limit).toList(growable: false);
    return StationCommandOutcome.ok(<String, dynamic>{
      'agent_id': target.agentId,
      'mode_key': target.modeKey,
      if (sessionFilter.isNotEmpty) 'session_id': sessionFilter,
      'only_running': onlyRunning,
      'total': matched.length,
      'count': page.length,
      'truncated': matched.length > page.length,
      'runs': <Map<String, dynamic>>[
        for (final HookTask task in page) _hookRow(task),
      ],
    });
  }

  /// `terminal.stopRun`：按台账 id 终止一条后台任务（**不保证杀得掉**）。
  ///
  /// 与 `terminal.exec` 的 `hook_action=cancel` 用的是同一个 `TerminalHooks.cancel`，
  /// 差别只在回包形状。最要紧的是**不假装杀成功**：会话失联转的、远端没拿到 pid 的，
  /// 都得给出一句能说清为什么杀不掉的话（[cancelRefusal]）。
  Future<StationCommandOutcome> _terminalStopRun(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final String taskId = _string(context.arguments['task_id']);
    if (taskId.isEmpty) {
      return const StationCommandOutcome.failed(
        'terminal.stopRun 需要 task_id（terminal.listRuns 里的那一个）',
      );
    }
    final HookTask? task = _hooks.task(taskId);
    // 别人的任务一律当成“不存在”：既不动它，也不告诉发起者它真的存在
    if (task == null || task.agentId != target.agentId) {
      return StationCommandOutcome.failed(
        '未知 task_id：$taskId（目标 agent ${target.agentId} 名下没有这条后台任务；'
        '可用 terminal.listRuns 看有哪些）',
      );
    }
    final bool requested = task.running && await _hooks.cancel(taskId);
    return StationCommandOutcome.ok(<String, dynamic>{
      'agent_id': target.agentId,
      'mode_key': target.modeKey,
      'task_id': taskId,
      'requested': requested,
      'running': task.running,
      'exit_code': task.exitCode,
      // 命令本身是跑成了的（杀不掉不等于没执行）：结论写在 requested，理由写在这里
      if (!requested)
        'reason': task.running
            ? cancelRefusal(task)
            : '任务已结束（退出码 ${task.exitCode}），无需终止',
    });
  }

  /// `terminal.log`：读一条后台任务的**日志尾部**。
  ///
  /// 为什么不走 `fs.read`：日志可能在**远端**工作空间（而且可能是链路已断那一边），
  /// 读口径只在 `BackgroundExecHost.readTail` 那里；本层不自己拼路径。
  Future<StationCommandOutcome> _terminalLog(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final String taskId = _string(context.arguments['task_id']);
    if (taskId.isEmpty) {
      return const StationCommandOutcome.failed(
        'terminal.log 需要 task_id（terminal.listRuns 里的那一个）',
      );
    }
    final HookTask? task = _hooks.task(taskId);
    if (task == null || task.agentId != target.agentId) {
      return StationCommandOutcome.failed(
        '未知 task_id：$taskId（目标 agent ${target.agentId} 名下没有这条后台任务）',
      );
    }
    final BackgroundExecHost? host = task.background;
    if (host == null) {
      // 退化场景如实说：该工作空间后端不支持后台执行，日志本来就没写进去过
      return StationCommandOutcome.failed(
        '任务 $taskId 的工作空间后端不支持后台执行：日志读不到（不假装写过）',
      );
    }
    // 上限挂在核心自己那份读数上（与 `hook_action=status` 同源），插件能往下调不能往上调：
    // 一条命令把几百 MB 日志拽进内存 = 整个核心被一个插件拖死。
    final int chars = _boundedInt(
      context.arguments['tail_chars'],
      fallback: _hooks.maxTailChars,
      min: 1,
      max: _hooks.maxTailChars * 20,
    );
    final String? text = await host.readTail(task.logRelative, chars);
    return StationCommandOutcome.ok(<String, dynamic>{
      'agent_id': target.agentId,
      'mode_key': target.modeKey,
      'task_id': taskId,
      'log_relative': task.logRelative,
      'remote_log': task.remoteLog,
      // 口径明示：这是**尾部**，不是全文（全文属于会话工作空间，走 fs.read）
      'tail': true,
      'tail_chars': chars,
      'text': text ?? '',
      'has_content': text != null && text.trim().isNotEmpty,
      if (text == null) 'reason': '日志文件还不存在（任务刚起，或远端命令结束时才回写完整输出）',
    });
  }

  /// `usage.query`：取一个会话的逐调用用量账本（只读，四元组隔离后交给核心）。
  ///
  /// 本层不自己拼路径也不自己算聚合：前者属于存储层（见 [StationUsageQuerier]），
  /// 后者算两份就会与面板上那份漂。参数只钳一件事：`tail_bytes`（上限 2 MiB，
  /// 超限按上限走——账本可以很长，而这是一次站点命令不是导库）。
  Future<StationCommandOutcome> _usageQuery(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final StationUsageQuerier? querier = usageQuerier;
    if (querier == null) {
      return const StationCommandOutcome.failed(
        'usage.query 尚无挂载实现（核心未给执行站注入用量账本读口：未接线，'
        '不假装读过）',
      );
    }
    final int tailBytes = _boundedInt(
      context.arguments['tail_bytes'],
      fallback: 0,
      min: 0,
      max: 2 * 1024 * 1024,
    );
    final Map<String, dynamic> result = await querier(
      agentId: target.agentId,
      // 会话口径与 llm.call / agent.compact 逐字一致：命令参数 → 站点 scope → 默认会话
      sessionId: _sessionOf(context),
      tailBytes: tailBytes,
    );
    return _outcomeOf(result, 'usage.query');
  }

  /// 一条后台任务的结构化行（`terminal.listRuns` 的形状，字段表只在这里给一次）。
  ///
  /// `exit_code` / `pid` 拿不到时写 **null 而不省略键**：省略就分不出“正常退出码 0”
  /// 与“根本没读到”，而后者才是插件要不要重试的判据。
  static Map<String, dynamic> _hookRow(HookTask task) => <String, dynamic>{
    'task_id': task.id,
    'command': task.command,
    'session_id': task.sessionId,
    'running': task.running,
    'exit_code': task.exitCode,
    'elapsed_seconds': task.elapsed.inSeconds,
    'started_at': task.startedAt.millisecondsSinceEpoch,
    'log_relative': task.logRelative,
    'remote': task.remote,
    'remote_log': task.remoteLog,
    'detached': task.detached,
    'cancelled': task.cancelled,
    'pid': task.handle?.pid,
    'fail_streak': task.failStreak,
  };

  /// 钳一个整数参数（越界不静默接受：拿到上限就按上限跑，并把生效值 echo 回包里）。
  static int _boundedInt(
    Object? raw, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final int? parsed = raw is num
        ? raw.toInt()
        : (raw is String ? int.tryParse(raw.trim()) : null);
    if (parsed == null) return fallback;
    if (parsed < min) return min;
    if (parsed > max) return max;
    return parsed;
  }

  // ── agent.*：会话侧既有路径 ──────────────────────────────────────────

  Future<StationCommandOutcome> _agentMessage(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final StationAgentMessageSender? sender = messageSender;
    if (sender == null) {
      return const StationCommandOutcome.failed(
        'agent.message 未接线：TeamMessageDispatcher / ConversationService 未注入',
      );
    }
    final String content = _string(
      context.arguments['message'] ?? context.arguments['content'],
    );
    if (content.isEmpty) {
      return const StationCommandOutcome.failed(
        'agent.message 需要 message（消息正文）',
      );
    }
    final String sessionId = _sessionOf(context);
    final Map<String, dynamic> result = await sender(
      agentId: target.agentId,
      sessionId: sessionId,
      content: content,
      sourcePluginId: context.sourcePluginId,
    );
    final Object? error = result['error'];
    if (error != null && error.toString().isNotEmpty) {
      return StationCommandOutcome.failed(error.toString());
    }
    return StationCommandOutcome.ok(<String, dynamic>{
      ...result,
      'agent_id': target.agentId,
      'session_id': sessionId,
    });
  }

  Future<StationCommandOutcome> _agentStop(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final StationAgentStopper? stopper = agentStopper;
    if (stopper == null) {
      return const StationCommandOutcome.failed('agent.stop 未接线：停止路径未注入');
    }
    // 缺省 = **级联**（与核心既有 stop 语义一致：TOP 停整棵团队树）
    final bool cascade = context.arguments['cascade'] != false;
    final Map<String, dynamic> result = await stopper(
      target.agentId,
      cascade: cascade,
    );
    final Object? error = result['error'];
    if (error != null && error.toString().isNotEmpty) {
      return StationCommandOutcome.failed(error.toString());
    }
    if (result['any_running'] != true) {
      // 没有在途任务也要**显式**回话（不静默）
      result['reason'] = '没有进行中的任务可停止';
    }
    return StationCommandOutcome.ok(<String, dynamic>{
      ...result,
      'agent_id': target.agentId,
    });
  }

  Future<StationCommandOutcome> _agentCompact(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final StationAgentCompactor? service = compactor;
    if (service == null) {
      return const StationCommandOutcome.failed(
        'agent.compact 未接线：CompactionService 未注入',
      );
    }
    final String sessionId = _sessionOf(context);
    final Map<String, dynamic> result = await service(
      target.agentId,
      sessionId,
    );
    final Object? error = result['error'];
    if (error != null && error.toString().isNotEmpty) {
      return StationCommandOutcome.failed(error.toString());
    }
    return StationCommandOutcome.ok(<String, dynamic>{
      ...result,
      'agent_id': target.agentId,
      'session_id': sessionId,
    });
  }

  /// 会话 id：命令参数 → 站点 scope → 默认会话（与既有投递口径一致）。
  static String _sessionOf(StationCommandContext context) {
    final String explicit = _string(context.arguments['session_id']);
    if (explicit.isNotEmpty) return explicit;
    if (context.scope.sessionId.trim().isNotEmpty) {
      return context.scope.sessionId.trim();
    }
    return TreeStore.defaultSessionId;
  }

  /// `llm.call`：用目标 agent 的模型发一次 LLM 调用（**缺省硬设 JSON 返回形式**）。
  ///
  /// 参数：`messages`（OpenAI 形状的数组）**或** `prompt`（字符串），可选
  /// `system` / `model` / `temperature` / `max_tokens` / `tools` / `response_format`。
  /// 语义要点（用户定稿）：`response_format` **缺省**由**站点处**强制为 `json_object`；
  /// 显式给 `"text"`（或 `{"type":"text"}`）时**不发**该字段 —— 这条是给"要复用对话
  /// 前缀缓存"的调用留的正路（实测 `json_object` 会让端点改写提示词、整段丢缓存）；
  /// 模型复用该 agent 解析出的模型（含成员级覆盖），`model` 只作显式覆盖；
  /// **不进**任何中转点位（它不是对话的 LLM 处理）；端点不支持时如实失败。
  Future<StationCommandOutcome> _llmCall(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final StationLlmCaller? caller = llmCaller;
    if (caller == null) {
      return const StationCommandOutcome.failed('llm.call 未接线：核心未注入 LLM 调用器');
    }
    final Object? rawMessages = context.arguments['messages'];
    final String prompt = _string(
      context.arguments['prompt'] ?? context.arguments['content'],
    );
    if (rawMessages == null && prompt.isEmpty) {
      return const StationCommandOutcome.failed(
        'llm.call 需要 messages（OpenAI 形状的数组）或 prompt（字符串）',
      );
    }
    if (rawMessages != null && rawMessages is! List) {
      return const StationCommandOutcome.failed('llm.call 的 messages 必须是数组');
    }
    final Object? rawTools = context.arguments['tools'];
    if (rawTools != null && rawTools is! List) {
      return const StationCommandOutcome.failed('llm.call 的 tools 必须是数组');
    }
    // 返回形式：缺省 = 站点硬设 `json_object`（与本参数引入前**逐字一致**）；
    // 显式 `"text"` = 这次调用与对话同形态（**不发** `response_format`）——要复用
    // 端点前缀缓存的调用必须走它；给了不认识的值 ⇒ **可读失败**，不静默忽略。
    final Object? rawFormat = context.arguments['response_format'];
    final String? responseFormat = _normalizeResponseFormat(rawFormat);
    if (rawFormat != null && responseFormat == null) {
      return StationCommandOutcome.failed(
        'llm.call 的 response_format 只支持 "json_object"（缺省）或 "text"，'
        '也接受 {"type": "json_object"} / {"type": "text"} 形式；'
        '收到的是：$rawFormat',
      );
    }
    final Map<String, dynamic> result = await caller(
      agentId: target.agentId,
      // 会话口径与 `tool.call` 一致：命令参数 → 站点 scope → 默认会话
      sessionId: _sessionOf(context),
      messages: rawMessages is List ? rawMessages : null,
      prompt: prompt.isEmpty ? null : prompt,
      system: _string(context.arguments['system']),
      model: _string(context.arguments['model']),
      temperature: _double(context.arguments['temperature']),
      maxTokens: _int(context.arguments['max_tokens']),
      tools: rawTools is List ? rawTools : null,
      responseFormat: responseFormat,
    );
    final Object? error = result['error'];
    if (error != null && error.toString().isNotEmpty) {
      // **失败也要把 detail 带回去**（`text` / `text_length` / `truncated_suspect`
      // / `error_kind`…）：这是插件自愈（本地修 JSON、或发一次小的"判断 + 修 JSON"
      // 调用）的唯一依据。只回一句 error = 把那次已付费的调用彻底丢掉
      // （现场见 docs/known-issues.md #31）。
      return StationCommandOutcome.failedWith(
        error.toString(),
        <String, dynamic>{...result},
      );
    }
    return StationCommandOutcome.ok(<String, dynamic>{
      ...result,
      'agent_id': target.agentId,
      // 回包 echo **生效值**：缺省仍写 `json_object`（老插件读到的键与值都没变）
      'response_format': responseFormat ?? 'json_object',
    });
  }

  /// `tool.call`：执行**任意工具**（内置 / MCP / 插件工具同一入口）。
  ///
  /// 参数：`tool`（工具名，含 `plugin__` / `mcp__` 命名空间）、`arguments`（对象）、
  /// 可选 `relay`（true = 这次调用**也**走工具中转与广播；默认绕开，防插件自锁）。
  ///
  /// 结果口径：命令**本身**成功即 `ok: true`，工具自身失败体现在 `is_error: true`
  /// 与 `result` 文本里（与工具层 [ToolOutcome] 同一口径）——把"命令没跑起来"与
  /// "工具返回了错误"分开，插件才好判断。
  Future<StationCommandOutcome> _toolCall(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final StationToolCaller? caller = toolCaller;
    if (caller == null) {
      return const StationCommandOutcome.failed('tool.call 未接线：核心未注入工具执行器');
    }
    final String tool = _string(
      context.arguments['tool'] ?? context.arguments['name'],
    );
    if (tool.isEmpty) {
      return const StationCommandOutcome.failed(
        'tool.call 需要 tool（工具名，含 plugin__ / mcp__ 命名空间）',
      );
    }
    final Object? rawArguments =
        context.arguments['arguments'] ?? context.arguments['args'];
    if (rawArguments != null && rawArguments is! Map) {
      return const StationCommandOutcome.failed('tool.call 的 arguments 必须是对象');
    }
    final Map<String, dynamic> arguments = rawArguments is Map
        ? rawArguments.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final bool relay = context.arguments['relay'] == true;
    final String sessionId = _sessionOf(context);
    final ToolOutcome outcome = await caller(
      agentId: target.agentId,
      sessionId: sessionId,
      tool: tool,
      arguments: arguments,
      sourcePluginId: context.sourcePluginId,
      relay: relay,
    );
    return StationCommandOutcome.ok(<String, dynamic>{
      'tool': tool,
      'result': outcome.content,
      'is_error': outcome.isError,
      'relayed': relay,
      'agent_id': target.agentId,
      'session_id': sessionId,
    });
  }

  /// `tool.close`：**显式**关闭一次正在运行的"工具"。
  ///
  /// 参数：`handle`（工具运行句柄，形如 `toolrun_…`；当前在跑的可用
  /// `GET /api/tools/running` 取）。
  ///
  /// 语义要点（用户定稿，plan §10 D2/D3/D5）：
  /// - **显式干预**：工具超过阈值（默认 120 s）只发 warning，**核心不自动杀**——
  ///   关闭必须由调用方显式发起（右栏"关闭"按钮 / 本命令 / `ToolRunRegistry.close`
  ///   是**同一个**实现），避免误杀长任务；
  /// - 关闭的含义 = **尽力终止该次运行的进程树**（本地 `taskkill /T`、远端杀该会话
  ///   的进程组）+ **把这次运行从登记表移除** + **让在途工具调用收敛**（回一段可读
  ///   结果，不再等它返回）；进程是否真被终止由关闭器如实写在 `note` 里；
  /// - **fail-closed**：句柄缺失 / 失效（纯内存登记表，核心重启即清空）一律是
  ///   **命令失败 + 可读原因**，绝不假装成功；未接线同样显式报「未接线」。
  Future<StationCommandOutcome> _toolClose(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final StationToolCloser? closer = toolCloser;
    if (closer == null) {
      return const StationCommandOutcome.failed('tool.close 未接线：核心未注入工具运行关闭器');
    }
    final String handle = _string(context.arguments['handle']);
    if (handle.isEmpty) {
      return const StationCommandOutcome.failed(
        'tool.close 需要 handle（工具运行句柄，形如 toolrun_…；'
        '可用 GET /api/tools/running 取当前在跑的）',
      );
    }
    final Map<String, dynamic> result = await closer(handle);
    final Object? error = result['error'];
    if (error != null && error.toString().isNotEmpty) {
      // 句柄失效等一律是**命令失败** + 可读原因（不静默降级成"关掉了"）
      return StationCommandOutcome.failed(error.toString());
    }
    return StationCommandOutcome.ok(<String, dynamic>{
      ...result,
      'agent_id': target.agentId,
    });
  }

  /// `session.rename`：会话重命名（与 REST `PATCH …/sessions/{id}` 同一 store 实现）。
  ///
  /// 参数：`title`（新标题，**空标题显式失败**——store 层"空标题 = 不改名"不能
  /// 在命令层静默返回成功）。
  Future<StationCommandOutcome> _sessionRename(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final StationSessionRenamer? renamer = sessionRenamer;
    if (renamer == null) {
      return const StationCommandOutcome.failed(
        'session.rename 未接线：核心未注入会话改名器',
      );
    }
    final String title = _string(
      context.arguments['title'] ?? context.arguments['name'],
    );
    if (title.isEmpty) {
      return const StationCommandOutcome.failed(
        'session.rename 需要 title（新标题，不能为空）',
      );
    }
    final String sessionId = _sessionOf(context);
    final Map<String, dynamic> result = await renamer(
      agentId: target.agentId,
      sessionId: sessionId,
      title: title,
    );
    final Object? error = result['error'];
    if (error != null && error.toString().isNotEmpty) {
      return StationCommandOutcome.failed(error.toString());
    }
    return StationCommandOutcome.ok(<String, dynamic>{
      ...result,
      'agent_id': target.agentId,
      'session_id': sessionId,
      'title': title,
    });
  }

  /// `ssh.reconnect`：**重建目标 agent 的远端（SSH）链路**。
  ///
  /// 与 REST `POST /api/agents/{id}/ssh/reconnect`、右栏文件面板「重连」按钮走
  /// **同一份实现**（`WorkspaceToolRunner.reconnectSshLink`）：判活判据不变（只看
  /// 连续心跳丢失），重连是判死**之后**的动作，不引入任何静态时长上限。
  ///
  /// 参数：`agent_id?`（缺省用站点 scope 的 agent）——四元组隔离已在
  /// [_resolveTarget] 里做完，这里拿到的 [target] 是**已证明归属**的目标。
  /// **三种结局如实表达**：目标不是 SSH 工作空间 ⇒ 失败 + 可读原因（**不把
  /// notSsh 说成成功**）；重建失败 ⇒ 失败；成功 ⇒ `{ok, agent_id, stale}`。
  Future<StationCommandOutcome> _sshReconnect(
    StationCommandContext context,
    _StationTarget target,
  ) async {
    final StationSshReconnector? connector = sshReconnector;
    if (connector == null) {
      return const StationCommandOutcome.failed(
        'ssh.reconnect 未接线：核心未注入远端链路重建入口',
      );
    }
    final Map<String, dynamic> result = await connector(target.agentId);
    final Object? error = result['error'];
    if (error != null && error.toString().isNotEmpty) {
      // 注入方如实报的失败（含"该 agent 不是 SSH 工作空间"）：命令失败 + 可读原因
      return StationCommandOutcome.failed(error.toString());
    }
    if (result['ok'] != true) {
      // 既没成功、也没给原因 ⇒ 不假装成功
      return StationCommandOutcome.failed(
        'ssh.reconnect 未成功：核心未给出可读原因（payload=$result）',
      );
    }
    return StationCommandOutcome.ok(<String, dynamic>{
      ...result,
      'agent_id': target.agentId,
    });
  }

  static String _string(Object? value) =>
      value == null ? '' : value.toString().trim();

  /// 归一化 `llm.call` 的 `response_format`（2026-10-04 新增）。
  ///
  /// - 入参 `null` = 调用方**没给** ⇒ 返回 `null`（用站点缺省 `json_object`）；
  /// - `"json_object"` / `"text"`（大小写不敏感）或 `{"type": "…"}` 对象 ⇒ 归一成这两个值；
  /// - 其它 ⇒ 返回 `null`，调用方据此**可读失败**（插件写了错值却以为生效，是最难查的一类问题）。
  static String? _normalizeResponseFormat(Object? raw) {
    if (raw == null) return null;
    final Object? type = raw is Map ? raw['type'] : raw;
    final String value = (type ?? '').toString().trim().toLowerCase();
    return (value == 'text' || value == 'json_object') ? value : null;
  }

  static int? _int(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static List<String> _strings(Object? value) {
    if (value is List) {
      return value
          .map((Object? item) => item.toString())
          .where((String item) => item.trim().isNotEmpty)
          .toList(growable: false);
    }
    if (value is String && value.trim().isNotEmpty) {
      return <String>[value.trim()];
    }
    return const <String>[];
  }
}

/// 一条命令解析出来的目标（agent + 归属；[error] 非空 = 拒绝原因）。
class _StationTarget {
  const _StationTarget({
    required this.agentId,
    required this.teamId,
    required this.modeKey,
  }) : error = '';

  const _StationTarget.rejected(this.error)
    : agentId = '',
      teamId = '',
      modeKey = '';

  final String agentId;
  final String teamId;
  final String modeKey;
  final String error;
}
