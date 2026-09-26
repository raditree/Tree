import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_service.dart';
import 'websocket_service.dart';

// ==================== 数据模型（宽容解析：缺字段给默认值、坏条目跳过） ====================

/// 插件实例信息（快照条目 / `plugin_status` 增量条目）。
///
/// 字段口径见契约 v1.3 §15.1（与后端对齐；M9 起补健康度）：
/// `name` 为展示名（可能为空串，展示层回退 [pluginId]）；
/// `disabled_reason` = 启动/注册失败原因（正常时为空串）；
/// `health` / `missed_heartbeats` / `heartbeat_interval_s` / `degraded_reason`
/// 是 M9 §1.1 的**心跳判活**产物：`degraded` 表示**心跳连续丢失**，
/// **不是停用**——此时 `status` 仍是 `registered`（插件进程活着，只是不回应心跳）；
/// 缺失这些字段（旧核心 / 总开关关闭）时按「未知」处理，展示层不臆测。
class PluginInstanceInfo {
  /// 插件 ID（实例去重键的一部分）
  final String pluginId;

  /// 展示名（可能为空串）
  final String name;

  /// 实例粒度：team / agent / session（未知值原样保留）
  final String granularity;

  /// 实例 scope 四元组（宽容解析为 Map；缺失字段展示层视为空串）
  final Map<String, dynamic> scope;

  /// 生命周期状态：registered / disabled（增量合并只识别契约枚举）
  final String status;

  /// 最近心跳时间（epoch 秒；缺失为 null）
  final double? lastHeartbeat;

  /// 入站队列深度（缺失为 null）
  final int? queueDepth;

  /// 停用原因（启动/注册失败原因；为空时不渲染）
  final String disabledReason;

  /// 健康度（M9 §1.1）：ok / degraded / unavailable；缺失为**空串 = 未知**
  /// （未知值原样保留，展示层不崩、不臆测）。
  final String health;

  /// 连续丢失的心跳拍数（缺失为 null）；`isDegraded` 时通常 ≥ N=3
  final int? missedHeartbeats;

  /// 心跳间隔 I（秒；缺失为 null）——判活窗口 = I × N（前端按 I=10s / N=3 显示）
  final double? heartbeatIntervalS;

  /// 心跳降级原因（core 的 `degraded_reason` / 增量 `reason`；未降级为空串）
  final String degradedReason;

  /// 健康度取值：正常
  static const String healthOk = 'ok';

  /// 健康度取值：心跳连续丢失（**不是**停用）
  static const String healthDegraded = 'degraded';

  /// 健康度取值：宿主不可用（未启动 / 已断开）
  static const String healthUnavailable = 'unavailable';

  const PluginInstanceInfo({
    required this.pluginId,
    this.name = '',
    this.granularity = '',
    this.scope = const <String, dynamic>{},
    this.status = '',
    this.lastHeartbeat,
    this.queueDepth,
    this.disabledReason = '',
    this.health = '',
    this.missedHeartbeats,
    this.heartbeatIntervalS,
    this.degradedReason = '',
  });

  /// 是否处于「心跳降级」（M9 §1.1）：连续 N 拍没收到心跳。
  ///
  /// 语义边界：降级**不等于**停用——插件仍注册、仍在跑（只是不回应心跳）；
  /// 因此这里要求 `status == 'registered'`，停用的实例走「停用原因」那条线。
  bool get isDegraded => health == healthDegraded && status != 'disabled';

  /// 是否已知健康度（空串 = 旧核心 / 未提供，展示层不据此渲染降级角标）。
  bool get hasHealth => health.isNotEmpty;

