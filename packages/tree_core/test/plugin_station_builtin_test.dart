import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 内置站「**点位化 + 启动即存在**」（M9 §3，用户 2026-10-01 定稿语义）。
///
/// 语义（点位化）：站点 = **拦截点 / 触发点**，站点类型只有四种
/// （广播 / 执行 / 中转 / 收集），但每类下有若干**点位**——**每个点位是一个独立的
/// 站点实例**（各自唯一订阅者 / 各自挂载位置 / 各自计数），id 形如
/// `system.relay.tool.pre`、**不含 team、不含 mode**。team / agent / session / mode 是
/// **每次交互携带的信封**（消息 scope）与**订阅声明**，只在投递时用于匹配订阅者。
///
/// 这个文件锁住六条语义：
/// 1. **就位**：18 个内置点位一次建齐（广播 4 + 执行 8 + 中转 6），id = 点位常量；
/// 2. **与 team / agent 无关**：站点数不随团队或 agent 数量变化；
/// 3. **幂等**：重复调用不产生重复实例，也不重复落盘；
/// 4. **持久化**：第二次启动从 stations.yaml 恢复，数量与 id 不变、不再新建；
/// 5. **迁移**：旧 `baseId@team@mode` 条目归并到点位 id；**退役 id**（`system.relay` /
///    `system.execute`）按点位化规则迁移（幂等，只写回一次）；
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

  /// 预建点位（= 除收集站外的全部内置点位，按 id 字典序：`stationList()` 的输出顺序）。
  List<String> expectedPrebuilt() => StationPoints.all
      .where((StationPointSpec spec) => spec.kind != StationKind.collect)
      .map((StationPointSpec spec) => spec.id)
      .toList()
    ..sort();

  test('空存储：18 个内置点位一次建齐，id 是点位常量（不含 team / mode）', () {
    final StationHub hub = StationHub(storePath: storePath);
    expect(hub.stationList(), isEmpty, reason: '预建之前确实是空的（懒创建的世界）');

    final List<String> created = hub.ensureBuiltinStations();

    expect(
      created,
      hasLength(18),
      reason: '广播 4 + 执行 8 + 中转 6；每个点位是一个独立实例',
    );
    // stationList() 按 id 字典序（输出稳定）
    expect(idsOf(hub), expectedPrebuilt());
    for (final StationInstance station in hub.stationList()) {
      expect(station.builtin, isTrue, reason: '预建的都是系统自带站');
      expect(
        station.id.contains('@'),
        isFalse,
        reason: '点位 id 不含 team×mode 后缀（点位化的核心）',
      );
    }
    // 每个**点位**都是一条独立实例：按类型数是 4 / 8 / 6（不是四种类型各一个）
    expect(hub.stationList().whereType<BroadcastStation>(), hasLength(4));
    expect(hub.stationList().whereType<ExecuteStation>(), hasLength(8));
    expect(hub.stationList().whereType<RelayStation>(), hasLength(6));

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
    expect(baseline, hasLength(18));

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
    expect(idsOf(hub), hasLength(18));

    // 接入点需要时现建（「插件定义 tool」的首个接入点），预建不会碰它
    final CollectStation collect = hub.toolDefineStationFor()!;
    expect(collect.id, StationHubIds.collect);
    expect(collect.schema.fieldNames, contains('tools'));
    // 再来一次拿到的必须是同一个实例（全局唯一），而不是又建一个
    expect(hub.toolDefineStationFor(), same(collect));
    expect(hub.ensureBuiltinStations(), isEmpty);
    expect(idsOf(hub), hasLength(19));
    expect(hub.stationList().whereType<CollectStation>().single.id, collect.id);
  });

  test('幂等：重复调用不重复创建、不重复落盘', () {
    final _CountingStationStore counting = _CountingStationStore(storePath);
    final StationHub hub = StationHub(storePath: storePath, store: counting);

    expect(hub.ensureBuiltinStations(), hasLength(18));
    expect(counting.saves, 1, reason: '一批预建合并成一次落盘（不是每站一次）');
    final String after = File(storePath).readAsStringSync();

    // 第二次 / 第三次：全部已存在 ⇒ 不新建、不落盘（文件内容与写盘次数都不变）
    expect(hub.ensureBuiltinStations(), isEmpty);
    expect(hub.ensureBuiltinStations(), isEmpty);
    expect(counting.saves, 1);
    expect(idsOf(hub), hasLength(18), reason: '不产生重复实例');
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
    // 预建按**点位表顺序**（广播 4 → 执行 8 → 中转 6）：通用主题点位已存在 ⇒
    // 本轮只新建其余 17 个点位（已存在的既不新建也不覆盖）
    expect(
      created,
      StationPoints.all
          .where(
            (StationPointSpec spec) =>
                spec.kind != StationKind.collect &&
                spec.id != StationHubIds.broadcast,
          )
          .map((StationPointSpec spec) => spec.id)
          .toList(),
      reason: '广播站·通用主题已存在 ⇒ 只补其余 17 个点位',
    );
    expect(created, hasLength(17));
    expect(hub.station(broadcast.id), same(broadcast));
    expect(hub.station(broadcast.id)!.subscribers, hasLength(1));
    // 订阅者的 team 视角由一个全局站承载（面板据此分组）
    expect(hub.station(broadcast.id)!.subscribersByTeam().keys, <String>[
      'team-1',
    ]);
  });

  test('持久化：第二次启动从 stations.yaml 恢复，数量与 id 不变且不再新建', () {
    final StationHub first = StationHub(storePath: storePath);
    expect(first.ensureBuiltinStations(), hasLength(18));
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

  test('迁移：旧 baseId@team@mode 条目归并到点位 id，订阅去重合并', () {
    // 手写一份"第一代"存储（`baseId@team@mode`）：3 个 team×mode 组合 × 3 类站，
    // 其中广播站在两个组合上各有一条订阅（同一插件在两个 team 上各订一次）。
    //
    // **注意 `system.relay@…` / `system.execute@…` 这两族的去向**：带 `@` 的条目按
    // **基础 id** 归并，退役映射看的是 base id（而不是整条 id）——
    // `system.relay@team@mode` ⇒ 拆分到 `system.relay.tool.pre` / `.tool.post`
    // 两个点位（订阅复制到两处，原订阅者行为等价）；`system.execute@…` ⇒ 丢弃
    // （执行站不可订阅，没有订阅需要迁移）。
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
    subscribers:
      - {plugin_id: sample, scope: {team_id: team-1, mode_key: local}, subscribed_at: 3}
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
        // 字典序：plugin.* < system.broadcast < system.relay.*
        StationHubIds.collect,
        StationHubIds.broadcast,
        StationHubIds.relayToolPost,
        StationHubIds.relayToolPre,
      ],
      reason:
          '6 条旧实例归并成 4 个点位：广播站按基础 id 归并、收集站保留 schema、'
          '退役中转站（两处旧条目）拆成工具前/后两个点位；退役执行站无订阅可迁 ⇒ 丢弃',
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

    // 退役基础 id 的条目被丢弃 / 拆分（不产生半截站点、也不复活退役 id）
    expect(hub.station('system.execute'), isNull);
    expect(hub.station('system.relay'), isNull);
    expect(hub.stationList().whereType<ExecuteStation>(), isEmpty);
    // `system.relay@…` ⇒ 两个工具点位；created_at 取两处最小（70 / 60 ⇒ 60）
    final List<RelayStation> relays = hub
        .stationList()
        .whereType<RelayStation>()
        .toList();
    expect(relays, hasLength(2));
    expect(
      relays.map((RelayStation r) => r.id).toSet(),
      <String>{StationHubIds.relayToolPre, StationHubIds.relayToolPost},
    );
    expect(relays.every((RelayStation r) => r.createdAt == 60), isTrue);
    // **旧中转站的订阅复制到两个点位**（原订阅者照样 pre / post 都收到）
    for (final RelayStation relay in relays) {
      expect(relay.subscribers, hasLength(1), reason: '${relay.id} 应带着旧订阅');
      expect(relay.subscribers.first.pluginId, 'sample');
      expect(relay.subscribers.first.scope.teamId, 'team-1');
      expect(relay.subscribers.first.subscribedAt, 3);
    }

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

  test('迁移（点位化）：退役 id system.relay 拆成工具前/后两个点位，system.execute 直接丢弃', () {
    // 第二代旧存储：**精确的退役 id**（中转站工具前/后曾共用一个实例，靠
    // payload.phase 区分；执行站九条命令曾共用一个实例）。
    // 迁移规则：relay 的订阅**复制**到两个工具点位，execute 没有订阅可迁 ⇒ 丢弃。
    File(storePath).parent.createSync(recursive: true);
    File(storePath).writeAsStringSync('''
version: 1
stations:
  - id: system.relay
    kind: relay
    description: 中转站（系统自带）
    builtin: true
    created_at: 70
    subscribers:
      - {plugin_id: sample, scope: {team_id: team-1, mode_key: local}, subscribed_at: 5}
  - id: system.execute
    kind: execute
    description: 执行站（系统自带）
    builtin: true
    created_at: 80
''');

    final _CountingStationStore counting = _CountingStationStore(storePath);
    final StationHub hub = StationHub(storePath: storePath, store: counting);
    hub.load();

    expect(
      idsOf(hub),
      <String>[
        // 字典序：tool.post < tool.pre
        StationHubIds.relayToolPost,
        StationHubIds.relayToolPre,
      ],
      reason: '退役中转站拆成两个点位；退役执行站无订阅可迁 ⇒ 丢弃',
    );
    expect(counting.saves, 1, reason: '迁移结果立刻写回一次');

    // **旧订阅复制到两处**：原订阅者行为等价（照样 pre / post 都收到），
    // 想只收一个的自己退订另一个。
    for (final String pointId in <String>[
      StationHubIds.relayToolPre,
      StationHubIds.relayToolPost,
    ]) {
      final RelayStation point = hub.station(pointId)! as RelayStation;
      expect(
        point.subscribers.single.pluginId,
        'sample',
        reason: '$pointId 必须继承旧中转站的订阅',
      );
      expect(point.subscribers.single.scope.teamId, 'team-1');
      expect(point.createdAt, 70, reason: '站点"资历"跨迁移保留');
    }
    // 退役 id 不再是实例 id（迁移后也不该复活）
    expect(hub.station(StationHubIds.legacyRelay), isNull);
    expect(hub.station(StationHubIds.legacyExecute), isNull);
    expect(hub.stationList().whereType<ExecuteStation>(), isEmpty);

    // 幂等：再起一次不再迁移、不再写盘
    final _CountingStationStore again = _CountingStationStore(storePath);
    final StationHub restarted = StationHub(storePath: storePath, store: again);
    restarted.load();
    expect(again.saves, 0, reason: '第二次启动不再迁移、不再写盘');
    expect(idsOf(restarted), idsOf(hub));
    final String text = File(storePath).readAsStringSync();
    expect(text.contains('system.relay.tool.pre'), isTrue);
    expect(text.contains('system.relay.tool.post'), isTrue);
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
