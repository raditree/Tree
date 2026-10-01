import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 记录引擎看到的上下文（不发网络请求）。
class _CapturingEngine implements AgentEngine {
  final List<AgentRunContext> contexts = <AgentRunContext>[];

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    contexts.add(context);
    yield const AgentDone();
  }

  @override
  Future<void> close() async {}
}

/// `user_message.attachments` 的规范化与透传：
/// 前端上传后发的是**工作空间相对路径**，核心必须原样落库、并原样交给引擎
/// （引擎据此把路径写进提示词）。
void main() {
  late MemoryStore store;
  late CoreAgent agent;
  late ConversationService service;
  late _CapturingEngine engine;

  setUp(() {
    store = MemoryStore();
    agent = store.createAgent(name: '附件用例', modelId: 'demo');
    store.putAgent(agent);
    engine = _CapturingEngine();
    service = ConversationService(
      store: store,
      hub: WsHub(),
      settings: CoreSettings(),
      engine: engine,
    );
  });

  Future<void> send(Object? attachments) => service.handleUserMessage(
    <String, dynamic>{
      'type': 'user_message',
      'agent_id': agent.id,
      'content': '看这张图',
      'session_id': TreeStore.defaultSessionId,
      'attachments': attachments,
    },
  );

  CoreMessage storedUser() => store
      .messages(agent.id, TreeStore.defaultSessionId)
      .firstWhere((CoreMessage m) => m.role == 'user');

  test('Map 形态：规范化为 {name,path,size,type} 并落库', () async {
    await send(<dynamic>[
      <String, dynamic>{
        'name': '图片.png',
        'path': '.input/20261001/图片.png',
        'size': 2048,
        'type': 'png',
      },
      <String, dynamic>{'name': '无路径的坏条目', 'path': ''},
    ]);

    final List<Map<String, dynamic>>? stored = storedUser().attachments;
    expect(stored, hasLength(1), reason: '没有 path 的条目对模型无意义，必须丢弃');
    expect(stored!.single['path'], '.input/20261001/图片.png');
    expect(stored.single['name'], '图片.png');
    expect(stored.single['size'], 2048);
  });

  test('字符串形态（兼容旧客户端）：当作路径并补出文件名', () async {
    await send(<dynamic>[r'C:\Users\me\图片\x.png']);

    final List<Map<String, dynamic>>? stored = storedUser().attachments;
    expect(stored, hasLength(1));
    expect(stored!.single['path'], r'C:\Users\me\图片\x.png');
    expect(stored.single['name'], 'x.png', reason: '兼容 / 与 \\ 两种分隔符');
  });

  test('全部非法 / 没带附件：attachments 落库为 null（不写空壳数组）', () async {
    await send(<dynamic>[42, '', <String, dynamic>{'name': 'x'}]);
    expect(storedUser().attachments, isNull);

    await send(null);
    expect(storedUser().attachments, isNull);
  });

  test('引擎视图透传 attachments（提示词注入的唯一来源）', () async {
    await send(<dynamic>[
      <String, dynamic>{'name': 'a.png', 'path': '.input/20261001/a.png'},
    ]);

    final AgentRunContext context = engine.contexts.single;
    expect(context.history.last.attachments, hasLength(1));
    expect(context.history.last.attachments!.single['path'], '.input/20261001/a.png');
  });
}
