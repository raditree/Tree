import 'dart:async';
import 'dart:convert' show jsonEncode, utf8;

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'plugin_methods.dart';
import 'self_updater_loop.dart';
import 'tool_surface.dart';

/// 随包自检：在**同一个进程里**装一条脚本化的假核心，走一遍
/// 握手 → 双路申报工具 → 执行一次 action → 转储 → 拒绝生命周期原语。
///
/// 为什么值得写它（而不是"装了再看面板"）：装机后端到端验证要的是**可判定的退出码**。
/// "插件起来了、面板没报错"证明不了工具真的能申报进表；这几条断言能。
///
/// 每一步都只核**事实**（帧里的字段、计数），不核"看起来成功了"。
Future<int> runSelfTest({void Function(String line)? emit}) async {
  final void Function(String) say = emit ?? ((String line) {});
  final List<String> failures = <String>[];

  void check(String name, bool ok, [String detail = '']) {
    if (!ok) failures.add('$name${detail.isEmpty ? '' : '（$detail）'}');
    say('${ok ? 'PASS' : 'FAIL'}  $name${detail.isEmpty ? '' : '  → $detail'}');
  }

  final StreamController<List<int>> coreIn = StreamController<List<int>>();
  final Map<Object, Completer<Map<String, dynamic>>> pluginReplies =
      <Object, Completer<Map<String, dynamic>>>{};
  int coreId = 1000;

  final SelfUpdaterLoop loop = SelfUpdaterLoop(
    send: (Map<String, dynamic> frame) =>
        _onPluginFrame(frame, coreIn, pluginReplies),
  );
  final Future<int> exitCode = loop.run(coreIn.stream);

  // ── ① 握手 ───────────────────────────────────────────────────────────
  final Map<String, dynamic> hello = await _askCore(
    coreIn,
    pluginReplies,
    () => coreId++,
    PluginMethods.hello,
    <String, dynamic>{
      'protocol': 1,
      'core_version': 'selftest',
      'plugin_id': SelfUpdaterIdentity.pluginId,
    },
  );
  check(
    'hello 回了自报身份',
    hello['plugin_id'] == SelfUpdaterIdentity.pluginId &&
        hello['name'] == SelfUpdaterIdentity.name,
    '$hello',
  );

  // ── ② tools/list 那一面 ──────────────────────────────────────────────
  final Map<String, dynamic> listed = await _askCore(
    coreIn,
    pluginReplies,
    () => coreId++,
    PluginMethods.toolsList,
    const <String, dynamic>{},
  );
  final List<dynamic> listTools =
      (listed['tools'] as List<dynamic>?) ?? const <dynamic>[];
  check(
    'tools/list 申报了唯一一个工具',
    listTools.length == 1 && listTools.first['name'] == SelfUpdaterTool.name,
    '$listTools',
  );

  // ── ③ 收集站那一面（同一份 schema，不同字段名）────────────────────────
  final Map<String, dynamic> collected = await _askCore(
    coreIn,
    pluginReplies,
    () => coreId++,
    PluginMethods.stationRequest,
    <String, dynamic>{
      'station_id': 'plugin.tool.define',
      'kind': 'collect',
      'payload': <String, dynamic>{},
    },
  );
  final Map<String, dynamic> collectPayload =
      (collected['reply'] is Map &&
          (collected['reply'] as Map)['payload'] is Map)
      ? Map<String, dynamic>.from(
          ((collected['reply'] as Map)['payload'] as Map).map(
            (dynamic k, dynamic v) => MapEntry(k.toString(), v),
          ),
        )
      : const <String, dynamic>{};
  final List<dynamic> collectTools =
      (collectPayload['tools'] as List<dynamic>?) ?? const <dynamic>[];
  check(
    '收集站按 schema 申报（tool_name / parameters / execution）',
    collectTools.length == 1 &&
        collectTools.first['tool_name'] == SelfUpdaterTool.name &&
        collectTools.first['parameters'] is Map &&
        (collectTools.first['execution'] as Map?)?['method'] ==
            PluginMethods.toolsCall,
    '$collectTools',
  );

  // ── ④ 执行一次 action=list（转述给执行站，再把结论交回）───────────────
  final Map<String, dynamic> called = await _askCore(
    coreIn,
    pluginReplies,
    () => coreId++,
    PluginMethods.toolsCall,
    <String, dynamic>{
      'name': SelfUpdaterTool.name,
      'arguments': <String, dynamic>{'action': 'list'},
      'scope': <String, dynamic>{
        'team_id': 'team-selftest',
        'agent_id': 'agt_selftest',
        'session_id': 'sess-selftest',
        'mode_key': 'local',
      },
    },
  );
  check(
    'action=list 走通了执行站并回给工具层（不是错误）',
    called['isError'] == false &&
        (called['content'] as List<dynamic>?)?.isNotEmpty == true,
    '$called',
  );

  // ── ⑤ 生命周期原语不得做成 action（D9）──────────────────────────────
  final Map<String, dynamic> refused = await _askCore(
    coreIn,
    pluginReplies,
    () => coreId++,
    PluginMethods.toolsCall,
    <String, dynamic>{
      'name': SelfUpdaterTool.name,
      'arguments': <String, dynamic>{'action': 'stateDump'},
      'scope': const <String, dynamic>{'team_id': 'team-selftest'},
    },
  );
  final String refusedText = _firstText(refused);
  check(
    'action=stateDump 被拒（快照原语不暴露给模型）',
    refused['isError'] == true && refusedText.contains('plugin.stateDump'),
    refusedText,
  );

  // ── ⑥ suspend：先转储、等回包、再 ack ───────────────────────────────
  final Map<String, dynamic> ack = await _askCore(
    coreIn,
    pluginReplies,
    () => coreId++,
    PluginMethods.suspend,
    const <String, dynamic>{'reason': 'hot_restart'},
  );
  check(
    'suspend 的 ack 里 dumped=true（说明 plugin.stateDump 的回包先到了）',
    ack['ok'] == true && ack['dumped'] == true,
    '$ack',
  );
  check(
    '转储计数与 dump_id 一致',
    loop.dumpCount == 1 && loop.lastDumpId == 'd-selftest',
    'dumps=${loop.dumpCount} id=${loop.lastDumpId}',
  );

  // ── ⑦ ping 必答（转储期间也不能堵）───────────────────────────────────
  final Map<String, dynamic> pong = await _askCore(
    coreIn,
    pluginReplies,
    () => coreId++,
    PluginMethods.ping,
    const <String, dynamic>{},
  );
  check('ping 立即回答', pong['ok'] == true, '$pong');

  // 收手：假核心关流 ⇒ 插件正常退出（0），不留悬着的任务。
  await coreIn.close();
  final int code = await exitCode.timeout(
    const Duration(seconds: 10),
    onTimeout: () => -1,
  );
  check('核心关闭 stdin 后插件以 0 退出', code == 0, 'exit=$code');

  if (failures.isEmpty) {
    say('self_updater 自检通过（7 项全部为真）');
    return 0;
  }
  say('self_updater 自检失败：${failures.join('；')}');
  return 1;
}

