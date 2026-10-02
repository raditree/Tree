import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'fake_transport.dart';
import 'ws_harness.dart';

/// **前缀稳定性**回归：下一轮重建出来的历史，必须与上一轮**真正发出去的那份**
/// 逐字一致——否则端点前缀缓存只能命中 system 提示词，长会话的缓存全丢。
void main() {
  late Directory dataDir;
  late Directory workspace;
  late CoreServer server;
  late CoreSettings settings;
  late String agentId;
  late FakeTransport transport;
  final List<String> logs = <String>[];

  Future<void> start({
    required List<List<LlmStreamEvent>> script,
    bool withStatusText = false,
  }) async {
    transport = FakeTransport(script);
    settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'max_seqlen': 128000,
      'thinking': true,
      // 固定 token_scale / 水位线：门控阈值不随"学习"漂移，用例才是确定性的
      'token_scale': 2.0,
      'longest_session_tokens': 999999999,
    });
    final WorkspaceToolRunner tools = WorkspaceToolRunner(
      resolveWorkspaceDir: (String id) {
        final String configured = server.store.agent(id)?.workspaceDir ?? '';
        return configured.isNotEmpty ? configured : workspace.path;
      },
    );
    server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      settings: settings,
      engine: LlmAgentEngine(
        resolveModel: settings.model,
        toolRunner: tools,
        transportFactory: (CoreModelConfig config) => transport,
        sessionStatusText: withStatusText
            ? (String a, String s) => sessionStatusText(
                todos: const <TodoItem>[],
                selectedSpecIds: const <String>[],
              )
            : null,
        log: (String m) => logs.add(m),
      ),
    );
    final CoreAgent agent = server.store.createAgent(
      name: '前缀用例',
      systemPrompt: '你是助手',
      modelId: 'demo',
    );
    agentId = agent.id;
  }

  setUp(() {
    logs.clear();
    dataDir = Directory.systemTemp.createTempSync('tree_prefix_');
    workspace = Directory(p.join(dataDir.path, 'workspace'))
      ..createSync(recursive: true);
    File(p.join(workspace.path, 'notes', 'hello.txt'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('file body');
  });

  tearDown(() async {
    await server.close();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  /// 发一条消息并等到该轮生成结束（agent_status 计数按轮递增）。
  Future<void> sendTurn(TestWs ws, String content, int statusCount) async {
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': content,
      'session_id': TreeStore.defaultSessionId,
    });
    await ws.untilCount('agent_status', statusCount);
  }

  /// 打印两条请求的第一处分歧（用于诊断）。
  String firstDiff(List<LlmMessage> a, List<LlmMessage> b) {
    final int n = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < n; i++) {
      final String la = jsonEncode(a[i].toWire());
      final String lb = jsonEncode(b[i].toWire());
      if (la != lb) {
        final String head = la.length > 400 ? la.substring(0, 400) : la;
        final String tail = lb.length > 400 ? lb.substring(0, 400) : lb;
        return '第 $i 条不同:\n  上一轮实发: $head\n  本轮重建  : $tail';
      }
    }
    return '前 $n 条逐字一致（a=${a.length} / b=${b.length}）';
  }

  test('新消息重建的历史与上一轮实发请求逐字一致（含工具调用参数/思考）', () async {
    await start(
      script: <List<LlmStreamEvent>>[
        <LlmStreamEvent>[
          const LlmThinkingDelta('先看一眼文件。'),
          ...toolCallScript(
            name: 'read',
            // 模型原始参数串：带空格，非 jsonEncode 的规范形态
            arguments: '{"file_path": "notes/hello.txt", "start_line": 1}',
          ),
        ],
        textScript('读到了'),
        textScript('第二轮回答'),
      ],
      withStatusText: true,
    );
    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);

    await sendTurn(ws, '看文件', 2);
    await sendTurn(ws, '再来一条', 4);

    expect(transport.requests.length, 3, reason: '两轮各一次 + 第一轮工具循环一次');
    final List<LlmMessage> firstRunLastHop = transport.requests[1].messages;
    final List<LlmMessage> secondRunFirstHop = transport.requests[2].messages;
    expect(
      secondRunFirstHop.length,
      greaterThan(firstRunLastHop.length),
      reason: '第二轮请求应当把上一轮那份原样接在后面',
    );
    final String diff = firstDiff(firstRunLastHop, secondRunFirstHop);
    expect(diff, startsWith('前 '), reason: '重建的历史必须与上一轮实发逐字一致，\n$diff');
  });

  test('超长工具结果：下一轮重建不再写第二份文件，提示里的路径逐字不变', () async {
    final String big = 'x' * 20000;
    File(p.join(workspace.path, 'big.txt')).writeAsStringSync(big);
    await start(
      script: <List<LlmStreamEvent>>[
        toolCallScript(name: 'read', arguments: '{"file_path":"big.txt"}'),
        textScript('读完了'),
        textScript('第二轮回答'),
      ],
    );
    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);

    await sendTurn(ws, '看大文件', 2);
    // 跨一秒：修复前"时间戳命名"会写成第二份文件（这正是要钉住的行为）
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await sendTurn(ws, '再来一条', 4);

    // 模型口径仍写 `.self/results`，磁盘上按 agent 分栏：`.tree/<agent_id>/.self/results`。
    final Directory results = Directory(
      p.join(workspace.path, '.tree', agentId, '.self', 'results'),
    );
    final int files = results.existsSync() ? results.listSync().length : 0;
    expect(files, 1, reason: '同一个工具结果只应重定向一次（现在是每次 run 一份新文件）');

    final List<LlmMessage> firstRunLastHop = transport.requests[1].messages;
    final List<LlmMessage> secondRunFirstHop = transport.requests[2].messages;
    final String diff = firstDiff(firstRunLastHop, secondRunFirstHop);
    expect(diff, startsWith('前 '), reason: '重建的历史必须与上一轮实发逐字一致，\n$diff');
  });
}