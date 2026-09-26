import 'package:path/path.dart' as p;

import '../store/atomic_file.dart';
import '../store/yaml_codec.dart';
import '../util/liveness.dart';
import 'mcp_client.dart';

/// MCP 服务管理器（M6a）：配置落盘 + 连接缓存 + 工具聚合 + 调用兜底。
///
/// 配置是**用户可直接手改**的 `<数据根>/config/mcp.yaml`：
/// ```yaml
/// servers:
///   - name: filesystem
///     command: npx
///     args: ['-y', '@modelcontextprotocol/server-filesystem', '/tmp']
///     enabled: true
/// ```
/// 连接是**懒建 + 缓存**：启动时尝试一次（`refresh`），之后只有调用失败/服务被改
/// 才重连；一个坏插件只会体现在它自己的错误里，不影响其它服务与核心本身。
///
/// **超时口径（M9 规约 1.1）**：这里**没有任何连接/调用超时**——判据全在客户端侧
/// 的心跳（MCP `ping` 回包或任意一条协议消息；连续 N 拍没有 ⇒ 判失活）。因此
/// [heartbeatInterval] / [missedHeartbeatLimit] 是**心跳参数**而不是超时：
/// 它们只决定"多久没有心跳算死"，与"这次调用总共跑了多久"无关。
class McpService {
  McpService({
    required this.configFile,
    this.clientFactory,
    this.log,
    this.heartbeatInterval = LivenessTracker.defaultInterval,
    this.missedHeartbeatLimit = LivenessTracker.defaultMaxMisses,
  });

  /// 配置文件（`<数据根>/config/mcp.yaml`）。
  final String configFile;

  /// 客户端工厂（测试注入假客户端；生产走 [McpClient.start]）。
  final Future<McpClient> Function(McpServerConfig config)? clientFactory;

  final void Function(String message)? log;

  /// 心跳间隔 I（判活节拍，不是超时）。
  final Duration heartbeatInterval;

  /// 连续丢失多少次判失活 N。
  final int missedHeartbeatLimit;

  final List<McpServerConfig> _servers = <McpServerConfig>[];
  final Map<String, McpClient> _clients = <String, McpClient>{};
  final Map<String, List<McpToolInfo>> _tools = <String, List<McpToolInfo>>{};
  final Map<String, String> _errors = <String, String>{};
  bool _loaded = false;

  /// 读配置（幂等；文件不存在按空配置）。
  void load() {
    if (_loaded) return;
    _loaded = true;
    final String? text = AtomicFile.readStringOrNullSync(configFile);
    if (text == null || text.trim().isEmpty) return;
    try {
      final Map<String, dynamic> data = YamlCodec.decode(text);
      final Object? raw = data['servers'];
      if (raw is List<dynamic>) {
        for (final dynamic item in raw) {
          if (item is! Map) continue;
          final McpServerConfig config = McpServerConfig.fromJson(
            item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
          );
          if (config.name.trim().isEmpty) continue;
          _servers.add(config);
        }
      }
    } catch (error) {
      log?.call('MCP 配置解析失败（$configFile）：$error');
    }
  }

  /// 全部服务（按配置顺序）。
  List<McpServerConfig> servers() {
    load();
    return List<McpServerConfig>.unmodifiable(_servers);
  }

  McpServerConfig? server(String name) {
    load();
    for (final McpServerConfig config in _servers) {
      if (config.name == name) return config;
    }
    return null;
  }

  /// 某服务当前可见的工具。
  List<McpToolInfo> toolsOf(String name) =>
      _tools[name] ?? const <McpToolInfo>[];

  /// 某服务最近一次连接/调用错误（无则 null）。
  String? errorOf(String name) => _errors[name];

  /// 某服务是否已判 degraded（连续 N 次心跳丢失；心跳恢复自动变回 false）。
  bool isDegraded(String name) => _clients[name]?.isDegraded ?? false;

  /// 某服务的链路活性台账（未连接则 null），供上层观测/重连决策与 UI 展示。
  LivenessTracker? livenessOf(String name) => _clients[name]?.liveness;

  /// 全部已就绪服务暴露的工具（带服务名）。
  List<({String service, McpToolInfo tool})> allTools() {
    final List<({String service, McpToolInfo tool})> out =
        <({String service, McpToolInfo tool})>[];
    for (final McpServerConfig config in servers()) {
      if (!config.enabled) continue;
      for (final McpToolInfo tool in toolsOf(config.name)) {
        out.add((service: config.name, tool: tool));
      }
    }
    return out;
  }

