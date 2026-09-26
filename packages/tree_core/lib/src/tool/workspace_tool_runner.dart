import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_local_exec/tree_local_exec.dart';

import '../settings/ssh_config.dart';

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
    // MCP 工具（含命名空间工具）不经 BuiltinTools 的 switch：它们的名字是
    // 动态的，且同样不依赖工作空间。
    final McpService? mcp = mcpService;
    if (mcp != null && McpTool.handles(invocation.name)) {
      return _truncate(await McpTool.run(invocation, mcp));
    }
    final PluginBus? plugins = pluginBus;
    if (plugins != null && PluginTool.handles(invocation.name)) {
      return _truncate(await PluginTool.run(invocation, plugins));
    }
    // 不依赖工作空间的工具（set_todo_list / ask_user_question）先走：工作空间
    // 不可用（SSH 配置不全等）不该连带它们一起失败。
    WorkspaceIO? io;
    if (BuiltinTools.needsWorkspace(invocation.name)) {
      io = await _ioFor(invocation.agentId);
      if (io == null) {
        return ToolOutcome(
          '无法准备工作空间：${invocation.agentId} 的工作目录不可用，'
          '或 SSH 配置不完整/尚未接入（详见核心日志）',
          isError: true,
        );
      }
    }
    final ToolOutcome outcome = await BuiltinTools.run(
      invocation,
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
      final WorkspaceIO io = await factory(ssh);
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
    final WorkspaceIO io = _ioFactory(p.normalize(dir));
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
