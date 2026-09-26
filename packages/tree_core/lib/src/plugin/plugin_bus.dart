import 'dart:async';

import '../store/atomic_file.dart';
import '../store/yaml_codec.dart';
import 'plugin_host.dart';

/// 插件总线（M6b）：配置、实例生命周期、事件分发、工具聚合与前端快照。
///
/// 配置是**用户可直接手改**的 `<数据根>/config/plugins.yaml`：
/// ```yaml
/// enabled: true
/// plugins:
///   - id: sample
///     command: dart
///     args: [run, plugins/sample.dart]
///     granularity: team
/// ```
/// 与 MCP 一样是"本机直跑"：一个插件崩了只体现在它自己的状态与错误里
/// （`status: disabled` + `disabled_reason`），不影响其它插件与核心。
///
/// 事件总线语义（M6b 的最小可用集）：事件带 `team_id`/`agent_id`/`session_id`，
/// 插件 scope 中的空字段表示"不限定"，非空字段必须与事件一致才会收到事件。
/// `stations`（插件间的处理站订阅）留待 M6c：快照里字段仍在，值为空数组。
class PluginBus {
  PluginBus({
    required this.configFile,
    this.hostFactory,
    this.log,
    this.connectTimeout = const Duration(seconds: 20),
    this.callTimeout = const Duration(seconds: 60),
    this.watchdogInterval = const Duration(seconds: 15),
    this.coreVersion = '',
  });

  final String configFile;

  /// 宿主工厂（测试注入假宿主；生产走 [PluginHost.start]）。
  final Future<PluginHost> Function(PluginConfig config)? hostFactory;

  final void Function(String message)? log;
  final Duration connectTimeout;
  final Duration callTimeout;
  final Duration watchdogInterval;
  final String coreVersion;

  bool enabled = true;

  final List<PluginConfig> _configs = <PluginConfig>[];
  final Map<String, PluginHost> _hosts = <String, PluginHost>{};
  final Map<String, List<PluginToolInfo>> _tools =
      <String, List<PluginToolInfo>>{};
  final Map<String, String> _errors = <String, String>{};
  final Map<String, int> _lastHeartbeat = <String, int>{};
  final Map<String, int> _queueDepth = <String, int>{};
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

  List<PluginToolInfo> toolsOf(String pluginId) =>
      _tools[pluginId] ?? const <PluginToolInfo>[];

  /// 某插件最近一次失败原因（注册失败/心跳失败/调用失败）。
  String? errorOf(String pluginId) => _errors[pluginId];

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

  /// 启动全部启用插件（幂等；单个失败只记录不抛出）。
  Future<void> start() async {
    load();
    if (!enabled) return;
    for (final PluginConfig config in _configs) {
      if (!config.enabled) continue;
      await _startOne(config);
    }
    _watchdogTimer ??= Timer.periodic(watchdogInterval, (Timer _) {
      unawaited(watchdog());
    });
  }

  Future<void> _startOne(PluginConfig config) async {
    if (_hosts.containsKey(config.id)) return;
    try {
      final PluginHost host = await _spawn(config);
      _hosts[config.id] = host;
      _tools[config.id] = await host.listTools(timeout: connectTimeout);
      _errors.remove(config.id);
      _lastHeartbeat[config.id] = _nowSeconds();
      _queueDepth[config.id] = 0;
      log?.call('插件 ${config.id} 就绪（${toolsOf(config.id).length} 个工具）');
    } catch (error) {
      _errors[config.id] = '$error';
      log?.call('插件 ${config.id} 不可用：$error');
      await _disconnect(config.id);
    }
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

  /// 调用插件工具（接受命名空间名，或 `pluginId` + 裸工具名）。
  Future<PluginCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    String pluginId = '',
  }) async {
    load();
    String targetPlugin = pluginId;
    String targetTool = toolName;
    final ({String pluginId, String tool})? parsed = parseNamespacedPluginTool(
      toolName,
    );
    if (parsed != null) {
      targetPlugin = parsed.pluginId;
      targetTool = parsed.tool;
    } else if (targetPlugin.isEmpty) {
      for (final PluginConfig config in _configs) {
        if (toolsOf(config.id).any((PluginToolInfo t) => t.name == toolName)) {
          targetPlugin = config.id;
          break;
        }
      }
    }
    if (targetPlugin.isEmpty) {
      return PluginCallResult(text: '未找到插件工具: $toolName', isError: true);
    }
    final PluginHost? host = _hosts[targetPlugin];
    if (host == null || host.isClosed) {
      return PluginCallResult(
        text: '插件 $targetPlugin 不可用：${_errors[targetPlugin] ?? '未启动'}',
        isError: true,
      );
    }
    final PluginCallResult result = await host.callTool(
      targetTool,
      arguments,
      timeout: callTimeout,
    );
    if (result.isError) {
      _errors[targetPlugin] = result.text;
    } else {
      _errors.remove(targetPlugin);
      _lastHeartbeat[targetPlugin] = _nowSeconds();
    }
    return result;
  }

  /// 心跳巡检：ping 所有实例，失败的标记为不可用并记录原因。
  Future<void> watchdog() async {
    load();
    _lastWatchdogRun = _nowSeconds();
    for (final String pluginId in _hosts.keys.toList(growable: false)) {
      final PluginHost? host = _hosts[pluginId];
      if (host == null) continue;
      final bool alive = await host.ping();
      if (alive) {
        _lastHeartbeat[pluginId] = _nowSeconds();
        continue;
      }
      _errors[pluginId] = '心跳失败（插件无响应）';
      log?.call('插件 $pluginId 心跳失败，标记为不可用');
      await _disconnect(pluginId);
    }
  }

  /// 前端快照（`GET /api/plugin/snapshot`）。
  ///
  /// 字段与前端 `plugin_monitor_service.dart` 的宽容解析对齐；总开关关闭时
  /// 仍然 200 + `enabled: false`（前端渲染空态而不是报错）。
  Map<String, dynamic> snapshot({String? teamId}) {
    load();
    final List<Map<String, dynamic>> instances = <Map<String, dynamic>>[];
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
        if (_lastHeartbeat[config.id] != null)
          'last_heartbeat': _lastHeartbeat[config.id],
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
      // 处理站（插件间订阅）由 M6c 交付；字段保留，值为空数组（前端显示 0）
      'stations': <Map<String, dynamic>>[],
      'watchdog': <String, dynamic>{
        'enabled': enabled,
        'interval_s': watchdogInterval.inSeconds,
        'last_run': _lastWatchdogRun,
        'disabled_count': disabled,
      },
      'config': <String, dynamic>{
        'enabled': enabled,
        'plugins': _configs.map((PluginConfig c) => c.toApiJson()).toList(),
        'path': configFile,
      },
    };
  }

  /// 关闭全部实例与巡检定时器（幂等）。
  Future<void> close() async {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    for (final String pluginId in _hosts.keys.toList(growable: false)) {
      await _disconnect(pluginId);
    }
  }

  Future<PluginHost> _spawn(PluginConfig config) {
    final Future<PluginHost> Function(PluginConfig config)? factory =
        hostFactory;
    if (factory != null) return factory(config);
    return PluginHost.start(
      config,
      timeout: connectTimeout,
      coreVersion: coreVersion,
    );
  }

  Future<void> _disconnect(String pluginId) async {
    final PluginHost? host = _hosts.remove(pluginId);
    _tools.remove(pluginId);
    _queueDepth[pluginId] = 0;
    if (host == null) return;
    try {
      await host.close();
    } catch (error) {
      log?.call('关闭插件 $pluginId 失败：$error');
    }
  }

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}
