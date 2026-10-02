import 'dart:async';

/// 伪终端会话的**最小接口**。
///
/// 为什么在核心这一侧再定义一个形状，而不是直接用 tree_local_exec 的类型：
/// 平台实现（Windows ConPTY / POSIX pty）是最难移植、最该被换掉的一层，核心只依赖
/// 这个形状就能**独立编译与单测**（测试注入假实现，不依赖真 PTY），换平台实现也
/// 不用动核心。真正的实现由 CLI 构造时注入（见 [PtyStarter]）。
abstract interface class PtyProcess {
  /// 终端原始输出字节（含 ANSI 控制序列，原样，不清洗、不解码）
  Stream<List<int>> get output;

  /// 把键盘输入写进伪终端（UTF-8 字节；回车由调用方转成 \r）
  Future<void> write(List<int> data);

  /// 改窗口尺寸（列 / 行）
  Future<void> resize(int columns, int rows);

  /// 进程退出码（会话被主动关掉时也应完成，不许永久悬挂）
  Future<int> get exitCode;

  /// 结束会话：关掉进程与伪终端（**幂等**，已结束也不许抛）
  Future<void> close();

  /// 实际起的 shell / 命令行（界面显示用）
  String get shell;
}

/// 起一个伪终端会话的工厂（CLI 注入平台实现；测试注入假实现）
typedef PtyStarter = Future<PtyProcess> Function({
  required String command,
  required String workingDirectory,
  required int columns,
  required int rows,
});
