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
///
/// **拖它的时候**（用户 2026-10-03：「滑块乱跳」）另有两处硬要求：
/// ① 按位置反解下标（[messageScrollbarIndexAt]）必须是绘制几何的**严格逆**——两边
///    各算一套就会差 `total/(total-visible)` 倍，抓一下拇指就被自己报出去的下标甩走；
/// ② 拖拽期间把几何输入与拇指位置**都钉住**（[_MessageScrollbarState._dragFraction]）：
///    列表补页/落点估算每帧都在变，让拇指跟着"实际落到哪"画，它就不在指针下了。
///    这是**以指针为准、松手再对齐**的取舍：拖的时候手感是"抓到哪就是哪"，
///    松手后跳一下到列表的真实位置。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/message_window.dart';

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

/// 拇指（那条能拖的短棒）的 key：用例直接量它的位置——「拖拽时抓哪儿是哪儿」只能靠量位置钉住。
const Key messageScrollbarThumbKey = ValueKey<String>('message-scrollbar-thumb');

/// 要不要画滑块：视口里装得下整份会话就不画（没得滚）。
bool messageScrollbarVisible({
  required int total,
  required int firstVisible,
  required int lastVisible,
}) {
  if (total <= 0 || firstVisible < 0 || lastVisible < firstVisible) return false;
  return total > lastVisible - firstVisible + 1;
}

/// 滑块几何的两个中间量：**绘制与反解必须同源**。
///
/// 各算一次就会各差一点（旧口径画的时候分母是 `total - visible`、反解的时候乘的是
/// `total`，差 `total/(total-visible)` 倍），拖滑块时拇指就会被自己反解出来的下标甩走。
({int visible, int maxFirst}) _barMetrics({
  required int total,
  required int firstVisible,
  required int lastVisible,
}) {
  final int visible = lastVisible < firstVisible
      ? 1
      : (lastVisible - firstVisible + 1);
  final int maxFirst = total - visible;
  return (visible: visible, maxFirst: maxFirst < 0 ? 0 : maxFirst);
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
  final ({int visible, int maxFirst}) m = _barMetrics(
    total: total,
    firstVisible: firstVisible,
    lastVisible: lastVisible,
  );
  final int visible = m.visible;
  double fraction = total <= 0 ? 1 : visible / total;
  if (fraction < minFraction) fraction = minFraction;
  if (fraction > 1) fraction = 1;
  final double length = (track * fraction).clamp(0.0, track);
  final double room = track - length;
  // 位置按下标比：0 = 最旧那条在视口顶，1 = **最后一条**在视口底（滑块贴底）。
  // 分母用"第一条能到的最大下标"（total - visible），这样"看到末尾"就是真的贴底。
  final double frac = m.maxFirst <= 0
      ? 0
      : (firstVisible / m.maxFirst).clamp(0.0, 1.0);
  return ScrollbarThumb(top: room <= 0 ? 0 : room * frac, length: length);
}

/// [messageScrollbarThumb] 的**严格逆映射**：给定"拇指顶端该在的位置"[top]（已减掉抓取偏移、
/// 已夹进轨道内），反解出它对应的全局下标。
///
/// 为什么必须严格互逆：拖滑块时要"抓哪儿是哪儿"——指针不动，反解出来的下标就不该变。
/// 旧口径画的时候按下标比（分母 `total - visible`）、反解时却乘 `total`，两条几何差
/// `total/(total-visible)` 倍：长会话约 1%，短会话（`total=100`、看得见 25 条）能到 33%
/// ——拇指被自己反解出来的下标甩到指针前面，看起来就是「乱跳」（用户 2026-10-03）。
int messageScrollbarIndexAt({
  required double track,
  required int total,
  required int firstVisible,
  required int lastVisible,
  required double top,
  double minFraction = kMessageScrollbarMinFraction,
}) {
  if (total <= 0 || track <= 0) return 0;
  final ScrollbarThumb thumb = messageScrollbarThumb(
    track: track,
    total: total,
    firstVisible: firstVisible,
    lastVisible: lastVisible,
    minFraction: minFraction,
  );
  final double room = track - thumb.length;
  if (room <= 0) return 0;
  final int maxFirst = _barMetrics(
    total: total,
    firstVisible: firstVisible,
    lastVisible: lastVisible,
  ).maxFirst;
  if (maxFirst <= 0) return 0;
  final double frac = (top / room).clamp(0.0, 1.0);
  return (frac * maxFirst).round().clamp(0, total - 1);
}

/// 中栏右侧的全局下标滑块：拖到哪就请面板把那一带加载出来（[onSeek]）。
///
/// **几何输入是"视口坐标"**（[MessageWindowCoordinate]，列表帧后刷新）：拇指直接监听它，
/// 所以滚动时只重绘拇指、不重建列表（丝滑）。
class MessageScrollbar extends StatefulWidget {
  const MessageScrollbar({
    super.key,
    required this.coordinate,
    required this.onSeek,
    this.onSeekSettled,
  });

  /// 视口在整份历史里的坐标（=-1/-1 表示还没量出来）。
  final ValueListenable<MessageWindowCoordinate> coordinate;

  /// 拖到 / 点到某个全局下标（列表据此跳到那一带；那一带的补页由面板按坐标做）。
  final void Function(int index) onSeek;

  /// 松手（或点击）之后：请列表把落点**校正**到该下标（null = 不校正）。
  ///
  /// 落点是估算的（占位槽 88px/条 vs 已加载消息的真实高度），松手后由列表用实测
  /// 落点反馈两三次收口——否则拇指停在指针那儿、内容却停在别处，拇指只好"回落"。
  final void Function(int index)? onSeekSettled;

  @override
  State<MessageScrollbar> createState() => _MessageScrollbarState();
}

