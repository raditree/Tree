import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/io/api_service.dart';
import 'package:tree/ui/font_service.dart';
import 'package:tree/ui/pages/settings_page.dart';

/// 设置页「界面字体」一节的 UI 行为（用户 2026-10-18 要求补字体设置）。
///
/// 断言三件事：
/// 1. 该节确实渲染出来（字体族 + 字重两组 chip 都在，不是被漏掉的卡片）；
/// 2. 点 chip 真的把值写进 [FontService]（全局字形的唯一数据源）；
/// 3. 选中态跟着 [FontService] 走（当前档位能被看出来，而不是每次都回到默认）。
///
/// 为什么不测"全局文字真的变粗"：那要把整个 AgentTeamApp 跑起来，
/// 依赖 windowManager / CoreProcessLauncher / TrayService 一堆平台插件，
/// 而应用逻辑只有 main.dart 里 `_withUiFont` 几行 + FontService.applyTo，
/// 后者的映射由 test/font_service_test.dart 逐值锁住，这里重复跑整个 App 不划算。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer fakeCore;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 假核心：全部 404，让设置页的 API 调用走兜底分支
    fakeCore = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakeCore.listen((HttpRequest req) async {
      req.response.statusCode = 404;
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"detail":"未知接口"}');
      await req.response.close();
    });
    ApiService.baseUrl = 'http://127.0.0.1:${fakeCore.port}';
    // 单例复位：setMockInitialValues 已清空 prefs，load 会回落到出厂默认
    await FontService.instance.load();
  });

  tearDown(() async {
    await fakeCore.close(force: true);
  });

  /// 把测试视口撑大：设置页是长 ListView，「界面字体」在「文字大小」之后，
  /// 默认 800x600 会落在视口外，找不到控件。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('设置页渲染出「界面字体」一节与两组 chip', (WidgetTester tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    expect(find.text('界面字体'), findsOneWidget);
    expect(find.text('字体族'), findsOneWidget);
    expect(find.text('字重'), findsOneWidget);
    for (final UiFontFamily f in UiFontFamily.values) {
      expect(find.byKey(Key('ui-font-family-${f.key}')), findsOneWidget);
    }
    for (final UiFontWeight w in UiFontWeight.values) {
      expect(find.byKey(Key('ui-font-weight-${w.key}')), findsOneWidget);
    }
  });

  testWidgets('选字体族 / 字重把值写进 FontService（= 全局字形的唯一数据源）',
      (WidgetTester tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ui-font-family-mono')));
    await tester.pumpAndSettle();
    expect(FontService.instance.family, UiFontFamily.mono);

    await tester.tap(find.byKey(const Key('ui-font-weight-bold')));
    await tester.pumpAndSettle();
    expect(FontService.instance.weight, UiFontWeight.bold);
  });

  testWidgets('选中态跟随 FontService：预置成等宽 + 常规时对应 chip 是选中态',
      (WidgetTester tester) async {
    FontService.instance.setFamily(UiFontFamily.mono);
    FontService.instance.setWeight(UiFontWeight.regular);
    useTallViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    ChoiceChip chipOf(String key) =>
        tester.widget<ChoiceChip>(find.byKey(Key(key)));

    expect(chipOf('ui-font-family-mono').selected, isTrue);
    expect(chipOf('ui-font-family-yahei').selected, isFalse);
    expect(chipOf('ui-font-weight-regular').selected, isTrue);
    expect(chipOf('ui-font-weight-medium').selected, isFalse);
  });
}
