/// 中栏消息流的**窗口**（用户 2026-10-04）。
///
/// 用户原话：「现在懒加载，上滑过程中右侧滑块跳来跳去（右侧滑块位置按全局长度算，
/// 滑到哪加载哪，限制缓存长度，仅缓存窗口附近的消息）」——这个文件就是那句话的模型：
///
/// - **按全局下标寻址**：整份会话流是一张"槽位表"，下标 0 = 最旧那条。槽位里要么是
///   已经取回来的消息，要么是 `null`（还没加载 = 界面上的占位槽）。滑块的"全局长度"
///   口径就是这个表的长度——**长度只随新消息增长，不随加载/淘汰变化**，所以上滑补页
///   时滑块不会跳来跳去；
/// - **滑到哪加载哪**：面板拿视口附近的下标区间问 [gapsFor]，只补那一段；
/// - **限制缓存长度**：离开视口又离末尾太远的槽位由 [evict] 放回占位（消息对象随之
///   释放）。**正在流式的消息与正在跑的工具卡片永不被淘汰**（正文还在往里写）。
///
/// 这个类只是**模型**：不做 IO、不碰 Widget。放页（核心给了 offset）、淘汰、找缺口
/// 都是纯函数，单测直接钉在它上面（见 `test/message_window_test.dart`）。
library;

import 'package:flutter/foundation.dart';

import '../models/message.dart';

/// 一段连续的下标区间：`[from, to)`（左闭右开，与 `sublist` 同口径）。
@immutable
class MessageRange {
  const MessageRange(this.from, this.to);

  final int from;
  final int to;

  bool get isEmpty => to <= from;
  int get length => to <= from ? 0 : to - from;
  bool contains(int index) => index >= from && index < to;

  @override
  bool operator ==(Object other) =>
      other is MessageRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => '[$from, $to)';
}

/// 视口（当前窗口）在**整份历史**里的坐标。
///
/// **用户口径（2026-10-03）**：「计算当前窗口在整个历史中的坐标，右侧拇指位置按坐标计算」。
/// 它是右侧滑块几何的唯一输入，也是面板"滑到哪加载哪 / 只缓存坐标附近"的唯一口径：
/// 列表每帧把**本帧构建到的下标区间**算成它（见 [MessageList.onWindowChanged]），
/// 拇指监听它（滚动时只重绘拇指，不重建列表）。
@immutable
class MessageWindowCoordinate {
  const MessageWindowCoordinate({
    required this.first,
    required this.last,
    required this.total,
  });

  /// 视口内第一条的全局下标（-1 = 还没量出来）。
  final int first;

  /// 视口内最后一条的全局下标。
  final int last;

  /// 整份会话的条数（= [MessageWindow.total]，只随新消息增长）。
  final int total;

  /// 还没量出来（首帧之前）。
  static const MessageWindowCoordinate unknown = MessageWindowCoordinate(
    first: -1,
    last: -1,
    total: 0,
  );

  /// 量出来了没有。
  bool get known => first >= 0 && last >= first;

  /// 视口里看得见几条（未知时 0）。
  int get visible => known ? last - first + 1 : 0;

  /// 滑块能指到的**最靠后下标**：`total - 看得见的条数`（"最后一条正好落在视口底" = 贴底），
  /// 与 [messageScrollbarThumb] 的分母同源。
  int get lastSeekable {
    if (total <= 0) return 0;
    final int v = visible <= 0 ? 1 : visible;
    return (total - v).clamp(0, total - 1);
  }

  /// 这个全局下标在不在视口内。
  bool containsIndex(int index) => known && index >= first && index <= last;

  @override
  bool operator ==(Object other) =>
      other is MessageWindowCoordinate &&
      other.first == first &&
      other.last == last &&
      other.total == total;

  @override
  int get hashCode => Object.hash(first, last, total);

  @override
  String toString() =>
      'MessageWindowCoordinate([$first,$last] of $total)';
}

/// 全局下标 → **滚动像素**：以坐标里的第一条为锚点，按 [step] 像素/条线性外推。
///
/// 为什么以视口第一条为锚点、而不是 `下标 × 占位高度`：占位槽恒定 88px（[kMessagePlaceholderExtent]），
/// 但**已加载消息的真实高度各不相同**，从 0 开始算会把误差一路累积（"拖到中段落点很怪"）。
/// 锚点法在占位区是精确的（88/格），在已加载区只差"这一段平均高度 vs 88"——而
/// "仅缓存坐标附近"这条口径本身就让这两段离视口不远，剩下的误差由
/// [MessageSeekCorrection] 的反馈校正收掉。
///
/// [at] 未知（还没量出来）时退回朴素的 `index × step`。
double pixelOffsetForIndex({
  required int index,
  required MessageWindowCoordinate at,
  required double anchorPixels,
  required double step,
}) {
  final bool known = at.known;
  final int anchor = known ? at.first : 0;
  final double base = known ? anchorPixels : 0;
  return base + (index - anchor) * step;
}

