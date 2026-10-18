import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 界面字体族档位（用户 2026-10-18：字体设置太少了，要"大小、粗细、字体"）。
///
/// [family] 为 null 表示**不指定字体族**——交给 Flutter 的 Typography 默认
/// （Windows 上是 Segoe UI），也就是用户说的"系统默认"。给固定字体族时带上
/// [fallback]，免得这台机器没装那个字就掉进某个不知名的替代字体。
enum UiFontFamily {
  yahei(
    key: 'yahei',
    label: '微软雅黑',
    family: 'Microsoft YaHei',
    fallback: <String>['PingFang SC', 'Noto Sans CJK SC', 'sans-serif'],
  ),
  system(key: 'system', label: '系统默认', family: null, fallback: null),
  simhei(key: 'simhei', label: '黑体', family: 'SimHei', fallback: null),
  mono(
    key: 'mono',
    label: '等宽（Consolas）',
    family: 'Consolas',
    fallback: <String>['Cascadia Mono', 'monospace'],
  );

  const UiFontFamily({
    required this.key,
    required this.label,
    required this.family,
    required this.fallback,
  });

  /// 持久化用的稳定键（改名 = 用户升级后设置丢失，测试拦着）
  final String key;
  final String label;
  final String? family;
  final List<String>? fallback;

  /// 出厂默认：微软雅黑（与 1.0.4 之前写死在 ThemeData 里的那一个一致）
  static const UiFontFamily defaultValue = UiFontFamily.yahei;

  /// 持久化值 → 档位；认不出的值一律回落到默认（不能抛异常，那是启动路径）。
  static UiFontFamily fromKey(Object? value) => UiFontFamily.values.firstWhere(
    (UiFontFamily f) => f.key == value?.toString(),
    orElse: () => defaultValue,
  );
}

/// 界面字重档位。
///
/// 数值 [delta] 是**相对 Material 默认字重的增量**（Material 的 textTheme 各
/// 样式默认 w400 一档），加在 `TextTheme.apply(fontWeightDelta:)` 上——这样
/// 加粗是"整体抬一档"，而不是把标题也压成正文的粗细。
enum UiFontWeight {
  regular(key: 'regular', label: '常规', delta: 0),
  medium(key: 'medium', label: '中等', delta: 1),
  bold(key: 'bold', label: '加粗', delta: 2);

  const UiFontWeight({
    required this.key,
    required this.label,
    required this.delta,
  });

  final String key;
  final String label;
  final int delta;

  /// 出厂默认：中等（用户 2026-10-18 反馈"目前感觉偏细"——雅黑 w400 在白底上
  /// 确实发虚，默认抬一档到 w500，明显比"让用户自己去找设置"更符合预期）。
  static const UiFontWeight defaultValue = UiFontWeight.medium;

  static UiFontWeight fromKey(Object? value) => UiFontWeight.values.firstWhere(
    (UiFontWeight w) => w.key == value?.toString(),
    orElse: () => defaultValue,
  );
}

/// 界面字体偏好（字体族 + 字重）的保存与恢复。
///
/// 与 [TextScaleService] 的分工：那个管**字号**（注入 MediaQuery 的 textScaler），
/// 这个管**字形**（注入 ThemeData 的 textTheme）。两者都是应用根 Widget 监听，
/// 变化即时重建、无需重启。
class FontService extends ChangeNotifier {
  /// 全局单例
  static final FontService instance = FontService._();

  /// shared_preferences 中的存储键名（跨版本用户数据契约，别改名）
  static const String familyKey = 'ui_font_family';
  static const String weightKey = 'ui_font_weight';

  UiFontFamily _family = UiFontFamily.defaultValue;
  UiFontWeight _weight = UiFontWeight.defaultValue;

  FontService._();

  /// 当前字体族
  UiFontFamily get family => _family;

  /// 当前字重
  UiFontWeight get weight => _weight;

  /// 从本地存储加载（应用启动时调用；认不出的值回落默认，绝不抛）。
  Future<void> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _family = UiFontFamily.fromKey(prefs.getString(familyKey));
    _weight = UiFontWeight.fromKey(prefs.getString(weightKey));
    notifyListeners();
  }

  /// 设置字体族并持久化。
  void setFamily(UiFontFamily value) {
    if (_family == value) return;
    _family = value;
    notifyListeners();
    _persist(familyKey, value.key);
  }

  /// 设置字重并持久化。
  void setWeight(UiFontWeight value) {
    if (_weight == value) return;
    _weight = value;
    notifyListeners();
    _persist(weightKey, value.key);
  }

  /// 把 [base] 的文本样式套上当前字体偏好：先换字体族，再整体抬字重。
  ///
  /// 为什么改 textTheme 而不是 ThemeData(fontFamily:)：字重没有对应的 ThemeData
  /// 构造参数，只能落在 textTheme 上；而 textTheme 正是所有**没写死 fontWeight**
  /// 的 Text 的默认来源（`Text(style: TextStyle(fontSize: 12))` 也会与它合并），
  /// 所以"抬一档"能覆盖到全应用——只有显式写死 fontWeight 的那几处不跟随。
  ///
  /// 逐样式调用 [TextStyle.apply]（`TextTheme.apply` 没有 fontWeightDelta 参数），
  /// 两端都没得改时**原样返回同一个对象**，让调用方能用 identical 判出"没变"。
  TextTheme applyTo(TextTheme base) {
    if (_family.family == null && _weight.delta == 0) return base;
    TextStyle? fix(TextStyle? style) {
      if (style == null) return null;
      TextStyle next = style;
      if (_family.family != null) {
        next = next.apply(
          fontFamily: _family.family,
          fontFamilyFallback: _family.fallback,
        );
      }
      if (_weight.delta != 0) {
        // 不能直接用 `TextStyle.apply(fontWeightDelta:)`：它对 "fontWeight 为 null
        // 且 delta ≠ 0" 会断言失败，而 Material 主题里确实有些样式没写死字重。
        // 这里显式把 null 当 w400 起点，再整体抬档、夹在 w100…w900 内。
        final int slot = FontWeight.values.indexOf(style.fontWeight ?? FontWeight.w400);
        final int nextSlot = (slot + _weight.delta)
            .clamp(0, FontWeight.values.length - 1);
        next = next.copyWith(fontWeight: FontWeight.values[nextSlot]);
      }
      return next;
    }

    return TextTheme(
      displayLarge: fix(base.displayLarge),
      displayMedium: fix(base.displayMedium),
      displaySmall: fix(base.displaySmall),
      headlineLarge: fix(base.headlineLarge),
      headlineMedium: fix(base.headlineMedium),
      headlineSmall: fix(base.headlineSmall),
      titleLarge: fix(base.titleLarge),
      titleMedium: fix(base.titleMedium),
      titleSmall: fix(base.titleSmall),
      bodyLarge: fix(base.bodyLarge),
      bodyMedium: fix(base.bodyMedium),
      bodySmall: fix(base.bodySmall),
      labelLarge: fix(base.labelLarge),
      labelMedium: fix(base.labelMedium),
      labelSmall: fix(base.labelSmall),
    );
  }

  Future<void> _persist(String key, String value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }
}
