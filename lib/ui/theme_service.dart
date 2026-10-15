import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个可选的主题色（强调色）预设：展示名 + 十六进制色值。
///
/// 色值只存这一个数，其余整套品牌调色板由 [ThemeService.deriveDeep] 等
/// 派生函数从它算出来（见 ThemeService 的派生注释）。
class AccentPreset {
  const AccentPreset({required this.key, required this.label, required this.hex});

  /// 持久化用的稳定标识（不随展示名改动）
  final String key;
  /// 设置页里的展示名
  final String label;
  /// 十六进制色值（'RRGGBB'，不带 #）
  final String hex;

  Color get color => Color(int.parse(hex, radix: 16) | 0xFF000000);
}

/// 主题管理服务
///
/// 负责应用主题模式（浅色 / 深色 / 跟随系统）与主题色（荧光绿 / 豆沙绿 /
/// 薄荷绿 / 自定义十六进制）的保存与恢复。
/// 使用 [ChangeNotifier]，应用根 Widget 监听它并在切换时重建主题。
class ThemeService extends ChangeNotifier {
  /// 全局单例
  static final ThemeService instance = ThemeService._();

  /// shared_preferences 中的存储键名
  static const String _key = 'theme_mode';

  /// 主题色的存储键名
  static const String _accentKey = 'accent_color';

  /// 内置预设（顺序即设置页展示顺序；「自定义」另列，不在此表内）
  static const List<AccentPreset> accentPresets = <AccentPreset>[
    AccentPreset(key: 'bright_green', label: '荧光绿', hex: '00FF8C'),
    AccentPreset(key: 'adzuki_green', label: '豆沙绿', hex: '9BBB8E'),
    AccentPreset(key: 'mint_green', label: '薄荷绿', hex: 'A8E6CF'),
  ];

  /// 「自定义」这一选项的标识（存储值形如 'custom|RRGGBB'）
  static const String customAccentKey = 'custom';

  /// 默认主题色：品牌荧光绿（对齐 web/icons/Icon-512.png 的图标主亮绿）
  static const String defaultAccentHex = '00FF8C';

  ThemeMode _mode = ThemeMode.system;

  /// 当前主题色：预设 key，或 [customAccentKey]（此时 [_customAccentHex] 有效）
  String _accentKeySelected = 'bright_green';

  /// 自定义主题色的十六进制（'RRGGBB'，不带 #）；仅在选中「自定义」时参与渲染
  String _customAccentHex = defaultAccentHex;

  ThemeService._();

  /// 当前主题模式
  ThemeMode get mode => _mode;

  /// 当前选中的主题色标识（预设 key 或 [customAccentKey]）
  String get accentKey => _accentKeySelected;

  /// 自定义输入框的回显值（带 # 的常见写法，方便用户直接改）
  String get customAccentHex => '#$_customAccentHex';

  /// 当前主题色的实际颜色——整套品牌调色板的唯一来源。
  ///
  /// 非法的自定义值不抛错也不回退默认：按 [defaultAccentHex] 渲染，
  /// 让界面稳定，坏值留在输入框里可见、可改。
  Color get accentColor {
    if (_accentKeySelected == customAccentKey) {
      return _parseHex(_customAccentHex) ??
          Color(int.parse(defaultAccentHex, radix: 16) | 0xFF000000);
    }
    return accentPresets
        .firstWhere(
          (AccentPreset p) => p.key == _accentKeySelected,
          orElse: () => accentPresets.first,
        )
        .color;
  }

  /// 解析十六进制色值：接受 'RRGGBB' / '#RRGGBB' / '#RGB'，非法时返回 null
  static Color? parseUserHex(String input) => _parseHex(input.trim());

