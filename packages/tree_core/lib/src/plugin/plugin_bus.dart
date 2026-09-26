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

  /// 读配置（幂等；文件不存在按"无插件"）。
  void load() {
    if (_loaded) return;
    _loaded = true;
    final String? text = AtomicFile.readStringOrNullSync(configFile);
    if (text == null || text.trim().isEmpty) return;
    try {
      final Map<String, dynamic> data = YamlCodec.decode(text);
      enabled = data['enabled'] != false;
      final Object? raw = data['plugins'];
      if (raw is List<dynamic>) {
        for (final dynamic item in raw) {
          if (item is! Map) continue;
          final PluginConfig config = PluginConfig.fromJson(
            item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
          );
          if (config.id.trim().isEmpty) continue;
          _configs.add(config);
        }
      }
    } catch (error) {
      log?.call('插件配置解析失败（$configFile）：$error');
    }
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
      _hosts[config.id] = host;
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
  Future<PluginCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    String pluginId = '',
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
    final PluginCallResult result = await host.callTool(targetTool, arguments);
    if (result.isError) {
      _errors[targetPlugin] = result.text;
    } else {
      _errors.remove(targetPlugin);
      host.liveness.recordBeat();
    }
    return result;
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
    );
  }

  Future<void> _disconnect(String pluginId) async {
    final PluginHost? host = _hosts.remove(pluginId);
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
