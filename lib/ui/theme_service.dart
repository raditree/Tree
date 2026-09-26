import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题管理服务
///
/// 负责应用主题模式（浅色 / 深色 / 跟随系统）的保存与恢复。
/// 使用 [ChangeNotifier]，应用根 Widget 监听它并在切换时重建主题。
class ThemeService extends ChangeNotifier {
  /// 全局单例
  static final ThemeService instance = ThemeService._();

  /// shared_preferences 中的存储键名
  static const String _key = 'theme_mode';

  ThemeMode _mode = ThemeMode.system;

  ThemeService._();

  /// 当前主题模式
  ThemeMode get mode => _mode;

  /// 从本地存储加载主题模式（应用启动时调用）
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
}
