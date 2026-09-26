import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

void main() {
  group('CoreToken', () {
    test('生成 256 位熵的 base64url token（无填充、每次不同）', () {
      final String a = CoreToken.generate();
      final String b = CoreToken.generate();
      expect(a, isNot(equals(b)));
      expect(a, isNot(contains('=')));
      expect(a.length, greaterThanOrEqualTo(42));
    });

    test('matches 只在完全相等时为真（含 null 与长度不等）', () {
      const String token = 'abc123';
      expect(CoreToken.matches(token, 'abc123'), isTrue);
      expect(CoreToken.matches(token, 'abc124'), isFalse);
      expect(CoreToken.matches(token, 'abc1234'), isFalse);
      expect(CoreToken.matches(token, 'abc12'), isFalse);
      expect(CoreToken.matches(token, null), isFalse);
      expect(CoreToken.matches(token, ''), isFalse);
    });

    test('matchesAuthorization 只接受 Bearer 前缀', () {
      const String token = 'tok';
      expect(CoreToken.matchesAuthorization(token, 'Bearer tok'), isTrue);
      expect(CoreToken.matchesAuthorization(token, 'Bearer  tok '), isTrue);
      expect(CoreToken.matchesAuthorization(token, 'tok'), isFalse);
      expect(CoreToken.matchesAuthorization(token, 'Basic tok'), isFalse);
      expect(CoreToken.matchesAuthorization(token, null), isFalse);
    });
  });

  group('CoreIds', () {
    test('带前缀且同一毫秒内不重复', () {
      final Set<String> ids = <String>{};
      for (int i = 0; i < 200; i++) {
        final String id = CoreIds.agent();
        expect(id.startsWith('agt_'), isTrue);
        expect(ids.add(id), isTrue, reason: 'id 重复：$id');
      }
    });
  });

  group('JsonTime', () {
    test('ISO 字符串与毫秒整数都能解码，且可往返', () {
      const int ms = 1735689600000;
      final String iso = JsonTime.encode(ms);
      expect(iso, contains('T'));
      expect(JsonTime.decode(iso), ms);
      expect(JsonTime.decode(ms), ms);
      expect(JsonTime.decode('$ms'), ms);
      expect(JsonTime.decode(null), isNull);
      expect(JsonTime.decode('not a time'), isNull);
    });
  });

  group('WsConnection.splitByUtf8Budget', () {
    test('按字节预算切分且拼接后与原文一致', () {
      final String text = 'a' * 100 + '中' * 100 + '\u{1F600}' * 50;
      final List<String> parts = WsConnection.splitByUtf8Budget(text, 32);
      expect(parts.length, greaterThan(1));
      expect(parts.join(), text);
      for (final String part in parts) {
        expect(part.isNotEmpty, isTrue);
      }
    });

    test('不切断代理对（补充平面字符按 4 字节整体切）', () {
      final String emoji = '\u{1F600}'; // 4 字节 / 2 个 UTF-16 码元
      expect(emoji.length, 2);
      final List<String> parts = WsConnection.splitByUtf8Budget(emoji * 4, 4);
      expect(parts.length, 4);
      expect(parts.every((String p) => p == emoji), isTrue);
    });

    test('单码点超过预算时仍推进（不产生死循环）', () {
      final List<String> parts = WsConnection.splitByUtf8Budget('中中', 1);
      expect(parts, <String>['中', '中']);
    });

    test('空串返回单个空片段', () {
      expect(WsConnection.splitByUtf8Budget('', 16), <String>['']);
    });
  });

  group('InboundFrameReassembler', () {
    test('重组 frame_begin/chunk/end 为原始 JSON 文本', () {
      final InboundFrameReassembler reassembler = InboundFrameReassembler();
      final String payload = '{"type":"ping","value":"你好世界"}';
      final List<String> parts = WsConnection.splitByUtf8Budget(payload, 8);
      expect(
        InboundFrameReassembler.isChunkFrame(<String, dynamic>{
          'type': WsOutboundType.frameBegin,
        }),
        isTrue,
      );
      expect(
        reassembler.accept(<String, dynamic>{
          'type': WsOutboundType.frameBegin,
          'id': 'frg_1',
          'total': parts.length,
        }),
        isNull,
      );
      String? complete;
      for (int i = 0; i < parts.length; i++) {
        complete = reassembler.accept(<String, dynamic>{
          'type': WsOutboundType.frameChunk,
          'id': 'frg_1',
          'seq': i,
          'part': parts[i],
        });
      }
      expect(complete, payload);
      expect(reassembler.pendingCount, 0);
    });

    test('无起始帧的残片被丢弃且不抛异常', () {
      final InboundFrameReassembler reassembler = InboundFrameReassembler();
      expect(
        reassembler.accept(<String, dynamic>{
          'type': WsOutboundType.frameChunk,
          'id': 'missing',
          'seq': 0,
          'part': 'x',
        }),
        isNull,
      );
      expect(reassembler.pendingCount, 0);
    });
  });
}