  /// 宽容解析单条实例；无法使用（非 Map / 缺 plugin_id）时返回 null（跳过）。
  static PluginInstanceInfo? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Map<String, dynamic> m = Map<String, dynamic>.from(raw);
    final String pluginId = (m['plugin_id'] ?? '').toString();
    if (pluginId.isEmpty) {
      return null;
    }
    Map<String, dynamic> scope = const <String, dynamic>{};
    final Object? rawScope = m['scope'];
    if (rawScope is Map) {
      scope = Map<String, dynamic>.from(rawScope);
    }
    final Object? rawHeartbeat = m['last_heartbeat'];
    final Object? rawQueueDepth = m['queue_depth'];
    // M9 §1.1 健康度字段：宽容解析（类型不符视为缺失，未知字符串原样保留）
    final Object? rawHealth = m['health'];
    final Object? rawMissed = m['missed_heartbeats'];
    final Object? rawInterval = m['heartbeat_interval_s'];
    return PluginInstanceInfo(
      pluginId: pluginId,
      name: (m['name'] ?? '').toString(),
      granularity: (m['granularity'] ?? '').toString(),
      scope: scope,
      status: (m['status'] ?? '').toString(),
      lastHeartbeat: rawHeartbeat is num ? rawHeartbeat.toDouble() : null,
      queueDepth: rawQueueDepth is num ? rawQueueDepth.toInt() : null,
      disabledReason: (m['disabled_reason'] ?? '').toString(),
      health: rawHealth is String ? rawHealth : '',
      missedHeartbeats: rawMissed is num ? rawMissed.toInt() : null,
      heartbeatIntervalS: rawInterval is num ? rawInterval.toDouble() : null,
      degradedReason: (m['degraded_reason'] ?? '').toString(),
    );
  }

  /// 实例去重键：plugin_id + scope 三元（team/agent/session；缺失字段视为空串）。
  String get key => keyOf(pluginId, scope);

  /// 组合实例键（供增量合并与快照条目对齐）。
  static String keyOf(String pluginId, Map<String, dynamic> scope) {
    String f(Object? v) => v == null ? '' : v.toString();
    return '$pluginId|${f(scope['team_id'])}'
        '|${f(scope['agent_id'])}|${f(scope['session_id'])}';
  }

  /// 复制并覆盖可变字段（增量合并用；null 表示保持原值）。
  ///
  /// 注意：清空一个字符串字段要传**空串**（如 `degradedReason: ''`），
  /// 传 null 是"保持原值"——降级恢复时必须显式清零，否则角标会残留。
  PluginInstanceInfo copyWith({
    String? name,
    String? status,
    double? lastHeartbeat,
    int? queueDepth,
    String? disabledReason,
    String? health,
    int? missedHeartbeats,
    double? heartbeatIntervalS,
    String? degradedReason,
  }) {
    return PluginInstanceInfo(
      pluginId: pluginId,
      name: name ?? this.name,
      granularity: granularity,
      scope: scope,
      status: status ?? this.status,
      lastHeartbeat: lastHeartbeat ?? this.lastHeartbeat,
      queueDepth: queueDepth ?? this.queueDepth,
      disabledReason: disabledReason ?? this.disabledReason,
      health: health ?? this.health,
      missedHeartbeats: missedHeartbeats ?? this.missedHeartbeats,
      heartbeatIntervalS: heartbeatIntervalS ?? this.heartbeatIntervalS,
      degradedReason: degradedReason ?? this.degradedReason,
    );
  }
}

/// 站点订阅项（`stations[].subscriptions[]` 单条）。
class PluginStationSub {
  /// 订阅方实例键（展示为主）
  final String subscriber;

  /// 订阅插件 ID
  final String pluginId;

  /// 订阅粒度
  final String granularity;

  /// 订阅 scope 四元组
  final Map<String, dynamic> scope;

  /// 站级等待超时（秒；缺失为 null）
  final double? timeoutS;

  const PluginStationSub({
    this.subscriber = '',
    this.pluginId = '',
    this.granularity = '',
    this.scope = const <String, dynamic>{},
    this.timeoutS,
  });

