import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/code_highlight.dart';

/// 取某段文本所在记号的类型（没被任何记号覆盖时返回 null = 基础样式）
CodeTokenKind? kindOf(String text, CodeLanguage language, String needle) {
  final int at = text.indexOf(needle);
  expect(at, greaterThanOrEqualTo(0), reason: '用例本身要先包含这段文本');
  for (final CodeToken token in tokenize(text, language)) {
    if (token.start <= at && at < token.end) return token.kind;
  }
  return null;
}

void main() {
  group('语言识别', () {
    test('按扩展名挑语言，认不出来给纯文本', () {
      expect(languageForPath('lib/main.dart').id, 'dart');
      expect(languageForPath(r'C:\a\b.PY').id, 'python');
      expect(languageForPath('a/b.tsx').id, 'javascript');
      expect(languageForPath('a/b.ps1').id, 'powershell');
      expect(languageForPath('a/b.yaml').id, 'yaml');
      expect(languageForPath('Makefile').id, 'plain');
      expect(languageForPath('a/b.unknown_ext').id, 'plain');
    });

    test('纯文本语言不着色（整段没有任何记号）', () {
      expect(tokenize('hello world\n第二行\n', kPlainLanguage), isEmpty);
    });
  });

  group('Dart 词法', () {
    const String code = '''
// 注释里的引号 " 与 // 都该留在注释里
class Foo {
  final String name = 'x // 不是注释';
  /* 块注释
     跨行 */
  int bar(int a) => a + 0x1F;
}
''';

    test('关键字 / 类型 / 字符串 / 注释 / 数字 / 函数名各归各位', () {
      expect(kindOf(code, kDartLanguage, 'class'), CodeTokenKind.keyword);
      expect(kindOf(code, kDartLanguage, 'final'), CodeTokenKind.keyword);
      expect(kindOf(code, kDartLanguage, 'String'), CodeTokenKind.type);
      expect(kindOf(code, kDartLanguage, 'Foo'), CodeTokenKind.type,
          reason: '大写开头的标识符按类型着色（语言无关的通用启发）');
      expect(kindOf(code, kDartLanguage, '不是注释'), CodeTokenKind.string);
      expect(kindOf(code, kDartLanguage, '块注释'), CodeTokenKind.comment);
      expect(kindOf(code, kDartLanguage, '0x1F'), CodeTokenKind.number);
      expect(kindOf(code, kDartLanguage, 'bar'), CodeTokenKind.function);
    });

    test('注释里的引号不吞掉后面的代码', () {
      // 第一行注释含一个孤立的 "：若把注释里的引号当字符串起点，class 会被吃掉
      expect(kindOf(code, kDartLanguage, '都该留在注释里'),
          CodeTokenKind.comment);
      expect(kindOf(code, kDartLanguage, 'class'), CodeTokenKind.keyword);
    });

    test('未闭合的块注释吃到结尾，不越界', () {
      const String broken = 'void main() {\n/* 没关\n';
      final List<CodeToken> tokens = tokenize(broken, kDartLanguage);
      expect(tokens.last.kind, CodeTokenKind.comment);
      expect(tokens.last.end, broken.length);
    });

    test('记号按位置升序、互不重叠、都在文本范围内', () {
      final List<CodeToken> tokens = tokenize(code, kDartLanguage);
      expect(tokens, isNotEmpty);
      for (int i = 0; i < tokens.length; i++) {
        expect(tokens[i].start, lessThan(tokens[i].end));
        expect(tokens[i].end, lessThanOrEqualTo(code.length));
        if (i > 0) {
          expect(tokens[i].start, greaterThanOrEqualTo(tokens[i - 1].end),
              reason: '记号之间不许交叠');
        }
      }
    });

    test('装饰器按注解着色', () {
      expect(kindOf('@override\nvoid f() {}', kDartLanguage, 'override'),
          CodeTokenKind.annotation);
    });
  });

  group('其它语言', () {
    test('Python：# 注释与三引号字符串', () {
      const String py = 'def f(x):\n    """文档\n    多行"""\n    return x  # 收尾\n';
      expect(kindOf(py, kPythonLanguage, 'def'), CodeTokenKind.keyword);
      expect(kindOf(py, kPythonLanguage, '文档'), CodeTokenKind.string);
      expect(kindOf(py, kPythonLanguage, '收尾'), CodeTokenKind.comment);
    });

    test('SQL 不分大小写', () {
      expect(kindOf('select * from t', kSqlLanguage, 'select'),
          CodeTokenKind.keyword);
      expect(kindOf('SELECT * FROM t', kSqlLanguage, 'SELECT'),
          CodeTokenKind.keyword);
    });

    test('HTML 的 <!-- --> 是块注释', () {
      const String html = '<div class="a">\n<!-- 说明 -->\n</div>';
      expect(kindOf(html, kHtmlLanguage, '说明'), CodeTokenKind.comment);
      expect(kindOf(html, kHtmlLanguage, 'div'), CodeTokenKind.keyword);
    });

    test('YAML/TOML 的 # 是注释，值是字符串', () {
      const String yaml = 'name: demo  # 名字\ntag: "v1"';
      expect(kindOf(yaml, kYamlLanguage, '名字'), CodeTokenKind.comment);
      expect(kindOf(yaml, kYamlLanguage, '"v1"'), CodeTokenKind.string);
    });

    test('Shell 的 # 注释与变量前缀', () {
      const String sh = 'echo "hi"  # 打招呼\nFOO=1';
      expect(kindOf(sh, kShellLanguage, 'echo'), CodeTokenKind.type);
      expect(kindOf(sh, kShellLanguage, '打招呼'), CodeTokenKind.comment);
    });
  });

  group('编辑控制器', () {
    testWidgets('关键字 / 数字按配色表着色，普通标识符保持基础样式',
        (WidgetTester tester) async {
      final CodeEditingController controller = CodeEditingController(
        language: kDartLanguage,
        text: 'final int x = 1;',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: TextField(controller: controller)),
      ));
      final BuildContext context = tester.element(find.byType(TextField));
      final TextSpan span = controller.buildTextSpan(
        context: context,
        style: const TextStyle(),
        withComposing: false,
      );
      final List<TextSpan> children = span.children!.cast<TextSpan>();
      final CodeTheme theme = CodeTheme.of(context);

      expect(children.firstWhere((TextSpan s) => s.text == 'final').style!.color,
          theme.keyword);
      expect(children.firstWhere((TextSpan s) => s.text == 'int').style!.color,
          theme.type);
      expect(children.firstWhere((TextSpan s) => s.text == '1').style!.color,
          theme.number);
      // 普通标识符不单列样式（并进前后那段），也就没有任何颜色覆盖
      expect(children.any((TextSpan s) => s.text == 'x' && s.style?.color != null),
          isFalse);
    });

    testWidgets('超过上限的文件退回单色（不着色）', (WidgetTester tester) async {
      final StringBuffer buffer = StringBuffer();
      while (buffer.length <= kHighlightMaxChars) {
        buffer.write('final int aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa = 1;\n');
      }
      final String big = buffer.toString();
      expect(big.length, greaterThan(kHighlightMaxChars));

      final CodeEditingController controller =
          CodeEditingController(language: kDartLanguage, text: big);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: TextField(controller: controller)),
      ));
      final TextSpan span = controller.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        style: const TextStyle(),
        withComposing: false,
      );
      expect(span.children, isNull, reason: '大文件不该再切 span');
      expect(span.text!.length, big.length);
    });

    testWidgets('输入法组字期间交回平台（不切走组字区间）',
        (WidgetTester tester) async {
      final CodeEditingController controller =
          CodeEditingController(language: kDartLanguage, text: '注释');
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: TextField(controller: controller)),
      ));
      controller.value = const TextEditingValue(
        text: '注释',
        composing: TextRange(start: 0, end: 2),
      );
      final TextSpan span = controller.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        style: const TextStyle(),
        withComposing: true,
      );
      // 平台路径会给出带下划线的组字 span（我们不再自己切色）
      expect(span.toPlainText(), '注释');
      expect(span.children, isNotNull);
      expect(
        span.children!.cast<TextSpan>().any((TextSpan s) =>
            (s.style?.decoration ?? TextDecoration.none) !=
            TextDecoration.none),
        isTrue,
      );
    });
  });
}
