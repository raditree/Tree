import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_local_exec/tree_local_exec.dart';

import '../settings/ssh_config.dart';

import '../agent/private_workspace_io.dart';
import '../mcp/mcp_service.dart';
import '../plugin/plugin_bus.dart';
import '../spec/spec_service.dart';
import '../team/message_dispatcher.dart';
import '../team/team_service.dart';
import 'builtin_tools.dart';
import 'hook_ledger.dart';
import 'mcp_tool.dart';
import 'message_tool.dart';
import 'plugin_tool.dart';
import 'question_channel.dart';
import 'subagent_tool.dart';
import 'team_tool.dart';
import 'terminal_hooks.dart';
import 'todo_store.dart';
import 'tool_run_registry.dart';
import 'tool_runner.dart';
import 'tool_runs_scope.dart';

/// 按 agent 解析其工作空间目录（绝对路径）。
typedef WorkspaceDirResolver = String Function(String agentId);

/// 工具层实现：把 [ToolInvocation] 落到某个 agent 的工作空间（本地文件系统）。
///
/// - 每个 agent 一个 [WorkspaceIO]，按需创建并缓存（目录首次使用时创建）；
/// - **默认不截断工具结果**（M9 Q1）：有界性由 LLM 侧的 `ToolResultGate` 保证——
///   超长结果写进工作空间 `.self/results/`，送模型的那一份换成提示 + 预览，而
///   落库与前端 `tool_end` 仍是全文。工具层若先按字符截断（M9 之前是 24000 字符），
///   门控的 8000 token ≈ 16000 字符阈值就只覆盖 16000~24000 这一段，再长就直接
///   被砍掉、根本走不到重定向。要硬上限的调用方仍可显式传 [maxResultChars]；
/// - 工作空间目录由外部注入（[resolveWorkspaceDir]），因此这里不认识存储层：
///   测试可以直接给一个临时目录。
class WorkspaceToolRunner implements ToolRunner {
  WorkspaceToolRunner({
    required this.resolveWorkspaceDir,
    this.resolveSshConfig,
    this.sshIoFactory,
    this.maxResultChars = 0,
    this.todoStore,
    this.askQuestion,
    this.teamService,
    this.messageDispatcher,
    this.specService,
    this.subagentService,
    this.mcpService,
    this.pluginBus,
    ToolRunRegistry? toolRuns,
    this.hookLedger,
    WorkspaceIO Function(String dir)? ioFactory,
    this.log,
  }) : _ioFactory = ioFactory ?? LocalWorkspaceIO.new,
       // 默认 = 进程级唯一那一份（REST 快照 / `query_status.stuck_tools` / 执行站
       // `tool.close` 都读同一份真值）；测试显式注入自己的实例与阈值。
       toolRuns = toolRuns ?? ToolRunRegistry.instance {
    hooks = TerminalHooks(
      log: log,
      // 远端后台任务的落盘台账（CLI 注入 `<data_root>/hooks`）：核心/应用重启后
      // 由 `TerminalHooks.restorePending` 接续，完成提示投递回原会话。
      ledger: hookLedger,
      // 后台 hook 登记进「正在执行的 tool」：右栏因此看得见、用户关得掉。
      //
      // **必须写 `this.toolRuns`**：这里裸写 `toolRuns` 解析到的是**同名构造形参**
      // （不是上面刚初始化过的字段），而生产调用方（`tree_core_cli/bin/tree_core.dart`）
      // 不传 `toolRuns:` ⇒ 形参恒为 null ⇒ hooks 永远不登记，右栏与 `tool_runs`
      // 都看不到后台 hook。事故见 docs/known-issues.md #25，
      // 回归见 test/terminal_hook_registration_test.dart。
      toolRuns: this.toolRuns,
      // 临时员工起的 hook 归到**会话主人**（与 `.self` 分栏同一口径）。
      ownerOf: subagentService?.privateOwnerOf,
    );
    hooks.onFinished = _finished;
  }

