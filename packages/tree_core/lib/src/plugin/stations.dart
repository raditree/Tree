import 'package:tree_protocol/tree_protocol.dart';

import '../util/liveness.dart';
import 'station_instance.dart';
import 'station_runtime.dart';
import 'station_schema.dart';
import 'station_scope.dart';
import 'station_store.dart';

/// 站点中枢（M9 §3）：内置四站、插件自建站、订阅、插件下线注销、快照与落盘。
///
/// 站点 = **持久化实例**：同一类型在每个 team×mode 上是一个独立实例
/// （id = 基础 id@team@mode），因此隔离四元组天然成立：跨 team / 跨 local-ssh 的
/// 消息根本找不到站点（fail-closed）。
///
/// 「触发 = 实例的一个方法」：中枢只负责**找到实例**并把方法调用转过去；
/// 不做触发时机编排（时机由调用方 = 挂载位置的具体逻辑决定）。
class StationHub {
  StationHub({
    required this.storePath,
    StationStore? store,
    this.log,
    this.frameSink,
    this.heartbeatInterval = LivenessTracker.defaultInterval,
    this.missThreshold = LivenessTracker.defaultMaxMisses,
    this.livenessProbe,
    this.livenessProbeInterval = const Duration(milliseconds: 500),
  }) : _store = store ?? StationStore(storePath);

  /// 广播站基础 id。
  static const String broadcastBaseId = 'system.broadcast';

  /// 执行站基础 id。
  static const String executeBaseId = 'system.execute';

  /// 中转站基础 id。
  static const String relayBaseId = 'system.relay';

  /// 收集站（插件定义 tool，首个接入点）基础 id。
  static const String toolDefineBaseId = 'plugin.tool.define';

  /// 工具定义收集站的 schema（**站点定义输入格式**：插件必须按它产出）。
  ///
  /// 形状 = {tools: [ {tool_name, description, parameters, execution}, ... ]}：
  /// 每个订阅者（插件）一次申报自己的全部工具；同一插件多工具靠数组承载，
  /// 而**每一条**都覆盖了「名称 / 描述 / 参数 schema / 执行方式」四项。
  static const StationSchema toolDefinitionSchema = StationSchema(
    description: '插件工具定义清单（每项覆盖名称 / 描述 / 参数 schema / 执行方式）',
    fields: <StationSchemaField>[
      StationSchemaField(
        name: 'tools',
        type: StationFieldType.array,
        required: true,
        description: '本插件申报的工具定义列表（每项一条；没有工具时给空数组）',
        fields: <StationSchemaField>[
          StationSchemaField(
            name: 'tool_name',
            type: StationFieldType.string,
            required: true,
            description: '插件内唯一的工具名；注册后命名空间化为 plugin__插件id__工具名',
          ),
          StationSchemaField(
            name: 'description',
            type: StationFieldType.string,
            required: true,
            description: '工具描述（原样进模型工具表）',
          ),
          StationSchemaField(
            name: 'parameters',
            type: StationFieldType.object,
            required: true,
            description: '参数定义（JSON Schema 形状：type/properties/required）',
          ),
          StationSchemaField(
            name: 'execution',
            type: StationFieldType.object,
            required: false,
            description: '执行方式；缺省 = 经插件宿主 tools/call 调用 tool_name',
            fields: <StationSchemaField>[
              StationSchemaField(
                name: 'method',
                type: StationFieldType.string,
                required: false,
                description: '执行方式（当前支持 tools/call）',
              ),
              StationSchemaField(
                name: 'name',
                type: StationFieldType.string,
                required: false,
                description: '插件侧实际工具名（缺省 = tool_name）',
              ),
            ],
          ),
        ],
      ),
    ],
  );

  /// 落盘文件路径（与 plugins.yaml 同目录）。
  final String storePath;

  /// 日志出口（可空）。
  final void Function(String message)? log;

  /// 前端下行帧出口（**主 WS 广播**；ui.push 复用 card 槽位帧）。
  final void Function(Map<String, dynamic> frame)? frameSink;

  /// 心跳间隔 I（默认 10s；测试可缩参）。
  final Duration heartbeatInterval;

  /// 连续丢失阈值 N（默认 3）。
  final int missThreshold;

  /// 活性窗口（I×N）：只在订阅者「无活性信息」时兜底，心跳在则续期。
  Duration get livenessWindow => heartbeatInterval * missThreshold;

  /// 活性探针（由总线在接线时注入：pluginId → 心跳判活状态）。
  StationLivenessProbe? livenessProbe;

  /// 探测节拍（等待回包时轮询订阅者心跳的间隔）。
  final Duration livenessProbeInterval;

  final StationStore _store;
  final Map<String, StationInstance> _stations = <String, StationInstance>{};
  bool _loaded = false;