class _MessageScrollbarState extends State<MessageScrollbar> {
  /// 鼠标悬停 / 正在拖：滑块加粗一点（Material 滑块的既有观感）
  bool _active = false;

  /// 抓取点相对滑块顶端的偏移（拖拽时保持"抓哪儿是哪儿"）
  double _grab = 0;

  /// 拖拽期间**冻结**的几何输入（null = 不在拖拽）。
  ///
  /// 拖的时候列表正在补页、视口每帧都在动；若每帧都拿实时输入反解，指针没动下标也在变
  /// ⇒ 拇指从指针下滑走。按下时锁一份，松开再交回实时值。
  int? _dragTotal;
  int? _dragFirst;
  int? _dragLast;

  /// 拖拽期间拇指该在的位置（占比 0..1，相对"拇指顶端能走的区间"）；null = 不在拖拽。
  ///
  /// 拖拽期间**拇指跟着指针走、不等列表**：落点是估算的（`下标 × 占位槽高度`，见
  /// [MessageList.onSeek]），若让拇指按"列表实际落到哪"画，一拖就滑到指针外面去。
  /// 松手后交回真实下标（会跳一下——那是列表的真实位置，不是抖动）。
  double? _dragFraction;

  int get _total => _dragTotal ?? widget.coordinate.value.total;
  int get _first => _dragFirst ?? widget.coordinate.value.first;
  int get _last => _dragLast ?? widget.coordinate.value.last;

  /// 拖拽 / 点击最后报出去的下标（松手时用它请求落点校正）。
  int _lastSeekIndex = 0;

  ScrollbarThumb _thumb(double track) => messageScrollbarThumb(
        track: track,
        total: _total,
        firstVisible: _first,
        lastVisible: _last,
      );

  /// 指针位置 → 拇指顶端该在的位置（减掉抓取偏移、夹进轨道）。
  double _topFor(double dy, double track, ScrollbarThumb thumb) {
    final double room = track - thumb.length;
    return room <= 0 ? 0 : (dy - _grab).clamp(0.0, room);
  }

  /// 按下：冻结几何输入（拖拽全程用同一份，见 [_dragTotal]）。
  void _beginDrag() {
    _dragTotal = widget.coordinate.value.total;
    _dragFirst = widget.coordinate.value.first;
    _dragLast = widget.coordinate.value.last;
    _dragFraction = null;
  }

  /// 松手 / 手势取消：解冻，拇指交回**实时坐标**，并请列表把落点收口到目标下标。
  void _endDrag() {
    final int settled = _lastSeekIndex;
    setState(() {
      _active = false;
      _dragTotal = null;
      _dragFirst = null;
      _dragLast = null;
      _dragFraction = null;
    });
    widget.onSeekSettled?.call(settled);
  }

  @override
  Widget build(BuildContext context) {
    // 坐标变了就重建拇指：**只重绘拇指**（列表不重建），滚动才跟手且不卡
    return ValueListenableBuilder<MessageWindowCoordinate>(
      valueListenable: widget.coordinate,
      builder: (BuildContext context, MessageWindowCoordinate _, Widget? child) {
        return _buildBar(context);
      },
    );
  }

  Widget _buildBar(BuildContext context) {
    if (!messageScrollbarVisible(
      total: _total,
      firstVisible: _first,
      lastVisible: _last,
    )) {
      return const SizedBox.shrink();
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double track = constraints.maxHeight;
        final ScrollbarThumb thumb = _thumb(track);
        final double room = track - thumb.length;
        // 拖拽中钉在指针下（见 [_dragFraction]），否则按全局下标画。
        final double top = _dragFraction == null
            ? thumb.top
            : (room <= 0 ? 0 : room * _dragFraction!);
        return MouseRegion(
          cursor: SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _active = true),
          onExit: (_) => setState(() => _active = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (DragStartDetails d) {
              _beginDrag();
              setState(() => _active = true);
              final double dy = d.localPosition.dy;
              _grab = (dy >= thumb.top && dy <= thumb.top + thumb.length)
                  ? dy - thumb.top
                  : thumb.length / 2;
              _seek(dy, track);
            },
            onVerticalDragUpdate: (DragUpdateDetails d) =>
                _seek(d.localPosition.dy, track),
            onVerticalDragEnd: (_) => _endDrag(),
            onVerticalDragCancel: () => _endDrag(),
            onTapDown: (TapDownDetails d) {
              // 单击 = 直接把那一带拉出来：不做抓取保持（下一帧拇指就归位到真实下标）
              _grab = thumb.length / 2;
              final int index = messageScrollbarIndexAt(
                track: track,
                total: _total,
                firstVisible: _first,
                lastVisible: _last,
                top: _topFor(d.localPosition.dy, track, thumb),
              );
              _lastSeekIndex = index;
              widget.onSeek(index);
              // 点的落点也是估算的：请列表校正一次，落点才真的到得了
              widget.onSeekSettled?.call(index);
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
                  top: top,
                  width: 6,
                  height: thumb.length,
                  child: DecoratedBox(
                    key: messageScrollbarThumbKey,
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

  /// 拖动中：把指针位置反解成全局下标报出去（[onSeek]），并把拇指钉在指针下。
  void _seek(double dy, double track) {
    final ScrollbarThumb thumb = _thumb(track);
    final double room = track - thumb.length;
    final double top = _topFor(dy, track, thumb);
    setState(() {
      _dragFraction = room <= 0 ? 0 : top / room;
    });
    final int index = messageScrollbarIndexAt(
      track: track,
      total: _total,
      firstVisible: _first,
      lastVisible: _last,
      top: top,
    );
    _lastSeekIndex = index;
    widget.onSeek(index);
  }
}
