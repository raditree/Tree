import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('YamlCodec 编码', () {
    test('标量：null/bool/int/double/字符串', () {
      final String yaml = YamlCodec.encode(<String, dynamic>{
        'n': null,
        't': true,
        'f': false,
        'i': 42,
        'd': 1.5,
        's': 'hello',
        'empty': '',
      });
      expect(yaml, contains('n: null'));
      expect(yaml, contains('t: true'));
      expect(yaml, contains('f: false'));
      expect(yaml, contains('i: 42'));
      expect(yaml, contains('s: hello'));
      expect(yaml, contains('empty: ""'));
    });

    test('看起来像数字/布尔值的字符串必须加引号（否则往返类型漂移）', () {
      final Map<String, dynamic> source = <String, dynamic>{
        'a': '123',
        'b': '1.5',
        'c': 'true',
        'd': 'on',
        'e': '-3',
      };
      final Map<String, dynamic> back = YamlCodec.decode(
        YamlCodec.encode(source),
      );
      expect(back, source);
      for (final Object? value in back.values) {
        expect(value, isA<String>());
      }
    });

    test('多行字符串写成块标量，读回来完全一致（含缩进与空行）', () {
      const String prompt = '第一行\n\n  缩进两格\n最后一行';
      final String yaml = YamlCodec.encode(<String, dynamic>{
        'system_prompt': prompt,
      });
      expect(yaml, contains('|-')); // 无结尾换行 -> |-
      expect(yaml, contains('  第一行'));
      expect(YamlCodec.decode(yaml)['system_prompt'], prompt);
    });

    test('以换行结尾的多行字符串用 | 保留结尾换行', () {
      const String text = '一行\n';
      final String yaml = YamlCodec.encode(<String, dynamic>{'t': text});
      expect(yaml, contains('|\n'));
      expect(YamlCodec.decode(yaml)['t'], '一行\n');
    });

    test('嵌套映射与列表；空集合写成 {} / []', () {
      final Map<String, dynamic> source = <String, dynamic>{
        'outer': <String, dynamic>{
          'inner': <String, dynamic>{
            'deep': <int>[1, 2, 3],
          },
          'empty_map': <String, dynamic>{},
          'empty_list': <String>[],
        },
        'list': <dynamic>[
          'a',
          <String, dynamic>{'k': 'v'},
        ],
      };
      expect(YamlCodec.decode(YamlCodec.encode(source)), source);
    });

    test('中文与 emoji 往返一致', () {
      final Map<String, dynamic> source = <String, dynamic>{
        'name': '桌面核心进程',
        'note': 'emoji: 🚀 与引号" 与反斜杠\\',
      };
      expect(YamlCodec.decode(YamlCodec.encode(source)), source);
    });

    test('文件头注释以 # 开头', () {
      final String yaml = YamlCodec.encode(<String, dynamic>{
        'a': 1,
      }, header: '第一行\n# 已有井号');
      expect(yaml.startsWith('# 第一行\n# 已有井号\n\n'), isTrue);
    });

    test('需要引号的键会被引号包起来', () {
      final Map<String, dynamic> source = <String, dynamic>{'带空格 的键': 1};
      expect(YamlCodec.decode(YamlCodec.encode(source)), source);
    });
  });

  group('YamlCodec 解码（用户手改的输入）', () {
    test('容忍注释、flow 风格、单双引号、行内列表', () {
      final Map<String, dynamic> map = YamlCodec.decode('''
# 顶层注释
frame_rate: 60          # 行尾注释
rate_limit_enabled: "true"
tags: [a, b, 'c d']
nested: {k: v, n: 2}
text: "带 \\"引号\\" 的值"
''');
      expect(map['frame_rate'], 60);
      expect(map['rate_limit_enabled'], 'true');
      expect(map['tags'], <String>['a', 'b', 'c d']);
      expect((map['nested'] as Map<String, dynamic>)['n'], 2);
      expect(map['text'], contains('引号'));
    });

    test('空文档与全注释文档都返回空映射', () {
      expect(YamlCodec.decode(''), isEmpty);
      expect(YamlCodec.decode('# 只有注释\n'), isEmpty);
    });

    test('顶层不是映射时抛 FormatException（宁可大声失败）', () {
      expect(() => YamlCodec.decode('- a\n- b\n'), throwsFormatException);
      expect(() => YamlCodec.decode('just a scalar'), throwsFormatException);
    });

    test('normalize 递归去掉 YamlMap/YamlList 包装', () {
      final Object? normalized = YamlCodec.normalize(
        loadYaml('a:\n  - 1\n  - b:\n      c: true\n'),
      );
      expect(normalized, isA<Map<String, dynamic>>());
      final Map<String, dynamic> map = normalized! as Map<String, dynamic>;
      expect((map['a'] as List<dynamic>).first, 1);
      expect(
        ((map['a'] as List<dynamic>)[1] as Map<String, dynamic>)['b'],
        <String, dynamic>{'c': true},
      );
    });
  });
}
