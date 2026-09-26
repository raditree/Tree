import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'fake_transport.dart';
import 'ws_harness.dart';

/// M4d 验收：后台长任务完成后**自动唤醒 agent**（terminal hook 闭环）。
///
/// 只有 LLM 传输是假的；工具执行、后台进程、日志文件、唤醒与续跑都是真的。
void main() {
  late Directory dataDir;
  late Directory workspace;
  late CoreServer server;
  late CoreSettings settings;
  late WorkspaceToolRunner tools;
  late String agentId;
  late FakeTransport transport;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('tree_hook_wake_');
    workspace = Directory(p.join(dataDir.path, 'ws'))
      ..createSync(recursive: true);
    transport = FakeTransport(<List<LlmStreamEvent>>[
      toolCallScript(
        name: 'terminal',
        arguments: '{"command":"echo hook-ok","hook":true}',
      ),
      textScript('后台已启动'),
      textScript('收到后台完成提示'),
    ]);
    settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
    });
    tools = WorkspaceToolRunner(
      resolveWorkspaceDir: (String id) => workspace.path,
    );
    server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      settings: settings,
      engine: LlmAgentEngine(
        resolveModel: settings.model,
        toolRunner: tools,
        transportFactory: (CoreModelConfig config) => transport,
      ),
    );
    // CLI 里的同一根接线：后台任务完成 → 唤醒 agent
    tools.onHookFinished = (String agentId, String sessionId, String notice) {
      server.conversation.wake(
        agentId: agentId,
        sessionId: sessionId,
        notice: notice,
      );
    };
    agentId = server.store.createAgent(name: 'hook 用例', modelId: 'demo').id;
  });

  tearDown(() async {
    await server.close();
    await tools.close();
    for (int i = 0; i < 10 && dataDir.existsSync(); i++) {
      try {
        dataDir.deleteSync(recursive: true);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  test('hook 启动即返回 → 命令结束 → 注入完成提示并自动续跑一轮', () async {
    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': '跑一下长任务',
      'session_id': TreeStore.defaultSessionId,
    });

    // 后台完成提示以完整 message 帧下发
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.message &&
          (f['content'] as String? ?? '').contains('[terminal hook]'),
      reason: '后台完成提示帧',
    );
    // 两轮生成（首轮 + 唤醒轮）各自 working/idle
    await ws.untilCount(WsOutboundType.agentStatus, 4);

    // 工具调用确实以 hook 模式启动（返回里带 task_id 与日志路径）
    final Map<String, dynamic> toolEnd = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolEnd,
    );
    expect((toolEnd['result'] as String), contains('[terminal hook]'));
    expect((toolEnd['result'] as String), contains('task_id'));

    // 两轮请求：第一轮带工具声明，第二轮带工具结果，第三轮（唤醒）带完成提示
    expect(transport.requests.length, greaterThanOrEqualTo(3));
    final String wakeMessages = transport.requests
        .expand((LlmRequest r) => r.messages)
        .map((LlmMessage m) => m.content)
        .join('\n');
    expect(wakeMessages, contains('[terminal hook]'));
    expect(wakeMessages, contains('hook-ok'));

    // 落库：用户消息 → hook 工具卡片 → 首轮文本 → 完成提示 → 唤醒轮文本
    final List<CoreMessage> stored = server.store.messages(
      agentId,
      TreeStore.defaultSessionId,
    );
    final List<String> kinds = stored.map((CoreMessage m) => m.kind).toList();
    expect(kinds.first, 'text');
    expect(kinds, contains('tool'));
    expect(
      stored.map((CoreMessage m) => m.content).join('\n'),
      contains('[terminal hook]'),
    );
    expect(
      stored.map((CoreMessage m) => m.content).join('\n'),
      contains('收到后台完成提示'),
      reason: '唤醒轮确实生成了新回复',
    );

    // 日志文件落在工作空间内，含命令输出与结束标记
    final Directory output = Directory(p.join(workspace.path, '.output'));
    expect(output.existsSync(), isTrue);
    final List<File> logs = output
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.log'))
        .toList();
    expect(logs, hasLength(1));
    final String log = logs.single.readAsStringSync();
    expect(log, contains('hook-ok'));
    expect(log, contains('结束：退出码 0'));
  });

  test('hook_action=status 能读到任务状态与日志尾部（模型可自查进度）', () async {
    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': '跑一下',
      'session_id': TreeStore.defaultSessionId,
    });
    await waitIdle(ws);
    expect(tools.hooks.tasks, hasLength(1));
    final HookTask task = tools.hooks.tasks.single;
    expect(task.agentId, agentId);
    expect(task.sessionId, TreeStore.defaultSessionId);
    // 首轮生成可能比"进程启动 + echo"更快结束，这里等任务真正收尾
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
    while (task.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(task.running, isFalse, reason: 'echo 很快结束');
    expect(tools.hooks.renderStatus(task), contains('hook-ok'));
  });
}
