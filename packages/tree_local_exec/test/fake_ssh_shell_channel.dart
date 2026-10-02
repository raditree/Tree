import 'dart:async';

import 'package:tree_local_exec/tree_local_exec.dart';

/// 假的远端 shell 通道：把 [SshShellChannel] 的**语义契约**变成可断言的记录。
///
/// 为什么需要它：真 dartssh2 的 `SSHSession` 必须有真 channel 才能构造，本机没有
/// 可连的 sshd（真链路由 `test/ssh_integration_test.dart` 的环境变量门控用例覆盖）。
/// 因此"写入字节 / 改尺寸 / 读到输出 / 幂等 close / exitCode 一定收口 / close 不关
/// 整条连接"这些真正容易出错的语义，靠这份假通道做确定性验证；真实现
/// （`dartssh_transport.dart` 的 `_DartSshShellChannel`）按同一份契约写。
class FakeSshShellChannel implements SshShellChannel {
  FakeSshShellChannel({this.shell = 'fake-ssh'});

  @override
  final String shell;

  final StreamController<List<int>> _out = StreamController<List<int>>();

  final Completer<int> _exit = Completer<int>();

  /// 写进来的**原始字节**（按调用顺序，未解码）。
  final List<List<int>> writes = <List<int>>[];

  /// 收到的窗口尺寸（列, 行）。
  final List<(int, int)> resizes = <(int, int)>[];

  /// [close] 被调用的次数：用来断言"第二次 close 不抛、也不再动状态"。
  int closeCount = 0;

  bool _closed = false;

  bool get isClosed => _closed;

  @override
  Stream<List<int>> get output => _out.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> write(List<int> data) async {
    // 契约：会话已结束不抛，静默丢弃（终端输入是高频操作）。
    if (_closed) return;
    writes.add(List<int>.of(data));
  }

  @override
  Future<void> resize(int columns, int rows) async {
    if (_closed) return;
    resizes.add((columns, rows));
  }

  @override
  Future<void> close() async {
    closeCount++;
    if (_closed) return; // 幂等：已结束不抛
    _closed = true;
    // 主动关掉**不会**让 exitCode 悬挂：拿不到远端退出状态就给 -1。
    if (!_exit.isCompleted) _exit.complete(-1);
    // 不 await：单订阅 StreamController 在**没人监听**时 close() 的 future 永不完成
    // （实测确认），await 会把测试与真实 close 一起挂住。真实现同样不能 await。
    if (!_out.isClosed) unawaited(_out.close());
  }

  /// 灌一块**原始**输出（ANSI 控制序列 / 非法 UTF-8 由调用方自己造字节）。
  void emit(List<int> bytes) {
    if (!_out.isClosed) _out.add(bytes);
  }

  /// 远端进程退出：退出码收口（真实现由 `exit-status` 触发；被信号杀死时为 -1）。
  void finish(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }
}
