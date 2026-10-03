import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// **接线后真能落账**：按生产装配方式（`packages/tree_core_cli/bin/tree_core.dart`）
/// 把 `UsageLog` 接到四个落账口上，断言 `usage.jsonl` 里真的出现对应的行。
///
/// 这一份测的是"**接上就生效**"，不是机制本身（机制在
/// `llm_usage_per_call_test.dart` / `llm_usage_sink_test.dart` / `usage_log_test.dart`）：
/// - 对话跳：`LlmAgentEngine(usageLog:)`（CLI 那行）
/// - 插件接管跳：引擎从会话读数里认出 `plugin` ⇒ `source=plugin`
/// - 内置压缩：`CompactionService.usageLog = …`（CLI 那行）→ 按会话绑定 sink 交给总结器
/// - 执行站 `llm.call`：`CoreServer` 那行的等价写法 `usageLog.sinkFor(sessionId)`
void main() {
  late Directory root;
  late TreePaths paths;
  late UsageLog usageLog;

  const String agentId = 'agt_1';
  const String sessionId = 'ses_1';

  setUp(() {
    root = Directory.systemTemp.createTempSync('tree_usage_wiring_');
    paths = TreePaths(root.path);
    usageLog = UsageLog(paths);
  });

  tearDown(() {
    // 临时目录清理尽力而为：Windows 上偶发"另一个程序正在使用此文件"
    // （杀毒/索引器占着句柄），不能让它把测试判成失败。
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } on FileSystemException {
      // 忽略：临时目录残留不影响断言
    }
  });

  CoreModelConfig model() => CoreModelConfig(
    modelId: 'demo',
    name: '演示',
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'sk-test',
    maxSeqlen: 64000,
  );

  /// 从盘上重读账本（＝"换个进程再看"的视角）。
  Future<List<Map<String, dynamic>>> rowsOf([
    String session = sessionId,
    String agent = agentId,
  ]) async {
    final UsageHistory history = await UsageLog.read(paths, agent, session);
    return <Map<String, dynamic>>[
      for (final UsageCall call in history.calls) call.toJson(),
    ];
  }

  AgentRunContext context() => AgentRunContext(
    agentId: agentId,
    sessionId: sessionId,
    modelId: 'demo',
    systemPrompt: '你是助手',
    userContent: '读一下 a.txt',
    history: const <CoreMessageRef>[
      CoreMessageRef(role: 'user', content: '读一下 a.txt'),
    ],
  );

  const List<ToolSpec> readTool = <ToolSpec>[
    ToolSpec(name: 'read_file', description: '读文件'),
  ];

  group('对话跳：LlmAgentEngine(usageLog:)', () {
    test('装配后每一跳一行；flush 之后仍在（关停路径）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'read_file', arguments: '{"path":"a.txt"}'),
        textScript('收工', withUsage: false),
      ]);
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => id == 'demo' ? model() : null,
        toolRunner: FakeToolRunner(specs: readTool, result: '工具结果'),
        transportFactory: (CoreModelConfig c) => transport,
        usageLog: usageLog, // ← CLI 那一行
      );

      await engine.run(context(), isCancelled: () => false).toList();
      await usageLog.flush(); // ← 关停那一行

      final List<Map<String, dynamic>> rows = await rowsOf();
      expect(rows, hasLength(2), reason: '工具跳 + 最终跳');
      expect(rows.map((Map<String, dynamic> r) => r['source']), <String>[
        'turn',
        'turn',
      ]);
      expect(rows.first['model'], 'demo');
      expect(rows.first['estimated'], isFalse, reason: '端点给了 usage');
      expect(rows.last['estimated'], isTrue, reason: '端点安静的那一跳用估算');
      for (final Map<String, dynamic> row in rows) {
        expect(row.keys.toSet(), <String>{
          'at',
          'source',
          'model',
          'prompt_tokens',
          'cached_tokens',
          'completion_tokens',
          'estimated',
          'duration_ms',
        });
      }
      expect(
        File(paths.usageFile(agentId, sessionId)).readAsStringSync().trim(),
        isNotEmpty,
        reason: 'flush 之后文件里必须有内容（硬杀才可能丢尾行）',
      );
    });
  });

  group('插件接管跳：source=plugin（插件回包带 / 不带 usage）', () {
    LlmAgentEngine engineWithHandler(
      LlmTurnHandler handler,
      FakeTransport transport,
    ) {
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => id == 'demo' ? model() : null,
        transportFactory: (CoreModelConfig c) => transport,
        usageLog: usageLog,
      );
      engine.llmTurnHandler = handler;
      return engine;
    }

    test('插件回包带 usage ⇒ 记真值，source=plugin、estimated=false', () async {
      final LlmAgentEngine engine = engineWithHandler(
        ({
          required LlmRequest request,
          required String agentId,
          required String sessionId,
          required int turn,
          required bool Function() isCancelled,
        }) async => Stream<LlmStreamEvent>.fromIterable(
          const <LlmStreamEvent>[
            LlmTextDelta('插件接管正文'),
            LlmUsageEvent(
              LlmUsage(
                promptTokens: 777,
                completionTokens: 88,
                totalTokens: 865,
                cachedTokens: 512,
              ),
            ),
            LlmFinishEvent('stop'),
          ],
        ),
        FakeTransport(<List<LlmStreamEvent>>[]),
      );

      await engine.run(context(), isCancelled: () => false).toList();
      await usageLog.flush();

      final List<Map<String, dynamic>> rows = await rowsOf();
      expect(rows, hasLength(1));
      expect(rows.single['source'], 'plugin');
      expect(rows.single['estimated'], isFalse);
      expect(rows.single['prompt_tokens'], 777);
      expect(rows.single['cached_tokens'], 512);
      expect(rows.single['completion_tokens'], 88);
    });

    test('插件不回 usage ⇒ 估算记一笔，source=plugin、estimated=true', () async {
      final LlmAgentEngine engine = engineWithHandler(
        ({
          required LlmRequest request,
          required String agentId,
          required String sessionId,
          required int turn,
          required bool Function() isCancelled,
        }) async => Stream<LlmStreamEvent>.fromIterable(
          const <LlmStreamEvent>[
            LlmTextDelta('插件接管正文'),
            LlmFinishEvent('stop'),
          ],
        ),
        FakeTransport(<List<LlmStreamEvent>>[]),
      );

      await engine.run(context(), isCancelled: () => false).toList();
      await usageLog.flush();

      final List<Map<String, dynamic>> rows = await rowsOf();
      expect(rows, hasLength(1), reason: '接管跳也必须有一条账');
      expect(rows.single['source'], 'plugin');
      expect(rows.single['estimated'], isTrue);
      expect(rows.single['prompt_tokens'], greaterThan(0));
      expect(rows.single['completion_tokens'], greaterThan(0));
      expect(rows.single['cached_tokens'], isNull);
    });
  });

  group('内置压缩：CompactionService.usageLog', () {
    late FileTreeStore store;
    late CoreAgent agent;
    late CoreSession session;
    late CoreSettings settings;
    int clock = 0;

    setUp(() {
      store = FileTreeStore(paths);
      agent = store.createAgent(name: '压缩用例', modelId: 'demo');
      agent.systemPrompt = '你是助手';
      store.putAgent(agent);
      settings = CoreSettings()..putModel(model());
      session = store.ensureDefaultSession(agent.id);
      for (int i = 0; i < 3; i++) {
        for (final String role in <String>['user', 'agent']) {
          store.appendMessage(
            CoreMessage(
              id: CoreIds.next('m'),
              agentId: agent.id,
              sessionId: session.sessionId,
              role: role,
              content: role == 'user' ? '需求$i' : '回答$i',
              timestamp: ++clock,
            ),
          );
        }
      }
      agent.compressThreshold = 0.5;
      agent.modelId = 'demo';
      store.putAgent(agent);
    });

    CompactionService service(FakeTransport transport) {
      final CompactionService built = CompactionService(
        store: store,
        settings: settings,
        summarizer: LlmSummarizer(
          resolveModel: (String id) => id == 'demo' ? model() : null,
          transportFactory: (CoreModelConfig c) => transport,
        ),
        keepRecentUserMessages: 2,
        keepTailLength: 2,
        minSummarizeMessages: 4,
      );
      built.usageLog = usageLog; // ← CLI 那一行
      return built;
    }

    test('压缩落 source=compact 一行（端点给 usage ⇒ 真值）', () async {
      final CompactionService compaction = service(
        FakeTransport(<List<LlmStreamEvent>>[textScript('要点一；要点二')]),
      );

      final CompactionResult result = await compaction.compact(
        agent.id,
        session.sessionId,
      );
      expect(result.compressed, isTrue, reason: '前置条件：这次压缩真的发生了');
      await usageLog.flush();

      final List<Map<String, dynamic>> rows = await rowsOf(
        session.sessionId,
        agent.id,
      );
      expect(rows, hasLength(1));
      expect(rows.single['source'], 'compact');
      expect(rows.single['model'], 'demo');
      expect(rows.single['estimated'], isFalse);
      expect(rows.single['prompt_tokens'], greaterThan(0));
    });

    test('端点不回 usage ⇒ 仍有一行且标 estimated', () async {
      final CompactionService compaction = service(
        FakeTransport(<List<LlmStreamEvent>>[
          textScript('要点一', withUsage: false),
        ]),
      );

      final CompactionResult result = await compaction.compact(
        agent.id,
        session.sessionId,
      );
      expect(result.compressed, isTrue);
      await usageLog.flush();

      final List<Map<String, dynamic>> rows = await rowsOf(
        session.sessionId,
        agent.id,
      );
      expect(rows, hasLength(1));
      expect(rows.single['source'], 'compact');
      expect(rows.single['estimated'], isTrue);
      expect(rows.single['cached_tokens'], isNull);
    });

    test('不同会话的压缩各记各的（按次绑定 sink，不串账）', () async {
      final CoreSession other = store.createSession(agent.id, title: '另一个')!;
      for (int i = 0; i < 3; i++) {
        for (final String role in <String>['user', 'agent']) {
          store.appendMessage(
            CoreMessage(
              id: CoreIds.next('m'),
              agentId: agent.id,
              sessionId: other.sessionId,
              role: role,
              content: role == 'user' ? '别的需求$i' : '别的回答$i',
              timestamp: ++clock,
            ),
          );
        }
      }
      final CompactionService compaction = service(
        FakeTransport(<List<LlmStreamEvent>>[textScript('要点')]),
      );

      await compaction.compact(agent.id, session.sessionId);
      await compaction.compact(agent.id, other.sessionId);
      await usageLog.flush();

      expect(await rowsOf(session.sessionId, agent.id), hasLength(1));
      expect(await rowsOf(other.sessionId, agent.id), hasLength(1));
    });
  });

  group('执行站 llm.call：按次绑定 sink', () {
    test('按 CoreServer 的写法绑定会话 ⇒ 落 source=llm.call 一行', () async {
      final LlmJsonCaller caller = LlmJsonCaller(
        resolveModel: (String id) => id == 'demo' ? model() : null,
        transportFactory: (CoreModelConfig c) => FakeTransport(
          <List<LlmStreamEvent>>[
            <LlmStreamEvent>[
              const LlmTextDelta('{"ok":true}'),
              const LlmUsageEvent(
                LlmUsage(
                  promptTokens: 321,
                  completionTokens: 45,
                  totalTokens: 366,
                ),
              ),
              const LlmFinishEvent('stop'),
            ],
          ],
        ),
      );

      final Map<String, dynamic> reply = await caller.call(
        agentId: agentId,
        modelId: 'demo',
        prompt: '帮我压缩',
        // ← CoreServer._stationLlmCall 里那一行（按次绑定，避免并发串账）
        usageSink: usageLog.sinkFor(sessionId),
      );
      expect(reply['ok'], isTrue);
      await usageLog.flush();

      final List<Map<String, dynamic>> rows = await rowsOf();
      expect(rows, hasLength(1));
      expect(rows.single['source'], 'llm.call');
      expect(rows.single['prompt_tokens'], 321);
      expect(rows.single['completion_tokens'], 45);
      expect(rows.single['estimated'], isFalse);
    });

    test('没绑 sink 时不落账（证明那一行是真的接线）', () async {
      final LlmJsonCaller caller = LlmJsonCaller(
        resolveModel: (String id) => id == 'demo' ? model() : null,
        transportFactory: (CoreModelConfig c) => FakeTransport(
          <List<LlmStreamEvent>>[textScript('{"ok":true}')],
        ),
      );
      await caller.call(agentId: agentId, modelId: 'demo', prompt: 'x');
      await usageLog.flush();
      expect(File(paths.usageFile(agentId, sessionId)).existsSync(), isFalse);
    });
  });
}

/// 让 IDE/分析器知道这里用到了 jsonEncode（账本行本身是 JSON，排障时手工看）。
// ignore: unused_element
String _rowPreview(Map<String, dynamic> row) => jsonEncode(row);
