import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';
import 'package:tree/ui/widgets/welcome_mark.dart';

/// 中栏空态标识（**用户 2026-10-04 定稿「C7」**）的回归测试。
///
/// 口径：主题色的**纯样式**字标——TREE 大写宽字距 w800 + 主色渐变 + HUD 三段线 +
/// 一行「你好，欢迎使用」；不引资源、不动 pubspec，颜色全部随 [ColorScheme]。
/// "什么时候显示它"（只在确实加载完且真的没有消息时）由
/// test/message_panel_agent_switch_test.dart 钉住；这里只钉**长什么样**，
/// 以及与 MessageList 的接线（空表 + 加载完 ⇒ 就是它；加载中 ⇒ 不许出现）。
void main() {
  Future<void> pumpMark(WidgetTester tester, ThemeData theme) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(body: Center(child: WelcomeMark())),
      ),
    );
    await tester.pump();
  }

  testWidgets('① 字标 = 大写 TREE + w800 + 宽字距（几何取自公开常量）',
      (WidgetTester tester) async {
    await pumpMark(tester, ThemeData.dark());

    final Text t = tester.widget<Text>(find.byKey(WelcomeMark.wordmarkKey));
    expect(t.data, WelcomeMark.wordmark);
    expect(t.data, 'TREE', reason: '大写是版式的一部分');
    expect(t.style!.fontWeight, FontWeight.w800, reason: '单薄感靠字重 + 字距压掉');
    expect(t.style!.fontSize, WelcomeMark.wordmarkFontSize);
    expect(t.style!.letterSpacing, WelcomeMark.wordmarkLetterSpacing);
    expect(find.text(WelcomeMark.caption), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('② 字是渐变的：ShaderMask + srcIn（不是纯色字）',
      (WidgetTester tester) async {
    await pumpMark(tester, ThemeData.dark());

    final Finder mask = find.byType(ShaderMask);
    expect(mask, findsOneWidget);
    expect(tester.widget<ShaderMask>(mask).blendMode, BlendMode.srcIn);
    final Text t = tester.widget<Text>(find.byKey(WelcomeMark.wordmarkKey));
    expect(t.style!.color, Colors.white,
        reason: 'ShaderMask 只吃 alpha，底字给白色，颜色由渐变决定');
  });

  testWidgets('③ HUD 三段线：整体宽度 = 2×侧段 + 中段 + 2×缺口，中段比两侧亮',
      (WidgetTester tester) async {
    await pumpMark(tester, ThemeData.dark());

    expect(tester.getSize(find.byKey(WelcomeMark.ruleKey)).width,
        WelcomeMark.ruleWidth);

    final List<BoxDecoration> decos = tester
        .widgetList<Container>(find.descendant(
          of: find.byKey(WelcomeMark.ruleKey),
          matching: find.byType(Container),
        ))
        .map((Container c) => c.decoration! as BoxDecoration)
        .toList();
    expect(decos.length, 3, reason: '三段（两处缺口是空白，不是第四段）');
    expect(decos[1].color, isNot(decos[0].color), reason: '中段比两侧亮');
    expect(decos[0].color, decos[2].color, reason: '两侧同色');
    expect(decos[1].borderRadius, isNotNull);
  });

  test('④ 渐变随主题：起点是主题主色，深 / 浅两套终点', () {
    const ColorScheme dark = ColorScheme.dark(primary: Color(0xFF00FF8C));
    const ColorScheme light = ColorScheme.light(primary: Color(0xFF00904A));

    expect(WelcomeMark.gradientOf(dark).first, dark.primary);
    expect(WelcomeMark.gradientOf(light).first, light.primary);
    expect(WelcomeMark.gradientOf(dark).last, const Color(0xFF00904A));
    expect(WelcomeMark.gradientOf(light).last, const Color(0xFF00B45C));
  });

  testWidgets('⑤ 不许回到底层 emoji（平台彩色，染不上主题色）',
      (WidgetTester tester) async {
    await pumpMark(tester, ThemeData.dark());

    expect(find.text('👋'), findsNothing);
    expect(find.textContaining('欢迎使用 Tree'), findsNothing,
        reason: '文案定稿是「你好，欢迎使用」');
  });

  testWidgets('⑥ 接进真实中栏空态：空表 + 加载完 ⇒ 显示的就是它',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MessageList(slots: <ChatMessage?>[])),
    ));
    await tester.pump();

    expect(find.byType(WelcomeMark), findsOneWidget);
    expect(find.text(WelcomeMark.caption), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('⑦ 加载中不显示它（渲染骨架，不闪空态）', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MessageList(slots: <ChatMessage?>[], loading: true),
      ),
    ));
    await tester.pump();

    expect(find.byType(WelcomeMark), findsNothing);
  });
}
