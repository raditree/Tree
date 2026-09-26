import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 进程外插件宿主（M6b）。
///
/// 协议（行分隔 JSON-RPC 2.0，方法与 MCP 同风格但独立命名）：
/// - 核心 → 插件：`hello`（握手）→ `tools/list` → `tools/call`，另有 `ping` 与
///   `event`（通知，用于把总线事件推给插件）；
/// - 插件 → 核心：只要求**应答**；插件主动发的 `log` / `event` 通知会被收集成
///   [PluginHost.notifications]，由总线转成前端事件（M6c）。
///
/// 与 MCP 客户端一样是"本机直跑、不做安全隔离"：只做超时、崩溃感知与优雅关闭。
/// （stdio/JSON-RPC 的搬运代码与 `mcp_client.dart` 同构：两者协议细节不同、都只有
/// 一份实现，暂时各自持有；出现第三个消费者时再抽公共传输层。）
class PluginHost {
  PluginHost._(this.config, this._process, this._stderr);

  /// 启动插件进程并完成 `hello` 握手。
  static Future<PluginHost> start(
    PluginConfig config, {
    Duration timeout = const Duration(seconds: 20),
    String coreVersion = '',
    void Function(Map<String, dynamic> notification)? onNotification,
  }) async {
    if (config.command.trim().isEmpty) {
      throw PluginException('插件 ${config.id} 未配置 command');
    }
    final Process process;
    try {
      process = await Process.start(
        config.command,
        config.args,
        environment: config.env.isEmpty ? null : config.env,
        runInShell: Platform.isWindows && _needsShell(config.command),
      );
    } catch (error) {
      throw PluginException('启动插件 ${config.id} 失败：$error');
    }
    final StringBuffer stderr = StringBuffer();
    process.stderr
        .transform(utf8.decoder)
        .listen(stderr.write, onError: (Object _) {});
    final PluginHost host = PluginHost._(config, process, stderr)
      .._onNotification = onNotification;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(host._onLine, onError: (Object _) {}, onDone: host._onDone);
    process.exitCode.then((int code) {
      host._exitCode = code;
      host._failPending('插件进程已退出（exit=$code）');
    });
    try {
      final Map<String, dynamic> hello = await host._request(
        'hello',
        <String, dynamic>{
          'protocol': 1,
          'core_version': coreVersion,
          'plugin_id': config.id,
        },
        timeout,
      );
      host.pluginId = (hello['plugin_id'] ?? config.id).toString();
      host.name = (hello['name'] ?? config.name).toString();
      host.capabilities =
          (hello['capabilities'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toList() ??
          const <String>[];
    } catch (error) {
      await host.close();
      rethrow;
    }
    return host;
  }

  static bool _needsShell(String command) {
    final String lower = command.toLowerCase();
    return lower.endsWith('.cmd') ||
        lower.endsWith('.bat') ||
        lower == 'npx' ||
        lower == 'npm' ||
        lower == 'pnpm' ||
        lower == 'yarn';
  }

  final PluginConfig config;
  final Process _process;
  final StringBuffer _stderr;

  /// 插件主动通知的转发口（总线用它转成前端 `plugin_event`）；null = 只收集。
  void Function(Map<String, dynamic> notification)? _onNotification;

  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 0;
  int? _exitCode;
  bool _closed = false;

  /// 插件自报的 id / 展示名（可与配置不同，信插件的）。
  String pluginId = '';
  String name = '';

  /// 插件声明的能力（如 tools/events）。
  List<String> capabilities = const <String>[];

  /// 插件主动发的通知（`log` / `event`），供总线转成前端事件。
  final List<Map<String, dynamic>> notifications = <Map<String, dynamic>>[];

  String get stderrTail {
    final String text = _stderr.toString();
    return text.length <= 2000 ? text : text.substring(text.length - 2000);
  }

  bool get isClosed => _closed || _exitCode != null;

  /// 插件当前暴露的工具。
  Future<List<PluginToolInfo>> listTools({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Map<String, dynamic> result = await _request(
      'tools/list',
      const <String, dynamic>{},
      timeout,
    );
    final Object? raw = result['tools'];
    if (raw is! List<dynamic>) return const <PluginToolInfo>[];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (Map<dynamic, dynamic> item) => PluginToolInfo.fromJson(
            item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
          ),
        )
        .where((PluginToolInfo tool) => tool.name.isNotEmpty)
        .toList(growable: false);
  }

  /// 调用插件工具；失败返回**可读结果**（不抛异常，工具层直接用）。
  Future<PluginCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    try {
      final Map<String, dynamic> result = await _request(
        'tools/call',
        <String, dynamic>{'name': toolName, 'arguments': arguments},
        timeout,
      );
      final List<String> parts = <String>[];
      final Object? content = result['content'];
      if (content is List<dynamic>) {
        for (final dynamic item in content) {
          if (item is Map<dynamic, dynamic>) {
            if (item['type'] == 'text') {
              parts.add('${item['text'] ?? ''}');
            } else {
              parts.add(jsonEncode(item));
            }
          } else {
            parts.add('$item');
          }
        }
      } else if (result['text'] != null) {
        parts.add('${result['text']}');
      }
      return PluginCallResult(
        text: parts.join('\n'),
        isError: result['isError'] == true,
        raw: result,
      );
    } catch (error) {
      return PluginCallResult(text: '插件工具调用失败：$error', isError: true);
    }
  }

  /// 把总线事件推给插件（通知，不等应答）。
  void dispatchEvent(Map<String, dynamic> event) {
    if (isClosed) return;
    try {
      _write(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'event',
        'params': event,
      });
    } catch (_) {
      // 插件已死：由心跳/调用路径感知并标记不可用
    }
  }

