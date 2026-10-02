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
import 'mcp_tool.dart';
import 'plugin_tool.dart';
import 'question_channel.dart';
import 'terminal_hooks.dart';
import 'todo_store.dart';
import 'tool_runner.dart';

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
    this.mcpService,
    this.pluginBus,
    WorkspaceIO Function(String dir)? ioFactory,
    this.log,
  }) : _ioFactory = ioFactory ?? LocalWorkspaceIO.new {
    hooks = TerminalHooks(log: log);
    hooks.onFinished = _finished;
  }

  /// 后台长任务管理器（terminal 的 hook 模式）。
  late final TerminalHooks hooks;

  /// 后台任务完成回调（CLI 接到 `ConversationService.wake`）。
  void Function(String agentId, String sessionId, String notice)?
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

  /// 消息派发（为 null 时不声明 `message`）。
  final TeamMessageDispatcher? messageDispatcher;

  /// Spec 体系（为 null 时不声明 `spec`）。
  final SpecService? specService;

  /// MCP 服务（为 null 时不声明 `mcp` 与各 MCP 工具）。
  final McpService? mcpService;

  /// 插件总线（为 null 时不声明 `plugin` 与各插件工具）。
  final PluginBus? pluginBus;

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
  }) => <ToolSpec>[
    ...BuiltinTools.specs(
      withTodos: todoStore != null,
      withQuestions: askQuestion != null,
      withTeam: teamService != null,
      withMessage: messageDispatcher != null,
      withSpec: specService != null,
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
        agentId: agentId,
        sessionId: sessionId,
      ),
    ],
  ];

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
  Future<ToolOutcome> _execute(
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
    // 不依赖工作空间的工具（set_todo_list / ask_user_question）先走：工作空间
    // 不可用（SSH 配置不全等）不该连带它们一起失败。
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
    final ToolOutcome outcome = await BuiltinTools.run(
      effective,
      io,
      isCancelled: isCancelled,
      todos: todoStore,
      hooks: hooks,
      askQuestion: askQuestion,
      teamService: teamService,
      messageDispatcher: messageDispatcher,
      specService: specService,
      withTodos: todoStore != null,
      withQuestions: askQuestion != null,
      withTeam: teamService != null,
      withMessage: messageDispatcher != null,
      withSpec: specService != null,
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

  void _finished(HookTask task, int exitCode) {
    final void Function(String, String, String)? callback = onHookFinished;
    if (callback == null) return;
    callback(task.agentId, task.sessionId, hookNotice(task, exitCode));
  }

  /// 供核心层（Spec 索引、待办读取等）复用同一份工作空间缓存：
  /// 解析失败返回 null（调用方决定降级行为）。
  Future<WorkspaceIO?> ioFor(String agentId) => _ioFor(agentId);

  Future<WorkspaceIO?> _ioFor(String agentId) async {
    final WorkspaceIO? cached = _ios[agentId];
    if (cached != null) return cached;

    final SshConfig? ssh = resolveSshConfig?.call(agentId);
    if (ssh != null) {
      final Future<WorkspaceIO> Function(SshConfig config)? factory =
          sshIoFactory;
      if (factory == null) {
        log?.call(
          'agent $agentId 配置了 SSH ${ssh.redacted()}，'
          '但 SSH 执行后端尚未接入（M4b-2）',
        );
        return null;
      }
      if (!ssh.isComplete) {
        log?.call('agent $agentId 的 SSH 配置缺少：${ssh.missingFields.join('、')}');
        return null;
      }
      // 私有状态按 agent 分栏（`.self/…` → `.tree/<agent_id>/.self/…`）：
      // 团队成员与 leader 共享工作目录，但各自的 .self 必须分开（见 PrivateWorkspaceIO）。
      final WorkspaceIO io = PrivateWorkspaceIO(await factory(ssh), agentId);
      _ios[agentId] = io;
      return io;
    }

    final String dir = resolveWorkspaceDir(agentId);
    if (dir.trim().isEmpty) {
      log?.call('agent $agentId 的工作空间目录为空');
      return null;
    }
    try {
      await Directory(dir).create(recursive: true);
    } catch (error) {
      log?.call('创建工作空间失败（$dir）：$error');
      return null;
    }
    // 本机后端同样按 agent 分栏（`.self/…` → `.tree/<agent_id>/.self/…`）。
    final WorkspaceIO io = PrivateWorkspaceIO(_ioFactory(p.normalize(dir)), agentId);
    _ios[agentId] = io;
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
