import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 一个**不是合法 UTF-8** 的字节样本：GBK/CP936 的「中文测试」。
const List<int> _gbkBytes = <int>[
  0xD6,
  0xD0,
  0xCE,
  0xC4,
  0xB2,
  0xE2,
  0xCA,
  0xD4,
];

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tree_atomic_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String path(String name) => p.join(dir.path, name);

  group('AtomicFile 读入口：容错解码', () {
    test('文件不存在返回 null', () async {
      expect(await AtomicFile.readStringOrNull(path('nope.txt')), isNull);
      expect(AtomicFile.readStringOrNullSync(path('nope.txt')), isNull);
    });

    test('空文件返回空串（与"不存在"区分）', () async {
      File(path('empty.txt')).writeAsBytesSync(<int>[]);
      expect(await AtomicFile.readStringOrNull(path('empty.txt')), '');
      expect(AtomicFile.readStringOrNullSync(path('empty.txt')), '');
    });

    test('合法 UTF-8（含中文/emoji）原样读出', () async {
      const String text = '第一行\n第二行 😀\n';
      File(path('ok.txt')).writeAsBytesSync(utf8.encode(text));
      expect(await AtomicFile.readStringOrNull(path('ok.txt')), text);
      expect(AtomicFile.readStringOrNullSync(path('ok.txt')), text);
    });

    test('非法 UTF-8：不抛异常，坏字节顶成 U+FFFD，合法部分一个字节不丢', () async {
      // 头尾合法 ASCII + 中间两个在任何位置都不合法的字节：结果可以精确断言
      final List<int> bytes = <int>[
        ...utf8.encode('head:'),
        0xFF,
        0xFE,
        ...utf8.encode(':tail'),
      ];
      File(path('bad.bin')).writeAsBytesSync(bytes);

      final String? text = await AtomicFile.readStringOrNull(path('bad.bin'));
      expect(text, 'head:\uFFFD\uFFFD:tail', reason: '坏字节顶替、合法部分逐字节保留');
      expect(
        AtomicFile.readStringOrNullSync(path('bad.bin')),
        text,
        reason: '同步与异步口径必须一致',
      );
    });

    test('GBK 老文件：读得出来、不抛异常（坏字节顶成 U+FFFD）', () async {
      File(path('gbk.bin')).writeAsBytesSync(_gbkBytes);
      final String? text = await AtomicFile.readStringOrNull(path('gbk.bin'));
      expect(text, isNotNull);
      expect(text, contains('\uFFFD'), reason: '坏字节必须看得见，而不是抛异常');
      expect(AtomicFile.readStringOrNullSync(path('gbk.bin')), text);
    });

    test('与 readTailOrNullSync 的 allowMalformed 口径一致', () async {
      File(path('bad2.bin')).writeAsBytesSync(_gbkBytes);
      final String? head = AtomicFile.readStringOrNullSync(path('bad2.bin'));
      final String? tail = AtomicFile.readTailOrNullSync(
        path('bad2.bin'),
        1024,
      );
      expect(head, tail, reason: '同一个坏字节样本，两个读入口不该给出不同文本');
      expect(head, isNotNull);
    });

    test('截断的多字节序列（另半个汉字）也能读出来', () async {
      // '中' 的 UTF-8 是 E4 B8 AD：砍掉最后一个字节 = 截断的多字节序列
      File(path('trunc.bin')).writeAsBytesSync(<int>[0xE4, 0xB8]);
      expect(AtomicFile.readStringOrNullSync(path('trunc.bin')), '\uFFFD');
      expect(await AtomicFile.readStringOrNull(path('trunc.bin')), '\uFFFD');
    });

    test('原子写 → 读往返（合法 UTF-8 路径不受影响）', () async {
      await AtomicFile.writeStringAtomic(path('round.txt'), '待办：写测试 ✅');
      expect(await AtomicFile.readStringOrNull(path('round.txt')), '待办：写测试 ✅');
      AtomicFile.writeStringAtomicSync(path('round2.txt'), '同步往返');
      expect(AtomicFile.readStringOrNullSync(path('round2.txt')), '同步往返');
    });
  });
}
