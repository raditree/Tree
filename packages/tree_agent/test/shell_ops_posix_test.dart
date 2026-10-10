import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent/tree_agent.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'support.dart';

/// 目标机有没有 util-linux 的 `script`（没有就 skip —— **不删断言**）。
bool scriptAvailable() {
  if (Platform.isWindows) return false;
  try {
    return Process.runSync('/bin/sh', <String>[
      '-c',
      'command -v script >/dev/null 2>&1',
    ]).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  final String? skipReason = Platform.isWindows
      ? 'POSIX 专属（script -qec 真 PTY）：Windows 开发机跳过，'
            'M7 用交叉编译的 Linux 二进制真跑'
      : (scriptAvailable()
            ? null
            : '本机没有 util-linux 的 script 命令 ⇒ POSIX PTY 用例跳过（不删断言）');

  late Directory root;
  late String rootPath;
  late List<Map<String, dynamic>> notifications;
  late ShellOps shells;

  setUp(() {
    root = createTempRoot('shell_posix');
    rootPath = toPosix(root.path);
    notifications = <Map<String, dynamic>>[];
    shells = ShellOps(
      guard: PathGuard(rootPath),
      root: rootPath,
      notify: (String method, Map<String, dynamic> params) async {
        notifications.add(<String, dynamic>{'method': method, 'params': params});
      },
    );
  });

  tearDown(() => removeTempRoot(root));

  List<int> dataOf(String shellId) => <int>[
    for (final Map<String, dynamic> n in notifications)
      if (n['method'] == AgentMethods.shellData &&
          (n['params'] as Map<String, dynamic>)['shell_id'] == shellId)
        ...base64Decode((n['params'] as Map<String, dynamic>)['data'] as String),
  ];

  int? exitCodeOf(String shellId) {
    for (final Map<String, dynamic> n in notifications) {
      if (n['method'] == AgentMethods.shellExit &&
          (n['params'] as Map<String, dynamic>)['shell_id'] == shellId) {
        return (n['params'] as Map<String, dynamic>)['exit_code'] as int?;
      }
    }
    return null;
  }

  Future<void> waitFor(bool Function() predicate, String what) async {
    final Stopwatch watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 15)) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('等待「$what」超时；已收到的通知：$notifications');
  }

  group('shell.*（POSIX，script 后端）', () {
    test('open 起真 PTY；输出是原始字节；exit 收口到命令的退出码', () async {
      final Map<String, dynamic> opened = await shells.open(<String, dynamic>{
        'command': 'echo hello-from-pty; exit 3',
        'columns': 80,
        'rows': 24,
      });
      expect(opened['pty'], true);
      final String shellId = opened['shell_id'] as String;

      await waitFor(
        () => exitCodeOf(shellId) != null,
        'shell.exit',
      );
      expect(exitCodeOf(shellId), 3);
      expect(utf8.decode(dataOf(shellId)), contains('hello-from-pty'));

      // close 幂等
      expect(await shells.close(<String, dynamic>{'shell_id': shellId}), <String, dynamic>{});
      expect(await shells.close(<String, dynamic>{'shell_id': shellId}), <String, dynamic>{});
    });

    test('shell.write 把字节写进 PTY 的 stdin（cat 回显）', () async {
      final Map<String, dynamic> opened = await shells.open(<String, dynamic>{
        'command': 'cat',
        'columns': 80,
        'rows': 24,
      });
      final String shellId = opened['shell_id'] as String;

      await shells.write(<String, dynamic>{
        'shell_id': shellId,
        'data': base64Encode(utf8.encode('ping-pong\n')),
      });
      await waitFor(
        () => utf8.decode(dataOf(shellId), allowMalformed: true).contains('ping-pong'),
        'cat 回显到 shell.data',
      );
      await shells.close(<String, dynamic>{'shell_id': shellId});
    });

    test('close 主动关会话 ⇒ shell.exit 仍然收口（拿不到状态就给 -1）', () async {
      final Map<String, dynamic> opened = await shells.open(<String, dynamic>{
        'command': 'sleep 30',
        'columns': 80,
        'rows': 24,
      });
      final String shellId = opened['shell_id'] as String;

      await shells.close(<String, dynamic>{'shell_id': shellId});
      await waitFor(() => exitCodeOf(shellId) != null, 'close 之后的 shell.exit');
      expect(exitCodeOf(shellId), isNotNull);
    });

    test('resize 回 {supported:false} 且不抛', () async {
      final Map<String, dynamic> opened = await shells.open(<String, dynamic>{
        'command': 'sleep 30',
        'columns': 80,
        'rows': 24,
      });
      final String shellId = opened['shell_id'] as String;
      expect(
        await shells.resize(<String, dynamic>{
          'shell_id': shellId,
          'columns': 120,
          'rows': 40,
        }),
        <String, dynamic>{'supported': false},
      );
      await shells.close(<String, dynamic>{'shell_id': shellId});
    });
  }, skip: skipReason);
}