  /// 心跳探测：返回是否存活。
  Future<bool> ping({Duration timeout = const Duration(seconds: 5)}) async {
    if (isClosed) return false;
    try {
      await _request('ping', const <String, dynamic>{}, timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> _requestResult(Map<String, dynamic> message) {
    final Object? error = message['error'];
    if (error is Map<dynamic, dynamic>) {
      throw PluginException('插件返回错误：${error['message'] ?? jsonEncode(error)}');
    }
    final Object? result = message['result'];
    if (result is Map<dynamic, dynamic>) {
      return result.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params,
    Duration timeout,
  ) {
    if (isClosed) {
      return Future<Map<String, dynamic>>.error(
        PluginException('插件 ${config.id} 已关闭'),
      );
    }
    final int id = ++_nextId;
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _write(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw PluginException(
          '插件 ${config.id} 的 $method 超时（${timeout.inSeconds}s）',
        );
      },
    );
  }

  void _write(Map<String, dynamic> message) {
    _process.stdin.writeln(jsonEncode(message));
  }

  void _onLine(String line) {
    final String text = line.trim();
    if (text.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final Object? id = decoded['id'];
    if (id is! int) {
      // 插件主动通知（log/event）：收集并转发（总线转前端 plugin_event）
      notifications.add(decoded);
      _onNotification?.call(decoded);
      return;
    }
    final Completer<Map<String, dynamic>>? completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    try {
      completer.complete(_requestResult(decoded));
    } catch (error) {
      completer.completeError(error);
    }
  }

  void _onDone() => _failPending('插件 ${config.id} 的输出流已关闭');

  void _failPending(String message) {
    final List<Completer<Map<String, dynamic>>> waiting = _pending.values
        .toList(growable: false);
    _pending.clear();
    for (final Completer<Map<String, dynamic>> completer in waiting) {
      if (!completer.isCompleted) {
        completer.completeError(PluginException(message));
      }
    }
  }

  /// 关闭：礼貌通知 → 关 stdin → 超时后强杀。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _write(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'shutdown',
        'params': const <String, dynamic>{},
      });
    } catch (_) {}
    _failPending('插件 ${config.id} 已关闭');
    try {
      await _process.stdin.close();
    } catch (_) {}
    try {
      await _process.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      _process.kill();
    }
  }
}