  /// 宽容解析单条订阅；无法使用（非 Map）时返回 null（跳过）。
  static PluginStationSub? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Map<String, dynamic> m = Map<String, dynamic>.from(raw);
    Map<String, dynamic> scope = const <String, dynamic>{};
    final Object? rawScope = m['scope'];
    if (rawScope is Map) {
      scope = Map<String, dynamic>.from(rawScope);
    }
    final Object? rawTimeout = m['timeout_s'];
    return PluginStationSub(
      subscriber: (m['subscriber'] ?? '').toString(),
      pluginId: (m['plugin_id'] ?? '').toString(),
      granularity: (m['granularity'] ?? '').toString(),
      scope: scope,
      timeoutS: rawTimeout is num ? rawTimeout.toDouble() : null,
    );
  }
}

/// 站点信息（M9 §3 站点体系：类型 + scope 绑定 + 订阅 + 分类计数 + 在飞等待）。
///
/// 站点 = **持久化实例**，四类：广播站 / 执行站 / 中转站 / 收集站。核心的
/// `StationInstance.describe()` 已给出展示需要的全部字段，前端不再自己猜类型：
/// `kind`（线名）/ `kind_label`（中文名）/ `builtin`（是否系统自带）/
/// `subscriber_count`（订阅数，执行站恒为 0——它不支持订阅）。
///
/// 宽容解析：旧核心没有这些字段时全部按"未知"处理（空串 / false / 回退订阅列表
/// 长度），展示层不臆测、不崩。
class PluginStationInfo {
  /// 站 ID（含 scope 归属，如 `system.broadcast@team-1@local`）
  final String stationId;

  /// 站点类型线名：broadcast / execute / relay / collect（缺失为空串 = 未知）
  final String kind;

  /// 站点类型中文名（核心给的 `kind_label`；缺失为空串）
  final String kindLabel;

  /// 站点说明（核心给的 `description`；缺失为空串）
  final String description;

  /// 站点绑定的 scope（team_id / mode_key 是关键维度；缺失字段展示层视为空串）
  final Map<String, dynamic> scope;

  /// 是否系统自带（内置三站为 true；插件自建为 false；缺失按 false）
  final bool builtin;

  /// 订阅者数量（核心给的 `subscriber_count`；缺失回退订阅列表长度）
  final int subscriberCount;

  /// 订阅列表（站 × scope 键位唯一；当前通常 1 项）
  final List<PluginStationSub> subscriptions;

  /// 分类计数（仅保留数值型；未知键宽容保留、展示层裁剪）
  final Map<String, int> counts;

  /// 在飞等待数（`gauges.waits_in_flight`；缺失为 null）
  final int? waitsInFlight;

  const PluginStationInfo({
    required this.stationId,
    this.kind = '',
    this.kindLabel = '',
    this.description = '',
    this.scope = const <String, dynamic>{},
    this.builtin = false,
    this.subscriberCount = 0,
    this.subscriptions = const <PluginStationSub>[],
    this.counts = const <String, int>{},
    this.waitsInFlight,
  });

  /// 展示用的中文类型名：核心给的 `kind_label` 优先；旧核心没给时按线名 `kind`
  /// 兜底；两者都认不出 ⇒ 空串（**不猜**，卡片上就不显示类型标签）。
  String get displayKindLabel {
    if (kindLabel.isNotEmpty) {
      return kindLabel;
    }
    switch (kind) {
      case 'broadcast':
        return '广播站';
      case 'execute':
        return '执行站';
      case 'relay':
        return '中转站';
      case 'collect':
        return '收集站';
      default:
        return '';
    }
  }

