import 'package:flutter/material.dart';

/// 二分窗格：按 [axis] 把 [first] / [second] 排开，中间一条可拖的分隔条。
///
/// 为什么单独抽出来：分屏的"布局 + 拖动比例 + 太窄降级"是纯几何，跟文件、编辑器、
/// 网络都没关系——抽成独立控件才能单独测（拖一下比例真的变、太窄真的只留一个），
/// 不然只能靠人肉点。
class SplitPanes extends StatelessWidget {
  const SplitPanes({
    super.key,
    required this.axis,
    required this.ratio,
    required this.onRatioChanged,
    required this.first,
    required this.second,
    this.degraded,
    this.minExtent = 120,
    this.degradeBelow = 260,
    this.dividerWidth = 7,
  });

  /// 分屏方向：horizontal = 左右并排，vertical = 上下
  final Axis axis;

  /// 第一个窗格占的比例（0.2–0.8）
  final double ratio;

  /// 拖动分隔条时回调新比例（已经夹在 0.2–0.8）
  final ValueChanged<double> onRatioChanged;

  final Widget first;
  final Widget second;

  /// 可用空间太小（< [degradeBelow]）时只显示它——两个都挤到 120px 谁也用不了
  final Widget? degraded;

  /// 单个窗格的最小尺寸
  final double minExtent;

  /// 低于这个可用尺寸就降级成单窗格
  final double degradeBelow;

  final double dividerWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool horizontal = axis == Axis.horizontal;
        final double available =
            (horizontal ? constraints.maxWidth : constraints.maxHeight) -
                dividerWidth;
        if (available < degradeBelow && degraded != null) return degraded!;
        // 没有降级控件时也要活得下去：可用空间比两倍最小尺寸还小时，把最小值砍半，
        // 否则 clamp(120, 73) 会直接抛（宁可两个窄窗格，也不能崩）
        final double minSide =
            minExtent > available / 2 ? available / 2 : minExtent;
        final double firstExtent =
            (available * ratio).clamp(minSide, available - minSide);
        return Flex(
          direction: axis,
          children: <Widget>[
            SizedBox(
              width: horizontal ? firstExtent : null,
              height: horizontal ? null : firstExtent,
              child: first,
            ),
            _SplitDivider(
              axis: axis,
              width: dividerWidth,
              onDelta: (double delta) {
                final double next = (ratio + delta / available).clamp(0.2, 0.8);
                if (next != ratio) onRatioChanged(next);
              },
            ),
            Expanded(child: second),
          ],
        );
      },
    );
  }
}

/// 可拖的分隔条：横向分屏时是竖条（左右拖），纵向时是横条（上下拖）
class _SplitDivider extends StatelessWidget {
  const _SplitDivider({
    required this.axis,
    required this.width,
    required this.onDelta,
  });

  final Axis axis;
  final double width;
  final ValueChanged<double> onDelta;

  @override
  Widget build(BuildContext context) {
    final bool horizontal = axis == Axis.horizontal;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate:
            horizontal ? (DragUpdateDetails d) => onDelta(d.delta.dx) : null,
        onVerticalDragUpdate:
            horizontal ? null : (DragUpdateDetails d) => onDelta(d.delta.dy),
        child: SizedBox(
          width: horizontal ? width : null,
          height: horizontal ? null : width,
          child: Center(
            child: Container(
              width: horizontal ? 1 : double.infinity,
              height: horizontal ? double.infinity : 1,
              color: Theme.of(context).dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}
