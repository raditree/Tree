import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/services/message_window.dart';

/// 消息窗口（按全局下标寻址的槽位表）的行为。
///
/// 钉住的是用户 2026-10-04 的三条口径：
/// - **滑到哪加载哪**：只补视口附近缺的那几段（[MessageWindow.gapsFor]）；
/// - **限制缓存长度，仅缓存窗口附近的消息**（[MessageWindow.evict]）；
/// - **滑块位置按全局长度算**：槽位表长度只随新消息增长，加载/淘汰都不改变它
///   （`total` 与 `loadedCount` 分开）。
void main() {
  ChatMessage msg(String id, {bool streaming = false, bool running = false}) =>
      ChatMessage(
        id: id,
        role: 'agent',
        content: '正文 $id',
        timestamp: DateTime(2026, 1, 1),
        isStreaming: streaming,
        toolRunning: running,
      );

  List<ChatMessage> page(int from, int count) =>
      <ChatMessage>[for (int i = 0; i < count; i++) msg('m${from + i}')];

  group('放置与总数', () {
    test('放一页：落在 offset 指定的下标上，长度按核心的 total 补齐', () {
      final MessageWindow w = MessageWindow();
      w.ensureTotal(10);
      expect(w.total, 10);
      expect(w.loadedCount, 0);

      final int placed = w.place(offset: 7, messages: page(7, 3));
      expect(placed, 3);
      expect(w.at(7)!.id, 'm7');
      expect(w.at(9)!.id, 'm9');
      expect(w.at(6), isNull, reason: '没加载的槽位是占位');
      expect(w.indexOfId('m8'), 8);
      expect(w.loadedRanges, <MessageRange>[const MessageRange(7, 10)]);
    });

    test('同一页放两次：按 id 去重，不出现两条', () {
      final MessageWindow w = MessageWindow();
      w.place(offset: 0, messages: page(0, 3));
      final int again = w.place(offset: 0, messages: page(0, 3));
      expect(again, 0);
      expect(w.loadedCount, 3);
    });

    test('核心那边多落了几条：按 id 对齐整页的基准，不错位', () {
      final MessageWindow w = MessageWindow();
      w.place(offset: 0, messages: page(0, 3));
      // 核心说这一页从 1 开始，但 m1 本端已经在 1 号位 ⇒ 整页按 m1 对齐
      w.place(offset: 1, messages: page(1, 3));
      expect(w.at(1)!.id, 'm1');
      expect(w.at(2)!.id, 'm2');
      expect(w.at(3)!.id, 'm3');
      expect(w.loadedCount, 4);
    });

    test('空页只把长度对齐（用户滑到了超出末尾的位置）', () {
      final MessageWindow w = MessageWindow();
      w.place(offset: 42, messages: <ChatMessage>[]);
      expect(w.total, 42);
      expect(w.loadedCount, 0);
    });
  });

  group('实时追加', () {
    test('追加落在末尾：下标 = 当前长度，total 随之 +1', () {
      final MessageWindow w = MessageWindow();
      w.ensureTotal(3);
      w.appendTail(msg('live'));
      expect(w.total, 4);
      expect(w.indexOfId('live'), 3);
    });

    test('同 id 的实时帧：原位替换，不新增槽位', () {
      final MessageWindow w = MessageWindow();
      w.place(offset: 0, messages: page(0, 2));
      final ChatMessage older = w.at(1)!;
      w.appendTail(msg('m1'));
      expect(w.total, 2);
      expect(identical(w.at(1), older), isFalse, reason: '换成更完整的那一份');
    });
  });

  group('滑到哪加载哪', () {
    test('gapsFor：只报视口附近**没加载**的连续段，并外扩 margin', () {
      final MessageWindow w = MessageWindow(margin: 2);
      w.ensureTotal(10);
      w.place(offset: 4, messages: page(4, 2)); // 4,5 已加载
      // 视口 [5,6] 外扩 2 ⇒ 关心 [3,9)：3 没加载、4/5 有、6..8 没加载
      final List<MessageRange> gaps = w.gapsFor(5, 6);
      expect(gaps, <MessageRange>[
        const MessageRange(3, 4),
        const MessageRange(6, 9),
      ]);
    });

    test('gapsFor 外扩到表外时夹住（不越界）', () {
      final MessageWindow w = MessageWindow(margin: 100);
      w.ensureTotal(3);
      expect(w.gapsFor(1, 2), <MessageRange>[const MessageRange(0, 3)]);
    });

    test('pageSizeFor：至少一页；缺口更大就整段要', () {
      final MessageWindow w = MessageWindow(pageSize: 200);
      expect(w.pageSizeFor(const MessageRange(0, 5)), 200);
      expect(w.pageSizeFor(const MessageRange(0, 400)), 400);
    });
  });

  group('限制缓存长度', () {
    test('淘汰：离开视口又离末尾太远的槽位放回占位', () {
      final MessageWindow w = MessageWindow(tailKeep: 2);
      w.ensureTotal(20);
      w.place(offset: 0, messages: page(0, 10)); // 0..9
      w.place(offset: 18, messages: page(18, 2)); // 18,19（末尾保留）
      final int removed = w.evict(keep: const MessageRange(8, 11));
      expect(removed, 8, reason: '0..7 被淘汰；8,9 在视口；18,19 是末尾');
      expect(w.loadedCount, 4);
      expect(w.at(7), isNull);
      expect(w.at(8)!.id, 'm8');
      expect(w.at(18)!.id, 'm18');
      expect(w.indexOfId('m3'), -1, reason: '淘汰后 id 索引也要清掉');
    });

    test('正在流式 / 正在跑工具的消息永不被淘汰（正文还在写）', () {
      final MessageWindow w = MessageWindow(tailKeep: 0);
      w.ensureTotal(5);
      w.place(
        offset: 0,
        messages: <ChatMessage>[
          msg('a'),
          msg('b', streaming: true),
          msg('c', running: true),
          msg('d'),
        ],
      );
      final int removed = w.evict(keep: const MessageRange(9, 10));
      expect(removed, 2, reason: '只淘汰 a 与 d');
      expect(w.at(1)!.id, 'b');
      expect(w.at(2)!.id, 'c');
    });

    test('加载与淘汰都不改变槽位表长度（滑块的全局长度口径）', () {
      final MessageWindow w = MessageWindow(tailKeep: 1);
      w.ensureTotal(100);
      final int total = w.total;
      w.place(offset: 50, messages: page(50, 10));
      w.place(offset: 99, messages: page(99, 1));
      w.evict(keep: const MessageRange(50, 60));
      expect(w.total, total);
    });
  });

  group('重载末尾一段（回到底部）', () {
    test('只留比这一页更新的实时尾巴，其余回占位', () {
      final MessageWindow w = MessageWindow();
      w.place(offset: 0, messages: page(0, 8));
      w.appendTail(msg('live1'));
      w.appendTail(msg('live2'));
      expect(w.total, 10);

      // 核心此时只落了 8 条（实时那两条还没落库）⇒ 末尾页 = 0..7
      w.resetTail(offset: 0, messages: page(0, 8));
      expect(w.total, 10, reason: '实时尾巴还在原位');
      expect(w.at(8)!.id, 'live1');
      expect(w.at(9)!.id, 'live2');
      expect(w.loadedCount, 10);
    });

    test('核心已经落了实时那两条：按 id 去重，不出现两份', () {
      final MessageWindow w = MessageWindow();
      w.place(offset: 0, messages: page(0, 8));
      w.appendTail(msg('m8'));
      w.appendTail(msg('m9'));
      expect(w.total, 10);

      w.resetTail(offset: 0, messages: page(0, 10));
      expect(w.total, 10);
      expect(w.loadedCount, 10);
      expect(w.at(8)!.id, 'm8');
      expect(w.at(9)!.id, 'm9');
    });

    test('重载把之前翻出来的老页全部作废（回到底部 = 只剩末尾一段）', () {
      final MessageWindow w = MessageWindow();
      w.place(offset: 0, messages: page(0, 50));
      w.place(offset: 50, messages: page(50, 50));
      expect(w.loadedCount, 100);

      w.resetTail(offset: 95, messages: page(95, 5));
      expect(w.loadedRanges, <MessageRange>[const MessageRange(95, 100)]);
      expect(w.loadedCount, 5);
    });

    test('核心新落了消息（页尾超过本地长度）：槽位表跟着变长', () {
      final MessageWindow w = MessageWindow();
      w.place(offset: 0, messages: page(0, 5));
      w.resetTail(offset: 3, messages: page(3, 5));
      expect(w.total, 8);
      expect(w.at(7)!.id, 'm7');
    });
  });

  test('clear：整表作废', () {
    final MessageWindow w = MessageWindow();
    w.place(offset: 0, messages: page(0, 4));
    w.clear();
    expect(w.isEmpty, isTrue);
    expect(w.total, 0);
    expect(w.loadedCount, 0);
  });
}