  /// 宽容解析单条站；无法使用（非 Map / 缺 station_id）时返回 null（跳过）。
  static PluginStationInfo? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Map<String, dynamic> m = Map<String, dynamic>.from(raw);
    final String stationId = (m['station_id'] ?? '').toString();
    if (stationId.isEmpty) {
      return null;
    }
    final List<PluginStationSub> subs = <PluginStationSub>[];
    final Object? rawSubs = m['subscriptions'];
    if (rawSubs is List) {
      for (final Object? item in rawSubs) {
        final PluginStationSub? sub = PluginStationSub.tryParse(item);
        if (sub != null) {
          subs.add(sub);
        }
      }
    }
    Map<String, dynamic> scope = const <String, dynamic>{};
    final Object? rawScope = m['scope'];
    if (rawScope is Map) {
      scope = Map<String, dynamic>.from(rawScope);
    }
    final Map<String, int> counts = <String, int>{};
    final Object? rawCounts = m['counts'];
    if (rawCounts is Map) {
      rawCounts.forEach((Object? k, Object? v) {
        if (k is String && v is num) {
          counts[k] = v.toInt();
        }
      });
    }
    int? waits;
    final Object? rawGauges = m['gauges'];
    if (rawGauges is Map && rawGauges['waits_in_flight'] is num) {
      waits = (rawGauges['waits_in_flight'] as num).toInt();
    }
    // 订阅数以核心给的为准（执行站不支持订阅，恒 0）；缺失回退订阅列表长度
    final Object? rawSubscriberCount = m['subscriber_count'];
    final int subscriberCount = rawSubscriberCount is num
        ? rawSubscriberCount.toInt()
        : subs.length;
    return PluginStationInfo(
      stationId: stationId,
      kind: (m['kind'] ?? '').toString(),
      kindLabel: (m['kind_label'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      scope: scope,
      builtin: m['builtin'] == true,
      subscriberCount: subscriberCount,
      subscriptions: subs,
      counts: counts,
      waitsInFlight: waits,
    );
  }
}

/// 看门狗概要（`watchdog` 块）。
class PluginWatchdogInfo {
  /// 活跃 run 数
  final int activeRuns;

  /// 判死数（M9 起心跳巡检**只标健康度、不终止插件**，因此恒为 0）
  final int judgedDead;

  /// 心跳降级实例数（`degraded_count`；缺失为 null = 未知）
  final int? degradedCount;

  /// 巡检间隔（秒；`interval_s`，即心跳间隔 I；缺失为 null）
  final double? intervalS;

  /// 判降级阈值（`miss_threshold`，即连续丢失拍数 N；缺失为 null）
  final int? missThreshold;

  const PluginWatchdogInfo({
    this.activeRuns = 0,
    this.judgedDead = 0,
    this.degradedCount,
    this.intervalS,
    this.missThreshold,
  });

  /// 宽容解析；非 Map 返回 null。
  static PluginWatchdogInfo? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Map<String, dynamic> m = Map<String, dynamic>.from(raw);
    int i(Object? v) => v is num ? v.toInt() : 0;
    final Object? rawDegraded = m['degraded_count'];
    final Object? rawInterval = m['interval_s'];
    final Object? rawThreshold = m['miss_threshold'];
    return PluginWatchdogInfo(
      activeRuns: i(m['active_runs']),
      judgedDead: i(m['judged_dead']),
      degradedCount: rawDegraded is num ? rawDegraded.toInt() : null,
      intervalS: rawInterval is num ? rawInterval.toDouble() : null,
      missThreshold: rawThreshold is num ? rawThreshold.toInt() : null,
    );
  }
}

/// 插件体系只读快照（`GET /api/plugin/snapshot` 的解析结果）。
class PluginSnapshot {
  /// 总开关状态（关闭时后端仍返回 200 + false + 空集）
  final bool enabled;

  /// 快照生成时间（epoch 秒；缺失为 null）
  final double? generatedAt;

  /// 实例列表（坏条目已跳过）
  final List<PluginInstanceInfo> instances;

  /// 站点列表（四类内置站 + 插件自建站；坏条目已跳过）
  final List<PluginStationInfo> stations;

  /// 看门狗概要（缺失为 null）
  final PluginWatchdogInfo? watchdog;

  /// 配置摘要（展示层按白名单裁剪）
  final Map<String, dynamic> config;

  /// 插件配置文件路径（`config.path`；旧核心 / 未接入总线时为空串）。
  ///
  /// 面板用它回答用户最常问的两件事：「插件配在哪」「改完怎么生效」——
  /// plugins.yaml 是用户可以直接手改的文件，路径必须在界面上看得见。
  /// 缺失就空串，展示层跳过那一行（不臆测路径）。
  final String pluginConfigPath;