  /// 后台任务台账（terminal hook 的落盘；null = 不落盘，测试友好）。
  final HookLedger? hookLedger;

  /// 后台长任务管理器（terminal 的 hook 模式）。
  late final TerminalHooks hooks;

  /// 后台任务完成回调（CLI 接到 `ConversationService.wake`）。
  ///
  /// [subagent] 非空 = 这次完成属于一个**临时员工**（后台 subagent）：回调方要把
  /// `subagent_id/name/level` 一并带进注入会话的那条消息（前端据此分组）。终端 hook
  /// 的完成通知不带它（null）——两条路共用同一个回调，不新增第二条唤醒通道。
  FutureOr<void> Function(
    String agentId,
    String sessionId,
    String notice, {
    SubagentTag? subagent,
  })?
  onHookFinished;

  /// 解析 agent 的工作空间目录。
  final WorkspaceDirResolver resolveWorkspaceDir;

  /// 解析 agent 的 SSH 配置（非空 = 该 agent 的工具跑在远端主机上）。
  final SshConfig? Function(String agentId)? resolveSshConfig;

  /// SSH 后端工厂（异步：要建连接、问远端 `$HOME`）。M4b-2 已交付真实实现
  /// （dartssh2 + SFTP/exec）；为 null 时对配置了 SSH 的 agent 明确报"尚未接入"
  /// 而不是静默回落本地——静默回落会把远端该做的活干在用户本机，是更坏的失败方式。
  final Future<WorkspaceIO> Function(SshConfig config)? sshIoFactory;

  /// 单条工具结果的字符上限；**0（默认）= 不截断**，交给 `ToolResultGate` 门控。
  ///
  /// 留这个开关是为了给调用方一个显式的硬上限（例如自检脚本只想要短结果）；
  /// 默认必须是 0——见类文档里 16000~24000 那一段的取舍。
  final int maxResultChars;

  /// 待办存储（为 null 时不声明 `set_todo_list`）。
  final TodoStore? todoStore;

  /// 提问通道（为 null 时不声明 `ask_user_question`）。
  final AskQuestion? askQuestion;

  /// 团队服务（为 null 时不声明 `team`）。
  final TeamService? teamService;

  /// **临时员工**服务（为 null 时不声明 `subagent`）。
  ///
  /// 除了声明与分派，它还提供两条判据（都走同一份会话级名册）：
  /// - [SubagentChannel.isSubagent]：临时员工的工具表要裁掉 `team` / `message`
  ///   （不能被派活、不能建队），其余照旧；
  /// - [SubagentChannel.privateOwnerOf]：临时员工的工作空间 IO 直接**复用发起者那条**
  ///   （同一份根、同一条 SSH 连接、同一个 `.tree/<agent>/.self` 分栏）。
  final SubagentChannel? subagentService;

  /// 消息派发（为 null 时不声明 `message`）。
  final TeamMessageDispatcher? messageDispatcher;

  /// Spec 体系（为 null 时不声明 `spec`）。
  final SpecService? specService;

  /// MCP 服务（为 null 时不声明 `mcp` 与各 MCP 工具）。
  final McpService? mcpService;

  /// 插件总线（为 null 时不声明 `plugin` 与各插件工具）。
  final PluginBus? pluginBus;

  /// **运行中工具登记表**（默认 = [ToolRunRegistry.instance]）。
  ///
  /// 挂载点就在下面的 [_execute]——内置工具、`plugin__*`、`mcp__*` 与站内
  /// `tool.call`（[runFromPlugin]）**都走这一个入口**，所以一处挂载全覆盖。
  /// 它把"正在跑什么、跑了多久、怎么收手"变成可观测（REST 快照 / warning / 广播
  /// `system.tool.timeout` / `query_status.stuck_tools`）+ 可显式干预（`tool.close`）。
  final ToolRunRegistry toolRuns;

