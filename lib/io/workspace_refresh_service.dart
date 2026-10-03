import 'package:flutter/foundation.dart';

/// 工作空间数据变更所影响的面板区域。
///
/// 用于"增量刷新"：只重载实际发生变更的 tab（文件 / Git / Todo / 正在执行的 tool），
/// 并配合各 tab 的软更新（有旧数据时不显示加载态）消除闪烁。
enum WorkspaceArea {
  /// 文件浏览（文件写入/编辑/上传/删除等）
  files,

  /// Git 历史与分支
  git,

  /// Todo 列表
  todo,

  /// 正在执行的工具（核心的内存登记表快照；工具开始 / 结束时重拉，
  /// 所以卡住的工具会自己出现在右栏「正在执行的 tool」页）
  toolRuns,
}

/// 工作空间数据变更通知（文件 / Git / Todo），按 [WorkspaceArea] 区分。
///
/// 中栏 MessagePanel 收到工具开始 / 结束事件时，依据工具名判定影响的区域并调用
/// [notifyWorkspaceChanged]（工具开始 / 结束都会带上 [WorkspaceArea.toolRuns]，
/// 因为核心的登记表此刻变了）；右栏 FilePanel 监听后只刷新对应区域，实现
/// 增量同步——它再按区域把刷新计数透给各页（如 TodoPanel / ToolRunsPanel）。
///
/// 采用全局 ChangeNotifier 单例（与 LocalExecutorService 同风格），
/// 因同一时刻只有一个活跃的当前 Agent / FilePanel，无需按工作空间过滤。
class WorkspaceRefreshService extends ChangeNotifier {
  WorkspaceRefreshService._();

  static final WorkspaceRefreshService instance = WorkspaceRefreshService._();

  DateTime? _lastNotify;

  /// 等待合并的区域（防抖窗口内累积）
  Set<WorkspaceArea> _pending = <WorkspaceArea>{};

  /// 最近一次通知携带的区域（由 FilePanel 消费）
  Set<WorkspaceArea>? _lastAreas;

  /// 节流窗口：工具循环中连续 `tool_end` 会被合并，避免高频拉取。
  static const Duration cooldown = Duration(milliseconds: 600);

  /// 触发一次工作空间变更通知（带节流，缺省视为文件区域）。
  ///
  /// 防抖窗口内的多次调用会合并区域后一次性通知，避免连续工具结束时高频重拉。
  void notifyWorkspaceChanged([
    Iterable<WorkspaceArea> areas = const [WorkspaceArea.files],
  ]) {
    _pending.addAll(areas);
    final DateTime now = DateTime.now();
    if (_lastNotify != null && now.difference(_lastNotify!) < cooldown) {
      return;
    }
    if (_pending.isEmpty) return;
    _lastAreas = Set<WorkspaceArea>.of(_pending);
    _pending = <WorkspaceArea>{};
    _lastNotify = now;
    notifyListeners();
  }

  /// 取走最近一次通知携带的区域（消费一次后清空）。
  Set<WorkspaceArea>? takeAreas() {
    final Set<WorkspaceArea>? a = _lastAreas;
    _lastAreas = null;
    return a;
  }
}