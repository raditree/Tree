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
/// 连接是**懒建 + 缓存**：
/// - **启动时**全量连一次（`refresh`）：MCP 工具以 `mcp__<服务>__<工具>` 原生注入模型
///   工具表，启动不连会让首轮工具表缺项；
/// - **注册时只连它自己**（`register` → `ensureConnected`）：注册代价不随"别的服务有多少 /
///   多慢"增长（旧实现每次注册都 `refresh(force: true)` 全量重连，是"点了很久没反应"的根因）；
/// - 其余时刻**用到才连**（`ensureConnected`：工具调用命中未连接的服务时补连），失败带
///   [connectRetryDelay] 退避，避免把死服务反复拉起来。
/// 一个坏服务只会体现在它自己的错误里，不影响其它服务与核心本身。
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

  /// 正在连接中的服务（同名并发去重：同时多次 `ensureConnected` 只连一次）。
  final Map<String, Future<McpClient?>> _connecting =
      <String, Future<McpClient?>>{};

  /// 上次尝试连接的时刻（失败退避用，见 [ensureConnected]）。
  final Map<String, DateTime> _lastAttemptAt = <String, DateTime>{};

  /// 连接失败后的重试退避窗口。
  ///
  /// 为什么不无限重试：连接失败本身就要等满 I×N（默认 30s）或等到进程报错，如果
  /// `mcp help`、工具调用每次都重试一遍，用户/模型看到的就是"又卡住了"。显式动作
  /// （`refresh(force: true)`）不受这个窗口限制。
  static const Duration connectRetryDelay = Duration(seconds: 30);

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
  ///
  /// **只连它自己**（[ensureConnected]）：注册的代价不随"其它服务有多少 / 多慢"增长——
  /// 真机反馈的"点注册很久没反应、连点多次"正是旧实现（`refresh(force: true)` 全量重连）
  /// 造成的。其它服务保持现状，用到时才会连（懒连接）。
  Future<Map<String, dynamic>> register(Map<String, dynamic> body) async {
    load();
    final Map<String, dynamic> parsed = _configFromBody(body);
    final Object? parseError = parsed['error'];
    if (parseError != null) return <String, dynamic>{'error': parseError};
    final McpServerConfig config = parsed['config'] as McpServerConfig;
    final int index = _servers.indexWhere(
      (McpServerConfig s) => s.name == config.name,
    );
    if (index >= 0) {
      _servers[index] = config;
    } else {
      _servers.add(config);
    }
    await _persist();
    await _disconnect(config.name);
    // 这次是**新配置**的第一次尝试：清掉退避（用户刚改完命令，没道理还挡着）
    _lastAttemptAt.remove(config.name);
    // 注册自己的人（确保可用）：失败不抛，如实进 error_detail（注册成功 ≠ 服务可用）
    if (config.enabled) await ensureConnected(config.name);
    return <String, dynamic>{
      'success': true,
      'service': config.toApiJson(),
      'tools': toolsOf(config.name).map((McpToolInfo t) => t.name).toList(),
      if (errorOf(config.name) != null) 'error_detail': errorOf(config.name),
    };
  }

  /// 校验 + 构造配置（传输相关：stdio 要 command、http 要合法 url）。
  Map<String, dynamic> _configFromBody(Map<String, dynamic> body) {
    final String name = (body['name'] ?? '').toString().trim();
    if (name.isEmpty) return <String, dynamic>{'error': '缺少 name'};
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(name)) {
      return <String, dynamic>{'error': 'name 只允许 [A-Za-z0-9_.-]（避免配置注入）'};
    }
    final String transport = (body['transport'] ?? mcpTransportStdio)
        .toString()
        .trim()
        .toLowerCase();
    if (transport != mcpTransportStdio && transport != mcpTransportHttp) {
      return <String, dynamic>{
        'error': 'transport 只支持 $mcpTransportStdio / $mcpTransportHttp（收到：$transport）',
      };
    }
    final String command = (body['command'] ?? '').toString().trim();
    final String url = (body['url'] ?? '').toString().trim();
    if (transport == mcpTransportStdio && command.isEmpty) {
      return <String, dynamic>{'error': '缺少 command'};
    }
    if (transport == mcpTransportHttp) {
      final Uri? uri = Uri.tryParse(url);
      if (uri == null ||
          !(uri.isScheme('http') || uri.isScheme('https')) ||
          uri.host.isEmpty) {
        return <String, dynamic>{
          'error': 'transport=http 需要合法 url（http/https 绝对地址，收到：${url.isEmpty ? '空' : url}）',
        };
      }
    }
    return <String, dynamic>{
      'config': McpServerConfig(
        name: name,
        transport: transport,
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
        url: url,
        headers: <String, String>{
          for (final MapEntry<dynamic, dynamic> e
              in (body['headers'] as Map<dynamic, dynamic>? ??
                      <dynamic, dynamic>{})
                  .entries)
            e.key.toString(): e.value.toString(),
        },
        enabled: body['enabled'] != false,
        builtin: server(name)?.builtin ?? (body['builtin'] == true),
        scope: (body['scope'] ?? '').toString(),
      ),
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

  /// 某服务是否已连接（未连 / 已关闭都算未连接）。
  bool isConnected(String name) {
    final McpClient? client = _clients[name];
    return client != null && !client.isClosed;
  }

  /// 懒连接：**只连这一家**（已连直接返回；同名并发去重；失败带 [connectRetryDelay] 退避）。
  ///
  /// 连接是"用到才做"的事：除启动（全量，保工具表完整）与注册（只连自己，确保可用）
  /// 之外，工具调用命中未连接的服务时走这里补连。
  /// 退避窗口内不重复尝试（原因留在 [errorOf]），避免死服务被反复拉起。
  Future<McpClient?> ensureConnected(
    String name, {
    bool ignoreBackoff = false,
  }) async {
    load();
    final McpServerConfig? config = server(name);
    if (config == null || !config.enabled) return null;
    final McpClient? existing = _clients[name];
    if (existing != null && !existing.isClosed) return existing;
    final Future<McpClient?>? inFlight = _connecting[name];
    if (inFlight != null) return inFlight;
    final DateTime? last = _lastAttemptAt[name];
    if (!ignoreBackoff &&
        last != null &&
        DateTime.now().difference(last) < connectRetryDelay) {
      log?.call(
        'MCP 服务 $name 在重试退避窗口内（${connectRetryDelay.inSeconds}s），跳过本次连接尝试',
      );
      return null;
    }
    final Future<McpClient?> task = _connectAndList(config);
    _connecting[name] = task;
    try {
      return await task;
    } finally {
      _connecting.remove(name);
    }
  }

  /// 连一家并取它的工具表（成功/失败都落到 `_clients` / `_tools` / `_errors`）。
  ///
  /// 退避窗口**只由失败产生**（成功即清除）：这样"连上之后又崩了"的服务可以立刻重连，
  /// 而"根本连不上"的服务不会被 `mcp help` / 反复的工具调用一次次拉起（每次都要等满
  /// 心跳窗口，用户看到的就是"又卡住了"）。
  Future<McpClient?> _connectAndList(McpServerConfig config) async {
    try {
      final McpClient client = await _connect(config);
      _clients[config.name] = client;
      _tools[config.name] = await client.listTools();
      _errors.remove(config.name);
      _lastAttemptAt.remove(config.name);
      log?.call(
        'MCP 服务 ${config.name} 就绪（${toolsOf(config.name).length} 个工具）',
      );
      return client;
    } catch (error) {
      _errors[config.name] = '$error';
      _lastAttemptAt[config.name] = DateTime.now();
      log?.call('MCP 服务 ${config.name} 不可用：$error');
      await _disconnect(config.name);
      return null;
    }
  }

  /// 连接全部启用服务并刷新工具列表（**启动时**与显式"重试全部"用）。
  ///
  /// 注意：**注册不再调用它**（注册只连自己，见 [register]）——旧实现每次都全量重连，
  /// 是"点注册很久没反应"的根因。
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
      await _connectAndList(config);
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
      // 连接掉了（服务崩过 / 还没连过）：**只重连它自己**，不惊动其它服务（懒连接）
      client = await ensureConnected(targetService);
      client ??= _clients[targetService];
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
        header:
            'MCP 服务配置（M6）：可直接手改。\n'
            'transport: stdio（缺省，用 command/args/env 起本机子进程）或 http\n'
            '（Streamable HTTP 单端点，用 url + headers，headers 里放 Authorization 之类的鉴权头）。',
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
