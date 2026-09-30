import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// 会话状态注入（M5d）：模型每次拿到工具结果时都要能看到 todo 与已选 Spec。
///
/// 这是"不静默撒谎"的另一面：UI 里勾选的 Spec / 写下的 todo 必须真的影响模型，
/// 否则用户以为自己挂上了规范，模型却一无所知。
void main() {
  group('文案', () {
    test('todo 三态：未设置 / 已设置但无 in_progress / 有 in_progress', () {
      expect(todoStatusText(<TodoItem>[]), contains('todo 未设置'));
      final List<TodoItem> idle = <TodoItem>[
        TodoItem(id: 'a', content: '甲', status: 'pending', progress: 0),
      ];
      expect(todoStatusText(idle), contains('todo 已设置'));
      expect(todoStatusText(idle), contains('无 in_progress'));
      final List<TodoItem> running = <TodoItem>[
        TodoItem(id: 'a', content: '甲', status: 'in_progress', progress: 50),
      ];
      expect(todoStatusText(running), contains('当前 in_progress'));
      expect(todoStatusText(running), contains('a 50%'));
    });

    test('spec 三态：未选择 / 只选自定义（提醒补内置）/ 正常', () {
      expect(specStatusText(<String>[]), contains('spec 未选择'));
      final String customOnly = specStatusText(<String>['my-spec']);
      expect(customOnly, contains('my-spec(自定义)'));
      expect(customOnly, contains('至少选择一个内置 spec'));
      final String builtin = specStatusText(<String>['general-task']);
      expect(builtin, contains('general-task(内置)'));
      expect(builtin, isNot(contains('至少选择')));
    });

    test('整体文案带时间戳页脚', () {
      final String text = sessionStatusText(
        todos: <TodoItem>[],
        selectedSpecIds: <String>['general-task'],
      );
      expect(text, contains('current_todo_id'));
      expect(text, contains('selected spec'));
      expect(text, contains('结果返回时间：'));
    });
  });

  test('引擎把状态拼到工具结果前（模型可见；UI 的工具卡片仍是原始结果）', () async {
    final CoreSettings settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
    });
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      toolCallScript(name: 'read_file', arguments: '{"path":"a.txt"}'),
      textScript('好了'),
    ]);
    final LlmAgentEngine engine = LlmAgentEngine(
      resolveModel: settings.model,
      toolRunner: FakeToolRunner(
        specs: const <ToolSpec>[ToolSpec(name: 'read_file', description: '读')],
        result: '文件内容',
      ),
      transportFactory: (CoreModelConfig _) => transport,
      sessionStatusText: (String agentId, String sessionId) =>
          '[STATUS:$agentId:$sessionId]',
    );
    final List<AgentEvent> events = await engine
        .run(
          AgentRunContext(
            agentId: 'agt_1',
            sessionId: 'ses_1',
            systemPrompt: '',
            userContent: '读文件',
            modelId: 'demo',
            history: <CoreMessageRef>[
              const CoreMessageRef(role: 'user', content: '读文件'),
            ],
          ),
          isCancelled: () => false,
        )
        .toList();
    expect(events.whereType<AgentError>(), isEmpty);
    // 工具卡片（UI 看到的）不带状态
    final AgentToolEnd end = events.whereType<AgentToolEnd>().single;
    expect(end.result, '文件内容');
    // 第二轮请求里的工具结果带状态
    final LlmMessage toolMessage = transport.requests[1].messages.lastWhere(
      (LlmMessage m) => m.role == LlmRole.tool,
    );
    expect(toolMessage.content, contains('[STATUS:agt_1:ses_1]'));
    expect(toolMessage.content, contains('文件内容'));
    await engine.close();
  });
}
