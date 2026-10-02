/// 可交互**伪终端（PTY）**会话：给"真终端"用的双向字节流 + 窗口尺寸控制。
///
/// 与 `WorkspaceIO.exec`（[../workspace_io.dart](../workspace_io.dart) 定义的**一次性执行**）
/// 是**互补**的两条路径，别混用：
/// - `exec`：命令跑完才回包，没有 TTY——`vim` / `top` / 需要 `Ctrl+C` 的程序在里面根本用不了；
/// - `PtySession`（本文件）：持续双向的**原始字节**流 + 改尺寸 + 退出码，交互式程序照常工作。
///
/// 设计要点：
/// - **输出是原始字节**（`Stream<List<int>>`）：不解码、不清洗 ANSI——终端渲染归前端；
/// - **后端按平台分**：Windows 走 ConPTY（[conpty_windows.dart]），POSIX 走系统 `script`
///   （[pty_posix.dart]）；两条实现背后的取舍都写在各自文件头部；
/// - **拿不到后端就报可读错误**（[PtyUnsupportedException]），**不静默降级**成无 TTY 的
///   一次性执行——那会让 vim/top 直接坏掉，比明确报错更难排查。
library;

import 'dart:io';

import 'conpty_windows.dart';
import 'pty_posix.dart';

/// PTY 会话本身失败（起不来 / 写不进 / 状态已关闭）。
class PtySessionException implements Exception {
  PtySessionException(this.message);

  /// 可读原因（中文，直接给日志/界面看）。
  final String message;

  @override
  String toString() => 'PTY 会话失败：$message';
}

/// 平台或系统**缺少可用的 PTY 后端**（ConPTY API 缺失 / POSIX 没有 `script` /
/// 当前平台没有实现）。
///
/// 与 [PtySessionException] 分开：这一类是"这台机器上根本做不了伪终端"，
/// 调用方据此决定是提示用户还是退回别的功能；另一类是"这次会话出了错"。
class PtyUnsupportedException extends PtySessionException {
  PtyUnsupportedException(super.message);

  @override
  String toString() => 'PTY 后端不可用：$message';
}

/// 一个跑在伪终端里的会话（交互式：能收键盘、能改尺寸、能拿退出码）。
abstract interface class PtySession {
  /// 终端原始输出字节（含 ANSI 控制序列，原样，不要解码/清洗）。
  Stream<List<int>> get output;

  /// 把键盘输入写进伪终端（UTF-8 字节；调用方负责把回车变成 `\r`）。
  Future<void> write(List<int> data);

  /// 改窗口尺寸（列/行）。
  ///
  /// 后端不支持改尺寸时（POSIX 的 `script` 分支）**只记日志、不抛**：
  /// 尺寸变化是高频且可被下一次覆盖的操作，为它中断终端反而更糟。
  Future<void> resize(int columns, int rows);

  /// 进程结束时的退出码。
  Future<int> get exitCode;

  /// 结束会话：关掉进程与伪终端句柄（幂等；已经结束也不许抛）。
  Future<void> close();

  /// 实际起的 shell / 命令行（给界面显示）。
  String get shell;
}

/// 诊断与测试注入点：Windows 上 ConPTY 入口从哪个动态库解析（默认 `kernel32.dll`）。
///
/// 把它换成**不存在的库名**（或缺少 ConPTY 符号的库）就能确定性地覆盖
/// 「API 缺失 → 可读错误，不崩」这条路径——真机上装不出"缺符号的 kernel32"。
/// 生产代码不设置它（保持默认）。**全局可变**：测试里用完必须复原。
String ptyDebugKernel32Library = 'kernel32.dll';

/// 起一个伪终端会话。
///
/// [command] 为空时用平台默认 shell（Windows：`cmd.exe`；POSIX：`$SHELL` 或 `/bin/sh`）。
/// [workingDirectory] 不存在会被创建（与 `WorkspaceIO.exec` 同一口径）。
/// [environment] 为 null = **继承**父进程环境；非空 = 在父进程环境之上**叠加/覆盖**。
///
/// 失败一律抛 [PtySessionException]（可读中文）；后端缺失抛 [PtyUnsupportedException]。
Future<PtySession> startPtySession({
  String command = '',
  required String workingDirectory,
  int columns = 80,
  int rows = 24,
  Map<String, String>? environment,
  void Function(String message)? log,
}) {
  if (Platform.isWindows) {
    return startConPtySession(
      command: command,
      workingDirectory: workingDirectory,
      columns: columns,
      rows: rows,
      environment: environment,
      log: log,
      kernel32Library: ptyDebugKernel32Library,
    );
  }
  return startPosixPtySession(
    command: command,
    workingDirectory: workingDirectory,
    columns: columns,
    rows: rows,
    environment: environment,
    log: log,
  );
}