/// 插件相关错误（可读中文）。
class PluginException implements Exception {
  PluginException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 插件配置（`<数据根>/config/plugins.yaml` 的一项）。
class PluginConfig {
  PluginConfig({
    required this.id,
    required this.command,
    this.name = '',
    List<String>? args,
    Map<String, String>? env,
    this.enabled = true,
    this.granularity = 'team',
    Map<String, dynamic>? scope,
  }) : args = args ?? <String>[],
       env = env ?? <String, String>{},
       scope = scope ?? <String, dynamic>{};

  final String id;
  final String name;
  final String command;
  final List<String> args;
  final Map<String, String> env;
  final bool enabled;

  /// 实例粒度：`team` / `agent` / `session`（与前端契约一致）。
  final String granularity;

  /// 实例 scope 四元组（team_id/agent_id/session_id；空串表示"不限定"）。
  final Map<String, dynamic> scope;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'command': command,
    'args': args,
    'env': env,
    'enabled': enabled,
    'granularity': granularity,
    'scope': scope,
  };

  /// 前端形态（`GET /api/plugin/snapshot` 的 config 段）。
  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'plugin_id': id,
    'name': name,
    'command': command,
    'args': args,
    'enabled': enabled,
    'granularity': granularity,
  };

  static PluginConfig fromJson(Map<String, dynamic> json) => PluginConfig(
    id: (json['id'] ?? json['plugin_id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    command: (json['command'] ?? '').toString(),
    args:
        (json['args'] as List<dynamic>?)
            ?.map((dynamic e) => e.toString())
            .toList() ??
        const <String>[],
    env: <String, String>{
      for (final MapEntry<dynamic, dynamic> e
          in (json['env'] as Map<dynamic, dynamic>? ?? <dynamic, dynamic>{})
              .entries)
        e.key.toString(): e.value.toString(),
    },
    enabled: json['enabled'] != false,
    granularity: (json['granularity'] ?? 'team').toString(),
    scope:
        (json['scope'] as Map<dynamic, dynamic>?)?.map(
          (dynamic k, dynamic v) => MapEntry(k.toString(), v),
        ) ??
        <String, dynamic>{},
  );
}

/// 插件工具（`tools/list` 的一项）。
class PluginToolInfo {
  PluginToolInfo({
    required this.name,
    this.description = '',
    Map<String, dynamic>? inputSchema,
  }) : inputSchema =
           inputSchema ??
           <String, dynamic>{
             'type': 'object',
             'properties': <String, dynamic>{},
           };

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  static PluginToolInfo fromJson(Map<String, dynamic> json) => PluginToolInfo(
    name: (json['name'] ?? '').toString(),
    description: (json['description'] ?? '').toString(),
    inputSchema: (json['inputSchema'] as Map<dynamic, dynamic>?)?.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    ),
  );
}

/// 一次插件工具调用结果。
class PluginCallResult {
  PluginCallResult({
    required this.text,
    this.isError = false,
    this.raw = const <String, dynamic>{},
  });

  final String text;
  final bool isError;
  final Map<String, dynamic> raw;
}

/// 插件工具命名空间：`plugin__<插件id>__<工具名>`（与 MCP 的 `mcp__` 区分）。
String namespacedPluginTool(String pluginId, String tool) =>
    'plugin__${pluginId}__$tool';

/// 解析插件工具名；非法返回 null。
({String pluginId, String tool})? parseNamespacedPluginTool(String name) {
  if (!name.startsWith('plugin__')) return null;
  final String rest = name.substring(8);
  final int index = rest.indexOf('__');
  if (index <= 0 || index >= rest.length - 2) return null;
  return (pluginId: rest.substring(0, index), tool: rest.substring(index + 2));
}
