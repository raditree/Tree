import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 界面文字缩放服务
///
/// 负责应用内「界面文字大小」的保存与恢复。
/// 使用 [ChangeNotifier]，应用根 Widget 监听它，并在变化时把缩放值
/// 注入 MaterialApp 的 MediaQuery.textScaler，全局 Text 自动跟随。
///
/// 与系统无障碍缩放的关系：本值是**在系统缩放之上**再乘一次
/// （MediaQuery 会保留系统 textScaler，App 内缩放叠加其上）。
class TextScaleService extends ChangeNotifier {
  /// 全局单例
  static final TextScaleService instance = TextScaleService._();

  /// shared_preferences 中的存储键名
  static const String _key = 'text_scale';

  /// 允许的缩放范围（含）
  static const double minScale = 0.8;
  static const double maxScale = 1.5;

  /// 默认缩放（= 系统原样）
  static const double defaultScale = 1.0;

  double _scale = defaultScale;

  TextScaleService._();

  /// 当前缩放系数（1.0 = 不缩放）
  double get scale => _scale;

  /// 从本地存储加载缩放（应用启动时调用）
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final double? value = prefs.getDouble(_key);
    _scale = (value ?? defaultScale).clamp(minScale, maxScale).toDouble();
    notifyListeners();
  }

  /// 设置缩放并持久化。
  ///
  /// 先更新内存值并 notifyListeners（让滑杆拖动时 UI 立即跟随），
  /// 再异步写盘——拖动会高频触发本方法，同步 await 写盘会拖慢拖动。
  void setScale(double value) {
    final double next = value.clamp(minScale, maxScale).toDouble();
    if (_scale == next) return;
    _scale = next;
    notifyListeners();
    _persist(next);
  }

  Future<void> _persist(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key, value);
  }
}