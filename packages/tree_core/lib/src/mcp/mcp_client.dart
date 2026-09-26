import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../util/liveness.dart';

/// MCP（Model Context Protocol）stdio 客户端（M6a）。
///
/// 协议边界：JSON-RPC 2.0、**按行分隔**（MCP stdio 传输的规定），流程为
/// `initialize` → `notifications/initialized` → `tools/list` / `tools/call`。
/// 这里刻意只实现这三个方法：桌面端把 MCP 当"工具来源"用，不需要 resources/
/// prompts/sampling 那些面。
///
/// 进程外运行、无沙箱（用户明确要求"插件直接本机运行"）：因此**不做安全隔离**，
/// 只做活性判定、崩溃感知与优雅关闭，避免一个坏插件把核心进程拖死。
///
/// **超时口径（M9 规约 1.1：取消静态时间超时，改心跳丢失判超时）**
/// - **没有任务总时长上限**：一次 `tools/call` 想跑多久就跑多久，绝不因为"总耗时到了"
///   被丢弃。要避开的正是"心跳还在、只是总时间长了就被判超时丢掉"；
/// - 判死的唯一依据是**心跳丢失**：MCP 有 `ping` 语义，就用它——每 [heartbeatInterval]
///   发一次 `ping`，一拍内**没有收到任何协议消息**（ping 回包、任意请求的成功/错误
///   响应、服务端通知都算）就记一次丢失；连续 [missedHeartbeatLimit] 次（默认 3）即判
///   **链路失活（degraded）**，在途请求立刻以**显式错误**结束（既不静默挂死，也不
///   静默丢弃），并可从 [isDegraded] / [missedCount] 观测到；
/// - **为什么不用静态超时**：慢的 MCP 服务（拉远端数据、跑大模型、编译）本来就可能
///   跑几分钟——用"总时长"当判据必然误杀；而"连续 N 拍一声不吭"只说明链路死了，
///   这才是真实的失败信号。心跳恢复（任意一条协议消息）后失活标记**自动清除**，
///   连接不重建也能继续用；
/// - 握手（`initialize`）同样不用静态窗口：进程起来了却一声不吭 = 心跳丢失，
///   由同一套心跳判据负责，所以这里**没有任何 timeout 参数**。副作用是"启动窗口"
///   也由心跳给出（默认 I×N = 30s）：npx/node 冷启动几秒绰绰有余，真起不来就以
///   心跳丢失显式失败，而不是让核心一直挂着；
///
/// MCP 客户端接口：真实现是 [McpClient.start]（stdio 子进程），测试可注入假实现。
abstract interface class McpClient {
  /// 启动一个 MCP 服务进程并完成握手（用心跳判活，没有静态握手超时）。
  static Future<McpClient> start(
    McpServerConfig config, {
    Duration heartbeatInterval = LivenessTracker.defaultInterval,
    int missedHeartbeatLimit = LivenessTracker.defaultMaxMisses,
  }) => _StdioMcpClient.start(
    config,
    heartbeatInterval: heartbeatInterval,
    missedHeartbeatLimit: missedHeartbeatLimit,
  );

  /// 已握手的服务信息（initialize 的 result）。
  Map<String, dynamic> get serverInfo;

  /// 服务声明的协议版本。
  String get protocolVersion;

  /// 子进程 stderr 的最后若干内容（报错时附上，便于排查插件）。
  String get stderrTail;

  bool get isClosed;

  /// 链路活性台账：最近心跳时间 / 连续丢失次数 / 是否失活（供上层观测与重连决策）。
  LivenessTracker get liveness;

  /// 是否已判 degraded（连续 N 次心跳丢失）；心跳恢复后自动变回 false。
  bool get isDegraded;

  /// 累计进入 degraded 的次数（排障与 UI 展示用）。
  int get degradeCount;

  /// `tools/list`：返回该服务暴露的工具。
  Future<List<McpToolInfo>> listTools();

  /// `tools/call`：调用一个工具，把 content 拼成文本（模型直接可读）。
  ///
  /// **没有 timeout 参数**：跑多久由心跳说了算（见类文档）。
  Future<McpCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments,
  );

  /// 关闭：先关 stdin（礼貌退出），再杀进程（兜底）。
  Future<void> close();
}

