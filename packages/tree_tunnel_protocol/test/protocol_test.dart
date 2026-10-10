import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

void main() {
  group('帧编解码', () {
    test('encodeFrame 产出单行 UTF-8 + \\n', () {
      final Uint8List bytes = encodeFrame(<String, dynamic>{'a': 1, 'b': '中文'});
      final String text = utf8.decode(bytes);
      expect(text.endsWith('\n'), isTrue);
      expect('\n'.allMatches(text).length, 1);
      expect(jsonDecode(text.trim()), <String, dynamic>{'a': 1, 'b': '中文'});
    });

    test('超过上限的帧抛 FrameTooLargeException', () {
      final String big = 'x' * (kMaxFrameBytes + 10);
      expect(
        () => encodeFrame(<String, dynamic>{'d': big}),
        throwsA(isA<FrameTooLargeException>()),
      );
    });

    test('分片喂入也能切出一帧', () {
      final List<Map<String, dynamic>> got = <Map<String, dynamic>>[];
      final LineFrameDecoder decoder = LineFrameDecoder(onFrame: got.add);
      final Uint8List frame = encodeFrame(<String, dynamic>{'id': 1, 'method': 'a'});
      decoder.add(frame.sublist(0, 3));
      decoder.add(frame.sublist(3, 7));
      decoder.add(frame.sublist(7));
      expect(got, hasLength(1));
      expect(got.single['method'], 'a');
    });

    test('一次喂入多帧全部切出，空行被跳过', () {
      final List<Map<String, dynamic>> got = <Map<String, dynamic>>[];
      final LineFrameDecoder decoder = LineFrameDecoder(onFrame: got.add);
      final List<int> buf = <int>[
        ...encodeFrame(<String, dynamic>{'id': 1}),
        ...utf8.encode('\n'),
        ...encodeFrame(<String, dynamic>{'id': 2}),
      ];
      decoder.add(buf);
      expect(got.map((Map<String, dynamic> m) => m['id']), <int>[1, 2]);
    });

    test('行尾 \\r 被容忍', () {
      final List<Map<String, dynamic>> got = <Map<String, dynamic>>[];
      final LineFrameDecoder decoder = LineFrameDecoder(onFrame: got.add);
      decoder.add(utf8.encode('{"id":7}\r\n'));
      expect(got.single['id'], 7);
    });

    test('坏帧只报错，读循环继续', () {
      final List<Map<String, dynamic>> got = <Map<String, dynamic>>[];
      final List<String> errors = <String>[];
      final LineFrameDecoder decoder = LineFrameDecoder(
        onFrame: got.add,
        onError: errors.add,
      );
      decoder.add(utf8.encode('not json\n{"id":3}\n'));
      expect(errors, hasLength(1));
      expect(got.single['id'], 3);
    });

    test('超长行被丢弃，后续帧不受影响', () {
      final List<Map<String, dynamic>> got = <Map<String, dynamic>>[];
      final List<String> errors = <String>[];
      final LineFrameDecoder decoder = LineFrameDecoder(
        maxFrameBytes: 64,
        onFrame: got.add,
        onError: errors.add,
      );
      // 一条 200 字节的行（没有换行），逐段喂；随后是正常帧
      final List<int> oversized = utf8.encode('{"pad":"${'y' * 200}"}');
      decoder.add(oversized.sublist(0, 120));
      decoder.add(oversized.sublist(120));
      decoder.add(utf8.encode('\n{"id":9}\n'));
      expect(errors, isNotEmpty);
      expect(got.single['id'], 9);
    });

    test('reset 丢弃半个帧', () {
      final List<Map<String, dynamic>> got = <Map<String, dynamic>>[];
      final List<String> errors = <String>[];
      final LineFrameDecoder decoder = LineFrameDecoder(
        onFrame: got.add,
        onError: errors.add,
      );
      // 半个帧（前缀）先入缓冲 → 通道重建 → reset
      decoder.add(utf8.encode('{"id":1'));
      decoder.reset();
      // 新通道上的第一条完整帧：若 reset 没生效，缓冲会拼成 `{"id":1{"id":2}` 而解析失败
      decoder.add(utf8.encode('{"id":2}\n'));
      expect(errors, isEmpty);
      expect(got.map((Map<String, dynamic> m) => m['id']), <int>[2]);
    });
  });

  group('RPC 构造与解包', () {
    test('request / notification / result / error 形状', () {
      expect(rpcRequest(1, 'm')['id'], 1);
      expect(rpcRequest(1, 'm').containsKey('params'), isFalse);
      expect(rpcNotification('m').containsKey('id'), isFalse);
      expect(rpcResult(1, <String, dynamic>{'ok': true})['result'], isA<Map>());
      final Map<String, dynamic> err = rpcErrorResult(2, TunnelErrorCodes.notFound, '没了');
      expect((err['error'] as Map)['code'], TunnelErrorCodes.notFound);
    });

    test('rpcUnwrap 正常取值 / 带 error 抛 RpcException', () {
      expect(rpcUnwrap(<String, dynamic>{'id': 1, 'result': 5}), 5);
      expect(
        () => rpcUnwrap(<String, dynamic>{
          'id': 1,
          'error': <String, dynamic>{'code': -32002, 'message': 'x'},
        }),
        throwsA(
          isA<RpcException>()
              .having((RpcException e) => e.code, 'code', TunnelErrorCodes.notFound)
              .having((RpcException e) => e.message, 'message', 'x'),
        ),
      );
    });

    test('帧分类', () {
      expect(RpcIds.isResponse(<String, dynamic>{'id': 1, 'result': null}), isTrue);
      expect(RpcIds.isRequest(<String, dynamic>{'id': 1, 'method': 'm'}), isTrue);
      expect(RpcIds.isNotification(<String, dynamic>{'method': 'm'}), isTrue);
      expect(RpcIds.isNotification(<String, dynamic>{'id': 1, 'method': 'm'}), isFalse);
    });

    test('shouldFallbackForErrorKind：可回退 vs 不可回退', () {
      expect(shouldFallbackForErrorKind(TunnelErrorKinds.handshakeFailed), isTrue);
      expect(shouldFallbackForErrorKind(TunnelErrorKinds.tunnelDown), isTrue);
      expect(shouldFallbackForErrorKind(TunnelErrorKinds.agentUnreachable), isTrue);
      expect(shouldFallbackForErrorKind(TunnelErrorKinds.configIncomplete), isFalse);
      expect(shouldFallbackForErrorKind('  push_failed  '), isTrue);
    });

    test('describeRpcCode 覆盖每个专用码（都有人话）', () {
      for (final int code in <int>[
        TunnelErrorCodes.pathOutOfRoot,
        TunnelErrorCodes.notFound,
        TunnelErrorCodes.alreadyExists,
        TunnelErrorCodes.notEmpty,
        TunnelErrorCodes.parentMissing,
        TunnelErrorCodes.ptyUnsupported,
        TunnelErrorCodes.handshakeFailed,
        TunnelErrorCodes.protocolMismatch,
        TunnelErrorCodes.permissionDenied,
        TunnelErrorCodes.execFailed,
        TunnelErrorCodes.frameTooLarge,
        TunnelErrorCodes.busy,
      ]) {
        expect(describeRpcCode(code), isNot(contains('未知错误')));
      }
    });
  });

  group('路径归一化与越界判定', () {
    test('normalizePosixPath 与 p.posix.normalize 一致的关键用例', () {
      expect(normalizePosixPath('/a/b/../c'), '/a/c');
      expect(normalizePosixPath('/a//b/./c/'), '/a/b/c');
      expect(normalizePosixPath('/../a'), '/a');
      expect(normalizePosixPath('a/../../b'), '../b');
      expect(normalizePosixPath(''), '.');
      expect(normalizePosixPath('/'), '/');
    });

    test('isWithinRoot：等于是、前缀是、兄弟不是、逃逸不是', () {
      expect(isWithinRoot('/root', '/root'), isTrue);
      expect(isWithinRoot('/root/a/b', '/root'), isTrue);
      expect(isWithinRoot('/root2/a', '/root'), isFalse);
      expect(isWithinRoot('/root/../etc/passwd', '/root'), isFalse);
      expect(isWithinRoot('/etc/passwd', '/root'), isFalse);
      expect(isWithinRoot('/root/./a/../b', '/root'), isTrue);
    });
  });
}
