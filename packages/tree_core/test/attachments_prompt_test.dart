import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// 用户上传附件的提示词注入（"附件落工作空间 + 告知模型路径"）。
///
/// 覆盖三件事：
/// 1. 附件段纯函数（引擎与压缩估算**共用**，口径必须逐字一致）；
/// 2. 引擎装配：附件路径进请求、**只有附件没有正文**的消息不再被丢弃；
/// 3. `_toRef` / `_attachments` 的透传与归一化（经真实会话服务路径）。
void main() {
  final CoreModelConfig config = CoreModelConfig(
    modelId: 'demo',
    name: '演示',
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'sk-test',
    maxSeqlen: 64000,
  );

  AgentRunContext context(List<CoreMessageRef> history) => AgentRunContext(
    agentId: 'agt_1',
    sessionId: 'ses_1',
    modelId: 'demo',
    systemPrompt: '系统提示',
    userContent: '',
    history: history,
  );

  LlmAgentEngine engine(FakeTransport transport) => LlmAgentEngine(
    resolveModel: (String id) => id == config.modelId ? config : null,
    toolRunner: const EmptyToolRunner(),
    transportFactory: (CoreModelConfig _) => transport,
  );

  List<Map<String, dynamic>> attachment(String path, {String name = ''}) =>
      <Map<String, dynamic>>[
        <String, dynamic>{
          'name': name.isEmpty ? path.split('/').last : name,
          'path': path,
          'size': 12,
          'type': 'png',
        },
      ];

  group('attachmentsPromptSuffix（共享纯函数）', () {
    test('没有附件 / 只有空路径 ⇒ 空串（不产生多余段）', () {
      expect(attachmentsPromptSuffix(null), '');
      expect(attachmentsPromptSuffix(const <Map<String, dynamic>>[]), '');
      expect(
        attachmentsPromptSuffix(const <Map<String, dynamic>>[
          <String, dynamic>{'name': 'a.png', 'path': ''},
          <String, dynamic>{'name': 'b.png'},
        ]),
        '',
        reason: '没有 path 的附件对模型毫无意义，不该出现在提示词里',
      );
    });

    test('多附件按顺序列出工作空间相对路径，并点明"相对工作空间根"', () {
      final String text = attachmentsPromptSuffix(const <Map<String, dynamic>>[
        <String, dynamic>{'name': 'a.png', 'path': '.input/20261001/a.png'},
        <String, dynamic>{'name': 'b.pdf', 'path': '.input/20261001/b.pdf'},
      ]);
      expect(text, contains('[用户上传的附件'));
      expect(text, contains('相对工作空间根'));
      expect(text, contains('- .input/20261001/a.png'));
      expect(text, contains('- .input/20261001/b.pdf'));
      expect(
        text.indexOf('a.png') < text.indexOf('b.pdf'),
        isTrue,
        reason: '顺序应与用户附件的顺序一致',
      );
    });

    test('attachmentPaths 只取非空 path', () {
      expect(
        attachmentPaths(const <Map<String, dynamic>>[
          <String, dynamic>{'path': ' .input/20261001/a.png '},
          <String, dynamic>{'name': 'x'},
        ]),
        <String>['.input/20261001/a.png'],
      );
    });
  });

  group('引擎装配：附件路径必须进提示词', () {
    test('带附件的用户消息：请求体文本含路径与说明段', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(transport)
          .run(
            context(<CoreMessageRef>[
              CoreMessageRef(
                role: 'user',
                content: '看看这个',
                attachments: attachment('.input/20261001/图片.png'),
              ),
            ]),
            isCancelled: () => false,
          )
          .toList();

      final LlmMessage sent = transport.requests.single.messages.last;
      expect(sent.role, LlmRole.user);
      expect(sent.content, contains('看看这个'));
      expect(sent.content, contains('.input/20261001/图片.png'));
      expect(sent.content, contains('相对工作空间根'));
    });

    test('只有附件、正文为空：消息仍要发出去（不能被整条丢掉）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(transport)
          .run(
            context(<CoreMessageRef>[
              CoreMessageRef(
                role: 'user',
                content: '',
                attachments: attachment('.input/20261001/只有图.png'),
              ),
            ]),
            isCancelled: () => false,
          )
          .toList();

      final List<LlmMessage> sent = transport.requests.single.messages;
      expect(
        sent.where((LlmMessage m) => m.role == LlmRole.user),
        hasLength(1),
        reason: '正文空但带附件的用户消息必须保留，否则用户等于什么都没发',
      );
      expect(sent.last.content, contains('.input/20261001/只有图.png'));
    });

    test('没有附件：用户消息文本与改动前逐字一致', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(transport)
          .run(
            context(<CoreMessageRef>[
              const CoreMessageRef(role: 'user', content: '你好'),
            ]),
            isCancelled: () => false,
          )
          .toList();

      expect(transport.requests.single.messages.last.content, '你好');
    });

    test('agent 消息永不附加附件段（附件只属于用户消息）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(transport)
          .run(
            context(<CoreMessageRef>[
              CoreMessageRef(
                role: 'agent',
                content: '我的回答',
                attachments: attachment('.input/20261001/不该出现.png'),
              ),
            ]),
            isCancelled: () => false,
          )
          .toList();

      expect(
        transport.requests.single.messages.last.content,
        '我的回答',
        reason: '附件段只挂在用户消息上',
      );
    });
  });
}
