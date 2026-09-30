import 'dart:async';

import '../store/atomic_file.dart';
import '../store/yaml_codec.dart';
import '../util/liveness.dart';
import 'execute_mounts.dart';
import 'plugin_host.dart';
import 'plugin_tool_definition.dart';
import 'station_instance.dart';
import 'station_runtime.dart';
import 'station_scope.dart';
import 'station_store.dart';
import 'stations.dart';

/// 站点四元组的**运行期**解析器：插件配置 + 调用点上下文 → 四元组。
///
/// 见 [PluginBus.stationScopeResolver]（主控可在核心启动后注入）。
typedef RuntimeStationScopeResolver = StationScope Function(
  PluginConfig config,
  StationScopeContext context,
);

/// 插件总线（M6b + M9 Wave 3-F）：配置、实例生命周期、事件分发、工具聚合、
/// **站点体系**与**心跳判活**。
///
/// 配置是**用户可直接手改**的 <数据根>/config/plugins.yaml：
///
///   enabled: true
///   plugins:
///     - id: sample
///       command: dart
///       args: [run, plugins/sample.dart]
///       granularity: team
///       scope: {team_id: team-1, mode_key: local}
///
/// 与 MCP 一样是"本机直跑"：一个插件崩了只体现在它自己的状态与错误里
/// （status: disabled + disabled_reason），不影响其它插件与核心。
///
/// **心跳判活（M9 §1.1）**：取消静态总时长上限；看门狗每过一拍（I=10s）ping 一次，
/// 连续 N=3 拍没有心跳 ⇒ 标记 health: degraded + 前端可见，**不自动终止插件**
/// （插件长任务跑多久都不因时间被杀），心跳恢复后自动清除；用户可显式 [restart]。
class PluginBus {
  PluginBus({
    required this.configFile,
    this.hostFactory,
    this.log,
    this.connectTimeout = const Duration(seconds: 20),
    this.heartbeatInterval = LivenessTracker.defaultInterval,
    this.missThreshold = LivenessTracker.defaultMaxMisses,
    this.coreVersion = '',
    this.broadcast,
    StationHub? stations,
    this.stationScopeResolver,
    this.agentModeKeyResolver,
    this.callSiteContext,
    this.toolTableRefreshHook,
  }) : stations =
           stations ??
           StationHub(
             storePath: StationStore.pathFor(configFile),
             log: log,
             frameSink: broadcast,
             heartbeatInterval: heartbeatInterval,
             missThreshold: missThreshold,
           ) {
    // 活性探针：站点等回包时用它判「订阅者心跳还在不在」。
    this.stations.livenessProbe = _livenessOf;
  }

  final String configFile;

  /// 宿主工厂（测试注入假宿主；生产走 [PluginHost.start]）。
  final Future<PluginHost> Function(PluginConfig config)? hostFactory;

  final void Function(String message)? log;

  /// **建连窗口**（只覆盖 hello 握手与首次 tools/list；不是任务总时长上限）。
  final Duration connectTimeout;

  /// 心跳间隔 I（默认 10s；看门狗节拍与单拍窗口都用它）。
  final Duration heartbeatInterval;

  /// 连续丢失阈值 N（默认 3）：连续 N 拍没有心跳 ⇒ degraded。
  final int missThreshold;

  final String coreVersion;

  /// WS 下行广播（plugin_status / plugin_event / 插件 UI 帧）；null = 不推。
  final void Function(Map<String, dynamic> frame)? broadcast;

  /// 站点中枢（四站、订阅、落盘；落点 = <数据根>/config/stations.yaml）。
  final StationHub stations;

  /// 插件配置 → 站点四元组的**运行期接线点**（M9 Wave 3-I）。
  ///
  /// 入参 = 插件配置 + [StationScopeContext]（调用点上下文：当前 team / agent /
  /// session）。未接线时走默认解析：team 只认插件自己的声明（**不**用调用点团队替
  /// 插件认领归属，否则无归属插件会被跨 team 放大），agent / session 取声明（更细）
  /// 或调用点上下文，mode_key 由 [agentModeKeyResolver] 从 agent 的工作空间模式解析。
  RuntimeStationScopeResolver? stationScopeResolver;

  /// agent → **工作空间模式**（local | ssh）：mode_key 的运行期来源（plan §1.2）。
  ///
  /// 核心侧注入 store.agent(id)?.sshConfig != null ? ssh : local；未接线时退回
  /// 插件声明里的 mode_key（缺省 local，与既有配置语义一致）。
  String Function(String agentId)? agentModeKeyResolver;

  /// **调用点上下文**解析（当前 agent / 会话 → team / agent / session）。
  ///
  /// 核心侧注入「从 agent 的团队归属取 team_id」；未接线时调用点只带 agent /
  /// session（team 为空 = 工具表不做 team 过滤，行为与 M9 之前一致）。
  StationScopeContext Function(String agentId, String sessionId)?
  callSiteContext;

  /// 工具表刷新时的**观测钩子**（测试 / 日志用：记录收集站真的被触发了几次）。
  void Function(StationScope? scope)? toolTableRefreshHook;

  bool enabled = true;

  final List<PluginConfig> _configs = <PluginConfig>[];
  final Map<String, PluginHost> _hosts = <String, PluginHost>{};

  /// 每个**正在运行的实例**是按哪一份配置拉起来的（[applyConfigs] 判断"启动参数
  /// 有没有变"的唯一依据）。
  ///
  /// 为什么不能拿 `_configs` 里的那一份比：对账会重读磁盘并**整体覆盖** `_configs`，
  /// 旧配置当场就没了；而"这个进程当时是按什么参数起来的"才是"要不要重启"的判据。
  final Map<String, PluginConfig> _spawnedConfigs = <String, PluginConfig>{};
  final Map<String, String> _errors = <String, String>{};
  final Map<String, int> _queueDepth = <String, int>{};

  /// 已被判 degraded 的插件（用于只在**跃迁**时通知前端）。
  final Set<String> _degraded = <String>{};

  /// 动态工具表（**触发方** = 工具表刷新处；由收集站收集后注册）。
  final PluginToolDefinitionTable _definitions = PluginToolDefinitionTable();

  /// 模型工具表（插件部分）的**按 scope 缓存**（M9 Wave 3-I）。
  ///
  /// 缓存的意义：工具表在每个 agent 每轮生成前都要拼一次（WorkspaceToolRunner 的
  /// specsFor），若每次都全量触发收集站，插件会被高频打扰。失效点 = **插件生命周期
  /// 事件**（上线 / 下线 / 重启 / 一次收集完成），只有脏了才在后台补一次收集。
  final Map<String, List<({String pluginId, PluginToolInfo tool})>>
  _toolTableCache = <String, List<({String pluginId, PluginToolInfo tool})>>{};

  /// 工具表是否需要重新收集（失效标记）。
  bool _toolTableDirty = true;

  /// 是否已有一次收集在途（防止同一拍里重复触发）。
  bool _toolTableRefreshing = false;

  /// 收集站被真正触发的次数（观测 / 测试用；缓存命中不增加）。
  int toolTableRefreshCount = 0;

  /// 最近一次收集的结论（[ensureToolTableFresh] 在不脏时返回它）。
  ToolDefinitionRefresh? _lastToolTableRefresh;

  int _lastWatchdogRun = 0;
  Timer? _watchdogTimer;
  bool _loaded = false;

  /// 读配置（**幂等**；文件不存在按"无插件"）。
  ///
  /// 幂等 = 配置只在核心启动时进内存一次。这条口径不能丢：[configs] / [config]
  /// 在热路径上（每次模型工具表拼装都会问一次"有哪些插件"），每次调用都读盘会把
  /// 工具表刷新拖成磁盘 IO。运行期的增删改走 [applyConfigs]（它先调 [_reloadConfigs]）。
  void load() {
    if (_loaded) return;
    _reloadConfigs();
  }

  /// **强制重读** <数据根>/config/plugins.yaml 到内存（[applyConfigs] 的读盘口）。
  ///
  /// 为什么需要它：load() 幂等意味着"用户在盘上改了配置"在运行期没有任何落点，
  /// 于是每个插件开关都得等重启核心。返回 null = 读盘成功（内存被磁盘整体覆盖；
  /// 先解析到临时列表、成功才替换，所以重复调用幂等）；返回可读原因 = 解析失败，
  /// 此时内存配置与运行实例**保持原样**：把用户手改坏的文件当成"没有插件"会顺手
  /// 停掉全部在跑的插件，那是把一次拼写错误放大成一次全量停机。
  String? _reloadConfigs() {
    _loaded = true;
    final String? text = AtomicFile.readStringOrNullSync(configFile);
    final List<PluginConfig> parsed = <PluginConfig>[];
    bool totalEnabled = true;
    if (text != null && text.trim().isNotEmpty) {
      try {
        final Map<String, dynamic> data = YamlCodec.decode(text);
        totalEnabled = data['enabled'] != false;
        final Object? raw = data['plugins'];
        if (raw is List<dynamic>) {
          for (final dynamic item in raw) {
            if (item is! Map) continue;
            final PluginConfig config = PluginConfig.fromJson(
              item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
            );
            if (config.id.trim().isEmpty) continue;
            parsed.add(config);
          }
        }
      } catch (error) {
        log?.call('插件配置解析失败（$configFile）：$error');
        return '插件配置解析失败（$configFile）：$error';
      }
    }
    // 成功解析才整体替换内存配置（追加式更新会让删掉的条目阴魂不散）
    _configs
      ..clear()
      ..addAll(parsed);
    enabled = totalEnabled;
    return null;
  }

