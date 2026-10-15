import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/io/api_service.dart';
import 'package:tree/ui/pages/settings_page.dart';
import 'package:tree/ui/theme_service.dart';

/// 「主题色可选」功能的回归测试（用户反馈：荧光绿色块长期使用晃眼）。
///
/// 两层口径：
/// - 服务层 [ThemeService]：十六进制解析、预设 / 自定义的持久化与恢复、非法值回退，
///   以及「整套品牌调色板由主色派生」在默认荧光绿下仍贴近原手写色板（观感不回退）；
/// - UI 层（设置页「主题色」卡片）：四个选项渲染、点预设即时改主色、自定义输入的
///   校验与提交。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  int ch(int argb, int shift) => (argb >> shift) & 0xFF;

  /// 断言 [actual] 与参考色 [refArgb] 每通道差 ≤ [tol]——「派生色贴近手写字面量」的口径。
  void expectNear(Color actual, int refArgb, int tol, String label) {
    final int a = actual.toARGB32();
    for (final int s in <int>[16, 8, 0]) {
      expect(
        (ch(a, s) - ch(refArgb, s)).abs(),
        lessThanOrEqualTo(tol),
        reason: '$label 通道偏移过大：#${a.toRadixString(16)} vs 参考 #${refArgb.toRadixString(16)}',
      );
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ThemeService.instance.load(); // 复位到默认荧光绿
  });

  group('ThemeService 主题色', () {
    test('默认 = 荧光绿 #00FF8C', () {
      expect(ThemeService.instance.accentKey, 'bright_green');
      expect(ThemeService.instance.accentColor, const Color(0xFF00FF8C));
    });

    test('parseUserHex 接受 #RGB / #RRGGBB / RRGGBB，拒绝非法', () {
      expect(ThemeService.parseUserHex('#0F8'), const Color(0xFF00FF88));
      expect(ThemeService.parseUserHex('#00FF8C'), const Color(0xFF00FF8C));
      expect(ThemeService.parseUserHex('00ff8c'), const Color(0xFF00FF8C));
      expect(ThemeService.parseUserHex('#12'), isNull);
      expect(ThemeService.parseUserHex('zzzzzz'), isNull);
      expect(ThemeService.parseUserHex(''), isNull);
    });

    test('选预设薄荷绿 → accentColor 变，并落盘', () async {
      await ThemeService.instance.setAccent('mint_green');
      expect(ThemeService.instance.accentColor, const Color(0xFFA8E6CF));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('accent_color'), 'mint_green');
    });

    test('自定义十六进制合法 → 应用并落盘 custom|RRGGBB', () async {
      await ThemeService.instance.applyCustomAccent('#123456');
      expect(ThemeService.instance.accentKey, ThemeService.customAccentKey);
      expect(ThemeService.instance.accentColor, const Color(0xFF123456));
      expect(ThemeService.instance.customAccentHex, '#123456');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('accent_color'), 'custom|123456');
    });

    test('自定义非法 → 忽略，不改状态', () async {
      await ThemeService.instance.applyCustomAccent('nope');
      expect(ThemeService.instance.accentKey, 'bright_green');
      expect(ThemeService.instance.accentColor, const Color(0xFF00FF8C));
    });

    test('load 恢复预设（豆沙绿）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'accent_color': 'adzuki_green',
      });
      await ThemeService.instance.load();
      expect(ThemeService.instance.accentColor, const Color(0xFF9BBB8E));
    });

    test('load 恢复自定义（custom|RRGGBB）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'accent_color': 'custom|ABCDEF',
      });
      await ThemeService.instance.load();
      expect(ThemeService.instance.accentKey, ThemeService.customAccentKey);
      expect(ThemeService.instance.accentColor, const Color(0xFFABCDEF));
    });

    test('load 遇垃圾值回默认荧光绿', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'accent_color': 'gibberish',
      });
      await ThemeService.instance.load();
      expect(ThemeService.instance.accentColor, const Color(0xFF00FF8C));
    });

    test('默认荧光绿下派生色板贴近原手写品牌色（观感不回退）', () {
      const Color bright = Color(0xFF00FF8C);
      expectNear(ThemeService.deriveDeep(bright), 0xFF00904A, 8, 'deep');
      expectNear(ThemeService.deriveLine(bright), 0xFF00522C, 8, 'line');
      expectNear(ThemeService.deriveDivider(bright), 0xFF2B7A4B, 12, 'divider');
      expectNear(ThemeService.deriveOnBright(bright), 0xFF00280F, 8, 'onBright');
      expectNear(ThemeService.deriveContainerDark(bright), 0xFF0E2B1A, 6, 'contDark');
      expectNear(
          ThemeService.deriveOnContainerDark(bright), 0xFFB8FFD9, 8, 'onContDark');
      expectNear(
          ThemeService.deriveContainerLight(bright), 0xFFD9F2E3, 6, 'contLight');
      expectNear(ThemeService.deriveOnContainerLight(bright), 0xFF00491F, 12,
          'onContLight');
      expectNear(
          ThemeService.deriveDividerLight(bright), 0xFFC9E5D3, 6, 'divLight');
      expectNear(ThemeService.deriveInputBorderLight(bright), 0xFFB9DCC7, 6,
          'inputLight');
      expectNear(
          ThemeService.deriveAppBarForeground(bright), 0xFFD9FFEC, 6, 'appbarFg');
      expectNear(
          ThemeService.deriveOutlineDark(bright), 0xFF5E8E71, 8, 'outlineDark');
      // 浅色字标渐变尾色：从 deep 再提亮一档 ≈ #00B45C
      expectNear(ThemeService.deriveMidGreen(const Color(0xFF00904A)),
          0xFF00B45C, 2, 'midGreen');
    });

    test('非绿色主题：派生随主色走（豆沙绿 deep ≠ 荧光绿 deep）', () {
      expect(
        ThemeService.deriveDeep(const Color(0xFF9BBB8E)),
        isNot(ThemeService.deriveDeep(const Color(0xFF00FF8C))),
      );
    });
  });

  group('设置页「主题色」卡片', () {
    late HttpServer fakeCore;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // 假核心：全部 404，让设置页其它 API 调用走兜底分支
      fakeCore = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      fakeCore.listen((HttpRequest req) async {
        req.response.statusCode = 404;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"detail":"未知接口"}');
        await req.response.close();
      });
      ApiService.baseUrl = 'http://127.0.0.1:${fakeCore.port}';
      await ThemeService.instance.load();
    });

    tearDown(() async {
      await fakeCore.close(force: true);
    });

    Future<void> openSettings(WidgetTester tester) async {
      // 视口撑高：设置页是长 ListView，主题色卡片需完整可见才能命中控件
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();
    }

    testWidgets('渲染「主题色」标题与四个选项', (WidgetTester tester) async {
      await openSettings(tester);
      expect(find.text('主题色'), findsOneWidget);
      expect(find.text('荧光绿'), findsOneWidget);
      expect(find.text('豆沙绿'), findsOneWidget);
      expect(find.text('薄荷绿'), findsOneWidget);
      expect(find.text('自定义'), findsOneWidget);
      expect(find.byKey(const Key('accent-custom-field')), findsOneWidget);
    });

    testWidgets('点「薄荷绿」即时改主色', (WidgetTester tester) async {
      await openSettings(tester);
      await tester.tap(find.byKey(const Key('accent-option-mint_green')));
      await tester.pumpAndSettle();
      expect(ThemeService.instance.accentColor, const Color(0xFFA8E6CF));
    });

    testWidgets('自定义：非法色号报错且不改变当前主题色', (WidgetTester tester) async {
      await openSettings(tester);
      await tester.enterText(find.byKey(const Key('accent-custom-field')), '#12');
      await tester.pump();
      expect(find.text('格式非法，应为 #RRGGBB'), findsOneWidget);
      await tester.tap(find.byKey(const Key('accent-custom-apply')));
      await tester.pumpAndSettle();
      expect(ThemeService.instance.accentKey, 'bright_green');
    });

    testWidgets('自定义：合法色号可应用并切到「自定义」', (WidgetTester tester) async {
      await openSettings(tester);
      await tester.enterText(
          find.byKey(const Key('accent-custom-field')), '#123456');
      await tester.pump();
      await tester.tap(find.byKey(const Key('accent-custom-apply')));
      await tester.pumpAndSettle();
      expect(ThemeService.instance.accentKey, ThemeService.customAccentKey);
      expect(ThemeService.instance.accentColor, const Color(0xFF123456));
    });
  });
}
