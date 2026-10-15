import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 热重启用例里的**可挂起假插件**（stdio JSON-RPC，声明 `suspension: keep`）。
///
/// 它与 `hot_plugin.dart` 同一套协议骨架，但多出热重启这条路需要的三件事，而且
/// **每一件都落盘成可数的证据**（用例不许靠"看起来成功了"判定）：
///
/// 1. **数得出第几世**：每次进程启动往事件日志追加一行 `start`，并把 hello 参数里
///    的 `resume_dump_id` 一起记下来 ⇒ 用例能断言"第二世确实拿到了第一世的快照 id"；
/// 2. **转储/取回都是真命令**：收到 `suspend` 时先用 `plugin.stateDump` 把快照递给
///    核心，**再**回 ack（顺序是刻意的：核心因此不需要"等时长"就能确定快照已入池）；
///    新一世就绪后主动 `plugin.stateFetch`，并把拿到的 payload 记进事件日志；
/// 3. **退出时机可编程**：`--exit-delay-ms` 让它在 ack 之后再赖 N 毫秒才退，
///    `--no-exit-on-shutdown` 让它收到 shutdown 也**不退**而只继续发心跳 —— 后者
///    正是"慢退出不会被时长误杀"（D8）能被钉住的地方。
///
/// 参数：
/// - `--id ID`：hello 回带的 plugin_id（缺省 suspendable）
/// - `--event-log PATH`：事件日志（JSONL，一行一个事件）
/// - `--dump-payload-bytes N`：转储载荷里塞多少字节的 filler（测上限）
/// - `--dump-delay-ms N`：收到 suspend 后**先等 N 毫秒**再递快照（模拟慢转储）
/// - `--exit-delay-ms N`：ack 之后再等 N 毫秒才自己退出
/// - `--no-exit-on-shutdown`：收到 shutdown **不退出**；`--beat-ms N` 决定它赖着时
///   要不要继续按拍发通知（N > 0 = 一直发心跳；N = 0 = 彻底沉默但也不退）
/// - `--beat-ms N`：上面那种“赖着不退”时每次发通知的间隔（缺省 20ms）
/// - `--self-stop-ms N`：无论如何，启动 N 毫秒后自己退出（用例用来观察"自然退出"）
void main(List<String> args) {
  final String pluginId = _valueOf(args, '--id', fallback: 'suspendable');
  final String eventLog = _valueOf(args, '--event-log');
  final int dumpPayloadBytes = _intValue(args, '--dump-payload-bytes');
  final int dumpDelayMs = _intValue(args, '--dump-delay-ms');
  final int exitDelayMs = _intValue(args, '--exit-delay-ms');
  final int selfStopMs = _intValue(args, '--self-stop-ms');
  final int beatMs = _intValue(args, '--beat-ms', fallback: 20);
  final bool keepAliveOnShutdown =
      _valueOf(args, '--no-exit-on-shutdown') == 'true';

  void event(String kind, [Map<String, Object?> fields = const <String, Object?>{}]) {
    if (eventLog.isEmpty) return;
    File(eventLog).writeAsStringSync(
      '${jsonEncode(<String, Object?>{
            'kind': kind,
            'pid': pid,
            ...fields,
          })}\n',
      mode: FileMode.append,
      flush: true, // 用例会在子进程还活着时就读这份日志
    );
  }

  event('start', <String, Object?>{'args': args});
  // “无论如何 N 毫秒后自己退”只给**不赖着**的形态用：赖着不退的那两种就是要
  // 让用例看见“它还在”，开头放一个定时器会把它们提前抓走。
  if (selfStopMs > 0 && !keepAliveOnShutdown) {
    Timer(Duration(milliseconds: selfStopMs), () => exit(0));
  }

  // ── 出站：插件 → 核心请求（要拿回包，所以必须记 pending）────────────────
  int nextId = 1000;
  final Map<String, void Function(Map<String, dynamic>)> pending =
      <String, void Function(Map<String, dynamic>)>{};

  void sendRequest(
    String method,
    Map<String, dynamic> params, {
    void Function(Map<String, dynamic>)? onResult,
  }) {
    final int id = nextId++;
    if (onResult != null) pending['$id'] = onResult;
    stdout.writeln(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
  }

  /// 通知（不带 id）：用来在“赖着不退”期间持续制造入站报文 = 心跳证据。
  void sendNotification(String method, Map<String, dynamic> params) {
    stdout.writeln(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      }),
    );
  }

  /// 走执行站下一条 `plugin.*` 命令（D10：转储/取回不新增 method，就用 station/command）。
  void pluginCommand(
    String command,
    Map<String, dynamic> arguments, {
    void Function(Map<String, dynamic> result)? onResult,
  }) {
    sendRequest(
      'station/command',
      <String, dynamic>{'command': command, 'arguments': arguments},
      onResult: (Map<String, dynamic> message) {
        final Object? result = message['result'];
        final Map<String, dynamic> envelope =
            result is Map<String, dynamic> ? result : <String, dynamic>{};
        // 执行站的回包形状是 {ok, mount_id, payload, error}：命令真正的结论在
        // **payload 里**，被拒时 payload 为空、原因在 error。这里把两层抹平成一层，
        // 假插件只关心“命令给了我什么”。
        final Object? inner = envelope['payload'];
        onResult?.call(
          inner is Map<String, dynamic> ? inner : envelope,
        );
      },
    );
  }

  void reply(Object? id, Map<String, dynamic> result) {
    stdout.writeln(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      }),
    );
  }

  /// 本进程已经活了多久（转储载荷里的"这一段人生"证据）。
  final Stopwatch alive = Stopwatch()..start();

  Map<String, dynamic> dumpPayload() => <String, dynamic>{
    'era_pid': pid,
    'alive_ms': alive.elapsedMilliseconds,
    'marker': _valueOf(args, '--marker'),
    if (dumpPayloadBytes > 0) 'filler': 'x' * dumpPayloadBytes,
  };

  /// 收到 `suspend`：转储 → （可选延迟）→ ack → （可选延迟）→ 自己退出。
  void handleSuspend(Object? id, Map<String, dynamic> params) {
    event('suspend', <String, Object?>{'reason': params['reason'] ?? ''});
    void ackAndMaybeExit() {
      reply(id, <String, dynamic>{'ok': true, 'dumped': true});
      event('suspend_ack');
      if (keepAliveOnShutdown) return;
      if (exitDelayMs > 0) {
        Timer(Duration(milliseconds: exitDelayMs), () => exit(0));
      } else {
        exit(0);
      }
    }

    if (dumpDelayMs > 0) {
      Timer(Duration(milliseconds: dumpDelayMs), () {
        pluginCommand(
          'plugin.stateDump',
          <String, dynamic>{'payload': dumpPayload()},
          onResult: (Map<String, dynamic> result) {
            event('dump', <String, Object?>{
              'dump_id': result['dump_id'],
              'bytes': result['bytes'],
              'ok': result['ok'],
            });
            ackAndMaybeExit();
          },
        );
      });
      return;
    }
    pluginCommand(
      'plugin.stateDump',
      <String, dynamic>{'payload': dumpPayload()},
      onResult: (Map<String, dynamic> result) {
        event('dump', <String, Object?>{
          'dump_id': result['dump_id'],
          'bytes': result['bytes'],
          'ok': result['ok'],
        });
        ackAndMaybeExit();
      },
    );
  }

  /// 就绪后取回上一世的快照（取不到就按冷启动继续，两者都要留下证据）。
  void fetchAndRecord() {
    pluginCommand(
      'plugin.stateFetch',
      <String, dynamic>{},
      onResult: (Map<String, dynamic> result) {
        event('fetch', <String, Object?>{
          'ok': result['ok'],
          'has_snapshot': result['has_snapshot'],
          'dump_id': result['dump_id'],
          'generation': result['generation'],
          'payload': result['payload'],
          'reason': result['reason'],
        });
      },
    );
  }

  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((
    String line,
  ) {
    if (line.trim().isEmpty) return;
    Map<String, dynamic> message;
    try {
      message = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final Object? id = message['id'];
    final String method = (message['method'] ?? '').toString();

    // ① 响应（有 id、无 method）：回填给等着的那个请求
    if (id != null && method.isEmpty) {
      final void Function(Map<String, dynamic>)? waiting = pending.remove('$id');
      if (waiting != null) waiting(message);
      return;
    }
    // ② 通知（无 id）
    if (id == null) {
      if (method == 'shutdown') {
        event('shutdown');
        if (keepAliveOnShutdown) {
          // 收到 shutdown 也**不退**。两种形态分开钉：
          // - `--beat-ms > 0`：继续按拍发通知。这就是“心跳在、只是慢”，核心
          //   绝不能因时长杀它（D8），也不能因“看门狗跑了很多拍”而杀它；
          // - `--beat-ms = 0`：彻底沉默但进程还在。这才是“判失活后收尸”的正当场景。
          if (beatMs > 0) {
            Timer.periodic(Duration(milliseconds: beatMs), (Timer timer) {
              sendNotification('log', <String, dynamic>{
                'level': 'info',
                'message': 'still-alive',
              });
              event('beat');
              if (selfStopMs > 0 && alive.elapsedMilliseconds >= selfStopMs) {
                timer.cancel();
                exit(0);
              }
            });
          } else {
            event('silent');
            if (selfStopMs > 0) {
              Timer(Duration(milliseconds: selfStopMs), () => exit(0));
            }
          }
          return;
        }
        exit(0);
      }
      return;
    }
    // ③ 核心 → 插件请求
    switch (method) {
      case 'hello':
        final Map<String, dynamic> params = _params(message);
        final String resumeDumpId = (params['resume_dump_id'] ?? '').toString();
        event('hello', <String, Object?>{'resume_dump_id': resumeDumpId});
        reply(id, <String, dynamic>{
          'plugin_id': pluginId,
          'name': '可挂起假插件',
          'capabilities': <String>['tools'],
        });
        // 就绪后立刻问一句"有没有我的快照"（第一世会拿到 has_snapshot=false）
        fetchAndRecord();
      case 'tools/list':
        reply(id, <String, dynamic>{
          'tools': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'echo',
              'description': '可挂起假插件的回声工具',
              'inputSchema': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          ],
        });
      case 'station/request':
        // 收集站：申报一个工具定义（让"重启后工具表重新收集"这条链路也能被断言）
        reply(id, <String, dynamic>{
          'reply': <String, dynamic>{
            'payload': <String, dynamic>{
              'tools': <Map<String, dynamic>>[
                <String, dynamic>{
                  'tool_name': 'echo',
                  'description': '可挂起假插件的回声工具',
                  'parameters': <String, dynamic>{'type': 'object'},
                  'execution': <String, dynamic>{
                    'method': 'tools/call',
                    'name': 'echo',
                  },
                },
              ],
            },
          },
        });
      case 'tools/call':
        reply(id, <String, dynamic>{
          'content': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'text': 'echo from pid=$pid alive=${alive.elapsedMilliseconds}ms',
            },
          ],
          'isError': false,
        });
      case 'suspend':
        handleSuspend(id, _params(message));
      case 'ping':
        reply(id, <String, dynamic>{'ok': true});
      default:
        stdout.writeln(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'error': <String, dynamic>{
              'code': -32601,
              'message': 'method not found: $method',
            },
          }),
        );
    }
  }, onDone: () {
    // 核心关了 stdin（它的 close 第二步）不等于“我可以退了”：
    // “赖着不退”的两种形态都得继续活着，否则 D8 的用例当场失真。
    if (!keepAliveOnShutdown) exit(0);
  });
}

Map<String, dynamic> _params(Map<String, dynamic> message) {
  final Object? raw = message['params'];
  return raw is Map
      ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
      : <String, dynamic>{};
}

String _valueOf(List<String> args, String key, {String fallback = ''}) {
  for (int i = 0; i < args.length - 1; i++) {
    if (args[i] == key) return args[i + 1];
  }
  return fallback;
}

int _intValue(List<String> args, String key, {int fallback = 0}) =>
    int.tryParse(_valueOf(args, key)) ?? fallback;
