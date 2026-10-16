import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'plugin_methods.dart';
import 'tool_surface.dart';

/// 框架自迭代插件的主循环（L1：核心 ⇄ 本插件，stdio 上的 JSON-RPC 2.0）。
///
/// 铁律逐条落到代码里（与 `tree_ssh_plugin` 的循环同一口径）：
/// 1. **stdout 只放协议帧**：本类只经 [send] 出帧，日志走 [log]（→ stderr）；
/// 2. **并发**：每个请求在独立 Future 里处理，读循环**从不 await 业务**
///    （否则一次转储就把 `ping` 堵死 ⇒ 被判 degraded）；
/// 3. **心跳必答**：`ping` 是纯内存操作，永远立即回；
/// 4. **未知方法回 `-32601`，不静默**；异常一律收敛成响应（不能挂住读循环）。
///
/// 本插件的全部能力都是"把一条 `plugin.*` 命令转给执行站"，因此它自己
/// **不持有任何插件状态**：谁是第几世、快照在不在池里、重启成没成，
/// 都由核心回答（它才是唯一知道实例表的一方）。
class SelfUpdaterLoop {
  SelfUpdaterLoop({required this.send, this.log, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 出一帧（调用方负责写到 stdout；测试里收到的是帧序列）。
  final void Function(Map<String, dynamic> frame) send;

  /// 日志出口（**绝不写 stdout**：那是协议面）。
  final void Function(String message)? log;

  final DateTime Function() _now;

  final RpcIds _outIds = RpcIds();
  final Map<Object, Completer<Map<String, dynamic>>> _pendingOut =
      <Object, Completer<Map<String, dynamic>>>{};
  final Set<Future<void>> _inFlight = <Future<void>>{};

  Completer<int>? _done;
  StreamSubscription<List<int>>? _input;

  // ── 可计数证据（用例钉的就是这些，不靠"看起来成功了"）────────────────

  /// 处理过的 `tools/call` 次数（按工具名分别计）。
  final Map<String, int> toolCalls = <String, int>{};

  /// 下达过的执行站命令次数（按命令名分别计）。
  final Map<String, int> commands = <String, int>{};

  /// 转储（`plugin.stateDump`）成功次数与最近一次的 dump_id。
  int dumpCount = 0;
  String lastDumpId = '';

  /// 取回（`plugin.stateFetch`）：是否真的续跑上了，以及取回的字节数。
  bool resumed = false;
  int fetchedBytes = 0;

  /// 本世的 `hello` 参数里带回来的 `resume_dump_id`（没快照 = 空串）。
  String resumeDumpId = '';

  /// 上一世留下的计数（续跑成功后会被填回来；这就是"真的续上了"的证据）。
  int inheritedToolCalls = 0;

  /// 就绪后的读数（面板与用例都从这里取）。
  Map<String, Object?> readings() => <String, Object?>{
    'plugin_id': SelfUpdaterIdentity.pluginId,
    'resume_dump_id': resumeDumpId,
    'resumed': resumed,
    'fetched_bytes': fetchedBytes,
    'dumps': dumpCount,
    'tool_calls': toolCalls.values.fold<int>(0, (int a, int b) => a + b),
    'inherited_tool_calls': inheritedToolCalls,
    'commands': Map<String, int>.of(commands),
  };

  /// 跑读循环；返回进程退出码。**只有** stdin 关闭或收到 `shutdown` 才会返回。
  Future<int> run(Stream<List<int>> input) {
    final Completer<int> done = Completer<int>();
    _done = done;
    final LineFrameDecoder decoder = LineFrameDecoder(
      onFrame: handleFrame,
      onError: (String reason) => log?.call('核心报文的坏帧（已丢弃）：$reason'),
    );
    _input = input.listen(
      decoder.add,
      onError: (Object error) => _finish(1, '读 stdin 出错：$error'),
      onDone: () => _finish(0, '核心关闭了 stdin'),
      cancelOnError: false,
    );
    return done.future;
  }

  /// 主动收手（`shutdown` 与测试共用）。**幂等**：重复调用只收尾一次。
  void shutdown() {
    log?.call('收到 shutdown：退出（在途的执行站命令以可读错误收尾）');
    _finish(0, 'shutdown');
  }

  // ───────────────────────── 分发 ─────────────────────────

  /// 处理一条入站帧（公开给测试：可以直接喂帧，不必真起进程）。
  void handleFrame(Map<String, dynamic> frame) {
    if (RpcIds.isRequest(frame)) {
      final Object? id = frame['id'];
      final String method = (frame['method'] ?? '').toString();
      final Map<String, dynamic> params = _paramsOf(frame);
      // **并发**：不 await，读循环立刻回到监听（铁律 2）。
      late final Future<void> task;
      task = _handleRequest(id, method, params).whenComplete(() {
        _inFlight.remove(task);
      });
      _inFlight.add(task);
      return;
    }
    if (RpcIds.isNotification(frame)) {
      final String method = (frame['method'] ?? '').toString();
      if (method == PluginMethods.shutdown) {
        // 通知形态的 shutdown：没有 ack 要回，直接收手。
        shutdown();
      } else {
        log?.call('核心通知（本插件不消费）：$method');
      }
      return;
    }
    if (RpcIds.isResponse(frame)) {
      final Object? id = frame['id'];
      final Completer<Map<String, dynamic>>? waiting = _pendingOut.remove(id);
      if (waiting != null && !waiting.isCompleted) waiting.complete(frame);
      return;
    }
    log?.call('忽略无法归类的帧（既非请求/通知，也不是我方在途请求的回包）');
  }

  Future<void> _handleRequest(
    Object? id,
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      switch (method) {
        case PluginMethods.hello:
          resumeDumpId = (params['resume_dump_id'] ?? '').toString();
          _reply(id, <String, dynamic>{
            'plugin_id': SelfUpdaterIdentity.pluginId,
            'name': SelfUpdaterIdentity.name,
            'version': SelfUpdaterIdentity.version,
            'capabilities': const <String>['tools'],
          });
          log?.call(
            '握手完成（resume_dump_id=${resumeDumpId.isEmpty ? '（无）' : resumeDumpId}）',
          );
          // 就绪后第一件事：问核心"有没有我的快照"。没有就冷启动，**这不是错误**。
          unawaited(_restoreState());
          return;
        case PluginMethods.ping:
          _reply(id, <String, dynamic>{
            'ok': true,
            'ts': _now().millisecondsSinceEpoch,
          });
          return;
        case PluginMethods.toolsList:
          _reply(id, <String, dynamic>{
            'tools': SelfUpdaterTool.toolsListEntries(),
          });
          return;
        case PluginMethods.toolsCall:
          _reply(id, await _callTool(params));
          return;
        case PluginMethods.suspend:
          // ★ 顺序是本插件的全部要点：**先转储、等它的回包、再回 ack**。
          //   反了核心就只能"等一会儿"碰运气，而它不等也不判时长（D8）。
          final String dumpId = await _dumpState();
          _reply(id, <String, dynamic>{
            'ok': true,
            'dumped': dumpId.isNotEmpty,
            'dump_id': dumpId,
          });
          log?.call(
            dumpId.isEmpty
                ? 'suspend 但没转储成功 ⇒ 下一世按冷启动继续'
                : 'suspend 已转储（$dumpId）⇒ 等核心 shutdown',
          );
          return;
        case PluginMethods.shutdown:
          _reply(id, <String, dynamic>{'ok': true});
          shutdown();
          return;
        case PluginMethods.stationRequest:
          _reply(id, await _onStationRequest(params));
          return;
        default:
          _replyError(id, RpcCodes.methodNotFound, 'method not found: $method');
      }
    } catch (error, stack) {
      // 异常必须变成响应：挂住读循环 = 核心等到心跳判失活，比失败更难查。
      log?.call('处理 $method 异常：$error\n$stack');
      _replyError(id, RpcCodes.internalError, '处理器异常：$error');
    }
  }

  // ───────────────────────── 工具执行 ─────────────────────────

  /// 执行一次 `plugin_hot_restart`：把它翻译成一条执行站 `plugin.*` 命令。
  ///
  /// 返回 MCP 风格的工具结果（`{content:[{type:text,…}], isError}`）：
  /// **失败也是结果**，绝不抛出（不变量 6「失败必须可读上报」）。
  Future<Map<String, dynamic>> _callTool(Map<String, dynamic> params) async {
    final String name = (params['name'] ?? '').toString();
    if (name != SelfUpdaterTool.name) {
      return _toolText(
        '未知工具「$name」（本插件只提供 ${SelfUpdaterTool.name}）',
        isError: true,
      );
    }
    toolCalls[name] = (toolCalls[name] ?? 0) + 1;
    final Map<String, dynamic> args = _asMap(params['arguments']);
    final Map<String, dynamic> identity = _identityOf(params);

    final String action = (args['action'] ?? '').toString();
    final ({String? command, String? error}) resolved =
        SelfUpdaterTool.resolveCommand(action);
    if (resolved.command == null) {
      log?.call('工具 $name 的 action「$action」被拒：${resolved.error}');
      return _toolText(resolved.error!, isError: true);
    }
    final String command = resolved.command!;
    final String pluginId = (args['plugin_id'] ?? '').toString().trim();
    if (pluginId.isEmpty && command != PluginCommands.list) {
      return _toolText(
        'action「$action」需要 plugin_id（要动哪个插件）；'
        '想先看全局就用 action=list',
        isError: true,
      );
    }
    final Map<String, dynamic> arguments = <String, dynamic>{
      if (pluginId.isNotEmpty) 'plugin_id': pluginId,
      if (command == PluginCommands.restart && args.containsKey('keep_state'))
        'keep_state': args['keep_state'] == true,
    };

    final bool selfRestart =
        command == PluginCommands.restart &&
        pluginId == SelfUpdaterIdentity.pluginId;
    Map<String, dynamic> outcome = await _command(command, arguments, identity);
    if (outcome['ok'] != true) {
      final String error = (outcome['error'] ?? '执行站没有给出原因').toString();
      log?.call('$command 失败：$error');
      return _toolText(
        '插件命令 $command 失败：$error'
        '${identity.isEmpty ? '（本次调用没有可证明的归属身份：核心按 fail-closed 拒绝）' : ''}',
        isError: true,
      );
    }

    // 「等就绪」走的是**读数**而不是时长：重启命令本身已经把新一世拉到 ready，
    // 这里只是把它的阶段/代际附进结果，让模型看得到"续上的是第几世"。
    final bool wantReady = args['wait_ready'] != false;
    if (command == PluginCommands.restart && wantReady) {
      if (selfRestart) {
        outcome = <String, dynamic>{
          ...outcome,
          'settled': <String, dynamic>{
            'note':
                '重启目标就是发起者本人 ⇒ 核心先应答再动手，本插件拿不到自己新一世的读数'
                '（那正是"不挂死"的代价，写清楚而不是假装看到了）',
          },
        };
      } else {
        final Map<String, dynamic> state = await _command(
          PluginCommands.state,
          <String, dynamic>{'plugin_id': pluginId},
          identity,
        );
        outcome = <String, dynamic>{
          ...outcome,
          'settled': state['ok'] == true
              ? state
              : <String, dynamic>{
                  'unreadable': (state['error'] ?? '读不到新一世的阶段').toString(),
                },
        };
      }
    }
    log?.call(
      '工具 $name（action=$action，target=${pluginId.isEmpty ? '（全部）' : pluginId}）'
      '⇒ ${selfRestart ? '已应答，动手在下一回合' : '已拿到结论'}',
    );
    return _toolText(_json(outcome));
  }

  /// 收集站的采集请求（`plugin.tool.define`）：按 schema 回自己的工具定义。
  ///
  /// 两条申报路（`tools/list` 与本点位）**共用同一份 schema 常量**，见
  /// [SelfUpdaterTool]：漂移出的两个工具名比"没工具"更难查。
  Future<Map<String, dynamic>> _onStationRequest(
    Map<String, dynamic> params,
  ) async {
    final String stationId = (params['station_id'] ?? '').toString();
    if (stationId != kToolDefineStationId) {
      // 本插件不订任何点位（收集站的订阅是核心自己下的），收到别的投递就是接线异常。
      log?.call('收到未预期的点位投递「$stationId」⇒ 回空载荷（不假装处理过）');
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': null},
      };
    }
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{
          'tools': SelfUpdaterTool.collectToolDefinitions(),
        },
      },
    };
  }

  // ───────────────────────── 转储 / 取回 ─────────────────────────

  /// `plugin.stateDump`：把本插件的可续跑状态递进核心的**内存池**（不落盘，D4）。
  ///
  /// 状态里只有"计数与最近一次动作"这类**可核对的事实**：消息与工具结果由核心落库在先，
  /// 本插件从不把会话事实唯一地寄存到这里（那是 D4 的代价面）。
  Future<String> _dumpState() async {
    final Map<String, dynamic> payload = <String, dynamic>{
      'tool_calls': toolCalls.values.fold<int>(0, (int a, int b) => a + b),
      'dumps': dumpCount + 1,
      'inherited_tool_calls': inheritedToolCalls,
      'last_readings': readings(),
      'dumped_at': _now().millisecondsSinceEpoch ~/ 1000,
    };
    final Map<String, dynamic> result = await _command(
      PluginCommands.stateDump,
      <String, dynamic>{'payload': payload},
      const <String, dynamic>{},
    );
    if (result['ok'] != true) {
      log?.call('转储被拒（下一世按冷启动继续）：${result['error']}');
      return '';
    }
    dumpCount++;
    lastDumpId = (result['dump_id'] ?? '').toString();
    log?.call('快照已入池：$lastDumpId（${result['bytes']} 字节）');
    return lastDumpId;
  }

  /// `plugin.stateFetch`：取回上一世的快照。没有就按冷启动继续（**这不是错误**）。
  Future<void> _restoreState() async {
    final Map<String, dynamic> result = await _command(
      PluginCommands.stateFetch,
      const <String, dynamic>{},
      const <String, dynamic>{},
    );
    if (result['ok'] != true) {
      log?.call('取回被拒（按冷启动继续）：${result['error']}');
      return;
    }
    if (result['has_snapshot'] != true) {
      log?.call('没有可续跑的快照 ⇒ 冷启动：${result['reason']}');
      return;
    }
    final Map<String, dynamic> payload = _asMap(result['payload']);
    inheritedToolCalls = (payload['tool_calls'] as num?)?.toInt() ?? 0;
    resumed = true;
    fetchedBytes = (result['bytes'] as num?)?.toInt() ?? 0;
    log?.call(
      '续跑成功：接上上一世累计的 $inheritedToolCalls 次工具调用'
      '（快照 $fetchedBytes 字节）',
    );
  }

  // ───────────────────────── 我方主动请求 ─────────────────────────

  /// 下一条执行站命令并把两层信封抹平成一层的**结论**（`payload` 优先）。
  ///
  /// 回包形状是 `{command, ok, mount_id, payload, error}`：命令真正的结论在
  /// `payload` 里，被拒时原因在 `error`。**这里保留 ok/error 两个键**，
  /// 调用方要的正是"到底成没成、没成为什么"。
  Future<Map<String, dynamic>> _command(
    String command,
    Map<String, dynamic> arguments,
    Map<String, dynamic> identity,
  ) async {
    commands[command] = (commands[command] ?? 0) + 1;
    try {
      final Object? result = rpcUnwrap(
        await _requestCore(PluginMethods.stationCommand, <String, dynamic>{
          'command': command,
          'arguments': arguments,
          ...identity,
        }),
      );
      if (result is! Map) {
        return <String, dynamic>{
          'ok': false,
          'error': '执行站回包不是对象：$result',
          'command': command,
        };
      }
      final Map<String, dynamic> envelope = _asMap(result);
      final Map<String, dynamic> payload = _asMap(envelope['payload']);
      if (payload.isNotEmpty) return <String, dynamic>{...envelope, ...payload};
      return envelope;
    } on RpcException catch (error) {
      return <String, dynamic>{
        'ok': false,
        'command': command,
        'error': '${error.message}（code=${error.code}）',
      };
    } catch (error) {
      return <String, dynamic>{
        'ok': false,
        'command': command,
        'error': '下达命令失败：$error',
      };
    }
  }

  /// 向核心发一条请求并等回包。**无静态超时**（与中转站其它请求同口径）：
  /// 只有进程收手（[_finish]）才把在途请求以可读错误显式收尾。
  Future<Map<String, dynamic>> _requestCore(
    String method,
    Map<String, dynamic> params,
  ) {
    final int id = _outIds.next();
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pendingOut[id] = completer;
    send(rpcRequest(id, method, params));
    return completer.future;
  }

  void _finish(int code, String reason) {
    // 幂等**靠 done 本身**判，不靠另一个布尔：上一版在 shutdown() 里先把
    // `_finishing` 置 true，这里再一检查就直接 return ⇒ `run()` 的 future 永远
    // 不完成（插件拿不到退出码，"优雅退出"这条路由此名存实亡）。
    final Completer<int>? done = _done;
    if (done == null || done.isCompleted) return;
    log?.call('收手：$reason');
    for (final Completer<Map<String, dynamic>> waiting in _pendingOut.values) {
      if (!waiting.isCompleted) {
        waiting.complete(<String, dynamic>{
          'error': <String, dynamic>{
            'code': RpcCodes.internalError,
            'message': '插件正在退出（$reason）⇒ 这条请求不会再有回包',
          },
        });
      }
    }
    _pendingOut.clear();
    unawaited(_input?.cancel());
    done.complete(code);
  }

  // ───────────────────────── 小工具 ─────────────────────────

  static const String kToolDefineStationId = 'plugin.tool.define';

  void _reply(Object? id, Map<String, dynamic> result) {
    if (id == null) return;
    send(rpcResult(id, result));
  }

  void _replyError(Object? id, int code, String message) {
    if (id == null) return;
    send(rpcErrorResult(id, code, message));
  }

  Map<String, dynamic> _toolText(String text, {bool isError = false}) =>
      <String, dynamic>{
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': text},
        ],
        'isError': isError,
      };

  static String _json(Object? value) {
    try {
      return jsonEncode(value);
    } catch (error) {
      // 结果里混进了无法序列化的东西（真发生就是 bug）：给可读结论，
      // 而不是让工具回包在边界上抛出去。
      return '{"ok":false,"error":"结果无法序列化：$error"}';
    }
  }

  static Map<String, dynamic> _paramsOf(Map<String, dynamic> frame) =>
      _asMap(frame['params']);

  static Map<String, dynamic> _asMap(Object? value) => value is Map
      ? value.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
      : <String, dynamic>{};

  /// 把核心给的**本次调用身份**（`tools/call` 的 `scope`）原样带回命令的顶层参数。
  ///
  /// 为什么原样带而不是自己填：执行站 `plugin.*` 的控制面要求可证明的 team 归属，
  /// 而"证明"只能来自核心告诉我的那一份（我编一个 team 就是越权）。带了 `agent_id`
  /// 更关键 —— 核心会按目标 agent 的**真实归属**再核一遍，报上去的对不上就拒。
  static Map<String, dynamic> _identityOf(Map<String, dynamic> params) {
    final Map<String, dynamic> scope = _asMap(params['scope']);
    return <String, dynamic>{
      for (final String key in const <String>[
        'team_id',
        'agent_id',
        'session_id',
        'mode_key',
      ])
        if ((scope[key] ?? '').toString().trim().isNotEmpty)
          key: scope[key].toString().trim(),
    };
  }
}
