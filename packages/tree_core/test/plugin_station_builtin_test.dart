import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 内置站「**全局唯一 + 启动即存在**」（M9 §3「三站系统自带」，用户定稿语义）。
///
/// 语义（本次收敛）：站点是**拦截点 / 触发点**，每类站全局只有一个实例，
/// id 就是类型常量（`system.broadcast` / `system.execute` / `system.relay`）、
/// **不含 team、不含 mode**。team / agent / session / mode 是**每次交互携带的
/// 信封**（消息 scope）与**订阅声明**，只在投递时用于匹配订阅者。
///
/// 这个文件锁住六条语义：
/// 1. **就位**：三站一次建齐，id = 类型常量；
/// 2. **与 team / agent 无关**：站点数不随团队或 agent 数量变化；
/// 3. **幂等**：重复调用不产生重复实例，也不重复落盘；
/// 4. **持久化**：第二次启动从 stations.yaml 恢复，数量与 id 不变、不再新建；
/// 5. **迁移**：旧 `baseId@team@mode` 条目归并到常量 id（幂等，只写回一次）；
/// 6. **取舍**：**不预建收集站**（schema 属于具体接入点，空 schema 没有意义）。
void main() {
  late Directory temp;
  late String storePath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_station_global_');
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

  StationScope team(String id, {String mode = StationModeKey.local}) =>
      StationScope(teamId: id, modeKey: mode);

  List<String> idsOf(StationHub hub) =>
      hub.stationList().map((StationInstance s) => s.id).toList();

  test('空存储：三站一次建齐，id 是类型常量（不含 team / mode）', () {
    final StationHub hub = StationHub(storePath: storePath);
    expect(hub.stationList(), isEmpty, reason: '预建之前确实是空的（懒创建的世界）');

    final List<String> created = hub.ensureBuiltinStations();

    expect(created, hasLength(3), reason: '广播 / 执行 / 中转 各一个');
    // stationList() 按 id 字典序（输出稳定）：broadcast < execute < relay
    expect(idsOf(hub), <String>[
      StationHubIds.broadcast,
      StationHubIds.execute,
      StationHubIds.relay,
    ]);
    for (final StationInstance station in hub.stationList()) {
      expect(station.builtin, isTrue, reason: '预建的都是系统自带站');
      expect(
        station.id.contains('@'),
        isFalse,
        reason: '全局 id 不含 team×mode 后缀（这是本次收敛的核心）',
      );
    }
    expect(hub.stationList().whereType<BroadcastStation>(), hasLength(1));
    expect(hub.stationList().whereType<ExecuteStation>(), hasLength(1));
    expect(hub.stationList().whereType<RelayStation>(), hasLength(1));

    // 面板快照口径（前端卡片直接渲染这几个字段）：中文名 / 内置 / 订阅数 / 分组
    final Map<String, dynamic> described = hub
        .snapshot()
        .firstWhere(
          (Map<String, dynamic> s) => s['station_id'] == StationHubIds.broadcast,
        );
    expect(described['kind'], 'broadcast');
    expect(described['kind_label'], '广播站');
    expect(described['builtin'], isTrue);
    expect(described['subscriber_count'], 0);
    expect(described['subscribers_by_team'], isEmpty);
  });

  test('站点数与 team / agent 的数量无关（新建 agent 不产生新站点）', () {
    final StationHub hub = StationHub(storePath: storePath);
    hub.ensureBuiltinStations();
    final List<String> baseline = idsOf(hub);
    expect(baseline, hasLength(3));

    // 模拟"团队变多 / 新 agent 出现"：这些在收敛后**不再**是站点的输入。
    // 反复调用预建（核心在启动接线处与任何补建点都可能调）必须一字不变。
    for (int i = 0; i < 3; i++) {
      expect(hub.ensureBuiltinStations(), isEmpty);
    }
    expect(idsOf(hub), baseline, reason: '站点表与团队/agent 解耦');
  });

  test('取舍：不预建收集站（schema 属于接入点），需要时现建且全局唯一', () {
    final StationHub hub = StationHub(storePath: storePath);
    hub.ensureBuiltinStations();

    expect(
      hub.stationList().whereType<CollectStation>(),
      isEmpty,
      reason: '没有接入点就没有输入格式，空 schema 的收集站没有意义',
    );
    expect(idsOf(hub), hasLength(3));

    // 接入点需要时现建（「插件定义 tool」的首个接入点），预建不会碰它
    final CollectStation collect = hub.toolDefineStationFor()!;
    expect(collect.id, StationHubIds.collect);
    expect(collect.schema.fieldNames, contains('tools'));
    // 再来一次拿到的必须是同一个实例（全局唯一），而不是又建一个
    expect(hub.toolDefineStationFor(), same(collect));
    expect(hub.ensureBuiltinStations(), isEmpty);
    expect(idsOf(hub), hasLength(4));
    expect(hub.stationList().whereType<CollectStation>().single.id, collect.id);
  });

  test('幂等：重复调用不重复创建、不重复落盘', () {
    final _CountingStationStore counting = _CountingStationStore(storePath);
    final StationHub hub = StationHub(storePath: storePath, store: counting);

    expect(hub.ensureBuiltinStations(), hasLength(3));
    expect(counting.saves, 1, reason: '一批预建合并成一次落盘（不是每站一次）');
    final String after = File(storePath).readAsStringSync();

    // 第二次 / 第三次：全部已存在 ⇒ 不新建、不落盘（文件内容与写盘次数都不变）
    expect(hub.ensureBuiltinStations(), isEmpty);
    expect(hub.ensureBuiltinStations(), isEmpty);
    expect(counting.saves, 1);
    expect(idsOf(hub), hasLength(3), reason: '不产生重复实例');
    expect(File(storePath).readAsStringSync(), after, reason: '磁盘内容一字不差');
  });

  test('幂等边界：已存在的站点（含订阅）原样保留，只补缺的那类', () {
    final StationHub hub = StationHub(storePath: storePath);
    final StationScope scope = team('team-1');
    final BroadcastStation broadcast = hub.broadcastFor()!;
    hub.subscribe(
      broadcast.id,
      StationSubscriber(pluginId: 'p1', scope: scope, subscribedAt: 1),
      (StationRequest request) async => StationReply.ok(),
    );

    final List<String> created = hub.ensureBuiltinStations();
    expect(created, <String>[
      StationHubIds.execute,
      StationHubIds.relay,
    ], reason: '广播站已存在 ⇒ 只补执行站与中转站');
    expect(hub.station(broadcast.id), same(broadcast));
    expect(hub.station(broadcast.id)!.subscribers, hasLength(1));
    // 订阅者的 team 视角由一个全局站承载（面板据此分组）
    expect(hub.station(broadcast.id)!.subscribersByTeam().keys, <String>[
      'team-1',
    ]);
  });

  test('持久化：第二次启动从 stations.yaml 恢复，数量与 id 不变且不再新建', () {
    final StationHub first = StationHub(storePath: storePath);
    expect(first.ensureBuiltinStations(), hasLength(3));
    final List<String> baseline = idsOf(first);
    expect(File(storePath).existsSync(), isTrue, reason: '内置站必须落盘');

    // 「重启」：新中枢读同一个文件（顺序与核心启动一致：先 load 再预建）
    final _CountingStationStore counting = _CountingStationStore(storePath);
    final StationHub second = StationHub(storePath: storePath, store: counting);
    second.load();
    expect(idsOf(second), baseline, reason: '从盘恢复的实例一字不差');

    expect(
      second.ensureBuiltinStations(),
      isEmpty,
      reason: '恢复完就没有可建的了',
    );
    expect(counting.saves, 0, reason: '一个都没新建 ⇒ 一次盘都不写');
    expect(idsOf(second), baseline);
    expect(second.stationList().whereType<CollectStation>(), isEmpty);
  });

  test('迁移：旧 baseId@team@mode 条目归并到常量 id，订阅去重合并', () {
    // 手写一份"收敛前"的存储：3 个 team×mode 组合 × 3 类站 = 9 条，
    // 其中广播站在两个组合上各有一条订阅（同一插件在两个 team 上各订一次）。
    File(storePath).parent.createSync(recursive: true);
    File(storePath).writeAsStringSync('''
version: 1
stations:
  - id: system.broadcast@team-1@local
    kind: broadcast
    description: 广播站（系统自带）
    scope: {team_id: team-1, agent_id: "", session_id: "", mode_key: local}
    builtin: true
    created_at: 100
    subscribers:
      - {plugin_id: sample, scope: {team_id: team-1, mode_key: local}, subscribed_at: 5}
    board_limit: 50
    board_seq: 1
    board:
      - {seq: 1, topic: t1, source_plugin_id: sample, ts: 10, scope: {team_id: team-1, mode_key: local}}
  - id: system.broadcast@team-1@ssh
    kind: broadcast
    description: 广播站（系统自带）
    builtin: true
    created_at: 90
    subscribers:
      - {plugin_id: sample, scope: {team_id: team-1, mode_key: ssh}, subscribed_at: 7}
    board_limit: 50
    board_seq: 2
  - id: system.execute@team-1@local
    kind: execute
    description: 执行站（系统自带）
    builtin: true
    created_at: 80
  - id: system.relay@team-1@local
    kind: relay
    description: 中转站（系统自带）
    builtin: true
    created_at: 70
  - id: system.relay@team-2@ssh
    kind: relay
    description: 中转站（系统自带）
    builtin: true
    created_at: 60
  - id: plugin.tool.define@team-1@local
    kind: collect
    description: 收集站（系统自带）
    builtin: true
    created_at: 50
    schema:
      description: 插件工具定义清单
      fields:
        - {name: tools, type: array, required: true}
''');

    final _CountingStationStore counting = _CountingStationStore(storePath);
    final StationHub hub = StationHub(storePath: storePath, store: counting);
    hub.load();

    expect(
      idsOf(hub),
      <String>[
        // 字典序：plugin.* < system.*
        StationHubIds.collect,
        StationHubIds.broadcast,
        StationHubIds.execute,
        StationHubIds.relay,
      ],
      reason: '9 条旧实例归并成 4 条全局站（去重 + 常量 id）',
    );
    expect(counting.saves, 1, reason: '迁移结果立刻写回一次');

    // 广播站：两处订阅都保留（team-1 的 local 与 ssh 各一条，scope 不同 ⇒ 两条）
    final BroadcastStation broadcast =
        hub.station(StationHubIds.broadcast)! as BroadcastStation;
    expect(broadcast.subscribers, hasLength(2));
    expect(broadcast.subscribersByTeam().keys, <String>['team-1']);
    expect(
      broadcast.subscribersByTeam()['team-1']!['plugin_ids'],
      <String>['sample'],
      reason: '同期同插件的订阅者按 team 归到一处',
    );
    // created_at 取最小（跨迁移保留"资历"）
    expect(broadcast.createdAt, 90);
    // 公告板：合并后 board_seq 取最大水位
    expect(broadcast.boardSeq, 2);
    expect(broadcast.board, hasLength(1), reason: '两处只有一条真实公告');

    // 中转站：两个 team 各有一条旧实例 ⇒ 归并成一条，订阅者都在上面
    final RelayStation relay = hub.station(StationHubIds.relay)! as RelayStation;
    expect(relay.createdAt, 60, reason: '取最小 created_at');
    expect(relay.subscribers, isEmpty);

    // 收集站：schema 跨迁移保留（迁移后仍是可用的收集站）
    final CollectStation collect =
        hub.station(StationHubIds.collect)! as CollectStation;
    expect(collect.schema.fieldNames, contains('tools'));

    // 迁移是幂等的：再起一次不该再写盘（文件里已经没有 @ 条目了）
    final _CountingStationStore again = _CountingStationStore(storePath);
    final StationHub restarted = StationHub(storePath: storePath, store: again);
    restarted.load();
    expect(again.saves, 0, reason: '第二次启动不再迁移、不再写盘');
    expect(idsOf(restarted), idsOf(hub));

    // 写回后的文件必须是新口径（可人工阅读，不含 @team@mode）
    final String text = File(storePath).readAsStringSync();
    expect(text.contains('@team-1@local'), isFalse);
    expect(text.contains('system.broadcast'), isTrue);
  });

  test('迁移：无法判定类型的旧条目被丢弃，不产生半截站点', () {
    File(storePath).parent.createSync(recursive: true);
    File(storePath).writeAsStringSync('''
version: 1
stations:
  - id: mystery.thing@team-1@local
    kind: relay
    description: 来历不明
    builtin: false
''');

    final StationHub hub = StationHub(storePath: storePath);
    hub.load();
    expect(hub.stationList(), isEmpty, reason: '未知基础 id 不猜类型，直接丢弃');
  });
}

/// 记录落盘次数的站点存储：用来证明「重复启动不重复落盘」（幂等的另一半）。
class _CountingStationStore extends StationStore {
  _CountingStationStore(super.path);

  /// [StationStore.save] 的真实调用次数（不含被合并掉的那些）。
  int saves = 0;

  @override
  void save(Iterable<StationInstance> stations) {
    saves++;
    super.save(stations);
  }
}
