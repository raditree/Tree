// **重启期保活的有界暂存队列**（20261015-hot-restart 阶段 2）。
//
// 这一份只管一件事：**队列本身必须是有界的，而且每一次"没接住"都留下了可读痕迹**。
// 为什么单独钉它（而不只在端到端用例里顺带覆盖）：溢出的正常路径是"放行原数据"，
// 也就是说**它不报错**。一个把上限写错、把丢弃写静的实现，在端到端里看起来一切正常，
// 只有数数才能揭穿——所以这里逐个数。
//
// 钉住的九件事：
// 1. 默认上限是保守值（每插件 32 条 / 全局 1 MiB），且可由构造参数收窄；
// 2. 条数溢出 ⇒ **立即**回 failed（不排队、不无界堆积），原因里写清"按 fail-open 放行"；
// 3. 字节溢出同理，且原因带上实际字节与上限（"差多少"必须能查）；
// 4. 重放按 **FIFO**，且用的是**新一世的投递闭包**（旧闭包握着已退的宿主）；
// 5. `stillValid` 逐条复查：被丢的那条不投递、不计数，**后面的照常按序投**；
// 6. `abandon` / `abandonAll` 以可读原因结账，返回条数，且**绝不双结**（幂等）；
// 7. 字节估算是 fail-open：payload 里塞一个 jsonEncode 会炸的对象也不许把投递路径炸掉；
// 8. `readings()` 的水位与实际一致（面板与用例都读它，不留第二份台账）；
// 9. 收尾靠**事件**而不是时长：整个文件里没有一处 `timeout(`。
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_core/src/plugin/plugin_restart_buffer.dart';
import 'package:tree_core/src/plugin/station_runtime.dart';
import 'package:tree_core/src/plugin/station_schema.dart';
import 'package:tree_core/src/plugin/station_scope.dart';