  /// 全部插件配置（按配置顺序）。
  List<PluginConfig> configs() {
    load();
    return List<PluginConfig>.unmodifiable(_configs);
  }

  PluginConfig? config(String id) {
    load();
    for (final PluginConfig config in _configs) {
      if (config.id == id) return config;
    }
    return null;
  }

  /// 已启动的实例（id → 宿主）。
  List<({String pluginId, PluginHost host})> instances() =>
      <({String pluginId, PluginHost host})>[
        for (final MapEntry<String, PluginHost> entry in _hosts.entries)
          (pluginId: entry.key, host: entry.value),
      ];

  /// 某插件当前注册的工具（来自动态工具表 = 收集站收集到的定义）。
  List<PluginToolInfo> toolsOf(String pluginId) => _definitions
      .definitions()
      .where((PluginToolDefinition d) => d.pluginId == pluginId)
      .map((PluginToolDefinition d) => d.toToolInfo())
      .toList(growable: false);

  /// 某插件最近一次失败原因（注册失败 / 调用失败）。
  String? errorOf(String pluginId) => _errors[pluginId];

  /// 某插件的健康度快照（心跳判活；degraded **不等于**死亡）。
  Map<String, dynamic> healthOf(String pluginId) {
    final PluginHost? host = _hosts[pluginId];
    if (host == null) {
      return <String, dynamic>{
        'plugin_id': pluginId,
        'health': 'unavailable',
        'degraded': false,
        'missed_heartbeats': 0,
        'reason': _errors[pluginId] ?? '未启动',
      };
    }
    final LivenessTracker tracker = host.liveness;
    return <String, dynamic>{
      'plugin_id': pluginId,
      'health': tracker.isStale ? 'degraded' : 'ok',
      'degraded': tracker.isStale,
      'missed_heartbeats': tracker.missedCount,
      'miss_threshold': tracker.maxMisses,
      'heartbeat_interval_s': tracker.interval.inMilliseconds / 1000,
      'last_heartbeat':
          (tracker.lastBeatAt?.millisecondsSinceEpoch ?? 0) ~/ 1000,
      if (tracker.isStale) 'reason': tracker.staleMessage,
    };
  }

  /// 全部**可用**插件工具（带插件 id）。
  ///
  /// [scope] 非空时按**站点四元组**过滤（plan §1.2）：只保留归属该 team 的定义，
  /// 定义里更细的 agent / session 也必须与调用点一致；无 team 归属的老式定义
  /// （tools/list 路径）不受站点过滤影响，保持既有行为。
  List<({String pluginId, PluginToolInfo tool})> allTools({
    StationScope? scope,
  }) {
    final List<({String pluginId, PluginToolInfo tool})> out =
        <({String pluginId, PluginToolInfo tool})>[];
    for (final PluginConfig config in configs()) {
      if (!config.enabled) continue;
      for (final PluginToolDefinition definition in _definitionList(
        config.id,
      )) {
        if (!_visible(definition, scope)) continue;
        out.add((pluginId: config.id, tool: definition.toToolInfo()));
      }
    }
    return out;
  }

  /// 某插件的工具定义（**带 scope**，过滤 / 调试用）。
  List<PluginToolDefinition> _definitionList(String pluginId) => _definitions
      .definitions()
      .where((PluginToolDefinition d) => d.pluginId == pluginId)
      .toList(growable: false);

  /// 一条定义是否对调用点 scope 可见（fail-closed：证明了不一致就不给看）。
  static bool _visible(PluginToolDefinition definition, StationScope? scope) {
    if (scope == null) return true;
    final StationScope declared = definition.scope;
    // 无 team 归属 = 老式 tools/list 申报路径：不做站点过滤（保持既有行为）
    if (declared.teamId.trim().isEmpty) return true;
    // 调用点没有 team 信息：不过滤（M9 之前的行为）
    if (scope.teamId.trim().isEmpty) return true;
    if (declared.teamId != scope.teamId) return false;
    if (declared.agentId.isNotEmpty && declared.agentId != scope.agentId) {
      return false;
    }
    if (declared.sessionId.isNotEmpty &&
        declared.sessionId != scope.sessionId) {
      return false;
    }
    return true;
  }

  /// 已注册的工具定义（按命名空间名；调用路由用）。
  PluginToolDefinition? definitionOf(String namespacedName) =>
      _definitions.byNamespacedName(namespacedName);

  /// 启动全部启用插件（幂等；单个失败只记录不抛出），随后触发一次工具定义收集。
  Future<void> start() async {
    load();
    if (!enabled) return;
    for (final PluginConfig config in _configs) {
      if (!config.enabled) continue;
      await _startOne(config);
    }
    // **触发时机在调用方**：插件启动完成 = 工具表刷新点，这里触发收集站。
    await refreshToolDefinitions();
    _watchdogTimer ??= Timer.periodic(heartbeatInterval, (Timer _) {
      unawaited(watchdog());
    });
  }

  Future<void> _startOne(PluginConfig config) async {
    if (_hosts.containsKey(config.id)) return;
    try {
      final PluginHost host = await _spawn(config);
      // **插件 → 核心请求通道**（M9 §3）：插件主动下命令（station/command）在这里
      // 接线。生产路径已在 _spawn 里接好（建连即生效），这里再设一次是为了覆盖
      // hostFactory 注入的宿主（测试 / 自定义宿主）。
      host.onPluginRequest = (String method, Map<String, dynamic> params) =>
          _handlePluginRequest(config, method, params);
      _hosts[config.id] = host;
      // 记下"这个实例是按哪一份配置起来的"：对账时据此判断启动参数有没有变
      _spawnedConfigs[config.id] = config;
      _errors.remove(config.id);
      _queueDepth[config.id] = 0;
      host.liveness.recordBeat();
      if (!_scopeOf(config).isValid) {
        // 无 team 归属的插件进不了站点体系（隔离要求四元组）：
        // 走既有 tools/list 直接申报，保证工具仍可用（显式路径，不是静默降级）
        _registerLegacyTools(
          config.id,
          await host.listTools(timeout: connectTimeout),
        );
      }
      // 插件上线 = 工具表失效点（下次工具表刷新点会重新收集它的申报）
      invalidateToolTable(reason: '插件 ${config.id} 上线');
      log?.call('插件 ${config.id} 就绪');
      _emitStatus(config, 'registered', degraded: false);
    } catch (error) {
      _errors[config.id] = '$error';
      log?.call('插件 ${config.id} 不可用：$error');
      await _disconnect(config.id);
      _emitStatus(config, 'disabled', reason: '$error');
    }
  }

  /// 推一条 plugin_status 增量（前端按 plugin_id + scope 合并）。
  ///
  /// 心跳降级时 **status 仍是 registered**（插件活着），健康度走 health 字段——
  /// 这样前端的增量合并不会把它当成"停用"。
  void _emitStatus(
    PluginConfig config,
    String status, {
    String reason = '',
    bool? degraded,
  }) {
    final PluginHost? host = _hosts[config.id];
    broadcast?.call(<String, dynamic>{
      'type': 'plugin_status',
      'data': <String, dynamic>{
        'plugin_id': config.id,
        'name': config.name,
        'granularity': config.granularity,
        'scope': config.scope,
        'status': status,
        if (reason.isNotEmpty) 'reason': reason,
        if (degraded != null) 'health': degraded ? 'degraded' : 'ok',
        if (host != null) ...<String, dynamic>{
          'missed_heartbeats': host.liveness.missedCount,
          'heartbeat_interval_s': host.liveness.interval.inMilliseconds / 1000,
          'last_heartbeat':
              (host.liveness.lastBeatAt?.millisecondsSinceEpoch ?? 0) ~/ 1000,
        },
        'ts': _nowSeconds(),
      },
    });
  }

  /// 推一条 plugin_event（插件主动通知：log / event）。
  void _emitPluginEvent(String pluginId, Map<String, dynamic> notification) {
    broadcast?.call(<String, dynamic>{
      'type': 'plugin_event',
      'data': <String, dynamic>{
        'plugin_id': pluginId,
        'method': (notification['method'] ?? '').toString(),
        'params': notification['params'] ?? <String, dynamic>{},
        'ts': _nowSeconds(),
      },
    });
  }

  /// 把一个总线事件分发给订阅的插件实例，返回收到的实例数。
  int dispatch(Map<String, dynamic> event) {
    load();
    if (!enabled) return 0;
    int delivered = 0;
    for (final PluginConfig config in _configs) {
      if (!config.enabled) continue;
      final PluginHost? host = _hosts[config.id];
      if (host == null || host.isClosed) continue;
      if (!_subscribes(config, event)) continue;
      host.dispatchEvent(event);
      _queueDepth[config.id] = (_queueDepth[config.id] ?? 0) + 1;
      delivered++;
    }
    return delivered;
  }

