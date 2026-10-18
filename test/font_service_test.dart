import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/ui/font_service.dart';

/// 界面字体偏好（字体族 + 字重）：夹取 / 持久化读回 / 同值不重通知 / 落到 textTheme。
///
/// 四条红线：
/// 1. 首次启动（无持久化值）回落到出厂默认——字体族雅黑、字重**中等**（用户
///    2026-10-18 反馈"目前感觉偏细"，默认就是抬过一档的那个，不能再掉回 w400）；
/// 2. 持久化里塞了认不出的字符串（旧版本 / 手改）也不能抛——load 在启动路径上，
///    抛异常等于应用起不来；这么写只回落默认；
/// 3. 同值 set 不重复 notify（chip 连点两次不该重建整棵树）；
/// 4. 字重 delta 必须真的落到 TextTheme 上：抬一档后 bodyMedium 从 w400 变 w500、
///    标题从 w700 变 w800——只涨不压，否则"加粗"会把标题压成正文粗细。
///
/// 持久化 key 用字符串字面量断言：它是跨版本的用户数据契约，
/// 改名 = 用户升级后设置丢失，测试要拦住这种漂移。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 单例复位：把上一个用例改过的值按"无持久化"重新载入
    return FontService.instance.load();
  });

  test('首次启动无持久化值时回落到出厂默认（雅黑 + 中等）', () async {
    expect(FontService.instance.family, UiFontFamily.yahei);
    expect(FontService.instance.weight, UiFontWeight.medium);
    expect(
      UiFontWeight.medium.delta,
      greaterThan(0),
      reason: '默认字重必须比 Material 默认重一档——"偏细"就是这么修的',
    );
  });

  test('持久化里是认不出的值时 load 回落默认、不抛异常', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ui_font_family': 'comic_sans',
      'ui_font_weight': 'ultra_black',
    });
    await FontService.instance.load();
    expect(FontService.instance.family, UiFontFamily.yahei);
    expect(FontService.instance.weight, UiFontWeight.medium);
  });

  test('setFamily / setWeight 同值时不触发 notifyListeners', () async {
    int notifyCount = 0;
    FontService.instance.addListener(() => notifyCount++);
    FontService.instance.setFamily(UiFontFamily.yahei);
    FontService.instance.setWeight(UiFontWeight.medium);
    expect(notifyCount, 0, reason: 'chip 连点两次不该重复重建');
  });

  test('setFamily / setWeight 把值写进 shared_preferences 并回读', () async {
    FontService.instance.setFamily(UiFontFamily.mono);
    FontService.instance.setWeight(UiFontWeight.bold);
    // _persist 是 fire-and-forget，等它落盘
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ui_font_family'), 'mono');
    expect(prefs.getString('ui_font_weight'), 'bold');

    await FontService.instance.load();
    expect(FontService.instance.family, UiFontFamily.mono);
    expect(FontService.instance.weight, UiFontWeight.bold);
  });

  test('applyTo：字体族落到 fontFamily，字重按 delta 抬档且标题不被压平', () {
    /// 字重枚举里的档位号（w100 = 0 … w900 = 8）。null 按 Material 的隐含默认
    /// **w400** 计——主题里没显式给字重的样式就是这么被 [TextStyle.apply] 抬档的。
    int slot(FontWeight? w) => FontWeight.values.indexOf(w ?? FontWeight.w400);

    final TextTheme base = ThemeData.light().textTheme;
    final int baseBody = slot(base.bodyMedium?.fontWeight);
    final int baseTitle = slot(base.titleLarge?.fontWeight);

    // ① 系统默认（family = null）⇒ 不改 fontFamily（否则"系统默认"会变成雅黑）
    FontService.instance.setFamily(UiFontFamily.system);
    expect(
      FontService.instance.applyTo(base).bodyMedium?.fontFamily,
      base.bodyMedium?.fontFamily,
    );

    // ② 雅黑 + 加粗：fontFamily 换了，且整体抬两档
    FontService.instance.setFamily(UiFontFamily.yahei);
    FontService.instance.setWeight(UiFontWeight.bold);
    final TextTheme applied = FontService.instance.applyTo(base);
    expect(applied.bodyMedium?.fontFamily, 'Microsoft YaHei');
    expect(
      slot(applied.bodyMedium?.fontWeight) - baseBody,
      2,
      reason: '正文要跟着字重档位走',
    );
    expect(
      slot(applied.titleLarge?.fontWeight) - baseTitle,
      2,
      reason: '标题同样抬两档（不是被压成正文粗细）',
    );
  });

  test('applyTo：常规档不加字重（delta = 0 ⇒ 一字不动）', () {
    final TextTheme base = ThemeData.light().textTheme;
    FontService.instance.setWeight(UiFontWeight.regular);
    final TextTheme applied = FontService.instance.applyTo(base);
    expect(applied.bodyMedium?.fontWeight, base.bodyMedium?.fontWeight);
  });
}
