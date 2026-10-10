import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent/tree_agent.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'support.dart';

void main() {
  late Directory root;
  late String rootPath;
  late List<Map<String, dynamic>> notifications;
  late ShellOps shells;

  setUp(() {
    root = createTempRoot('shell');
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

  group('shell.* 的能力缺口如实报（不变量 8 / 9）', () {
    test('resize 恒回 {supported:false} 且**不抛**（script 不暴露 TIOCSWINSZ）', () async {
      expect(
        await shells.resize(<String, dynamic>{
          'shell_id': 'whatever',
          'columns': 120,
          'rows': 40,
        }),
        <String, dynamic>{'supported': false},
      );
    });

    test('close **幂等**：未知 id / 缺 id 都回 {} 不抛（且不牵连别的）', () async {
      expect(await shells.close(<String, dynamic>{'shell_id': 'nope'}), <String, dynamic>{});
      expect(await shells.close(<String, dynamic>{}), <String, dynamic>{});
      expect(
        await shells.close(<String, dynamic>{'shell_id': 'nope'}),
        <String, dynamic>{},
        reason: '第二次同样成功',
      );
    });

    test('write 到不存在的会话 ⇒ not_found（不静默吞掉）', () async {
      expect(
        () => shells.write(<String, dynamic>{
          'shell_id': 'nope',
          'data': base64Encode(<int>[1]),
        }),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.notFound,
          ),
        ),
      );
    });

    test('write 的 data 不是合法 base64 ⇒ invalidParams', () async {
      expect(
        () => shells.write(<String, dynamic>{
          'shell_id': 'nope',
          'data': '!!!',
        }),
        throwsA(isA<RpcException>()),
      );
    });

    test('shell.open 的 cwd 先过越界 / 存在性检查', () async {
      expect(
        () => shells.open(<String, dynamic>{
          'command': '',
          'cwd': '/definitely/outside',
          'columns': 80,
          'rows': 24,
        }),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.pathOutOfRoot,
          ),
        ),
      );
      expect(
        () => shells.open(<String, dynamic>{
          'command': '',
          'cwd': '$rootPath/nope',
          'columns': 80,
          'rows': 24,
        }),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.notFound,
          ),
        ),
      );
    });

    test(
      '目标机没有 script ⇒ **-32006 pty_unsupported**（绝不静默降级成无 TTY exec）',
      // 只在"确实没有 script"的开发机上有效（Linux 上 script 存在，这条不该跑）。
      skip: Platform.isWindows
          ? null
          : '本用例验的是"目标机没有 script"这一面：Linux 上 script 存在 ⇒ 跳过',
      () async {
        await expectLater(
          shells.open(<String, dynamic>{'columns': 80, 'rows': 24}),
          throwsA(
            isA<RpcException>().having(
              (RpcException e) => e.code,
              'code',
              TunnelErrorCodes.ptyUnsupported,
            ),
          ),
        );
        expect(notifications, isEmpty, reason: '没开成就不该有任何 shell.data / shell.exit');
      },
    );
  });
}
