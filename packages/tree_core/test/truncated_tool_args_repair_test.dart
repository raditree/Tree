import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// max_tokens 截断的半截 tool_call arguments 的**自动修复**（用户 2026-10-15：
/// 「补全工具调用字段（截断未生成部分用特殊标记），发回继续生成」）。
///
/// 三层防线各钉一组：修复函数本体（llm_types）、会话组装处修复 + 续写指引
/// （llm_session）、回灌把关处 sanitize（llm_agent_engine，救存量中毒会话）。
void main() {
  group('修复函数', () {
    test('本来合法的 JSON → null（无需修，一个字节都不许动）', () {
      expect(
        repairTruncatedToolArguments('{"a":1,"b":[2,3]}'),
        isNull,
      );
    });

    test('截断在字符串内：补 marker、闭引号、闭花括号', () {
      const String raw = '{"path":"a.md","content":"# 标题\\n正文写到一';
      final String? fixed = repairTruncatedToolArguments(raw);
      expect(fixed, isNotNull);
      expect(isValidToolArguments(fixed!), isTrue);
      expect(fixed, contains(kToolArgsTruncatedMarker));
      // 前半段逐字保留（续写的前提）
      expect(fixed, contains('# 标题'));
      expect(fixed, contains('正文写到一'));
    });

    test('截断在悬 key 名：回退到上一个串外逗号', () {
      const String raw = '{"a":1,"b":"two","cu';
      final String? fixed = repairTruncatedToolArguments(raw);
      expect(fixed, isNotNull);
      expect(fixed, '{"a":1,"b":"two"}');
    });

    test('悬反斜杠不吃掉补的闭引号', () {
      const String raw = '{"c":"abc\\';
      final String? fixed = repairTruncatedToolArguments(raw);
      expect(fixed, isNotNull);
      expect(isValidToolArguments(fixed!), isTrue);
    });

    test('嵌套结构：补齐 ] 和 }', () {
      const String raw = '{"a":[{"b":"x';
      final String? fixed = repairTruncatedToolArguments(raw);
      expect(fixed, isNotNull);
      expect(isValidToolArguments(fixed!), isTrue);
      expect(fixed, endsWith('"}]}'));
    });

    test('数组元素里整项已写完：不消费 marker，原样收拢', () {
      const String raw = '["a","b"';
      final String? fixed = repairTruncatedToolArguments(raw);
      expect(fixed, '["a","b"]');
    });

    test('完全救不了的串 → null（调用方负责包壳）', () {
      expect(repairTruncatedToolArguments('not json at all'), isNull);
    });

    test('空串 → null', () {
      expect(repairTruncatedToolArguments(''), isNull);
    });

    test('真机现场还原：500 报错里那段半截 markdown 正文能被修复', () {
      // 复刻 llama.cpp parse_error.101 报回来的那段（missing closing quote）
      final String raw =
          '{"path":"design.md","content":"### 3.2 热重启的两个层次\\n'
          '层次 A：插件热重启（进程级）——现有 applyConfigs/restart';
      final String? fixed = repairTruncatedToolArguments(raw);
      expect(fixed, isNotNull);
      expect(isValidToolArguments(fixed!), isTrue);
      expect(fixed, contains(kToolArgsTruncatedMarker));
    });
  });

  group('会话组装处：截断跳修复后照常执行 + 续写指引', () {
    const String partial =
        '{"content":"# 设计文档\\n第一段写完了。第二段刚刚写到一半被';

    test('finish_reason=length 的半截参数：落库与回灌的都是合法 JSON + 指引进了下一跳', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(
          name: 'write',
          arguments: partial,
          finishReason: 'length',
        ),
        textScript('继续写完了剩下的部分'),
      ]);
      final FakeToolRunner tools = FakeToolRunner(result: '写入成功');
      final LlmSession session = LlmSession(
        transport: transport,
        model: 'demo',
        toolRunner: tools,
        maxSeqlen: 128000,
      );
      final List<AgentEvent> run = await session
          .run(
            messages: <LlmMessage>[const LlmMessage.user('写设计文档')],
            agentId: 'a',
            sessionId: 's',
            isCancelled: () => false,
          )
          .toList();

      // 1. 工具照常执行，参数已是合法 JSON（前半段保真 + marker 当"洞"）
      final AgentToolStart start = run.whereType<AgentToolStart>().single;
      expect(isValidToolArguments(start.rawArguments), isTrue);
      expect(start.rawArguments, contains(kToolArgsTruncatedMarker));
      expect(start.arguments['content'], contains('第一段写完了'));
      // marker 只出现在参数里一次（回灌那份不能二次补洞）
      expect(
        kToolArgsTruncatedMarker.allMatches(start.rawArguments).length,
        1,
      );

      // 2. 续写指引进的是"送模型那一份"（AgentToolEnd.modelContent），
      //    不进 UI 结果口径
      final AgentToolEnd end = run.whereType<AgentToolEnd>().single;
      expect(end.result, '写入成功');
      expect(end.modelContent, contains('写入成功'));
      expect(end.modelContent, contains('从标记处继续'));
      expect(end.modelContent, contains('不要重复思考'));

      // 3. 下一跳请求：assistant 的 arguments 与落库一致；tool 结果带指引；
      //    半截串已经不存在——端点渲染历史不会再 500
      final LlmRequest second = transport.requests[1];
      final LlmMessage assistant = second.messages.firstWhere(
        (LlmMessage m) => m.toolCalls.isNotEmpty,
      );
      expect(assistant.toolCalls.single.arguments, start.rawArguments);
      final LlmMessage toolResult = second.messages.firstWhere(
        (LlmMessage m) => m.isToolResult,
      );
      expect(toolResult.content, contains('从标记处继续'));
    });

    test('修不出来的串：包壳成合法 JSON（会话绝不带着半截串落库）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(
          name: 'write',
          arguments: 'not json at all',
          finishReason: 'length',
        ),
        textScript('重来了'),
      ]);
      final LlmSession session = LlmSession(
        transport: transport,
        model: 'demo',
        toolRunner: FakeToolRunner(result: 'r'),
        maxSeqlen: 128000,
      );
      await session
          .run(
            messages: <LlmMessage>[const LlmMessage.user('x')],
            agentId: 'a',
            sessionId: 's',
            isCancelled: () => false,
          )
          .toList();
      final LlmMessage assistant = transport.requests[1].messages.firstWhere(
        (LlmMessage m) => m.toolCalls.isNotEmpty,
      );
      final String args = assistant.toolCalls.single.arguments;
      expect(isValidToolArguments(args), isTrue);
      expect(args, contains('truncated_arguments'));
      expect(args, contains('not json at all'));
    });

    test('正常完成（finish_reason=tool_calls）的合法参数：零改动放行', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'read_file', arguments: '{"path":"a.txt"}'),
        textScript('好了'),
      ]);
      final LlmSession session = LlmSession(
        transport: transport,
        model: 'demo',
        toolRunner: FakeToolRunner(result: '内容'),
        maxSeqlen: 128000,
      );
      await session
          .run(
            messages: <LlmMessage>[const LlmMessage.user('读')],
            agentId: 'a',
            sessionId: 's',
            isCancelled: () => false,
          )
          .toList();
      // 零改动：回灌给端点的参数串与模型原文逐字相同
      final LlmMessage assistant = transport.requests[1].messages.firstWhere(
        (LlmMessage m) => m.toolCalls.isNotEmpty,
      );
      expect(assistant.toolCalls.single.arguments, '{"path":"a.txt"}');
      expect(
        assistant.toolCalls.single.arguments,
        isNot(contains(kToolArgsTruncatedMarker)),
      );
    });
  });

  group('回灌把关处：中毒历史进请求前被修复（救存量会话）', () {
    List<CoreMessageRef> poisonedHistory({String raw = '{"content":"写到一半被'}) {
      return <CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '写文档'),
        CoreMessageRef(
          role: 'agent',
          content: '',
          kind: 'tool',
          toolName: 'write',
          toolCallId: 'call_9',
          toolArgumentsRaw: raw,
          toolResult: '已写入',
          toolResultForModel: '已写入',
        ),
        const CoreMessageRef(role: 'user', content: '继续'),
      ];
    }

    LlmAgentEngine engine(FakeTransport transport, void Function(String)? log) =>
        LlmAgentEngine(
          resolveModel: (String id) => CoreModelConfig(
            modelId: 'demo',
            name: '演示',
            baseUrl: 'https://api.example.com/v1',
            apiKey: 'sk-test',
            maxSeqlen: 64000,
            maxOutputTokens: 512,
          ),
          toolRunner: const EmptyToolRunner(),
          transportFactory: (CoreModelConfig c) => transport,
          log: log,
        );

    Future<LlmMessage> assistantWithCalls(FakeTransport transport) async =>
        transport.requests.single.messages.firstWhere(
          (LlmMessage m) => m.toolCalls.isNotEmpty,
        );

    test('半截 rawArguments：修复成合法 JSON + marker，并留日志', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('续写完成'),
      ]);
      final List<String> logs = <String>[];
      await engine(transport, logs.add)
          .run(
            AgentRunContext(
              agentId: 'a',
              sessionId: 's',
              modelId: 'demo',
              systemPrompt: 'sys',
              userContent: '继续',
              history: poisonedHistory(),
            ),
            isCancelled: () => false,
          )
          .toList();
      final LlmMessage assistant = await assistantWithCalls(transport);
      final String args = assistant.toolCalls.single.arguments;
      expect(isValidToolArguments(args), isTrue);
      expect(args, contains(kToolArgsTruncatedMarker));
      expect(args, contains('写到一半被'), reason: '前半段必须保真');
      expect(logs.any((String l) => l.contains('半截 JSON')), isTrue);
    });

    test('救不了的 rawArguments：包壳放行（合法 JSON，原文不丢）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('续写完成'),
      ]);
      await engine(transport, null)
          .run(
            AgentRunContext(
              agentId: 'a',
              sessionId: 's',
              modelId: 'demo',
              systemPrompt: 'sys',
              userContent: '继续',
              history: poisonedHistory(raw: 'totally broken'),
            ),
            isCancelled: () => false,
          )
          .toList();
      final LlmMessage assistant = await assistantWithCalls(transport);
      final String args = assistant.toolCalls.single.arguments;
      expect(isValidToolArguments(args), isTrue);
      expect(args, contains('truncated_arguments'));
      expect(args, contains('totally broken'));
    });

    test('合法 rawArguments：逐字放行（前缀缓存不换字节）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('续写完成'),
      ]);
      const String good = r'{"path":"a.txt","content":"x\ny"}';
      await engine(transport, null)
          .run(
            AgentRunContext(
              agentId: 'a',
              sessionId: 's',
              modelId: 'demo',
              systemPrompt: 'sys',
              userContent: '继续',
              history: poisonedHistory(raw: good),
            ),
            isCancelled: () => false,
          )
          .toList();
      final LlmMessage assistant = await assistantWithCalls(transport);
      expect(assistant.toolCalls.single.arguments, good);
    });
  });
}