  const PluginSnapshot({
    this.enabled = false,
    this.generatedAt,
    this.instances = const <PluginInstanceInfo>[],
    this.stations = const <PluginStationInfo>[],
    this.watchdog,
    this.config = const <String, dynamic>{},
    this.pluginConfigPath = '',
  });

  /// 宽容解析完整快照：缺字段给默认值、坏条目跳过、未知字段忽略。
  factory PluginSnapshot.fromJson(Map<String, dynamic> raw) {
    final List<PluginInstanceInfo> instances = <PluginInstanceInfo>[];
    final Object? rawInstances = raw['instances'];
    if (rawInstances is List) {
      for (final Object? item in rawInstances) {
        final PluginInstanceInfo? e = PluginInstanceInfo.tryParse(item);
        if (e != null) {
          instances.add(e);
        }
      }
    }
    final List<PluginStationInfo> stations = <PluginStationInfo>[];
    final Object? rawStations = raw['stations'];
    if (rawStations is List) {
      for (final Object? item in rawStations) {
        final PluginStationInfo? e = PluginStationInfo.tryParse(item);
        if (e != null) {
          stations.add(e);
        }
      }
    }
    final Object? rawGenerated = raw['generated_at'];
    final Object? rawConfig = raw['config'];
    final Map<String, dynamic> config = rawConfig is Map
        ? Map<String, dynamic>.from(rawConfig)
        : const <String, dynamic>{};
    // 配置路径：新核心给 config.path；老核心/别的生产方可能给顶层 plugin_config。
    // 两个都没有 ⇒ 空串（面板跳过"插件配置在…"那一行）。
    final String rawPath = (config['path'] ?? raw['plugin_config'] ?? '')
        .toString()
        .trim();
    return PluginSnapshot(
      enabled: raw['enabled'] == true,
      generatedAt: rawGenerated is num ? rawGenerated.toDouble() : null,
      instances: instances,
      stations: stations,
      watchdog: PluginWatchdogInfo.tryParse(raw['watchdog']),
      config: config,
      pluginConfigPath: rawPath,
    );
  }

  /// 复制并覆盖实例列表（增量合并用）。
  PluginSnapshot copyWith({List<PluginInstanceInfo>? instances}) {
    return PluginSnapshot(
      enabled: enabled,
      generatedAt: generatedAt,
      instances: instances ?? this.instances,
      stations: stations,
      watchdog: watchdog,
      config: config,
      pluginConfigPath: pluginConfigPath,
    );
  }
}

// ==================== 监控服务 ====================

/// 插件监控服务（右栏「插件」面板数据源；M1 只读）。
///
/// 数据两条路径（契约 v1.3 §15.1 / §15.4）：
/// 1. 快照——`GET /api/plugin/snapshot`：打开面板 / 重连 / 手动刷新时拉取；
/// 2. 增量——WS `plugin_status`：合并 registered / disabled / destroyed，
///    并在 registered 上叠加 M9 §1.1 的**健康度**（health / missed_heartbeats /
///    heartbeat_interval_s / degraded_reason）；
///    未知消息类型、未知 status、畸形载荷一律忽略（防御式解析）。
///
/// 一致性策略：**快照为准**（事件尽力而为、最终一致）；断连重连后自动重拉。
/// 前端薄：仅"搬运 + 展示状态"，不做任何策略判断；不修改现有 WS 协议。
class PluginMonitorService extends ChangeNotifier {
  PluginMonitorService._();

  static final PluginMonitorService instance = PluginMonitorService._();

  /// 测试专用实例（不共享单例状态）。
  @visibleForTesting
  factory PluginMonitorService.forTesting() => PluginMonitorService._();