  /// 注册（或覆盖）一个服务；返回 `{success}` 或 `{error}`。
  Future<Map<String, dynamic>> register(Map<String, dynamic> body) async {
    load();
    final String name = (body['name'] ?? '').toString().trim();
    final String command = (body['command'] ?? '').toString().trim();
    if (name.isEmpty) return <String, dynamic>{'error': '缺少 name'};
    if (command.isEmpty) return <String, dynamic>{'error': '缺少 command'};
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(name)) {
      return <String, dynamic>{'error': 'name 只允许 [A-Za-z0-9_.-]（避免配置注入）'};
    }
    final McpServerConfig config = McpServerConfig(
      name: name,
      command: command,
      args:
          (body['args'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toList() ??
          const <String>[],
      env: <String, String>{
        for (final MapEntry<dynamic, dynamic> e
            in (body['env'] as Map<dynamic, dynamic>? ?? <dynamic, dynamic>{})
                .entries)
          e.key.toString(): e.value.toString(),
      },
      enabled: body['enabled'] != false,
      builtin: server(name)?.builtin ?? (body['builtin'] == true),
      scope: (body['scope'] ?? '').toString(),
    );
    final int index = _servers.indexWhere(
      (McpServerConfig s) => s.name == name,
    );
    if (index >= 0) {
      _servers[index] = config;
    } else {
      _servers.add(config);
    }
    await _persist();
    await _disconnect(name);
    await refresh(force: true);
    return <String, dynamic>{
      'success': true,
      'service': config.toApiJson(),
      'tools': toolsOf(name).map((McpToolInfo t) => t.name).toList(),
      if (errorOf(name) != null) 'error_detail': errorOf(name),
    };
  }

  /// 删除一个服务（内置服务拒绝删除）；返回 `{success}` 或 `{error}`。
  Future<Map<String, dynamic>> remove(String name) async {
    load();
    final McpServerConfig? config = server(name);
    if (config == null) return <String, dynamic>{'error': 'MCP 服务不存在: $name'};
    if (config.builtin) {
      return <String, dynamic>{'error': '内置 MCP 服务不可删除（可改为 enabled: false）'};
    }
    _servers.removeWhere((McpServerConfig s) => s.name == name);
    await _persist();
    await _disconnect(name);
    _tools.remove(name);
    _errors.remove(name);
    return <String, dynamic>{'success': true, 'name': name};
  }

  /// 连接全部启用服务并刷新工具列表（启动时与"连接失败后重试"用）。
  Future<void> refresh({bool force = false}) async {
    load();
    for (final McpServerConfig config in _servers) {
      if (!config.enabled) continue;
      final McpClient? existing = _clients[config.name];
      if (!force &&
          existing != null &&
          !existing.isClosed &&
          _tools.containsKey(config.name)) {
        continue;
      }
      try {
        final McpClient client = await _connect(config);
        _clients[config.name] = client;
        _tools[config.name] = await client.listTools();
        _errors.remove(config.name);
        log?.call(
          'MCP 服务 ${config.name} 就绪（${toolsOf(config.name).length} 个工具）',
        );
      } catch (error) {
        _errors[config.name] = '$error';
        log?.call('MCP 服务 ${config.name} 不可用：$error');
        await _disconnect(config.name);
      }
    }
    // 已禁用/已删除的服务：断开并清缓存
    for (final String name in _clients.keys.toList(growable: false)) {
      final McpServerConfig? config = server(name);
      if (config == null) {
        await _disconnect(name);
        continue;
      }
      if (!config.enabled) await _disconnect(name);
    }
  }

  /// 调用一个 MCP 工具（接受命名空间名或 `service` + 工具名）。
  ///
  /// 失败时返回**可读错误结果**而不是抛异常：模型要能读到原因并纠正。
  Future<McpCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    String service = '',
  }) async {
    load();
    String targetService = service;
    String targetTool = toolName;
    final ({String service, String tool})? parsed = parseNamespacedToolName(
      toolName,
    );
    if (parsed != null) {
      targetService = parsed.service;
      targetTool = parsed.tool;
    } else if (targetService.isEmpty) {
      for (final McpServerConfig config in _servers) {
        if (toolsOf(config.name).any((McpToolInfo t) => t.name == toolName)) {
          targetService = config.name;
          break;
        }
      }
    }
    if (targetService.isEmpty) {
      return McpCallResult(text: '未找到 MCP 工具: $toolName', isError: true);
    }
    final McpServerConfig? config = server(targetService);
    if (config == null) {
      return McpCallResult(text: 'MCP 服务不存在: $targetService', isError: true);
    }
    McpClient? client = _clients[targetService];
    if (client == null || client.isClosed) {
      // 连接掉了（插件崩过）：重连一次再试，避免模型看到"偶发失败"
      await refresh(force: true);
      client = _clients[targetService];
    }
    if (client == null || client.isClosed) {
      return McpCallResult(
        text: 'MCP 服务 $targetService 不可用：${errorOf(targetService) ?? '未连接'}',
        isError: true,
      );
    }
    try {
      // 无静态超时：跑多久由客户端侧的心跳判据说了算（M9 规约 1.1）
      final McpCallResult result = await client.callTool(targetTool, arguments);
      _errors.remove(targetService);
      return result;
    } catch (error) {
      _errors[targetService] = '$error';
      return McpCallResult(
        text: '调用 MCP 工具 $targetService/$targetTool 失败：$error',
        isError: true,
      );
    }
  }

  /// 关闭全部连接（幂等）。
  Future<void> close() async {
    for (final String name in _clients.keys.toList(growable: false)) {
      await _disconnect(name);
    }
  }

  Future<void> _persist() async {
    final Map<String, dynamic> data = <String, dynamic>{
      'servers': _servers.map((McpServerConfig s) => s.toJson()).toList(),
    };
    await AtomicFile.writeStringAtomic(
      configFile,
      YamlCodec.encode(
        data,
        header: 'MCP 服务配置（M6）：可直接手改；command/args 就是本机进程的启动命令。',
      ),
    );
  }

  Future<McpClient> _connect(McpServerConfig config) {
    final Future<McpClient> Function(McpServerConfig config)? factory =
        clientFactory;
    if (factory != null) return factory(config);
    return McpClient.start(
      config,
      heartbeatInterval: heartbeatInterval,
      missedHeartbeatLimit: missedHeartbeatLimit,
    );
  }

  Future<void> _disconnect(String name) async {
    final McpClient? client = _clients.remove(name);
    if (client == null) return;
    try {
      await client.close();
    } catch (error) {
      log?.call('关闭 MCP 服务 $name 失败：$error');
    }
  }
}

/// 配置文件所在目录（供测试与文档引用）。
String mcpConfigPathIn(String dataRoot) =>
    p.join(dataRoot, 'config', 'mcp.yaml');