  /// **agent 事件派发**（M9 追加）：把会话服务发布的 agent 侧事件（如
  /// `agent.tool_call`）按**既有订阅口径**投给插件实例。
  ///
  /// 「既有口径」= [_subscribes]：`config.scope` 里为空即通配，非空则精确匹配
  /// `team_id` / `agent_id` / `session_id`（**不发明新的订阅语法**）；插件声明得
  /// 更细（agent / session 级）就只收该更细范围的事件，声明 team 就收该 team 的事件。
  ///
  /// 与 [dispatch] 的区别只在**取数与兜底**（agent 数据面的唯一入口）：
  /// - 事件名取 `event` 字段：缺失 / 空 ⇒ **拒发并记日志**（不静默丢一条无名字的事件）；
  /// - 补一个 `ts`（epoch 秒）便于插件与自己日志对时间（已有则原样保留）；
  /// - **绝不抛异常**：本方法在生成循环里被调用（工具调用处），插件侧的任何问题都不该
  ///   让生成失败——异常一律收敛成日志 + 返回 0。
  int dispatchAgentEvent(Map<String, dynamic> event) {
    final String name = (event['event'] ?? '').toString().trim();
    if (name.isEmpty) {
      log?.call('agent 事件缺少 event 名称，未派发：$event');
      return 0;
    }
    try {
      return dispatch(<String, dynamic>{
        ...event,
        'event': name,
        if (!event.containsKey('ts')) 'ts': _nowSeconds(),
      });
    } catch (error) {
      log?.call('agent 事件 $name 派发失败（已忽略，不影响生成）：$error');
      return 0;
    }
  }

  bool _subscribes(PluginConfig config, Map<String, dynamic> event) {
    bool matches(String key) {
      final String wanted = (config.scope[key] ?? '').toString();
      if (wanted.isEmpty) return true;
      return wanted == (event[key] ?? '').toString();
    }

    return matches('team_id') && matches('agent_id') && matches('session_id');
  }

