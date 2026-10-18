import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/station_ids.dart';
import 'package:tree_core/src/plugin/station_instance.dart';
import 'package:tree_core/src/plugin/station_runtime.dart';
import 'package:tree_core/src/plugin/station_scope.dart';
import 'package:tree_core/src/plugin/stations.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 站点体系（M9 §3）：四站 + 落盘 + 隔离 + 收集站部分结果。
///
/// 这里用**进程内假订阅者**（闭包 responder + 可注入的活性探针）验证站点语义：
/// 站点是纯数据面，插件进程的真实往返另有 plugin_test / plugin_tool_define_test。
void main() {
  late Directory temp;
  late String storePath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_station_');
    storePath = p.join(temp.path, 'config', 'stations.yaml');
  });

  tearDown(() {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        // Windows 上文件句柄可能还没释放，稍后重试
      }
    }
  });

  StationHub hub({
    Duration interval = const Duration(milliseconds: 60),
    int miss = 3,
    String? path,
    void Function(Map<String, dynamic> frame)? frameSink,
  }) => StationHub(
    storePath: path ?? storePath,
    heartbeatInterval: interval,
    missThreshold: miss,
    livenessProbeInterval: const Duration(milliseconds: 10),
    frameSink: frameSink,
  );

  StationScope team(String id, {String mode = StationModeKey.local}) =>
      StationScope(teamId: id, modeKey: mode);

  StationResponder ok([Object? payload]) =>
      (StationRequest request) async => StationReply.ok(payload);

  test('站点实例落盘与恢复：实例 + 订阅者 + 公告板跨重启保留', () async {
    final StationHub first = hub();
    final StationScope scope = team('team-1');
    final BroadcastStation broadcast = first.broadcastFor()!;
    expect(broadcast.builtin, isTrue);
    // 站点全局唯一：id 是类型常量，**不绑 team / mode**（收敛后这些是消息信封属性）
    expect(broadcast.id, StationHubIds.broadcast);
    expect(broadcast.scope.teamId, isEmpty, reason: '站点不再绑 team');

    final StationSubResult sub = first.subscribe(
      broadcast.id,
      StationSubscriber(pluginId: 'p1', scope: scope, subscribedAt: 11),
      ok(<String, dynamic>{'seen': true}),
    );
    expect(sub.ok, isTrue);
    final StationPublishResult publish = await broadcast.publish(
      topic: 'hello',
      scope: scope,
      payload: <String, dynamic>{'x': 1},
      sourcePluginId: 'p1',
    );
    expect(publish.boardSeq, 1);
    expect(publish.delivered, 1);
    expect(File(storePath).existsSync(), isTrue, reason: '订阅关系必须落盘');

    // 「重启」：新中枢读同一个文件
    final StationHub second = hub();
    second.load();
    final StationInstance? restored = second.station(broadcast.id);
    expect(restored, isA<BroadcastStation>());
    expect(restored!.id, StationHubIds.broadcast, reason: '恢复后仍是全局 id');
    expect(restored.maxSubscriptions, broadcast.maxSubscriptions);
    expect(restored.subscribers.single.pluginId, 'p1');
    expect(
      restored.subscribers.single.scope.teamId,
      'team-1',
      reason: '订阅声明的归属必须跨重启保留（面板的 team 视角靠它）',
    );
    final BroadcastStation reloaded = restored as BroadcastStation;
    expect(reloaded.boardSeq, 1);
    expect(reloaded.boardEntries().single.topic, 'hello');
    expect(reloaded.boardEntries().single.payload, <String, dynamic>{'x': 1});

    final StationPublishResult again = await reloaded.publish(
      topic: 'again',
      scope: scope,
    );
    expect(again.boardSeq, 2, reason: '公告板序号跨重启不回退');
    expect(
      reloaded.boardEntries().map((StationBoardEntry e) => e.topic),
      <String>['again', 'hello'],
    );
  });

  test('订阅上限：实例自带上限，超限拒绝订阅并显式报错', () async {
    final StationHub h = hub();
    final StationScope scope = team('team-1');
    expect(
      h.register(
        CollectStation(
          id: 'plugin.demo.collect',
          description: '插件自建收集站（上限 2）',
          schema: StationHub.toolDefinitionSchema,
          maxSubscriptions: 2,
        ),
      ),
      isNull,
    );
    final StationInstance station = h.station('plugin.demo.collect')!;
    for (int i = 0; i < 2; i++) {
      final StationSubResult result = h.subscribe(
        station.id,
        StationSubscriber(pluginId: 'p$i', scope: scope),
        ok(),
      );
      expect(result.ok, isTrue);
    }
    final StationSubResult overflow = h.subscribe(
      station.id,
      StationSubscriber(pluginId: 'p2', scope: scope),
      ok(),
    );
    expect(overflow.ok, isFalse);
    expect(overflow.code, 'subscription_limit');
    expect(overflow.error, contains('订阅上限'));
    expect(overflow.error, contains('p2'));
    expect(station.subscribers, hasLength(2));
    expect(station.counters['overflow'], 1);
  });

  test('隔离：四元组精确匹配，跨 team / 跨 mode 一律不投递（fail-closed）', () async {
    final StationHub h = hub();
    final StationScope teamA = team('team-a');
    final StationScope teamB = team('team-b');
    final BroadcastStation broadcast = h.broadcastFor()!;
    final List<String> delivered = <String>[];
    h.subscribe(broadcast.id, StationSubscriber(pluginId: 'pa', scope: teamA), (
      StationRequest request,
    ) async {
      delivered.add(request.requestId);
      return const StationReply.ok();
    });
    expect((await broadcast.publish(topic: 't', scope: teamA)).delivered, 1);

    // 站点全局唯一后，**投递判定改由「消息 ↔ 订阅者」承担**：team-b 的消息是
    // 合法消息（站点不绑 team），但没有任何订阅者匹配 ⇒ 一个都不投。
    final StationPublishResult crossTeam = await broadcast.publish(
      topic: 't',
      scope: teamB,
    );
    expect(crossTeam.delivered, 0, reason: '跨 team 不投给 team-a 的订阅者');
    expect(
      crossTeam.boardSeq,
      2,
      reason: '公告板是全局的（站不绑 team）：消息本身合法，照常入板（第 2 条）',
    );
    expect(crossTeam.skipped.single, contains('跨 team'));

    final StationPublishResult crossMode = await broadcast.publish(
      topic: 't',
      scope: team('team-a', mode: StationModeKey.ssh),
    );
    expect(crossMode.delivered, 0);
    expect(crossMode.skipped.single, contains('跨模式'));

    // 另一个 team 的订阅者可以**正常订上**（站点不再按 team 拒绝订阅）；
    // 它只是收不到 team-a 的消息——隔离仍在，只是落点从"站"移到了"投递"。
    final StationSubResult otherTeam = h.subscribe(
      broadcast.id,
      StationSubscriber(pluginId: 'pb', scope: teamB),
      ok(),
    );
    expect(otherTeam.ok, isTrue, reason: '订阅按声明归属生效，站点不拒绝别的 team');
    expect(
      (await broadcast.publish(topic: 't', scope: teamA)).delivered,
      1,
      reason: 'team-b 的订阅者不会收到 team-a 的消息',
    );
    final StationPublishResult forBoth = await broadcast.publish(
      topic: 't',
      scope: teamB,
    );
    expect(forBoth.delivered, 1, reason: 'team-b 的消息投给 team-b 的订阅者');
    expect(forBoth.skipped.single, contains('team-a'));

    // 订阅可声明**更细**粒度，但不得放大：agent 级订阅只收本 agent 的消息
    h.subscribe(
      broadcast.id,
      StationSubscriber(
        pluginId: 'pa2',
        scope: StationScope(teamId: 'team-a', agentId: 'agt-1'),
      ),
      (StationRequest request) async {
        delivered.add('agt-1');
        return const StationReply.ok();
      },
    );
    final StationPublishResult forAgent1 = await broadcast.publish(
      topic: 't',
      scope: StationScope(teamId: 'team-a', agentId: 'agt-1'),
    );
    expect(forAgent1.delivered, 2, reason: 'pa 不限 agent、pa2 限定 agt-1');
    final StationPublishResult forAgent2 = await broadcast.publish(
      topic: 't',
      scope: StationScope(teamId: 'team-a', agentId: 'agt-2'),
    );
    expect(forAgent2.delivered, 1);
    // 被跳过的有两条：team-b 的订阅者（跨 team）+ 限定 agt-1 的 pa2（agent 不符）
    expect(forAgent2.skipped, hasLength(2));
    expect(forAgent2.skipped.join('；'), contains('agt-1'));
    expect(forAgent2.skipped.join('；'), contains('跨 team'));
    expect(delivered, hasLength(5), reason: '第 1 次 + team-a 两次 + team-b 一次 + agt-1 一次');
  });
  test('收集站：部分结果 + 未响应者清单（心跳丢失 / 窗口内无回 / 校验失败）', () async {
    final StationHub h = hub();
    final StationScope scope = team('team-1');
    final CollectStation station = h.toolDefineStationFor()!;
    expect(station.schema.fields.map((dynamic f) => f.name), <String>['tools']);

    h.subscribe(
      station.id,
      StationSubscriber(pluginId: 'good', scope: scope),
      (StationRequest request) async => StationReply.ok(<String, dynamic>{
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{
            'tool_name': 'echo',
            'description': '回显',
            'parameters': <String, dynamic>{'type': 'object'},
          },
        ],
      }),
    );
    h.subscribe(
      station.id,
      StationSubscriber(pluginId: 'bad-schema', scope: scope),
      (StationRequest request) async =>
          const StationReply.ok(<String, dynamic>{'tools': 'not-a-list'}),
    );
    h.subscribe(
      station.id,
      StationSubscriber(pluginId: 'silent', scope: scope),
      (StationRequest request) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return const StationReply.ok();
      },
    );
    // 心跳判活：silent 心跳丢失 ⇒ 立即判未响应（不等窗口、不阻塞整体）
    h.livenessProbe = (String pluginId) => pluginId == 'silent'
        ? const StationLivenessState.lost('连续 3 拍未达')
        : const StationLivenessState.alive();

    final StationCollectResult result = await station.collect(scope: scope);
    expect(result.items, hasLength(1));
    expect(result.items.single.pluginId, 'good');
    expect(result.complete, isFalse);
    expect(
      result.unresponsive.map((StationUnresponsive u) => u.pluginId).toSet(),
      <String>{'bad-schema', 'silent'},
    );
    final StationUnresponsive silent = result.unresponsive.firstWhere(
      (StationUnresponsive u) => u.pluginId == 'silent',
    );
    expect(silent.reason, contains('心跳丢失'));
    final StationUnresponsive schema = result.unresponsive.firstWhere(
      (StationUnresponsive u) => u.pluginId == 'bad-schema',
    );
    expect(schema.reason, contains('schema'));
    expect(result.describe(), contains('未响应'));
    expect(station.counters['waits_in_flight'], 0);
  });

  test('收集站：无活性信息的订阅者只在活性窗口内无回时才判未响应', () async {
    final StationHub h = hub(
      interval: const Duration(milliseconds: 40),
      miss: 2,
    );
    final StationScope scope = team('team-1');
    final CollectStation station = h.toolDefineStationFor()!;
    h.subscribe(station.id, StationSubscriber(pluginId: 'slow', scope: scope), (
      StationRequest request,
    ) async {
      // 比活性窗口（40ms×2=80ms）慢，但仍会回：响应到达后照收
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return const StationReply.ok(<String, dynamic>{
        'tools': <Map<String, dynamic>>[],
      });
    });
    h.subscribe(
      station.id,
      StationSubscriber(pluginId: 'never', scope: scope),
      (StationRequest request) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return const StationReply.ok();
      },
    );
    final StationCollectResult result = await station.collect(scope: scope);
    expect(result.items.single.pluginId, 'slow');
    expect(result.unresponsive.single.pluginId, 'never');
    expect(result.unresponsive.single.reason, contains('活性窗口'));
  });

  test('中转站·工具前点位：**全站唯一订阅者**（先到先得 + 显式 replace），且 fail-open 放行原数据', () async {
    final StationHub h = hub();
    final StationScope scope = team('team-1');
    final RelayStation relay = h.relayPointFor(StationHubIds.relayToolPre)!;
    expect(relay.scopeKeyUnique, isTrue);

    final StationSubResult first = h.subscribe(
      relay.id,
      StationSubscriber(pluginId: 'p1', scope: scope),
      (StationRequest request) async =>
          StationReply.ok('p1 改写：${request.payload}'),
    );
    expect(first.ok, isTrue);
    // 另一个 team 也不能再订**同一个点位**（旧口径是"站 × scope 键位唯一"，那会按 team
    // 各放一个；新口径是"一个拦截点一个处理者"——要分流由转发型订阅者自己分发）。
    final StationSubResult second = h.subscribe(
      relay.id,
      StationSubscriber(pluginId: 'p2', scope: team('team-2')),
      (StationRequest request) async => const StationReply.ok('p2 改写'),
    );
    expect(second.ok, isFalse, reason: '中转站点位只允许一个订阅者（与 scope 无关）');
    expect(second.code, 'key_conflict');
    expect(second.error, contains('p1'));
    expect(
      second.error,
      contains('转发'),
      reason: '拒绝信息要给出正解：由订阅者自己转发，而不是重复订阅',
    );

    final StationRelayResult relayed = await relay.relay(
      data: '原数据',
      scope: scope,
    );
    expect(relayed.handled, isTrue);
    expect(relayed.pluginId, 'p1');
    expect(relayed.data, 'p1 改写：原数据');

    // 订阅者若声明了粒度，只接匹配的消息（fail-closed，但不是"没人则放行"）
    h.subscribe(
      relay.id,
      StationSubscriber(
        pluginId: 'p1',
        scope: StationScope(teamId: 'team-1', agentId: 'agt-1'),
      ),
      (StationRequest request) async => const StationReply.ok('p1 agent 版'),
      replace: true,
    );
    expect(
      (await relay.relay(data: '原数据', scope: scope)).handled,
      isFalse,
      reason: '订阅者限定 agt-1，团队级消息（agent 为空）不匹配 ⇒ 原数据放行',
    );
    expect(
      (await relay.relay(
        data: '原数据',
        scope: StationScope(teamId: 'team-1', agentId: 'agt-1'),
      )).data,
      'p1 agent 版',
    );

    // 换回团队级订阅者（后续步骤都用团队级 scope 验证回填类型）
    h.subscribe(
      relay.id,
      StationSubscriber(pluginId: 'p2', scope: scope),
      (StationRequest request) async => const StationReply.ok('p2 改写'),
      replace: true,
    );

    // 换回团队级订阅者（后续步骤都用团队级 scope 验证回填类型）
    h.subscribe(
      relay.id,
      StationSubscriber(pluginId: 'p2', scope: scope),
      (StationRequest request) async => const StationReply.ok('p2 改写'),
      replace: true,
    );

    // 显式 replace：接管并回报被替换者
    final StationSubResult replaced = h.subscribe(
      relay.id,
      StationSubscriber(pluginId: 'p3', scope: scope),
      (StationRequest request) async => const StationReply.ok('p3 改写'),
      replace: true,
    );
    expect(replaced.ok, isTrue);
    expect(
      replaced.replacedPluginId,
      'p2',
      reason: '回填里带上被顶掉的订阅者，接管方知道自己在接谁的班',
    );
    expect((await relay.relay(data: '原数据', scope: scope)).data, 'p3 改写');

    // 回包类型非法 / 无订阅者 ⇒ fail-open 放行原数据（绝不抛出）
    h.subscribe(
      relay.id,
      StationSubscriber(pluginId: 'p3', scope: scope),
      (StationRequest request) async => const StationReply.ok(42),
      replace: true,
    );
    final StationRelayResult invalid = await relay.relay(
      data: '原数据',
      scope: scope,
    );
    expect(invalid.handled, isFalse);
    expect(invalid.data, '原数据');
    expect(invalid.reason, contains('非法'));

    // 结构化回填（对象 / 数组）**整体替换**：工具调用报文本身就是 Map，
    // 只支持 string 会让「改写工具参数」无路可走（本次扩展的用途）。
    h.subscribe(
      relay.id,
      StationSubscriber(pluginId: 'p2', scope: scope),
      (StationRequest request) async => StationReply.ok(<String, dynamic>{
        'phase': 'post',
        'result': '被插件改写',
      }),
      replace: true,
    );
    final StationRelayResult structured = await relay.relay(
      data: <String, dynamic>{'phase': 'pre', 'result': '原结果'},
      scope: scope,
    );
    expect(structured.handled, isTrue);
    expect(structured.data, <String, dynamic>{
      'phase': 'post',
      'result': '被插件改写',
    });

    h.subscribe(
      relay.id,
      StationSubscriber(pluginId: 'p2', scope: scope),
      (StationRequest request) async => StationReply.ok(<Object?>['a', 'b']),
      replace: true,
    );
    final StationRelayResult array = await relay.relay(
      data: <Object?>['原'],
      scope: scope,
    );
    expect(array.handled, isTrue);
    expect(array.data, <Object?>['a', 'b']);

    final StationHub other = hub(path: p.join(temp.path, 'other.yaml'));
    final RelayStation empty = other.relayPointFor(
      StationHubIds.relayToolPre,
    )!;
    final StationRelayResult noSubscriber = await empty.relay(
      data: '原数据',
      scope: scope,
    );
    expect(noSubscriber.handled, isFalse);
    expect(noSubscriber.data, '原数据');
    expect(noSubscriber.reason, contains('无匹配订阅者'));

    // 跨 scope：无匹配订阅者 ⇒ fail-open 放行原数据（绝不阻塞工具调用）
    final StationRelayResult cross = await relay.relay(
      data: '原数据',
      scope: team('team-2'),
    );
    expect(cross.handled, isFalse);
    expect(cross.data, '原数据');
    expect(cross.reason, contains('无匹配订阅者'));
  });

  test('中转站点位化：**两个不同点位各自可以有订阅者，互不干扰**（点位化的核心收益）', () async {
    final StationHub h = hub();
    final StationScope scope = team('team-1');
    final RelayStation pre = h.relayPointFor(StationHubIds.relayToolPre)!;
    final RelayStation post = h.relayPointFor(StationHubIds.relayToolPost)!;
    expect(pre.id, isNot(post.id), reason: '工具前 / 工具后是两个独立实例');

    // 「接管某一段」不再顺带垄断另一段：两个**不同**插件各订一个点位，都成立。
    // （同一个点位仍然只有一个订阅者——那是上一条用例锁住的语义。）
    final StationSubResult preSub = h.subscribe(
      pre.id,
      StationSubscriber(pluginId: 'pre-plugin', scope: scope),
      (StationRequest request) async => StationReply.ok('pre 改写'),
    );
    expect(preSub.ok, isTrue, reason: preSub.error);
    final StationSubResult postSub = h.subscribe(
      post.id,
      StationSubscriber(pluginId: 'post-plugin', scope: scope),
      (StationRequest request) async => StationReply.ok('post 改写'),
    );
    expect(
      postSub.ok,
      isTrue,
      reason:
          '另一个点位的订阅者与工具前点位无关：'
          '点位化之前这个插件会被"已在别处有订阅者"顶掉——'
          '「职责交给插件、无订阅者才回退系统默认」因此退化成"只能有一个插件"，'
          '这正是本次点位化要修的问题。${postSub.error}',
    );
    expect(pre.subscribers.single.pluginId, 'pre-plugin');
    expect(post.subscribers.single.pluginId, 'post-plugin');

    // 各自回填自己的那段，互不串台
    expect((await pre.relay(data: '原数据', scope: scope)).data, 'pre 改写');
    expect((await post.relay(data: '原数据', scope: scope)).data, 'post 改写');

    // 同一个点位的第二个订阅者仍被拒（唯一订阅者语义没有被点位化削弱）
    final StationSubResult conflict = h.subscribe(
      pre.id,
      StationSubscriber(pluginId: 'third', scope: scope),
      (StationRequest request) async => const StationReply.ok('third'),
    );
    expect(conflict.ok, isFalse);
    expect(conflict.code, 'key_conflict');
    expect(pre.subscribers.single.pluginId, 'pre-plugin');
  });

  test('广播站：持久公告板按容量裁剪，可回看最近若干条', () async {
    final StationHub h = hub();
    final StationScope scope = team('team-1');
    expect(
      h.register(
        BroadcastStation(
          id: 'plugin.demo.broadcast',
          description: '插件自建广播站（公告板只留 2 条）',
          boardLimit: 2,
        ),
      ),
      isNull,
    );
    final BroadcastStation broadcast =
        h.station('plugin.demo.broadcast')! as BroadcastStation;
    for (int i = 1; i <= 4; i++) {
      await broadcast.publish(topic: 't$i', scope: scope);
    }
    expect(broadcast.boardSeq, 4);
    expect(broadcast.board, hasLength(2), reason: '超出容量的最旧条目被丢弃');
    expect(
      broadcast.boardEntries().map((StationBoardEntry e) => e.topic),
      <String>['t4', 't3'],
    );
    expect(broadcast.boardEntries(limit: 1).single.topic, 't4', reason: '最新在前');

    final StationHub reloaded = hub();
    reloaded.load();
    final BroadcastStation restored =
        reloaded.station('plugin.demo.broadcast')! as BroadcastStation;
    expect(restored.boardSeq, 4);
    expect(
      restored.boardEntries().map((StationBoardEntry e) => e.topic),
      <String>['t4', 't3'],
    );
    expect(restored.boardLimit, 2);
  });

  test('执行站·文件操作点位：白名单 + 隔离 + 挂载位置；不订阅、不触发插件', () async {
    final StationHub h = hub();
    final StationScope scope = team('team-1');
    final ExecuteStation execute = h.executePointFor(StationHubIds.executeFs)!;
    // 白名单由**点位**决定：本点位只有 fs.* 一族；全命令并集仍可从 builtinCommands 取
    expect(execute.commands, contains('fs.read'));
    expect(execute.commands, isNot(contains('ui.push')), reason: 'ui.push 属于前端推送点位');
    expect(ExecuteStation.builtinCommands, contains('fs.read'));
    expect(ExecuteStation.builtinCommands, contains('ui.push'));
    expect(execute.kind.subscribable, isFalse);

    // 未挂载：显式错误（不是静默成功）
    final StationCommandResult noMount = await execute.execute(
      command: 'fs.read',
      scope: scope,
    );
    expect(noMount.ok, isFalse);
    expect(noMount.error, contains('暂无挂载位置'));

    // 挂载位置（「执行器只是站点的一种挂载位置」）
    expect(
      execute.mount(
        command: 'fs.read',
        mountId: 'test.frontend',
        handler: (StationCommandContext context) async =>
            StationCommandOutcome.ok(<String, dynamic>{
              'path': context.arguments['path'],
              'team': context.scope.teamId,
              'mode': context.scope.modeKey,
            }),
      ),
      isNull,
    );
    final StationCommandResult read = await execute.execute(
      command: 'fs.read',
      scope: scope,
      arguments: <String, dynamic>{'path': '/a.txt'},
    );
    expect(read.ok, isTrue);
    expect(read.mountId, 'test.frontend');
    final Map<String, dynamic> payload = read.payload! as Map<String, dynamic>;
    expect(payload['path'], '/a.txt');
    expect(payload['team'], 'team-1');
    expect(payload['mode'], 'local');

    // 白名单外：挂载被拒 + 执行被拒（错误里要能读出"本点位允许什么"）
    expect(
      execute.mount(
        command: 'shell.rm',
        mountId: 'x',
        handler: (StationCommandContext context) async =>
            const StationCommandOutcome.ok(),
      ),
      contains('不属于点位'),
    );
    // 别的点位的命令也挂不上（命令族之间互不干扰：这是点位化的直接收益）
    expect(
      execute.mount(
        command: 'terminal.exec',
        mountId: 'x',
        handler: (StationCommandContext context) async =>
            const StationCommandOutcome.ok(),
      ),
      contains(StationHubIds.executeFs),
    );
    final StationCommandResult denied = await execute.execute(
      command: 'shell.rm',
      scope: scope,
    );
    expect(denied.ok, isFalse);
    expect(denied.error, contains('不属于点位'));

    // 站点不再持有 scope（全局唯一），因此**站点层不做隔离拒绝**：scope 原样交给
    // 挂载位置。真正的跨 team / 跨模式 fail-closed 落点在两处（都另有专项测试）：
    // ① 插件总线下命令前的 `_resolveCommandScope`；② 挂载位置的 `_resolveTarget`。
    final StationCommandResult crossMode = await execute.execute(
      command: 'fs.read',
      scope: team('team-1', mode: StationModeKey.ssh),
    );
    expect(crossMode.ok, isTrue, reason: '站点层只透传 scope');
    final Map<String, dynamic> relayedScope =
        crossMode.payload! as Map<String, dynamic>;
    expect(
      relayedScope['mode'],
      StationModeKey.ssh,
      reason: '挂载位置必须拿到真实 mode，才能自己判跨模式并拒绝',
    );
    expect(relayedScope['team'], 'team-1');

    // 命令的 team 允许为空 = **通配所有 team**（用户定稿：为空默认作用于所有 team）。
    // 站点层只透传 scope；需要落到实处的命令由挂载位置自己拒绝
    // （execute_mounts._resolveTarget：缺 team / agent 解析不出 / 模式对不上都拒）。
    final StationCommandResult noTeam = await execute.execute(
      command: 'fs.read',
      scope: const StationScope(modeKey: StationModeKey.local),
    );
    expect(noTeam.ok, isTrue, reason: '站点层不再替挂载位置兜底：空 team = 通配');
    expect((noTeam.payload! as Map<String, dynamic>)['team'], '');

    // mode 非法（拼错）⇒ 站点层就拒：命令必须能落到某个工作面上才谈得上执行
    final StationCommandResult badMode = await execute.execute(
      command: 'fs.read',
      scope: const StationScope(teamId: 'team-1', modeKey: 'local-typo'),
    );
    expect(badMode.ok, isFalse);
    expect(badMode.error, contains('mode_key'));

    // 执行站不支持订阅
    final StationSubResult sub = h.subscribe(
      execute.id,
      StationSubscriber(pluginId: 'p1', scope: scope),
      ok(),
    );
    expect(sub.ok, isFalse);
    expect(sub.code, 'not_subscribable');
  });

  test('执行站·前端推送点位：ui.push 复用 4.1 的 card 槽位帧（带 team_id，发到广播）', () async {
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
    final StationHub h = hub(frameSink: frames.add);
    final StationScope scope = team('team-1');
    final ExecuteStation execute = h.executePointFor(StationHubIds.executeUi)!;
    final StationCommandResult pushed = await execute.execute(
      command: 'ui.push',
      scope: scope,
      sourcePluginId: 'p1',
      arguments: <String, dynamic>{
        'slot_key': 'demo.plugin.card.1',
        'view': <String, dynamic>{'type': 'text', 'text': '你好'},
      },
    );
    expect(pushed.ok, isTrue);
    expect(frames, hasLength(1));
    expect(frames.single['type'], PluginUiFrameType.update);
    final Map<String, dynamic> data =
        frames.single['data']! as Map<String, dynamic>;
    expect(data['plugin_id'], 'p1');
    expect(data['team_id'], 'team-1');
    expect(data['slot_key'], 'demo.plugin.card.1');
    expect((data['view']! as Map<String, dynamic>)['type'], 'text');

    // 缺 slot_key：可读错误
    final StationCommandResult bad = await execute.execute(
      command: 'ui.push',
      scope: scope,
      arguments: <String, dynamic>{
        'view': <String, dynamic>{'type': 'text'},
      },
    );
    expect(bad.ok, isFalse);
    expect(bad.error, contains('slot_key'));
  });

  test('插件下线：中枢注销其全部订阅并落盘', () async {
    final StationHub h = hub();
    final StationScope scope = team('team-1');
    final BroadcastStation broadcast = h.broadcastFor()!;
    final CollectStation collect = h.toolDefineStationFor()!;
    for (final StationInstance station in <StationInstance>[
      broadcast,
      collect,
    ]) {
      h.subscribe(
        station.id,
        StationSubscriber(pluginId: 'p1', scope: scope),
        ok(),
      );
      h.subscribe(
        station.id,
        StationSubscriber(pluginId: 'p2', scope: scope),
        ok(),
      );
    }
    expect(h.unsubscribePlugin('p1'), 2);
    expect(broadcast.subscribers.single.pluginId, 'p2');
    expect(collect.subscribers.single.pluginId, 'p2');
    expect(h.summary()['subscription_count'], 2);

    final StationHub reloaded = hub();
    reloaded.load();
    expect(reloaded.station(broadcast.id)!.subscribers.single.pluginId, 'p2');
  });

  // ── 站点介绍 / 共享声明 / 面板可改的配置（M9：插件内置站点的三条定稿）──

  test('介绍与共享声明落盘：readme / shared / allowed_plugins / config 跨重启保留；'
      '内置点位的介绍来自点位表', () async {
    final StationHub h = hub();
    expect(
      h.register(
        BroadcastStation(
          id: 'plugin.demo.broadcast.fanout',
          description: '自建广播站',
          readme: '这个站干什么、什么时候被触发、订阅者该怎么回',
          shared: true,
          allowedPlugins: <String>['p2'],
          config: <String, dynamic>{'route': 'team'},
        ),
      ),
      isNull,
    );
    final BroadcastStation station =
        h.station('plugin.demo.broadcast.fanout')! as BroadcastStation;

    // 内置点位：介绍取自点位表（面板上永远有介绍可读，不留空白）
    final BroadcastStation builtin = h.broadcastFor()!;
    expect(
      builtin.readme,
      isNotEmpty,
      reason: '内置点位的介绍在 station_points.dart 里：断言 3 对内置站同样成立',
    );

    // 新中枢读同一个文件（面板与插件跨重启看到的是同一份说明书）
    final StationHub second = hub();
    second.load();
    final BroadcastStation restored =
        second.station(station.id)! as BroadcastStation;
    expect(restored.readme, station.readme);
    expect(restored.shared, isTrue);
    expect(restored.allowedPlugins, <String>['p2']);
    expect(restored.config, <String, dynamic>{'route': 'team'});

    // 一把闸门的五种情形（断言 2：跨插件调用只认显式声明）
    expect(
      restored.callableBy('demo', isOwner: true, isBuiltin: false),
      isTrue,
      reason: '所有者永远能用：门是给别人的，不是防自己的',
    );
    expect(
      restored.callableBy('p2', isOwner: false, isBuiltin: false),
      isTrue,
      reason: '已共享 + 名单里有它 ⇒ 可以订阅也可以被触发',
    );
    expect(
      restored.callableBy('p3', isOwner: false, isBuiltin: false),
      isFalse,
      reason: '名单外一律拒',
    );
    expect(
      restored.callableBy('anyone', isOwner: false, isBuiltin: true),
      isFalse,
      reason: '内置点位对谁都不开触发：它的触发时机由核心在固定接入点决定',
    );
    expect(
      BroadcastStation(
        id: 'plugin.demo.broadcast.private',
        description: '私有站',
        readme: '不外开的站',
      ).callableBy('p2', isOwner: false, isBuiltin: false),
      isFalse,
      reason: '默认不共享：别人的插件连门都摸不到',
    );
  });

  test('updateConfig：面板上能改什么按「内置 / 自建」分开（改完立即生效并落盘）', () async {
    final StationHub h = hub();
    expect(
      h.register(
        BroadcastStation(
          id: 'plugin.demo.broadcast.cfg',
          description: '可配置的站',
          readme: '原始介绍',
        ),
      ),
      isNull,
    );
    final StationInstance station = h.station('plugin.demo.broadcast.cfg')!;
    final StationScope scope = team('team-1');

    // ① 自建站：介绍 / 上限 / 共享 / 白名单 / 自定义配置都能改
    expect(
      h.updateConfig(station.id, <String, dynamic>{
        'readme': '改过的介绍',
        'max_subscriptions': 2,
        'shared': true,
        'allowed_plugins': <String>['p2'],
        'config': <String, dynamic>{'limit': 10},
      }),
      isNull,
    );
    expect(station.readme, '改过的介绍');
    expect(station.maxSubscriptions, 2);
    expect(station.shared, isTrue);
    expect(station.allowedPlugins, <String>['p2']);
    expect(station.config, <String, dynamic>{'limit': 10});

    // ② 上限是**这个实例**的：改完立即影响订阅判定（不需要重启核心）
    expect(
      h
          .subscribe(
            station.id,
            StationSubscriber(pluginId: 'a', scope: scope),
            ok(),
          )
          .ok,
      isTrue,
    );
    final StationSubResult overflow = h.subscribe(
      station.id,
      StationSubscriber(pluginId: 'b', scope: team('team-2')),
      ok(),
    );
    expect(overflow.ok, isTrue, reason: overflow.error);
    expect(
      h
          .subscribe(
            station.id,
            StationSubscriber(pluginId: 'c', scope: team('team-3')),
            ok(),
          )
          .ok,
      isFalse,
      reason: '上限改成 2 之后第三人应该被拒',
    );

    // ③ 非法值显式报错（不静默接受、不假装成功）
    expect(
      h.updateConfig(station.id, <String, dynamic>{'max_subscriptions': 'ten'}),
      contains('整数'),
    );
    expect(
      h.updateConfig(station.id, <String, dynamic>{'shared': 'yes'}),
      contains('布尔'),
    );
    expect(
      h.updateConfig(station.id, <String, dynamic>{
        'config': <String>['a'],
      }),
      contains('映射'),
    );
    expect(
      h.updateConfig('plugin.demo.broadcast.nope', <String, dynamic>{
        'readme': 'x',
      }),
      contains('不存在'),
    );
    // 报错的那些键没被写进去
    expect(station.shared, isTrue);
    expect(station.maxSubscriptions, 2);

    // ④ 内置点位：只有「可订阅插件数量」能改（介绍与配置在点位表里）
    final BroadcastStation builtin = h.broadcastFor()!;
    expect(
      h.updateConfig(builtin.id, <String, dynamic>{'max_subscriptions': 5}),
      isNull,
    );
    expect(builtin.maxSubscriptions, 5);
    final String? forbidden = h.updateConfig(builtin.id, <String, dynamic>{
      'readme': '界面上改内置站的介绍',
    });
    expect(forbidden, isNotNull);
    expect(forbidden, contains('内置站点'));
    expect(
      builtin.readme,
      isNot('界面上改内置站的介绍'),
      reason: '内置点位的介绍以点位表为单一真源，不接受盘上覆写',
    );

    // ⑤ 落盘：新中枢读到改后的值
    final StationHub reloaded = hub();
    reloaded.load();
    final StationInstance again = reloaded.station(station.id)!;
    expect(again.readme, '改过的介绍');
    expect(again.maxSubscriptions, 2);
    expect(again.shared, isTrue);
    expect(again.allowedPlugins, <String>['p2']);
    expect(again.config, <String, dynamic>{'limit': 10});
  });

  test('站点 enabled：停用后四类触发都以可读原因跳过，落盘跨重启保留', () async {
    final StationHub h = hub();
    final StationScope scope = team('team-1');
    final BroadcastStation broadcast = h.broadcastFor()!;
    final RelayStation relay = h.relayPointFor(StationHubIds.relayToolPre)!;
    final CollectStation collect = h.toolDefineStationFor()!;
    final ExecuteStation execute = h.executePointFor(StationHubIds.executeFs)!;

    // 默认启用（缺键 = 启用），describe 带着它给面板
    expect(broadcast.enabled, isTrue);
    expect(broadcast.describe()['enabled'], isTrue);
    expect(broadcast.stationDisabledReason, isNull);

    // 内置站也能切（面板写面四格的第 ② 格）；非法值显式报错
    expect(
      h.updateConfig(execute.id, <String, dynamic>{'enabled': false}),
      isNull,
    );
    expect(execute.enabled, isFalse);
    expect(execute.describe()['enabled'], isFalse);
    expect(execute.stationDisabledReason, contains('已停用'));
    expect(
      h.updateConfig(broadcast.id, <String, dynamic>{'enabled': 'yes'}),
      contains('布尔'),
    );
    expect(
      broadcast.enabled,
      isTrue,
      reason: '报错的键没被写进去（先校验后落）',
    );
    final String? forbidden = h.updateConfig(execute.id, <String, dynamic>{
      'shared': true,
    });
    expect(forbidden, contains('启用 / 停用'), reason: '内置站文案要指路可改的两格');

    // ① 执行站：第一道闸就地拒绝
    final StationCommandResult cmd = await execute.execute(
      command: 'fs.read',
      scope: scope,
    );
    expect(cmd.ok, isFalse);
    expect(cmd.error, contains('已停用'));
    expect(execute.counters['skipped_disabled'], 1);

    // ② 广播站：可读原因 + 不入板
    expect(
      h.updateConfig(broadcast.id, <String, dynamic>{'enabled': false}),
      isNull,
    );
    final StationPublishResult pub = await broadcast.publish(
      topic: 'off',
      scope: scope,
      payload: <String, dynamic>{'x': 1},
    );
    expect(pub.boardSeq, 0, reason: '停用的站不入公告板');
    expect(pub.delivered, 0);
    expect(pub.skipped.single, contains('已停用'));
    expect(broadcast.counters['skipped_disabled'], 1);

    // ③ 中转站：照旧放行原数据（fail-open 红线不因停用破例）
    expect(
      h.updateConfig(relay.id, <String, dynamic>{'enabled': false}),
      isNull,
    );
    h.subscribe(
      relay.id,
      StationSubscriber(pluginId: 'p1', scope: scope),
      ok(),
    );
    final StationRelayResult rr = await relay.relay(
      data: '原数据',
      scope: scope,
    );
    expect(rr.handled, isFalse);
    expect(rr.data, '原数据', reason: '停用只是不接管，原数据照旧放行');
    expect(rr.reason, contains('已停用'));
    expect(rr.reason, contains('原数据放行'));

    // ④ 收集站：可读原因 + 无产出
    expect(
      h.updateConfig(collect.id, <String, dynamic>{'enabled': false}),
      isNull,
    );
    final StationCollectResult cr = await collect.collect(scope: scope);
    expect(cr.items, isEmpty);
    expect(cr.skipped.single, contains('已停用'));

    // 管理面不受影响：停用期间照样能改配置、照样能订阅（禁用 ≠ 退订）
    expect(
      h.updateConfig(collect.id, <String, dynamic>{'max_subscriptions': 7}),
      isNull,
    );
    expect(collect.maxSubscriptions, 7);
    expect(
      h
          .subscribe(
            broadcast.id,
            StationSubscriber(pluginId: 'p2', scope: scope),
            ok(),
          )
          .ok,
      isTrue,
      reason: '停用不退订：订阅关系与管理面原样保留',
    );

    // 落盘跨重启
    final StationHub reloaded = hub();
    reloaded.load();
    expect(reloaded.station(broadcast.id)!.enabled, isFalse);
    expect(reloaded.station(execute.id)!.enabled, isFalse);

    // 重新启用后原样继续
    expect(
      h.updateConfig(broadcast.id, <String, dynamic>{'enabled': true}),
      isNull,
    );
    final StationPublishResult back = await broadcast.publish(
      topic: 'on',
      scope: scope,
    );
    expect(back.boardSeq, 1, reason: '重新启用后公告板继续');
    expect(back.delivered, 1, reason: '停用期间保留的订阅者原样收到');
  });

  test('订阅者的禁用标记落盘：重启后仍是关着的（不会被重新订阅悄悄打开）', () async {
    final StationHub h = hub();
    expect(
      h.register(
        BroadcastStation(
          id: 'plugin.demo.broadcast.switch',
          description: '带开关的站',
          readme: '订阅者可被所有者关掉',
          shared: true,
        ),
      ),
      isNull,
    );
    final StationInstance station = h.station('plugin.demo.broadcast.switch')!;
    final StationScope scope = team('team-1');
    h.subscribe(
      station.id,
      StationSubscriber(pluginId: 'p1', scope: scope),
      ok(),
    );
    final String key = station.subscribers.single.key;

    expect(h.setSubscriberDisabled(station.id, key, true), isNull);
    expect(station.subscribers.single.disabled, isTrue);
    // 快照里看得见（面板的「已订阅插件管理」读它渲染开关）
    expect(
      (station.describe()['subscriptions'] as List).single
          as Map<String, dynamic>,
      containsPair('disabled', isTrue),
    );

    final StationHub reloaded = hub();
    reloaded.load();
    expect(
      reloaded.station(station.id)!.subscribers.single.disabled,
      isTrue,
      reason: '禁用关系跨重启保留：插件重新上线也不会把用户关掉的东西悄悄打开',
    );
    // 未知订阅键 ⇒ 可读错误
    expect(
      reloaded.setSubscriberDisabled(station.id, 'ghost|team-1', true),
      contains('不存在'),
    );
    expect(
      reloaded.setSubscriberDisabled('plugin.demo.broadcast.nope', key, true),
      contains('不存在'),
    );
  });
}
