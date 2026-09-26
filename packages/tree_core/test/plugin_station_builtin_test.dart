import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 内置站「**启动即存在**」（M9 §3「三站系统自带」+ 用户实机反馈）。
///
/// 背景：广播站 / 执行站 / 中转站原本是**懒创建**的（首次使用时才实例化），
/// 于是"没配插件、没人用过"时一个内置站都没有 —— 面板上就是「站点（0）」，
/// 与「三站默认设在系统中」的预期不符。核心现在在站点接线处按存储里已有的
/// (team, 工作空间模式) 组合预建一遍，这个文件锁住四条语义：
///
/// 1. **就位**：每个组合上三类内置站齐全，id = `system.<kind>@<team>@<mode>`；
/// 2. **幂等**：重复调用不产生重复实例，也不重复落盘；
/// 3. **持久化**：第二次启动从 stations.yaml 恢复，数量与 id 不变、不再新建；
/// 4. **取舍**：**不预建收集站**（schema 属于具体接入点，空 schema 的收集站没有意义）。
void main() {
  late Directory temp;
  late String storePath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_station_builtin_');
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

  test('空存储：每个 (team, 工作空间模式) 上三类内置站各就位', () {
    final StationHub hub = StationHub(storePath: storePath);
    expect(hub.stationList(), isEmpty, reason: '预建之前确实是空的（懒创建的世界）');

    final List<String> created = hub.ensureBuiltinStations(<StationScope>[
      team('team-1'),
      team('team-1', mode: StationModeKey.ssh),
      team('team-2'),
    ]);

    expect(created, hasLength(9), reason: '3 个组合 × 广播/执行/中转 3 类');
    // stationList() 按 id 字典序（输出稳定）：broadcast < execute < relay，
    // team-1@local < team-1@ssh < team-2@local
    expect(idsOf(hub), <String>[
      'system.broadcast@team-1@local',
      'system.broadcast@team-1@ssh',
      'system.broadcast@team-2@local',
      'system.execute@team-1@local',
      'system.execute@team-1@ssh',
      'system.execute@team-2@local',
      'system.relay@team-1@local',
      'system.relay@team-1@ssh',
      'system.relay@team-2@local',
    ]);
    for (final StationInstance station in hub.stationList()) {
      expect(station.builtin, isTrue, reason: '预建的都是系统自带站');
      expect(station.scope.teamId, isNotEmpty);
      expect(station.scope.agentId, isEmpty, reason: '内置站只绑 team×mode');
      expect(station.scope.sessionId, isEmpty);
    }
    expect(hub.stationList().whereType<BroadcastStation>(), hasLength(3));
    expect(hub.stationList().whereType<ExecuteStation>(), hasLength(3));
    expect(hub.stationList().whereType<RelayStation>(), hasLength(3));

    // 面板快照口径（前端卡片直接渲染这几个字段）：中文名 / 内置 / 订阅数 / mode
    final Map<String, dynamic> described = hub
        .snapshot(teamId: 'team-1')
        .firstWhere(
          (Map<String, dynamic> s) =>
              s['station_id'] == 'system.broadcast@team-1@ssh',
        );
    expect(described['kind'], 'broadcast');
    expect(described['kind_label'], '广播站');
    expect(described['builtin'], isTrue);
    expect(described['subscriber_count'], 0);
    expect(
      (described['scope'] as Map<String, dynamic>)['mode_key'],
      StationModeKey.ssh,
    );
  });

  test('取舍：不预建收集站（schema 属于接入点）', () {
    final StationHub hub = StationHub(storePath: storePath);
    hub.ensureBuiltinStations(<StationScope>[team('team-1')]);

    expect(
      hub.stationList().whereType<CollectStation>(),
      isEmpty,
      reason: '没有接入点就没有输入格式，空 schema 的收集站没有意义',
    );
    expect(idsOf(hub), hasLength(3));

    // 接入点需要时现建（「插件定义 tool」的首个接入点），预建不会碰它
    final CollectStation collect = hub.toolDefineStationFor(team('team-1'))!;
    expect(collect.id, 'plugin.tool.define@team-1@local');
    expect(collect.schema.fieldNames, contains('tools'));
    expect(hub.ensureBuiltinStations(<StationScope>[team('team-1')]), isEmpty);
    expect(idsOf(hub), hasLength(4));
    expect(hub.stationList().whereType<CollectStation>().single.id, collect.id);
  });

  test('幂等：重复调用不重复创建、不重复落盘', () {
    final _CountingStationStore counting = _CountingStationStore(storePath);
    final StationHub hub = StationHub(storePath: storePath, store: counting);
    final List<StationScope> scopes = <StationScope>[team('team-1')];

    expect(hub.ensureBuiltinStations(scopes), hasLength(3));
    expect(counting.saves, 1, reason: '一批预建合并成一次落盘（不是每站一次）');
    final String after = File(storePath).readAsStringSync();

    // 第二次 / 第三次：全部已存在 ⇒ 不新建、不落盘（文件内容与写盘次数都不变）
    expect(hub.ensureBuiltinStations(scopes), isEmpty);
    expect(hub.ensureBuiltinStations(scopes), isEmpty);
    expect(counting.saves, 1);
    expect(idsOf(hub), hasLength(3), reason: '不产生重复实例');
    expect(File(storePath).readAsStringSync(), after, reason: '磁盘内容一字不差');
  });

  test('幂等边界：已存在的站点（含订阅/公告板）原样保留，只补缺的那类', () {
    final StationHub hub = StationHub(storePath: storePath);
    final StationScope scope = team('team-1');
    final BroadcastStation broadcast = hub.broadcastFor(scope)!;
    hub.subscribe(
      broadcast.id,
      StationSubscriber(pluginId: 'p1', scope: scope, subscribedAt: 1),
      (StationRequest request) async => StationReply.ok(),
    );

    final List<String> created = hub.ensureBuiltinStations(<StationScope>[
      scope,
    ]);
    expect(created, <String>[
      'system.execute@team-1@local',
      'system.relay@team-1@local',
    ], reason: '广播站已存在 ⇒ 只补执行站与中转站');
    expect(hub.station(broadcast.id), same(broadcast));
    expect(hub.station(broadcast.id)!.subscribers, hasLength(1));
  });

  test('持久化：第二次启动从 stations.yaml 恢复，数量与 id 不变且不再新建', () {
    final StationHub first = StationHub(storePath: storePath);
    expect(
      first.ensureBuiltinStations(<StationScope>[
        team('team-1'),
        team('team-1', mode: StationModeKey.ssh),
      ]),
      hasLength(6),
    );
    final List<String> baseline = idsOf(first);
    expect(File(storePath).existsSync(), isTrue, reason: '内置站必须落盘');

    // 「重启」：新中枢读同一个文件（顺序与核心启动一致：先 load 再预建）
    final _CountingStationStore counting = _CountingStationStore(storePath);
    final StationHub second = StationHub(storePath: storePath, store: counting);
    second.load();
    expect(idsOf(second), baseline, reason: '从盘恢复的实例一字不差');

    expect(
      second.ensureBuiltinStations(<StationScope>[
        team('team-1'),
        team('team-1', mode: StationModeKey.ssh),
      ]),
      isEmpty,
      reason: '恢复完就没有可建的了',
    );
    expect(counting.saves, 0, reason: '一个都没新建 ⇒ 一次盘都不写');
    expect(idsOf(second), baseline);
    expect(second.stationList().whereType<CollectStation>(), isEmpty);
  });

  test('非法组合直接跳过：team 为空或 mode 非法都不建、也不产生空文件', () {
    final StationHub hub = StationHub(storePath: storePath);
    expect(
      hub.ensureBuiltinStations(<StationScope>[
        const StationScope(),
        const StationScope(teamId: 'team-1', modeKey: 'cloud'),
        const StationScope(teamId: '   ', modeKey: StationModeKey.local),
      ]),
      isEmpty,
    );
    expect(hub.stationList(), isEmpty);
    expect(
      File(storePath).existsSync(),
      isFalse,
      reason: '什么都没建 ⇒ 不该留下一个空 stations.yaml',
    );
  });

  test('重复的 (team, mode) 组合不会建两遍（靠站点 id 幂等，不靠调用方去重）', () {
    final StationHub hub = StationHub(storePath: storePath);
    expect(
      hub.ensureBuiltinStations(<StationScope>[team('team-1'), team('team-1')]),
      hasLength(3),
    );
    expect(idsOf(hub), hasLength(3));
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
