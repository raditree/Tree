import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 编辑器的客户端偏好（落 SharedPreferences，与托盘设置同一套做法）。
///
/// 只有两个开关，**没有定时自动保存**：定时器会在人正打到一半时写盘，而真正会丢
/// 内容的时刻是「切走 / 关掉这个文件」——所以自动保存的形态定成**失焦与离开时保存**
/// （2026-10-02 用户定夺）。手动保存始终可用：标题栏的保存键或 Ctrl+S。
class EditorSettings extends ChangeNotifier {
  EditorSettings._();

  /// 全局单例（与 ThemeService / TrayService 同形态）
  static final EditorSettings instance = EditorSettings._();

  static const String _kSaveOnBlur = 'editor_save_on_blur';
  static const String _kHighlight = 'editor_highlight';

  bool _saveOnBlur = true;
  bool _highlight = true;

  /// 失焦 / 关闭窗格 / 换文件时自动保存（默认开）
  bool get saveOnBlur => _saveOnBlur;

  /// 源码模式按语言着色（默认开；大文件无论如何都不着色，见 kHighlightMaxChars）
  bool get highlight => _highlight;

  /// 启动时装载（main.dart 调用；测试里不调，用默认值）
  Future<void> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _saveOnBlur = prefs.getBool(_kSaveOnBlur) ?? true;
    _highlight = prefs.getBool(_kHighlight) ?? true;
    notifyListeners();
  }

  Future<void> setSaveOnBlur(bool value) async {
    if (_saveOnBlur == value) return;
    _saveOnBlur = value;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSaveOnBlur, value);
  }

  Future<void> setHighlight(bool value) async {
    if (_highlight == value) return;
    _highlight = value;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHighlight, value);
  }
}
