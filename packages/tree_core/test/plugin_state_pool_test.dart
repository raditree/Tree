// 插件状态内存池（plugin_state_pool.dart）的用例（20261015-hot-restart 阶段 1，D4）。
//
// 锁住的六件事：
// 1. **不落盘**：整个文件不出现任何 IO —— 用"池里没有文件路径可给"这一点从正面钉住
//    （断言读数只有内存字段，且 clear/discard 之后不留任何东西）；
// 2. **一世一份**：同一 `(pluginId, generation)` 重复放入 = 覆盖，取回即消费，
//    第二次取必须拿不到（否则两个实例认领同一段人生）；
// 3. **代际隔离**：上一世的快照不能被下一世取走；
// 4. **归属 fail-closed**：scope 不精确相等 ⇒ 拒绝（防"重启后取回别人的快照"）；
// 5. **上限是真拒**：单条过大 = 整条拒收且**不截断**；条数/总字节超限按 LRU 丢最旧，
//    且刚放入的那条不会被顺手丢掉；
// 6. **TTL 到期 = 按冷启动继续**，并留下可读原因（不变量 10：坏了会怎样要看得见）。
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/plugin_state_pool.dart';
import 'package:tree_core/src/plugin/station_scope.dart';

const StationScope _scopeA = StationScope(
  teamId: 't1',
  agentId: 'a1',
  sessionId: 's1',
  modeKey: 'local',
);

