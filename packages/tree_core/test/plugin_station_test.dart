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

  test('中转站：**全站唯一订阅者**（先到先得 + 显式 replace），且 fail-open 放行原数据', () async {
    final StationHub h = hub();
    final StationScope scope = team('team-1');
    final RelayStation relay = h.relayFor()!;
    expect(relay.scopeKeyUnique, isTrue);

    final StationSubResult first = h.subscribe(
      relay.id,
      StationSubscriber(pluginId: 'p1', scope: scope),
      (StationRequest request) async =>
          StationReply.ok('p1 改写：${request.payload}'),
    );
    expect(first.ok, isTrue);
    // **另一个 team 也不能再订**（旧口径是"站 × scope 键位唯一"，那会按 team 各放一个；
    // 新口径是"一个拦截点一个处理者"——要分流由转发型订阅者自己分发）。
    final StationSubResult second = h.subscribe(
      relay.id,
      StationSubscriber(pluginId: 'p2', scope: team('team-2')),
      (StationRequest request) async => const StationReply.ok('p2 改写'),
    );
    expect(second.ok, isFalse, reason: '中转站只允许一个订阅者（与 scope 无关）');
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
    final RelayStation empty = other.relayFor()!;
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

  test('执行站：白名单 + 隔离 + 挂载位置；不订阅、不触发插件', () async {
    final StationHub h = hub();
    final StationScope scope = team('team-1');
    final ExecuteStation execute = h.executeFor()!;
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

    // 白名单外：挂载被拒 + 执行被拒
    expect(
      execute.mount(
        command: 'shell.rm',
        mountId: 'x',
        handler: (StationCommandContext context) async =>
            const StationCommandOutcome.ok(),
      ),
      contains('首命令集'),
    );
    final StationCommandResult denied = await execute.execute(
      command: 'shell.rm',
      scope: scope,
    );
    expect(denied.ok, isFalse);
    expect(denied.error, contains('首命令集'));

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

    // 消息信封本身不完整（缺 team）⇒ 站点层启动就拒（fail-closed）
    final StationCommandResult noTeam = await execute.execute(
      command: 'fs.read',
      scope: const StationScope(modeKey: StationModeKey.local),
    );
    expect(noTeam.ok, isFalse);
    expect(noTeam.error, contains('team_id'));

    // 执行站不支持订阅
    final StationSubResult sub = h.subscribe(
      execute.id,
      StationSubscriber(pluginId: 'p1', scope: scope),
      ok(),
    );
    expect(sub.ok, isFalse);
    expect(sub.code, 'not_subscribable');
  });

  test('执行站：ui.push 复用 4.1 的 card 槽位帧（带 team_id，发到广播）', () async {
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
    final StationHub h = hub(frameSink: frames.add);
    final StationScope scope = team('team-1');
    final ExecuteStation execute = h.executeFor()!;
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
}
