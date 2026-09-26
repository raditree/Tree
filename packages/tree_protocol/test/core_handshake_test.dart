import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

void main() {
  group('CoreHandshake', () {
    const CoreHandshake handshake = CoreHandshake(
      port: 54321,
      token: 'abc-DEF_123',
      pid: 4321,
      version: '0.1.0',
    );

    test('派生出的 HTTP/WS 基址符合前端 baseUrl 约定', () {
      expect(handshake.httpBaseUrl, 'http://127.0.0.1:54321');
      expect(handshake.wsBaseUrl, 'ws://127.0.0.1:54321');
    });

    test('encode/decode 往返（单行 JSON，可逐行读取）', () {
      final String line = handshake.encode();
      expect(line.contains('\n'), isFalse, reason: '必须是单行，父进程按行解析');
      final CoreHandshake? restored = CoreHandshake.decode(line);
      expect(restored, isNotNull);
      expect(restored!.port, handshake.port);
      expect(restored.token, handshake.token);
      expect(restored.pid, handshake.pid);
      expect(restored.version, handshake.version);
      expect(restored.host, '127.0.0.1');
    });

    test('decode 对非握手输入一律返回 null（父进程可继续读下一行）', () {
      expect(CoreHandshake.decode(''), isNull);
      expect(CoreHandshake.decode('   '), isNull);
      expect(CoreHandshake.decode('starting tree_core ...'), isNull);
      expect(CoreHandshake.decode('[1,2,3]'), isNull);
      expect(
        CoreHandshake.decode('{"event":"other","port":1,"token":"t"}'),
        isNull,
      );
      expect(
        CoreHandshake.decode('{"event":"ready","port":0,"token":"t"}'),
        isNull,
      );
      expect(
        CoreHandshake.decode('{"event":"ready","port":1,"token":""}'),
        isNull,
      );
      expect(CoreHandshake.decode('{"event":"ready","port":1}'), isNull);
    });

    test('decode 容忍额外字段与缺省 host（向前兼容）', () {
      final CoreHandshake? restored = CoreHandshake.decode(
        jsonEncode(<String, dynamic>{
          'event': CoreHandshake.readyEvent,
          'port': 8080,
          'token': 'tok',
          'pid': 1,
          'version': '1.2.3',
          'extra': <String>['future', 'field'],
        }),
      );
      expect(restored, isNotNull);
      expect(restored!.host, '127.0.0.1');
      expect(restored.port, 8080);
    });
  });

  group('分帧参数', () {
    test('阈值与分片预算互相自洽，且类型名与下行常量一致', () {
      expect(kWsFrameChunkPartBytes, lessThan(kWsFrameChunkThresholdBytes));
      expect(kWsFrameChunkTtl, greaterThan(Duration.zero));
      expect(WsOutboundType.frameChunking, <String>{
        WsOutboundType.frameBegin,
        WsOutboundType.frameChunk,
        WsOutboundType.frameEnd,
      });
    });
  });
}
