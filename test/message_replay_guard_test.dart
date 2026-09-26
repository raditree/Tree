// 断线补发帧「重播去重」闸单元测试（M9 §1.1 / Wave 3-H 待办 3）。
//
// 风险背景：核心在链路失活 / 前端断开期间把广播帧登记进待补发队列，重连后原样重播
// （帧无 TTL、无序号）。前端 `msg_chunk` 是追加语义、start 帧是新建气泡语义，两者
// 都不幂等；而**别的路径会整批重建消息列表**（切 agent / 会话、清空历史后的
// refreshTrigger、新建 / 删除会话），一旦落在"断线登记 → 重连重播"之间，同一条消息
// 就会先由 REST 全量重建、再被重播增量追加一遍。
//
// 本文件覆盖闸门判据本身；面板侧的接线点共 7 处（message_panel.dart）：
// msg_start / msg_chunk / msg_end（封口）/ tool_start / message / ask_user_question
// 调 shouldCreateMessage 或 shouldAppendChunk，_loadHistory 调 resetToHistory。
//
// 运行方式（项目根目录）：
//   flutter test test/message_replay_guard_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/services/message_replay_guard.dart';

void main() {
  group('重播去重判据', () {
    test('未知 id：允许新建气泡、允许追加增量（正常流式路径）', () {
      final MessageReplayGuard g = MessageReplayGuard();
      expect(g.shouldCreateMessage(id: 'msg_1', exists: false), isTrue);
      expect(g.shouldAppendChunk(id: 'msg_1', exists: true), isTrue);
      expect(g.isSealed('msg_1'), isFalse);
      expect(g.sealedCount, 0);
    });

    test('空 id：既不建条也不追加（畸形帧交调用方按既有行为处理）', () {
      final MessageReplayGuard g = MessageReplayGuard();
      expect(g.shouldCreateMessage(id: '', exists: false), isFalse);
      expect(g.shouldAppendChunk(id: '', exists: true), isFalse);
    });

    test('同 id 已存在 ⇒ 重播的 start 帧不再建第二条气泡', () {
      final MessageReplayGuard g = MessageReplayGuard();
      // msg_start / tool_start / message / ask_user_question 共用这一条判据
      expect(g.shouldCreateMessage(id: 'msg_1', exists: true), isFalse);
      expect(g.shouldCreateMessage(id: 'tool_1', exists: true), isFalse);
      expect(g.shouldCreateMessage(id: 'qst_1', exists: true), isFalse);
    });

    test('没有对应消息的孤立增量 ⇒ 丢弃（既有行为，顺带覆盖）', () {
      final MessageReplayGuard g = MessageReplayGuard();
      expect(g.shouldAppendChunk(id: 'msg_none', exists: false), isFalse);
      expect(g.describe(id: 'msg_none', exists: false), contains('孤立'));
    });

    test('msg_end 封口后：重播增量不再追加（同一片段不会渲染两遍）', () {
      final MessageReplayGuard g = MessageReplayGuard();
      final String id = 'msg_done';
      g.seal(id);
      expect(g.isSealed(id), isTrue);
      expect(g.sealedCount, 1);
      expect(g.shouldAppendChunk(id: id, exists: true), isFalse);
      expect(g.describe(id: id, exists: true), contains('已封口'));
      // 封口不影响别的 id，也不影响"已有消息"这一事实
      expect(g.shouldAppendChunk(id: 'msg_other', exists: true), isTrue);
      expect(g.shouldCreateMessage(id: id, exists: true), isFalse);
    });

    test('历史整批重建 ⇒ 全部封口（REST 终稿不再被重播增量追加）', () {
      final MessageReplayGuard g = MessageReplayGuard();
      g.resetToHistory(<String>['msg_a', 'msg_b', 'msg_c']);
      expect(g.sealedCount, 3);
      for (final String id in <String>['msg_a', 'msg_b', 'msg_c']) {
        expect(g.isSealed(id), isTrue);
        expect(g.shouldAppendChunk(id: id, exists: true), isFalse);
      }
      // 历史里还没有的在途消息（段未关闭 ⇒ 未落库）照常放行
      expect(g.shouldAppendChunk(id: 'msg_inflight', exists: true), isTrue);
    });

    test('resetToHistory 是替换而非累加：上个会话的封口不残留', () {
      final MessageReplayGuard g = MessageReplayGuard();
      g.resetToHistory(<String>['old_1']);
      g.resetToHistory(<String>['new_1']);
      expect(g.sealedCount, 1);
      expect(g.isSealed('old_1'), isFalse);
      expect(g.isSealed('new_1'), isTrue);
      // 切换会话后重建的空列表：封口集合也应为空（新会话的增量全部放行）
      g.resetToHistory(const <String>[]);
      expect(g.sealedCount, 0);
      expect(g.shouldAppendChunk(id: 'new_1', exists: true), isTrue);
    });

    test('seal 空 id 忽略；sealAll 不覆盖既有集合', () {
      final MessageReplayGuard g = MessageReplayGuard();
      g.seal('');
      expect(g.sealedCount, 0);
      g.sealAll(<String>['a', '', 'b']);
      g.sealAll(<String>['b', 'c']);
      expect(g.sealedIds, <String>{'a', 'b', 'c'});
      expect(g.sealedIds, isNot(same(g.sealedIds))); // 对外只读快照
      g.clear();
      expect(g.sealedCount, 0);
      expect(g.shouldAppendChunk(id: 'a', exists: true), isTrue);
    });

    test('id 精确匹配：大小写 / 前后缀不同互不影响', () {
      final MessageReplayGuard g = MessageReplayGuard();
      g.seal('msg_1');
      expect(g.shouldAppendChunk(id: 'msg_1', exists: true), isFalse);
      expect(g.shouldAppendChunk(id: 'MSG_1', exists: true), isTrue);
      expect(g.shouldAppendChunk(id: 'msg_10', exists: true), isTrue);
    });

    test('describe 区分三种丢弃原因（排障日志可读）', () {
      final MessageReplayGuard g = MessageReplayGuard();
      expect(g.describe(id: '', exists: false), '空 id');
      g.seal('s');
      expect(g.describe(id: 's', exists: true), contains('已封口'));
      expect(g.describe(id: 'x', exists: false), contains('孤立'));
      expect(g.describe(id: 'x', exists: true), '正常');
    });
  });
}
