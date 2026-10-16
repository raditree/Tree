import 'dart:async';
import 'dart:convert' show utf8;

import 'package:test/test.dart';
import 'package:tree_self_updater/tree_self_updater.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart'
    show RpcCodes, RpcIds, encodeFrame;

/// 框架自迭代插件的**协议面**用例（不真起进程：假核心在进程内喂帧）。
///
/// 为什么这么测：本插件的全部风险都在"帧的形状与顺序"上（申报是否双路同源、
/// 转储是否先于 ack、身份是否原样带回、生命周期原语是否被拒）。这些都能在一堆
/// 帧序列里**数出来**。而"插件真的能被核心当内置插件拉起来、工具真的进模型工具表"
/// 那部分由 tree_core 侧的 `plugin_tool_define_self_updater_test` /
/// `plugin_self_restart_tool_test` 用**真子进程**钉住（两层各管各的，不重复）。
void main() {
  late _Harness core;

  setUp(() => core = _Harness());
  tearDown(() => core.dispose());

  test('握手回自报身份，并主动问一次「有没有我的快照」（没有就算冷启动，不是错误）', () async {
    final Map<String, dynamic> hello = await core.request(
      PluginMethods.hello,
      <String, dynamic>{
        'protocol': 1,
        'core_version': 'test',
        'plugin_id': SelfUpdaterIdentity.pluginId,
      },
    );
    expect(hello['plugin_id'], SelfUpdaterIdentity.pluginId);
    expect(hello['name'], SelfUpdaterIdentity.name);
    expect(hello['capabilities'], contains('tools'));
    // hello 之后那一次 stateFetch 要等假核心的回包落地才算“处完”：
    // 帧在 StreamController 上是**异步**送达的，不 pump 就只能看到一半事实。
    await pumpEventQueue();

    // hello 之后它必须自己下一次 stateFetch —— 不取快照就永远续不上跑。
    final Map<String, dynamic> fetch = core.outgoing.single;
    expect(fetch['method'], PluginMethods.stationCommand);
    expect(_commandOf(fetch), PluginCommands.stateFetch);
    expect(core.loop.resumed, isFalse, reason: '假核心回了"没有快照" ⇒ 冷启动');
    expect(
      core.logLines.any((String l) => l.contains('冷启动')),
      isTrue,
      reason: '冷启动这件事要能被日志查到，不静默',
    );
  });

  test('带 resume_dump_id 的握手 ⇒ 取回快照并把上一世的计数接上（续跑真的发生）', () async {
    core.hasSnapshot = true;
    core.snapshotPayload = <String, dynamic>{'tool_calls': 7, 'dumps': 2};
    core.snapshotBytes = 128;
    await core.request(PluginMethods.hello, <String, dynamic>{
      'plugin_id': SelfUpdaterIdentity.pluginId,
      'resume_dump_id': 'd-1',
    });
    await pumpEventQueue();
    expect(core.loop.resumeDumpId, 'd-1');
    expect(core.loop.resumed, isTrue);
    expect(core.loop.inheritedToolCalls, 7, reason: '上一世 7 次工具调用被接上');
    expect(core.loop.fetchedBytes, 128);
  });

  test('两条申报路共用同一份参数 schema（tools/list 与收集站字段名不同、内容同源）', () async {
    final Map<String, dynamic> listed = await core.request(
      PluginMethods.toolsList,
      const <String, dynamic>{},
    );
    final Map<String, dynamic> collected = await core.request(
      PluginMethods.stationRequest,
      <String, dynamic>{
        'station_id': 'plugin.tool.define',
        'kind': 'collect',
        'payload': <String, dynamic>{},
      },
    );
    final Map<String, dynamic> fromList =
        (listed['tools'] as List<dynamic>).single as Map<String, dynamic>;
    final Map<String, dynamic> payload =
        (collected['reply'] as Map<String, dynamic>)['payload']
            as Map<String, dynamic>;
    final Map<String, dynamic> fromCollect =
        (payload['tools'] as List<dynamic>).single as Map<String, dynamic>;

    expect(fromList['name'], SelfUpdaterTool.name);
    expect(fromCollect['tool_name'], SelfUpdaterTool.name);
    expect(
      fromCollect['parameters'],
      fromList['inputSchema'],
      reason: '两条路的参数定义必须是同一份：漂移出的两个工具比"没有工具"更难查',
    );
    expect(fromCollect['execution'], <String, dynamic>{
      'method': PluginMethods.toolsCall,
      'name': SelfUpdaterTool.name,
    });
  });

  test('非收集站的点位投递 ⇒ 回空载荷并留痕（不假装处理过）', () async {
    await core.request(PluginMethods.hello, <String, dynamic>{
      'plugin_id': SelfUpdaterIdentity.pluginId,
    });
    core.outgoing.clear();
    final Map<String, dynamic> reply = await core.request(
      PluginMethods.stationRequest,
      <String, dynamic>{
        'station_id': 'system.relay.tool.pre',
        'payload': <String, dynamic>{'phase': 'pre'},
      },
    );
    expect((reply['reply'] as Map<String, dynamic>)['payload'], isNull);
    expect(core.logLines.any((String l) => l.contains('收到未预期的点位投递')), isTrue);
  });

  test('action ⇒ 执行站命令的映射唯一，身份四元组原样带回命令**顶层**', () async {
    await core.request(PluginMethods.hello, <String, dynamic>{
      'plugin_id': SelfUpdaterIdentity.pluginId,
    });
    core.outgoing.clear();
    final Map<String, dynamic> result = await core.request(
      PluginMethods.toolsCall,
      <String, dynamic>{
        'name': SelfUpdaterTool.name,
        'arguments': <String, dynamic>{
          'action': 'restart',
          'plugin_id': 'words',
          'keep_state': false,
        },
        'scope': const <String, dynamic>{
          'team_id': 'team-1',
          'agent_id': 'agt_1',
          'session_id': 'sess-1',
          'mode_key': 'ssh',
        },
      },
    );
    expect(result['isError'], isFalse, reason: '$result');

    // 第一条 plugin.restart；wait_ready 缺省 true ⇒ 再读一次 plugin.state
    final List<Map<String, dynamic>> sent = core.outgoingWhere(
      PluginMethods.stationCommand,
    );
    expect(sent.map(_commandOf), <String>[
      PluginCommands.restart,
      PluginCommands.state,
    ]);
    final Map<String, dynamic> params =
        sent.first['params'] as Map<String, dynamic>;
    expect(
      params['team_id'],
      'team-1',
      reason: '身份带在顶层，核心据此证明归属（编一个 team 就是越权）',
    );
    expect(params['agent_id'], 'agt_1');
    expect(params['session_id'], 'sess-1');
    expect(params['mode_key'], 'ssh');
    expect(
      (params['arguments'] as Map<String, dynamic>)['keep_state'],
      isFalse,
    );
    expect(_textOf(result), contains('"lifecycle":"ready"'));
    expect(_textOf(result), contains('"generation":2'));
  });

  test('wait_ready=false ⇒ 只下那一条命令（不多打一次读数）', () async {
    final Map<String, dynamic> result = await core.request(
      PluginMethods.toolsCall,
      <String, dynamic>{
        'name': SelfUpdaterTool.name,
        'arguments': <String, dynamic>{
          'action': 'restart',
          'plugin_id': 'words',
          'wait_ready': false,
        },
        'scope': const <String, dynamic>{'team_id': 'team-1'},
      },
    );
    expect(result['isError'], isFalse);
    expect(
      core.outgoingWhere(PluginMethods.stationCommand).map(_commandOf),
      <String>[PluginCommands.restart],
    );
  });

  test('快照原语不得做成 action：stateDump / stateFetch 被拒，且一条命令都不下', () async {
    await core.request(PluginMethods.hello, <String, dynamic>{
      'plugin_id': SelfUpdaterIdentity.pluginId,
    });
    for (final String action in <String>['stateDump', 'stateFetch']) {
      core.outgoing.clear();
      final Map<String, dynamic> result = await core.request(
        PluginMethods.toolsCall,
        <String, dynamic>{
          'name': SelfUpdaterTool.name,
          'arguments': <String, dynamic>{'action': action, 'plugin_id': 'x'},
          'scope': const <String, dynamic>{'team_id': 'team-1'},
        },
      );
      expect(result['isError'], isTrue, reason: 'action=$action 必须回错误');
      expect(_textOf(result), contains('plugin.stateDump'));
      expect(
        core.outgoingWhere(PluginMethods.stationCommand),
        isEmpty,
        reason: '被拒的 action 不许先下一次执行站（那是把闸门推到核心那边）',
      );
    }
    final Map<String, dynamic> unknown = await core.request(
      PluginMethods.toolsCall,
      <String, dynamic>{
        'name': SelfUpdaterTool.name,
        'arguments': <String, dynamic>{'action': 'kill'},
      },
    );
    expect(unknown['isError'], isTrue);
    expect(_textOf(unknown), contains('未知 action'));
    expect(_textOf(unknown), contains('restart'), reason: '要给可改的措辞');
  });

  test('缺 plugin_id 的 restart ⇒ 可读错误，且不下命令', () async {
    final Map<String, dynamic> result = await core.request(
      PluginMethods.toolsCall,
      <String, dynamic>{
        'name': SelfUpdaterTool.name,
        'arguments': <String, dynamic>{'action': 'restart'},
        'scope': const <String, dynamic>{'team_id': 'team-1'},
      },
    );
    expect(result['isError'], isTrue);
    expect(_textOf(result), contains('需要 plugin_id'));
    expect(core.outgoingWhere(PluginMethods.stationCommand), isEmpty);
  });

  test('未知工具名 ⇒ 可读错误（核心注册表与插件不一致时不许沉默）', () async {
    final Map<String, dynamic> result = await core.request(
      PluginMethods.toolsCall,
      <String, dynamic>{
        'name': 'plugin__self_updater__rm_rf',
        'arguments': <String, dynamic>{},
      },
    );
    expect(result['isError'], isTrue);
    expect(_textOf(result), contains('未知工具'));
    expect(core.loop.toolCalls, isEmpty, reason: '连工具名都不对，不该计入调用数');
  });

  test('执行站说失败 ⇒ 工具回可读原因，并把「没有可证明归属」这件事说破', () async {
    core.commandOutcome = <String, dynamic>{
      'ok': false,
      'error': '命令 plugin.state 的 scope 缺少 team_id：证明不了归属 ⇒ 拒绝执行（fail-closed）',
    };
    final Map<String, dynamic> result = await core.request(
      PluginMethods.toolsCall,
      <String, dynamic>{
        'name': SelfUpdaterTool.name,
        'arguments': <String, dynamic>{'action': 'state', 'plugin_id': 'words'},
        // 没有 scope：调用点证明不了归属时，核心给的就是空
      },
    );
    expect(result['isError'], isTrue);
    final String text = _textOf(result);
    expect(text, contains('证明不了归属'));
    expect(text, contains('本次调用没有可证明的归属身份'));
    final Map<String, dynamic> sent = core
        .outgoingWhere(PluginMethods.stationCommand)
        .single;
    expect(
      (sent['params'] as Map<String, dynamic>).containsKey('team_id'),
      isFalse,
      reason: '没身份就不许编一个 team 出来',
    );
  });

  test('自重启：核心先应答再动手 ⇒ 不追读自己新一世的读数，并把原因写明', () async {
    await core.request(PluginMethods.hello, <String, dynamic>{
      'plugin_id': SelfUpdaterIdentity.pluginId,
    });
    core.outgoing.clear();
    core.commandOutcome = <String, dynamic>{
      'ok': true,
      'deferred': true,
      'plugin_id': SelfUpdaterIdentity.pluginId,
    };
    final Map<String, dynamic> result = await core.request(
      PluginMethods.toolsCall,
      <String, dynamic>{
        'name': SelfUpdaterTool.name,
        'arguments': <String, dynamic>{
          'action': 'restart',
          'plugin_id': SelfUpdaterIdentity.pluginId,
        },
        'scope': const <String, dynamic>{'team_id': 'team-1'},
      },
    );
    expect(result['isError'], isFalse, reason: _textOf(result));
    expect(
      core.outgoingWhere(PluginMethods.stationCommand).map(_commandOf),
      <String>[PluginCommands.restart],
      reason: '重启目标就是自己 ⇒ 不该再下 plugin.state（正在退出的我看不到新一世）',
    );
    expect(_textOf(result), contains('重启目标就是发起者本人'));
  });

  test('suspend 的顺序是"先转储、等回包、再 ack"（帧序列可数）', () async {
    core.autoReply = false; // 手动控制回包时机，才能证明 ack 在 dump 之后
    final Future<Map<String, dynamic>> ack = core.request(
      PluginMethods.suspend,
      const <String, dynamic>{'reason': 'hot_restart'},
    );
    await pumpEventQueue();
    final List<Map<String, dynamic>> dumpRequests = core.outgoingWhere(
      PluginMethods.stationCommand,
    );
    expect(dumpRequests, hasLength(1));
    expect(_commandOf(dumpRequests.single), PluginCommands.stateDump);
    expect(core.responses, isEmpty, reason: '转储的回包没到 ⇒ ack 必须还没发出去');

    core.replyLastOutgoing(<String, dynamic>{
      'command': PluginCommands.stateDump,
      'ok': true,
      'payload': <String, dynamic>{'ok': true, 'dump_id': 'd-9', 'bytes': 64},
    });
    final Map<String, dynamic> acked = await ack;
    expect(acked['dumped'], isTrue);
    expect(acked['dump_id'], 'd-9');
    expect(core.loop.dumpCount, 1);
  });

  test('转储没完成时 ping 照样必答（读循环从不 await 业务）', () async {
    core.autoReply = false;
    await core.request(
      PluginMethods.suspend,
      const <String, dynamic>{},
      toleratePending: true,
    );
    await pumpEventQueue();
    expect(
      core.outgoingWhere(PluginMethods.stationCommand),
      hasLength(1),
      reason: 'suspend 正卡在等转储回包',
    );

    final Map<String, dynamic> pong = await core
        .request(PluginMethods.ping, const <String, dynamic>{})
        .timeout(const Duration(seconds: 2));
    expect(pong['ok'], isTrue, reason: '心跳被慢活堵住 = 核心判 degraded 的唯一来源，绝不能发生');

    core.replyLastOutgoing(<String, dynamic>{
      'ok': true,
      'payload': <String, dynamic>{'dump_id': 'd-x'},
    });
  });

  test('shutdown（请求形态）先回 ack 再收手；run() 以 0 收尾', () async {
    final Map<String, dynamic> ack = await core.request(
      PluginMethods.shutdown,
      const <String, dynamic>{},
    );
    expect(ack['ok'], isTrue);
    expect(await core.exitCode, 0);
  });

  test('通道断开时在途的命令以可读失败收尾（不静默、也不永远悬着）', () async {
    core.autoReply = false;
    final Future<Map<String, dynamic>> pending = core.request(
      PluginMethods.toolsCall,
      <String, dynamic>{
        'name': SelfUpdaterTool.name,
        'arguments': <String, dynamic>{'action': 'list'},
        'scope': const <String, dynamic>{'team_id': 'team-1'},
      },
    );
    await pumpEventQueue();
    expect(core.outgoingWhere(PluginMethods.stationCommand), hasLength(1));

    await core.closeStdin();
    expect(await core.exitCode, 0, reason: '核心关流 ⇒ 正常退场，不是崩溃');
    final Map<String, dynamic> result = await pending;
    expect(result['isError'], isTrue);
    expect(
      _textOf(result),
      contains('插件正在退出'),
      reason: '那条命令的结论必须是"通道断了所以没做成"，而不是没人管它',
    );
  });

  test('身份表与执行站命令名逐字对齐（漂移只会在运行时以"未知命令"暴露）', () async {
    expect(SelfUpdaterTool.actions.values.toSet(), <String>{
      PluginCommands.list,
      PluginCommands.state,
      PluginCommands.restart,
      PluginCommands.suspend,
    });
    expect(SelfUpdaterIdentity.pluginId, 'self_updater');
    expect(SelfUpdaterTool.name, 'plugin_hot_restart');
    expect(
      SelfUpdaterTool.refusedActions,
      containsAll(<String>['stateDump', 'stateFetch']),
    );
    // 被拒清单与可申报清单必须**不相交**（相交就是同一个命令既能被模型使唤
    // 又被声明成原语 —— 那正是 D9 要拦的形状）。
    final Set<String> exposed = SelfUpdaterTool.actions.values.toSet();
    for (final String refused in SelfUpdaterTool.refusedActions) {
      expect(exposed, isNot(contains(refused)));
      expect(exposed, isNot(contains('plugin.$refused')));
    }
  });
}