  /// 读盘（幂等；文件不存在 = 空表）。
  void load() {
    if (_loaded) return;
    _loaded = true;
    for (final StationInstance station in _store.load()) {
      _attach(station);
      _stations[station.id] = station;
    }
  }

  /// 全部站点实例（按 id 字典序，输出稳定）。
  List<StationInstance> stationList() {
    load();
    final List<StationInstance> list = _stations.values.toList();
    list.sort((StationInstance a, StationInstance b) => a.id.compareTo(b.id));
    return list;
  }

  /// 取站点实例（不存在返回 null）。
  StationInstance? station(String id) {
    load();
    return _stations[id];
  }

  /// 某插件在某 team×mode 上的内置站 id。
  static String teamStationId(String baseId, StationScope scope) =>
      '$baseId@${scope.teamId}@${scope.modeKey}';

  /// 广播站（系统自带；按 team×mode 落一个实例，不存在则创建）。
  BroadcastStation? broadcastFor(StationScope scope) {
    load();
    if (!scope.isValid) return null;
    final String id = teamStationId(broadcastBaseId, scope);
    final StationInstance? existing = _stations[id];
    if (existing is BroadcastStation) return existing;
    if (existing != null) return null;
    final BroadcastStation station = BroadcastStation(
      id: id,
      description: '广播站（系统自带）：插件发布 topic → 多订阅者接收 + 持久公告板',
      scope: teamScope(scope),
      builtin: true,
    );
    _register(station);
    return station;
  }

  /// 执行站（系统自带；插件主动下命令的落点，内置 ui.push 挂载位置）。
  ExecuteStation? executeFor(StationScope scope) {
    load();
    if (!scope.isValid) return null;
    final String id = teamStationId(executeBaseId, scope);
    final StationInstance? existing = _stations[id];
    if (existing is ExecuteStation) return existing;
    if (existing != null) return null;
    final ExecuteStation station = ExecuteStation(
      id: id,
      description:
          '执行站（系统自带）：插件主动下命令，由挂载位置执行；首命令集 = '
          'fs.read/fs.write/fs.list/fs.grep/terminal.exec/agent.message/'
          'agent.stop/agent.compact/ui.push',
      scope: teamScope(scope),
      builtin: true,
    );
    _register(station);
    return station;
  }

  /// 中转站（系统自带；站 × scope 键位唯一）。
  RelayStation? relayFor(StationScope scope) {
    load();
    if (!scope.isValid) return null;
    final String id = teamStationId(relayBaseId, scope);
    final StationInstance? existing = _stations[id];
    if (existing is RelayStation) return existing;
    if (existing != null) return null;
    final RelayStation station = RelayStation(
      id: id,
      description: '中转站（系统自带）：数据流拦截-回填；站 × scope 键位唯一（先到先得）',
      scope: teamScope(scope),
      maxSubscriptions: 16,
      builtin: true,
    );
    _register(station);
    return station;
  }

  /// 收集站「插件定义 tool」（系统自带；收集站的首个接入点）。
  CollectStation? toolDefineStationFor(StationScope scope) {
    load();
    if (!scope.isValid) return null;
    final String id = teamStationId(toolDefineBaseId, scope);
    final StationInstance? existing = _stations[id];
    if (existing is CollectStation) return existing;
    if (existing != null) return null;
    final CollectStation station = CollectStation(
      id: id,
      description: '收集站（系统自带）：插件按 schema 申报工具定义（名称/描述/参数/执行方式）',
      scope: teamScope(scope),
      schema: toolDefinitionSchema,
      builtin: true,
    );
    _register(station);
    return station;
  }

  /// 站点 scope：内置站绑定到 team×mode（agent/session 留空 = 不限定）。
  static StationScope teamScope(StationScope scope) =>
      StationScope(teamId: scope.teamId, modeKey: scope.modeKey);

  /// 插件自建站点（**只能注册既有四种类型**，不允许发明新类型）。
  ///
  /// 返回 null = 成功；否则返回可读中文原因。
  String? register(StationInstance station) {
    load();
    if (_stations.containsKey(station.id)) {
      return '站点 id 已存在：${station.id}';
    }
    if (!station.scope.isValid) {
      return '站点 scope 非法：team_id 必须非空、mode_key 只能是 local | ssh';
    }
    if (station is CollectStation && station.schema.fields.isEmpty) {
      return '收集站必须定义 schema（输入格式），当前为空';
    }
    _register(station);
    return null;
  }

  /// 订阅站点（执行站会被显式拒绝）。
  StationSubResult subscribe(
    String stationId,
    StationSubscriber subscriber,
    StationResponder responder, {
    bool replace = false,
  }) {
    load();
    final StationInstance? station = _stations[stationId];
    if (station == null) {
      return StationSubResult.rejected('站点不存在：$stationId', code: 'no_station');
    }
    if (!subscriber.scope.isValid) {
      return StationSubResult.rejected(
        '订阅者 scope 非法：team_id 必须非空、mode_key 只能是 local | ssh',
        code: 'invalid_scope',
      );
    }
    return station.subscribe(subscriber, responder, replace: replace);
  }

