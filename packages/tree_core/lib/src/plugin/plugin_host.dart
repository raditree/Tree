import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../util/liveness.dart';
import 'station_runtime.dart';
import 'station_scope.dart';

/// 进程外插件宿主（M6b）。
///
/// 协议（行分隔 JSON-RPC 2.0，方法与 MCP 同风格但独立命名）：
/// - 核心 → 插件：`hello`（握手）→ `tools/list` → `tools/call`，另有 `ping` 与
///   `event`（通知，用于把总线事件推给插件）；
/// - 插件 → 核心：只要求**应答**；插件主动发的 `log` / `event` 通知会被收集成
///   [PluginHost.notifications]，由总线转成前端事件（M6c）。
///
/// 与 MCP 客户端一样是"本机直跑、不做安全隔离"：只做**心跳判活**、崩溃感知与优雅关闭。
///
/// M9 §1.1：**取消静态总时间上限**——tools/call 跑多久都不因时间失败，判据换成
/// 心跳丢失（连续 N 拍没有任何入站证据 ⇒ 标记 degraded；只标记、不终止，见
/// PluginBus.watchdog）。唯一保留的短窗口是**建连握手**（hello / 首次 tools/list）：
/// 没有它就无法诊断"插件根本没起来"。
/// （stdio/JSON-RPC 的搬运代码与 `mcp_client.dart` 同构：两者协议细节不同、都只有
/// 一份实现，暂时各自持有；出现第三个消费者时再抽公共传输层。）
class PluginHost {
  PluginHost._(
    this.config,
    this._process,
    this._stderr,
    Duration heartbeatInterval,
  ) : liveness = LivenessTracker(
        label: '插件 ${config.id}',
        interval: heartbeatInterval,
      );

  /// 启动插件进程并完成 `hello` 握手。
  static Future<PluginHost> start(
    PluginConfig config, {
    Duration timeout = const Duration(seconds: 20),
    Duration heartbeatInterval = LivenessTracker.defaultInterval,
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
    final PluginHost host = PluginHost._(
      config,
      process,
      stderr,
      heartbeatInterval,
    ).._onNotification = onNotification;
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
        timeout: timeout,
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

  /// 心跳台账（M9 §1.1）：**任意入站报文都算一次心跳**（数据还在流动即链路活着），
  /// 由 PluginBus 的看门狗每过一拍探测一次；连续 N 拍未达 ⇒ degraded。
  ///
  /// 单拍窗口 = 心跳间隔 I（由总线注入，默认 10s）。
  final LivenessTracker liveness;

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
      timeout: timeout,
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
  ///
  /// **无静态总时长上限**（M9 §1.1）：插件跑多久都等；只有插件进程退出 / 输出流
  /// 关闭（[_failPending]）才会让在途调用以可读错误显式失败。
  Future<PluginCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    try {
      final Map<String, dynamic> result = await _request(
        'tools/call',
        <String, dynamic>{'name': toolName, 'arguments': arguments},
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

  /// 心跳探测：返回**这一拍**是否活着。
  ///
  /// 窗口 = 一个心跳间隔 I（默认 10s）——这是「这一拍有没有心跳」的窗口，
  /// **不是**任务总时长上限（见 [LivenessTracker] 的说明）。
  Future<bool> ping({Duration? timeout}) async {
    if (isClosed) return false;
    try {
      await _request(
        'ping',
        const <String, dynamic>{},
        timeout: timeout ?? liveness.interval,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// **收集站请求（站 → 插件）**：把站点请求经 stdio 发过去并等回包。
  ///
  /// 无静态超时（同 tools/call）；插件未实现 / 异常时返回**可读失败回包**，
  /// 由站点的收集语义把它记成「未响应者」，不静默。
  Future<StationReply> requestStation(StationRequest request) async {
    if (isClosed) return StationReply.failed('插件 ${config.id} 已关闭');
    try {
      final Map<String, dynamic> result = await _request(
        'station/request',
        request.toJson(),
      );
      final Object? rawReply = result['reply'] ?? result;
      // 回包可选回带 scope：带了就必须与请求四元组精确相等（fail-closed），
      // 没带则由站点按 request_id → 订阅者身份归属，不存在"投给别人"的路径。
      if (rawReply is Map && rawReply['scope'] != null) {
        final StationScope echoed = StationScope.parse(rawReply['scope']);
        if (!echoed.exactEquals(request.scope)) {
          return StationReply.failed(
            '回包 scope 与请求不一致（跨 scope 回包被拒）：'
            '请求 ${request.scope.describe()}，回包 ${echoed.describe()}',
          );
        }
      }
      return StationReply.fromJson(rawReply);
    } catch (error) {
      return StationReply.failed('插件未响应收集站请求：$error');
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

  /// [timeout] 为 null（默认）= **无静态超时**：只有进程退出 / 输出流关闭 /
  /// 显式 close 才会让在途请求失败——这就是 1.1 的「取消静态时间超时」。
  /// 只有「建连握手」这种必须能诊断的场景才传一个小窗口。
  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) {
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
    if (timeout == null) return completer.future;
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw PluginException(
          '插件 ${config.id} 的 $method 无响应（建连窗口 ${timeout.inMilliseconds}ms）',
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
    // 任意入站报文都是「链路还活着」的证据（M9 §1.1：成功响应同样算心跳）
    liveness.recordBeat();
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
