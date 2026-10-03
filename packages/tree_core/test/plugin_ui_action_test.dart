import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'ws_harness.dart';

/// **插件 UI 动作回路（前端帧 → 核心 → 插件进程）的核心侧测试**。
///
/// 链路上半段已有测试（`plugin_ui_bridge_test.dart` / `plugin_ui_manifest_test.dart`
/// 管声明与缓存、`plugin_ui_replay_test.dart` 管补发），但**用户在插件面板上点按钮**
/// 这条下行路径此前零覆盖：
///
/// 1. 前端发一条上行帧 `{"type":"plugin_ui_action","data":{plugin_id,team_id,agent_id,
///    session_id,slot_key,action_id,payload}}`（[PluginUiAction]）；
/// 2. 核心 `_handlePluginUiAction` 按 `plugin_id` 在 `pluginBus.instances()` 里找实例，
///    命中就 `host.dispatchEvent({...})`；找不到就显式回一帧 `error`；
/// 3. `PluginHost.dispatchEvent` 把它包成 **JSON-RPC 通知**
///    `{"jsonrpc":"2.0","method":"event","params":{"event":"plugin_ui_action",...}}`。
///
/// **本文件存在的核心理由（钉住一个真实的坑）**：插件进程拿到的动作类型在
/// `params.event` 上，而**不是** `params.method`——真正的 `method` 是信封上的 `"event"`。
/// 谁把动作判据写在 `method` 层（例如期待收到 `{"method":"plugin_ui_action"}`），
/// 插件就永远取不到事件名，表现为"用户点了按钮毫无反应、且没有任何报错"。
/// 因此断言跑在**插件进程落盘的那一行**（假插件的 `--events-file` 抄的是 `params`），
/// 而不是"连接上出现过什么帧"——后者只能证明核心发了点什么，证不了插件收到了什么。
void main() {
  late Directory temp;
  late PluginBus bus;
  late CoreServer server;
  late TestWs ws;

  /// 假插件脚本（Dart 脚本，用跑测试的同一个 dart 可执行文件去跑它）。
  String scriptPath() => p.normalize(
    p.join(Directory.current.path, 'test', 'fixtures', 'fake_plugin.dart'),
  );

  /// plugins.yaml 是双引号 YAML 串，反斜杠在里面是转义符 ⇒ 落盘前统一成正斜杠
  /// （Dart 的 `File` 在 Windows 上同样认正斜杠）。
  String slash(String path) => path.replaceAll(Platform.pathSeparator, '/');

  /// 事件文件路径：假插件把收到的每条 `event` 通知的 `params` 追加成一行 JSON。
  /// 这是"插件**进程**实际收到了什么"的唯一真实抓手。
  String eventsPath() => p.join(temp.path, 'events.jsonl');

  /// 读已落盘的事件行（按"可 JSON 解析"过滤，避免读到半行）。
  List<Map<String, dynamic>> eventLines() {
    final File file = File(eventsPath());
    if (!file.existsSync()) return <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> parsed = <Map<String, dynamic>>[];
    for (final String line in file.readAsStringSync().split('\n')) {
      if (line.trim().isEmpty) continue;
      try {
        final Object? decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) parsed.add(decoded);
      } catch (_) {
        // 半行：跳过（插件是整行 append，理论上不会出现）
      }
    }
    return parsed;
  }

  /// 轮询等第一行事件落盘（只有插件**进程**收到通知才会有这一行）。
  Future<Map<String, dynamic>> waitFirstEvent(String reason) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      final List<Map<String, dynamic>> lines = eventLines();
      if (lines.isNotEmpty) return lines.first;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('超时等待$reason；events 文件内容=${eventLines()}');
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_ui_action_');

    // 真插件配置：命令行必须是"dart <fake_plugin.dart> --ui-manifest --events-file <路径>"。
    // `Platform.resolvedExecutable` = 跑本测试的那个 dart（务必用 3.13.4 那一个）。
    final File config = File(p.join(temp.path, 'config', 'plugins.yaml'));
    config.createSync(recursive: true);
    config.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: demo\n'
      '    name: 动作回路插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(scriptPath())}", "--ui-manifest", '
      '"--events-file", "${slash(eventsPath())}"]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1}\n',
    );

    // 插件总线的广播转发给 WS hub，前端（TestWs）才收得到槽位声明。
    bus = PluginBus(
      configFile: config.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      broadcast: (Map<String, dynamic> frame) => server.hub.broadcast(frame),
    );
    server = await CoreServer.start(
      pluginBus: bus,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    ws = await TestWs.connect(server);
    ws.record();

    await bus.start();
    // 「先声明、后动作」是契约本身（前端得先有面板才点得动），所以每个用例都在
    // 声明落定之后才发动作帧——否则动作可能撞进插件尚未 online 的窗口，
    // 本文件的主用例就会悄悄退化成"未运行"分支的空转。
    await ws.until(
      (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.manifest,
      reason: '假插件启动时推的 ui/manifest',
    );
  });

  tearDown(() async {
    await ws.close();
    await server.close();
    await bus.close();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        // Windows 上插件进程可能还没松开文件句柄，稍后重试
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('主用例：在线插件的动作 ⇒ 插件进程收到 params.event=plugin_ui_action（判据不在 method 上）', () async {
    // 前置：插件必须真的 online，否则动作会落进"未运行"分支，本用例就成了空转。
    expect(
      bus.instances().map((e) => e.pluginId),
      contains('demo'),
      reason: '派发的前提是插件实例在线',
    );
    // 「声明先于动作」：动作帧发出之前，槽位声明必须已经在连接上出现过。
    final int manifestAt = ws.frames.indexWhere(
      (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.manifest,
    );
    expect(
      manifestAt,
      isNonNegative,
      reason: '动作之前必须已经有过 ui/manifest（先有面板才点得到）',
    );
    final int framesBeforeAction = ws.frames.length;

    const Map<String, dynamic> payload = <String, dynamic>{
      'k': 'v',
      'n': 3,
      'nested': <String, dynamic>{
        'deep': <String>['a', 'b'],
      },
    };
    final Map<String, dynamic> frame = const PluginUiAction(
      pluginId: 'demo',
      teamId: 'team-1',
      agentId: 'agt_1',
      sessionId: 'ses_1',
      slotKey: 'fake.activity.1',
      actionId: 'refresh',
      payload: payload,
    ).toFrame();

    // 顺手钉住协议类产出的**线上形状**（手写一份对照）。前后端各自实现时形状一漂，
    // 这里立刻失败，而不是变成"点按钮没反应"的静默故障。
    expect(
      frame,
      equals(<String, dynamic>{
        'type': 'plugin_ui_action',
        'data': <String, dynamic>{
          'plugin_id': 'demo',
          'team_id': 'team-1',
          'agent_id': 'agt_1',
          'session_id': 'ses_1',
          'slot_key': 'fake.activity.1',
          'action_id': 'refresh',
          'payload': <String, dynamic>{
            'k': 'v',
            'n': 3,
            'nested': <String, dynamic>{
              'deep': <String>['a', 'b'],
            },
          },
        },
      }),
      reason: 'PluginUiAction.toFrame() 必须就是文档里的上行帧形状（前端照它发）',
    );
    expect(
      frame['type'],
      WsInboundType.pluginUiAction,
      reason: '动作帧必须登记进 WsInboundType（别名口径），否则核心的完备性门禁与路由对不上',
    );

    ws.send(frame);
    final Map<String, dynamic> got = await waitFirstEvent('插件进程落盘的 event 通知');

    // ① 本用例的核心判据：插件进程收到的是 JSON-RPC 通知 `method:"event"`，
    //    动作类型在 **params.event** 上；事件文件里存的就是那个 params。
    expect(
      got['event'],
      'plugin_ui_action',
      reason: '动作类型必须在 params.event 上：判据写错层就永远取不到（静默失效）',
    );
    // ② 反面钉子：params 里**没有** method。谁把动作判据写成 `params.method`
    //    （或把信封上的 method 塞进 params），插件侧取到的就是 null ⇒ 用户点按钮
    //    "毫无反应且无报错"。这一条就是用来钉住这个坑的。
    expect(
      got['method'],
      isNull,
      reason: 'JSON-RPC 的 method 在信封上（值是 "event"），params 里不得再出现 method',
    );
    // ③ 路由依据是**实例 id**（plugins.yaml 里的 id），不是插件 hello 时自称的名字
    //    （假插件自称 'fake-plugin'，路由错用自称名时这里就会露馅）。
    expect(
      got['plugin_id'],
      'demo',
      reason: '必须是实例 id：核心按 plugins.yaml 的 id 在 instances() 里找宿主',
    );
    // ④ 槽位 / 动作 / 载荷原样透传（核心不解释动作语义，也不改写载荷）。
    expect(got['slot_key'], 'fake.activity.1');
    expect(got['action_id'], 'refresh');
    expect(
      got['payload'],
      payload,
      reason: 'payload 原样透传（含嵌套结构），核心不得改写',
    );
    // ⑤ 身份三元组原样透传：插件据此判断"是哪个 team / agent / session 点的"。
    expect(got['team_id'], 'team-1');
    expect(got['agent_id'], 'agt_1');
    expect(got['session_id'], 'ses_1');
    // ⑥ 时序：声明先于动作。
    expect(
      manifestAt,
      lessThan(framesBeforeAction),
      reason: '槽位声明必须早于动作帧（顺序即契约）',
    );
    // ⑦ 在线派发不该回 error（否则"事件文件里有内容"可能来自别的路径）。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      ws.frames.where(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.error,
      ),
      isEmpty,
      reason: '派发成功的动作不该产生 error 帧',
    );
  });

  test('插件不在线：动作帧不静默丢弃，连接上收到 error（message 含「未运行」）', () async {
    // 前置：插件总线**已启用且有实例**——这样"ghost 报错"就不是"总线根本没起"
    // 造成的假阳性，而真的是"按 id 找不到实例"。
    expect(
      bus.instances().map((e) => e.pluginId),
      contains('demo'),
      reason: '前置：总线里已有 demo 实例',
    );
    expect(
      bus.instances().map((e) => e.pluginId),
      isNot(contains('ghost')),
      reason: '前置：ghost 确实不在线',
    );

    // 手写线上形状（不经过协议类）：任何前端只要发出这个形状，核心都该照契约处理。
    ws.send(<String, dynamic>{
      'type': PluginUiFrameType.action,
      'data': <String, dynamic>{
        'plugin_id': 'ghost',
        'team_id': 'team-1',
        'slot_key': 'ghost.panel.1',
        'action_id': 'refresh',
        'payload': <String, dynamic>{},
      },
    });

    // 契约是"显式报错，不静默丢弃"：静默丢弃会让用户点了按钮却毫无反应。
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.error &&
          '${(f['data'] as Map<String, dynamic>?)?['message']}'.contains('未运行'),
      reason: '插件不在线的显式报错（message 含「未运行」）',
    );
    final Map<String, dynamic> err = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.error,
    );
    expect(
      (err['data'] as Map<String, dynamic>)['message'],
      contains('ghost'),
      reason: '报错要点名是哪个插件（否则用户不知道该去启哪个）',
    );
    // 未送达 ⇒ 插件进程压根不存在 ⇒ 不可能有事件落盘。
    expect(
      eventLines(),
      isEmpty,
      reason: '未送达的动作不得被记成"已送达到插件"',
    );
  });

  test('缺 / 空 plugin_id：同样显式回 error（不静默丢弃）', () async {
    // ① data 里**没有** plugin_id 键（老前端 / 手写帧可能这样发）
    ws.send(<String, dynamic>{
      'type': PluginUiFrameType.action,
      'data': <String, dynamic>{
        'slot_key': 'fake.activity.1',
        'action_id': 'refresh',
      },
    });
    await ws.untilCount(
      WsOutboundType.error,
      1,
      timeout: const Duration(seconds: 10),
    );

    // ② plugin_id 是空串（前端拿不到归属时会发空值）
    ws.send(<String, dynamic>{
      'type': PluginUiFrameType.action,
      'data': <String, dynamic>{
        'plugin_id': '',
        'slot_key': 'fake.activity.1',
        'action_id': 'refresh',
      },
    });
    await ws.untilCount(
      WsOutboundType.error,
      2,
      timeout: const Duration(seconds: 10),
    );

    for (final Map<String, dynamic> err
        in ws.frames.where(
          (Map<String, dynamic> f) => f['type'] == WsOutboundType.error,
        )) {
      expect(
        '${(err['data'] as Map<String, dynamic>)['message']}',
        contains('plugin_id'),
        reason: '报错要说清是缺 plugin_id，而不是含糊地静默丢弃',
      );
    }
    // 没有 plugin_id 就**不能**派发：尤其不能退化成"广播给所有插件"
    // （那会让所有插件都以为用户点了自己的按钮）。
    expect(
      eventLines(),
      isEmpty,
      reason: '无 plugin_id 的动作不得被派发给任何插件（更不能广播）',
    );
  });
}
