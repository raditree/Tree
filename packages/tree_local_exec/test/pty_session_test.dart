import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// ANSI 控制序列（CSI / OSC / 单字符 ESC 序列）。
///
/// 断言前先剥掉：ConPTY 会在文本中间插光标定位（例如 \x1b[4;1H），不剥的话
/// "整行匹配命令输出"会假失败。**这只是测试侧的整理**——库交付的仍是原始字节。
final RegExp _ansi = RegExp(
  r'\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]',
);

/// 收字节的桶：字节原样进，断言时按需解码/剥 ANSI。
class _Sink {
  final List<int> bytes = <int>[];

  /// 宽松解成文本（解码失败不抛：这正是"原始字节"要证明的事）。
  String get text => utf8.decode(bytes, allowMalformed: true);

  /// 剥掉 ANSI 后的可读文本。
  String get plain => text.replaceAll(_ansi, '');

  bool get hasEscape => bytes.contains(0x1b);
}

/// 轮询等待条件成立；超时不抛（由调用方 fail 并带上现场）。
Future<bool> _waitFor(
  _Sink sink,
  bool Function(_Sink sink) ready, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (ready(sink)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}

/// 一条"命令回显之外"的输出行：行首（换行后）就是标记本身。
bool _hasOutputLine(_Sink sink, String marker) =>
    RegExp('[\\r\\n]\\s*${RegExp.escape(marker)}').hasMatch(sink.plain);

/// 字节流里是否含 [needle] 子序列（用于断言 \x1b[ 这类序列没被清洗）。
bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  for (int i = 0; i + needle.length <= haystack.length; i++) {
    bool hit = true;
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// POSIX 后端（系统 script）本仓库开发机跑不到：整组交互用例在非 Windows 上跳过，
/// 只保留编译级保证（见 pty_posix.dart 的取舍说明）。
final String? _posixSkip = Platform.isWindows
    ? null
    : 'POSIX 的 script 后端未在真机验证（本仓库开发机是 Windows）';

/// 伪终端会话（Win10 1809+ 的 ConPTY / POSIX 的 script）。
void main() {
  late Directory temp;
  final List<PtySession> sessions = <PtySession>[];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_pty_test_');
  });

  tearDown(() async {
    // 先还原测试注入点（全局静态），免得污染其它用例
    ptyDebugKernel32Library = 'kernel32.dll';
    for (final PtySession session in sessions) {
      try {
        await session.close();
      } on Object {
        // close 幂等且不该抛；这里只是兜底清理
      }
    }
    sessions.clear();
    for (int i = 0; i < 10 && temp.existsSync(); i++) {
      try {
        temp.deleteSync(recursive: true);
        break;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  /// 起一个会话并把输出接进 [_Sink]。
  Future<_Sink> boot({String command = '', int columns = 80, int rows = 24}) async {
    final PtySession session = await startPtySession(
      command: command,
      workingDirectory: temp.path,
      columns: columns,
      rows: rows,
    );
    sessions.add(session);
    final _Sink sink = _Sink();
    session.output.listen(sink.bytes.addAll);
    return sink;
  }

  test('① 默认 shell：写入 echo 后能在终端输出里看到命令结果', () async {
    final _Sink sink = await boot();
    final PtySession session = sessions.single;
    expect(session.shell, isNotEmpty);

    // 先等 ConPTY/cmd 的 banner（顺便证明"开了就真的有输出"）
    expect(
      await _waitFor(sink, (_Sink s) => s.plain.contains('Microsoft Windows')),
      isTrue,
      reason: '没等到 cmd 横幅；已收到：${sink.plain}',
    );

    const String marker = 'pty-ok-marker';
    await session.write(utf8.encode('echo $marker\r\n'));
    expect(
      await _waitFor(sink, (_Sink s) => _hasOutputLine(s, marker)),
      isTrue,
      reason: '没等到 echo 的结果行（回显不算）；已收到：${sink.plain}',
    );
    expect(sink.plain, contains('echo $marker'), reason: '输入回显也要照实给');
  }, skip: _posixSkip);

  test('② resize 不抛且不崩，之后会话照常工作', () async {
    final _Sink sink = await boot();
    final PtySession session = sessions.single;
    await session.resize(120, 40);
    await session.resize(40, 120);
    // 极端值也要被夹住而不是抛
    await session.resize(0, -5);

    const String marker = 'pty-after-resize';
    await session.write(utf8.encode('echo $marker\r\n'));
    expect(
      await _waitFor(sink, (_Sink s) => _hasOutputLine(s, marker)),
      isTrue,
      reason: '改尺寸后会话不该失效；已收到：${sink.plain}',
    );
  }, skip: _posixSkip);

  test('③ close() 幂等：连调两次不抛，exitCode 会收口', () async {
    final _Sink sink = await boot();
    final PtySession session = sessions.single;
    expect(
      await _waitFor(sink, (_Sink s) => s.bytes.isNotEmpty),
      isTrue,
      reason: '会话起来后应当至少收到 ConPTY 的初始化序列',
    );

    // 进程仍在跑时关：必须能把进程收掉（否则就是孤儿 cmd.exe）
    await session.close();
    await session.close();
    final int code = await session.exitCode.timeout(const Duration(seconds: 15));
    expect(code, isA<int>(), reason: 'close 之后 exitCode 必须有值，不能永久悬着');
  }, skip: _posixSkip);

  test('④ 退出码：exit 3 拿回 3（不是 0）', () async {
    await boot();
    final PtySession session = sessions.single;
    await session.write(utf8.encode('exit 3\r\n'));
    expect(await session.exitCode.timeout(const Duration(seconds: 20)), 3);
  }, skip: _posixSkip);

  test('⑤ 输出是原始字节：ANSI 序列不清洗，非 UTF-8 字节不崩', () async {
    final _Sink sink = await boot();

    // (a) ESC 序列原样交付（ConPTY 自己就会发 \x1b[?25l / \x1b[2J 之类）
    expect(
      await _waitFor(sink, (_Sink s) => s.hasEscape),
      isTrue,
      reason: '没收到任何 ESC 字节：要么输出被清洗了，要么后端不对',
    );
    expect(
      _containsBytes(sink.bytes, <int>[0x1b, 0x5b]),
      isTrue,
      reason: '收到的字节里必须有 CSI 前缀 \x1b[',
    );

    // (b) 往伪终端灌"非法 UTF-8 + 方向键序列"：必须只当字节处理，不抛、不崩
    final PtySession session = sessions.single;
    await session.write(<int>[0xff, 0xfe, 0x1b, 0x5b, 0x41, 0x0d]);

    // (c) 会话仍可继续用：再跑一条命令还能看到结果
    const String marker = 'pty-after-bad-bytes';
    await session.write(utf8.encode('echo $marker\r\n'));
    expect(
      await _waitFor(sink, (_Sink s) => _hasOutputLine(s, marker)),
      isTrue,
      reason: '非 UTF-8 输入之后会话必须还能用；已收到：${sink.plain}',
    );
  }, skip: _posixSkip);

  test('⑥ ConPTY API 缺失：给可读错误，不崩', () async {
    if (!Platform.isWindows) {
      return;
    }
    // 注入一个不存在的库名：真机上装不出"缺符号的 kernel32"，这是唯一确定的复现方式
    ptyDebugKernel32Library = 'definitely-not-a-kernel32-xyz.dll';
    await expectLater(
      startPtySession(workingDirectory: temp.path),
      throwsA(
        isA<PtyUnsupportedException>().having(
          (PtyUnsupportedException e) => e.message,
          'message',
          allOf(contains('ConPTY'), contains('kernel32')),
        ),
      ),
    );
  });

  test('⑥b 命令起不来：给可读错误（带 Win32 错误码），不是静默空会话', () async {
    if (!Platform.isWindows) {
      return;
    }
    await expectLater(
      startPtySession(
        command: 'definitely-no-such-program-xyz.exe',
        workingDirectory: temp.path,
      ),
      throwsA(
        isA<PtySessionException>().having(
          (PtySessionException e) => e.message,
          'message',
          contains('CreateProcessW'),
        ),
      ),
    );
  });

  test(
    '⑦ POSIX：script 后端（未在真机验证，仅编译级保证）',
    () async {
      final _Sink sink = await boot(command: 'echo pty-posix');
      final PtySession session = sessions.single;
      expect(session.shell, contains('echo pty-posix'));
      expect(
        await _waitFor(sink, (_Sink s) => s.plain.contains('pty-posix')),
        isTrue,
        reason: 'script 后端的输出没回来：${sink.plain}',
      );
    },
    skip: Platform.isWindows
        ? 'POSIX 后端在 Windows 上不适用（本用例只在 POSIX 机器上跑）'
        : null,
  );
}
