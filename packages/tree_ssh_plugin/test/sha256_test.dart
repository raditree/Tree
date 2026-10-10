import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';

/// 期望值由**独立实现**产出（.NET `SHA256`，非本插件代码），因此能真正钉住算法。
const Map<String, String> _vectors = <String, String>{
  '': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  'abc': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq':
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
  'hello world':
      'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
};

void main() {
  group('sha256Hex', () {
    _vectors.forEach((String input, String expected) {
      test('「${input.length} 字符」的摘要', () {
        expect(sha256Hex(utf8.encode(input)), expected);
      });
    });

    test('1000 个 a（多分块路径）', () {
      expect(
        sha256Hex(utf8.encode('a' * 1000)),
        '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3',
      );
    });

    test('空输入与单字节不同（防止把 padding 写错还自洽）', () {
      expect(sha256Hex(<int>[0]), isNot(sha256Hex(<int>[])));
    });
  });

  group('shortDigest', () {
    test('只截前 8 位并带省略号（日志用，绝不用于对账）', () {
      expect(
        shortDigest(
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        ),
        'ba7816bf…',
      );
      expect(shortDigest('abc'), 'abc');
    });
  });
}