class _StdioMcpClient implements McpClient {
  /// 启动一个 MCP 服务进程并完成握手（心跳判活，见类文档）。
  static Future<McpClient> start(
    McpServerConfig config, {
    Duration heartbeatInterval = LivenessTracker.defaultInterval,
    int missedHeartbeatLimit = LivenessTracker.defaultMaxMisses,
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
    // 协议上都是 UTF-8，但一个坏字节不该中断整条通道：allowMalformed 把非法字节换成
    // U+FFFD，stderr 照常收进错误文本里，进程与心跳都不受影响。
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(stderr.write, onError: (Object _) {});
    final _StdioMcpClient client = _StdioMcpClient._(
      config,
      process,
      stderr,
      LivenessTracker(
        label: 'MCP 服务 ${config.name}',
        interval: heartbeatInterval,
        maxMisses: missedHeartbeatLimit,
      ),
    );
    bool warnedMalformed = false;
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (String line) {
            if (!warnedMalformed && line.contains('\uFFFD')) {
              warnedMalformed = true;
              // 只说一次：坏字节替换成 U+FFFD 是"看得见的告警"，但**不中断**通道
              stderr.writeln(
                '[tree] 警告：MCP 服务 ${config.name} 的输出含非法 UTF-8 字节，已按 U+FFFD 顶替',
              );
            }
            client._onLine(line);
          },
          onError: (Object _) {},
          onDone: client._onDone,
        );
    process.exitCode.then((int code) {
      client._exitCode = code;
      client._failPending('MCP 服务进程已退出（exit=$code）');
    });
    // 心跳循环在**握手之前**就起来：进程起了却一直不说话会被判"心跳丢失"，
    // 而不是等一个静态的握手超时——判据因此只有一套（M9 规约 1.1）。
    client._startHeartbeat();
    try {
      await client._initialize();
    } catch (error) {
      await client.close();
      rethrow;
    }
    return client;
  }

  _StdioMcpClient._(this.config, this._process, this._stderr, this.liveness);

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

  /// 链路活性台账（心跳丢失判据）。
  @override
  final LivenessTracker liveness;

  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 0;
  int? _exitCode;
  bool _closed = false;

  /// 心跳探活循环（每 [LivenessTracker.interval] 一拍）。
  Timer? _heartbeatTimer;

  /// 本拍内是否收到过任何协议消息（收到即算心跳）。
  bool _beatSinceTick = false;

  /// 上一拍结束时是否已判失活（用来只在"刚判死"的那一刻计一次降级）。
  bool _wasStale = false;

  int _degradeCount = 0;

  @override
  bool get isDegraded => liveness.isStale;

