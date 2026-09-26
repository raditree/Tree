import 'dart:async';

import '../store/atomic_file.dart';
import '../store/yaml_codec.dart';
import '../util/liveness.dart';
import 'plugin_host.dart';
import 'plugin_tool_definition.dart';
import 'station_instance.dart';
import 'station_runtime.dart';
import 'station_scope.dart';
import 'station_store.dart';
import 'stations.dart';

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

  /// 插件配置 → 站点四元组的**接线点**（默认直接读配置里的 scope）。
  ///
  /// 主控接线后这里可以按运行期上下文（当前 team / local-ssh 模式）解析；
  /// 未接线时按 plugins.yaml 的 scope 字段（mode_key 缺失 = local）。
  final StationScope Function(PluginConfig config)? stationScopeResolver;

  bool enabled = true;

  final List<PluginConfig> _configs = <PluginConfig>[];
  final Map<String, PluginHost> _hosts = <String, PluginHost>{};
  final Map<String, String> _errors = <String, String>{};
  final Map<String, int> _queueDepth = <String, int>{};

  /// 已被判 degraded 的插件（用于只在**跃迁**时通知前端）。
  final Set<String> _degraded = <String>{};

  /// 动态工具表（**触发方** = 工具表刷新处；由收集站收集后注册）。
  final PluginToolDefinitionTable _definitions = PluginToolDefinitionTable();

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
  List<({String pluginId, PluginToolInfo tool})> allTools() {
    final List<({String pluginId, PluginToolInfo tool})> out =
        <({String pluginId, PluginToolInfo tool})>[];
    for (final PluginConfig config in configs()) {
      if (!config.enabled) continue;
      for (final PluginToolInfo tool in toolsOf(config.id)) {
        out.add((pluginId: config.id, tool: tool));
      }
    }
    return out;
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
  }) async {
    load();
    if (!enabled) return const ToolDefinitionRefresh();
    final Set<String> stationIds = <String>{};
    for (final PluginConfig config in _configs) {
      if (!config.enabled) continue;
      final PluginHost? host = _hosts[config.id];
      if (host == null || host.isClosed) continue;
      final StationScope pluginScope = _scopeOf(config);
      if (!pluginScope.isValid) continue;
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
    }
    final List<StationCollectedItem> collected = <StationCollectedItem>[];
    final List<StationUnresponsive> unresponsive = <StationUnresponsive>[];
    final List<String> skipped = <String>[];
    for (final String stationId in stationIds) {
      final StationInstance? instance = stations.station(stationId);
      if (instance is! CollectStation) continue;
      final StationCollectResult result = await instance.collect(
        scope: instance.scope,
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
    return ToolDefinitionRefresh(
      stationIds: stationIds.toList(growable: false),
      collected: collected,
      unresponsive: unresponsive,
      skipped: skipped,
      registered: registered,
      removed: removed,
    );
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

  /// 插件配置 → 站点四元组（未接线时读配置 scope；mode_key 缺失 = local）。
  StationScope _scopeOf(PluginConfig config) {
    final StationScope Function(PluginConfig)? resolver = stationScopeResolver;
    if (resolver != null) return resolver(config);
    return StationScope.parse(config.scope);
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