  /// 调用插件工具（接受命名空间名，或 pluginId + 裸工具名）。
  ///
  /// **按来源 plugin_id 路由**：先查动态工具表（收集站注册的定义），命中则用定义里的
  /// 来源插件与执行名（唯一权威）；否则退回既有的命名空间解析。
  /// **无静态超时**：插件跑多久都等（判活靠心跳，见 [watchdog]）。
  /// [agentId] / [sessionId] = **调用点**身份：随 `tools/call` 下发给插件
  /// （单实例插件据此做归属判断）。留空 = 不带 scope（老调用方行为不变）。
  Future<PluginCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    String pluginId = '',
    String agentId = '',
    String sessionId = '',
  }) async {
    load();
    String targetPlugin = pluginId;
    String targetTool = toolName;
    final PluginToolDefinition? definition = _definitions.byNamespacedName(
      toolName,
    );
    if (definition != null) {
      targetPlugin = definition.pluginId;
      targetTool = definition.resolvedExecutionName;
    } else {
      final ({String pluginId, String tool})? parsed =
          parseNamespacedPluginTool(toolName);
      if (parsed != null) {
        targetPlugin = parsed.pluginId;
        targetTool = parsed.tool;
      } else if (targetPlugin.isEmpty) {
        for (final PluginConfig config in _configs) {
          if (toolsOf(config.id)
              .any((PluginToolInfo t) => t.name == toolName)) {
            targetPlugin = config.id;
            break;
          }
        }
      }
    }
    if (targetPlugin.isEmpty) {
      return PluginCallResult(text: '未找到插件工具: $toolName', isError: true);
    }
    final PluginHost? host = _hosts[targetPlugin];
    if (host == null || host.isClosed) {
      final String reason = _errors[targetPlugin] ?? '未启动';
      return PluginCallResult(
        text: '插件 $targetPlugin 不可用：$reason',
        isError: true,
      );
    }
    final PluginCallResult result = await host.callTool(
      targetTool,
      arguments,
      scope: _callIdentity(agentId, sessionId),
    );
    if (result.isError) {
      _errors[targetPlugin] = result.text;
    } else {
      _errors.remove(targetPlugin);
      host.liveness.recordBeat();
    }
    return result;
  }

  /// 核心 → 插件 `tools/call` 的身份四元组（Q2）。
  ///
  /// 与 `station/command` 同一口径：team 取调用点 agent 的团队归属、mode 取目标
  /// agent 的工作空间模式；两者都解析不出来时退化为只带 agent/session（插件侧
  /// 自己决定是否要求更完整的身份）。agent 与 session 都为空 = 不带 scope。
  Map<String, dynamic>? _callIdentity(String agentId, String sessionId) {
    final String agent = agentId.trim();
    final String session = sessionId.trim();
    if (agent.isEmpty && session.isEmpty) return null;
    final StationScopeContext context =
        callSiteContext?.call(agent, session) ??
        StationScopeContext(agentId: agent, sessionId: session);
    final String mode = (agentModeKeyResolver?.call(agent) ?? '').trim();
    return <String, dynamic>{
      'team_id': context.teamId.trim(),
      'agent_id': agent,
      'session_id': session,
      if (StationModeKey.isValid(mode)) 'mode_key': mode,
    };
  }

  /// 停止心跳巡检定时器（关停 / 测试用；显式 [watchdog] 仍可手动跑一拍）。
  ///
  /// 起停**只影响探活节拍**，不影响任何任务：插件跑多久都不会因为这里被中止。
  void pauseHeartbeat() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  /// 心跳巡检（M9 §1.1）：**只标健康度，不终止插件**。
  ///
  /// - ping 成功（或插件有任意入站报文，见 PluginHost 的 _onLine）⇒ 记一次心跳；
  /// - 连续 N 拍未达 ⇒ 标记 degraded + 前端可见（status 仍是 registered）；
  /// - degraded **不杀进程**：插件长任务继续跑，恢复后自动清除（用户口径）。
  Future<void> watchdog() async {
    load();
    _lastWatchdogRun = _nowSeconds();
    for (final String pluginId in _hosts.keys.toList(growable: false)) {
      final PluginHost? host = _hosts[pluginId];
      final PluginConfig? pluginConfig = config(pluginId);
      if (host == null || pluginConfig == null) continue;
      final bool alive = await host.ping();
      if (alive) {
        host.liveness.recordBeat();
        if (_degraded.remove(pluginId)) {
          log?.call('插件 $pluginId 心跳恢复（degraded 已清除）');
          _emitStatus(pluginConfig, 'registered', degraded: false);
        }
        continue;
      }
      host.liveness.recordMiss();
      if (host.liveness.isStale && _degraded.add(pluginId)) {
        log?.call(
          '插件 $pluginId 心跳丢失 ⇒ degraded（不自动终止，可显式重启）：'
          '${host.liveness.staleMessage}',
        );
        _emitStatus(
          pluginConfig,
          'registered',
          degraded: true,
          reason: host.liveness.staleMessage,
        );
      }
    }
  }

  /// **显式重启**插件（心跳 degraded 之后由用户 / 上层决定，**不自动做**）。
  Future<bool> restart(String pluginId) async {
    load();
    final PluginConfig? pluginConfig = config(pluginId);
    if (pluginConfig == null) return false;
    await _disconnect(pluginId);
    await _startOne(pluginConfig);
    await refreshToolDefinitions();
    return _hosts.containsKey(pluginId);
  }

  /// **配置对账**（M9 §4.2「开关立刻有用」的核心入口）：重读磁盘配置，把运行中的
  /// 实例调整到与文件一致，并返回**结构化**的逐条结论。
  ///
  /// 为什么必须单独有这个方法：`load()` 幂等 = 配置只在核心启动时进内存，运行期
  /// 没有任何落点——于是前端改了开关也只能回"重启核心后生效"。这里把"磁盘 vs
  /// 运行实例"的差量算清楚，并**复用既有的 [_startOne] / [_disconnect]**（不复制一套
  /// 生命周期逻辑：握手、工具申报、站点订阅、状态广播、失败隔离因此与核心启动时
  /// 走的是同一条路径）。
  ///
  /// 判定口径：
  /// - 文件里**新增**且 enabled ⇒ 启动（started）；
  /// - **在跑且启动参数未变**（command / args / env / granularity / scope 全等）
  ///   ⇒ 一个字节都不动（unchanged）。**刻意不重启**：重启要打断插件正在跑的活、
  ///   丢掉它的内存态，而配置没变时重启换不来任何东西；
  /// - 在跑但启动参数变了 ⇒ 断开后用**新参数**启动（restarted，附变化字段名）；
  /// - enabled=false ⇒ 断开并从实例列表移除（stopped），配置条目**保留**
  ///   （面板据此显示"已停用"，再次打开沿用同一个 id）；
  /// - 文件里已删除 ⇒ 断开并忘掉（stopped；工具定义与站点订阅在 [_disconnect] 里注销）；
  /// - 单个插件启动失败（命令不存在等）⇒ 只进 failed（带可读原因），**不影响其它
  ///   插件**，与 [start] 同口径：一个插件崩了不牵连同级与核心；
  /// - 顶层总开关关闭 ⇒ 只断不启（与 [start] 提前返回同一口径）。
  ///
  /// 对账真的改动了运行态时，按既有机制补一次工具定义收集：下线插件的定义与站点
  /// 订阅已在 [_disconnect] 里注销，新上线插件的申报由这次 [refreshToolDefinitions]
  /// 收走。什么都没变时**不触发收集**（不白打扰插件），工具表也就没有失效点。
  Future<PluginReconcileResult> applyConfigs() async {
    final String? readError = _reloadConfigs();
    if (readError != null) {
      // 配置读不出来：保持现状，只把可读原因报上去（见 [_reloadConfigs] 的说明）
      return PluginReconcileResult(totalEnabled: enabled, error: readError);
    }
    final List<PluginReconcileAction> started = <PluginReconcileAction>[];
    final List<PluginReconcileAction> stopped = <PluginReconcileAction>[];
    final List<PluginReconcileAction> restarted = <PluginReconcileAction>[];
    final List<PluginReconcileAction> unchanged = <PluginReconcileAction>[];
    final List<PluginReconcileAction> failed = <PluginReconcileAction>[];
    final Map<String, PluginConfig> next = <String, PluginConfig>{
      for (final PluginConfig config in _configs) config.id: config,
    };

    // ① 文件里已消失的运行实例：断开并忘掉。放在最前面——被删掉的插件不该继续
    //    收事件、占着工具命名空间与站点订阅。
    for (final String pluginId in _hosts.keys.toList(growable: false)) {
      if (next.containsKey(pluginId)) continue;
      const String reason = '配置条目已删除：实例已断开并忘掉（工具定义与站点订阅一并注销）';
      await _stopPlugin(pluginId, reason);
      _errors.remove(pluginId); // 条目都没了，旧错误不该再留在探针里
      stopped.add(
        PluginReconcileAction(
          kind: PluginReconcileKind.stopped,
          pluginId: pluginId,
          reason: reason,
        ),
      );
    }

    // ② 逐条对账（按文件顺序，与 start() 的遍历口径一致）
    for (final PluginConfig config in _configs) {
      final bool running = _isRunning(config.id);
      if (!enabled) {
        if (running) {
          const String reason =
              '插件系统总开关为关（plugins.yaml 顶层 enabled: false）：实例已断开';
          await _stopPlugin(config.id, reason);
          stopped.add(
            PluginReconcileAction(
              kind: PluginReconcileKind.stopped,
              pluginId: config.id,
              reason: reason,
            ),
          );
        }
        continue;
      }
      if (!config.enabled) {
        if (running) {
          const String reason = '条目已停用（enabled: false）：实例已断开，条目仍保留在清单里';
          await _stopPlugin(config.id, reason);
          stopped.add(
            PluginReconcileAction(
              kind: PluginReconcileKind.stopped,
              pluginId: config.id,
              reason: reason,
            ),
          );
        } else {
          unchanged.add(
            PluginReconcileAction(
              kind: PluginReconcileKind.unchanged,
              pluginId: config.id,
              reason: '条目已停用，实例本来就没在运行',
            ),
          );
        }
        continue;
      }
      if (!running) {
        // 进程退出 / 被关掉留下的残留实例先摘干净：_startOne 见到"实例表里已经有
        // 这个 id"会直接返回，那样会把一个死进程当成已就绪（假成功）。
        if (_hosts.containsKey(config.id)) await _disconnect(config.id);
        final PluginReconcileAction action = await _startForReconcile(config);
        (action.kind == PluginReconcileKind.failed ? failed : started).add(
          action,
        );
        continue;
      }
      final PluginConfig? spawned = _spawnedConfigs[config.id];
      // spawned == null 只可能出现在"实例不是 _startOne 拉起来的"这种不该存在的
      // 情况；此时证明不了参数没变 ⇒ 按当前配置重启一次（宁多重启一次，也不用旧参数硬撑）
      final String diff = spawned == null
          ? '没有上次启动参数的记录'
          : describeStartupDiff(spawned, config);
      if (diff.isEmpty) {
        unchanged.add(
          PluginReconcileAction(
            kind: PluginReconcileKind.unchanged,
            pluginId: config.id,
            reason: '启动参数未变（command / args / env / granularity / scope 全等）：保持运行，不重启',
          ),
        );
        continue;
      }
      await _disconnect(config.id);
      final PluginReconcileAction action = await _startForReconcile(
        config,
        changed: diff,
      );
      (action.kind == PluginReconcileKind.failed ? failed : restarted).add(
        action,
      );
    }

    final PluginReconcileResult result = PluginReconcileResult(
      started: started,
      stopped: stopped,
      restarted: restarted,
      unchanged: unchanged,
      failed: failed,
      totalEnabled: enabled,
    );
    if (result.hasChanges) {
      invalidateToolTable(reason: '插件配置对账：运行态有变化');
      await refreshToolDefinitions();
      // 与 start() 同口径：有实例在跑就该有探活节拍（幂等）。对账刚把插件拉起来
      // 而心跳巡检还停着的话，它就没人判活了。
      _watchdogTimer ??= Timer.periodic(heartbeatInterval, (Timer _) {
        unawaited(watchdog());
      });
    }
    log?.call(result.describe());
    return result;
  }

  /// 某插件此刻**真的在跑**吗（实例在表里且进程没退出）。
  bool _isRunning(String pluginId) {
    final PluginHost? host = _hosts[pluginId];
    return host != null && !host.isClosed;
  }

  /// 拉起一个插件并归类成 started / restarted / failed（**单个插件的失败不外溢**）。
  Future<PluginReconcileAction> _startForReconcile(
    PluginConfig config, {
    String changed = '',
  }) async {
    try {
      await _startOne(config);
    } catch (error) {
      // _startOne 自己会吞掉常规失败；这里兜住任何意外，保证"一个插件的问题不会
      // 中断整轮对账"（失败隔离是对账口径的一部分，不是可选项）。
      _errors[config.id] = '$error';
    }
    if (_hosts.containsKey(config.id)) {
      return PluginReconcileAction(
        kind: changed.isEmpty
            ? PluginReconcileKind.started
            : PluginReconcileKind.restarted,
        pluginId: config.id,
        reason: changed.isEmpty ? '已按配置启动' : '启动参数变化（$changed）：已断开并按新参数启动',
      );
    }
    return PluginReconcileAction(
      kind: PluginReconcileKind.failed,
      pluginId: config.id,
      reason: _errors[config.id] ?? '启动失败（总线没有记录到原因）',
    );
  }

  /// 断开一个实例，并把"停用"如实推给前端（[reason] = 面板上显示的可读原因）。
  ///
  /// 比 [_disconnect] 多做的事就是**广播状态**：不广播的话前端只能等下一次快照，
  /// 用户点完开关还会看到"还在跑"——那这次热应用就白做了。
  Future<void> _stopPlugin(String pluginId, String reason) async {
    // 先留一份配置：_disconnect 会把这个实例的记录清掉，而广播要用它带
    // scope / granularity（条目被删时磁盘上已经找不到这一条了）。
    final PluginConfig? last = _spawnedConfigs[pluginId] ?? config(pluginId);
    await _disconnect(pluginId);
    if (last != null) _emitStatus(last, 'disabled', reason: reason);
  }

  /// 两份配置在**启动参数**上的差异（可读字段名；全等返回空串）。
  ///
  /// 只比"改了就必须重新拉起进程"的字段：command / args / env / granularity / scope。
  /// **name 不在其中**——它只是显示名，改它不需要重启（"不无谓重启"的一部分）；
  /// enabled 是启停开关，由 [applyConfigs] 的分支单独处理，不算"启动参数"。
  static String describeStartupDiff(PluginConfig running, PluginConfig next) {
    final List<String> fields = <String>[];
    if (running.command != next.command) fields.add('command');
    if (!_sameArgs(running.args, next.args)) fields.add('args');
    if (!_sameEnv(running.env, next.env)) fields.add('env');
    if (running.granularity != next.granularity) fields.add('granularity');
    if (!_sameScope(running.scope, next.scope)) fields.add('scope');
    return fields.join(' / ');
  }

  /// 三个"同构比较"：逐项比而不是拼串（值里出现分隔符会误判）。
  /// scope 的值是 dynamic（YAML 里可能是数字 / 布尔），一律按文本比。
  static bool _sameArgs(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameEnv(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, String> e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  static bool _sameScope(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, dynamic> e in a.entries) {
      if (!b.containsKey(e.key)) return false;
      if (b[e.key].toString() != e.value.toString()) return false;
    }
    return true;
  }

  /// **触发「插件定义 tool」收集站**：插件按 schema 申报 → 收集 → 注册成动态工具。
  ///
  /// 数据流（用户定稿）：站点 --（schema + 附带信息）--> 所有订阅插件
  /// --目标数据：工具定义（名称 / 描述 / 参数 / 执行方式）--> 站点 --> 这里。
  /// 「触发时机」由**调用方**决定（本类在 start() 后触发一次；工具表刷新处可再触发），
  /// 站点内部不做管线：注册进工具表就是这里的后续处理。
  ///
  /// [scope] 非空时只刷新该 team×mode 的收集站。
  Future<ToolDefinitionRefresh> refreshToolDefinitions({
    StationScope? scope,
    StationScopeContext context = const StationScopeContext(),
  }) async {
    load();
    if (!enabled) {
      // 总开关关闭：不再收集（也把脏标记清掉，免得每次工具表都排一次空刷新）
      _toolTableDirty = false;
      _toolTableCache.clear();
      return const ToolDefinitionRefresh();
    }
    final Set<String> stationIds = <String>{};
    final List<String> skipped = <String>[];
    // 同一 scope 的订阅者合成一组：站点投递按**精确 scope** 匹配（plan §1.2），
    // 粒度不同的插件（granularity=agent/session）因此各收各的，不互相牵连。
    final Map<String, List<({String stationId, StationScope scope})>> groups =
        <String, List<({String stationId, StationScope scope})>>{};
    for (final PluginConfig config in _configs) {
      if (!config.enabled) continue;
      final PluginHost? host = _hosts[config.id];
      if (host == null || host.isClosed) continue;
      final StationScope pluginScope = _scopeOf(config, context);
      // 无 team 归属 ⇒ 不进站点体系（走既有 tools/list 申报路径，行为不变）
      if (!pluginScope.isValid) continue;
      final String? crossScope = _crossScopeReason(
        config.id,
        pluginScope,
        context,
      );
      if (crossScope != null) {
        skipped.add(crossScope);
        continue;
      }
      final CollectStation? station = stations.toolDefineStationFor(
        pluginScope,
      );
      if (station == null) continue;
      if (scope != null &&
          (station.scope.teamId != scope.teamId ||
              station.scope.modeKey != scope.modeKey)) {
        continue;
      }
      stationIds.add(station.id);
      stations.subscribe(
        station.id,
        StationSubscriber(
          pluginId: config.id,
          scope: pluginScope,
          subscribedAt: _nowSeconds(),
        ),
        (StationRequest request) =>
            _respondToToolDefinition(config, host, request),
      );
      // 采集的**消息 scope** = 调用点运行期四元组（team / agent / session / mode）：
      // 订阅者是插件实例（team 级或它自己声明的更细粒度），消息比订阅更细是允许的；
      // 反过来（消息比订阅粗）会被站点 fail-closed 拒绝。因此这里用调用点自己的
      // 四元组，而不是订阅者的声明 scope（那会把 team 级插件改写成某个 agent 的订阅）。
      final StationScope messageScope = context.teamId.trim().isEmpty
          ? station.scope
          : StationScope(
              teamId: pluginScope.teamId,
              agentId: context.agentId.trim(),
              sessionId: context.sessionId.trim(),
              modeKey: pluginScope.modeKey,
            );
      groups
          .putIfAbsent(
            pluginScope.key,
            () => <({String stationId, StationScope scope})>[],
          )
          .add((stationId: station.id, scope: messageScope));
    }
    final List<StationCollectedItem> collected = <StationCollectedItem>[];
    final List<StationUnresponsive> unresponsive = <StationUnresponsive>[];
    for (final List<({String stationId, StationScope scope})> group
        in groups.values) {
      final StationInstance? instance = stations.station(group.first.stationId);
      if (instance is! CollectStation) continue;
      // 消息 scope = 调用点四元组（订阅者是插件实例，消息更细才允许）
      final StationCollectResult result = await instance.collect(
        scope: group.first.scope,
        meta: <String, dynamic>{
          'purpose': 'tool_definition',
          'plugin_config': configFile,
        },
      );
      collected.addAll(result.items);
      unresponsive.addAll(result.unresponsive);
      skipped.addAll(result.skipped);
    }
    // 后续处理（触发方职责）：按来源 plugin_id 注册成动态工具。
    final List<String> registered = <String>[];
    final List<String> removed = <String>[];
    final Map<String, List<PluginToolDefinition>> byPlugin =
        <String, List<PluginToolDefinition>>{};
    for (final StationCollectedItem item in collected) {
      final Object? payload = item.payload;
      final Object? rawTools = payload is Map ? payload['tools'] : null;
      if (rawTools is! List) {
        unresponsive.add(
          StationUnresponsive(
            subscriber: item.subscriber,
            reason: '产出缺少 tools 数组（按 schema 应为工具定义列表）',
          ),
        );
        continue;
      }
      final List<PluginToolDefinition> definitions = <PluginToolDefinition>[];
      for (final Object? rawTool in rawTools) {
        final PluginToolDefinition? definition = PluginToolDefinition.tryParse(
          pluginId: item.pluginId,
          scope: item.subscriber.scope,
          payload: rawTool,
          onError: (String error) => skipped.add('插件 ${item.pluginId}：$error'),
        );
        if (definition != null) definitions.add(definition);
      }
      byPlugin[item.pluginId] = definitions;
    }
    for (final MapEntry<String, List<PluginToolDefinition>> entry
        in byPlugin.entries) {
      removed.addAll(_definitions.replacePlugin(entry.key, entry.value));
      registered.addAll(
        entry.value.map((PluginToolDefinition d) => d.namespacedName),
      );
    }
    if (unresponsive.isNotEmpty || skipped.isNotEmpty) {
      final int unresponsiveCount = unresponsive.length;
      final int skippedCount = skipped.length;
      log?.call(
        '插件工具定义收集：注册 ${registered.length} 个；'
        '未响应 $unresponsiveCount 个；跳过 $skippedCount 条',
      );
    }
    // 一次收集完成 = 工具表不再脏（缓存随即清空，下次取表按新定义重建）
    final ToolDefinitionRefresh outcome = ToolDefinitionRefresh(
      stationIds: stationIds.toList(growable: false),
      collected: collected,
      unresponsive: unresponsive,
      skipped: skipped,
      registered: registered,
      removed: removed,
    );
    _toolTableDirty = false;
    _toolTableCache.clear();
    _lastToolTableRefresh = outcome;
    toolTableRefreshCount++;
    return outcome;
  }

  // ── 工具表：缓存 + 失效点（M9 Wave 3-I） ──────────────────────────────

  /// **模型工具表刷新点**（同步）：返回当前模型工具表（插件部分）。
  ///
  /// 「收集站的触发时机由调用方决定」：这里就是触发方入口。工具表脏了（插件上线 /
  /// 下线 / 重启 / 换 scope）才**后台**触发一次收集，本次仍返回手上这一份——
  /// 「缓存 + 失效点」因此保证**每次工具调用都不会全量收集**；插件工具列表的变化
  /// 在本次就立刻体现（定义表随生命周期事件同步增删），重新收集只是把插件的申报
  /// 再核一遍（心跳仍在的插件照旧应答）。
  List<({String pluginId, PluginToolInfo tool})> toolTable({
    StationScope? scope,
  }) {
    load();
    if (_toolTableDirty) _scheduleToolTableRefresh(scope);
    final String key = _toolTableKey(scope);
    final List<({String pluginId, PluginToolInfo tool})>? cached =
        _toolTableCache[key];
    if (cached != null) return cached;
    final List<({String pluginId, PluginToolInfo tool})> built = allTools(
      scope: scope,
    );
    _toolTableCache[key] = built;
    return built;
  }

  /// **确保**工具表已收集过（异步；需要确定性的调用点与测试用）。
  ///
  /// 不脏的时候不会重复触发收集（返回上一次的结论）。
  Future<ToolDefinitionRefresh> ensureToolTableFresh({
    StationScope? scope,
    StationScopeContext context = const StationScopeContext(),
  }) async {
    load();
    if (!_toolTableDirty) {
      return _lastToolTableRefresh ?? const ToolDefinitionRefresh();
    }
    return refreshToolDefinitions(scope: scope, context: context);
  }

  /// 工具表是否脏（有失效点未处理）。
  bool get toolTableDirty => _toolTableDirty;

  /// **失效点**：插件上线 / 下线 / 重启时标脏并清缓存（下次刷新点重新收集）。
  void invalidateToolTable({String reason = ''}) {
    _toolTableDirty = true;
    _toolTableCache.clear();
    if (reason.isNotEmpty) {
      log?.call('插件工具表失效（$reason）：下次工具表刷新点会重新收集');
    }
  }

  /// 调用点 → **运行期四元组**（M9 Wave 3-I）。
  ///
  /// - team / agent / session：取 [callSiteContext]（核心按 agent 的团队归属解析），
  ///   未接线时只带 agent / session；
  /// - mode_key：由 [agentModeKeyResolver] 从**目标 agent 的工作空间模式**解析
  ///   （local | ssh），证明不了时退回上下文 / 声明里的值（缺省 local）。
  StationScope runtimeScopeFor({
    required String agentId,
    required String sessionId,
  }) {
    final StationScopeContext context =
        callSiteContext?.call(agentId, sessionId) ??
        StationScopeContext(agentId: agentId, sessionId: sessionId);
    final String agent = context.agentId.trim().isNotEmpty
        ? context.agentId.trim()
        : agentId.trim();
    final String session = context.sessionId.trim().isNotEmpty
        ? context.sessionId.trim()
        : sessionId.trim();
    final String fromAgent = agent.isEmpty
        ? ''
        : (agentModeKeyResolver?.call(agent) ?? '');
    final String mode = StationModeKey.isValid(fromAgent)
        ? fromAgent
        : (StationModeKey.isValid(context.modeKey)
              ? context.modeKey
              : StationModeKey.local);
    return StationScope(
      teamId: context.teamId.trim(),
      agentId: agent,
      sessionId: session,
      modeKey: mode,
    );
  }

  /// 把**执行站首命令集的挂载位置**接到全部执行站（M9 Wave 3-I；幂等）。
  ///
  /// 返回 null = 全部挂载成功；否则是可读原因（不静默）。
  String? mountExecuteStations(ExecuteStationMounts mounts) {
    final List<String> failed = <String>[];
    stations.mountExecuteStations((ExecuteStation station) {
      final String? error = mounts.mountInto(station);
      if (error != null) failed.add(error);
    });
    if (failed.isEmpty) return null;
    return failed.join('；');
  }

  // ── 插件 → 核心的请求通道（M9 §3「插件主动下命令」） ────────────────────

  /// 插件主动发起的请求（JSON-RPC `method` + `id`）的总入口（宿主
  /// [PluginHost.onPluginRequest] 的接线实现）。
  ///
  /// 当前实现执行站的 `station/command`；未知 method ⇒ `-32601`（不静默）。
  /// 失败一律抛 [PluginRequestException]，由宿主变成 `{jsonrpc, id, error}` 响应。
  Future<Map<String, dynamic>> _handlePluginRequest(
    PluginConfig config,
    String method,
    Map<String, dynamic> params,
  ) async {
    switch (method) {
      case 'station/command':
        return _handleStationCommand(config, params);
      default:
        throw PluginRequestException(
          PluginRpcErrorCode.methodNotFound,
          'method not found: $method',
        );
    }
  }

  /// **执行站命令（插件 → 核心）**：参数 {command, arguments, team_id?, agent_id?, session_id?, mode_key?}。
  ///
  /// **单实例 + 每条消息带身份（Q2）**：插件进程只有一个，身份**按这一次请求**解析：
  /// - 目标 agent 取请求里的 agent_id（params 顶层或 arguments 均可），缺省才回退
  ///   到 plugins.yaml 的 scope.agent_id；
  /// - team / mode 由核心按**目标 agent 的真实归属**解析（团队 + 工作空间模式），
  ///   而不是信任插件声明；
  /// - plugins.yaml 的 scope 从此是**作用域上限**：声明了 team 的插件只能在自己的
  ///   team 内活动；未声明的插件可服务任意 team，但每条命令都必须能证明归属
  ///   （fail-closed：agent 缺失 / 不存在 / 归属解析不出 / 请求里带的 team_id 与
  ///   真实归属不一致，一律拒绝）；
  /// - 不带 agent 的团队级命令（如 ui.push）：team 取请求或声明，agent 留空。
  ///
  /// 执行站的结论（含**可读错误**）原样放进 result 回给插件：命令被拒 / 挂载位置
  /// 失败不是 JSON-RPC 错误，而是 {ok: false, error: ...}——插件据此自查原因，
  /// 不会被吞成一句“调用失败”。
  Future<Map<String, dynamic>> _handleStationCommand(
    PluginConfig config,
    Map<String, dynamic> params,
  ) async {
    final String command = (params['command'] ?? '').toString().trim();
    if (command.isEmpty) {
      throw const PluginRequestException(
        PluginRpcErrorCode.invalidParams,
        'station/command 需要 command（执行站命令名，如 fs.read / ui.push）',
      );
    }
    final Object? rawArguments = params['arguments'];
    if (rawArguments != null && rawArguments is! Map) {
      throw const PluginRequestException(
        PluginRpcErrorCode.invalidParams,
        'station/command 的 arguments 必须是 JSON 对象',
      );
    }
    final Map<String, dynamic> arguments = rawArguments is Map
        ? rawArguments.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    // scope = 这一次命令的**运行期四元组**（Q2：单实例 + 每条消息带身份）。
    // 声明只作上限；team / mode 由核心按目标 agent 的真实归属解析。
    final StationScope declared = StationScope.parse(config.scope);
    final StationScope scope = _resolveCommandScope(
      config,
      declared,
      params,
      arguments,
    );
    final ExecuteStation? station = stations.executeFor(scope);
    if (station == null) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '插件 ${config.id} 的 scope（${scope.describe()}）没有可用的执行站',
      );
    }
    final StationCommandResult result = await station.execute(
      command: command,
      scope: scope,
      arguments: arguments,
      sourcePluginId: config.id,
    );
    // 结果原样回给插件（ok / payload / error 三件套，执行站说什么就回什么）
    return <String, dynamic>{
      'command': result.command,
      'ok': result.ok,
      'mount_id': result.mountId,
      'payload': result.payload,
      'error': result.error,
    };
  }

  /// 解析一次 station/command 的**运行期四元组**（Q2：单实例 + 每消息带身份）。
  ///
  /// 规则（fail-closed）：
  /// 1. 目标 agent = 请求里的 agent_id（params 顶层或 arguments）→ 声明里的
  ///    scope.agent_id；两者都空时才走"团队级命令"分支（如 ui.push）；
  /// 2. team / mode = 核心按目标 agent 的**真实归属**解析（callSiteContext /
  ///    agentModeKeyResolver）；解析器未接线（测试 / 嵌入式宿主）才回退到声明，
  ///    与改造前行为一致；
  /// 3. 插件声明是**作用域上限**：声明了非空 team / agent / session 时真实值必须一致；
  /// 4. 请求里显式带的 team_id / mode_key 必须与真实归属一致（带了就得对，
  ///    不允许"声明一套、请求另一套"）。
  StationScope _resolveCommandScope(
    PluginConfig config,
    StationScope declared,
    Map<String, dynamic> params,
    Map<String, dynamic> arguments,
  ) {
    String pick(String key) {
      for (final Object? source in <Object?>[params, arguments]) {
        if (source is! Map) continue;
        final Object? value = source[key];
        if (value != null && value.toString().trim().isNotEmpty) {
          return value.toString().trim();
        }
      }
      return '';
    }

    final String requestedTeam = pick('team_id');
    final String requestedMode = pick('mode_key');
    final String requestedSession = pick('session_id');
    final String requestedAgent = pick('agent_id');

    // ── 团队级命令（无目标 agent，如 ui.push）：team 必须能确定 ──────────
    if (requestedAgent.isEmpty && declared.agentId.isEmpty) {
      final String team = requestedTeam.isNotEmpty
          ? requestedTeam
          : declared.teamId.trim();
      if (team.isEmpty) {
        throw PluginRequestException(
          PluginRpcErrorCode.scopeDenied,
          '插件 ${config.id} 的命令既没有 agent_id 也没有可用 team：'
          '无法确定作用域（团队级命令请带 team_id，或在 plugins.yaml 声明 scope.team_id）',
        );
      }
      if (declared.teamId.trim().isNotEmpty && declared.teamId.trim() != team) {
        throw PluginRequestException(
          PluginRpcErrorCode.scopeDenied,
          '插件 ${config.id} 声明 team=${declared.teamId}，'
          '但命令要作用于 team=$team：跨 team 拒绝（声明是作用域上限）',
        );
      }
      return StationScope(
        teamId: team,
        sessionId: requestedSession.isNotEmpty
            ? requestedSession
            : declared.sessionId,
        modeKey: StationModeKey.isValid(requestedMode)
            ? requestedMode
            : declared.modeKey,
      );
    }

    // ── agent 级命令：按目标 agent 的真实归属解析 ────────────────────────
    final String agentId = requestedAgent.isNotEmpty
        ? requestedAgent
        : declared.agentId;
    final String sessionId = requestedSession.isNotEmpty
        ? requestedSession
        : declared.sessionId;
    final StationScopeContext? context = callSiteContext?.call(
      agentId,
      sessionId,
    );
    final String resolvedTeam = (context?.teamId ?? '').trim().isNotEmpty
        ? context!.teamId.trim()
        : declared.teamId.trim();
    final String resolvedMode = (agentModeKeyResolver?.call(agentId) ?? '')
        .trim();
    final String mode = StationModeKey.isValid(resolvedMode)
        ? resolvedMode
        : (StationModeKey.isValid(requestedMode)
              ? requestedMode
              : declared.modeKey);

    if (declared.teamId.trim().isNotEmpty &&
        declared.teamId.trim() != resolvedTeam) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '插件 ${config.id} 声明 team=${declared.teamId}，但目标 agent $agentId '
        '真实归属 team=${_scopeOr(resolvedTeam)}：跨 team 拒绝（声明是作用域上限）',
      );
    }
    if (declared.agentId.isNotEmpty && declared.agentId != agentId) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '插件 ${config.id} 绑定了 agent=${declared.agentId}，不能对 $agentId 下命令',
      );
    }
    if (declared.sessionId.isNotEmpty &&
        sessionId.isNotEmpty &&
        declared.sessionId != sessionId) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '插件 ${config.id} 绑定了 session=${declared.sessionId}，'
        '与命令的 session=$sessionId 不一致',
      );
    }
    if (requestedTeam.isNotEmpty && requestedTeam != resolvedTeam) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '命令请求的 team_id=$requestedTeam 与目标 agent $agentId 的真实归属 '
        'team=${_scopeOr(resolvedTeam)} 不一致：跨 team 拒绝',
      );
    }
    if (StationModeKey.isValid(requestedMode) && requestedMode != mode) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '命令请求的 mode_key=$requestedMode 与目标 agent $agentId 的真实工作面 '
        'mode=$mode 不一致：拒绝',
      );
    }
    if (resolvedTeam.isEmpty) {
      throw PluginRequestException(
        PluginRpcErrorCode.scopeDenied,
        '插件 ${config.id} 未声明 team，且目标 agent $agentId 没有可解析的团队归属，'
        '不能使用执行站（单实例插件请带 agent_id 并确保该 agent 存在；'
        '或在 plugins.yaml 的 scope.team_id 里声明团队）',
      );
    }
    return StationScope(
      teamId: resolvedTeam,
      agentId: agentId,
      sessionId: sessionId,
      modeKey: mode,
    );
  }

  /// 可读错误里把空归属显示成 "?"。
  static String _scopeOr(String value) => value.isEmpty ? '?' : value;

  void _scheduleToolTableRefresh(StationScope? scope) {
    if (_toolTableRefreshing) return;
    _toolTableRefreshing = true;
    toolTableRefreshHook?.call(scope);
    // 后台补一次收集：失败只记日志（插件不可用不该让工具表刷新点抛错）
    unawaited(() async {
      try {
        await refreshToolDefinitions(
          scope: scope,
          context: scope == null
              ? const StationScopeContext()
              : StationScopeContext(
                  teamId: scope.teamId,
                  agentId: scope.agentId,
                  sessionId: scope.sessionId,
                  modeKey: scope.modeKey,
                ),
        );
      } catch (error) {
        log?.call('插件工具表刷新失败（已忽略，保留现有工具表）：$error');
      } finally {
        _toolTableRefreshing = false;
      }
    }());
  }

  /// 缓存键：四元组全等（team / agent / session / mode 任一不同就是不同的表）。
  static String _toolTableKey(StationScope? scope) => scope?.key ?? '';

  /// 调用点上下文与插件声明不一致 ⇒ **不收集**并给出可读原因（fail-closed）。
  static String? _crossScopeReason(
    String pluginId,
    StationScope pluginScope,
    StationScopeContext context,
  ) {
    final String team = context.teamId.trim();
    if (team.isNotEmpty && pluginScope.teamId != team) {
      return '插件 $pluginId 归属 team=${pluginScope.teamId}，与调用点 team=$team 不一致（跨 team 不收集）';
    }
    final String agent = context.agentId.trim();
    if (agent.isNotEmpty &&
        pluginScope.agentId.isNotEmpty &&
        pluginScope.agentId != agent) {
      return '插件 $pluginId 限定 agent=${pluginScope.agentId}，与调用点 agent=$agent 不一致（跨 scope 不收集）';
    }
    final String session = context.sessionId.trim();
    if (session.isNotEmpty &&
        pluginScope.sessionId.isNotEmpty &&
        pluginScope.sessionId != session) {
      return '插件 $pluginId 限定 session=${pluginScope.sessionId}，与调用点 session=$session 不一致（跨 scope 不收集）';
    }
    return null;
  }

  /// 无 team 归属插件的申报路径（tools/list → 动态工具表）。
  ///
  /// 站点体系要求四元组，这类插件不参与收集站；工具仍照旧注册（tool_name 与
  /// 执行名一致、执行方式 tools/call），与收集站产出的定义**同一张表**。
  void _registerLegacyTools(String pluginId, List<PluginToolInfo> tools) {
    _definitions.replacePlugin(pluginId, <PluginToolDefinition>[
      for (final PluginToolInfo tool in tools)
        PluginToolDefinition(
          pluginId: pluginId,
          toolName: tool.name,
          description: tool.description,
          parameters: tool.inputSchema,
        ),
    ]);
  }

  /// 收集站订阅者的回包实现：**首选 station/request 通道**，老插件退回 tools/list。
  Future<StationReply> _respondToToolDefinition(
    PluginConfig config,
    PluginHost host,
    StationRequest request,
  ) async {
    final StationReply reply = await host.requestStation(request);
    if (!reply.isFailed) return reply;
    // 兼容路径：未实现 station/request 的插件仍用既有 tools/list 申报
    final List<PluginToolInfo> tools = await host.listTools(
      timeout: connectTimeout,
    );
    if (tools.isEmpty) return reply;
    return StationReply.ok(<String, dynamic>{
      'tools': <Map<String, dynamic>>[
        for (final PluginToolInfo tool in tools)
          <String, dynamic>{
            'tool_name': tool.name,
            'description': tool.description,
            'parameters': tool.inputSchema,
            'execution': <String, dynamic>{
              'method': 'tools/call',
              'name': tool.name,
            },
          },
      ],
    });
  }

  /// 插件配置 + 调用点上下文 → **运行期四元组**（M9 Wave 3-I）。
  ///
  /// 默认口径（未接线 [stationScopeResolver] 时）：
  /// - team / agent / session：**只认插件自己的声明**（订阅身份 = 插件实例的声明
  ///   粒度）。调用点上下文不替插件认领归属：既避免无 team 归属的插件被跨 team
  ///   放大（plan §1.2 fail-closed），也避免 team 级插件被收窄成某个 agent 的订阅
  ///   （那会让同队其他 agent 再也看不到它的工具）；
  /// - mode_key：优先由 [agentModeKeyResolver] 从**调用点 agent 的工作空间模式**
  ///   解析（local | ssh），其次上下文显式值，最后声明兜底（缺省 local）——这是
  ///   「SSH 团队的命令不会打到本地工作空间」在工具表这一侧的落点。
  ///
  /// 调用点上下文另有两个用途：过滤不该参与本次收集的插件（见 [_crossScopeReason]）
  /// 与作为采集请求的**消息 scope**（见 refreshToolDefinitions）。
  StationScope _scopeOf(
    PluginConfig config, [
    StationScopeContext context = const StationScopeContext(),
  ]) {
    final RuntimeStationScopeResolver? resolver = stationScopeResolver;
    if (resolver != null) return resolver(config, context);
    final StationScope declared = StationScope.parse(config.scope);
    if (!declared.isValid) return declared;
    // mode_key：调用点 agent 的工作空间模式（解析不出来才退回上下文 / 声明）
    final String callAgent = context.agentId.trim();
    final String fromAgent = callAgent.isEmpty
        ? ''
        : (agentModeKeyResolver?.call(callAgent) ?? '');
    final String mode = StationModeKey.isValid(fromAgent)
        ? fromAgent
        : (StationModeKey.isValid(context.modeKey)
              ? context.modeKey
              : declared.modeKey);
    return StationScope(
      teamId: declared.teamId,
      agentId: declared.agentId,
      sessionId: declared.sessionId,
      modeKey: mode,
    );
  }

  /// 站点活性探针：订阅者（插件）心跳还在不在。
  StationLivenessState _livenessOf(String pluginId) {
    final PluginHost? host = _hosts[pluginId];
    if (host == null) {
      return const StationLivenessState.lost('插件未启动或已下线');
    }
    if (host.isClosed) return const StationLivenessState.lost('插件进程已退出');
    if (host.liveness.isStale) {
      return StationLivenessState.lost('连续 ${host.liveness.missedCount} 拍未达');
    }
    return const StationLivenessState.alive();
  }

  /// 前端快照（GET /api/plugin/snapshot）。
  ///
  /// 字段与前端 plugin_monitor_service.dart 的宽容解析对齐；总开关关闭时
  /// 仍然 200 + enabled: false（前端渲染空态而不是报错）。
  /// stations 段 = 站点体系真实快照（站点实例 + 订阅 + 分类计数 + 收集站 schema）。
  Map<String, dynamic> snapshot({String? teamId}) {
    load();
    final List<Map<String, dynamic>> instances = <Map<String, dynamic>>[];
    int degradedCount = 0;
    for (final PluginConfig config in _configs) {
      final String scopeTeam = (config.scope['team_id'] ?? '').toString();
      if (teamId != null &&
          teamId.isNotEmpty &&
          scopeTeam.isNotEmpty &&
          scopeTeam != teamId) {
        continue;
      }
      final PluginHost? host = _hosts[config.id];
      final String? error = _errors[config.id];
      final bool degraded = host != null && host.liveness.isStale;
      if (degraded) degradedCount++;
      final String displayName = (host != null && host.name.isNotEmpty)
          ? host.name
          : config.name;
      instances.add(<String, dynamic>{
        'plugin_id': config.id,
        'name': displayName,
        'granularity': config.granularity,
        'scope': config.scope,
        'status': error == null && host != null && !host.isClosed
            ? 'registered'
            : 'disabled',
        'health': host == null ? 'unavailable' : (degraded ? 'degraded' : 'ok'),
        if (host != null) ...<String, dynamic>{
          'missed_heartbeats': host.liveness.missedCount,
          'heartbeat_interval_s': host.liveness.interval.inMilliseconds / 1000,
          'last_heartbeat':
              (host.liveness.lastBeatAt?.millisecondsSinceEpoch ?? 0) ~/ 1000,
          'degraded_reason': degraded ? host.liveness.staleMessage : '',
        },
        if (_queueDepth[config.id] != null)
          'queue_depth': _queueDepth[config.id],
        'disabled_reason': error ?? '',
      });
    }
    final int disabled = instances
        .where((Map<String, dynamic> i) => i['status'] == 'disabled')
        .length;
    return <String, dynamic>{
      'enabled': enabled,
      'instances': instances,
      'stations': stations.snapshot(teamId: teamId),
      'watchdog': <String, dynamic>{
        'enabled': enabled,
        'interval_s': heartbeatInterval.inSeconds,
        'miss_threshold': missThreshold,
        'last_run': _lastWatchdogRun,
        'disabled_count': disabled,
        'degraded_count': degradedCount,
      },
      'config': <String, dynamic>{
        'enabled': enabled,
        'plugins': _configs.map((PluginConfig c) => c.toApiJson()).toList(),
        'path': configFile,
      },
      'station_summary': stations.summary(),
    };
  }

  /// 关闭全部实例与心跳定时器（幂等）。
  Future<void> close() async {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    for (final String pluginId in _hosts.keys.toList(growable: false)) {
      final PluginConfig? pluginConfig = config(pluginId);
      await _disconnect(pluginId);
      if (pluginConfig != null) _emitStatus(pluginConfig, 'destroyed');
    }
    stations.save();
  }

  Future<PluginHost> _spawn(PluginConfig config) {
    final Future<PluginHost> Function(PluginConfig config)? factory =
        hostFactory;
    if (factory != null) return factory(config);
    return PluginHost.start(
      config,
      timeout: connectTimeout,
      heartbeatInterval: heartbeatInterval,
      coreVersion: coreVersion,
      onNotification: (Map<String, dynamic> notification) =>
          _emitPluginEvent(config.id, notification),
      // 插件主动请求（station/command）的处理器：建连时即接线，
      // 因此插件在 hello 握手期间就能下命令（不会撞上"未接线 ⇒ -32601"的窗口）。
      onPluginRequest: (String method, Map<String, dynamic> params) =>
          _handlePluginRequest(config, method, params),
    );
  }

  Future<void> _disconnect(String pluginId) async {
    final PluginHost? host = _hosts.remove(pluginId);
    // 实例没了 ⇒ "上次按什么参数起来的"这条记录也失效（重启会重新记）
    _spawnedConfigs.remove(pluginId);
    _queueDepth[pluginId] = 0;
    _degraded.remove(pluginId);
    // **插件下线由总线注销其订阅**（站点订阅关系随之落盘）
    stations.unsubscribePlugin(pluginId);
    // 动态工具表：下线插件的定义一并移除（避免调用到不存在的插件）
    _definitions.removePlugin(pluginId);
    // 插件下线 = 工具表失效点（模型工具表必须随之变化）
    invalidateToolTable(reason: '插件 $pluginId 下线');
    if (host == null) return;
    try {
      await host.close();
    } catch (error) {
      log?.call('关闭插件 $pluginId 失败：$error');
    }
  }

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}