  /// `tool_runs`（内置工具）的落点：作用域 = 本 agent + 其直属下级（团队关系 +
  /// 临时员工名册，**既有判据**），关闭 = 同一个 [ToolRunRegistry.close]。
  ///
  /// 懒建（第一次用到才建）：它只是把已有的三个对象拼在一起，没有代价也没有副作用。
  late final ToolRunsScope _toolRunsScope = ToolRunsScope(
    registry: toolRuns,
    teamService: teamService,
    subagents: subagentService,
  );

  final WorkspaceIO Function(String dir) _ioFactory;

  /// 可读日志（工具报错、结果截断等）。
  final void Function(String message)? log;

  final Map<String, WorkspaceIO> _ios = <String, WorkspaceIO>{};

  /// 已创建的工作空间根目录（自检/日志用）。
  Iterable<String> get workspaceRoots =>
      _ios.values.map((WorkspaceIO io) => io.root);

  @override
  List<ToolSpec> specsFor({
    required String agentId,
    required String sessionId,
  }) {
    final SubagentChannel? subs = subagentService;
    final bool isSubagent = subs?.isSubagent(agentId) ?? false;
    // 插件工具按**站点四元组**解析，而临时员工与发起者共享工作空间/团队归属：
    // 用发起者的 id 取表，插件的 scope 才落在真实团队上（临时员工不是独立团队）。
    final String scopeAgentId = isSubagent
        ? subs!.privateOwnerOf(agentId)
        : agentId;
    return <ToolSpec>[
      ...BuiltinTools.specs(
        withTodos: todoStore != null,
        withQuestions: askQuestion != null,
        // 临时员工：不能被派活（没有 message）、也不能建队/管队（没有 team）；
        // **subagent 不排除**——它可以再召临时员工（把同一个大任务拆细，层级有上限）。
        withTeam: teamService != null && !isSubagent,
        withMessage: messageDispatcher != null && !isSubagent,
        withSpec: specService != null,
        withSubagent: subs != null,
        // 运行中工具（plan §11.3）：登记表恒在（默认进程级唯一那一份），
        // 作用域解析用下面那份 team + 临时员工名册（缺谁就少看一路，不算未接线）。
        withToolRuns: true,
      ),
      if (mcpService != null) ...<ToolSpec>[
        McpTool.spec(),
        ...McpTool.dynamicSpecs(mcpService!),
      ],
      if (pluginBus != null) ...<ToolSpec>[
        PluginTool.spec(),
        // **工具表刷新处**（模型每轮生成前都走这里）：按调用点四元组取插件工具，
        // 内部是「缓存 + 失效点」——只有插件上线/下线/重启后才后台补一次收集。
        ...PluginTool.dynamicSpecsFor(
          pluginBus!,
          agentId: scopeAgentId,
          sessionId: sessionId,
        ),
      ],
    ];
  }

  @override
  Future<ToolOutcome> run(
    ToolInvocation invocation, {
    bool Function()? isCancelled,
  }) async {
    // **工具调用前**：把整条调用报文交给中转站点位「工具调用前」（插件可改参数，
    // 也可什么都不改）+ 广播站点位「工具调用前」（单向通知，不等回包）。
    // 未接线 / 无订阅者 / 任何异常 ⇒ 原样返回 null，走与原实现完全一致的路径。
    final ({ToolInvocation invocation, int round}) before = await _relayBefore(
      invocation,
    );
    final ToolOutcome outcome = await _execute(
      before.invocation,
      isCancelled: isCancelled,
    );
    return _relayAfter(before.invocation, outcome, round: before.round);
  }

