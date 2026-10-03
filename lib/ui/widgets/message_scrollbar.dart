/// 中栏右侧那条**按全局下标算**的滑块（用户 2026-10-04）。
///
/// 用户原话：「上滑过程中右侧滑块跳来跳去（右侧滑块位置按全局长度算，滑到哪加载哪，
/// 限制缓存长度，仅缓存窗口附近的消息）」。
///
/// 为什么不能用 Flutter 自带的 [Scrollbar]：它的几何完全来自**已构建内容**的
/// 滚动范围（`maxScrollExtent` / `viewportDimension`）。窗口化列表里这个范围是
/// 估算出来的——取回来的那几段按真实高度、占位槽按占位高度，**平均值随构建到哪而变**，
/// 于是滑块位置/长度会随着滚动来回跳。这里的几何只依赖**全局下标**：
///
/// - 位置 = 视口内第一条的全局下标 / 全局总条数；
/// - 长度 = 视口里能看到几条 / 全局总条数（下限 [kMessageScrollbarMinFraction]）；
///
/// 全局总条数只随新消息增长（见 [MessageWindow]），补页/淘汰都不改变它 ⇒ 上滑时
/// 滑块稳稳地跟着视口走。
library;

import 'package:flutter/material.dart';

/// 滑块几何（纯函数，单测直接钉它）。
@immutable
class ScrollbarThumb {
  const ScrollbarThumb({required this.top, required this.length});

  /// 滑块顶端（相对轨道顶部，px）。
  final double top;

  /// 滑块长度（px）。
  final double length;

  @override
  bool operator ==(Object other) =>
      other is ScrollbarThumb && other.top == top && other.length == length;

  @override
  int get hashCode => Object.hash(top, length);

  @override
  String toString() => 'ScrollbarThumb(top: $top, length: $length)';
}

/// 滑块的最小占比：再长的一份历史也得留一条抓得住的滑块。
const double kMessageScrollbarMinFraction = 0.06;

/// 要不要画滑块：视口里装得下整份会话就不画（没得滚）。
bool messageScrollbarVisible({
  required int total,
  required int firstVisible,
  required int lastVisible,
}) {
  if (total <= 0 || firstVisible < 0 || lastVisible < firstVisible) return false;
  return total > lastVisible - firstVisible + 1;
}

/// 按全局下标算滑块几何：见文件头。
ScrollbarThumb messageScrollbarThumb({
  required double track,
  required int total,
  required int firstVisible,
  required int lastVisible,
  double minFraction = kMessageScrollbarMinFraction,
}) {
  if (track <= 0) return const ScrollbarThumb(top: 0, length: 0);
  final int visible = lastVisible < firstVisible
      ? 1
      : (lastVisible - firstVisible + 1);
  double fraction = total <= 0 ? 1 : visible / total;
  if (fraction < minFraction) fraction = minFraction;
  if (fraction > 1) fraction = 1;
  final double length = (track * fraction).clamp(0.0, track);
  final double room = track - length;
  // 位置按下标比：0 = 最旧那条在视口顶，1 = **最后一条**在视口底（滑块贴底）。
  // 分母用"第一条能到的最大下标"（total - visible），这样"看到末尾"就是真的贴底。
  final int maxFirst = total - visible;
  final double frac = maxFirst <= 0
      ? 0
      : (firstVisible / maxFirst).clamp(0.0, 1.0);
  return ScrollbarThumb(top: room <= 0 ? 0 : room * frac, length: length);
}

/// 中栏右侧的全局下标滑块：拖到哪就请面板把那一带加载出来（[onSeek]）。
class MessageScrollbar extends StatefulWidget {
  const MessageScrollbar({
    super.key,
    required this.total,
    required this.firstVisible,
    required this.lastVisible,
    required this.onSeek,
  });

  /// 全局总条数（=[MessageWindow.total]，只随新消息增长）。
  final int total;

  /// 视口内第一条的全局下标（-1 = 还没量出来）。
  final int firstVisible;

  /// 视口内最后一条的全局下标。
  final int lastVisible;

  /// 拖到某个全局下标（面板据此补页；列表自己也会跳到那一带的估算位置）。
  final void Function(int index) onSeek;

  @override
  State<MessageScrollbar> createState() => _MessageScrollbarState();
}

class _MessageScrollbarState extends State<MessageScrollbar> {
  /// 鼠标悬停 / 正在拖：滑块加粗一点（Material 滑块的既有观感）
  bool _active = false;

  /// 抓取点相对滑块顶端的偏移（拖拽时保持"抓哪儿是哪儿"）
  double _grab = 0;

  @override
  Widget build(BuildContext context) {
    if (!messageScrollbarVisible(
      total: widget.total,
      firstVisible: widget.firstVisible,
      lastVisible: widget.lastVisible,
    )) {
      return const SizedBox.shrink();
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double track = constraints.maxHeight;
        final ScrollbarThumb thumb = messageScrollbarThumb(
          track: track,
          total: widget.total,
          firstVisible: widget.firstVisible,
          lastVisible: widget.lastVisible,
        );
        return MouseRegion(
          cursor: SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _active = true),
          onExit: (_) => setState(() => _active = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (DragStartDetails d) {
              setState(() => _active = true);
              final double dy = d.localPosition.dy;
              _grab = (dy >= thumb.top && dy <= thumb.top + thumb.length)
                  ? dy - thumb.top
                  : thumb.length / 2;
              _seek(dy, track, thumb);
            },
            onVerticalDragUpdate: (DragUpdateDetails d) =>
                _seek(d.localPosition.dy, track, thumb),
            onVerticalDragEnd: (_) => setState(() => _active = false),
            onVerticalDragCancel: () => setState(() => _active = false),
            onTapDown: (TapDownDetails d) {
              _grab = thumb.length / 2;
              _seek(d.localPosition.dy, track, thumb);
            },
            child: Stack(
              children: <Widget>[
                // 悬停时给一条极淡的轨道，"这条能拖"一眼看得出来
                if (_active)
                  Positioned(
                    right: 4,
                    top: 0,
                    bottom: 0,
                    width: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                Positioned(
                  right: 4,
                  top: thumb.top,
                  width: 6,
                  height: thumb.length,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.onSurfaceVariant.withValues(
                        alpha: _active ? 0.7 : 0.4,
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 把指针位置换算成全局下标：轨道上"滑块顶端能到哪"就是下标的 0..total 区间。
  void _seek(double dy, double track, ScrollbarThumb thumb) {
    final double room = track - thumb.length;
    final double top = room <= 0 ? 0 : (dy - _grab).clamp(0.0, room);
    final double frac = room <= 0 ? 0 : top / room;
    final int index = frac <= 0
        ? 0
        : (frac * widget.total).floor().clamp(0, widget.total - 1);
    widget.onSeek(index);
  }
}
