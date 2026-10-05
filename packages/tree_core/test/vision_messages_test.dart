import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// 假视觉解析器：记录被问过哪些附件，按脚本给 file_id（或一律失败/一律内联）。
class _FakeResolver implements VisionFileResolver {
  _FakeResolver({
    this.ids = const <String>['file-api-1'],
    this.fail = false,
    this.inlineBase64,
  });

  final List<String> ids;
  final bool fail;

  /// 非空 = 一律回退内联（模拟"端点不支持 Files API / 上传失败"）。
  final String? inlineBase64;

  final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
  final List<CoreModelConfig> configs = <CoreModelConfig>[];
  final List<String> agents = <String>[];
  bool closed = false;

  @override
  Future<VisionImageRef?> resolve({
    required CoreModelConfig config,
    required String agentId,
    required Map<String, dynamic> attachment,
  }) async {
    calls.add(attachment);
    configs.add(config);
    agents.add(agentId);
    if (fail) return null;
    final String? inline = inlineBase64;
    if (inline != null) {
      return VisionImageRef.inline(base64: inline, contentType: 'image/png');
    }
    final int index = calls.length - 1;
    return VisionImageRef.file(index < ids.length ? ids[index] : ids.last);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

Map<String, dynamic> _png(int index) => <String, dynamic>{
  'name': '图$index.png',
  'path': '.input/20261001/图$index.png',
  'size': 128 + index,
  'type': 'png',
};

void main() {
  CoreModelConfig modelConfig({bool ifVision = false}) => CoreModelConfig(
    modelId: 'demo',
    name: '演示',
    baseUrl: 'https://api.deepseek.com',
    apiKey: 'sk-test',
    maxSeqlen: 64000,
    ifVision: ifVision,
  );

  LlmAgentEngine build(
    FakeTransport transport, {
    required CoreModelConfig config,
    VisionFileResolver? resolver,
  }) => LlmAgentEngine(
    resolveModel: (String id) => id == config.modelId ? config : null,
    transportFactory: (CoreModelConfig c) => transport,
    visionResolver: resolver,
  );

  AgentRunContext context(List<CoreMessageRef> history) => AgentRunContext(
    agentId: 'agt_1',
    sessionId: 'ses_1',
    modelId: 'demo',
    systemPrompt: '系统提示',
    userContent: '看这张图',
    history: history,
  );

  /// 跑一轮，返回发给端点的那一份请求。
  Future<LlmRequest> run(
    LlmAgentEngine engine,
    FakeTransport transport,
    List<CoreMessageRef> history,
  ) async {
    await engine.run(context(history), isCancelled: () => false).toList();
    return transport.requests.last;
  }

  group('if_vision 关闭（回归：与改动前逐字一致）', () {
    test('图片附件只给路径、不碰解析器、线协议仍是字符串', () async {
      final CoreModelConfig config = modelConfig();
      final _FakeResolver resolver = _FakeResolver();
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('好的'),
      ]);
      await run(
        build(transport, config: config, resolver: resolver),
        transport,
        <CoreMessageRef>[
          CoreMessageRef(
            role: 'user',
            content: '看这张图',
            attachments: <Map<String, dynamic>>[_png(1)],
          ),
        ],
      );

      final LlmMessage sent = transport.requests.single.messages.last;
      expect(sent.content, contains('看这张图'));
      expect(sent.content, contains('.input/20261001/图1.png'));
      expect(sent.contentParts, isEmpty);
      expect(resolver.calls, isEmpty, reason: '关闭时连"要不要上传"都不该判断');
      expect(sent.toWire()['content'], isA<String>());
    });

    test('没接线（visionResolver 为空）时即使 if_vision=true 也不外发', () async {
      final CoreModelConfig config = modelConfig(ifVision: true);
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('好的'),
      ]);
      await run(build(transport, config: config), transport, <CoreMessageRef>[
        CoreMessageRef(
          role: 'user',
          content: '看这张图',
          attachments: <Map<String, dynamic>>[_png(1)],
        ),
      ]);
      final LlmMessage sent = transport.requests.single.messages.last;
      expect(sent.contentParts, isEmpty);
      expect(sent.toWire()['content'], isA<String>());
    });
  });

  group('if_vision 打开（图像真正送达模型）', () {
    test('图片 → file 内容块，线协议是 content 数组（文档要求的两段式引用）', () async {
      final CoreModelConfig config = modelConfig(ifVision: true);
      final _FakeResolver resolver = _FakeResolver(ids: <String>['file-api-9']);
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('这是只猫'),
      ]);
      await run(
        build(transport, config: config, resolver: resolver),
        transport,
        <CoreMessageRef>[
          CoreMessageRef(
            role: 'user',
            content: '看这张图',
            attachments: <Map<String, dynamic>>[_png(1)],
          ),
        ],
      );

      expect(resolver.calls, hasLength(1));
      expect(resolver.calls.single['path'], '.input/20261001/图1.png');
      expect(resolver.agents.single, 'agt_1');
      expect(resolver.configs.single.ifVision, isTrue);
      expect(resolver.configs.single.baseUrl, 'https://api.deepseek.com');

      final LlmMessage sent = transport.requests.single.messages.last;
      expect(sent.contentParts.single.fileId, 'file-api-9');

      // 真正的上线形态：正文块 + file 引用块
      final Map<String, dynamic> body = OpenAiCodec.requestBody(
        transport.requests.single,
        stream: true,
      );
      final Map<String, dynamic> user =
          (body['messages'] as List<dynamic>).last as Map<String, dynamic>;
      final List<dynamic> content = user['content'] as List<dynamic>;
      expect(content, hasLength(2));
      expect(content[0], <String, dynamic>{
        'type': 'text',
        'text': sent.content,
      });
      expect(content[1], <String, dynamic>{
        'type': 'file',
        'file_id': 'file-api-9',
      });
      expect(sent.content, contains('.input/20261001/图1.png'));
    });

    test('上传走不通（解析器回退内联）：请求体里出现内联 base64 图像块', () async {
      final CoreModelConfig config = modelConfig(ifVision: true);
      // 模拟"端点不支持 Files API / 上传失败"：解析器直接给内联 base64
      final _FakeResolver resolver = _FakeResolver(
        inlineBase64: 'iVBORw0KGgoAAAANSUhEUg==',
      );
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('我看到图了'),
      ]);
      await run(
        build(transport, config: config, resolver: resolver),
        transport,
        <CoreMessageRef>[
          CoreMessageRef(
            role: 'user',
            content: '看这张图',
            attachments: <Map<String, dynamic>>[_png(1)],
          ),
        ],
      );

      final LlmMessage sent = transport.requests.single.messages.last;
      expect(sent.contentParts.single.type, 'image_url');

      // 真正的上线形态：正文块 + **内联图像块**（OpenAI/DeepSeek vision 口径）
      final Map<String, dynamic> body = OpenAiCodec.requestBody(
        transport.requests.single,
        stream: true,
      );
      final Map<String, dynamic> user =
          (body['messages'] as List<dynamic>).last as Map<String, dynamic>;
      final List<dynamic> content = user['content'] as List<dynamic>;
      expect(content, hasLength(2));
      expect(content[1], <String, dynamic>{
        'type': 'image_url',
        'image_url': <String, dynamic>{
          'url': 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==',
        },
      });
      // 路径说明段照旧在（降级路径与内联路径不互斥）
      expect(sent.content, contains('.input/20261001/图1.png'));
    });

    test('多图：按附件顺序各给一个 file 块', () async {
      final CoreModelConfig config = modelConfig(ifVision: true);
      final _FakeResolver resolver = _FakeResolver(
        ids: <String>['file-a', 'file-b'],
      );
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('两张都看到了'),
      ]);
      await run(
        build(transport, config: config, resolver: resolver),
        transport,
        <CoreMessageRef>[
          CoreMessageRef(
            role: 'user',
            content: '两张图',
            attachments: <Map<String, dynamic>>[_png(1), _png(2)],
          ),
        ],
      );
      expect(
        transport.requests.single.messages.last.contentParts
            .map((LlmContentPart p) => p.fileId)
            .toList(),
        <String>['file-a', 'file-b'],
      );
    });

    test('非图片附件不参与（pdf 直接跳过，不浪费一次询问）', () async {
      final CoreModelConfig config = modelConfig(ifVision: true);
      final _FakeResolver resolver = _FakeResolver(ids: <String>['file-png']);
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('好'),
      ]);
      await run(
        build(transport, config: config, resolver: resolver),
        transport,
        <CoreMessageRef>[
          CoreMessageRef(
            role: 'user',
            content: '看图与报告',
            attachments: <Map<String, dynamic>>[
              <String, dynamic>{
                'name': '报告.pdf',
                'path': '.input/20261001/报告.pdf',
                'size': 4096,
                'type': 'pdf',
              },
              _png(1),
            ],
          ),
        ],
      );
      expect(resolver.calls, hasLength(1), reason: '只问图片那一条');
      final LlmMessage sent = transport.requests.single.messages.last;
      expect(sent.contentParts.single.fileId, 'file-png');
      expect(sent.content, contains('.input/20261001/报告.pdf'));
    });

    test('解析失败（上传挂了且没字节可内联）：本轮照常出结果，只是没有块', () async {
      final CoreModelConfig config = modelConfig(ifVision: true);
      final _FakeResolver resolver = _FakeResolver(fail: true);
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('我看到你的文件了'),
      ]);
      final List<AgentEvent> events =
          await build(transport, config: config, resolver: resolver)
              .run(
                context(<CoreMessageRef>[
                  CoreMessageRef(
                    role: 'user',
                    content: '看这张图',
                    attachments: <Map<String, dynamic>>[_png(1)],
                  ),
                ]),
                isCancelled: () => false,
              )
              .toList();

      expect(resolver.calls, hasLength(1));
      final LlmMessage sent = transport.requests.single.messages.last;
      expect(sent.contentParts, isEmpty);
      expect(sent.content, contains('.input/20261001/图1.png'));
      expect(events.whereType<AgentError>(), isEmpty);
      expect(events.last, isA<AgentDone>());
    });

    test('历史里更早的图片消息同样被解析（长会话里图片不只在最后一轮）', () async {
      final CoreModelConfig config = modelConfig(ifVision: true);
      final _FakeResolver resolver = _FakeResolver(
        ids: <String>['file-old', 'file-new'],
      );
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('好'),
      ]);
      await run(
        build(transport, config: config, resolver: resolver),
        transport,
        <CoreMessageRef>[
          CoreMessageRef(
            role: 'user',
            content: '第一张',
            attachments: <Map<String, dynamic>>[_png(1)],
          ),
          const CoreMessageRef(role: 'agent', content: '看到了'),
          CoreMessageRef(
            role: 'user',
            content: '第二张',
            attachments: <Map<String, dynamic>>[_png(2)],
          ),
        ],
      );
      final List<LlmMessage> users = transport.requests.single.messages
          .where((LlmMessage m) => m.role == LlmRole.user)
          .toList();
      expect(users, hasLength(2));
      expect(users[0].contentParts.single.fileId, 'file-old');
      expect(users[1].contentParts.single.fileId, 'file-new');
    });

    test('close() 会把解析器一起关掉（连接池不泄漏）', () async {
      final CoreModelConfig config = modelConfig(ifVision: true);
      final _FakeResolver resolver = _FakeResolver();
      final LlmAgentEngine engine = build(
        FakeTransport(<List<LlmStreamEvent>>[]),
        config: config,
        resolver: resolver,
      );
      await engine.close();
      expect(resolver.closed, isTrue);
    });
  });
}