/// 对账里**单个插件**的结论：做了什么（[kind]）+ 对谁（[pluginId]）+ 为什么（[reason]）。
class PluginReconcileAction {
  const PluginReconcileAction({
    required this.kind,
    required this.pluginId,
    required this.reason,
  });

  final PluginReconcileKind kind;
  final String pluginId;

  /// 可读原因（日志 / 热应用 detail 直接用；失败时就是"为什么没起来"）。
  final String reason;

  /// 一句话形式。
  String describe() => '$pluginId：$reason';
}

/// 对账动作的种类（[PluginBus.applyConfigs] 的五种结论）。
enum PluginReconcileKind {
  /// 文件里新增 / 本来没跑：按配置拉起来了。
  started,

  /// 按配置断开了（enabled=false，或条目已被删除）。
  stopped,

  /// 启动参数变了：断开后用新参数重新拉起。
  restarted,

  /// 配置与运行态已经一致，**没有**动它（尤其：启动参数没变 ⇒ 不重启）。
  unchanged,

  /// 这次没能就绪（可读原因在 [PluginReconcileAction.reason]）。
  failed;

  /// 中文名（日志 / 回报）。
  String get label => switch (this) {
    PluginReconcileKind.started => '启动',
    PluginReconcileKind.stopped => '停用',
    PluginReconcileKind.restarted => '重启',
    PluginReconcileKind.unchanged => '未变',
    PluginReconcileKind.failed => '失败',
  };
}

