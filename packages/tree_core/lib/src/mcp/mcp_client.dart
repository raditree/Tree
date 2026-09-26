import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// MCP（Model Context Protocol）stdio 客户端（M6a）。
///
/// 协议边界：JSON-RPC 2.0、**按行分隔**（MCP stdio 传输的规定），流程为
/// `initialize` → `notifications/initialized` → `tools/list` / `tools/call`。
/// 这里刻意只实现这三个方法：桌面端把 MCP 当"工具来源"用，不需要 resources/
/// prompts/sampling 那些面。
///
/// 进程外运行、无沙箱（用户明确要求"插件直接本机运行"）：因此**不做安全隔离**，
/// 只做超时、崩溃感知与优雅关闭，避免一个坏插件把核心进程拖死。
/// MCP 客户端接口：真实现是 [McpClient.start]（stdio 子进程），测试可注入假实现。
abstract interface class McpClient {
  /// 启动一个 MCP 服务进程并完成握手。
  static Future<McpClient> start(
    McpServerConfig config, {
    Duration timeout = const Duration(seconds: 20),
  }) => _StdioMcpClient.start(config, timeout: timeout);

  /// 已握手的服务信息（initialize 的 result）。
  Map<String, dynamic> get serverInfo;

  /// 服务声明的协议版本。
  String get protocolVersion;

  /// 子进程 stderr 的最后若干内容（报错时附上，便于排查插件）。
  String get stderrTail;

  bool get isClosed;

  /// `tools/list`：返回该服务暴露的工具。
  Future<List<McpToolInfo>> listTools({Duration timeout});

  /// `tools/call`：调用一个工具，把 content 拼成文本（模型直接可读）。
  Future<McpCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    Duration timeout,
  });

  /// 关闭：先关 stdin（礼貌退出），再杀进程（兜底）。
  Future<void> close();
}

class _StdioMcpClient implements McpClient {
  /// 启动一个 MCP 服务进程并完成握手。
  static Future<McpClient> start(
    McpServerConfig config, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (config.command.trim().isEmpty) {
      throw McpException('MCP 服务 ${config.name} 未配置 command');
    }
    final Process process;
    try {
      process = await Process.start(
        config.command,
        config.args,
        environment: config.env.isEmpty ? null : config.env,
        // Windows 上 npx/.cmd 必须经 shell 才能解析（与终端工具同一策略）
        runInShell: Platform.isWindows && _needsShell(config.command),
      );
    } catch (error) {
      throw McpException('启动 MCP 服务 ${config.name} 失败：$error');
    }
    final StringBuffer stderr = StringBuffer();
    process.stderr
        .transform(utf8.decoder)
        .listen(stderr.write, onError: (Object _) {});
    final _StdioMcpClient client = _StdioMcpClient._(config, process, stderr);
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(client._onLine, onError: (Object _) {}, onDone: client._onDone);
    process.exitCode.then((int code) {
      client._exitCode = code;
      client._failPending('MCP 服务进程已退出（exit=$code）');
    });
    try {
      await client._initialize(timeout);
    } catch (error) {
      await client.close();
      rethrow;
    }
    return client;
  }

  _StdioMcpClient._(this.config, this._process, this._stderr);

  static bool _needsShell(String command) {
    final String lower = command.toLowerCase();
    return lower.endsWith('.cmd') ||
        lower.endsWith('.bat') ||
        lower == 'npx' ||
        lower == 'npm' ||
        lower == 'pnpm' ||
        lower == 'yarn';
  }

  final McpServerConfig config;
  final Process _process;
  final StringBuffer _stderr;

  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 0;
  int? _exitCode;
  bool _closed = false;

  /// 已握手的服务信息（initialize 的 result）。
  @override
  Map<String, dynamic> serverInfo = <String, dynamic>{};

  /// 服务声明的协议版本。
  @override
  String protocolVersion = '';

  /// 子进程 stderr 的最后若干内容（报错时附上，便于排查插件）。
  @override
  String get stderrTail {
    final String text = _stderr.toString();
    return text.length <= 2000 ? text : text.substring(text.length - 2000);
  }

  @override
  bool get isClosed => _closed || _exitCode != null;

  /// `tools/list`：返回该服务暴露的工具。
  @override
  Future<List<McpToolInfo>> listTools({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Map<String, dynamic> result = await _request(
      'tools/list',
      const <String, dynamic>{},
      timeout,
    );
    final Object? raw = result['tools'];
    if (raw is! List<dynamic>) return const <McpToolInfo>[];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (Map<dynamic, dynamic> item) => McpToolInfo.fromJson(
            item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
          ),
        )
        .toList(growable: false);
  }

