import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

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
      // 活动日志走工作空间 IO（与 SSH 模式同一口径）：每个 agent 的私有目录是
      // `<工作空间>/.tree/<agent_id>/.self/`。
      ioFor: (String id) async => PrivateWorkspaceIO(
        LocalWorkspaceIO(p.join(temp.path, id)),
        id,
      ),
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
    // 私有状态按 agent 分栏：<工作空间>/.tree/<agent_id>/.self/activity.log
    final String logFile = p.join(
      temp.path,
      unready,
      '.tree',
      unready,
      '.self',
      'activity.log',
    );
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
    final String logFile = p.join(
      temp.path,
      ready,
      '.tree',
      ready,
      '.self',
      'activity.log',
    );
    expect(File(logFile).readAsStringSync(), contains('[start(成员)]'));
    blocker!.complete();
  });

  test('message 工具：默认把接收方归集到**发起会话**（而不是 session_default）', () async {
    final String ready = member(approved: true);
    final ToolOutcome outcome = await MessageTool.run(
      ToolInvocation(
        id: 'call_1',
        name: MessageTool.name,
        arguments: <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '去做 A',
        },
        agentId: top.id,
        sessionId: 'ses_team',
      ),
      dispatcher,
    );
    expect(outcome.isError, isFalse);
    expect(
      delivered.single['sessionId'],
      'ses_team',
      reason: '派活落在发起会话里，teammates 窗口（按当前会话过滤）才看得到成员进度',
    );
  });

  test('message 工具：显式 session_id 优先于发起会话', () async {
    final String ready = member(approved: true);
    await MessageTool.run(
      ToolInvocation(
        id: 'call_2',
        name: MessageTool.name,
        arguments: <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '去做 B',
          'session_id': TreeStore.defaultSessionId,
        },
        agentId: top.id,
        sessionId: 'ses_team',
      ),
      dispatcher,
    );
    expect(delivered.single['sessionId'], TreeStore.defaultSessionId);
  });

  test('SSH 模式（本机拿不到工作目录）：日志照样写进该 agent 的 .self', () async {
    final String ready = member(approved: true);
    // 模拟 SSH 模式：workspaceDirOf 指不出本机目录，只有工作空间 IO 能写。
    final TeamMessageDispatcher remote = TeamMessageDispatcher(
      store: store,
      teams: teams,
      deliver:
          ({
            required String agentId,
            required String sessionId,
            required String content,
            String senderId = '',
            String senderName = '',
          }) => Future<void>.value(),
      workspaceDirOf: (String _) => '',
      ioFor: (String id) async =>
          PrivateWorkspaceIO(LocalWorkspaceIO(p.join(temp.path, id)), id),
      startGrace: const Duration(milliseconds: 40),
      pollInterval: const Duration(milliseconds: 10),
    );
    final Map<String, dynamic> result = await remote.run(
      top.id,
      <String, dynamic>{
        'action': 'send_message',
        'target_member_id': ready,
        'message': '去做 C',
      },
    );
    expect(result['status'], 'sent');
    final String logFile = p.join(
      temp.path,
      ready,
      '.tree',
      ready,
      '.self',
      'activity.log',
    );
    expect(
      File(logFile).readAsStringSync(),
      contains('[start(成员)]'),
      reason: '远端工作空间也要有日志（真实路径 .tree/<agent_id>/.self/activity.log）',
    );
    // 读日志 API 同样走 IO：远端模式与本地同一个实现
    final Map<String, dynamic> read = await remote.readActivityLog(ready, lines: 10);
    expect(read['log'], contains('[start(成员)]'));
    expect(read['path'], '.self/activity.log');
  });

  test('SSH 模式：附件经工作空间 IO 投递（两侧都在远端，走本机中转）', () async {
    final String ready = member(approved: true);
    final List<Map<String, String>> got = <Map<String, String>>[];
    final TeamMessageDispatcher remote = TeamMessageDispatcher(
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
            got.add(<String, String>{'agentId': agentId, 'content': content});
            return Future<void>.value();
          },
      // 与 CLI 接线同口径：teamSshConfigFor 非空 ⇒ workspaceDirOf 给空串（远端拿不到本机目录）
      workspaceDirOf: (String _) => '',
      ioFor: (String id) async =>
          PrivateWorkspaceIO(LocalWorkspaceIO(p.join(temp.path, id)), id),
      startGrace: const Duration(milliseconds: 40),
      pollInterval: const Duration(milliseconds: 10),
    );
    Directory(p.join(temp.path, top.id, 'docs')).createSync(recursive: true);
    File(p.join(temp.path, top.id, 'docs', 'a.txt')).writeAsStringSync('hello');

    final Map<String, dynamic> result = await remote.run(
      top.id,
      <String, dynamic>{
        'action': 'send_message',
        'target_member_id': ready,
        'message': '看附件',
        'files': <String>['docs/a.txt'],
      },
    );

    expect(result['status'], 'sent', reason: '消息本身照常送达');
    expect(got.single['agentId'], ready);
    expect(
      got.single['content'],
      contains('附件已投递 1 个'),
      reason: '远端工作空间同样经工作空间 IO 收到附件（不再回"未投递"）',
    );
    final Directory dest = Directory(p.join(temp.path, ready, '.input'));
    expect(dest.existsSync(), isTrue, reason: '落在接收方**自己的**工作空间里');
    final File copied = dest
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((File f) => p.basename(f.path) == 'a.txt');
    expect(copied.readAsStringSync(), 'hello');
  });

  test('未接工作空间 IO：退回本机绝对路径 + AtomicFile（兜底不回归）', () async {
    final String ready = member(approved: true);
    final TeamMessageDispatcher localFallback = TeamMessageDispatcher(
      store: store,
      teams: teams,
      deliver:
          ({
            required String agentId,
            required String sessionId,
            required String content,
            String senderId = '',
            String senderName = '',
          }) => Future<void>.value(),
      workspaceDirOf: (String id) => p.join(temp.path, id),
      startGrace: const Duration(milliseconds: 40),
      pollInterval: const Duration(milliseconds: 10),
    );
    await localFallback.run(top.id, <String, dynamic>{
      'action': 'send_message',
      'target_member_id': ready,
      'message': '去做 D',
    });
    final String logFile = p.join(
      temp.path,
      ready,
      '.tree',
      ready,
      '.self',
      'activity.log',
    );
    expect(File(logFile).readAsStringSync(), contains('[start(成员)]'));
    final Map<String, dynamic> read = await localFallback.readActivityLog(ready);
    expect(read['log'], contains('[start(成员)]'));
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

  test(
    'wait_for：completed / never_started；静态时长上限已取消（timeout 参数不再生效）',
    () async {
      final String idleMember = member(name: '没开工', approved: true);
      final Map<String, dynamic> never = await dispatcher.run(
        top.id,
        <String, dynamic>{
          'action': 'wait_for',
          'target_member_ids': idleMember,
        },
      );
      expect(
        (never['members'] as List<dynamic>).single['outcome'],
        'never_started',
      );
      expect(never['partial'], isTrue, reason: '未接单也算未响应者（部分结果）');
      expect(never['liveness_lost'], isFalse, reason: '未接单不是心跳丢失');
      expect(
        (never['unresponsive'] as List<dynamic>).single['kind'],
        'not_started',
      );
      expect(
        never.containsKey('timed_out'),
        isFalse,
        reason: 'M9 §1.1：静态时长判据已取消，不再有 timed_out',
      );

      final String worker = member(name: '干活的', approved: true);
      working.add(worker);
      // 老参数 timeout=1 传进来也**不再有时长上限**：等成员真的做完才返回
      final Future<Map<String, dynamic>> pending = dispatcher.run(
        top.id,
        <String, dynamic>{
          'action': 'wait_for',
          'target_member_ids': worker,
          'timeout': 1,
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      working.remove(worker);
      final Map<String, dynamic> done = await pending;
      expect((done['members'] as List<dynamic>).single['outcome'], 'completed');
      expect(done['partial'], isFalse);
      expect(done['completed'], <String>['干活的']);
      expect(
        (done['waited'] as num).toDouble(),
        greaterThan(1.0),
        reason: '超过旧的 1s 夹取仍继续等（静态上限已取消）',
      );
    },
  );

  test('wait_for：成员心跳丢失 ⇒ 返回已收集的部分结果 + 未响应者清单（不整体失败）', () async {
    final String finished = member(name: '干完的', approved: true);
    final String lost = member(name: '失联的', approved: true);
    working.addAll(<String>[finished, lost]);
    bool lostJudged = false;
    dispatcher.memberLiveness = (String agentId) => agentId == lost
        ? (lostJudged
              ? const MemberLivenessState.lost('成员进程已退出')
              : const MemberLivenessState.alive(detail: '在途生成'))
        : const MemberLivenessState.unknown();

    final Future<Map<String, dynamic>> pending = dispatcher.run(
      top.id,
      <String, dynamic>{
        'action': 'wait_for',
        'target_member_ids': '$finished,$lost',
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    working.remove(finished); // 干完的先收工
    lostJudged = true; // 另一个成员心跳丢失
    final Map<String, dynamic> result = await pending;

    expect(result.containsKey('error'), isFalse, reason: '部分结果不是整体失败');
    expect(result['partial'], isTrue);
    expect(result['liveness_lost'], isTrue);
    expect(result['completed'], <String>['干完的']);
    final Map<String, dynamic> lostView =
        (result['unresponsive'] as List<dynamic>).single
            as Map<String, dynamic>;
    expect(lostView['member_id'], lost);
    expect(lostView['kind'], 'heartbeat_lost');
    expect(lostView['reason'], contains('心跳丢失'));
    expect(lostView['reason'], contains('成员进程已退出'));
    final Map<String, dynamic> lostMember = (result['members'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((Map<String, dynamic> m) => m['member_id'] == lost);
    expect(lostMember['outcome'], 'unresponsive');
    expect(lostMember['reason'], contains('心跳丢失'));
    expect(result['hint'], contains('部分结果'));
  });

  test('wait_for：连接心跳丢失 ⇒ 立刻按部分结果收口（不整体失败）', () async {
    final String worker = member(name: '干活的', approved: true);
    working.add(worker);
    final LivenessTracker link = LivenessTracker(
      label: 'WS 链路',
      interval: const Duration(seconds: 10),
      maxMisses: 1,
    );
    dispatcher.linkLiveness = link;
    link.recordMiss(); // 判链路失活

    final Map<String, dynamic> result = await dispatcher.run(
      top.id,
      <String, dynamic>{'action': 'wait_for', 'target_member_ids': worker},
    );
    expect(result.containsKey('error'), isFalse, reason: '不整体失败');
    expect(result['liveness_lost'], isTrue);
    expect(result['partial'], isTrue);
    final Map<String, dynamic> view =
        (result['unresponsive'] as List<dynamic>).single
            as Map<String, dynamic>;
    expect(view['kind'], 'heartbeat_lost');
    expect(view['reason'], contains('连接心跳丢失'));
    expect(
      (result['waited'] as num).toDouble(),
      lessThan(1.0),
      reason: '链路判死就收口，不空等',
    );
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
      final String logFile = p.join(
      temp.path,
      ready,
      '.tree',
      ready,
      '.self',
      'activity.log',
    );
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

  group('附件跨机投递（local↔remote / remote↔remote）', () {
    /// 今天（与实现里的 `_dateStamp` 同一口径）：默认落点是 `.input/<日期>/`。
    String today() {
      final DateTime now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      return '${now.year}-${two(now.month)}-${two(now.day)}';
    }

    /// 跨机夹具：`localDirOf` 给空串 = 该 agent 的工作空间不在本机；
    /// `ioOf` 给 null = 该 agent 的工作空间 IO **未接线**。
    TeamMessageDispatcher cross({
      required String Function(String id) localDirOf,
      required Future<WorkspaceIO?> Function(String id) ioOf,
      int maxFileBytes = 32 * 1024 * 1024,
    }) => TeamMessageDispatcher(
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
            return Future<void>.value();
          },
      workspaceDirOf: localDirOf,
      ioFor: ioOf,
      startGrace: const Duration(milliseconds: 40),
      pollInterval: const Duration(milliseconds: 10),
      // 上限本就是**构造参数**（生产默认 32 MB）：测试用小值即可，不必真造 32 MB 文件。
      maxFileBytes: maxFileBytes,
    );

    /// 某工作空间根下 `.input` 里的那个附件（递归找，避开日期目录的字面依赖）。
    File? deliveredFile(String root, String name) {
      final Directory dir = Directory(p.join(root, '.input'));
      if (!dir.existsSync()) return null;
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is File && p.basename(entity.path) == name) return entity;
      }
      return null;
    }

    test('local→remote：发送方在本机、接收方在远端 ⇒ 落到接收方 .input/<日期>/', () async {
      final String ready = member(approved: true);
      final String localRoot = p.join(temp.path, top.id);
      final String remoteRoot = p.join(temp.path, 'remote_a');
      Directory(p.join(localRoot, 'docs')).createSync(recursive: true);
      File(p.join(localRoot, 'docs', 'a.txt')).writeAsStringSync('hello');

      final TeamMessageDispatcher d = cross(
        localDirOf: (String id) => id == top.id ? localRoot : '',
        ioOf: (String id) async =>
            id == ready ? PrivateWorkspaceIO(LocalWorkspaceIO(remoteRoot), id) : null,
      );
      final Map<String, dynamic> result = await d.run(
        top.id,
        <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['docs/a.txt'],
        },
      );

      expect(result['status'], 'sent');
      expect(delivered.single['content'], contains('附件已投递 1 个'));
      final File? copied = deliveredFile(remoteRoot, 'a.txt');
      expect(copied, isNotNull, reason: '必须落在**接收方远端**工作空间下');
      expect(copied!.readAsStringSync(), 'hello');
      expect(
        p.relative(copied.parent.path, from: remoteRoot),
        p.join('.input', today()),
        reason: '默认落点是 .input/<日期>/',
      );
      expect(
        Directory(p.join(localRoot, '.input')).existsSync(),
        isFalse,
        reason: '不许把远端接收方的附件写回发送方的本机目录',
      );
    });

    test('remote→local：发送方在远端、接收方在本机 ⇒ 落到接收方本机 .input/<日期>/', () async {
      final String ready = member(approved: true);
      final String localRoot = p.join(temp.path, ready);
      final String remoteRoot = p.join(temp.path, 'remote_a');
      Directory(p.join(remoteRoot, 'docs')).createSync(recursive: true);
      File(p.join(remoteRoot, 'docs', 'a.txt')).writeAsStringSync('hello');

      final TeamMessageDispatcher d = cross(
        localDirOf: (String id) => id == ready ? localRoot : '',
        ioOf: (String id) async =>
            id == top.id ? PrivateWorkspaceIO(LocalWorkspaceIO(remoteRoot), id) : null,
      );
      final Map<String, dynamic> result = await d.run(
        top.id,
        <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['docs/a.txt'],
        },
      );

      expect(result['status'], 'sent');
      expect(delivered.single['content'], contains('附件已投递 1 个'));
      final File? copied = deliveredFile(localRoot, 'a.txt');
      expect(copied, isNotNull);
      expect(copied!.readAsStringSync(), 'hello');
    });

    test('remote→remote（同一远端根）：读 → 写共用一条工作空间 IO 通路', () async {
      final String ready = member(approved: true);
      final String remoteRoot = p.join(temp.path, 'remote_same');
      Directory(p.join(remoteRoot, 'docs')).createSync(recursive: true);
      File(p.join(remoteRoot, 'docs', 'a.txt')).writeAsStringSync('hello');

      final TeamMessageDispatcher d = cross(
        localDirOf: (String _) => '',
        ioOf: (String id) async =>
            PrivateWorkspaceIO(LocalWorkspaceIO(remoteRoot), id),
      );
      final Map<String, dynamic> result = await d.run(
        top.id,
        <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['docs/a.txt'],
        },
      );

      expect(result['status'], 'sent');
      final File? copied = deliveredFile(remoteRoot, 'a.txt');
      expect(copied, isNotNull);
      expect(copied!.readAsStringSync(), 'hello');
    });

    test('remote→remote（跨机）：两棵不同远端根，经本机进程读→写中转', () async {
      final String ready = member(approved: true);
      final String hostA = p.join(temp.path, 'host_a');
      final String hostB = p.join(temp.path, 'host_b');
      Directory(p.join(hostA, 'docs')).createSync(recursive: true);
      File(p.join(hostA, 'docs', 'a.txt')).writeAsStringSync('hello');

      final TeamMessageDispatcher d = cross(
        localDirOf: (String _) => '',
        ioOf: (String id) async {
          final String root = id == top.id ? hostA : hostB;
          return PrivateWorkspaceIO(LocalWorkspaceIO(root), id);
        },
      );
      final Map<String, dynamic> result = await d.run(
        top.id,
        <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['docs/a.txt'],
        },
      );

      expect(result['status'], 'sent');
      final File? copied = deliveredFile(hostB, 'a.txt');
      expect(copied, isNotNull, reason: '跨机必须落到**接收方那台主机**的根下');
      expect(copied!.readAsStringSync(), 'hello');
      expect(
        deliveredFile(hostA, 'a.txt'),
        isNull,
        reason: '不许把它又写回发送方那台主机',
      );
      expect(
        delivered.single['content'],
        contains('跨机经本机中转'),
        reason: '跨机要如实说明走的是本机进程中转',
      );
    });

    test('远端源超过单文件上限：拒绝（先问 WorkspaceFiles.sizeOf 再决定读多少）', () async {
      final String ready = member(approved: true);
      final String hostA = p.join(temp.path, 'host_a');
      final String hostB = p.join(temp.path, 'host_b');
      Directory(hostA).createSync(recursive: true);
      File(p.join(hostA, 'big.txt')).writeAsStringSync('12345'); // 5 字节
      File(p.join(hostA, 'ok.txt')).writeAsStringSync('123'); // 3 字节

      final TeamMessageDispatcher d = cross(
        localDirOf: (String _) => '',
        ioOf: (String id) async =>
            PrivateWorkspaceIO(LocalWorkspaceIO(id == top.id ? hostA : hostB), id),
        maxFileBytes: 4,
      );
      final Map<String, dynamic> result = await d.run(
        top.id,
        <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['big.txt', 'ok.txt'],
        },
      );

      expect(result['status'], 'sent');
      final String note = delivered.single['content'] as String;
      expect(note, contains('附件已投递 1 个'));
      expect(note, contains('失败：big.txt'));
      expect(deliveredFile(hostB, 'big.txt'), isNull);
      expect(deliveredFile(hostB, 'ok.txt'), isNotNull);
    });

    test('ioFor 未接线（返回 null）：回可读原因、消息照常送达、不复制到无关目录', () async {
      final String ready = member(approved: true);
      final String localRoot = p.join(temp.path, top.id);
      Directory(localRoot).createSync(recursive: true);
      File(p.join(localRoot, 'a.txt')).writeAsStringSync('hello');

      final TeamMessageDispatcher d = cross(
        localDirOf: (String id) => id == top.id ? localRoot : '',
        ioOf: (String _) async => null,
      );
      final Map<String, dynamic> result = await d.run(
        top.id,
        <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['a.txt'],
        },
      );

      expect(result['status'], 'sent', reason: '附件投不进去，消息本身照样要送到');
      expect(delivered.single['agentId'], ready);
      final String note = delivered.single['content'] as String;
      expect(note, contains('未投递'), reason: '必须如实说清附件没送到');
      expect(note, contains('工作空间'), reason: '原因要可读：说清是哪一侧的工作空间解析不到');
      expect(
        Directory(p.join(temp.path, ready, '.input')).existsSync(),
        isFalse,
        reason: '不许悄悄复制到本机某个无关目录',
      );
    });

    test('路径越界（.. 逃逸 / 绝对路径 / 盘符 / ~）：一律拒绝并如实计入 files_failed', () async {
      final String ready = member(approved: true);
      final String localRoot = p.join(temp.path, top.id);
      Directory(localRoot).createSync(recursive: true);
      File(p.join(localRoot, 'ok.txt')).writeAsStringSync('ok');
      const List<String> bad = <String>[
        '../escape.txt',
        '../../escape.txt',
        'docs/../../escape.txt',
        'C:/Windows/win.ini',
        '/etc/passwd',
        '~/secret.txt',
        '..',
        '.',
      ];
      final Map<String, dynamic> result = await dispatcher.run(
        top.id,
        <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['ok.txt', ...bad],
        },
      );

      expect(result['status'], 'sent');
      final String note = delivered.single['content'] as String;
      expect(note, contains('附件已投递 1 个'), reason: '只有 ok.txt 该被投递');
      expect(note, contains('失败：'));
      for (final String raw in bad) {
        expect(note, contains(raw), reason: '$raw 必须如实出现在失败清单里');
      }
      expect(
        deliveredFile(p.join(temp.path, ready), 'ok.txt')!.readAsStringSync(),
        'ok',
      );
      expect(
        Directory(p.join(temp.path, ready, '.input'))
            .listSync(recursive: true)
            .whereType<File>(),
        hasLength(1),
        reason: '越界路径一个都不许落地',
      );
    });

    test('超过单文件上限：拒绝并计入 files_failed（生产默认仍是 32 MB）', () async {
      final String ready = member(approved: true);
      final String localRoot = p.join(temp.path, top.id);
      Directory(localRoot).createSync(recursive: true);
      File(p.join(localRoot, 'big.txt')).writeAsStringSync('12345'); // 5 字节
      File(p.join(localRoot, 'small.txt')).writeAsStringSync('123'); // 3 字节

      // 注入点：`maxFileBytes` 本就是构造参数（生产默认 32 MB），小值即可，不必真造 32 MB 文件。
      final TeamMessageDispatcher tiny = cross(
        localDirOf: (String id) => p.join(temp.path, id),
        ioOf: (String id) async =>
            PrivateWorkspaceIO(LocalWorkspaceIO(p.join(temp.path, id)), id),
        maxFileBytes: 4,
      );
      final Map<String, dynamic> result = await tiny.run(
        top.id,
        <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['big.txt', 'small.txt'],
        },
      );

      expect(result['status'], 'sent');
      final String note = delivered.single['content'] as String;
      expect(note, contains('附件已投递 1 个'));
      expect(note, contains('失败：big.txt'));
      expect(deliveredFile(p.join(temp.path, ready), 'big.txt'), isNull);
      expect(deliveredFile(p.join(temp.path, ready), 'small.txt'), isNotNull);
    });

    test('部分失败：一个能投一个不能 ⇒ 成功计数与失败清单各自正确', () async {
      final String ready = member(approved: true);
      final String localRoot = p.join(temp.path, top.id);
      Directory(p.join(localRoot, 'docs')).createSync(recursive: true);
      File(p.join(localRoot, 'docs', 'a.txt')).writeAsStringSync('hello');

      final Map<String, dynamic> result = await dispatcher.run(
        top.id,
        <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['docs/a.txt', 'missing.txt'],
        },
      );

      expect(result['status'], 'sent');
      final String note = delivered.single['content'] as String;
      expect(note, contains('附件已投递 1 个'));
      expect(note, contains('失败：missing.txt'));
      expect(deliveredFile(p.join(temp.path, ready), 'a.txt'), isNotNull);
      expect(deliveredFile(p.join(temp.path, ready), 'missing.txt'), isNull);
    });

    test('local→local 文案逐字不变：仍是"附件已投递 N 个到 <相对目录>"', () async {
      final String ready = member(approved: true);
      final String localRoot = p.join(temp.path, top.id);
      Directory(p.join(localRoot, 'docs')).createSync(recursive: true);
      File(p.join(localRoot, 'docs', 'a.txt')).writeAsStringSync('hello');

      await dispatcher.run(
        top.id,
        <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['docs/a.txt'],
        },
      );

      expect(
        delivered.single['content'],
        '看附件\n\n（附件已投递 1 个到 ${p.join('.input', today())}）',
        reason: '本机之间的既有文案不许漂移（跨机才追加"经本机中转"的说明）',
      );
    });

    // ── 真机（门控）────────────────────────────────────────────────────────
    // 环境变量（缺 TREE_SSH_TEST_HOST 自动 skip，与 ssh_files_integration_test.dart 同风格）：
    //   TREE_SSH_TEST_HOST / TREE_SSH_TEST_USER（默认 open）/ TREE_SSH_TEST_KEY / TREE_SSH_TEST_ROOT
    test('真机门控：SFTP 附件投递（local→SSH / SSH→local / SSH→SSH）', () async {
      final String host = Platform.environment['TREE_SSH_TEST_HOST'] ?? '';
      if (host.isEmpty) {
        markTestSkipped('未设置 TREE_SSH_TEST_HOST，跳过真机附件投递测试');
        return;
      }
      final String home =
          Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
      final String user = Platform.environment['TREE_SSH_TEST_USER'] ?? 'open';
      final String keyPath =
          Platform.environment['TREE_SSH_TEST_KEY'] ?? '$home/.ssh/id_ed25519';
      final String root = Platform.environment['TREE_SSH_TEST_ROOT'] ?? '/mnt/space';

      final DartSshTransport transport = await DartSshTransport.connect(
        host: host,
        port: 22,
        username: user,
        keyPath: keyPath,
      );
      final String remoteRoot = await resolveRemoteRoot(transport, root);
      final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String srcDir = 'tree_msg_src_$stamp';
      final String dstDir = 'tree_msg_dst_$stamp';
      final PrivateWorkspaceIO srcIo = PrivateWorkspaceIO(
        SshWorkspaceIO('$remoteRoot/$srcDir', transport),
        'remote_src',
      );
      final PrivateWorkspaceIO dstIo = PrivateWorkspaceIO(
        SshWorkspaceIO('$remoteRoot/$dstDir', transport),
        'remote_dst',
      );
      try {
        await srcIo.writeBytes('docs/remote.txt', utf8.encode('from-remote'));
        final String ready = member(approved: true);
        final String localRoot = p.join(temp.path, top.id);
        final String box = p.join(temp.path, ready);
        Directory(p.join(localRoot, 'docs')).createSync(recursive: true);
        File(p.join(localRoot, 'docs', 'local.txt')).writeAsStringSync('from-local');

        // ① local → SSH：经本机读、SFTP 写
        final Map<String, dynamic> r1 = await cross(
          localDirOf: (String id) => id == top.id ? localRoot : '',
          ioOf: (String id) async => id == ready ? dstIo : null,
        ).run(top.id, <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['docs/local.txt'],
        });
        expect(r1['status'], 'sent');
        expect(delivered.last['content'], contains('附件已投递 1 个'));
        expect(
          utf8.decode(await dstIo.readBytes('.input/${today()}/local.txt')),
          'from-local',
          reason: '必须真的写进接收方远端工作空间（SFTP writeBytes）',
        );

        // ② SSH → local：经 SFTP 读、本机写
        final Map<String, dynamic> r2 = await cross(
          localDirOf: (String id) => id == ready ? box : '',
          ioOf: (String id) async => id == top.id ? srcIo : null,
        ).run(top.id, <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['docs/remote.txt'],
        });
        expect(r2['status'], 'sent');
        expect(
          deliveredFile(box, 'remote.txt')?.readAsStringSync(),
          'from-remote',
          reason: '远端源必须真的读出来（SFTP readBytes）再落到接收方本机',
        );

        // ③ SSH → SSH：两棵不同的远端根，经本机内存中转
        final Map<String, dynamic> r3 = await cross(
          localDirOf: (String _) => '',
          ioOf: (String id) async => id == top.id ? srcIo : dstIo,
        ).run(top.id, <String, dynamic>{
          'action': 'send_message',
          'target_member_id': ready,
          'message': '看附件',
          'files': <String>['docs/remote.txt'],
        });
        expect(r3['status'], 'sent');
        expect(delivered.last['content'], contains('跨机经本机中转'));
        expect(
          utf8.decode(await dstIo.readBytes('.input/${today()}/remote.txt')),
          'from-remote',
        );
        print('真机附件投递：local→SSH / SSH→local / SSH→SSH 各 1 份均通过');
      } finally {
        // 收尾：只删**本次运行**建的两个子目录（绝不删工作空间根）。
        final WorkspaceFiles parent = SshWorkspaceIO(remoteRoot, transport);
        for (final String dir in <String>[srcDir, dstDir]) {
          try {
            await parent.remove(dir, recursive: true);
          } catch (_) {
            // 清理失败不影响测试结论
          }
        }
        await transport.close();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