  @override
  int get degradeCount => _degradeCount;

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
  Future<List<McpToolInfo>> listTools() async {
    final Map<String, dynamic> result = await _request(
      'tools/list',
      const <String, dynamic>{},
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
    Map<String, dynamic> arguments,
  ) async {
    final Map<String, dynamic> result = await _request(
      'tools/call',
      <String, dynamic>{'name': toolName, 'arguments': arguments},
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

  Future<void> _initialize() async {
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

  /// 发一个请求并等回包。
  ///
  /// **没有静态超时**：等待时长完全由心跳决定——[LivenessTracker.guard] 让"等回包"
  /// 与"链路被判失活"赛跑：失活即抛显式错误，心跳一直在就一直等下去（M9 规约 1.1）。
  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params,
  ) {
    if (isClosed) {
      return Future<Map<String, dynamic>>.error(
        McpException('MCP 服务 ${config.name} 已关闭'),
      );
    }
    // 已判失活就不必再往这条链路发新请求：直接显式失败（最快的失败，也最省事）
    if (liveness.isStale) {
      return Future<Map<String, dynamic>>.error(_livenessError(method));
    }
    final int id = ++_nextId;
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _write(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
    } catch (error) {
      _pending.remove(id);
      return Future<Map<String, dynamic>>.error(error);
    }
    return _awaitReply(id, method, completer);
  }

  /// 等回包：在途期间链路被判失活 ⇒ 以「心跳丢失」显式失败（不挂起、不静默）。
  Future<Map<String, dynamic>> _awaitReply(
    int id,
    String method,
    Completer<Map<String, dynamic>> completer,
  ) async {
    try {
      return await liveness.guard(() => completer.future);
    } on LivenessLostException catch (error) {
      _pending.remove(id);
      final McpLivenessException lost = _livenessError(method, cause: error);
      // 回包可能永远不来；这里主动收口，避免留下一个悬空的 completer
      if (!completer.isCompleted) completer.completeError(lost);
      throw lost;
    } finally {
      _pending.remove(id);
    }
  }

  /// 心跳丢失时的显式错误（文案含「心跳丢失」「链路失活」，上层与模型都能读懂）。
  McpLivenessException _livenessError(String method, {Object? cause}) =>
      McpLivenessException(
        'MCP 服务 ${config.name} 的 $method 心跳丢失（链路失活）：'
        '连续 ${liveness.missedCount} 次心跳未达（心跳间隔 '
        '${LivenessTracker.formatDuration(liveness.interval)}，阈值 '
        '${liveness.maxMisses} 次）；连接未关闭，心跳恢复后自动清除',
        service: config.name,
        method: method,
        missedCount: liveness.missedCount,
        interval: liveness.interval,
        maxMisses: liveness.maxMisses,
        cause: cause,
      );

  // ── 心跳探活（M9 规约 1.1：判据是"心跳丢了"，不是"总时长超了"）────────────

  /// 启动心跳循环：每 [LivenessTracker.interval] 一拍——结算上一拍 + 发一次 ping。
  ///
  /// 间隔非正数 = 关闭心跳观测（测试 / 特殊场景）。
  void _startHeartbeat() {
    final Duration interval = liveness.interval;
    if (interval <= Duration.zero) return;
    _heartbeatTimer = Timer.periodic(interval, (Timer _) => _heartbeatTick());
  }

  void _heartbeatTick() {
    if (_closed) {
      _stopHeartbeat();
      return;
    }
    // 一拍结算：这一拍内收到过任何协议消息 ⇒ 心跳在，清零；否则记一次丢失。
    if (_beatSinceTick) {
      _beatSinceTick = false;
    } else {
      final bool staleNow = liveness.recordMiss();
      if (staleNow && !_wasStale) {
        // 刚判死：记一次降级。在途请求由 guard 同步唤醒并以显式错误结束。
        _degradeCount++;
      }
      _wasStale = staleNow;
    }
    _sendPing();
  }

  /// 主动探活：MCP 有 ping 语义就用它。
  ///
  /// 只发不等：ping 的回包（成功或 method-not-found 错误都算）会在 [_onLine] 里被
  /// 记成一次心跳。这样"服务端不支持 ping"也不会把自己判死——只要它还在回别的消息。
  void _sendPing() {
    if (isClosed) return;
    try {
      _write(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': ++_nextId,
        'method': 'ping',
        'params': const <String, dynamic>{},
      });
    } catch (_) {
      // 写失败：进程已经不在了，退出码回调会负责收口
    }
  }

  /// 记一次心跳：收到任意一条协议消息（成功响应 / 错误响应 / 服务端通知）都算。
  void _beat() {
    _beatSinceTick = true;
    _wasStale = false;
    liveness.recordBeat();
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
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
      return; // 非 JSON 输出（插件日志）：忽略，不打断协议，也不算心跳
    }
    if (decoded is! Map<String, dynamic>) return;
    // 任意一条合法 JSON-RPC 消息都是"链路还活着"的证据：请求的响应（成功或错误）、
    // ping 的回包、服务端主动发的通知，一律记一次心跳——这正是"心跳还在就永不判死"
    // 的依据（M9 规约 1.1）。
    _beat();
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
    _stopHeartbeat();
    _failPending('MCP 服务 ${config.name} 已关闭');
    try {
      await _process.stdin.close();
    } catch (_) {}
    try {
      // 这 2s 是**关闭时的收尾窗口**（等礼貌退出的进程自己走），不是任务时长上限：
      // 超时就杀进程兜底，避免关核心时被一个坏插件挂住。
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

/// MCP 链路**心跳丢失**（link degraded）时抛出的显式错误（M9 规约 1.1）。
///
/// 单独一个类型是为了让上层（工具层 / UI / 测试）能把"链路心跳丢了"与"这个工具自己
/// 报错"分开：前者该提示用户检查 MCP 服务 / 等它恢复，后者该让模型改参数重试。
/// 文案里同时含「心跳丢失」与「链路失活」，并且带上观测值（连续丢失次数、间隔、阈值）。
class McpLivenessException extends McpException {
  McpLivenessException(
    super.message, {
    this.service = '',
    this.method = '',
    this.missedCount = 0,
    this.interval = LivenessTracker.defaultInterval,
    this.maxMisses = LivenessTracker.defaultMaxMisses,
    this.cause,
  });

  /// 出问题的 MCP 服务名。
  final String service;

  /// 触发这次失败的方法（如 tools/call）。
  final String method;

  /// 判死时的连续丢失次数。
  final int missedCount;

  /// 心跳间隔 I。
  final Duration interval;

  /// 允许连续丢失的次数 N。
  final int maxMisses;

  /// 原始失活错误（若来自通用台账）。
  final Object? cause;

  /// 显式标志：这是"链路失活"而不是工具自身失败。
  bool get livenessLost => true;
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