/// 拖拽/点击落点的**反馈校正器**（纯逻辑，单测直接钉）。
///
/// 为什么需要：`jumpTo` 的像素落点由我们算的值直接决定（实测 sliver 不校正），
/// 但"像素 ↔ 全局下标"的换算只是估算（占位区精确、已加载区看平均高度）。与其把估算
/// 做得多准，不如**看实际落在哪再修**：每次观测到 `(实际下标, 实际像素)` 就用它反推
/// 这一带的真实步长（割线法），下一次跳得更准；最多 [maxAttempts] 次、落在
/// [tolerance] 条之内就收手。
///
/// **不和用户抢**：调用方在用户一有新的滚动/拖拽/按键时就把它丢掉（见
/// `MessageListView._cancelSeekCorrection`）。
class MessageSeekCorrection {
  MessageSeekCorrection({
    required this.target,
    required double step,
    this.maxAttempts = 3,
    this.tolerance = 3,
  }) : _step = step > 0 ? step : 1;

  /// 目标全局下标。
  final int target;

  /// 最多校正几次。
  final int maxAttempts;

  /// 落点与目标的容差（条）：进了这个范围就算到位。
  final int tolerance;

  double _step;
  int _attempts = 0;
  bool _finished = false;
  int? _lastLanded;
  double? _lastPixels;

  /// 已经收工（到位 / 放弃）。
  bool get finished => _finished;

  /// 已经校正了几次。
  int get attempts => _attempts;

  /// 当前用的步长（像素/条）：一次观测之后会被真实值替换。
  double get step => _step;

  /// 观测一次落点：返回**下一次该跳到的像素**；null = 到位了、放弃了，或没有新信息。
  double? observe({required int landed, required double pixels}) {
    if (_finished) return null;
    if ((landed - target).abs() <= tolerance) {
      _finished = true;
      return null;
    }
    final int? prevLanded = _lastLanded;
    final double? prevPixels = _lastPixels;
    // 落点与上次一模一样 = 跳不动了（贴到边界 / 目标在那一段外）：收手，别空转。
    if (prevLanded == landed &&
        prevPixels != null &&
        (prevPixels - pixels).abs() < 0.5) {
      _finished = true;
      return null;
    }
    // 两点反推这一带的真实步长（占位区 ≈ 88，已加载区 ≈ 真实平均高度）。
    if (prevLanded != null && prevPixels != null && landed != prevLanded) {
      final double observed = (pixels - prevPixels) / (landed - prevLanded);
      if (observed.isFinite && observed.abs() > 1) _step = observed.abs();
    }
    _lastLanded = landed;
    _lastPixels = pixels;
    if (_attempts >= maxAttempts) {
      _finished = true;
      return null;
    }
    _attempts++;
    return pixels + (target - landed) * _step;
  }
}

/// 把一段**缺口**按"视口顶"切成两次请求（用户 2026-10-03：「中间页的懒加载好像没做好」）。
///
/// 为什么必须切：补页会把占位槽换成真消息，**高度会变**。整页都在视口上方时列表有现成的
/// 高度补偿（`padAboveStamp`），但缺口**横跨视口顶**是常态（视口自己就在缺口里）——
/// 这时上方会长高、视口被整体推下去。切两刀之后：
/// - `[first, gap.to)`：视口及以下，**不改变视口上方的高度** ⇒ 正在看的内容不动；
/// - `[gap.from, first)`：整段在视口上方 ⇒ 走既有的高度补偿路径。
///
/// 顺序也是刻意的：先补视口那一侧，用户马上看到内容；上方那份稍后到达时由补偿接管。
List<MessageRange> splitGapAtViewportTop(MessageRange gap, int first) {
  if (gap.isEmpty) return const <MessageRange>[];
  if (gap.from >= first || gap.to <= first) return <MessageRange>[gap];
  return <MessageRange>[
    MessageRange(first, gap.to),
    MessageRange(gap.from, first),
  ];
}

/// 见文件头：按全局下标寻址的消息窗口。
class MessageWindow {
  MessageWindow({
    this.pageSize = 200,
    this.margin = 200,
    this.tailKeep = 200,
  });

