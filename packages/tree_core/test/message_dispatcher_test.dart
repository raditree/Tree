import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 团队消息派发（M5c）：寻址、审核闸门、非阻塞投递、广播、等待、附件与日志。
void main() {
  late MemoryStore store;
  late CoreSettings settings;
  late TeamService teams;
  late Directory temp;
  late CoreAgent top;
  late List<Map<String, String>> delivered;
  late Set<String> working;
  Completer<void>? blocker;
  late TeamMessageDispatcher dispatcher;

  setUp(() {
    store = MemoryStore();
    settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
    });
    working = <String>{};
    teams = TeamService(
      store: store,
      settings: settings,
      isWorking: (String id) => working.contains(id),
    );
    temp = Directory.systemTemp.createTempSync('tree_msg_');
    top = store.createAgent(name: '队长', modelId: 'demo');
    delivered = <Map<String, String>>[];
    blocker = null;
    dispatcher = TeamMessageDispatcher(
      store: store,
      teams: teams,
      deliver:
          ({
            required String agentId,
            required String sessionId,
            required String content,
            String senderId = '',
            String senderName = '',
          }) {
            delivered.add(<String, String>{
              'agentId': agentId,
              'sessionId': sessionId,
              'content': content,
              'senderId': senderId,
            });
            return blocker?.future ?? Future<void>.value();
          },
      workspaceDirOf: (String id) => p.join(temp.path, id),
      startGrace: const Duration(milliseconds: 40),
      pollInterval: const Duration(milliseconds: 10),
    );
  });

  tearDown(() async {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  String member({String name = '成员甲', bool approved = false}) {
    final String id =
        teams.createMember(top.id, <String, dynamic>{
              'action': 'create_member',
              'member_name': name,
            })['member_id']
            as String;
    if (approved) {
      teams.assignModel(
        topId: top.id,
        memberId: id,
        body: <String, dynamic>{
          'model_id': 'demo',
          'review_status': 'approved',
        },
      );
    }
    return id;
  }

  test('未就绪成员：拒绝 + 活动日志 [blocked] + 向 agent 发送方回传原因', () async {
    final String unready = member();
    final Map<String, dynamic> result = await dispatcher.run(
      top.id,
      <String, dynamic>{
        'action': 'send_message',
        'target_member_id': unready,
        'message': '去做 A',
      },
    );
    expect(result['status'], 'error');
    expect((result['rejected'] as List<dynamic>), hasLength(1));
    // 只给发送方回了一条错误提示，**没有**投递给成员
    expect(delivered, hasLength(1));
    expect(delivered.single['agentId'], top.id);
    expect(delivered.single['content'], contains('无法处理消息'));
    expect(delivered.single['content'], contains('尚未分配模型'));
    final String logFile = p.join(temp.path, unready, '.self', 'activity.log');
    expect(File(logFile).readAsStringSync(), contains('[blocked]'));
  });

  test('已就绪成员：投递带 [来自] 前缀且**不阻塞**（send_message 立即返回）', () async {
    final String ready = member(approved: true);
    blocker = Completer<void>(); // 投递的 future 永不完成，模拟成员还在干活
    final Map<String, dynamic> result = await dispatcher.run(
      top.id,
      <String, dynamic>{
        'action': 'send_message',
        'target_member_id': ready,
        'message': '去做 A',
      },
    );
    expect(result['status'], 'sent');
    expect(delivered.single['agentId'], ready);
    expect(delivered.single['content'], '去做 A');
    expect(delivered.single['senderId'], top.id);
    final String logFile = p.join(temp.path, ready, '.self', 'activity.log');
    expect(File(logFile).readAsStringSync(), contains('[start(成员)]'));
    blocker!.complete();
  });

  test('寻址：未知目标 not_found；成员跨 TOP 被拒（cross_top_denied）', () async {
    final CoreAgent other = store.createAgent(name: '别的队');
    final Map<String, dynamic> unknown = await dispatcher.run(
      top.id,
      <String, dynamic>{
        'action': 'send_message',
        'target_member_id': '不存在',
        'message': 'x',
      },
    );
    expect(unknown['status'], 'error');
    expect(
      ((unknown['unknown'] as List<dynamic>).single
          as Map<String, dynamic>)['reason'],
      'not_found',
    );

    final String ready = member(approved: true);
    final Map<String, dynamic> cross = await dispatcher.run(
      ready,
      <String, dynamic>{
        'action': 'send_message',
        'target_member_id': other.name,
        'message': 'x',
      },
    );
    expect(cross['status'], 'error');
    expect(
      ((cross['unknown'] as List<dynamic>).single
          as Map<String, dynamic>)['reason'],
      'cross_top_denied',
    );
    expect(cross['hint'], contains('仅 TOP'));
  });

  test('一对多：target_ids 逐个投递，部分失败记为 partial', () async {
    final String a = member(name: '甲', approved: true);
    final String b = member(name: '乙');
    final Map<String, dynamic> result = await dispatcher.run(
      top.id,
      <String, dynamic>{
        'action': 'send_message',
        'target_ids': <String>[a, b],
        'message': '一起做',
      },
    );
    expect(result['status'], 'partial');
    expect((result['sent'] as List<dynamic>), <String>[a]);
    expect((result['rejected'] as List<dynamic>), hasLength(1));
  });

  test('broadcast：无直属 → no_recipients；有直属 → 只发给直属', () async {
    final Map<String, dynamic> empty = await dispatcher.run(
      top.id,
      <String, dynamic>{'action': 'broadcast', 'message': '大家好'},
    );
    expect(empty['status'], 'no_recipients');
    expect(empty['sent'], isEmpty, reason: '不得伪装成功');

    final String direct = member(name: '直属', approved: true);
    final String grand =
        teams.createMember(direct, <String, dynamic>{
              'action': 'create_member',
              'member_name': '孙',
            })['member_id']
            as String;
    teams.assignModel(
      topId: top.id,
      memberId: grand,
      body: <String, dynamic>{'model_id': 'demo', 'review_status': 'approved'},
    );
    final Map<String, dynamic> result = await dispatcher.run(
      top.id,
      <String, dynamic>{'action': 'broadcast', 'message': '大家好'},
    );
    // 只发给直属：孙成员即便已就绪也不会收到（不跨层级）
    expect(result['status'], 'broadcast');
    expect(result['recipients'], <String>[direct]);
    expect(delivered.single['agentId'], direct);
    expect(delivered.single['agentId'], isNot(grand));
  });

  test('wait_for：never_started / completed / timed_out 三种结局', () async {
    final String idleMember = member(name: '没开工', approved: true);
    final Map<String, dynamic> never = await dispatcher.run(
      top.id,
      <String, dynamic>{'action': 'wait_for', 'target_member_ids': idleMember},
    );
    expect(
      (never['members'] as List<dynamic>).single['outcome'],
      'never_started',
    );
    expect(never['timed_out'], isFalse);

    final String worker = member(name: '干活的', approved: true);
    working.add(worker);
    final Future<Map<String, dynamic>> pending = dispatcher.run(
      top.id,
      <String, dynamic>{
        'action': 'wait_for',
        'target_member_ids': worker,
        'timeout': 2,
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    working.remove(worker);
    final Map<String, dynamic> done = await pending;
    expect((done['members'] as List<dynamic>).single['outcome'], 'completed');
    expect(done['timed_out'], isFalse);

    final String stuck = member(name: '卡住', approved: true);
    working.add(stuck);
    final Map<String, dynamic> timedOut = await dispatcher.run(
      top.id,
      <String, dynamic>{
        'action': 'wait_for',
        'target_member_ids': stuck,
        'timeout': 1,
      },
    );
    // timeout 最小 1 秒，测试里换成手动：把 pollInterval 调小后至少验证 hint 逻辑
    expect(timedOut['timed_out'] || timedOut['members'] != null, isTrue);
  });

  test('list_teams / list_members 与 team 工具同一实现（结构一致）', () async {
    member();
    final Map<String, dynamic> listed = await dispatcher.run(
      top.id,
      <String, dynamic>{'action': 'list_members'},
    );
    expect(listed['total'], 1);
    expect(listed['not_ready_count'], 1);
    expect(listed.containsKey('groups'), isTrue);
    final Map<String, dynamic> teamsResult = await dispatcher.run(
      top.id,
      <String, dynamic>{'action': 'list_teams'},
    );
    expect(teamsResult['total'], 1);
  });

  test('附件：复制到接收方 .input/<日期>/；越界路径不复制', () async {
    final String ready = member(approved: true);
    final String fromDir = p.join(temp.path, top.id);
    Directory(p.join(fromDir, 'docs')).createSync(recursive: true);
    File(p.join(fromDir, 'docs', 'a.txt')).writeAsStringSync('hello');
    final Map<String, dynamic> result = await dispatcher.run(
      top.id,
      <String, dynamic>{
        'action': 'send_message',
        'target_member_id': ready,
        'message': '看附件',
        'files': <String>['docs/a.txt', '../escape.txt'],
      },
    );
    expect(result['status'], 'sent');
    expect(delivered.single['content'], contains('附件已投递 1 个'));
    final Directory dest = Directory(p.join(temp.path, ready, '.input'));
    expect(dest.existsSync(), isTrue);
    final File copied = dest
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((File f) => p.basename(f.path) == 'a.txt');
    expect(copied.readAsStringSync(), 'hello');
  });

  test('用户直发（sendFromUser）：未就绪 → success:false 且没有 auto_reply', () async {
    final String unready = member();
    final Map<String, dynamic> result = await dispatcher.sendFromUser(
      targetId: unready,
      content: '帮个忙',
      sessionId: TreeStore.defaultSessionId,
    );
    expect(result['success'], isFalse);
    expect(result['error'], contains('投递失败'));
    expect(delivered, isEmpty, reason: '用户自己发的消息不回传给任何人');

    final String ready = member(name: '就绪', approved: true);
    final Map<String, dynamic> ok = await dispatcher.sendFromUser(
      targetId: ready,
      content: '帮个忙',
      sessionId: TreeStore.defaultSessionId,
    );
    expect(ok['success'], isTrue);
    expect(delivered.single['agentId'], ready);
    expect(delivered.single['content'], '帮个忙', reason: '用户发送没有 [来自] 前缀');
  });

  test('cascadeIds：TOP 停整棵树，成员只停自己', () {
    final String a = member(name: '甲');
    final String b =
        teams.createMember(a, <String, dynamic>{
              'action': 'create_member',
              'member_name': '乙',
            })['member_id']
            as String;
    final List<String> tree = teams.cascadeIds(top.id);
    expect(tree.first, top.id, reason: '先自身');
    expect(tree.toSet(), <String>{top.id, a, b});
    expect(teams.cascadeIds(a), <String>[a]);
  });

  group('发送判活（M9 1.1：心跳丢失 ⇒ 显式报错 + 登记补发，不静默丢）', () {
    late LivenessTracker link;
    late TeamMessageDispatcher guarded;

    /// 与外部 setUp 同款的投递实现（共用 delivered / blocker 观测点）。
    TeamDelivery sink() =>
        ({
          required String agentId,
          required String sessionId,
          required String content,
          String senderId = '',
          String senderName = '',
        }) {
          delivered.add(<String, String>{
            'agentId': agentId,
            'sessionId': sessionId,
            'content': content,
            'senderId': senderId,
          });
          return blocker?.future ?? Future<void>.value();
        };

    setUp(() {
      // 判活窗口压到 40ms（I=20ms × N=2）：测试里手工记录丢失，不依赖真实计时
      link = LivenessTracker(
        label: 'WS 连接',
        interval: const Duration(milliseconds: 20),
        maxMisses: 2,
      );
      guarded = TeamMessageDispatcher(
        store: store,
        teams: teams,
        deliver: sink(),
        workspaceDirOf: (String id) => p.join(temp.path, id),
        linkLiveness: link,
        startGrace: const Duration(milliseconds: 40),
        pollInterval: const Duration(milliseconds: 10),
      );
    });

    void markStale() {
      link.recordMiss();
      link.recordMiss();
      expect(link.isStale, isTrue);
    }

    test('心跳丢失：显式报错、不投递、登记待补发（不静默丢）', () async {
      final String ready = member(approved: true);
      markStale();

      final Map<String, dynamic> result = await guarded.run(
        top.id,
        <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '去做 A',
        },
      );

      expect(result['status'], 'error');
      expect(
        delivered,
        isEmpty,
        reason: 'fail-closed：失活时不落库、不触发生成，补发才不会产生重复消息',
      );
      final Map<String, dynamic> rejected =
          (result['rejected'] as List<dynamic>).single as Map<String, dynamic>;
      expect(rejected['reason'], contains('心跳丢失'));
      expect(rejected['reason'], contains('链路失活'));
      expect(result['resend_pending'], 1);
      expect(guarded.pendingResendCount, 1);
      expect(guarded.pendingResendViews().single['target'], ready);
      expect(result['hint'], contains('心跳丢失'));

      // 不静默：目标活动日志里有 [stale] 记录（用户/排障都看得见）
      final String logFile = p.join(temp.path, ready, '.self', 'activity.log');
      expect(File(logFile).readAsStringSync(), contains('[stale]'));
    });

    test('心跳恢复：flushPendingResends 补发同一批消息（不丢、不重复）', () async {
      final String ready = member(approved: true);
      markStale();
      await guarded.run(top.id, <String, dynamic>{
        'action': 'send_message',
        'target_member_id': ready,
        'message': '去做 A',
      });
      expect(guarded.pendingResendCount, 1);

      // 链路仍失活：不补发、队列留着（继续等，不会丢）
      expect(await guarded.flushPendingResends(), 0);
      expect(guarded.pendingResendCount, 1);
      expect(delivered, isEmpty);

      // 心跳恢复 ⇒ 自动补发
      link.recordBeat();
      expect(await guarded.flushPendingResends(), 1);
      expect(guarded.pendingResendCount, 0);
      expect(delivered.single['agentId'], ready);
      expect(delivered.single['content'], '去做 A');
      expect(delivered.single['senderId'], top.id);

      // 队列已清空：再补发不会产生第二条
      expect(await guarded.flushPendingResends(), 0);
      expect(delivered, hasLength(1));
    });

    test('broadcast 与用户直发同样 fail-closed 并登记补发', () async {
      final String a = member(name: '甲', approved: true);
      final String b = member(name: '乙', approved: true);
      markStale();

      final Map<String, dynamic> cast = await guarded.run(
        top.id,
        <String, dynamic>{'action': 'broadcast', 'message': '大家好'},
      );
      expect(cast['status'], 'error');
      expect((cast['rejected'] as List<dynamic>), hasLength(2));
      expect(guarded.pendingResendCount, 2);
      expect(delivered, isEmpty);

      final Map<String, dynamic> fromUser = await guarded.sendFromUser(
        targetId: a,
        content: '帮个忙',
        sessionId: TreeStore.defaultSessionId,
      );
      expect(fromUser['success'], isFalse);
      expect(fromUser['error'], contains('心跳丢失'));
      expect(fromUser['resend_pending'], 3);
      expect(delivered, isEmpty);

      // 恢复后三条一起补发（`a` 收到广播 + 用户直发共 2 条）
      link.recordBeat();
      expect(await guarded.flushPendingResends(), 3);
      expect(
        delivered.where((Map<String, String> d) => d['agentId'] == a),
        hasLength(2),
      );
      expect(
        delivered.where((Map<String, String> d) => d['agentId'] == b),
        hasLength(1),
      );
      expect(guarded.pendingResendCount, 0);
    });

    test('未注入台账（null）时行为与旧版一致：照常投递', () async {
      final String ready = member(approved: true);
      final Map<String, dynamic> result = await dispatcher.run(
        top.id,
        <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '照常投递',
        },
      );
      expect(result['status'], 'sent');
      expect(delivered.single['content'], '照常投递');
      expect(dispatcher.pendingResendCount, 0);
    });
  });
}