// ───────────────────────── 假核心 ─────────────────────────

String _commandOf(Map<String, dynamic> frame) {
  final Object? params = frame['params'];
  return (params is Map ? params['command'] : null)?.toString() ?? '';
}

String _textOf(Map<String, dynamic> toolResult) {
  final List<dynamic> content =
      (toolResult['content'] as List<dynamic>?) ?? const <dynamic>[];
  return content.isEmpty ? '' : (content.first['text'] ?? '').toString();
}

/// 一个最小的假核心：喂帧给插件、收插件发来的帧，并可自动或手动回应。
///
/// `autoReply = false` 是给"必须控制回包时机"的用例的：先看到插件下了什么，
/// 再决定什么时候回 —— 否则"先转储后 ack"这类**顺序**断言就只能靠运气。
class _Harness {
  _Harness() {
    _loop = SelfUpdaterLoop(send: _onPluginFrame, log: _logLines.add);
    _exit = _loop.run(stdin.stream);
  }

  final StreamController<List<int>> stdin = StreamController<List<int>>();
  final List<String> _logLines = <String>[];
  late final SelfUpdaterLoop _loop;
  late final Future<int> _exit;

  /// 插件本体（读它的计数器就是"可数证据"）。
  SelfUpdaterLoop get loop => _loop;

