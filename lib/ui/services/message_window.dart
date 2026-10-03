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