  /// 快照拉取函数（测试注入点；默认走 [ApiService.getPluginSnapshot]）。
  @visibleForTesting
  Future<Map<String, dynamic>> Function({String? teamId}) snapshotFetcher =
      ApiService.getPluginSnapshot;

  PluginSnapshot? _snapshot;
  bool _connected = false;
  bool _loading = false;
  String? _error;
  String _teamId = '';
  int _refs = 0;
  bool _hasConnectedBefore = false;
  WebSocketService? _ws;

  /// 最近一次成功解析的快照（未成功拉取前为 null）。
  PluginSnapshot? get snapshot => _snapshot;

  /// WS 连接态（false = 断连/重连中；面板据此显示"断连态"，区分于"空态"）。
  bool get connected => _connected;

  /// 是否正在拉取快照。
  bool get loading => _loading;

  /// 最近一次拉取失败的面向用户错误信息（成功时清空；不覆盖旧快照）。
  String? get error => _error;

  /// 面板可见期间调用（引用计数）；首次调用建立 WS 监听并拉取快照。
  Future<void> start({String teamId = ''}) async {
    _refs++;
    _teamId = teamId;
    if (_ws == null) {
      final WebSocketService ws = WebSocketService();
      ws.onMessage = handleMessage;
      ws.onConnectionChange = handleConnectionChange;
      _ws = ws;
      final String? token = ApiService.token;
      if (token != null && token.isNotEmpty) {
        ws.connect(token);
      }
    }
    await refresh();
  }

  /// 面板关闭时调用；引用计数归零后断开监听连接（保留最近快照供下次秒开）。
  void stop() {
    if (_refs > 0) {
      _refs--;
    }
    if (_refs > 0) {
      return;
    }
    final WebSocketService? ws = _ws;
    _ws = null;
    ws?.disconnect();
    _connected = false;
    _hasConnectedBefore = false;
    notifyListeners();
  }

  /// 更新团队过滤（面板上下文切换时调用；变化时重拉快照）。
  void setTeam(String teamId) {
    if (_teamId == teamId) {
      return;
    }
    _teamId = teamId;
    if (_refs > 0) {
      unawaited(refresh());
    }
  }

