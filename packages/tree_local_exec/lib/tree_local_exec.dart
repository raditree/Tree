/// 本机执行原语（M0b 骨架，M4 落实现）。
///
/// 迁移来源：`lib/io/local_executor_service.dart`（1663 行）与
/// `lib/io/ssh_workspace_executor.dart`（1375 行）中**与 Flutter 无关**的部分——
/// 重点是 Windows 下已踩过坑的细节，必须原样保留：
/// - cmd/bash 选择与 WSL/Unix 风格目录判定（`isUnixLikePath` / `resolveShellForDir`）；
/// - `chcp.com 65001` 前缀（cmd 内置命令输出 UTF-8）；
/// - 严格 UTF-8 → latin1 回退解码（不抛异常）；
/// - grep 命中行**发送端**截断（避免超帧被静默断连）。
library;

/// 本机执行后端分组（M0b 占位，M4 拆分为 local / ssh 两个实现）。
abstract final class TreeLocalExec {
  /// 当前已实现的后端分组数。
  static const int backendCount = 2;

  /// 工作空间 IO 原语名（与 server `WorkspaceIO` 抽象一一对应）。
  static const List<String> ioPrimitives = <String>[
    'read_file',
    'write_file',
    'read_file_base64',
    'write_file_base64',
    'exec_shell',
    'exec_shell_hook',
    'cancel_exec_hook',
    'exec_argv',
    'grep_search',
    'git_log',
    'git_branches',
    'list_files',
  ];
}