  static Color? _parseHex(String input) {
    String s = input.trim().toUpperCase();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 3) {
      s = s.split('').map((String c) => '$c$c').join();
    }
    if (s.length != 6 || !RegExp(r'^[0-9A-F]{6}$').hasMatch(s)) return null;
    return Color(int.parse(s, radix: 16) | 0xFF000000);
  }

  // ==================== 品牌调色板派生 ====================
  // 主题色只存一个数（主亮色），其余色位从它派生。HSL 参数按默认荧光绿
  // （#00FF8C）反推，保证选「荧光绿」时各派生色与手写的品牌色板高度贴近
  // （个位级色差，肉眼不可分）：
  //   deep   = 浅色主色/深色渐变尾色（≈ #00904A）
  //   line   = 深色输入框细边框（#00522C）
  //   divider= 深色各类边线（#2B7A4B）
  //   onBright = 亮色底上的前景深墨绿（#00280F）
  //   container / onContainer = 深色容器底与容器前景

  /// 派生主色的 HSL 中间量
  static HSLColor _hsl(Color c) => HSLColor.fromColor(c);

  /// 渐变深绿 / 浅色主题主色（默认荧光绿下 ≈ #00904A）
  static Color deriveDeep(Color accent) =>
      _hsl(accent).withLightness(0.282).withSaturation(1.0).toColor();

  /// 品牌中绿（浅色主题字标渐变尾色：把深绿主色提亮一档，白底上仍可读）
  static Color deriveMidGreen(Color deep) =>
      _hsl(deep).withSaturation(1.0).withLightness(0.353).toColor();

  /// 辅助深色（细刻度线）
  static Color deriveLine(Color accent) =>
      _hsl(accent).withLightness(0.16).withSaturation(1.0).toColor();

  /// 分割线 / 边线
  static Color deriveDivider(Color accent) =>
      _hsl(accent).withLightness(0.32).withSaturation(0.475).toColor();

  /// 亮色底上的前景深墨绿（保证 onPrimary 对比度）
  static Color deriveOnBright(Color accent) =>
      _hsl(accent).withLightness(0.08).withSaturation(1.0).toColor();

  /// 深色 PrimaryContainer
  static Color deriveContainerDark(Color accent) =>
      _hsl(accent).withLightness(0.11).withSaturation(0.6).toColor();

  /// 深色容器前景
  static Color deriveOnContainerDark(Color accent) =>
      _hsl(accent).withLightness(0.86).withSaturation(1.0).toColor();

  /// 浅色 PrimaryContainer
  static Color deriveContainerLight(Color accent) =>
      _hsl(accent).withLightness(0.9).withSaturation(0.5).toColor();

  /// 浅色容器前景
  static Color deriveOnContainerLight(Color accent) =>
      _hsl(accent).withLightness(0.145).withSaturation(1.0).toColor();

  /// 浅色分割线（浅底上的边线）
  static Color deriveDividerLight(Color accent) =>
      _hsl(accent).withLightness(0.84).withSaturation(0.3).toColor();

  /// 浅色输入框常态边框
  static Color deriveInputBorderLight(Color accent) =>
      _hsl(accent).withLightness(0.79).withSaturation(0.33).toColor();

  /// 深色 AppBar 前景（近白的同族淡色）
  static Color deriveAppBarForeground(Color accent) =>
      _hsl(accent).withLightness(0.92).withSaturation(1.0).toColor();

  /// 深色描边（outline：比分割线更灰，与深底保持层次）
  static Color deriveOutlineDark(Color accent) =>
      _hsl(accent).withLightness(0.46).withSaturation(0.22).toColor();

  /// 从存储值恢复主题色选择（无法识别的值一律回到默认荧光绿）
  ///
  /// 存储格式：预设直接存 key（如 'mint_green'）；自定义存 'custom|RRGGBB'。
  void _restoreAccent(String? stored) {
    if (stored == null || stored.isEmpty) {
      _accentKeySelected = 'bright_green';
      _customAccentHex = defaultAccentHex;
      return;
    }
    if (stored.startsWith('$customAccentKey$_sep')) {
      final String hex =
          stored.substring(customAccentKey.length + _sep.length);
      if (_parseHex(hex) != null) {
        _accentKeySelected = customAccentKey;
        _customAccentHex = hex.toUpperCase();
        return;
      }
    } else if (accentPresets.any((AccentPreset p) => p.key == stored)) {
      _accentKeySelected = stored;
    } else {
      _accentKeySelected = 'bright_green';
    }
    _customAccentHex = defaultAccentHex;
  }

  /// 从本地存储加载主题模式与主题色（应用启动时调用）
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final String? value = prefs.getString(_key);
    if (value == 'light') {
      _mode = ThemeMode.light;
    } else if (value == 'dark') {
      _mode = ThemeMode.dark;
    } else {
      _mode = ThemeMode.system;
    }
    _restoreAccent(prefs.getString(_accentKey));
    notifyListeners();
  }

  /// 切换主题模式并持久化
  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, _modeToString(mode));
  }

  /// 将主题模式转为持久化字符串
  static String _modeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  /// 切换主题色（预设 key）并持久化；自定义色不走这里，见 [applyCustomAccent]
  Future<void> setAccent(String key) async {
    if (key == customAccentKey) return;
    if (!accentPresets.any((AccentPreset p) => p.key == key)) return;
    if (_accentKeySelected == key) return;
    _accentKeySelected = key;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accentKey, key);
  }

  /// 应用自定义十六进制主题色并持久化；非法值直接忽略（报错由输入框自己负责）。
  Future<void> applyCustomAccent(String hex) async {
    final Color? parsed = _parseHex(hex);
    if (parsed == null) return;
    // 统一存成不带 # 的 'RRGGBB'，回显时再补 #
    final String normalized =
        _parseHex(hex)!.toARGB32().toRadixString(16).substring(2).toUpperCase();
    final bool changed = _accentKeySelected != customAccentKey ||
        _customAccentHex != normalized;
    _accentKeySelected = customAccentKey;
    _customAccentHex = normalized;
    if (!changed) return;
    notifyListeners();
    await _saveAccentValue('$customAccentKey$_sep$normalized');
  }

  /// 存储值里「自定义」的编码分隔符：'custom|RRGGBB'
  static const String _sep = '|';

  Future<void> _saveAccentValue(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accentKey, value);
  }
}
