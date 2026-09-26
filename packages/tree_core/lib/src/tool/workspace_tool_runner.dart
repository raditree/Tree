import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_local_exec/tree_local_exec.dart';

import '../settings/ssh_config.dart';

import 'builtin_tools.dart';
import 'question_channel.dart';
import 'terminal_hooks.dart';
import 'todo_store.dart';
import 'tool_runner.dart';

/// 按 agent 解析其工作空间目录（绝对路径）。
typedef WorkspaceDirResolver = String Function(String agentId);

/// 工具层实现：把 [ToolInvocation] 落到某个 agent 的工作空间（本地文件系统）。
///
/// - 每个 agent 一个 [WorkspaceIO]，按需创建并缓存（目录首次使用时创建）；
/// - 工具结果统一**截断**：单条工具结果最长 [maxResultChars]，超出保留头 70%
///   + 尾 30% 并显式标注——一次 `terminal` 的输出不该吃掉整个上下文；
/// - 工作空间目录由外部注入（[resolveWorkspaceDir]），因此这里不认识存储层：
///   测试可以直接给一个临时目录。
class WorkspaceToolRunner implements ToolRunner {
  WorkspaceToolRunner({
    required this.resolveWorkspaceDir,
    this.resolveSshConfig,
    this.sshIoFactory,
    this.maxResultChars = 24000,
    this.todoStore,
    this.askQuestion,
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

  /// 单条工具结果的字符上限。
  final int maxResultChars;

  /// 待办存储（为 null 时不声明 `set_todo_list`）。
  final TodoStore? todoStore;

  /// 提问通道（为 null 时不声明 `ask_user_question`）。
  final AskQuestion? askQuestion;

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
  }) => BuiltinTools.specs(
    withTodos: todoStore != null,
    withQuestions: askQuestion != null,
  );

  @override
  Future<ToolOutcome> run(
    ToolInvocation invocation, {
    bool Function()? isCancelled,
  }) async {
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
      withTodos: todoStore != null,
      withQuestions: askQuestion != null,
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
  ToolOutcome _truncate(ToolOutcome outcome) {
    final String content = outcome.content;
    if (content.length <= maxResultChars) return outcome;
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
