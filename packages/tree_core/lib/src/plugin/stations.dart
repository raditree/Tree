import 'package:tree_protocol/tree_protocol.dart';

import '../util/liveness.dart';
import 'station_ids.dart';
import 'station_instance.dart';
import 'station_points.dart';
import 'station_runtime.dart';
import 'station_schema.dart';
import 'station_store.dart';

/// 站点中枢（M9 §3）：内置点位、插件自建站、订阅、插件下线注销、快照与落盘。
///
/// **站点类型四种，每类下有若干点位（point），每个点位是一个独立的全局实例**
/// （点位化，2026-10-01）：
///
/// - 广播站 3 个：`system.broadcast`（通用主题）/ `.tool.pre` / `.tool.post`
/// - 执行站 7 个（按命令族）：`system.execute.fs` / `.terminal` / `.agent` / `.ui` /
///   `.llm` / `.tool` / `.session`
/// - 中转站 6 个（每个各自唯一订阅者）：`system.relay.tool.pre` / `.tool.post` /
///   `.llm.handle` / `.llm.request` / `.context.compact` / `.prompt.system`
/// - 收集站 1 个：`plugin.tool.define`（**不预建**，见 [ensureBuiltinStations]）
///
/// 点位的类型 / 说明 / 命令 / 别名表在 `station_points.dart`（加点位只改那张表）。
/// **id 不含 team / mode**：team / agent / session / mode 是**每次交互携带的信封**
/// （消息 scope）与订阅声明，只在投递时用于匹配订阅者。
///
/// 为什么这样定（用户定稿语义）：
/// - 站点是**拦截点 / 触发点**，不是「某个 team 的站点」——team / agent / session /
///   mode 是**每次交互携带的信封**（消息 scope），只在投递时用于匹配订阅者；
/// - 站点按 team 复制会让站点数随团队数膨胀（一堆没人用的空壳），核心内部也更啰嗦；
/// - 全局化后**跨 team 的数据整合**天然可行（一趟收集能看到所有 team 的订阅者），
///   而隔离仍然成立：投递判定在 `StationIsolation.checkSubscriber`，
///   工具表可见性在 `PluginBus._visible`，两处都按 team fail-closed。
/// - 插件需要细粒度分隔时，正解是**插件自建站点**（[register]），不是让核心复制站点。
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

  /// 广播站·通用主题点位 id（`system.broadcast`）。
  static const String broadcastBaseId = StationHubIds.broadcast;

  /// 收集站（插件定义 tool，首个接入点）基础 id。
  static const String toolDefineBaseId = StationHubIds.collect;

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
  ///
  /// 非 final：[PluginBus] 构造后要把它换成"包了 UI 帧缓存"的那一层出口
  /// （见 `PluginBus._outbound`），否则前端重连时卡片槽位回不来。
  void Function(Map<String, dynamic> frame)? frameSink;

  /// 心跳间隔 I（默认 10s；测试可缩参）。
  final Duration heartbeatInterval;

  /// 连续丢失阈值 N（默认 3）。
  final int missThreshold;

  /// 活性窗口（I×N）：只在订阅者「无活性信息」时兜底，心跳在则续期。
  Duration get livenessWindow => heartbeatInterval * missThreshold;

  /// 活性探针（由总线在接线时注入：pluginId → 心跳判活状态）。
  StationLivenessProbe? livenessProbe;

  /// **执行站挂载钩子**（M9 Wave 3-I）：执行站实例被创建或从落盘恢复时调用。
  ///
  /// 「执行器只是执行站的一种挂载位置」——首命令集（fs.* / terminal.exec /
  /// agent.* / ui.push）的挂载位置由核心在这里接上；不接的话命令会以
  /// 「暂无挂载位置」显式失败（不静默）。
  void Function(ExecuteStation station)? onExecuteStation;

  /// 探测节拍（等待回包时轮询订阅者心跳的间隔）。
  final Duration livenessProbeInterval;

  final StationStore _store;
  final Map<String, StationInstance> _stations = <String, StationInstance>{};
  bool _loaded = false;

  /// 批量新建期间的落盘合并深度（见 [save]）：>0 时只置脏，批量结束统一写一次。
  int _saveSuspend = 0;

  /// 合并落盘期间是否发生过写入（有新建才写，没有就不写）。
  bool _saveDirtyWhileSuspended = false;

  /// 读盘（幂等；文件不存在 = 空表）。
  void load() {
    if (_loaded) return;
    _loaded = true;
    // 读侧迁移：旧格式（baseId@team@mode）与退役 id 在这里被归并到现役点位。
    // [log] 只报告"发生了什么"，不阻塞启动；归并结果立刻写回一次，此后幂等。
    final ({List<StationInstance> stations, bool migrated}) loaded = _store.load();
    int rebuilt = 0;
    for (final StationInstance station in loaded.stations) {
      // 内置 id 的类型以**点位表**为准：落盘写错了类型就按表重建（并记可读日志），
      // 否则该点位会静默失效（见 [_normalizeBuiltinPoint]）。
      final StationInstance normalized = _normalizeBuiltinPoint(station);
      if (!identical(normalized, station)) rebuilt++;
      _attach(normalized);
      _stations[normalized.id] = normalized;
    }
    if (loaded.migrated) {
      log?.call(
        '站点存储已迁移到点位 id：${_stations.length} 个实例'
        '（${_stations.keys.join('、')}）——每个接入点一个实例，不再按 team×mode 复制',
      );
    }
    // 迁移结果与"类型纠正"都要写回（此后幂等：文件里没有旧 id / 没有错类型就不会再触发）
    if (loaded.migrated || rebuilt > 0) save();
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

  /// 广播站·通用主题点位（系统自带；懒创建）。
  BroadcastStation? broadcastFor() =>
      broadcastPointFor(StationHubIds.broadcast);

  /// 按 id 取广播站点位（懒创建）。
  BroadcastStation? broadcastPointFor(String id) {
    final StationInstance? station = pointFor(id);
    return station is BroadcastStation ? station : null;
  }

  /// 按 id 取执行站点位（懒创建）。
  ExecuteStation? executePointFor(String id) {
    final StationInstance? station = pointFor(id);
    return station is ExecuteStation ? station : null;
  }

  /// **命令 → 所属执行站点位**（`station/command` 的分发依据；懒创建）。
  ///
  /// 命令不在任何点位里返回 null（白名单外，由调用方给可读错误）。
  ExecuteStation? executeForCommand(String command) {
    final StationPointSpec? spec = StationPoints.ownerOfCommand(command);
    if (spec == null) return null;
    return executePointFor(spec.id);
  }

  /// 按 id 取中转站点位（懒创建）。
  RelayStation? relayPointFor(String id) {
    final StationInstance? station = pointFor(id);
    return station is RelayStation ? station : null;
  }

  /// **按 id 取内置点位**（不存在则按点位表懒创建）。
  ///
  /// - 已在表中（落盘恢复的、或之前建过的）直接返回——包括**插件自建站**；
  /// - 内置点位 id 且尚未建 ⇒ 按 `StationPoints` 的定义创建并落盘；
  /// - 其它（未知 id）⇒ null，调用方给可读错误。
  ///
  /// 站点不按 team / agent 复制：**点位是全局唯一实例**，team / agent / session /
  /// mode 只在投递时用于匹配订阅者（见 `station_scope.dart`）。
  StationInstance? pointFor(String id) {
    load();
    final String key = id.trim();
    if (key.isEmpty) return null;
    final StationInstance? existing = _stations[key];
    if (existing != null) return existing;
    final StationPointSpec? spec = StationPoints.byId(key);
    if (spec == null) return null;
    final StationInstance created = _createPoint(spec);
    _register(created);
    return created;
  }

  /// 按点位定义创建一个内置实例。
  ///
  /// [subscribers] / [createdAt] 只在"纠正类型不符的落盘实例"时传入（见
  /// [_normalizeBuiltinPoint]）：正常创建是空的、`createdAt` 由构造器取当前时间。
  StationInstance _createPoint(
    StationPointSpec spec, {
    List<StationSubscriber> subscribers = const <StationSubscriber>[],
    int? createdAt,
  }) => switch (spec.kind) {
    StationKind.broadcast => BroadcastStation(
      id: spec.id,
      description: spec.description,
      maxSubscriptions: spec.maxSubscriptions,
      builtin: true,
      subscribers: List<StationSubscriber>.of(subscribers),
      createdAt: createdAt,
    ),
    StationKind.execute => ExecuteStation(
      id: spec.id,
      description: spec.description,
      maxSubscriptions: spec.maxSubscriptions,
      builtin: true,
      subscribers: List<StationSubscriber>.of(subscribers),
      createdAt: createdAt,
      commands: spec.commands,
    ),
    StationKind.relay => RelayStation(
      id: spec.id,
      description: spec.description,
      maxSubscriptions: spec.maxSubscriptions,
      builtin: true,
      subscribers: List<StationSubscriber>.of(subscribers),
      createdAt: createdAt,
    ),
    StationKind.collect => CollectStation(
      id: spec.id,
      description: spec.description,
      schema: toolDefinitionSchema,
      builtin: true,
      subscribers: List<StationSubscriber>.of(subscribers),
      createdAt: createdAt,
    ),
  };

  /// **内置点位的类型以点位表为准**：落盘实例的类型与表不符时按表重建。
  ///
  /// 为什么必须纠正：内置 id 是**权威**的（`system.relay.llm.handle` 就是一个中转
  /// 点位）。stations.yaml 被手改、旧文件残留、半截写入都可能让同一个 id 落成别的
  /// 类型；那时 [relayPointFor] 会返回 null ⇒ 四个 LLM 中转点位**全部静默回退系统
  /// 默认**，而插件用 `station_id` 订阅它还会拿到 `ok:true`（对方恰好可订阅）却永远
  /// 收不到请求——全程**零日志**，属于最难查的一类问题。
  ///
  /// 订阅的处理：类型不符时旧订阅本来就没投递过（订阅的是"另一个站"），这里**尽力
  /// 保留**——中转站只允许一个订阅者，多出来的显式丢弃并在日志里写明。
  StationInstance _normalizeBuiltinPoint(StationInstance station) {
    final StationPointSpec? spec = StationPoints.byId(station.id);
    if (spec == null || spec.kind == station.kind) return station;
    final List<StationSubscriber> all = List<StationSubscriber>.of(
      station.subscribers,
    );
    final bool uniqueSubscriber = spec.kind == StationKind.relay;
    final List<StationSubscriber> kept = uniqueSubscriber && all.length > 1
        ? all.sublist(0, 1)
        : all;
    log?.call(
      '内置点位 ${station.id} 的落盘类型是 ${station.kind.wire}，'
      '与点位表（${spec.kind.wire}）不符：按点位表重建为${spec.kind.label}；'
      '原订阅 ${all.length} 条'
      '${kept.length == all.length ? '已保留' : '保留 ${kept.length} 条（该点位只允许一个订阅者）'}'
      '——插件下次上线会重新声明订阅',
    );
    return _createPoint(
      spec,
      subscribers: kept,
      createdAt: station.createdAt > 0 ? station.createdAt : null,
    );
  }

  /// **确保全部内置点位存在**（16 个：广播 3 + 执行 7 + 中转 6；收集站除外）。
  ///
  /// 为什么需要这一步：[pointFor] 是**懒创建**（首次使用时才实例化）。按需开销为零
  /// 是好事，代价却是"没配插件 / 没人用过"时一个点位都没有——面板上就是
  /// 「站点（已建 0/4 类）」，与用户「站点默认设在系统中」的预期不符。核心在
  /// **站点接线处**（`CoreServer._wirePluginStations`）调用一次，点位因此启动即就位。
  ///
  /// **与 team / agent 无关**（用户定稿语义）：点位全局唯一，不随团队产生新实例。
  /// 新建 agent、新增 team 都不会、也不该让站点数变化。
  ///
  /// 幂等（重复启动的安全边界）：
  /// - 已存在的点位（本次启动从 stations.yaml **恢复**的，或之前调用已建的）直接跳过，
  ///   既不新建也不覆盖——所以重复调用不产生重复实例；
  /// - 没有新建就**不落盘**（[_saveSuspend] 合并成一次写），
  ///   所以重复启动既不改文件内容也不刷新文件时间。
  ///
  /// **为什么不预建收集站**（本波次的取舍，用户裁定）：收集站的 schema 就是
  /// **接入点定义的输入格式**（如 [toolDefinitionSchema]）。没有接入点就没有格式，
  /// 预建一个"空 schema"的收集站毫无意义——既过不了 [register] 的空 schema 校验，
  /// 也不会有任何订阅者按它产出。收集站一律由接入点在需要时用
  /// [toolDefineStationFor] 现建。
  ///
  /// 返回**本次新建**的点位 id（已存在的不在内；顺序 = `StationPoints.all` 的表顺序，
  /// 而 [stationList] 是**字典序**——别把两者当成同一个顺序）；空列表 = 纯幂等命中。
  List<String> ensureBuiltinStations() {
    load();
    final List<String> created = <String>[];
    // 一批预建只落一次盘（每个点位的懒创建都会 save 一次，不合并就是 16 次写）
    _saveSuspend++;
    try {
      // 全部内置点位（广播 3 + 执行 7 + 中转 6）预建；**收集站不预建**（见下）。
      for (final StationPointSpec spec in StationPoints.all) {
        if (spec.kind == StationKind.collect) continue;
        _ensureOneBuiltin(() => pointFor(spec.id), created);
      }
    } finally {
      _saveSuspend--;
      if (_saveDirtyWhileSuspended) {
        _saveDirtyWhileSuspended = false;
        save();
      }
    }
    return created;
  }

  /// 建一个内置站（若不存在），并把"这次真的新建了"记进 [created]。
  ///
  /// 用 id 是否新增来判断，而不是拿创建函数的返回值——[StationHub.station] 的
  /// 同名不同类型的防御分支会返回 null，那种情况不算新建。
  void _ensureOneBuiltin(
    StationInstance? Function() create,
    List<String> created,
  ) {
    final int before = _stations.length;
    final StationInstance? station = create();
    if (station != null && _stations.length > before) {
      created.add(station.id);
    }
  }

  /// 收集站「插件定义 tool」（系统自带；收集站的首个接入点；**全局唯一实例**）。
  ///
  /// 站点不分 team：核心内任何文件、任何时机的触发都命中这一个实例，
  /// 采集时携带 team / agent / session（消息 scope），由订阅者各自匹配。
  CollectStation? toolDefineStationFor() {
    load();
    const String id = toolDefineBaseId;
    final StationInstance? existing = _stations[id];
    if (existing is CollectStation) return existing;
    if (existing != null) return null;
    final CollectStation station = CollectStation(
      id: id,
      description: '收集站（系统自带）：插件按 schema 申报工具定义（名称/描述/参数/执行方式）',
      schema: toolDefinitionSchema,
      builtin: true,
    );
    _register(station);
    return station;
  }

  /// 插件自建站点（**只能注册既有四种类型**，不允许发明新类型）。
  ///
  /// id **必须带命名空间**：内置保留 id（`system.*` 与 `plugin.tool.define`）不得冒用，
  /// 插件自建站一律用 `plugin.{plugin_id}.` 前缀（如 `plugin.sample.relay.audit`）。
  /// 这条校验是**为插件自建站铺路**：站点全局化后，插件要按 team / agent 细分
  /// 处理只能自己建站，所以 id 归属必须可证明，否则任何插件都能顶掉别人的站点。
  ///
  /// 站点不再绑 scope（team / mode 是消息信封属性，不是站点属性），因此这里不再
  /// 校验 `station.scope`。
  ///
  /// 返回 null = 成功；否则返回可读中文原因。
  String? register(StationInstance station) {
    load();
    final String id = station.id.trim();
    if (id.isEmpty) {
      return '站点 id 不能为空';
    }
    if (_stations.containsKey(id)) {
      return '站点 id 已存在：$id';
    }
    final String? idError = checkSelfBuiltId(id);
    if (idError != null) {
      return idError;
    }
    if (station is CollectStation && station.schema.fields.isEmpty) {
      return '收集站必须定义 schema（输入格式），当前为空';
    }
    _register(station);
    return null;
  }

  /// 插件自建站 id 的命名空间校验（返回 null = 合法）。
  ///
  /// 规则：必须是 `plugin.` 开头（全部内置点位 id 与 `system.` 保留前缀一律不得冒用）。
  /// 用独立静态方法是为了让「创建时校验」与「从盘上恢复时校验」共用同一口径。
  static String? checkSelfBuiltId(String id) {
    if (StationHubIds.all.contains(id)) {
      return '站点 id「$id」是内置保留 id，插件不得注册';
    }
    if (id.startsWith('system.')) {
      return '站点 id「$id」占用系统保留前缀 system.（内置站专用）';
    }
    if (!id.startsWith('plugin.')) {
      return '插件自建站 id 必须以 plugin. 开头（如 plugin.sample.relay.audit），收到「$id」';
    }
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
    // 订阅声明：**空维度 = 通配**（空 team 作用于所有 team、空 mode 两种工作面都收），
    // 只有 mode 填了非法值才算错（拼错要报出来，不静默空转）。
    if (!subscriber.scope.isValidSubscriber) {
      return StationSubResult.rejected(
        '订阅者 scope 非法：mode_key 只能是 local | ssh，或留空表示通配',
        code: 'invalid_scope',
      );
    }
    return station.subscribe(subscriber, responder, replace: replace);
  }

  /// 注销一个站点（连带其订阅）；返回是否真的移除了。
  ///
  /// 只有**插件自建站**会被注销（内置站不允许——它们系统自带、随核心恒在）。
  /// 调用方负责先做归属校验（见 `PluginBus._selfBuiltOwnershipError`）。
  bool unregister(String stationId) {
    load();
    final StationInstance? station = _stations[stationId];
    if (station == null) return false;
    if (station.builtin) {
      log?.call('拒绝注销内置站点：$stationId（系统自带，随核心恒在）');
      return false;
    }
    _stations.remove(stationId);
    save();
    log?.call(
      '站点已注销：$stationId（连带 ${station.subscribers.length} 条订阅）',
    );
    return true;
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

  /// **把挂载位置接到全部执行站**（含落盘恢复的与将来新建的）。
  ///
  /// 幂等：挂载位置按 mountId 覆盖，重复接线不会叠加。
  void mountExecuteStations(void Function(ExecuteStation station) mounter) {
    load();
    onExecuteStation = mounter;
    for (final StationInstance station in _stations.values) {
      if (station is ExecuteStation) mounter(station);
    }
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
  ///
  /// **站点段不再按 team 过滤**（站点全局唯一，过滤恒真且会误导）：
  /// `teamId` 只用于实例段（插件实例的 scope），站点段的 team 视角由每条订阅者
  /// 的 `scope` + `subscribers_by_team` 承担——面板据此分组展示。
  ///
  /// 快照前先 [ensureBuiltinStations]：否则面板显示几条取决于"之前有没有人触发过
  /// 站点"（懒创建残留），同一个系统会时多时少。这里幂等、且只有新建才落盘，
  /// 所以不会因为"看一眼面板"而反复写文件。
  List<Map<String, dynamic>> snapshot({String? teamId}) {
    load();
    ensureBuiltinStations();
    return stationList()
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
  ///
  /// **合并落盘**：批量预建（[ensureBuiltinStations]）期间只置脏，由批量末尾统一
  /// 写一次——「重复启动不重复落盘」的另一半：已存在的站点根本不会再走到这里。
  void save() {
    if (!_loaded) return;
    if (_saveSuspend > 0) {
      _saveDirtyWhileSuspended = true;
      return;
    }
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
    if (station is ExecuteStation) {
      _ensureUiPushMount(station);
      onExecuteStation?.call(station);
    }
  }

  /// 内置 ui.push 挂载位置（**只挂在 `system.execute.ui` 点位上**）：复用 4.1 的
  /// card 槽位帧（不发明新帧）。
  ///
  /// 帧发到主 WS 广播（前端只在主连接上消费插件 UI 帧）；team_id 取自命令
  /// scope（1.2 隔离：槽位一律带 team_id）。
  void _ensureUiPushMount(ExecuteStation station) {
    if (station.id != StationHubIds.executeUi) return;
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
