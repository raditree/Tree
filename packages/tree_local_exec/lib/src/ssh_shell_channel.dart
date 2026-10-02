/// 远端（SSH）**shell 通道**的最小形状：给"远端交互终端"用的双向原始字节流
/// + 窗口尺寸 + 退出码。
///
/// 为什么在这里再定义一个形状，而不是直接用 dartssh2 的 `SSHSession`：
/// - dartssh2 的 API 不好替身化（`SSHSession` 要一个真 channel 才能构造），测试就
///   没法确定性覆盖"写入 / 改尺寸 / 读到输出 / 幂等 close / 退出码收口"这些真正
///   容易出错的语义（本机没有可连的 sshd，真链路只能靠门控集成测试）；
/// - 与 `PtySession`（[pty/pty_session.dart](pty/pty_session.dart)）**同一口径**：
///   输出是**原始字节**（不解码、不清洗 ANSI——终端渲染归前端），这样核心那边的
///   适配器（`packages/tree_core/lib/src/terminal/ssh_pty_adapter.dart`）只是把两个
///   形状对上，不需要再翻译一遍。
///
/// 语义契约（`DartSshTransport` 的实现与各类假实现都必须满足）：
/// - [output] 交付**原始字节**，包括 ANSI 控制序列与非法 UTF-8 字节；空块可以不发；
/// - [write] 把键盘输入原样写进远端 PTY（回车由调用方转成 `\r`）；会话已结束
///   （close 之后）**不抛**，静默丢弃——终端输入是高频操作，为它抛异常只会刷日志；
/// - [resize] 改远端 PTY 的窗口尺寸；
/// - [exitCode] **必须完成，绝不永久悬挂**：远端进程退出、对端关掉会话、链路断开、
///   我们主动 [close]，四条路径都要让这个 future 收口（拿不到退出状态时用 -1）；
/// - [close] **幂等**：已结束再调不抛；且**只关这一条会话通道**，绝不拆整条 SSH
///   连接——SFTP / exec / 文件面板与它共用连接，关个终端不该把它们一起打断；
/// - [shell] 是给界面显示的"实际起了什么"（远端 shell 名字通常不可知，实现可以给
///   一个标注，例如 `ssh`）。
abstract interface class SshShellChannel {
  /// 终端原始输出字节（含 ANSI 控制序列，原样，不清洗、不解码）。
  Stream<List<int>> get output;

  /// 把键盘输入写进远端伪终端（UTF-8 字节；回车由调用方转成 `\r`）。
  Future<void> write(List<int> data);

  /// 改窗口尺寸（列 / 行）。
  Future<void> resize(int columns, int rows);

  /// 远端进程退出码（拿不到退出状态时为 -1）；**任何情况下都要完成**。
  Future<int> get exitCode;

  /// 结束会话（**幂等**，已结束不抛；不关整条 SSH 连接）。
  Future<void> close();

  /// 实际起的 shell / 命令行（界面显示用）。
  String get shell;
}