  /// 插件日志：`SelfUpdaterLoop` 只经 `send` 出帧，日志不公开，因此由假核心收集。
  List<String> get logLines => _logLines;

  /// 插件发出的**全部**帧（按到达顺序）。
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  /// 插件对核心请求的**响应帧**（ack 的证据面）。
  final List<Map<String, dynamic>> responses = <Map<String, dynamic>>[];

  final Map<Object, Completer<Map<String, dynamic>>> _waiting =
      <Object, Completer<Map<String, dynamic>>>{};
  int _coreId = 100;

  /// true = 见到 `station/command` 就自动回罐头结论；false = 由用例 [replyLastOutgoing]。
  bool autoReply = true;

  /// 覆盖自动回包的业务结论（用于"核心拒绝"那一类用例）。
  Map<String, dynamic>? commandOutcome;

  // `plugin.stateFetch` 的罐头读数。
  bool hasSnapshot = false;
  Map<String, dynamic> snapshotPayload = const <String, dynamic>{};
  int snapshotBytes = 0;

  /// 插件**发给核心**的请求帧（本插件只会下 `station/command`）；用例可以 `clear()`
  /// 把它当分段记账本（否则前面握手机里那一次 stateFetch 会污染后面的顺序断言）。
  final List<Map<String, dynamic>> outgoing = <Map<String, dynamic>>[];