/// 一次**配置对账**的结论（[PluginBus.applyConfigs]）。
///
/// 分五类而不是一个 bool：调用方（热应用接缝 / 日志 / 测试）要能回答"这个插件这次
/// 到底被怎么处理了"，而不是只知道"整体成功或失败"。
class PluginReconcileResult {
  const PluginReconcileResult({
    this.started = const <PluginReconcileAction>[],
    this.stopped = const <PluginReconcileAction>[],
    this.restarted = const <PluginReconcileAction>[],
    this.unchanged = const <PluginReconcileAction>[],
    this.failed = const <PluginReconcileAction>[],
    this.totalEnabled = true,
    this.error = '',
  });

  final List<PluginReconcileAction> started;
  final List<PluginReconcileAction> stopped;
  final List<PluginReconcileAction> restarted;
  final List<PluginReconcileAction> unchanged;
  final List<PluginReconcileAction> failed;

  /// 对账时读到的插件系统总开关（false = 本次只断不启）。
  final bool totalEnabled;

  /// 读盘失败的可读原因（非空 = 本次没有对账，运行态与内存配置都保持原样）。
  final String error;

  /// 是否真的改动了运行态（新增 / 停用 / 重启任一非空）。
  bool get hasChanges =>
      started.isNotEmpty || stopped.isNotEmpty || restarted.isNotEmpty;