  /// **插件经执行站发起的工具调用**（执行站命令 `tool.call` 的落点）。
  ///
  /// [relay] = false（默认）⇒ **绕开**工具中转与工具广播，直接执行。
  /// 为什么默认绕开：中转站是"一问一答 + 等回包"的，若插件既是 `tool.call` 的发起方、
  /// 又是该点位的唯一订阅者，单线程插件会在"等命令回包"与"处理自己引发的站点请求"
  /// 之间自锁。要审计自己的调用就显式 `relay: true`（代价自负：必须能并发处理）。
  ///
  /// 无论走不走中转，**隔离与权限口径不变**：仍走同一个 [ToolRunner] 实现、同一份
  /// 工作空间解析（命令层的四元组校验在 `execute_mounts._resolveTarget`）。
  Future<ToolOutcome> runFromPlugin(
    ToolInvocation invocation, {
    required String sourcePluginId,
    bool relay = false,
    bool Function()? isCancelled,
  }) async {
    if (relay) {
      final ({ToolInvocation invocation, int round}) before = await _relayBefore(
        invocation,
        origin: 'plugin',
        sourcePluginId: sourcePluginId,
      );
      final ToolOutcome outcome = await _execute(
        before.invocation,
        isCancelled: isCancelled,
      );
      return _relayAfter(
        before.invocation,
        outcome,
        round: before.round,
        origin: 'plugin',
        sourcePluginId: sourcePluginId,
      );
    }
    return _execute(invocation, isCancelled: isCancelled);
  }

  /// 工具执行的**核心分派**（不含站点中转 / 广播）：MCP / 插件 / 内置工具。
  ///
  /// 抽出来是为了让"插件发起的调用"能走同一条执行路径而**不触发站点**——绕开站点
  /// 绝不该绕开执行本身（否则两个入口的行为会各自漂移）。
  ///
  /// **登记表挂载点**（见 [toolRuns] 的文档）：每次工具调用都在这里登记 / 收尾，并在
  /// "收到显式关闭请求"时**立刻收敛**（回一段可读结果，而不是让这一批永不结束）。
  Future<ToolOutcome> _execute(
    ToolInvocation effective, {
    bool Function()? isCancelled,
  }) async {
    final ToolRun run = toolRuns.start(
      tool: effective.name,
      arguments: effective.arguments,
      agentId: effective.agentId,
      sessionId: effective.sessionId,
    );
    try {
      return await _raceClose(
        run,
        _dispatch(effective, isCancelled: isCancelled),
      );
    } finally {
      // 收尾必须走 finally：工具抛异常、被取消、被关闭，登记项都不能留下来
      // （留下的就是一个假的"正在执行的工具"）。
      toolRuns.finish(run);
    }
  }

