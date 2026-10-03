import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// **逐调用用量**：每一次 LLM 调用一条账（本任务 ③ 的验收核心）。
///
/// 覆盖两个层次：
/// - `LlmSession`（工具循环）：**每一跳**都产出一次 [AgentUsage]——包括"带工具调用
///   + 端点不回 usage"的跳（旧实现里这一跳**一条都没有**，而它恰恰是最常见的形态）；
/// - `LlmAgentEngine`：把逐调用读数落进 `<会话目录>/usage.jsonl`（`source=turn`），
///   同时保证**上行的 usage map 逐字不变**（内部键被剥掉）。
void main() {
  LlmSession session(FakeTransport transport, {ToolRunner? tools}) => LlmSession(
    transport: transport,
    model: 'demo',
    toolRunner: tools ?? const EmptyToolRunner(),
    maxSeqlen: 128000,
  );

  const List<ToolSpec> readTool = <ToolSpec>[
    ToolSpec(name: 'read_file', description: '读文件'),
  ];

  List<AgentUsage> usagesOf(List<AgentEvent> events) =>
      events.whereType<AgentUsage>().toList();

  group('每一跳都有账（LlmSession 工具循环）', () {
    test('带工具调用 + 端点不回 usage：两跳各一条（以前整跳丢账）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(
          name: 'read_file',
          arguments: '{"path":"a.txt"}',
          withUsage: false,
        ),
        textScript('收工', withUsage: false),
      ]);
      final List<AgentEvent> events = await session(
        transport,
        tools: FakeToolRunner(specs: readTool),
      ).run(
        messages: <LlmMessage>[const LlmMessage.user('读一下')],
        agentId: 'a',
        sessionId: 's',
        isCancelled: () => false,
      ).toList();

      final List<AgentUsage> usages = usagesOf(events);
      expect(
        usages,
        hasLength(2),
        reason: '工具跳与最终跳是两次 API 调用，必须各有一条（旧实现工具跳一条都没有）',
      );
      for (final AgentUsage usage in usages) {
        expect(usage.usage['estimated'], isTrue, reason: '端点没给 usage ⇒ 本地估算');
        expect(usage.usage['prompt_tokens'], greaterThan(0));
        expect(usage.usage['completion_tokens'], greaterThan(0));
      }
      // 第二跳的输入变长（多了一段工具轨迹）⇒ 逐调用的 prompt 是"这一跳"的口径
      expect(
        usages.last.usage['prompt_tokens'],
        greaterThan(usages.first.usage['prompt_tokens'] as int),
      );
      expect(transport.turnsUsed, 2);
    });

    test('端点给 usage 的跳用真值、不给的跳用估算（逐调用读数按"本次调用"计）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        // 第 1 跳：端点给真值（50 prompt / 5 completion）
        toolCallScript(name: 'read_file', arguments: '{}'),
        // 第 2 跳：端点安静
        textScript('收工', withUsage: false),
      ]);
      final List<AgentEvent> events = await session(
        transport,
        tools: FakeToolRunner(specs: readTool),
      ).run(
        messages: <LlmMessage>[const LlmMessage.user('读一下')],
        agentId: 'a',
        sessionId: 's',
        isCancelled: () => false,
      ).toList();

      final List<AgentUsage> usages = usagesOf(events);
      expect(usages, hasLength(2));
      expect(usages.first.usage.containsKey('estimated'), isFalse);

      // 逐调用读数（内部键）：第 1 跳是**这一次调用**的真值，不是"全轮累计"
      final Map<String, dynamic> firstCall =
          usages.first.usage[LlmSession.callUsageKey] as Map<String, dynamic>;
      expect(firstCall['prompt_tokens'], 50);
      expect(firstCall['completion_tokens'], 5);
      expect(firstCall['estimated'], isFalse);
      expect(firstCall['duration_ms'], isA<int>());

      // 第 2 跳：估算口径
      final Map<String, dynamic> secondCall =
          usages.last.usage[LlmSession.callUsageKey] as Map<String, dynamic>;
      expect(secondCall['estimated'], isTrue);
      expect(secondCall['prompt_tokens'], greaterThan(0));
      expect(secondCall['completion_tokens'], greaterThan(0));

      // 公开口径不变：只有"逐调用读数"是新增的（内部键），其余字段与旧契约一致
      expect(usages.first.usage['prompt_tokens'], 50);
      expect(usages.first.usage['completion_tokens'], 5);
      expect(usages.first.usage['total_tokens'], 55);
      // 公开的 completion 仍是**全轮累计**口径（这一跳没真值 ⇒ 真值累计 + 本跳估算）
      expect(usages.last.usage['completion_tokens'], greaterThan(5));
    });

    test('端点不给 usage 且**没有**工具调用：最终跳仍然只发一条（不重复）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('你好', withUsage: false),
      ]);
      final List<AgentEvent> events = await session(transport).run(
        messages: <LlmMessage>[const LlmMessage.user('hi')],
        agentId: 'a',
        sessionId: 's',
        isCancelled: () => false,
      ).toList();
      expect(usagesOf(events), hasLength(1));
      expect(events.last, isA<AgentDone>());
    });

    test('失败的跳不产账（只有真正跑完的调用才记账）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[
          const LlmFailureEvent('invalid api key', statusCode: 401),
        ],
      ]);
      final List<AgentEvent> events = await session(transport).run(
        messages: <LlmMessage>[const LlmMessage.user('x')],
        agentId: 'a',
        sessionId: 's',
        isCancelled: () => false,
      ).toList();
      expect(usagesOf(events), isEmpty);
      expect(events.whereType<AgentError>(), hasLength(1));
    });
  });

  group('引擎把逐调用账落进 usage.jsonl（source=turn）', () {
    late Directory root;
    late TreePaths paths;
    late UsageLog usageLog;

    setUp(() {
      root = Directory.systemTemp.createTempSync('tree_usage_per_call_');
      paths = TreePaths(root.path);
      usageLog = UsageLog(paths);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    CoreModelConfig model() => CoreModelConfig(
      modelId: 'demo',
      name: '演示',
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'sk-test',
      maxSeqlen: 64000,
    );

    AgentRunContext context() => AgentRunContext(
      agentId: 'agt_1',
      sessionId: 'ses_1',
      modelId: 'demo',
      systemPrompt: '你是助手',
      userContent: '读一下 a.txt',
      history: const <CoreMessageRef>[
        CoreMessageRef(role: 'user', content: '读一下 a.txt'),
      ],
    );

    List<Map<String, dynamic>> readLines() {
      final File file = File(paths.usageFile('agt_1', 'ses_1'));
      expect(file.existsSync(), isTrue, reason: 'usage.jsonl 必须落在会话目录');
      return <Map<String, dynamic>>[
        for (final String line in const LineSplitter().convert(
          file.readAsStringSync(),
        ))
          if (line.trim().isNotEmpty)
            jsonDecode(line) as Map<String, dynamic>,
      ];
    }

    test('两跳两条行；字段表齐全；上行 usage 无内部键', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(
          name: 'read_file',
          arguments: '{"path":"a.txt"}',
          withUsage: false,
        ),
        textScript('文件内容是 hello', withUsage: false),
      ]);
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => id == 'demo' ? model() : null,
        toolRunner: FakeToolRunner(specs: readTool, result: '工具结果'),
        transportFactory: (CoreModelConfig c) => transport,
        usageLog: usageLog,
      );

      final List<AgentEvent> events = await engine
          .run(context(), isCancelled: () => false)
          .toList();
      await usageLog.flush();

      // 上行契约：内部键必须被剥掉（前端帧 / messages.jsonl 的 usage 逐字不变）
      for (final AgentUsage usage in usagesOf(events)) {
        expect(
          usage.usage.containsKey(LlmSession.callUsageKey),
          isFalse,
          reason: '逐调用读数是内部键，不许上行',
        );
        expect(usage.usage.containsKey(LlmSession.contextCharsKey), isFalse);
      }

      final List<Map<String, dynamic>> lines = readLines();
      expect(lines, hasLength(2), reason: '一次调用一行');
      for (final Map<String, dynamic> line in lines) {
        expect(line.keys.toSet(), <String>{
          'at',
          'source',
          'model',
          'prompt_tokens',
          'cached_tokens',
          'completion_tokens',
          'estimated',
          'duration_ms',
        }, reason: '字段表就是对外契约（插件面板按它消费）');
        expect(line['source'], 'turn');
        expect(line['model'], 'demo');
        expect(line['estimated'], isTrue);
        expect(line['prompt_tokens'], isA<int>());
        expect(line['prompt_tokens'], greaterThan(0));
        expect(line['duration_ms'], isA<int>());
        expect(DateTime.tryParse(line['at'] as String), isNotNull);
      }
      expect(
        lines.last['cached_tokens'],
        isNull,
        reason: '端点没给这个字段 ⇒ 留空，绝不编造 0',
      );
      expect(
        lines.last['prompt_tokens'],
        greaterThan(lines.first['prompt_tokens'] as int),
        reason: '第二跳带着工具轨迹，输入更长',
      );
    });

    test('端点给 usage 的跳记真值（逐调用，不是全轮累计）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'read_file', arguments: '{}'),
        textScript('收工', withUsage: false),
      ]);
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => id == 'demo' ? model() : null,
        toolRunner: FakeToolRunner(specs: readTool),
        transportFactory: (CoreModelConfig c) => transport,
        usageLog: usageLog,
      );
      await engine.run(context(), isCancelled: () => false).toList();
      await usageLog.flush();

      final List<Map<String, dynamic>> lines = readLines();
      expect(lines, hasLength(2));
      expect(lines.first['estimated'], isFalse);
      expect(lines.first['prompt_tokens'], 50);
      expect(
        lines.first['completion_tokens'],
        5,
        reason: '逐调用口径：这一跳就是 5，而不是全轮累计',
      );
      expect(lines.last['estimated'], isTrue);
    });

    test('没接 UsageLog 时引擎照常跑（不落账、不报错）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('你好'),
      ]);
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => id == 'demo' ? model() : null,
        transportFactory: (CoreModelConfig c) => transport,
      );
      final List<AgentEvent> events = await engine
          .run(context(), isCancelled: () => false)
          .toList();
      expect(events.last, isA<AgentDone>());
      expect(
        File(paths.usageFile('agt_1', 'ses_1')).existsSync(),
        isFalse,
        reason: '未接线就不该凭空创建账本文件',
      );
    });
  });
}