  /// 是否有插件没能就绪。
  bool get hasFailure => failed.isNotEmpty;

  /// 五类结论的平铺（遍历 / 查找用；顺序 = 启动 / 停用 / 重启 / 未变 / 失败）。
  List<PluginReconcileAction> get all => <PluginReconcileAction>[
    ...started,
    ...stopped,
    ...restarted,
    ...unchanged,
    ...failed,
  ];

  /// 某个插件这次的结论；本次没提到它 ⇒ null（例如"停用且没在跑的条目被删除"：
  /// 运行态与配置本来就一致，没有任何动作可做）。
  PluginReconcileAction? actionOf(String pluginId) {
    for (final PluginReconcileAction action in all) {
      if (action.pluginId == pluginId) return action;
    }
    return null;
  }

  /// 可读摘要（日志与热应用 detail 用）。
  String describe() {
    if (error.isNotEmpty) return '插件配置对账未执行：$error';
    final StringBuffer out = StringBuffer('插件配置对账');
    void segment(String label, List<PluginReconcileAction> items) {
      if (items.isEmpty) return;
      out.write('；$label ${items.length} 个：');
      out.write(items.map((PluginReconcileAction a) => a.describe()).join('、'));
    }

    segment('启动', started);
    segment('停用', stopped);
    segment('重启', restarted);
    segment('未变', unchanged);
    segment('失败', failed);
    if (!hasChanges && !hasFailure) out.write('：配置与运行态一致，无需变更');
    if (!totalEnabled) out.write('（插件系统总开关为关，未启动任何插件）');
    return out.toString();
  }
}

