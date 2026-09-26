import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// [WsStreamSeq]：流式增量帧的**单调序号**字段契约（M9 断线补发帧重播去重）。
///
/// 这里冻结的是**跨端契约**：字段名、序号起点，以及"缺字段 / 非法值 = 未知"的
/// 老核心兼容口径。核心产出与前端判重都必须走本类，不得各写一份字面量
/// （完备性门禁另有断言）。
void main() {
  group('WsStreamSeq 字段契约', () {
    test('字段名与序号起点冻结：seq / 0', () {
      // 线上字段名一旦漂移，前端去重会**静默失效**（退回 id 级判据，重复渲染），
      // 所以把字面量钉死在协议包里。
      expect(WsStreamSeq.field, 'seq');
      expect(WsStreamSeq.firstSeq, 0);
    });

    test('读取：合法序号原样返回（0 是合法值，不是"缺失"）', () {
      expect(WsStreamSeq.of(<String, dynamic>{'seq': 0}), 0);
      expect(WsStreamSeq.of(<String, dynamic>{'seq': 1}), 1);
      expect(WsStreamSeq.of(<String, dynamic>{'seq': 42}), 42);
      // 帧里还有别的字段时不受影响
      expect(
        WsStreamSeq.of(<String, dynamic>{
          'type': WsOutboundType.msgChunk,
          'id': 'msg_1',
          'chunk': '增量',
          'seq': 7,
        }),
        7,
      );
    });

    test('读取：缺字段 / 非法值一律 null = 未知（老核心回退路径）', () {
      expect(WsStreamSeq.of(<String, dynamic>{}), isNull, reason: '老核心：整帧没有 seq');
      expect(WsStreamSeq.of(<String, dynamic>{'seq': null}), isNull);
      expect(
        WsStreamSeq.of(<String, dynamic>{'seq': '3'}),
        isNull,
        reason: '字符串不当数字用（误读会造出错的水位，进而静默丢正文）',
      );
      expect(
        WsStreamSeq.of(<String, dynamic>{'seq': 3.5}),
        isNull,
        reason: '浮点不当序号（截断成 3 会造出偏低的"已消费水位"）',
      );
      expect(
        WsStreamSeq.of(<String, dynamic>{'seq': -1}),
        isNull,
        reason: '负数不可能是核心产出的合法序号（起点是 0）',
      );
      expect(WsStreamSeq.of(<String, dynamic>{'seq': true}), isNull);
    });

    test('读取：JSON 往返后仍是 int（线上形态就是 jsonEncode 产出）', () {
      final Object? decoded = jsonDecode(
        jsonEncode(<String, dynamic>{
          'type': WsOutboundType.msgChunk,
          'id': 'msg_1',
          'chunk': '增量',
          'seq': 7,
        }),
      );
      expect(decoded, isA<Map<String, dynamic>>());
      final Map<String, dynamic> frame = decoded! as Map<String, dynamic>;
      expect(frame[WsStreamSeq.field], isA<int>());
      expect(WsStreamSeq.of(frame), 7);
    });
  });
}