  /// **插件下线**：注销该插件在所有站点的订阅（总线在插件退出 / 停用时调用）。
  int unsubscribePlugin(String pluginId) {
    load();
    int removed = 0;
    for (final StationInstance station in _stations.values) {
      removed += station.unsubscribePlugin(pluginId);
    }
    if (removed > 0) {
      log?.call('插件 $pluginId 下线：注销站点订阅 $removed 条');
      save();
    }
    return removed;
  }

  /// 显式退订某站点上的某插件；返回移除条数。
  int unsubscribe(String stationId, String pluginId) {
    load();
    final StationInstance? station = _stations[stationId];
    if (station == null) return 0;
    final List<StationSubscriber> removed = station.subscribers
        .where((StationSubscriber s) => s.pluginId == pluginId)
        .toList(growable: false);
    for (final StationSubscriber sub in removed) {
      station.unsubscribeKey(sub.key);
    }
    if (removed.isNotEmpty) save();
    return removed.length;
  }

  /// 前端快照（stations 段；形状与既有 PluginStationInfo 的宽容解析对齐）。
  List<Map<String, dynamic>> snapshot({String? teamId}) {
    load();
    return stationList()
        .where((StationInstance station) {
          if (teamId == null || teamId.isEmpty) return true;
          return station.scope.teamId.isEmpty || station.scope.teamId == teamId;
        })
        .map((StationInstance station) => station.describe())
        .toList(growable: false);
  }

  /// 汇总（快照 / 日志用）。
  Map<String, dynamic> summary() {
    load();
    int subscriptions = 0;
    final Map<String, int> byKind = <String, int>{};
    for (final StationInstance station in _stations.values) {
      subscriptions += station.subscribers.length;
      byKind[station.kind.wire] = (byKind[station.kind.wire] ?? 0) + 1;
    }
    return <String, dynamic>{
      'station_count': _stations.length,
      'subscription_count': subscriptions,
      'by_kind': byKind,
      'heartbeat_interval_s': heartbeatInterval.inMilliseconds / 1000,
      'miss_threshold': missThreshold,
      'store_path': storePath,
    };
  }

  /// 落盘（原子覆盖写；站点实例与订阅关系一起持久化，跨重启保留）。
  void save() {
    if (!_loaded) return;
    _store.save(_stations.values);
  }

  void _register(StationInstance station) {
    _attach(station);
    _stations[station.id] = station;
    save();
  }

  /// 运行期绑定：活性探针 / 探测节拍 / 活性窗口 / 变更即落盘 / 内置 ui.push 挂载。
  void _attach(StationInstance station) {
    station.liveness = (String pluginId) =>
        livenessProbe?.call(pluginId) ?? const StationLivenessState.unknown();
    station.livenessProbeInterval = livenessProbeInterval;
    station.livenessWindow = livenessWindow;
    station.onMutated = save;
    if (station is ExecuteStation) _ensureUiPushMount(station);
  }

  /// 内置 ui.push 挂载位置：**复用 4.1 的 card 槽位帧**（不发明新帧）。
  ///
  /// 帧发到主 WS 广播（前端只在主连接上消费插件 UI 帧）；team_id 取自命令
  /// scope（1.2 隔离：槽位一律带 team_id）。
  void _ensureUiPushMount(ExecuteStation station) {
    station.mount(
      command: 'ui.push',
      mountId: 'core.frontend.card',
      handler: (StationCommandContext context) async {
        final String slotKey = (context.arguments['slot_key'] ?? '')
            .toString()
            .trim();
        if (slotKey.isEmpty) {
          return const StationCommandOutcome.failed(
            'ui.push 需要 slot_key（消息流内联卡片槽位键）',
          );
        }
        final bool hasView = context.arguments.containsKey('view');
        final Object? rawView = context.arguments['view'];
        final PluginUiView? view = PluginUiView.tryParse(rawView);
        if (hasView && rawView != null && view == null) {
          return const StationCommandOutcome.failed(
            'ui.push 的 view 非法（声明式视图模型解析失败）',
          );
        }
        final void Function(Map<String, dynamic> frame)? sink = frameSink;
        if (sink == null) {
          return const StationCommandOutcome.failed('前端推送通道不可用（未接入主 WS 广播）');
        }
        final Map<String, dynamic> frame = PluginUiUpdate(
          pluginId: context.sourcePluginId,
          teamId: context.scope.teamId,
          slotKey: slotKey,
          view: view,
        ).toFrame();
        sink(frame);
        return StationCommandOutcome.ok(<String, dynamic>{
          'pushed': true,
          'slot': PluginUiSlotKind.card,
          'slot_key': slotKey,
          'unregistered': view == null,
        });
      },
    );
  }
}
