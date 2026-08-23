import 'package:flutter/foundation.dart';

/// 工作空间数据变更通知（文件 / Git / Todo）。
///
/// 中栏 MessagePanel 收到工具结束事件时触发 [notifyWorkspaceChanged]，
/// 右栏 FilePanel 监听后即时刷新，无需"切 Tab 再切回"。
///
/// 采用全局 ChangeNotifier 单例（与 LocalExecutorService 同风格），
/// 因同一时刻只有一个活跃的当前 Agent / FilePanel，无需按工作空间过滤。
class WorkspaceRefreshService extends ChangeNotifier {
  WorkspaceRefreshService._();

  static final WorkspaceRefreshService instance = WorkspaceRefreshService._();

  DateTime? _lastNotify;

  /// 节流窗口：工具循环中连续 `tool_end` 会被合并，避免高频拉取。
  static const Duration cooldown = Duration(milliseconds: 600);

  /// 触发一次工作空间变更通知（带节流）。
  void notifyWorkspaceChanged() {
    final DateTime now = DateTime.now();
    if (_lastNotify != null && now.difference(_lastNotify!) < cooldown) {
      return;
    }
    _lastNotify = now;
    notifyListeners();
  }
}