void main() {
  test('放入即可取回，且取回即消费：第二次取为空并留原因', () {
    final List<String> logs = <String>[];
    final PluginStatePool pool = PluginStatePool(log: logs.add);

    final PluginStatePutResult put = pool.put(
      pluginId: 'demo',
      generation: 1,
      payload: <String, dynamic>{'counter': 7},
      scope: _scopeA,
    );
    expect(put.accepted, isTrue, reason: put.error);
    expect(put.dumpId, isNotNull);
    expect(pool.putCount, 1);

    final PluginStateSnapshot? first = pool.take(
      pluginId: 'demo',
      generation: 1,
      scope: _scopeA,
    );
    expect(first, isNotNull);
    expect(first!.payload['counter'], 7);
    expect(first.consumed, isTrue, reason: '取回即消费：一份快照只喂一世');

    expect(
      pool.take(pluginId: 'demo', generation: 1, scope: _scopeA),
      isNull,
      reason: '同一份快照不能被取两次',
    );
    expect(
      logs.any((String line) => line.contains('已被取走')),
      isTrue,
      reason: '取不到必须留下可读原因，不能静默返回 null',
    );
  });

  test('consume=false 只读不消费；release 允许取回后再取一次', () {
    final PluginStatePool pool = PluginStatePool();
    final PluginStatePutResult put = pool.put(
      pluginId: 'demo',
      generation: 1,
      payload: <String, dynamic>{'k': 1},
      scope: _scopeA,
    );
    // 只读探测（面板/诊断）：不该把用户显式声明要保的状态吃掉。
    expect(
      pool.take(
        pluginId: 'demo',
        generation: 1,
        scope: _scopeA,
        consume: false,
      ),
      isNotNull,
    );
    expect(pool.length, 1, reason: '只读不改消费位');
    expect(
      pool.take(pluginId: 'demo', generation: 1, scope: _scopeA),
      isNotNull,
    );
    expect(pool.take(pluginId: 'demo', generation: 1, scope: _scopeA), isNull);
    // 新实例在真正就绪前退了 ⇒ 那次消费作废，退回可取。
    expect(pool.release(put.dumpId!), isTrue);
    expect(
      pool.take(pluginId: 'demo', generation: 1, scope: _scopeA),
      isNotNull,
      reason: 'release 之后必须能再取一次，否则偶发启动失败会永久吞掉在途状态',
    );
  });

  test('代际隔离：第 1 世的快照不会被第 2 世取走', () {
    final PluginStatePool pool = PluginStatePool();
    pool.put(
      pluginId: 'demo',
      generation: 1,
      payload: <String, dynamic>{'from': 1},
      scope: _scopeA,
    );
    expect(
      pool.take(pluginId: 'demo', generation: 2, scope: _scopeA),
      isNull,
      reason: '只用 pluginId 索引会让"重启失败的上一世"被"下一世"认领',
    );
    pool.put(
      pluginId: 'demo',
      generation: 2,
      payload: <String, dynamic>{'from': 2},
      scope: _scopeA,
    );
    final PluginStateSnapshot? mine = pool.take(
      pluginId: 'demo',
      generation: 2,
      scope: _scopeA,
    );
    expect(mine, isNotNull);
    expect(mine!.payload['from'], 2);
  });

  test('归属 fail-closed：scope 差一维就取不到，且计数记下来', () {
    final List<String> logs = <String>[];
    final PluginStatePool pool = PluginStatePool(log: logs.add);
    pool.put(
      pluginId: 'demo',
      generation: 1,
      payload: <String, dynamic>{'secret': 'x'},
      scope: _scopeA,
    );
    expect(pool.deniedCount, 0);
    expect(
      pool.take(
        pluginId: 'demo',
        generation: 1,
        scope: const StationScope(
          teamId: 't2',
          agentId: 'a1',
          sessionId: 's1',
          modeKey: 'local',
        ),
      ),
      isNull,
      reason: '换 team 就取走 = 把 A 团队的插件内部状态递给 B 团队',
    );
    expect(pool.deniedCount, 1);
    expect(logs.any((String line) => line.contains('归属不符')), isTrue);
    // 通配请求（空 scope）同样不行：归属校验不做"放宽匹配"。
    expect(
      pool.take(pluginId: 'demo', generation: 1, scope: const StationScope()),
      isNull,
    );
  });

  test('同代际重复放入 = 覆盖，不留两份可续跑状态', () {
    final PluginStatePool pool = PluginStatePool();
    pool.put(
      pluginId: 'demo',
      generation: 3,
      payload: <String, dynamic>{'v': 'old'},
      scope: _scopeA,
    );
    pool.put(
      pluginId: 'demo',
      generation: 3,
      payload: <String, dynamic>{'v': 'new'},
      scope: _scopeA,
    );
    final PluginStateSnapshot? got = pool.take(
      pluginId: 'demo',
      generation: 3,
      scope: _scopeA,
    );
    expect(got, isNotNull);
    expect(got!.payload['v'], 'new', reason: '同一代际只应有一份算数');
    expect(pool.length, 0);
  });

  test('单条过大 = 整条拒收且**不截断**，原因可读', () {
    final List<String> logs = <String>[];
    final PluginStatePool pool = PluginStatePool(
      maxEntryBytes: 64,
      log: logs.add,
    );
    final PluginStatePutResult put = pool.put(
      pluginId: 'demo',
      generation: 1,
      payload: <String, dynamic>{'blob': 'x' * 200},
      scope: _scopeA,
    );
    expect(put.accepted, isFalse);
    expect(put.dumpId, isNull);
    expect(
      put.error,
      contains('不截断'),
      reason: '半截状态被插件当完整状态恢复，比直接失败更糟',
    );
    expect(pool.rejectedCount, 1);
    expect(pool.length, 0);
    expect(logs, isNotEmpty);
  });

  test('非 JSON 载荷 = 拒收并给原因（跨进程边界不接受进程内引用）', () {
    final PluginStatePool pool = PluginStatePool();
    final PluginStatePutResult put = pool.put(
      pluginId: 'demo',
      generation: 1,
      // 循环引用：jsonEncode 会抛
      payload: <String, dynamic>{'self': <String, dynamic>{}},
      scope: _scopeA,
    );
    expect(put.accepted, isTrue, reason: '正常嵌套 Map 该收：${put.error}');

    final Map<String, dynamic> cyclic = <String, dynamic>{};
    cyclic['self'] = cyclic;
    final PluginStatePutResult denied = pool.put(
      pluginId: 'demo',
      generation: 2,
      payload: cyclic,
      scope: _scopeA,
    );
    expect(denied.accepted, isFalse);
    expect(denied.error, contains('不是合法 JSON'));
  });

  test('条目上限触发 LRU：丢最旧，绝不丢刚放入的那条', () {
    final PluginStatePool pool = PluginStatePool(maxEntries: 2);
    pool.put(
      pluginId: 'p1',
      generation: 1,
      payload: <String, dynamic>{'v': 1},
      scope: _scopeA,
    );
    pool.put(
      pluginId: 'p2',
      generation: 1,
      payload: <String, dynamic>{'v': 2},
      scope: _scopeA,
    );
    pool.put(
      pluginId: 'p3',
      generation: 1,
      payload: <String, dynamic>{'v': 3},
      scope: _scopeA,
    );
    expect(pool.length, 2, reason: '超出上限必须真的把旧的丢掉');
    expect(
      pool.take(pluginId: 'p1', generation: 1, scope: _scopeA),
      isNull,
      reason: '最旧的 p1 应当已被丢弃',
    );
    expect(
      pool.take(pluginId: 'p3', generation: 1, scope: _scopeA),
      isNotNull,
      reason: '刚放进去的绝不能被本轮上限顺手丢掉，否则取回路径莫名其妙就断了',
    );
    expect(pool.droppedCount, greaterThanOrEqualTo(1));
  });

  test('总字节上限同样生效（按累计字节，不是按条数）', () {
    final PluginStatePool pool = PluginStatePool(
      maxEntries: 100,
      maxTotalBytes: 120,
    );
    for (int i = 1; i <= 5; i++) {
      pool.put(
        pluginId: 'p$i',
        generation: 1,
        payload: <String, dynamic>{'blob': 'x' * 40},
        scope: _scopeA,
      );
    }
    expect(pool.totalBytes, lessThanOrEqualTo(120));
    expect(pool.length, lessThan(5), reason: '字节上限必须真的削减占用');
  });

  test('TTL 到期 = 当作没有，并留下"按冷启动继续"的原因', () {
    final List<String> logs = <String>[];
    final PluginStatePool pool = PluginStatePool(
      ttl: const Duration(milliseconds: 20),
      log: logs.add,
    );
    pool.put(
      pluginId: 'demo',
      generation: 1,
      payload: <String, dynamic>{'v': 1},
      scope: _scopeA,
    );
    expect(
      pool.take(pluginId: 'demo', generation: 1, scope: _scopeA),
      isNotNull,
    );
    // 再放一份，等它过期。
    pool.put(
      pluginId: 'demo',
      generation: 2,
      payload: <String, dynamic>{'v': 2},
      scope: _scopeA,
    );
    return Future<void>.delayed(const Duration(milliseconds: 40), () {
      expect(
        pool.take(pluginId: 'demo', generation: 2, scope: _scopeA),
        isNull,
        reason: 'TTL 到期后必须当作不存在（新实例走冷启动）',
      );
      expect(
        logs.any((String line) => line.contains('存活时长')),
        isTrue,
        reason: '过期丢弃也要留痕，否则"快照呢"成了零日志悬案',
      );
    });
  });

  test('discard 精确到代际；读数只暴露水位不暴露 payload', () {
    final PluginStatePool pool = PluginStatePool();
    pool.put(
      pluginId: 'demo',
      generation: 1,
      payload: <String, dynamic>{'secret': 'do-not-leak'},
      scope: _scopeA,
    );
    pool.put(
      pluginId: 'demo',
      generation: 2,
      payload: <String, dynamic>{'secret': 'also-private'},
      scope: _scopeA,
    );
    final List<PluginStateReading> readings = pool.readings();
    expect(readings, hasLength(2));
    final Map<String, dynamic> json = readings.first.toJson();
    expect(
      json.keys,
      isNot(contains('payload')),
      reason: '池水位是运维读数，不该顺手把插件内部状态端出去',
    );
    expect(json.containsKey('bytes'), isTrue);
    expect(json.containsKey('age_ms'), isTrue);

    pool.discard('demo', generation: 1);
    expect(pool.length, 1);
    expect(
      pool.take(pluginId: 'demo', generation: 1, scope: _scopeA),
      isNull,
    );
    expect(pool.take(pluginId: 'demo', generation: 2, scope: _scopeA), isNotNull);

    pool.discard('demo');
    expect(pool.length, 0);
    expect(pool.readings(), isEmpty);
  });
}