  /// 一次补多少条（正常一页的量级）。
  final int pageSize;

  /// 视口外**多留多少条**：滑得快时不至于每一屏都停下来等网络。
  final int margin;

  /// 末尾始终留着的条数：实时追加落在末尾，替它留好邻居（用户在读历史时也一样）。
  final int tailKeep;

  final List<ChatMessage?> _slots = <ChatMessage?>[];

  /// 已加载消息的 id → 全局下标（放置/追加时维护，淘汰时移除）。
  final Map<String, int> _indexById = <String, int>{};

  /// 槽位表长度 = 这份会话流一共多少条（0 = 还没拉过历史）。
  int get total => _slots.length;

  bool get isEmpty => _slots.isEmpty;

  bool get isNotEmpty => _slots.isNotEmpty;

  /// 槽位表本体（**只读视图**：列表组件按它渲染，放置/淘汰只能在 [place] /
  /// [appendTail] / [evict] 里做）。
  ///
  /// 直接给内部列表而不是拷贝：列表每帧都要按下标取槽位，几千条的浅拷贝没必要。
  List<ChatMessage?> get slots => _slots;

  /// 已加载的条数（观测 / 测试用：缓存长度就是这个数）。
  int get loadedCount => _indexById.length;

  bool isLoaded(int index) =>
      index >= 0 && index < _slots.length && _slots[index] != null;

  ChatMessage? at(int index) =>
      index >= 0 && index < _slots.length ? _slots[index] : null;

  int indexOfId(String id) => id.isEmpty ? -1 : (_indexById[id] ?? -1);

  bool containsId(String id) => indexOfId(id) >= 0;

  /// 已加载的消息（升序）。给"读全量"的消费者用：临时员工过程分栏、详情快照、
  /// 上下文读数——它们要的是"我知道的全部"，不是槽位表。
  List<ChatMessage> get loadedList {
    final List<ChatMessage> out = <ChatMessage>[];
    for (final ChatMessage? m in _slots) {
      if (m != null) out.add(m);
    }
    return out;
  }

  List<String> get loadedIds => List<String>.of(_indexById.keys);

  /// 已加载的槽位落在哪些区间（测试 / 排障用）。
  List<MessageRange> get loadedRanges {
    final List<MessageRange> out = <MessageRange>[];
    int start = -1;
    for (int i = 0; i < _slots.length; i++) {
      if (_slots[i] != null) {
        if (start < 0) start = i;
      } else if (start >= 0) {
        out.add(MessageRange(start, i));
        start = -1;
      }
    }
    if (start >= 0) out.add(MessageRange(start, _slots.length));
    return out;
  }

  /// 把总数补齐到 [count]：多出来的槽位是**占位**（还没加载）。
  ///
  /// 只增不减：本地实时消息可能让槽位表比核心报的 total 还长（核心还没落库），
  /// 那种情况下"更长的那份"才是真话。
  void ensureTotal(int count) {
    if (count <= _slots.length) return;
    while (_slots.length < count) {
      _slots.add(null);
    }
  }

  /// 把一页放进槽位表。[offset] = 这一页第一条的全局下标（核心给的真值）。
  ///
  /// **按 id 对齐**：如果这一页里有本端已经放在别处的消息，就用那条消息的位置
  /// 重算整页的基准（核心那边新落了消息 / 本地有实时消息时，下标可能差几条）。
  /// 同一个 id 全程只允许存在一份：已在别处的直接跳过。
  ///
  /// 返回真正放进去的条数。
  int place({required int offset, required List<ChatMessage> messages}) {
    if (messages.isEmpty) {
      // 空页也说明"这里没有更多了"：至少把长度对齐到 offset
      ensureTotal(offset);
      return 0;
    }
    int base = offset < 0 ? 0 : offset;
    for (int i = 0; i < messages.length; i++) {
      final int known = _indexById[messages[i].id] ?? -1;
      if (known >= 0) {
        base = known - i;
        break;
      }
    }
    if (base < 0) base = 0;
    ensureTotal(base + messages.length);
    int placed = 0;
    for (int i = 0; i < messages.length; i++) {
      final ChatMessage message = messages[i];
      if (_indexById.containsKey(message.id)) continue;
      final int index = base + i;
      if (index < 0 || index >= _slots.length) continue;
      // 目标槽位被别的消息占着 = 对齐有偏差：不覆盖（宁可留空，等下一次按 id 对齐）
      if (_slots[index] != null) continue;
      _slots[index] = message;
      _indexById[message.id] = index;
      placed++;
    }
    return placed;
  }

