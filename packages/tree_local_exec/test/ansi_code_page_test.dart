import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 「目录」的 GBK/CP936 字节（中文 Windows 的系统 ANSI 代码页就是 936，cmd 内建命令
/// 写管道用的正是这套字节）。
///
/// **注意歧义**：这 4 个字节同时也是一个**合法 UTF-8 序列**（U+013F 'Ŀ' + U+00BC '¼'），
/// 所以它只能用来直接验证"代码页解码器"，走解码链时会被"严格 UTF-8 优先"抢先解成 'Ŀ¼'。
const List<int> gbkMuLu = <int>[0xC4, 0xBF, 0xC2, 0xBC];

/// 「中文测试」的 GBK/CP936 字节：**不是**合法 UTF-8（0xD6 后面跟不了 0xD0），
/// 这正是 cmd 内建命令中文输出的真实形态（实测 `echo 中文测试` 管道输出就是这 8 字节），
/// 也是"严格 UTF-8 解不开 → 需要按代码页解"的现场。
const List<int> gbkZhongWen = <int>[
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
  tearDown(() {
    // 注入点是全局静态，用例结束必须复原，别串到别的用例
    AnsiCodePage.debugDecoderOverride = null;
  });

  group('解码链（严格 UTF-8 → 系统代码页 → latin1）', () {
    test('合法 UTF-8 一直走 UTF-8', () {
      final List<int> bytes = utf8.encode('中文测试');
      final DecodedText decoded = PlatformTextDecoder.decode(bytes);
      expect(decoded.text, '中文测试');
      expect(decoded.decoding, TextDecoding.utf8);
      expect(decoded.isUtf8, isTrue);
      expect(decoded.isGarbled, isFalse);
      expect(decoded.byteLength, bytes.length);
    });

    test('空字节串视为合法 UTF-8，不走兜底', () {
      final DecodedText decoded = PlatformTextDecoder.decode(const <int>[]);
      expect(decoded.text, isEmpty);
      expect(decoded.decoding, TextDecoding.utf8);
      expect(AnsiCodePage.decode(const <int>[]), isEmpty);
    });

    test('「目录」的 GBK 字节：代码页解码得到正确中文（该样本同时是合法 UTF-8）', () {
      final String? byCodePage = AnsiCodePage.decode(gbkMuLu);
      if (!Platform.isWindows || !AnsiCodePage.isAvailable) {
        // 非 Windows / FFI 不可用：不尝试代码页解码（也不加载 kernel32）
        expect(byCodePage, isNull);
      } else if (AnsiCodePage.systemCodePage == 936) {
        // 中文机器：这串字节按 CP936 就是「目录」
        expect(byCodePage, '目录');
      }
      // 解码链上它会被 UTF-8 分支抢走（严格 UTF-8 优先），如实断言这个已知歧义：
      // 嗅探式解码无法区分"恰好也是合法 UTF-8 的 GBK 字节"，只能按声明的顺序来。
      final DecodedText chained = PlatformTextDecoder.decode(gbkMuLu);
      expect(chained.decoding, TextDecoding.utf8);
      expect(chained.text, 'Ŀ¼');
    });

    test('非 UTF-8 的 GBK 字节按系统 ANSI 代码页解码为「中文测试」', () {
      final String? byCodePage = AnsiCodePage.decode(gbkZhongWen);
      final DecodedText decoded = PlatformTextDecoder.decode(gbkZhongWen);
      if (!Platform.isWindows || !AnsiCodePage.isAvailable) {
        expect(byCodePage, isNull);
        expect(decoded.decoding, TextDecoding.latin1Fallback);
        return;
      }
      final int? codePage = AnsiCodePage.systemCodePage;
      if (codePage == 936) {
        expect(byCodePage, '中文测试');
        expect(decoded.text, '中文测试');
        expect(decoded.decoding, TextDecoding.systemCodePage);
        expect(decoded.isUtf8, isFalse);
        expect(decoded.isGarbled, isFalse);
      } else {
        // 其它 ANSI 代码页（含把系统区域设成 UTF-8 的 65001）下这串字节是别的字符、
        // 甚至非法序列：只要求"不崩、如实返回"。下面这条不变式对任何代码页都成立。
        expect(
          decoded.isGarbled,
          byCodePage == null,
          reason: '本机 ANSI 代码页=$codePage',
        );
      }
    });

    test('ASCII 字节在系统代码页下解成自身（任意代码页都成立）', () {
      if (!Platform.isWindows || !AnsiCodePage.isAvailable) return;
      expect(AnsiCodePage.decode(const <int>[0x41, 0x42, 0x43]), 'ABC');
    });

    test('代码页不可用时降级 latin1：字节数不减、可原样还原', () {
      // 模拟"非 Windows / FFI 不可用"：注入一个恒定失败的代码页解码器
      AnsiCodePage.debugDecoderOverride = (List<int> bytes) => null;
      final DecodedText decoded = PlatformTextDecoder.decode(gbkZhongWen);
      expect(decoded.decoding, TextDecoding.latin1Fallback);
      expect(decoded.isGarbled, isTrue);
      expect(decoded.byteLength, gbkZhongWen.length);
      expect(
        decoded.text.length,
        gbkZhongWen.length,
        reason: 'latin1 逐字节映射：字符数 = 字节数',
      );
      expect(latin1.encode(decoded.text), gbkZhongWen, reason: '兜底不丢字节，可原样还原');
    });

    test('代码页解码成功时走 systemCodePage（不依赖本机代码页）', () {
      AnsiCodePage.debugDecoderOverride = (List<int> bytes) =>
          bytes.length == gbkZhongWen.length ? '中文测试' : null;
      final DecodedText decoded = PlatformTextDecoder.decode(gbkZhongWen);
      expect(decoded.decoding, TextDecoding.systemCodePage);
      expect(decoded.text, '中文测试');
      expect(decoded.isUtf8, isFalse);
      expect(decoded.isGarbled, isFalse);
    });

    test('代码页解码器抛异常也降级 latin1（解码链不上抛）', () {
      AnsiCodePage.debugDecoderOverride = (List<int> bytes) =>
          throw StateError('boom');
      final DecodedText decoded = PlatformTextDecoder.decode(gbkZhongWen);
      expect(decoded.decoding, TextDecoding.latin1Fallback);
      expect(latin1.encode(decoded.text), gbkZhongWen);
    });

    test('代码页编码器：与解码互为逆运算，编不回去时如实返回 null', () {
      if (!Platform.isWindows || !AnsiCodePage.isAvailable) return;
      if (AnsiCodePage.systemCodePage != 936) return; // 下面断言的是 CP936 的具体字节
      expect(AnsiCodePage.encode('中文测试'), gbkZhongWen);
      expect(AnsiCodePage.encode('目录'), gbkMuLu);
      expect(AnsiCodePage.encode(''), isEmpty);
      expect(AnsiCodePage.encode('plain-ascii'), utf8.encode('plain-ascii'));
      // 😀（非 BMP）在 CP936 里没有对应字节：必须返回 null 让调用方拒绝，
      // 而不是写成 '?' 顶替（那才是真的破坏用户文件）
      expect(AnsiCodePage.encode('你好😀'), isNull);
    });

    test('encodeLike：按原解码路径编回，编不回时返回 null', () {
      const DecodedText utf8Text = DecodedText(
        text: '你好',
        decoding: TextDecoding.utf8,
        byteLength: 6,
      );
      expect(PlatformTextDecoder.encodeLike(utf8Text, '你好'), utf8.encode('你好'));

      const DecodedText latin1Text = DecodedText(
        text: 'ab',
        decoding: TextDecoding.latin1Fallback,
        byteLength: 2,
      );
      expect(PlatformTextDecoder.encodeLike(latin1Text, 'ab'), <int>[
        0x61,
        0x62,
      ]);
      expect(
        PlatformTextDecoder.encodeLike(latin1Text, '你好'),
        isNull,
        reason: 'latin1 编不了 0..0xFF 之外的字符',
      );
    });

    test('decodeTolerant：非法字节不抛异常，顶替并如实标注', () {
      final DecodedText clean = PlatformTextDecoder.decodeTolerant(
        utf8.encode('你好'),
      );
      expect(clean.text, '你好');
      expect(clean.decoding, TextDecoding.utf8);

      // 0xFF 是孤立字节：严格 UTF-8 解不开。注入"代码页不可用"把"顶替"这条分支钉死，
      // 断言因此与机器代码页无关。
      AnsiCodePage.debugDecoderOverride = (List<int> bytes) => null;
      final DecodedText tolerant = PlatformTextDecoder.decodeTolerant(<int>[
        0x41,
        0xFF,
        0x42,
      ]);
      expect(tolerant.decoding, TextDecoding.utf8Malformed);
      expect(tolerant.text, 'A\uFFFDB');
      expect(tolerant.byteLength, 3);
    });

    test('decodeBytes 与解码链的结果一致（兼容旧入口）', () {
      expect(
        LocalWorkspaceIO.decodeBytes(gbkZhongWen),
        PlatformTextDecoder.decode(gbkZhongWen).text,
      );
      expect(LocalWorkspaceIO.decodeBytes(utf8.encode('中文测试')), '中文测试');
    });
  });
}