/// 假核心对**插件发来的帧**的处置：请求回罐头结果，响应交给等待者。
void _onPluginFrame(
  Map<String, dynamic> frame,
  StreamController<List<int>> coreIn,
  Map<Object, Completer<Map<String, dynamic>>> pluginReplies,
) {
  if (RpcIds.isResponse(frame)) {
    // 插件对我方请求的响应/错误。
    final Completer<Map<String, dynamic>>? waiting = pluginReplies.remove(
      frame['id']!,
    );
    if (waiting != null && !waiting.isCompleted) {
      if (frame['error'] != null) {
        waiting.complete(<String, dynamic>{'error': frame['error']});
      } else {
        waiting.complete(
          Map<String, dynamic>.from(
            (frame['result'] as Map? ?? const <String, dynamic>{}).map(
              (dynamic k, dynamic v) => MapEntry(k.toString(), v),
            ),
          ),
        );
      }
    }
    return;
  }
  if (!RpcIds.isRequest(frame)) return;
  // 插件 → 核心的请求：只可能是 `station/command`（转述执行站）。
  final String method = (frame['method'] ?? '').toString();
  final Object? id = frame['id'];
  final Map<String, dynamic> params = Map<String, dynamic>.from(
    (frame['params'] as Map? ?? const <String, dynamic>{}).map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    ),
  );
  final String command = (params['command'] ?? '').toString();
  Map<String, dynamic> payload = <String, dynamic>{};
  bool ok = true;
  String error = '';
  switch (command) {
    case PluginCommands.stateFetch:
      // 自检里没有上一世：如实回"没有快照"，看插件是否按冷启动继续（不是错误）。
      payload = <String, dynamic>{'has_snapshot': false, 'reason': '自检：池里没有快照'};
    case PluginCommands.stateDump:
      payload = <String, dynamic>{'dump_id': 'd-selftest', 'bytes': 42};
    case PluginCommands.list:
      payload = <String, dynamic>{
        'plugins': <Map<String, dynamic>>[
          <String, dynamic>{
            'plugin_id': SelfUpdaterIdentity.pluginId,
            'lifecycle': 'ready',
            'generation': 1,
          },
        ],
      };
    case PluginCommands.state:
      payload = <String, dynamic>{'lifecycle': 'ready', 'generation': 2};
    case PluginCommands.restart:
    case PluginCommands.suspend:
      payload = <String, dynamic>{
        'plugin_id': params['plugin_id'],
        'resumed': false,
      };
    default:
      ok = false;
      error = '未知命令 $command';
  }
  if (method != PluginMethods.stationCommand) {
    ok = false;
    error = '本自检不认 method「$method」';
  }
  coreIn.add(
    encodeFrame(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': <String, dynamic>{
        'command': command,
        'ok': ok,
        'mount_id': ok ? 'system.execute.plugin' : '',
        'payload': <String, dynamic>{
          'ok': ok,
          ...payload,
          if (!ok) 'error': error,
        },
        if (!ok) 'error': error,
      },
    }),
  );
}

/// 假核心发一条请求并等插件的回答（超时 = 失败，不静默挂着）。
Future<Map<String, dynamic>> _askCore(
  StreamController<List<int>> coreIn,
  Map<Object, Completer<Map<String, dynamic>>> pluginReplies,
  int Function() nextId,
  String method,
  Map<String, dynamic> params,
) async {
  final int id = nextId();
  final Completer<Map<String, dynamic>> reply =
      Completer<Map<String, dynamic>>();
  pluginReplies[id] = reply;
  coreIn.add(
    utf8.encode(
      '${jsonEncode(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})}\n',
    ),
  );
  return reply.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => <String, dynamic>{
      'isError': true,
      'content': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': '插件没回 $method'},
      ],
    },
  );
}

String _firstText(Map<String, dynamic> toolResult) {
  final List<dynamic> content =
      (toolResult['content'] as List<dynamic>?) ?? const <dynamic>[];
  if (content.isEmpty) return '';
  return (content.first['text'] ?? '').toString();
}
