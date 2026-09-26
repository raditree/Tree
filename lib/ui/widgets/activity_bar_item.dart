import 'package:flutter/material.dart';

/// 左侧活动栏的**面板切换项**（选中态带左侧高亮指示条 + 主色图标）。
///
/// 从 main_page.dart 抽出为公共控件（Q12）：既有的「Agent 列表 / 插件 / 下载」
/// 与追加的**插件项**必须共用同一套尺寸与观感，抽出来后插件项不可能与既有项
/// 视觉漂移；活动栏项的点击语义（切面板 + 展开左栏）仍由调用方决定。
class ActivityBarItem extends StatelessWidget {
  /// 构造。
  const ActivityBarItem({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  /// 未选中图标。
  final IconData icon;

  /// 选中图标。
  final IconData selectedIcon;

  /// 悬停提示（活动栏没有文字，提示是唯一的可读标签）。
  final String tooltip;

  /// 是否选中（决定高亮指示条与图标色）。
  final bool selected;

  /// 点击回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Row(
            children: <Widget>[
              // 选中指示条
              Container(
                width: 2,
                height: 44,
                color: selected ? cs.primary : Colors.transparent,
              ),
              Expanded(
                child: Icon(
                  selected ? selectedIcon : icon,
                  size: 22,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 左侧活动栏的**动作**按钮（非面板切换：不参与选中态、无高亮指示条）。
///
/// 与 [ActivityBarItem] 共用尺寸与图标规格，保证视觉一致；区别是点击不会改变
/// 左栏面板（例如底部的「设置」全局入口）。
class ActivityBarAction extends StatelessWidget {
  /// 构造。
  const ActivityBarAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  /// 图标。
  final IconData icon;

  /// 悬停提示。
  final String tooltip;

  /// 点击回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Row(
            children: <Widget>[
              // 与面板项对齐的占位（无选中色）
              const SizedBox(width: 2),
              Expanded(
                child: Icon(icon, size: 22, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
