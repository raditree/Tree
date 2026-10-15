import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_protocol/tree_protocol.dart' show PluginRpcMethods;

import '../util/liveness.dart';
import 'station_runtime.dart';
import 'station_scope.dart';

/// 进程外插件宿主（M6b）。
///
/// 协议（行分隔 JSON-RPC 2.0，方法与 MCP 同风格但独立命名）：
/// - 核心 → 插件：`hello`（握手）→ `tools/list` → `tools/call`，另有 `ping` 与
///   `event`（通知，用于把总线事件推给插件）；
/// - 插件 → 核心：入站报文按**三类**判别（见 [_onLine]）——
///   ① **响应**：有 `id` 且**没有 `method`**（JSON-RPC 的 Response 形态）——
///      `int id` 命中在途请求即回填，未知 / 重复的回包丢弃；
///   ② **请求**：带 `method` + `id`（插件**主动**调核心；执行站的
///      `station/command` 走这里，M9 §3「插件主动下命令」）。这类报文一律交给
///      [onPluginRequest]，并**必须且只能回一条**响应（成功 result / 失败 error），
///      处理器抛异常也变成 error 响应（异常绝不冲掉读循环）；未接线处理器 ⇒
///      `-32601`（不静默）；
///   ③ **通知**：其余（如 `log` / `event`，含不带 id 的通知形态），收集成
///      [PluginHost.notifications]，由总线转成前端事件（M6c）。
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
  ///
  /// [resumeDumpId]（20261015-hot-restart 阶段 1）：热重启后交给**新一世**的可续跑快照 id。
  /// 方向必须没提错：`hello` 是**核心→插件**的请求，所以这个信息只能出现在它的
  /// **参数**里（而不是“hello 响应”——响应是插件自己写的，它无从得知核心池里有什么）。
  /// **为空时不写这个键**：老插件的 hello 参数集与改动前逐字一致（D3 向后兼容）。
  static Future<PluginHost> start(
    PluginConfig config, {
    Duration timeout = const Duration(seconds: 20),
    Duration heartbeatInterval = LivenessTracker.defaultInterval,
    String coreVersion = '',
    String resumeDumpId = '',
    void Function(Map<String, dynamic> notification)? onNotification,
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    )?
    onPluginRequest,
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
    // 同 MCP：协议是 UTF-8，但坏字节只顶替（U+FFFD）不中断通道
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(stderr.write, onError: (Object _) {});
    final PluginHost host =
        PluginHost._(config, process, stderr, heartbeatInterval)
          .._onNotification = onNotification
          ..onPluginRequest = onPluginRequest;
    bool warnedMalformed = false;
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (String line) {
            if (!warnedMalformed && line.contains('\uFFFD')) {
              warnedMalformed = true;
              stderr.writeln(
                '[tree] 警告：插件 ${config.id} 的输出含非法 UTF-8 字节，已按 U+FFFD 顶替',
              );
            }
            host._onLine(line);
          },
          onError: (Object _) {},
          onDone: host._onDone,
        );
    process.exitCode.then((int code) {
      host._exitCode = code;
      host._failPending('插件进程已退出（exit=$code）');
      if (!host._exitSeen.isCompleted) host._exitSeen.complete();
    });
    // stdin 的写队列在插件死亡 / 管道被关时**以异常收尾**（实测 Windows：
    // `SocketException: Write failed (OS Error: 管道正在被关闭。, errno = 232)`）。
    //
    // 关键点是它**不会同步抛**：连写 200 帧实测 0 次同步异常，错误只在 IOSink 的
    // `done` 上异步冒出来。没人听就是**未捕获的异步异常**——测试里判当前用例失败
    // （`plugin_ws_test` 的「进程退出 ⇒ disabled」用例被它按负载偶发打红），生产里
    // 直接打到 zone（根 zone 会终止进程）。所以这里挂一个**常驻**处理器：它在进程
    // 建起来时就挂上，覆盖此后任意时刻的第一笔写失败（晚挂会漏掉先到的错误）。
    unawaited(host._process.stdin.done.catchError(host._onWriteFailure));
    try {
      final Map<String, dynamic> hello = await host._request(
        PluginRpcMethods.hello,
        <String, dynamic>{
          'protocol': 1,
          'core_version': coreVersion,
          'plugin_id': config.id,
          if (resumeDumpId.isNotEmpty) 'resume_dump_id': resumeDumpId,
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
      // 握手没完成就要放弃这个进程。注意这里**不等退出也不给时长宽限**：
      // 这个 host 还没进任何表（看门狗不认识它），而调用方也已在报错路径上——
      // 等它就是一个没人收的无底洞（旧实现靠一个 2s 静态超时堆掉这个洞，而静态时长
      // 本身就是要消除的东西）。所以：发完 shutdown、关掉 stdin，然后直接收尸。
      // 它本来就没有“在跑的工作”可保（连 hello 都没完成），不算丢东西。
      await host.close();
      host.killStray('启动握手未完成 ⇒ 放弃这个进程（收尸，不等时长）');
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

  /// **插件 → 核心**的请求处理器（M9 §3 执行站的核心语义）：插件主动发
  /// `method` + `id` 的请求时调用，返回值作为响应 `result` 回给插件。
  ///
  /// - 可随时设置（总线在插件启动后接线）；null ⇒ 一律回 `-32601`（不静默）；
  /// - 抛 [PluginRequestException] ⇒ 该异常自带的 code / message 变成 error 响应；
  ///   抛其它异常 ⇒ `-32603` + 可读文本（异常绝不冲掉读循环）；
  /// - **一次请求只回一条响应**，失败也回（插件侧不会永久挂起等回包）。
  Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> params,
  )?
  onPluginRequest;

  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  final Completer<void> _exitSeen = Completer<void>();
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

  bool get isClosed => _closed || _exitCode != null || _channelError != null;

  /// **通道断了**的可读原因（stdout 已关闭 / stdin 写失败）；null = 通道还在。
  ///
  /// 与 [_closed]（显式关停）、[_exitCode]（进程退出）并列，但表达的是另一件事：
  /// "进程可能还活着，可我们已经听不见它、或者说不进去了"。三者都让 [isClosed]
  /// 为真——核心 → 插件只能走 stdin、插件 → 核心只能走 stdout，通道断了它就不再
  /// 可用，快照口径也该显示 disabled。
  String? get channelError => _channelError;

  String? _channelError;

  /// 标记通道断了：**只标一次**，并让在途请求立刻拿到可读失败。
  ///
  /// 刻意**不置 [_closed]**：那个字段是 `close()` 的去重开关，在这里置真会让插件
  /// 进程再也不会被 `close()` 收掉（通道断了 ≠ 进程已经结束）。
  void _markChannelDead(String reason) {
    if (_channelError != null) return;
    _channelError = reason;
    _failPending(reason);
  }

  /// stdin 写失败（插件已死 / 管道被关）。
  ///
  /// 这是 [start] 里 `stdin.done` 处理器的落点，也是 [_write] 同步异常的落点。
  void _onWriteFailure(Object error) {
    _markChannelDead('插件 ${config.id} 的 stdin 写入失败（通道已断）：$error');
  }

  /// 插件当前暴露的工具。
  Future<List<PluginToolInfo>> listTools({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Map<String, dynamic> result = await _request(
      PluginRpcMethods.toolsList,
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

  /// 向插件发一次**自有方法**请求（既不是站点，也不是 `tools/call`）。
  ///
  /// 目前只有 SSH 中转站（`ssh_executor`）的 `tunnel.*` 走这条路 —— 执行器是一条
  /// **通道**，不是"点位"，因此刻意不进站点体系（见 `docs/ssh-tunnel-protocol.md` §2）。
  ///
  /// **无静态总时长上限**（M9 §1.1 同一口径）：不开 [timeout] 就一直等，
  /// 只有插件进程退出 / 通道断开（[_failPending]、[_markChannelDead]）才让在途请求
  /// 以可读错误显式失败。这正是"远端命令跑多久都等"能成立的前提。
  Future<Map<String, dynamic>> requestMethod(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) => _request(method, params, timeout: timeout);

  /// 调用插件工具；失败返回**可读结果**（不抛异常，工具层直接用）。
  ///
  /// **无静态总时长上限**（M9 §1.1）：插件跑多久都等；只有插件进程退出 / 输出流
  /// 关闭（[_failPending]）才会让在途调用以可读错误显式失败。
  /// [scope] 非空时随 `tools/call` 一起下发（单实例插件据此知道"这一次是谁在问"）。
  /// 形状与 station/request 的 scope 同源：{team_id, agent_id, session_id, mode_key}。
  Future<PluginCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    Map<String, dynamic>? scope,
  }) async {
    try {
      final Map<String, dynamic> result = await _request(
        PluginRpcMethods.toolsCall,
        <String, dynamic>{
          'name': toolName,
          'arguments': arguments,
          'scope': ?scope,
        },
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
        'method': PluginRpcMethods.event,
        'params': event,
      });
    } catch (_) {
      // 插件已死：由心跳/调用路径感知并标记不可用
    }
  }

  /// **核心 → 插件：`station/cancel` 通知**（流式回填的中断信号）。
  ///
  /// 单向通知、不等应答：插件收到后应停止推流并以 `done`（或直接停发）收尾。
  /// 核心侧在收到取消后**丢弃**该 request_id 迟到的增量（迟到无害，不报错）。
  ///
  /// 为什么需要它：`station/request` 是"一问一答"，插件接管 LLM 后可能长时间推流；
  /// 用户按下停止时，只有这条下行通知能让插件**立刻**知道别再烧算力了。
  void cancelStation({required String requestId, String reason = ''}) {
    if (isClosed) return;
    try {
      _write(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': PluginRpcMethods.stationCancel,
        'params': <String, dynamic>{
          'request_id': requestId,
          if (reason.isNotEmpty) 'reason': reason,
        },
      });
    } catch (_) {
      // 插件已死：由心跳 / 调用路径感知并标记不可用
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
        PluginRpcMethods.ping,
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
        PluginRpcMethods.stationRequest,
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
        // 通道断了（stdout 关闭 / stdin 写失败）时**说实话**：不是"没请求过"，
        // 而是"这个插件已经说不上话了"，原因直接回给调用方。
        PluginException(_channelError ?? '插件 ${config.id} 已关闭'),
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
    // 通道已断：再写只会再喂一次未捕获的异步错误（见 [start] 里的 done 处理器）。
    if (_channelError != null) return;
    try {
      _process.stdin.writeln(jsonEncode(message));
    } catch (error) {
      // 异步失败走 `done`（见 [start]）；这里只兜同步路径：`stdin` 被 `close()`
      // 之后再写会同步抛 StateError。
      _onWriteFailure(error);
    }
  }

  /// 入站报文的**三类判别**（顺序即优先级）：
  ///
  /// ① **响应**：有 `id` 且**没有 `method`**（JSON-RPC 的 Response 形态）⇒
  ///    `int id` 命中 [_pending] 即完成在途 Future；未知 / 重复的回包丢弃
  ///    （不重复完成、不抛异常）。判别用"有没有 method"而不是"id 命中"，是为了
  ///    插件用自增 int id 发请求时不会与核心在途请求撞号而被当成回包吞掉。
  /// ② **请求**：带非空字符串 `method` + 有 `id` ⇒ 交给 [onPluginRequest]，
  ///    由 [_answerRequest] **必回一条**响应（插件主动调核心的通道）。
  /// ③ **通知**：其余（`log` / `event`，含不带 id 的通知形态）⇒ 收集 + 转发。
  ///
  /// 判别只看报文形状，不看"插件有没有这个能力"：插件发的请求即使 method 没人
  /// 认识，也会得到 `-32601` 响应而不是被静默丢掉（这是 M9 §3「插件主动下命令」
  /// 此前缺失的一环）。
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
    final Object? rawMethod = decoded['method'];

    // ① 响应：核心发出的请求的回包。**响应形态 = 有 id、没有 method**
    //    （JSON-RPC 2.0 的 Response 不带 method）——这样"带 method 的 int id"一定
    //    是插件的**请求**，不会因为 id 恰好撞上在途请求而被当成回包吞掉。
    //    命中 _pending ⇒ 完成在途 Future；未知 / 重复的回包 ⇒ 丢弃（既不落通知，
    //    也不当新请求）。
    if (rawMethod == null && id != null) {
      final Completer<Map<String, dynamic>>? completer = id is int
          ? _pending.remove(id)
          : null;
      if (completer != null && !completer.isCompleted) {
        try {
          completer.complete(_requestResult(decoded));
        } catch (error) {
          completer.completeError(error);
        }
      }
      return;
    }

    // ② 请求：插件主动调核心（method + id）；必回一条响应，且不阻塞读循环
    if (rawMethod is String && rawMethod.isNotEmpty && id != null) {
      unawaited(_answerRequest(id, rawMethod, decoded['params']));
      return;
    }

    // ③ 通知：收集并转发（总线转前端 plugin_event）
    notifications.add(decoded);
    _onNotification?.call(decoded);
  }

  /// 回**一条**响应给插件主动发起的请求：成功 `{jsonrpc, id, result}`，
  /// 失败 `{jsonrpc, id, error: {code, message}}`。
  ///
  /// 任何异常都在这里收敛成 error 响应（绝不冒泡到读循环）；写回失败（插件已死）
  /// 只吞掉写异常，由心跳 / 在途调用路径感知不可用。
  Future<void> _answerRequest(
    Object? id,
    String method,
    Object? rawParams,
  ) async {
    final Map<String, dynamic> params = rawParams is Map
        ? rawParams.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    Map<String, dynamic>? result;
    Map<String, dynamic>? error;
    final Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    )?
    handler = onPluginRequest;
    if (handler == null) {
      error = <String, dynamic>{
        'code': PluginRpcErrorCode.methodNotFound,
        'message': 'method not found: $method（宿主未接线 onPluginRequest）',
      };
    } else {
      try {
        result = await handler(method, params);
      } on PluginRequestException catch (failure) {
        error = <String, dynamic>{
          'code': failure.code,
          'message': failure.message,
        };
      } catch (failure) {
        error = <String, dynamic>{
          'code': PluginRpcErrorCode.internalError,
          'message': '插件请求 $method 处理异常：$failure',
        };
      }
    }
    final Map<String, dynamic> response = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      if (error != null)
        'error': error
      else
        'result': result ?? <String, dynamic>{},
    };
    try {
      _write(response);
    } catch (_) {
      // 插件已死：回包写不进去不算错误（不可用状态由心跳 / 调用路径标记）
    }
  }

  void _onDone() => _markChannelDead('插件 ${config.id} 的输出流已关闭');

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

  /// 关闭：**礼貌通知 → 关 stdin → 让在途请求以可读原因失败**。
  ///
  /// ⚠ **D8：这里不再有 2s 硬超时**（原实现是 `exitCode.timeout(2s)` → 超时 `kill()`，
  /// 属于**静态时长判死**，与不变量 4 相违，也与本类上面写的「取消静态总时间上限」矛盾）。
  /// 新口径：
  /// - **默认不等退出**（`waitForExit = false`）：调用方不该因为某个插件赖着不退而卡住
  ///   （[PluginBus.applyConfigs] 是逐条串行对账的，这里一卡就是整轮）。“退没退”交给
  ///   看门狗驱动的心跳台账判，判失活后由 [killStray] 收尸；
  /// - `waitForExit = true` 只用于“真的必须拿到退出码”的两处：替换二进制前的 Windows
  ///   文件锁、核心自己退出。等的也不是时长，而是“进程真的结束”这个事件。
  ///
  /// 为什么 [_failPending] 放在这里仍然是安全的：转储阶段由调用方安排在 close **之前**
  /// 完成（见 [PluginBus.hotRestart]：先 requestSuspend 拿 ack → 等快照入池 → 才 close），
  /// 所以不会再把“正在转储的在途请求”自己杀死——那正是拆成两阶段的原因。
  Future<void> close({bool waitForExit = false}) async {
    if (_closed) {
      if (waitForExit) await exited;
      return;
    }
    _closed = true;
    try {
      _write(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': PluginRpcMethods.shutdown,
        'params': const <String, dynamic>{},
      });
    } catch (_) {}
    _failPending('插件 ${config.id} 已关闭');
    try {
      await _process.stdin.close();
    } catch (_) {}
    if (waitForExit) await exited;
  }

  /// 观察到进程退出的信号（已退出则立即完成）。
  ///
  /// 它永远**不因时长而完成**：“等了很久”不是“它退了”。
  Future<void> get exited => _exitSeen.future;

  /// 是否已经确认退出（看门狗据此决定要不要收尸）。
  bool get exitedConfirmed => _exitSeen.isCompleted;

  /// **显式强杀**（收尸）。
  ///
  /// 全项目只有两个地方能调到它：
  /// ① 心跳台账判失活后的收尸（见 [PluginBus] 看门狗对“已经被要求关闭”的实例的处理）；
  /// ② 用户显式动作（面板上的“强制停止”）。
  /// **绝不得因为“跑得太久”而调用**（D8）：心跳在、只是慢，不是杀人的理由。
  void killStray(String reason) {
    if (_exitSeen.isCompleted) return;
    if (_killed) return;
    _killed = true;
    _process.kill();
    _killReason = reason;
  }

  /// 强杀原因（读接口用；没杀过为空串）——让“这个进程是被收尸的”在日志里看得见。
  String get killReason => _killReason;
  bool _killed = false;
  String _killReason = '';

  /// **优雅挂起**（阶段 1 新增）：请求插件把可续跑状态转储出来然后退出。
  ///
  /// 为什么它可以“没完没了地等”而不出事：[LivenessTracker.guard] 让这个请求与
  /// “心跳判失活”信号赛跑——插件只要还在发东西（任意入站报文即心跳）就一直等，
  /// 完全沉默到连续 N 拍才被当作失活并抛 [LivenessLostException]。
  /// 这同时钉住了两件事：**慢转储不会被时长误杀**，**装死也不会把热重启永远卡住**。
  ///
  /// 返回 `(ok: false)` 的三种原因都带可读中文文本：没声明可挂起（D3）、已经不可用、
  /// 插件自报失败或心跳丢了。调用方据此走**冷启动重启**，而不是报错给用户。
  Future<({bool ok, String reason})> requestSuspend() async {
    if (!config.canSuspend) {
      return (
        ok: false,
        reason: '插件 ${config.id} 没声明 suspension: keep（默认不可挂起，D3）：' '本次按冷启动重启，不做转储',
      );
    }
    if (isClosed) {
      return (
        ok: false,
        reason: '插件 ${config.id} 已经不可用（进程退出或通道断了），无得可转储',
      );
    }
    try {
      final Map<String, dynamic> result = await liveness.guard(
        () => _request(
          PluginRpcMethods.suspend,
          const <String, dynamic>{'reason': 'hot_restart'},
        ),
      );
      final bool acked = result['ok'] != false;
      return (
        ok: acked,
        reason: acked
            ? ''
            : '插件 ${config.id} 自报不能挂起：${result['error'] ?? '未给原因'}',
      );
    } on LivenessLostException catch (error) {
      return (ok: false, reason: '挂起请求期间心跳丢失：${error.message}');
    } catch (error) {
      return (ok: false, reason: '挂起请求没成：$error');
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

/// **插件 → 核心请求**的 JSON-RPC 错误码（与 JSON-RPC 2.0 / MCP 同表）。
abstract final class PluginRpcErrorCode {
  /// 方法不存在（宿主未接线处理器 / 总线不认识的 method）。
  static const int methodNotFound = -32601;

  /// 参数非法（缺 command、arguments 不是对象…）。
  static const int invalidParams = -32602;

  /// 处理器内部异常（异常文本进 message）。
  static const int internalError = -32603;

  /// 服务端自定义：归属 / scope 不满足（如插件未声明 team ⇒ 不能使用执行站）。
  static const int scopeDenied = -32001;
}

/// 插件请求的**可读失败**（带 JSON-RPC 错误码）。
///
/// [PluginHost.onPluginRequest] 的处理器抛出它 ⇒ 原样变成 `{code, message}` 错误
/// 响应；抛其它异常 ⇒ `-32603` + 异常文本。两种都不会让插件永久等回包。
class PluginRequestException implements Exception {
  const PluginRequestException(this.code, this.message);

  /// JSON-RPC 错误码（见 [PluginRpcErrorCode]）。
  final int code;

  /// 可读中文原因。
  final String message;

  @override
  String toString() => message;
}

/// 插件的**挂起声明**（写在 `plugins.yaml` 的条目级字段 `suspension`）。
///
/// 为什么默认是"不可挂起"（D3，向后兼容）：热重启的转储-续跑要求插件自己
/// 肯在退出前把状态交出来，而**老插件根本不认识这一条**。把默认设为"能挂起"
/// 就等于拿旧插件的在途工作赌一个新能力，因此反过来：显式声明才支持。
abstract final class PluginSuspension {
  /// 未声明（空串）= 不可挂起：热重启 = 直接重启（冷启动），转储与续跑都不做。
  static const String none = '';

  /// 显式声明可挂起：热重启时先 `suspend`、等它递回快照、再拉新实例取回。
  static const String keep = 'keep';

  /// 全部合法取值（`plugin_config_store.dart` 的校验与本表共用一个来源）。
  static const Set<String> values = <String>{none, keep};

  /// 可读的取值提示（错误信息用，不靠调用方自己拼）。
  static String get describeValues => 'keep（留空 = 不可挂起）';
}

/// 插件配置（`<数据根>/config/plugins.yaml` 的一项）。
class PluginConfig {
  PluginConfig({
    required this.id,
    required this.command,
    this.name = '',
    this.description = '',
    List<String>? args,
    Map<String, String>? env,
    this.enabled = true,
    this.granularity = 'team',
    Map<String, dynamic>? scope,
    this.suspension = PluginSuspension.none,
  }) : args = args ?? <String>[],
       env = env ?? <String, String>{},
       scope = scope ?? <String, dynamic>{};

  final String id;
  final String name;

  /// 插件**介绍**（一行文本，写在 plugins.yaml）。
  ///
  /// 为什么要在配置里而不是在协议握手里：面板要能在插件**没启动**时也讲得出它是谁
  /// （启动失败的卡片点开详情页更需要说明），而 `initialize` 只在连上之后才有。
  /// 空串 = 未提供，展示层给占位文案（不拿 id 当介绍）。
  final String description;

  final String command;
  final List<String> args;
  final Map<String, String> env;
  final bool enabled;

  /// 实例粒度：`team` / `agent` / `session`（与前端契约一致）。
  final String granularity;

  /// 实例 scope 四元组（team_id/agent_id/session_id；空串表示"不限定"）。
  final Map<String, dynamic> scope;

  /// **挂起声明**（见 [PluginSuspension]）：`keep` = 支持热重启不丢在途工作；
  /// 空串 = 默认，不可挂起。
  ///
  /// 为什么必须是**显式字段**而不是靠"未知键原样保留"：落盘层确实会原样保留
  /// 未知键（见 `plugin_config_store.dart` 的类注释），但本类的 [fromJson] **会丢掉
  /// 它们**——写在顶层却不建字段，结果就是"用户配了、核心读了个空"这种难查的错。
  final String suspension;

  /// 这个插件能不能挂起（热重启走"转储→取回"而不是直接重启）。
  bool get canSuspend => suspension == PluginSuspension.keep;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'description': description,
    'command': command,
    'args': args,
    'env': env,
    'enabled': enabled,
    'granularity': granularity,
    'scope': scope,
    // 只在声明了可挂起时写这一条：没声明的插件的配置文档与改动前逐字一致
    //（未知键不写回比"多一个空键"更干净，也免得用户以为"写了 keep 之外的值也行"）。
    if (suspension.isNotEmpty) 'suspension': suspension,
  };

  /// 前端形态（`GET /api/plugin/snapshot` 的 config 段）。
  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'plugin_id': id,
    'name': name,
    'description': description,
    'command': command,
    'args': args,
    'enabled': enabled,
    'granularity': granularity,
    'suspension': suspension,
  };

  static PluginConfig fromJson(Map<String, dynamic> json) => PluginConfig(
    id: (json['id'] ?? json['plugin_id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    description: (json['description'] ?? '').toString(),
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
    // 挂起声明取"宽容读法"：没写 / 写成非字符串 ⇒ 空串（不可挂起）。
    // 绝不在此抛异常：配置读不出来时 PluginBus 要保持现状并只报一句可读原因。
    suspension: (json['suspension'] is String)
        ? (json['suspension'] as String).trim()
        : PluginSuspension.none,
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