  /// 拉取快照（打开 / 重连 / 手动刷新）。失败时保留旧快照并置 [error]。
  Future<void> refresh() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final Map<String, dynamic> data = await snapshotFetcher(
        teamId: _teamId.isEmpty ? null : _teamId,
      );
      _snapshot = PluginSnapshot.fromJson(data);
      _error = null;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 合并 WS 增量消息（由 WS 监听回调驱动；测试可直接调用）。
  ///
  /// 防御式：未知消息类型 / 畸形 data / 空 plugin_id / 未知 status 一律忽略；
  /// 快照未就绪时忽略增量（快照为权威来源）。
  ///
  /// 健康度（M9 §1.1）：`health == 'degraded'` 时 **status 仍是 registered**
  /// （核心口径：插件活着，只是心跳连续丢失），因此合并结果绝不能落成"停用"。
  void handleMessage(Map<String, dynamic> data) {
    final Object? rawType = data['type'];
    if (rawType is! String || rawType != 'plugin_status') {
      return; // 未知类型忽略（含非字符串 type）
    }
    final Object? raw = data['data'];
    if (raw is! Map) {
      return;
    }
    final Map<String, dynamic> d = Map<String, dynamic>.from(raw);
    final String pluginId = (d['plugin_id'] ?? '').toString();
    if (pluginId.isEmpty) {
      return;
    }
    Map<String, dynamic> scope = const <String, dynamic>{};
    final Object? rawScope = d['scope'];
    if (rawScope is Map) {
      scope = Map<String, dynamic>.from(rawScope);
    }
    // 团队过滤：仅在双方都有 team_id 时生效（缺失不拒绝；快照兜底）
    if (_teamId.isNotEmpty) {
      final String eventTeam = (scope['team_id'] ?? '').toString();
      if (eventTeam.isNotEmpty && eventTeam != _teamId) {
        return;
      }
    }
    final String status = (d['status'] ?? '').toString();
    final String reason = (d['reason'] ?? '').toString();
    final Object? rawTs = d['ts'];
    final double? ts = rawTs is num ? rawTs.toDouble() : null;
    // M9 §1.1 健康度增量：`health` 缺失 ≠ 正常，而是"本次增量没说" ⇒ 保持原值。
    // 注意 `reason` 是**歧义字段**：disabled 时是停用原因，registered+degraded 时
    // 是心跳降级原因——只有 `health` 能区分该往哪个字段落，不能只看 reason。
    final Object? rawHealth = d['health'];
    final String? health = rawHealth is String && rawHealth.isNotEmpty
        ? rawHealth
        : null;
    final Object? rawMissed = d['missed_heartbeats'];
    final int? missed = rawMissed is num ? rawMissed.toInt() : null;
    final Object? rawInterval = d['heartbeat_interval_s'];
    final double? interval = rawInterval is num ? rawInterval.toDouble() : null;

    final PluginSnapshot? snap = _snapshot;
    if (snap == null) {
      return; // 快照未就绪：忽略增量（以快照为准）
    }

    final List<PluginInstanceInfo> list = List<PluginInstanceInfo>.of(
      snap.instances,
    );
    final String key = PluginInstanceInfo.keyOf(pluginId, scope);
    final int idx = list.indexWhere((PluginInstanceInfo e) => e.key == key);
    switch (status) {
      case 'registered':
        // 心跳降级**不改 status**（核心就是这么发的：status 仍 registered）：
        // 只落健康度 / 丢失计数 / 降级原因，避免前端把降级误判成"停用"。
        if (idx >= 0) {
          list[idx] = list[idx].copyWith(
            status: 'registered',
            disabledReason: '',
            lastHeartbeat: ts ?? list[idx].lastHeartbeat,
            health: health,
            // 明确报 ok 却没带丢失计数 ⇒ 视为已清零（核心的恢复增量会带 0）
            missedHeartbeats:
                missed ?? (health == PluginInstanceInfo.healthOk ? 0 : null),
            heartbeatIntervalS: interval,
            degradedReason: health == null
                ? null
                : (health == PluginInstanceInfo.healthDegraded ? reason : ''),
          );
        } else {
          list.add(
            PluginInstanceInfo(
              pluginId: pluginId,
              scope: scope,
              status: 'registered',
              lastHeartbeat: ts,
              health: health ?? '',
              missedHeartbeats: missed,
              heartbeatIntervalS: interval,
              degradedReason: health == PluginInstanceInfo.healthDegraded
                  ? reason
                  : '',
            ),
          );
        }
        break;
      case 'disabled':
        if (idx >= 0) {
          list[idx] = list[idx].copyWith(
            status: 'disabled',
            disabledReason: reason,
            lastHeartbeat: ts ?? list[idx].lastHeartbeat,
            // 核心推 disabled 前会先断开宿主：快照口径即 unavailable。
            // 停用不再谈"心跳降级"，降级文案一并清掉（别和停用原因混淆）。
            health: health ?? PluginInstanceInfo.healthUnavailable,
            missedHeartbeats: missed ?? 0,
            heartbeatIntervalS: interval,
            degradedReason: '',
          );
        }
        break;
      case 'destroyed':
        if (idx >= 0) {
          list.removeAt(idx);
        }
        break;
      default:
        return; // 未知 status 忽略
    }
    _snapshot = snap.copyWith(instances: list);
    notifyListeners();
  }

  /// WS 连接态变化（由 WS 监听回调驱动；测试可直接调用）。
  ///
  /// 首次连接由 [start] 负责拉取；断连后重连（false→true）自动重拉快照。
  void handleConnectionChange(bool connected) {
    final bool was = _connected;
    _connected = connected;
    if (connected && !was && _hasConnectedBefore) {
      unawaited(refresh()); // 重连后重拉（快照为准）
    }
    if (connected) {
      _hasConnectedBefore = true;
    }
    notifyListeners();
  }
}