/// 一次「插件定义 tool」触发的回报（收集站部分结果 + 注册结果）。
class ToolDefinitionRefresh {
  const ToolDefinitionRefresh({
    this.stationIds = const <String>[],
    this.collected = const <StationCollectedItem>[],
    this.unresponsive = const <StationUnresponsive>[],
    this.skipped = const <String>[],
    this.registered = const <String>[],
    this.removed = const <String>[],
  });

  /// 本次触发涉及的收集站 id。
  final List<String> stationIds;

  /// 已收集到的合格产出。
  final List<StationCollectedItem> collected;

  /// 未响应者（**显式列出**，不静默、不阻塞、不整体失败）。
  final List<StationUnresponsive> unresponsive;

  /// 被跳过的条目（schema 之外的可读原因）。
  final List<String> skipped;

  /// 本轮注册进工具表的命名空间名。
  final List<String> registered;

  /// 本轮下线的命名空间名（插件没再申报的工具）。
  final List<String> removed;

  /// 注册条数。
  int get toolCount => registered.length;

  /// 是否全部订阅者都给了合格产出。
  bool get complete => unresponsive.isEmpty;

  /// 可读摘要（日志 / 工具层提示）。
  String describe() {
    final StringBuffer out = StringBuffer('插件工具定义：注册 ${registered.length} 个');
    if (removed.isNotEmpty) out.write('，下线 ${removed.length} 个');
    if (unresponsive.isNotEmpty) {
      out.write('；未响应 ${unresponsive.length} 个：');
      out.write(
        unresponsive
            .map((StationUnresponsive u) => '${u.pluginId}（${u.reason}）')
            .join('、'),
      );
    }
    for (final String reason in skipped) {
      out.write('；$reason');
    }
    return out.toString();
  }
}
