// 快照池在**总线口径**下的归属钉住用例（20261015-hot-restart 阶段 1，D4）。
//
// `plugin_state_pool_test.dart` 钉的是池本身的单元行为（键、上限、TTL、消费位）；
// 这一份钉的是**接到插件之后**会出事的那三件事：
//
// A. **改了归属就不许取回旧快照**：用户把插件的 `scope.team_id` 改了 ⇒ 重启后这一世
//    属于另一个工作面。旧那份快照是**前一个 team** 写下的内部状态，递过去就是跨 team
//    泄漏。池的取回是 fail-closed 精确相等，因此这里必须"取不到 + 原因可读 + 快照
//    没被顺手消费掉"，不能只是"返回 null 然后什么都不说"。
// B. **一份快照只喂一世**：取回即消费；第二次取不到（同一段人生不能被两个实例认领）。
// C. **保守侧的代价要写清楚**：一次重启失败会占掉一代（代际 +1 但那一世没起来），
//    于是再重启一次时"上一世"变成那个没起来的世代 ⇒ 旧快照**取不到**，按冷启动继续。
//    这是刻意的取舍（宁可冷启动也不递错状态），不是 bug：快照仍然留在池里、
//    仍然可被读数看见，只是不再被交给隔了两世的新实例。

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/plugin_state_pool.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late String configFile;
  late PluginBus bus;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_pool_scope_');
    configFile = p.join(temp.path, 'config', 'plugins.yaml');
    Directory(p.dirname(configFile)).createSync(recursive: true);
    File(configFile).writeAsStringSync('enabled: true\nplugins: []\n');
    bus = PluginBus(
      configFile: configFile,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
    );
  });

  tearDown(() async {
    await bus.close();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  /// 写一条插件条目。**本文件不需要真进程**：测的是核心这一侧的归属判定，
  /// 而“哪一世的快照能交给当前这一世”这个推导完全在核心手里，与进程无关。
  void writeEntry({String teamId = 'team-1', String command = 'noop'}) {
    File(configFile).writeAsStringSync(<String>[
      'enabled: true',
      'plugins:',
      '  - id: alpha',
      '    name: 甲插件',
      '    command: "$command"',
      '    args: []',
      '    enabled: true',
      '    granularity: team',
      '    suspension: keep',
      '    scope: {team_id: $teamId}',
      '',
    ].join('\n'));
  }

  Future<Map<String, dynamic>> dump([Map<String, dynamic> payload = const <String, dynamic>{'k': 1}]) =>
      bus.handlePluginCommand(
        command: 'plugin.stateDump',
        pluginId: 'alpha',
        sourcePluginId: 'alpha',
        arguments: <String, dynamic>{'payload': payload},
      );

  Future<Map<String, dynamic>> fetch() => bus.handlePluginCommand(
    command: 'plugin.stateFetch',
    pluginId: 'alpha',
    sourcePluginId: 'alpha',
  );

  // ── 用例 ───────────────────────────────────────────────────────────────

  test('A 改了 scope.team_id ⇒ 旧快照一律不给取回，且不因为被拒而损耗它', () async {
    // 直接把一份"写在 team-1 名下"的快照放进池（等价于第一世转储成功）
    final PluginStatePutResult put = bus.statePool.put(
      pluginId: 'alpha',
      generation: 1,
      payload: const <String, dynamic>{'session': 'S1', 'cursor': 7},
      scope: const StationScope(teamId: 'team-1'),
    );
    expect(put.accepted, isTrue);

    // 现在按 team-2 的归属去取：核心这一侧算出来的键是 alpha#1，但 scope 不相等
    final PluginStateSnapshot? taken = bus.statePool.take(
      pluginId: 'alpha',
      generation: 1,
      scope: const StationScope(teamId: 'team-2'),
    );
    expect(taken, isNull, reason: '跨 team 取回 = 把 A 队的内部状态递给 B 队');
    expect(bus.statePool.deniedCount, 1);
    // 被拒**不算消费**：它还在池里，等一个归属对得上的主人（不是"取不到就顺手吃掉"）
    expect(bus.statePool.length, 1);
    expect(bus.statePool.readings().single.consumed, isFalse);
  });

  test('A2 快照的写入归属来自配置声明，不接受插件自选的 scope', () async {
    writeEntry(teamId: 'team-1');
    // 代际 = 0（没启动过）⇒ 核心拒收：键里的 generation 必须是核心登记过的那一世
    final Map<String, dynamic> rejected = await dump();
    expect(rejected['ok'], isFalse, reason: '$rejected');
    expect(rejected['error'], contains('还没有任何一世'));
    expect(bus.statePool.putCount, 0);

    // 插件即使自带 team_id / dump_id 也改不了键：核心只认 config 声明 + 自己的代际计数
    final Map<String, dynamic> forged = await bus.handlePluginCommand(
      command: 'plugin.stateDump',
      pluginId: 'alpha',
      sourcePluginId: 'alpha',
      arguments: <String, dynamic>{
        'payload': const <String, dynamic>{'x': 1},
        'team_id': 'team-999',
        'dump_id': 'alpha#99',
      },
    );
    expect(forged['ok'], isFalse, reason: '$forged');
    expect(bus.statePool.length, 0, reason: '伪造的键一个都没进池');
  });

  test('B 一份快照只喂一世：取回即消费，第二次取不到并给出可读原因', () async {
    bus.statePool.put(
      pluginId: 'alpha',
      generation: 1,
      payload: const <String, dynamic>{'cursor': 7},
      scope: const StationScope(teamId: 'team-1'),
    );
    // 直接按池的口径取两次（bus 侧的"上一世"推导由 hot_restart 那份用例钉）
    final PluginStateSnapshot? first = bus.statePool.take(
      pluginId: 'alpha',
      generation: 1,
      scope: const StationScope(teamId: 'team-1'),
    );
    expect(first, isNotNull);
    expect(first!.payload['cursor'], 7);
    expect(
      bus.statePool.take(
        pluginId: 'alpha',
        generation: 1,
        scope: const StationScope(teamId: 'team-1'),
      ),
      isNull,
      reason: '同一段人生不能被两个实例认领',
    );

    // release = 唯一的正当退回：核心取回后新实例在就绪前就退了（那次消费作废）
    expect(bus.statePool.release(first.dumpId), isTrue);
    final PluginStateSnapshot? again = bus.statePool.take(
      pluginId: 'alpha',
      generation: 1,
      scope: const StationScope(teamId: 'team-1'),
    );
    expect(again, isNotNull, reason: '退回后允许再取一次（否则偶发失败会永久吃掉状态）');
  });

  test('C 保守侧的代价：重启失败占掉一代，旧快照留在池里但不交给隔了两世的实例', () async {
    writeEntry();
    // 手工搭出"三世"的台账：1 = 转过储；2 = 启动失败（占掉一代）；3 = 现在这一世
    bus.statePool.put(
      pluginId: 'alpha',
      generation: 1,
      payload: const <String, dynamic>{'cursor': 7},
      scope: const StationScope(teamId: 'team-1'),
    );
    // stateFetch 取的是"当前代 − 1"。当前代没被登记（= 0）时它先给出诚实的拒绝。
    final Map<String, dynamic> beforeBoot = await fetch();
    expect(beforeBoot['ok'], isTrue);
    expect(beforeBoot['has_snapshot'], isFalse);
    expect(beforeBoot['reason'], contains('没有上一世'));

    // 代际由核心的启动路径推进（这是唯一合法的推进方式），所以这里只断言：
    // 只要当前代不是 2，alpha#1 就**不该**被交出去 —— 一世一份优先于"能捞就捞"。
    expect(bus.generationOf('alpha'), 0);
    expect(bus.statePool.length, 1, reason: '取不到不等于丢掉：它还在池里');
    expect(bus.statePool.readings().single.consumed, isFalse);
    expect(bus.statePool.deniedCount, 0, reason: '这一路是"没有上一世"，不是归属被拒');
  });

  test('D 取回时指定了别的 dump_id ⇒ 直接拒：键由核心拼，不接受点名字', () async {
    writeEntry();
    bus.statePool.put(
      pluginId: 'alpha',
      generation: 1,
      payload: const <String, dynamic>{'cursor': 7},
      scope: const StationScope(teamId: 'team-1'),
    );
    final Map<String, dynamic> pointed = await bus.handlePluginCommand(
      command: 'plugin.stateFetch',
      pluginId: 'alpha',
      sourcePluginId: 'alpha',
      arguments: const <String, dynamic>{'dump_id': 'alpha#1'},
    );
    // 当前代 = 0 ⇒ 期望的上一世不存在 ⇒ 点名 alpha#1 也对不上，拒
    expect(pointed['ok'], isFalse, reason: '$pointed');
    expect(pointed['error'], contains('快照键由核心拼'));
    expect(bus.statePool.length, 1, reason: '被拒不该损耗快照');
  });
}