  /// 末尾追加一条**实时**消息（下标 = 当前长度，即紧接最新一条）。
  ///
  /// 已存在同 id 时**原位替换**（重播的 msg_start / 更完整的副本），不新增槽位。
  void appendTail(ChatMessage message) {
    final int existing = _indexById[message.id] ?? -1;
    if (existing >= 0) {
      _slots[existing] = message;
      return;
    }
    _slots.add(message);
    _indexById[message.id] = _slots.length - 1;
  }

  /// **重载末尾一段**（「回到底部」按钮直接走这条：用户 2026-10-04）。
  ///
  /// 只保留比这一页**更新**的本地实时消息（核心还没落库的那些，通常就是正在流式的
  /// 这一轮），其余槽位一律作废回占位——于是"回到最新"是**确定性**的：一份末尾页
  /// + 一条实时尾巴，不需要在几千条估算高度里找回底部。
  void resetTail({
    required int offset,
    required List<ChatMessage> messages,
  }) {
    final int pageEnd = offset + messages.length;
    final Set<String> pageIds = <String>{
      for (final ChatMessage m in messages) m.id,
    };
    final List<ChatMessage?> kept = List<ChatMessage?>.filled(
      _slots.length,
      null,
    );
    for (int i = 0; i < _slots.length; i++) {
      final ChatMessage? m = _slots[i];
      if (m == null) continue;
      if (i >= pageEnd && !pageIds.contains(m.id)) kept[i] = m;
    }
    _slots
      ..clear()
      ..addAll(kept);
    _indexById.clear();
    for (int i = 0; i < _slots.length; i++) {
      final ChatMessage? m = _slots[i];
      if (m != null) _indexById[m.id] = i;
    }
    place(offset: offset, messages: messages);
  }

  /// 区间 [from, to) 里**还没加载**的连续段（升序）。
  List<MessageRange> missing(MessageRange range) {
    final int from = range.from < 0 ? 0 : range.from;
    final int to = range.to > _slots.length ? _slots.length : range.to;
    final List<MessageRange> out = <MessageRange>[];
    int start = -1;
    for (int i = from; i < to; i++) {
      if (_slots[i] == null) {
        if (start < 0) start = i;
      } else if (start >= 0) {
        out.add(MessageRange(start, i));
        start = -1;
      }
    }
    if (start >= 0) out.add(MessageRange(start, to));
    return out;
  }

  /// 视口 `[first, last]`（闭区间）附近要补的段：外扩 [margin] 条，且只报**还没加载**
  /// 的那些（滑到哪加载哪）。
  List<MessageRange> gapsFor(int first, int last) {
    final int from = first - margin;
    final int to = last + 1 + margin;
    return missing(MessageRange(from < 0 ? 0 : from, to));
  }

  /// 这一页该问核心要多少条：**至少一页**；缺口比一页大就整段要
  /// （一次把视口那一段铺满，省得滑两下停一次；核心另有单页上限）。
  int pageSizeFor(MessageRange gap) =>
      gap.length > pageSize ? gap.length : pageSize;

  /// 淘汰离视口太远的槽位（**限制缓存长度**）。
  ///
  /// 保留：视口附近 [keep]、末尾 [tailKeep] 条、以及**正在流式 / 正在跑工具**的消息
  /// （正文还在往里写，放回占位等于把这一轮吃掉）。
  ///
  /// [keepAlso] 里的区间同样保留（面板用它钉住"刚定位过的那一页"：它可能离
  /// 视口很远，但用户正看着它）。
  ///
  /// 返回淘汰掉的条数。
  int evict({
    required MessageRange keep,
    List<MessageRange> keepAlso = const <MessageRange>[],
    int? keepTail,
  }) {
    final int tail = keepTail ?? tailKeep;
    final int tailFrom = _slots.length - tail;
    int removed = 0;
    for (int i = 0; i < _slots.length; i++) {
      final ChatMessage? m = _slots[i];
      if (m == null) continue;
      if (keep.contains(i)) continue;
      if (i >= tailFrom) continue;
      bool pinned = false;
      for (final MessageRange r in keepAlso) {
        if (r.contains(i)) {
          pinned = true;
          break;
        }
      }
      if (pinned) continue;
      if (m.isStreaming || m.toolRunning) continue;
      _slots[i] = null;
      _indexById.remove(m.id);
      removed++;
    }
    return removed;
  }

  /// 整表作废（换会话 / 换 agent / 清空历史）。
  void clear() {
    _slots.clear();
    _indexById.clear();
  }
}
