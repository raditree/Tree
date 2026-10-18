import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_service.dart';
import 'websocket_service.dart';

// ==================== 数据模型（宽容解析：缺字段给默认值、坏条目跳过） ====================

/// 插件工具简项（`instances[].tools[]` 单条：名称 + 一行说明）。
///
/// 插件详情页要列出“这个插件能给 agent 用什么”，而工具表是总线对账出来的**运行态**
/// （插件没启动就是空表），所以它跟在实例上而不是配置上。
class PluginToolBrief {
  /// 工具名（不含 `plugin__<id>__` 前缀）
  final String name;

  /// 一行说明（核心未给时为空串，展示层只显名称）
  final String description;

  const PluginToolBrief({required this.name, this.description = ''});

  /// 宽容解析单条；非 Map / 无名时返回 null（跳过）。
  static PluginToolBrief? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final String name = (raw['name'] ?? '').toString();
    if (name.isEmpty) return null;
    return PluginToolBrief(
      name: name,
      description: (raw['description'] ?? '').toString(),
    );
  }
}

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

  /// 插件**介绍**（plugins.yaml 里的 `description`；空串 = 未提供）。
  ///
  /// 详情页的“插件介绍”读它。它来自配置而不是握手，所以**启动失败的插件也有**——
  /// 那正是最需要说明的时候。
  final String description;

  /// 当前注册的工具（运行态；未启动 / 旧核心 = 空表）
  final List<PluginToolBrief> tools;

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

  /// **生命周期阶段**（20261015-hot-restart 阶段 2 新增的第三个轴）：
  /// `stopped` / `booting` / `ready` / `restarting` / `suspended` / `failed`；
  /// 缺失为**空串 = 未知**（旧核心根本不发这个键，展示层不崩、不臆测）。
  ///
  /// **三个轴各管各的，谁也不得吃掉谁**（这是文案纪律，不只是字段纪律）：
  /// **活性看 [health]、启停看 [status]、阶段看 [lifecycle]**。举两个真实会发生的组合：
  /// - `restarting` + `registered` + `ok`：插件正在热重启，对外仍是正常状态（核心
  ///   替它有界暂存站点请求），此时**绝不能**渲染成“已停用”或“降级”；
  /// - `ready` + `registered` + `degraded`：进程好好的、只是几拍没回心跳（阶段 2 前就存在）。
  final String lifecycle;

  /// 当前**代际**（第几世；每次启动 +1；缺失为 null）。
  ///
  /// 为什么面板要显示它：重启后面板上的名字没变，但“它是同一个进程”已经变了；
  /// 没有代际就分不清“这个 ready 是刚起来的那个还是上一世残留的读数”。
  final int? generation;

  /// 健康度取值：正常
  static const String healthOk = 'ok';

  /// 健康度取值：心跳连续丢失（**不是**停用）
  static const String healthDegraded = 'degraded';

  /// 健康度取值：宿主不可用（未启动 / 已断开）
  static const String healthUnavailable = 'unavailable';

  /// 生命周期取值：重启中（旧实例在转储或已退、新实例未就绪）
  static const String lifecycleRestarting = 'restarting';

  /// 生命周期取值：已挂起（进程已退，可续跑状态已转储给核心）
  static const String lifecycleSuspended = 'suspended';

  /// 生命周期取值：启动中（进程已拉起，握手或首次 tools/list 未完）
  static const String lifecycleBooting = 'booting';

  /// 生命周期取值：就绪
  static const String lifecycleReady = 'ready';

  /// 生命周期取值：失败（启动失败 / 通道断裂 / 判死）
  static const String lifecycleFailed = 'failed';

  /// 是否处于「暂时不可用但工作安排上是暂时性」的那一段（核心侧同口径：
  /// `PluginLifecycleState.isTemporarilyUnavailable`）。
  ///
  /// 面板用它说明“在等它回来”而不是“它坏了”；但**徽章文案仍逐态给**（重启中 /
  /// 已挂起 / 启动中），因为这三件事对用户的下一步动作不同。
  bool get isTemporarilyUnavailable =>
      lifecycle == lifecycleRestarting ||
      lifecycle == lifecycleSuspended ||
      lifecycle == lifecycleBooting;

  const PluginInstanceInfo({
    required this.pluginId,
    this.name = '',
    this.description = '',
    this.tools = const <PluginToolBrief>[],
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
    this.lifecycle = '',
    this.generation,
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
    // 生命周期与代际：**新增的可选键**（旧核心没有 ⇒ 空/ null，不臆测）
    final Object? rawLifecycle = m['lifecycle'];
    final Object? rawGeneration = m['generation'];
    final List<PluginToolBrief> tools = <PluginToolBrief>[];
    final Object? rawTools = m['tools'];
    if (rawTools is List) {
      for (final Object? item in rawTools) {
        final PluginToolBrief? tool = PluginToolBrief.tryParse(item);
        if (tool != null) {
          tools.add(tool);
        }
      }
    }
    return PluginInstanceInfo(
      pluginId: pluginId,
      name: (m['name'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      tools: tools,
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
      lifecycle: rawLifecycle is String ? rawLifecycle : '',
      generation: rawGeneration is num ? rawGeneration.toInt() : null,
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
    String? lifecycle,
    int? generation,
  }) {
    return PluginInstanceInfo(
      pluginId: pluginId,
      name: name ?? this.name,
      // 介绍与工具是**快照**才带的字段，增量帧里没有 ⇒ 原样保留，
      // 不能让一次心跳增量把详情页讲空。
      description: description,
      tools: tools,
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
      // 生命周期与代际同样是「增量没说 ⇒ 保持原值」：不能让一次不带 lifecycle 的
      // 旧口径增量把阶段从面板上抹掉（那会「重启中」闪一下又变成就绪）。
      lifecycle: lifecycle ?? this.lifecycle,
      generation: generation ?? this.generation,
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

  /// 是否被站点所有者**禁用**（true = 订阅关系保留但触发时不投递）。
  ///
  /// 旧核心没这个字段 ⇒ false（按“未禁用”展示，不臆测）。
  final bool disabled;

  const PluginStationSub({
    this.subscriber = '',
    this.pluginId = '',
    this.granularity = '',
    this.scope = const <String, dynamic>{},
    this.timeoutS,
    this.disabled = false,
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
      disabled: m['disabled'] == true,
    );
  }
}

/// 站点信息（M9 §3 站点体系：类型 + 订阅 + 分类计数 + 在飞等待）。
///
/// 站点**全局唯一**（id 是类型常量，不绑 team / mode）；team 视角看
/// [subscribersByTeam]（订阅声明里的归属），不再看站点自身。
///
/// 站点 = **持久化实例**，四类：广播站 / 执行站 / 中转站 / 收集站。核心的
/// `StationInstance.describe()` 已给出展示需要的全部字段，前端不再自己猜类型：
/// `kind`（线名）/ `kind_label`（中文名）/ `builtin`（是否系统自带）/
/// `subscriber_count`（订阅数，执行站恒为 0——它不支持订阅）。
///
/// 宽容解析：旧核心没有这些字段时全部按"未知"处理（空串 / false / 回退订阅列表
/// 长度），展示层不臆测、不崩。
class PluginStationInfo {
  /// 站 ID（**全局常量**，如 `system.broadcast` / `plugin.tool.define`；
  /// 旧核心可能给带归属后缀的 `system.broadcast@team-1@local`——两者都按字符串显示）
  final String stationId;

  /// 站点类型线名：broadcast / execute / relay / collect（缺失为空串 = 未知）
  final String kind;

  /// 站点类型中文名（核心给的 `kind_label`；缺失为空串）
  final String kindLabel;

  /// 站点说明（核心给的 `description`；缺失为空串）
  final String description;

  /// 站点**详细介绍**（`readme`）：插件自建站必填，内置点位没单独写时核心已回落
  /// 到 `description`，所以这一项永远可用。面板的「站点详情页」读它。
  final String readme;

  /// 是否**对外共享**（自建站默认私有；true = 别的插件可按 `allowed_plugins` 订阅与触发）
  final bool shared;

  /// 站点**启用态**（C 起面板可写；缺键 / 旧核心 = true = 启用）。
  ///
  /// 停用只是"四类触发的第一道闸"（核心计 `skipped_disabled` 并给可读原因），
  /// 订阅关系与配置原样保留——所以详情页那颗开关的文案是「启用 / 停用」，不是「删除」。
  final bool enabled;

  /// 共享白名单（**空 = 所有插件都能用**；只在 [shared] 为 true 时参与判定）
  final List<String> allowedPlugins;

  /// 站点**自定义配置**（由建站一方定义字段；面板「其他」区展示与编辑）
  final Map<String, dynamic> config;

  /// 可订阅插件数量上限（`max_subscriptions`；旧核心缺失为 null = 未知）
  final int? maxSubscriptions;

  /// 站点绑定的 scope（team_id / mode_key 是关键维度；缺失字段展示层视为空串）
  final Map<String, dynamic> scope;

  /// 是否系统自带（内置三站为 true；插件自建为 false；缺失按 false）
  final bool builtin;

  /// 订阅者数量（核心给的 `subscriber_count`；缺失回退订阅列表长度）
  final int subscriberCount;

  /// 订阅列表（订阅者身份 = plugin_id + 声明 scope；全局站点上通常只有 1 项，
  /// 广播站 / 收集站可多条）
  final List<PluginStationSub> subscriptions;

  /// 订阅者按 **team** 分组（站点全局化后的 team 视角）。
  ///
  /// 站点只有一个、不绑 team，所以"这个团队有哪些订阅者"必须由订阅声明回答：
  /// 形状 `{team_id: {count, plugin_ids: [...]}}`。旧核心没有该字段 ⇒ 空表，
  /// 面板退回只显示订阅总数（不臆测）。
  final Map<String, int> subscribersByTeam;

  /// 分类计数（仅保留数值型；未知键宽容保留、展示层裁剪）
  final Map<String, int> counts;

  /// 在飞等待数（`gauges.waits_in_flight`；缺失为 null）
  final int? waitsInFlight;

  const PluginStationInfo({
    required this.stationId,
    this.kind = '',
    this.kindLabel = '',
    this.description = '',
    this.readme = '',
    this.shared = false,
    this.enabled = true,
    this.allowedPlugins = const <String>[],
    this.config = const <String, dynamic>{},
    this.maxSubscriptions,
    this.scope = const <String, dynamic>{},
    this.builtin = false,
    this.subscriberCount = 0,
    this.subscriptions = const <PluginStationSub>[],
    this.subscribersByTeam = const <String, int>{},
    this.counts = const <String, int>{},
    this.waitsInFlight,
  });

  /// 详情页的「站点介绍」：`readme` 优先，没写时回落到一行 `description`。
  ///
  /// 两者都空（旧核心 / 旧存量数据）时返回空串，由展示层给「未提供介绍」占位。
  String get introText => readme.isNotEmpty ? readme : description;

  /// 被禁用的订阅者（面板「已订阅插件管理」要把它们标出来，不能混在正常项里）。
  List<PluginStationSub> get disabledSubscriptions => subscriptions
      .where((PluginStationSub sub) => sub.disabled)
      .toList(growable: false);

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
    // 团队分组：宽容解析（只认数值 count；未知键保留）
    final Map<String, int> byTeam = <String, int>{};
    final Object? rawByTeam = m['subscribers_by_team'];
    if (rawByTeam is Map) {
      rawByTeam.forEach((Object? team, Object? rawEntry) {
        if (team is! String || rawEntry is! Map) return;
        final Object? rawCount = rawEntry['count'];
        final int count = rawCount is num
            ? rawCount.toInt()
            : (rawEntry['plugin_ids'] is List
                  ? (rawEntry['plugin_ids'] as List).length
                  : 0);
        byTeam[team] = count;
      });
    }
    // 共享白名单与自定义配置：宽容解析（类型不符视为空 = 不限制 / 无配置）
    final List<String> allowed = <String>[];
    final Object? rawAllowed = m['allowed_plugins'];
    if (rawAllowed is List) {
      for (final Object? item in rawAllowed) {
        final String id = (item ?? '').toString().trim();
        if (id.isNotEmpty && !allowed.contains(id)) {
          allowed.add(id);
        }
      }
    }
    Map<String, dynamic> config = const <String, dynamic>{};
    final Object? rawConfig = m['config'];
    if (rawConfig is Map) {
      config = Map<String, dynamic>.from(rawConfig);
    }
    final Object? rawMax = m['max_subscriptions'];
    return PluginStationInfo(
      stationId: stationId,
      kind: (m['kind'] ?? '').toString(),
      kindLabel: (m['kind_label'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      readme: (m['readme'] ?? '').toString(),
      shared: m['shared'] == true,
      enabled: m['enabled'] != false,
      allowedPlugins: allowed,
      config: config,
      maxSubscriptions: rawMax is num ? rawMax.toInt() : null,
      scope: scope,
      builtin: m['builtin'] == true,
      subscriberCount: subscriberCount,
      subscriptions: subs,
      subscribersByTeam: byTeam,
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
    // 生命周期增量（阶段 2）：与 health 同一口径——**缺失 = 本次增量没说 ⇒ 保持原值**，
    // 绝不能当成“没在重启”。status / health 的合并规则一字未改：lifecycle 只多一个轴。
    final Object? rawLifecycle = d['lifecycle'];
    final String? lifecycle =
        rawLifecycle is String && rawLifecycle.isNotEmpty ? rawLifecycle : null;
    final Object? rawGeneration = d['generation'];
    final int? generation = rawGeneration is num
        ? rawGeneration.toInt()
        : null;

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
            lifecycle: lifecycle,
            generation: generation,
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
              lifecycle: lifecycle ?? '',
              generation: generation,
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
            lifecycle: lifecycle,
            generation: generation,
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
