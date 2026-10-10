import 'package:test/test.dart';
import 'package:tree_agent/tree_agent.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

void main() {
  group('PathGuard（越界防护，协议 §4）', () {
    final PathGuard guard = PathGuard('/home/u/ws');

    test('root 之内（含 root 自身）放行，并归一化', () {
      expect(guard.check('/home/u/ws/a/b.txt'), '/home/u/ws/a/b.txt');
      expect(guard.check('/home/u/ws'), '/home/u/ws');
      expect(guard.check('/home/u/ws/./a//b'), '/home/u/ws/a/b');
      // `..` 只要没逃出去就合法
      expect(guard.check('/home/u/ws/a/../b'), '/home/u/ws/b');
      // root 自己也归一化
      expect(PathGuard('/home/u/ws/').root, '/home/u/ws');
    });

    test('逃出 root ⇒ -32001 path_out_of_root，消息里带上那个路径', () {
      for (final String bad in <String>[
        '/home/u/ws/../other',
        '/home/u/ws2/x', // 前缀兄弟目录：绝不能被 startsWith 蒙混
        '/home/u',
        '/etc/passwd',
        '/',
        'relative/../../escape',
      ]) {
        expect(
          () => guard.check(bad),
          throwsA(
            isA<RpcException>()
                .having(
                  (RpcException e) => e.code,
                  'code',
                  TunnelErrorCodes.pathOutOfRoot,
                )
                .having((RpcException e) => e.message, 'message', contains(bad)),
          ),
          reason: '应拒绝：$bad',
        );
      }
    });

    test('路径参数不是字符串 / 空串 ⇒ invalidParams', () {
      expect(
        () => guard.check(null),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            RpcCodes.invalidParams,
          ),
        ),
      );
      expect(
        () => guard.check(42),
        throwsA(isA<RpcException>()),
      );
    });

    test('label 出现在错误消息里（便于定位是 from / to / log_path / cwd）', () {
      expect(
        () => guard.check('/elsewhere', label: 'log_path'),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.message,
            'message',
            contains('log_path'),
          ),
        ),
      );
    });

    test('破坏性操作额外挡住 root 自身（一次 RPC 删库的路必须堵死）', () {
      expect(guard.checkDestructiveTarget('/home/u/ws/a'), '/home/u/ws/a');
      expect(
        () => guard.checkDestructiveTarget('/home/u/ws'),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.pathOutOfRoot,
          ),
        ),
      );
    });
  });

  group('POSIX 路径助手（本包不引 package:path）', () {
    test('posixDirname / posixBasename', () {
      expect(posixDirname('/a/b/c.txt'), '/a/b');
      expect(posixDirname('/a'), '/');
      expect(posixDirname('a'), '.');
      expect(posixBasename('/a/b/c.txt'), 'c.txt');
      expect(posixBasename('/a/b/'), 'b');
      expect(posixBasename('a'), 'a');
    });

    test('posixQuote 转义裸单引号', () {
      expect(posixQuote('/a/b'), "'/a/b'");
      expect(posixQuote("a'b"), r"'a'\''b'");
    });
  });
}