  /// 按 method 过滤 [outgoing]（保留这个入口是为了读起来像断言而不是像记账本）。
  List<Map<String, dynamic>> outgoingWhere(String method) => outgoing
      .where((Map<String, dynamic> f) => f['method'] == method)
      .toList(growable: false);

  /// 插件最近发出、尚未回应的那条 `station/command`。
  Map<String, dynamic> get lastOutgoing => _unanswered.last;

  final List<Map<String, dynamic>> _unanswered = <Map<String, dynamic>>[];

  /// 发一条核心 → 插件的请求并等它的响应。
  ///
  /// [toleratePending] = true 用于"故意不回应"的用例（不 await 它，否则死等）。
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    bool toleratePending = false,
  }) {
    final int id = _coreId++;
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _waiting[id] = completer;
    stdin.add(
      utf8.encode(
        _line(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }),
      ),
    );
    if (toleratePending) {
      // 故意不回 ack 的用例：这条 future 的后续错误（超时 / 通道断开）与本题无关，
      // 显式丢掉而不是让它冒到 zone 里变成“上一个用例的噪声”。
      completer.future.ignore();
      return Future<Map<String, dynamic>>.value(<String, dynamic>{});
    }
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () =>
          throw StateError('插件没回 $method；出站帧：$frames；日志：$_logLines'),
    );
  }

  /// 手动回一条插件请求（信封由假核心拼）。
  void replyLastOutgoing(Map<String, dynamic> envelope) {
    final Map<String, dynamic> frame = lastOutgoing;
    _unanswered.remove(frame);
    _deliver(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': frame['id'],
      'result': envelope,
    });
  }

  Future<void> closeStdin() => stdin.close();

  Future<int> get exitCode => _exit;

  void dispose() {
    if (!stdin.isClosed) unawaited(stdin.close());
  }

  void _onPluginFrame(Map<String, dynamic> frame) {
    frames.add(frame);
    if (RpcIds.isResponse(frame)) {
      // 插件对核心请求的回答。
      responses.add(frame);
      final Completer<Map<String, dynamic>>? waiting = _waiting.remove(
        frame['id'] as Object,
      );
      if (waiting == null || waiting.isCompleted) return;
      final Object? error = frame['error'];
      if (error != null) {
        final String message = error is Map
            ? (error['message'] ?? '').toString()
            : error.toString();
        waiting.complete(<String, dynamic>{
          'isError': true,
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': '协议错误：$message'},
          ],
        });
        return;
      }
      final Object? result = frame['result'];
      waiting.complete(
        result is Map
            ? result.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
            : <String, dynamic>{'result': result},
      );
      return;
    }
    if (RpcIds.isNotification(frame)) return;
    if (!RpcIds.isRequest(frame)) return;
    final Object? id = frame['id'];
    final String method = (frame['method'] ?? '').toString();
    if (method != PluginMethods.stationCommand) {
      _deliver(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, dynamic>{
          'code': RpcCodes.methodNotFound,
          'message': '假核心不认 method「$method」',
        },
      });
      return;
    }
    outgoing.add(frame);
    _unanswered.add(frame);
    if (!autoReply) return; // 手动模式：等用例自己回，才能断言顺序
    _unanswered.remove(frame);
    final String command = _commandOf(frame);
    final Map<String, dynamic> outcome =
        commandOutcome ?? _defaultOutcome(command);
    _deliver(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': <String, dynamic>{
        'command': command,
        'ok': outcome['ok'] ?? true,
        'mount_id': 'system.execute.plugin',
        'payload': outcome,
        if (outcome['error'] != null) 'error': outcome['error'],
      },
    });
  }

  Map<String, dynamic> _defaultOutcome(String command) {
    switch (command) {
      case PluginCommands.stateFetch:
        return <String, dynamic>{
          'ok': true,
          'has_snapshot': hasSnapshot,
          'payload': snapshotPayload,
          'bytes': snapshotBytes,
          if (!hasSnapshot) 'reason': '这一世没有可续跑的快照（测试罐头）',
        };
      case PluginCommands.stateDump:
        return <String, dynamic>{
          'ok': true,
          'dump_id': 'd-test',
          'bytes': 32,
          'pool_entries': 1,
        };
      case PluginCommands.state:
        return <String, dynamic>{
          'ok': true,
          'plugin_id': 'words',
          'lifecycle': 'ready',
          'generation': 2,
        };
      case PluginCommands.list:
        return <String, dynamic>{
          'ok': true,
          'plugins': <Map<String, dynamic>>[
            <String, dynamic>{'plugin_id': 'words', 'running': true},
          ],
        };
      default:
        return <String, dynamic>{'ok': true};
    }
  }

  void _deliver(Map<String, dynamic> frame) =>
      stdin.add(utf8.encode(_line(frame)));
}

/// 把帧编成"一行一帧"的文本（`encodeFrame` 给的是带换行的字节，这里转回字符串
/// 只是为了让 `utf8.encode` 那一步读起来不绕）。
String _line(Map<String, dynamic> frame) => utf8.decode(encodeFrame(frame));
