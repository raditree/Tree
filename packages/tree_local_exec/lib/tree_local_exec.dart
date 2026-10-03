/// 本机执行原语（M4 落地）。
///
/// 迁移来源：`lib/io/local_executor_service.dart`（1663 行）与
/// `lib/io/ssh_workspace_executor.dart`（1375 行）中**与 Flutter 无关**的部分。
///
/// 在 desktop 分支里这些原语**直接由核心进程调用**（核心就跑在用户机器上），
/// 不再需要"核心 → 前端反向 WS → 前端执行"的往返：因此 `tool_exec_request` /
/// `tool_exec_response` 那套反向协议与前端两个执行器服务都成了多余（M7 清理）。
library;

export 'src/ansi_code_page.dart';
export 'src/dartssh_transport.dart';
export 'src/git_output.dart';
export 'src/local_workspace_io.dart';
export 'src/pty/pty_session.dart';
export 'src/ssh_liveness.dart';
export 'src/ssh_login_shell.dart';
export 'src/ssh_shell_channel.dart';
export 'src/ssh_workspace_io.dart';
export 'src/shell.dart';
export 'src/windows_environment.dart';
export 'src/workspace_io.dart';

/// 本机执行后端分组（本地 / SSH 均已实现：SSH 走 dartssh2 + SFTP/exec）。
abstract final class TreeLocalExec {
  /// 当前已实现的后端分组数（local / ssh）。
  static const int backendCount = 2;

  /// 工作空间 IO 原语名（与 [WorkspaceIO] 的方法一一对应）。
  static const List<String> ioPrimitives = <String>[
    'read_file',
    'write_file',
    'edit_file',
    'grep_search',
    'list_files',
    'exec_shell',
    'git_log',
    'git_branches',
    'git_status',
  ];

  /// 内置工具名（工具层声明用；team/message/spec/ask_user_question 属 M5，mcp 属 M6）。
  static const List<String> builtinToolNames = <String>[
    'read',
    'write',
    'edit',
    'grep',
    'terminal',
  ];
}