  /// `tools/call`：调用一个工具，把 content 拼成文本（模型直接可读）。
  @override
  Future<McpCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
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
          final Map<dynamic, dynamic> map = item;
          if (map['type'] == 'text') {
            parts.add('${map['text'] ?? ''}');
          } else {
            parts.add(jsonEncode(map));
          }
        } else {
          parts.add('$item');
        }
      }
    } else if (content != null) {
      parts.add('$content');
    }
    return McpCallResult(
      text: parts.join('\n'),
      isError: result['isError'] == true,
      raw: result,
    );
  }

  Future<void> _initialize(Duration timeout) async {
    final Map<String, dynamic> result = await _request(
      'initialize',
      <String, dynamic>{
        'protocolVersion': '2024-11-05',
        'capabilities': <String, dynamic>{},
        'clientInfo': <String, dynamic>{
          'name': 'tree_core',
          'version': '1.0.0',
        },
      },
      timeout,
    );
    serverInfo =
        (result['serverInfo'] as Map<dynamic, dynamic>?)?.map(
          (dynamic k, dynamic v) => MapEntry(k.toString(), v),
        ) ??
        <String, dynamic>{};
    protocolVersion = (result['protocolVersion'] ?? '').toString();
    _notify('notifications/initialized', const <String, dynamic>{});
  }

  Map<String, dynamic> _requestResult(Map<String, dynamic> message) {
    final Object? error = message['error'];
    if (error is Map<dynamic, dynamic>) {
      throw McpException('MCP 返回错误：${error['message'] ?? jsonEncode(error)}');
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
        McpException('MCP 服务 ${config.name} 已关闭'),
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
        throw McpException(
          'MCP 服务 ${config.name} 的 $method 超时（${timeout.inSeconds}s）',
        );
      },
    );
  }

  void _notify(String method, Map<String, dynamic> params) {
    _write(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
  }

  void _write(Map<String, dynamic> message) {
    try {
      _process.stdin.writeln(jsonEncode(message));
    } catch (error) {
      throw McpException('写入 MCP 服务 ${config.name} 失败：$error');
    }
  }

  void _onLine(String line) {
    final String text = line.trim();
    if (text.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return; // 非 JSON 输出（插件日志）：忽略，不打断协议
    }
    if (decoded is! Map<String, dynamic>) return;
    final Object? id = decoded['id'];
    if (id is! int) return; // 通知/日志：无需应答
    final Completer<Map<String, dynamic>>? completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    try {
      completer.complete(_requestResult(decoded));
    } catch (error) {
      completer.completeError(error);
    }
  }

  void _onDone() => _failPending('MCP 服务 ${config.name} 的输出流已关闭');

  void _failPending(String message) {
    final List<Completer<Map<String, dynamic>>> waiting = _pending.values
        .toList(growable: false);
    _pending.clear();
    for (final Completer<Map<String, dynamic>> completer in waiting) {
      if (!completer.isCompleted) {
        completer.completeError(McpException(message));
      }
    }
  }

  /// 关闭：先关 stdin（礼貌退出），再杀进程（兜底）。
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failPending('MCP 服务 ${config.name} 已关闭');
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

/// MCP 相关错误（可读中文，直接可以给模型/用户看）。
class McpException implements Exception {
  McpException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一个 MCP 服务（stdio 外接）的配置。
class McpServerConfig {
  McpServerConfig({
    required this.name,
    required this.command,
    List<String>? args,
    Map<String, String>? env,
    this.enabled = true,
    this.builtin = false,
    this.scope = '',
  }) : args = args ?? <String>[],
       env = env ?? <String, String>{};

  final String name;
  final String command;
  final List<String> args;
  final Map<String, String> env;
  final bool enabled;

  /// 是否为内置服务（内置的不可删除，只可禁用）。
  final bool builtin;

  /// 归属范围（前端"按当前会话模式自动落点"用；桌面端只做展示与持久化）。
  final String scope;

  McpServerConfig copyWith({bool? enabled}) => McpServerConfig(
    name: name,
    command: command,
    args: args,
    env: env,
    enabled: enabled ?? this.enabled,
    builtin: builtin,
    scope: scope,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'command': command,
    'args': args,
    'env': env,
    'enabled': enabled,
    'builtin': builtin,
    'scope': scope,
  };

  /// 前端形态（`GET /api/mcp/services`）。
  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'name': name,
    'command': command,
    'args': args,
    'builtin': builtin,
    'enabled': enabled,
    'scope': scope,
  };

  static McpServerConfig fromJson(Map<String, dynamic> json) => McpServerConfig(
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
    builtin: json['builtin'] == true,
    scope: (json['scope'] ?? '').toString(),
  );
}

/// 一个 MCP 工具（`tools/list` 的一项）。
class McpToolInfo {
  McpToolInfo({
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

  static McpToolInfo fromJson(Map<String, dynamic> json) => McpToolInfo(
    name: (json['name'] ?? '').toString(),
    description: (json['description'] ?? '').toString(),
    inputSchema: (json['inputSchema'] as Map<dynamic, dynamic>?)?.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    ),
  );
}

/// 一次 MCP 工具调用结果。
class McpCallResult {
  McpCallResult({
    required this.text,
    this.isError = false,
    this.raw = const <String, dynamic>{},
  });

  final String text;
  final bool isError;
  final Map<String, dynamic> raw;
}

/// 命名空间工具名：`mcp__<service>__<tool>`（与参考实现一致）。
String namespacedToolName(String service, String tool) =>
    'mcp__${service}__$tool';

/// 解析命名空间工具名；非法返回 null。
({String service, String tool})? parseNamespacedToolName(String name) {
  if (!name.startsWith('mcp__')) return null;
  final String rest = name.substring(5);
  final int index = rest.indexOf('__');
  if (index <= 0 || index >= rest.length - 2) return null;
  return (service: rest.substring(0, index), tool: rest.substring(index + 2));
}