void main() {
  StationRequest request(
    String id, {
    String stationId = 'system.relay.tool.pre',
    Object? payload,
    String teamId = 'team-1',
  }) => StationRequest(
    requestId: id,
    stationId: stationId,
    kind: StationKind.relay,
    scope: StationScope(teamId: teamId, modeKey: StationModeKey.local),
    payload: payload ?? <String, dynamic>{'call_id': id, 'text': 'x' * 32},
  );

  Future<StationReply> delivered(StationRequest r) async =>
      StationReply.ok(<String, dynamic>{'got': r.requestId});

  group('PluginRestartBuffer：有界、可计数、不静默', () {
    test('默认上限是保守值，且构造参数可以收窄', () {
      final PluginRestartBuffer defaults = PluginRestartBuffer();
      expect(defaults.maxPerPlugin, 32);
      expect(defaults.maxTotalBytes, 1 << 20);

      final PluginRestartBuffer small = PluginRestartBuffer(
        maxPerPlugin: 2,
        maxTotalBytes: 128,
      );
      expect(small.maxPerPlugin, 2);
      expect(small.maxTotalBytes, 128);
    });

    test('条数溢出：第 3 条立即 failed，队列不无限长，原因可读', () async {
      final List<String> logs = <String>[];
      final PluginRestartBuffer buffer = PluginRestartBuffer(
        maxPerPlugin: 2,
        log: logs.add,
      );

      final Future<StationReply> first = buffer.push(
        'p',
        request('a'),
        delivered,
      );
      final Future<StationReply> second = buffer.push(
        'p',
        request('b'),
        delivered,
      );
      expect(buffer.lengthOf('p'), 2);

      final StationReply third = await buffer.push(
        'p',
        request('c'),
        delivered,
      );
      expect(third.isFailed, isTrue, reason: '溢出必须当场失败，不许悄悄排队');
      expect(third.error, contains('暂存队列已满'));
      expect(third.error, contains('fail-open'));
      expect(third.error, contains('system.relay.tool.pre'));
      // **不无界堆积**：溢出那条没进队列
      expect(buffer.lengthOf('p'), 2);
      expect(buffer.queuedCount, 2);
      expect(buffer.overflowCount, 1);
      expect(buffer.droppedCount, 1, reason: '溢出也是丢掉一条，计数不能只加溢出');
      expect(
        logs.any((String l) => l.contains('暂存队列已满')),
        isTrue,
        reason: '溢出必须写日志（不变量 6：不静默）',
      );

      // 前两条照常还活着（溢出不能把在队的挤掉）
      await buffer.replay('p', deliver: delivered);
      expect(await first, isA<StationReply>());
      expect((await second).payload, isNotNull);
      expect(buffer.replayedCount, 2);
      expect(buffer.isEmpty, isTrue);
    });

    test('字节溢出：原因带上实际字节与上限（差多少必须能查）', () async {
      final PluginRestartBuffer buffer = PluginRestartBuffer(
        maxTotalBytes: 300,
      );
      // 先用一条小的占住额度（不猜长度：拿核心自己算出的那个数做断言）
      buffer.push('p', request('a'), delivered);
      final int used = buffer.totalBytes;
      expect(used, greaterThan(0), reason: '第一条真的占了额度');
      expect(buffer.lengthOf('p'), 1);

      // 再来一条“把余额用完还不够”的（blob 长到超过整个上限）
      final StationReply over = await buffer.push(
        'p',
        request('b', payload: <String, dynamic>{'blob': 'z' * 400}),
        delivered,
      );
      expect(over.isFailed, isTrue);
      expect(over.error, contains('超出上限 300 字节'));
      expect(over.error, contains('$used +'), reason: '原因里要能看见已经占了多少');
      expect(buffer.lengthOf('p'), 1, reason: '溢出那条不得进队（不无界堆积）');
      expect(buffer.overflowCount, 1);
      expect(buffer.droppedCount, 1);

      final List<String> sent = <String>[];
      await buffer.replay(
        'p',
        deliver: (StationRequest r) async {
          sent.add(r.requestId);
          return delivered(r);
        },
      );
      expect(sent, <String>['a'], reason: '在队的那条照常重放，溢出不能挤掉它');
    });

    test('字节估算是 fail-open：jsonEncode 编不出也不许炸掉投递路径', () async {
      final PluginRestartBuffer buffer = PluginRestartBuffer(maxTotalBytes: 1);
      final Map<String, dynamic> cyclic = <String, dynamic>{'k': 1};
      cyclic['self'] = cyclic;
      final Future<StationReply> odd = buffer.push(
        'p',
        request('a', payload: cyclic),
        delivered,
      );
      // 估不出来 ⇒ 按 0 计（超上限也不拒）：遥测算不出来不该把真请求挡在门外
      expect(buffer.lengthOf('p'), 1);
      expect(buffer.totalBytes, 0);
      await buffer.replay('p', deliver: delivered);
      expect((await odd).payload, isNotNull);
      expect(buffer.overflowCount, 0, reason: '它不是溢出，是“估不出”');
    });

    test('重放按 FIFO，且用的是新一世的投递闭包', () async {
      final PluginRestartBuffer buffer = PluginRestartBuffer();
      final List<String> oldCalls = <String>[];
      final List<String> newCalls = <String>[];

      // 入队时握着的闭包指向"上一世"：重放**不许**再碰它
      final List<Future<StationReply>> futures = <Future<StationReply>>[
        buffer.push('p', request('a'), (StationRequest r) async {
          oldCalls.add(r.requestId);
          return StationReply.failed('旧宿主已经被退掉了');
        }),
        buffer.push('p', request('b'), (StationRequest r) async {
          oldCalls.add(r.requestId);
          return StationReply.failed('旧宿主已经被退掉了');
        }),
      ];
      expect(buffer.readings()['queued'], 2);

      await buffer.replay(
        'p',
        deliver: (StationRequest r) async {
          newCalls.add(r.requestId);
          return StationReply.ok(<String, dynamic>{
            'era': 2,
            'id': r.requestId,
          });
        },
      );
      expect(newCalls, <String>['a', 'b'], reason: '顺序就是入队顺序（不得重排）');
      expect(oldCalls, isEmpty, reason: '重放必须走新闭包，不能再递旧宿主');
      expect(buffer.replayedCount, 2);
      expect(buffer.isEmpty, isTrue);
      for (final Future<StationReply> f in futures) {
        expect((await f).payload, isNotNull, reason: '两条都真的把结果给了调用方');
      }
    });

    test('stillValid 复查：无效的那条被丢且不影响后面的顺序', () async {
      final List<String> logs = <String>[];
      final PluginRestartBuffer buffer = PluginRestartBuffer(log: logs.add);
      final List<Future<StationReply>> futures = <Future<StationReply>>[
        buffer.push('p', request('a'), delivered),
        buffer.push('p', request('b'), delivered),
        buffer.push('p', request('c'), delivered),
      ];

      final List<String> sent = <String>[];
      await buffer.replay(
        'p',
        deliver: (StationRequest r) async {
          sent.add(r.requestId);
          return delivered(r);
        },
        stillValid: (QueuedStationRequest item) =>
            item.request.requestId != 'b',
        invalidReason: '这条在重启窗口里已经失效（测试指定）',
      );
      expect(sent, <String>['a', 'c'], reason: '丢掉一条不能打乱其余的顺序');
      expect(buffer.replayedCount, 2, reason: '被丢的那条不算重放成功');
      expect(buffer.droppedCount, 1);
      expect(buffer.isEmpty, isTrue);
      expect((await futures[1]).error, contains('已经失效'));
      expect((await futures[0]).payload, isNotNull);
    });

    test('abandon：以可读原因结账并返回条数；重复收尾不双结', () async {
      final PluginRestartBuffer buffer = PluginRestartBuffer();
      final Future<StationReply> a = buffer.push('p1', request('a'), delivered);
      final Future<StationReply> b = buffer.push('p2', request('b'), delivered);
      expect(buffer.readings()['per_plugin'], <String, int>{'p1': 1, 'p2': 1});

      expect(buffer.abandon('p1', '插件 p1 本轮启动失败 ⇒ 不再等待'), 1);
      // 再收一次必须是 0（幂等：不允许把已经结账的再结一遍）
      expect(buffer.abandon('p1', '第二次收尾'), 0);
      expect((await a).error, contains('插件 p1 本轮启动失败 ⇒ 不再等待'));
      expect(buffer.totalBytes, greaterThan(0), reason: 'p2 还在队里');

      expect(buffer.abandonAll('核心已退出'), 1);
      expect((await b).error, contains('核心已退出'));
      expect(buffer.isEmpty, isTrue);
      expect(buffer.totalBytes, 0);
      expect(buffer.droppedCount, 2);
      expect(buffer.replayedCount, 0, reason: '丢掉的不算重放');
    });

    test('水位读数与实际一致（面板与用例共用这一份台账）', () async {
      final PluginRestartBuffer buffer = PluginRestartBuffer(
        maxPerPlugin: 5,
        maxTotalBytes: 4096,
      );
      expect(buffer.readings(), <String, dynamic>{
        'queued': 0,
        'bytes': 0,
        'max_per_plugin': 5,
        'max_total_bytes': 4096,
        'per_plugin': <String, int>{},
        'replayed': 0,
        'dropped': 0,
        'overflowed': 0,
      });

      final List<Future<StationReply>> two = <Future<StationReply>>[
        buffer.push('p', request('a'), delivered),
        buffer.push('p', request('b'), delivered),
      ];
      expect(buffer.lengthOf('p'), 2, reason: '入队是**同步**发生的（不等重放）');
      final Map<String, dynamic> mid = buffer.readings();
      expect(mid['queued'], 2);
      expect(mid['per_plugin'], <String, int>{'p': 2});
      // 字节数是**估算**：它必须等于两条 jsonEncode 长度之和（不留第二本账）
      expect(
        mid['bytes'],
        jsonEncode(request('a').toJson()).length +
            jsonEncode(request('b').toJson()).length,
      );

      await buffer.replay('p', deliver: delivered);
      final Map<String, dynamic> after = buffer.readings();
      expect(after['queued'], 0);
      expect(after['bytes'], 0);
      expect(after['replayed'], 2);
      expect((await two.first).payload, isNotNull);
      expect((await two.last).payload, isNotNull);
    });

    test('重放途中投递抛异常：以可读失败收尾，不把整条链炸掉', () async {
      final PluginRestartBuffer buffer = PluginRestartBuffer();
      final Future<StationReply> boom = buffer.push(
        'p',
        request('a'),
        delivered,
      );
      await buffer.replay(
        'p',
        deliver: (StationRequest r) async => throw StateError('宿主写不去了'),
      );
      expect((await boom).error, contains('重启后重放失败'));
      expect((await boom).error, contains('宿主写不去了'));
      expect(buffer.isEmpty, isTrue);
    });
  });
}
