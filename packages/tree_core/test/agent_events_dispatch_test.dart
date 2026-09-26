import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/agent_events.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'ws_harness.dart';

/// 可控引擎：只产出工具调用事件（不模拟任何时间）。
class _ToolEngine implements AgentEngine {
  _ToolEngine(this.events);

  final List<AgentEvent> events;

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    for (final AgentEvent event in events) {
      yield event;
    }
  }

  @override
  Future<void> close() async {}
}

/// **agent 事件 → 插件**（M9 追加）：会话服务发布的 `agent.tool_call` 经
/// `PluginBus.dispatchAgentEvent` 按**既有 scope 口径**（`config.scope` 为空即通配，
/// 非空则精确匹配 team_id / agent_id / session_id）派发给插件实例。
///
/// 这里跑的是**真插件进程**（test/fixtures/fake_plugin.dart，`--events-file` 把收到的
/// event 通知逐行落文件），因此"插件确实收到了 agent.tool_call"是文件级证据。
void main() {
  late Directory temp;
  late String script;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_agent_events_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    expect(File(script).existsSync(), isTrue, reason: '假插件脚本必须存在');
  });

  tearDown(() async {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  String slash(String path) => path.replaceAll(Platform.pathSeparator, '/');

  /// 一个插件条目：真 dart 进程跑假插件，收到的 event 通知追加到 [eventsFile]。
  String pluginEntry({
    required String id,
    required String eventsFile,
    String scopeLine = '    scope: {}',
  }) =>
      '  - id: $id\n'
      '    name: 假插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--events-file", "${slash(eventsFile)}"]\n'
      '    granularity: team\n'
      '$scopeLine\n';

  Future<PluginBus> startBus({
    required String yaml,
    void Function(String message)? log,
    void Function(Map<String, dynamic> frame)? broadcast,
  }) async {
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(yaml);
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      log: log,
      broadcast: broadcast,
    );
    addTearDown(bus.close);
    await bus.start();
    return bus;
  }

  /// 轮询直到插件落够 [count] 条事件（真进程写文件是异步的）。
  Future<List<Map<String, dynamic>>> waitEvents(
    String path,
    int count, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final File file = File(path);
      if (file.existsSync()) {
        final List<Map<String, dynamic>> parsed = file
            .readAsLinesSync()
            .where((String line) => line.trim().isNotEmpty)
            .map((String line) => jsonDecode(line) as Map<String, dynamic>)
            .toList();
        if (parsed.length >= count) return parsed;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('等待插件事件超时（期望 $count 条）：$path');
  }

  Map<String, dynamic> toolCallEvent({
    String teamId = 'team-1',
    String agentId = 'agt_1',
    String sessionId = 'ses_1',
    String tool = 'plugin__sample__echo',
    String callId = 'call_1',
    int round = 1,
    String phase = 'start',
  }) => <String, dynamic>{
    'event': AgentEvents.toolCall,
    'team_id': teamId,
    'agent_id': agentId,
    'session_id': sessionId,
    'tool': tool,
    'call_id': callId,
    'round': round,
    'phase': phase,
  };

  test('scope 命中才派发：agent.tool_call 原样到插件（并补 ts）', () async {
    final String eventsFile = p.join(temp.path, 'events.jsonl');
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
    final PluginBus bus = await startBus(
      yaml:
          'enabled: true\n'
          'plugins:\n'
          '${pluginEntry(id: 'sample', eventsFile: eventsFile, scopeLine: '    scope: {team_id: team-1}')}',
      broadcast: frames.add,
    );

    // ① scope 不匹配：派发 0 个（插件根本收不到）
    expect(
      bus.dispatchAgentEvent(toolCallEvent(teamId: 'team-2')),
      0,
      reason: '插件的 scope 是 team-1：team-2 的事件不得投给它',
    );
    // ② scope 命中：派发 1 个
    expect(bus.dispatchAgentEvent(toolCallEvent(round: 7)), 1);

    final List<Map<String, dynamic>> received = await waitEvents(eventsFile, 1);
    expect(received, hasLength(1), reason: '不匹配的那条不该落文件');
    final Map<String, dynamic> event = received.single;
    expect(event['event'], 'agent.tool_call');
    expect(event['team_id'], 'team-1');
    expect(event['agent_id'], 'agt_1');
    expect(event['session_id'], 'ses_1');
    expect(event['tool'], 'plugin__sample__echo');
    expect(event['call_id'], 'call_1');
    expect(event['round'], 7);
    expect(event['phase'], 'start');
    expect(event['ts'], isA<int>(), reason: '总线补的 ts 便于插件与自己日志对时间');

    // ③ 插件对事件的回执（log 通知）→ 前端 plugin_event 帧（通道也通）
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline) &&
        !frames.any(
          (Map<String, dynamic> f) => f['type'] == WsOutboundType.pluginEvent,
        )) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final Map<String, dynamic> frame = frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.pluginEvent,
    );
    expect((frame['data'] as Map<String, dynamic>)['plugin_id'], 'sample');
    expect((frame['data'] as Map<String, dynamic>)['method'], 'log');
  });

  test('scope 为空 = 通配：未声明 team 的插件也收得到（不发明新订阅语法）', () async {
    final String eventsFile = p.join(temp.path, 'wild.jsonl');
    final PluginBus bus = await startBus(
      yaml:
          'enabled: true\n'
          'plugins:\n'
          '${pluginEntry(id: 'wild', eventsFile: eventsFile)}',
    );
    expect(bus.dispatchAgentEvent(toolCallEvent(teamId: 'team-9')), 1);
    final List<Map<String, dynamic>> received = await waitEvents(eventsFile, 1);
    expect(received.single['team_id'], 'team-9');
    expect(received.single['event'], AgentEvents.toolCall);
  });

  test('缺 event 名称 ⇒ 拒发 + 可读日志（不崩）', () async {
    final List<String> logs = <String>[];
    final String eventsFile = p.join(temp.path, 'events.jsonl');
    final PluginBus bus = await startBus(
      yaml:
          'enabled: true\n'
          'plugins:\n'
          '${pluginEntry(id: 'sample', eventsFile: eventsFile, scopeLine: '    scope: {team_id: team-1}')}',
      log: logs.add,
    );

    expect(
      bus.dispatchAgentEvent(<String, dynamic>{
        'team_id': 'team-1',
        'agent_id': 'agt_1',
      }),
      0,
    );
    expect(bus.dispatchAgentEvent(<String, dynamic>{'event': '   '}), 0);
    expect(logs.where((String l) => l.contains('缺少 event 名称')), hasLength(2));
    expect(File(eventsFile).existsSync(), isFalse, reason: '无名事件不该投给插件');
  });

  test('会话服务 → 总线 → 插件：真链路（CoreServer + 真插件进程）', () async {
    final String eventsFile = p.join(temp.path, 'chain.jsonl');
    final PluginBus bus = await startBus(
      yaml:
          'enabled: true\n'
          'plugins:\n'
          '${pluginEntry(id: 'sample', eventsFile: eventsFile, scopeLine: '    scope: {team_id: team-1}')}',
    );
    final CoreServer server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      pluginBus: bus,
      engine: _ToolEngine(<AgentEvent>[
        AgentToolStart(
          id: 'tool_a',
          callId: 'call_a',
          name: 'read',
          arguments: const <String, dynamic>{'file_path': 'a.txt'},
        ),
        const AgentToolEnd(id: 'tool_a', name: 'read', result: 'A 的内容'),
        const AgentDone(finishReason: 'stop'),
      ]),
    );
    addTearDown(server.close);
    // **主控要在 core_server 里接的那一行**（这里是测试里显式接）
    server.conversation.agentEvents.sink = bus.dispatchAgentEvent;

    final String agentId = server.store.createAgent(name: '链路用例').id;
    final CoreAgent agent = server.store.agent(agentId)!;
    agent.teamId = 'team-1';
    server.store.putAgent(agent);
    final TestWs ws = await TestWs.connect(server);
    addTearDown(ws.close);
    ws.record();

    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': '跑一个工具',
      'session_id': TreeStore.defaultSessionId,
    });
    await waitIdle(ws);

    final List<Map<String, dynamic>> received = await waitEvents(eventsFile, 2);
    expect(received, hasLength(2), reason: 'start + end 各一条');
    expect(received[0]['event'], 'agent.tool_call');
    expect(received[0]['phase'], 'start');
    expect(received[0]['agent_id'], agentId);
    expect(received[0]['session_id'], TreeStore.defaultSessionId);
    expect(received[0]['team_id'], 'team-1');
    expect(received[0]['tool'], 'read');
    expect(received[0]['call_id'], 'call_a');
    expect(received[0]['round'], 1);
    expect(received[1]['phase'], 'end');
    expect(received[1]['round'], 1);
  });
}