  /// 显式关闭竞速：`tool.close`（执行站命令）/ 右栏"关闭"按钮 ⇒ 这次工具调用
  /// **立刻**带着可读结果返回。
  ///
  /// 为什么必须有这一步：工具执行没有静态上限，一条不返回的命令会让整批工具永不结束，
  /// 而引擎把"批中途到来的用户消息"推迟到批结束之后 ⇒ teammate 永久失联（见
  /// `.self/recon-arch-stability.md` §2.7）。关闭的语义因此是"**让这次调用收敛**"
  /// （尽力终止进程树 + 交回控制权），而不是偷偷改掉停止/打断的语义——停止键与打断
  /// 一个字都没动，终止在途工具**只能**走这个显式句柄（plan §2.1）。
  ///
  /// 被放弃的那条执行 future 始终挂着错误处理器：它晚些时候结束（或抛
  /// `LocalExecStillRunning`）时不会变成"未捕获异常"。
  Future<ToolOutcome> _raceClose(ToolRun run, Future<ToolOutcome> work) {
    final Completer<ToolOutcome> done = Completer<ToolOutcome>();
    unawaited(
      run.closeRequested.then((String _) {
        if (!done.isCompleted) {
          done.complete(ToolOutcome(run.closedOutcomeText, isError: true));
        }
      }),
    );
    work.then(
      (ToolOutcome outcome) {
        if (!done.isCompleted) done.complete(outcome);
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) {
          done.completeError(error, stack);
        } else {
          log?.call('工具 ${run.tool} 被关闭后仍以异常收场（已忽略）：$error');
        }
      },
    );
    return done.future;
  }

  /// **终止一次登记中的工具运行**（执行站 `tool.close` / REST 关闭入口的落点）。
  ///
  /// 现状（如实，不假装杀成功）：本机**同步执行中**的命令，进程句柄由执行器
  /// （`LocalWorkspaceIO.exec`）持有，核心这一层拿不到 pid；远端命令更不在本机。
  /// 所以这里能真正 `taskkill /T` 的只有"进程句柄已在手"的运行（[ToolRun.pid] 非空
  /// ——本地执行器把 pid 交出来时的接缝）；其余情况返回可读说明，**真正的收敛**由
  /// [_raceClose] 保证（这次调用立刻返回、批可以收尾）。
  Future<String> terminateToolRun(ToolRun run) async {
    final int? pid = run.pid;
    if (pid != null) {
      await Shell.killProcessTree(pid);
      return '已终止本机进程树（pid=$pid，taskkill /T）；这次调用已按关闭请求收敛';
    }
    if (run.tool != BuiltinTools.terminal) {
      return '该工具（${run.tool}）不是命令执行类：没有可终止的进程；'
          '这次调用已按关闭请求收敛（工具若已结束，登记项同时移除）';
    }
    return '未拿到本机进程句柄（命令仍在同步执行中，pid 由执行器持有）：'
        '没有可供 taskkill /T 的目标；这次调用已按关闭请求收敛，命令可能仍在跑'
        '（远端命令本机无法终止）——请用 terminal 复查进程与产物，不要直接重跑';
  }

  /// MCP / 插件 / 内置工具的实际分派（不含登记表与关闭竞速，见 [_execute]）。
  Future<ToolOutcome> _dispatch(
    ToolInvocation effective, {
    bool Function()? isCancelled,
  }) async {
    // MCP 工具（含命名空间工具）不经 BuiltinTools 的 switch：它们的名字是
    // 动态的，且同样不依赖工作空间。
    final McpService? mcp = mcpService;
    if (mcp != null && McpTool.handles(effective.name)) {
      return _truncate(await McpTool.run(effective, mcp));
    }
    final PluginBus? plugins = pluginBus;
    if (plugins != null && PluginTool.handles(effective.name)) {
      return _truncate(await PluginTool.run(effective, plugins));
    }
    // **权限（工具表）口径**：临时员工没有 team / message（不能被派活、也不能建队/
    // 管队）。这是一条"以谁的身份能调什么"的判据，与三站无关——`subagent` 本身
    // 与其它内置工具同权同站，**不走任何白名单/特例**。
    final SubagentChannel? subs = subagentService;
    if (subs != null &&
        subs.isSubagent(effective.agentId) &&
        (effective.name == TeamTool.name ||
            effective.name == MessageTool.name)) {
      return ToolOutcome(
        '临时员工不能使用 ${effective.name} 工具：它的活由 task 下达、产出一段报告，'
        '既不能被派活也不能派活给团队成员。',
        isError: true,
      );
    }
    // 不依赖工作空间的工具（set_todo_list / ask_user_question / subagent）先走：
    // 工作空间不可用（SSH 配置不全等）不该连带它们一起失败。`subagent` 明确
    // **不属于** `needsWorkspace`：工具本身不读文件，子 agent 的工作空间由它自己
    // 在运行时解析（缺工作空间时由 SubagentService 给可读错误）。
    WorkspaceIO? io;
    if (BuiltinTools.needsWorkspace(effective.name)) {
      io = await _ioFor(effective.agentId);
      if (io == null) {
        return ToolOutcome(
          '无法准备工作空间：${effective.agentId} 的工作目录不可用，'
          '或 SSH 配置不完整/尚未接入（详见核心日志）',
          isError: true,
        );
      }
    }
    // 临时员工的提问要**带上它的名字**（用户不该以为这是主 agent 在问）：
    // 问题归集到会话主人的会话（临时员工没有自己的会话），并打上 subagent 标记。
    AskQuestion? ask = askQuestion;
    final SubagentTag? tag = subs?.tagOf(effective.agentId);
    if (ask != null && tag != null) {
      final AskQuestion inner = ask;
      ask = (AskQuestionRequest request) => inner(
        AskQuestionRequest(
          agentId: subs!.privateOwnerOf(request.agentId),
          sessionId: request.sessionId,
          // 多问题：标记只加在**第一问**的题面上（卡片本来就显示在这名临时员工名下，
          // 每道题都重复一遍名字只会把题面撑得读不下去）
          questions: prefixFirstQuestion(
            request.questions,
            '【临时员工「${tag.name}」提问】',
          ),
          teamId: request.teamId,
          isMember: request.isMember,
          subagentId: tag.id,
          subagentName: tag.name,
          subagentParentId: tag.parentId,
          subagentLevel: tag.level,
          isCancelled: request.isCancelled,
        ),
      );
    }
    final ToolOutcome outcome = await BuiltinTools.run(
      effective,
      io,
      isCancelled: isCancelled,
      todos: todoStore,
      hooks: hooks,
      askQuestion: ask,
      teamService: teamService,
      messageDispatcher: messageDispatcher,
      specService: specService,
      subagentChannel: subs,
      toolRunsChannel: _toolRunsScope,
      withTodos: todoStore != null,
      withQuestions: ask != null,
      withTeam: teamService != null,
      withMessage: messageDispatcher != null,
      withSpec: specService != null,
      withSubagent: subs != null,
      withToolRuns: true,
    );
    return _truncate(outcome);
  }

  /// **工具调用前**的中转：插件回填的报文里 `arguments` 即生效参数。
  ///
  /// 只有「回填报文里的 arguments 与进来时不同」才替换——插件回填整个报文但没动
  /// 参数时，调用方零改动。参数回填不是 Map 时忽略（工具参数必须是对象）。
  ///
  /// 返回的 `round` 是这次调用的序号（同一次 `run` 的 pre / post 同值）；
  /// **按调用分配**（不是实例字段）——同名工具可能被多路并行调用，用共享字段会串号。
  Future<({ToolInvocation invocation, int round})> _relayBefore(
    ToolInvocation invocation, {
    String origin = 'agent',
    String sourcePluginId = '',
  }) async {
    final int round = ++_relaySeq;
    final PluginBus? plugins = pluginBus;
    if (plugins == null) return (invocation: invocation, round: round);
    // 广播站点位（**单向通知，不等回包**）：与中转站同一位置、同一份报文。
    // 先广播再中转：广播的 pre 语义是"这次调用即将发生"（不该等改写结果）。
    plugins.announceToolCall(
      phase: 'pre',
      tool: invocation.name,
      callId: invocation.id,
      round: round,
      agentId: invocation.agentId,
      sessionId: invocation.sessionId,
      arguments: invocation.arguments,
      origin: origin,
      sourcePluginId: sourcePluginId,
    );
    final Map<String, dynamic>? relayed = await plugins.relayToolCall(
      phase: 'pre',
      tool: invocation.name,
      callId: invocation.id,
      round: round,
      agentId: invocation.agentId,
      sessionId: invocation.sessionId,
      arguments: invocation.arguments,
      origin: origin,
      sourcePluginId: sourcePluginId,
    );
    if (relayed == null) return (invocation: invocation, round: round);
    final Object? rawArguments = relayed['arguments'];
    if (rawArguments is! Map) return (invocation: invocation, round: round);
    final Map<String, dynamic> next = rawArguments.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    );
    if (_sameArguments(next, invocation.arguments)) {
      return (invocation: invocation, round: round);
    }
    log?.call(
      '工具 ${invocation.name} 的参数被中转站改写（${invocation.arguments.keys.length} → ${next.keys.length} 个键）',
    );
    return (
      invocation: ToolInvocation(
        id: invocation.id,
        name: invocation.name,
        arguments: next,
        // 原始文本已过时（参数被改写），置空避免回灌给模型的是旧 JSON。
        rawArguments: '',
        agentId: invocation.agentId,
        sessionId: invocation.sessionId,
      ),
      round: round,
    );
  }

  /// **工具调用后**的中转：插件回填的报文里 `result` 即生效结果。
  Future<ToolOutcome> _relayAfter(
    ToolInvocation invocation,
    ToolOutcome outcome, {
    required int round,
    String origin = 'agent',
    String sourcePluginId = '',
  }) async {
    final PluginBus? plugins = pluginBus;
    if (plugins == null) return outcome;
    // 广播站点位（单向通知）：这次调用的结果（含错误）
    plugins.announceToolCall(
      phase: 'post',
      tool: invocation.name,
      callId: invocation.id,
      round: round,
      agentId: invocation.agentId,
      sessionId: invocation.sessionId,
      arguments: invocation.arguments,
      result: outcome.content,
      isError: outcome.isError,
      origin: origin,
      sourcePluginId: sourcePluginId,
    );
    final Map<String, dynamic>? relayed = await plugins.relayToolCall(
      phase: 'post',
      tool: invocation.name,
      callId: invocation.id,
      round: round,
      agentId: invocation.agentId,
      sessionId: invocation.sessionId,
      arguments: invocation.arguments,
      result: outcome.content,
      isError: outcome.isError,
      origin: origin,
      sourcePluginId: sourcePluginId,
    );
    if (relayed == null) return outcome;
    final Object? rawResult = relayed['result'];
    final String content = rawResult is String
        ? rawResult
        : (rawResult == null ? outcome.content : jsonEncode(rawResult));
    if (content == outcome.content) return outcome;
    return ToolOutcome(content, isError: relayed['is_error'] == true);
  }

  /// 本进程内的工具调用序号（同一次 `run` 的 pre / post 同值）。
  ///
  /// 工具层本身不认识"第几轮"（那是 LLM 会话的概念），这里只保证一对调用可配对；
  /// 真正的轮次口径见 ConversationService 的 `round`（agent.tool_call 事件）。
  int _relaySeq = 0;

  static bool _sameArguments(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, dynamic> e in a.entries) {
      if (!b.containsKey(e.key)) return false;
      final Object? other = b[e.key];
      if (e.value is Map && other is Map) {
        if (!_sameArguments(
          (e.value as Map).map(
            (dynamic k, dynamic v) => MapEntry(k.toString(), v),
          ),
          other.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        )) {
          return false;
        }
        continue;
      }
      if (e.value is List && other is List) {
        if (jsonEncode(e.value) != jsonEncode(other)) return false;
        continue;
      }
      if (e.value != other) return false;
    }
    return true;
  }

  @override
  Future<void> close() async {
    await hooks.close();
    for (final WorkspaceIO io in _ios.values) {
      await io.close();
    }
    _ios.clear();
  }

  Future<void> _finished(HookTask task, int exitCode) async {
    final FutureOr<void> Function(
      String,
      String,
      String, {
      SubagentTag? subagent,
    })?
    callback = onHookFinished;
    if (callback == null) return;
    // **临时员工起的 hook**：把它的标记带上（`subagentService.tagOf`）。`wake` 因此
    // 能把完成提示归到**会话主人**的会话流（临时员工没有自己的会话）并带 `subagent_id`，
    // 同时以**它自己**的身份唤醒它。旧实现不带标记 ⇒ 提示会冒充主 agent 的消息，且
    // `wake` 用 `sub_…` 取会话取到 null 直接 return：不落库、不唤醒、父白等
    // （用户 2026-10-03 现场）。
    final SubagentTag? tag = subagentService?.tagOf(task.agentId);
    // `hookNotice` 异步：日志尾部可能要从**远端**读（io.readTail 走 SFTP）。
    final String notice = await hookNotice(task, exitCode);
    await callback(task.agentId, task.sessionId, notice, subagent: tag);
  }

  /// 供核心层（Spec 索引、待办读取等）复用同一份工作空间缓存：
  /// 解析失败返回 null（调用方决定降级行为）。
  Future<WorkspaceIO?> ioFor(String agentId) => _ioFor(agentId);

  Future<WorkspaceIO?> _ioFor(String agentId) async {
    // **临时员工复用发起者那条工作空间**（同一份根、同一条 SSH 连接、同一个
    // `.tree/<agent>/.self` 私有分栏）：私有状态归到**会话主人**，用户的工作空间里
    // 因此不会留下 `sub_*` 目录，它读到的系统提示词文件与发起者是同一份。
    final String ownerId = subagentService?.privateOwnerOf(agentId) ?? agentId;
    final WorkspaceIO? cached = _ios[ownerId];
    if (cached != null) return cached;

    final SshConfig? ssh = resolveSshConfig?.call(ownerId);
    if (ssh != null) {
      final Future<WorkspaceIO> Function(SshConfig config)? factory =
          sshIoFactory;
      if (factory == null) {
        log?.call(
          'agent $ownerId 配置了 SSH ${ssh.redacted()}，'
          '但 SSH 执行后端尚未接入（M4b-2）',
        );
        return null;
      }
      if (!ssh.isComplete) {
        log?.call('agent $ownerId 的 SSH 配置缺少：${ssh.missingFields.join('、')}');
        return null;
      }
      // 私有状态按 agent 分栏（`.self/…` → `.tree/<agent_id>/.self/…`）：
      // 团队成员与 leader 共享工作目录，但各自的 .self 必须分开（见 PrivateWorkspaceIO）。
      final WorkspaceIO io = PrivateWorkspaceIO(await factory(ssh), ownerId);
      _ios[ownerId] = io;
      return io;
    }

    final String dir = resolveWorkspaceDir(ownerId);
    if (dir.trim().isEmpty) {
      log?.call('agent $ownerId 的工作空间目录为空');
      return null;
    }
    try {
      await Directory(dir).create(recursive: true);
    } catch (error) {
      log?.call('创建工作空间失败（$dir）：$error');
      return null;
    }
    // 本机后端同样按 agent 分栏（`.self/…` → `.tree/<agent_id>/.self/…`）。
    final WorkspaceIO io = PrivateWorkspaceIO(_ioFactory(p.normalize(dir)), ownerId);
    _ios[ownerId] = io;
    return io;
  }

  /// 结果过长时保留头 70% + 尾 30%（尾部的错误栈/总结通常最有用）。
  ///
  /// [maxResultChars] 为 0（默认）时**不截断**：超长结果由 `ToolResultGate` 重定向到
  /// `.self/results/`（送模型的只有提示 + 预览），工具层不能抢先把它砍掉。
  ToolOutcome _truncate(ToolOutcome outcome) {
    final String content = outcome.content;
    if (maxResultChars <= 0 || content.length <= maxResultChars) return outcome;
    final int headLength = (maxResultChars * 0.7).round();
    final int tailLength = maxResultChars - headLength;
    final String head = content.substring(0, headLength);
    final String tail = content.substring(content.length - tailLength);
    final int dropped = content.length - headLength - tailLength;
    log?.call('工具结果过长（${content.length} 字符），已截断 $dropped 字符');
    return ToolOutcome(
      '$head\n…（结果过长，已省略 $dropped 字符）…\n$tail',
      isError: outcome.isError,
    );
  }
}
