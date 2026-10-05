import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/io/api_service.dart';
import 'package:tree/ui/pages/settings_page.dart';
import 'package:tree/ui/text_scale_service.dart';

/// 设置页「文字大小」一节的 UI 行为。
///
/// 断言三件事：
/// 1. 该节确实渲染出滑杆（不是被漏掉的卡片）；
/// 2. 拖动滑杆真的把值写进 [TextScaleService]（全局缩放的唯一数据源）；
/// 3. 常显的百分比文案随拖动更新（用户能感知当前值）。
///
/// 为什么不测"全局 Text 真的变大"：那要把整个 AgentTeamApp 跑起来，
/// 依赖 windowManager / CoreProcessLauncher / TrayService 一堆平台插件，
/// 而注入逻辑只有 main.dart 里 5 行（MediaQuery.copyWith(textScaler: ...)），
/// 读一遍就能确认，投入产出比不划算。
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
    // 单例复位：setMockInitialValues 已清空 prefs，load 会回落到 1.0
    await TextScaleService.instance.load();
  });

  tearDown(() async {
    await fakeCore.close(force: true);
  });

  /// 把测试视口撑大：设置页是长 ListView，「文字大小」在主题之后，
  /// 默认 800x600 会落在视口外，找不到控件。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('设置页渲染出「文字大小」一节与滑杆', (WidgetTester tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    expect(find.text('文字大小'), findsOneWidget);
    expect(find.byKey(const Key('text-scale-slider')), findsOneWidget);
  });

  testWidgets('拖动滑杆把值写进 TextScaleService（= 全局缩放的唯一数据源）',
      (WidgetTester tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    // 从当前值（1.0）拖到最右 —— 区间 [0.8, 1.5]，500px 足够跨越
    await tester.drag(
      find.byKey(const Key('text-scale-slider')),
      const Offset(500, 0),
    );
    await tester.pumpAndSettle();

    expect(TextScaleService.instance.scale, TextScaleService.maxScale);
  });

  testWidgets('拖动后常显百分比文案更新', (WidgetTester tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    expect(find.text('100%'), findsOneWidget);

    await tester.drag(
      find.byKey(const Key('text-scale-slider')),
      const Offset(500, 0),
    );
    await tester.pumpAndSettle();

    expect(find.text('150%'), findsOneWidget);
  });
}