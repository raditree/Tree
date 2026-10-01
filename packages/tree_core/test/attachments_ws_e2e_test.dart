import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'fake_files_api.dart';
import 'fake_transport.dart';
import 'ws_harness.dart';

/// 端到端（真实 HTTP + 真实 WebSocket，只有 LLM 传输层是假的）：
/// 前端把附件上传到工作空间后发 `user_message`（attachments = 工作空间相对路径），
/// 核心要**落库**并把这些路径**写进发给模型的提示词**。
///
/// 这是本功能的验收口径：光"UI 上有卡片"不算生效，模型必须在请求里看到路径。
///
/// 第二组（`if_vision`）再加两段真实链路：**真的从工作空间读图片字节**（真文件）、
/// **真的发 multipart 到 Files API**（本机假服务），最后断言请求体里出现
/// `{"type":"file","file_id":...}` —— 这才是"图片真正送到模型"。
void main() {
  late CoreServer server;
  late String agentId;

  Future<void> startWith(
    FakeTransport transport, {
    bool ifVision = false,
    VisionFileResolver? vision,
  }) async {
    final CoreSettings settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'name': '演示模型',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'max_seqlen': 64000,
      if (ifVision) 'if_vision': true,
    });
    server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      settings: settings,
      engine: LlmAgentEngine(
        resolveModel: settings.model,
        toolRunner: const EmptyToolRunner(),
        transportFactory: (CoreModelConfig config) => transport,
        visionResolver: vision,
      ),
    );
    agentId = server.store
        .createAgent(name: '附件端到端', systemPrompt: '你是助手', modelId: 'demo')
        .id;
  }

  tearDown(() async {
    await server.close();
  });

  Future<TestWs> send(Object? attachments, {String content = '看这张图'}) async {
    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': content,
      'session_id': TreeStore.defaultSessionId,
      'attachments': attachments,
    });
    await waitIdle(ws);
    return ws;
  }

  test('带附件的消息：落库保留路径，且请求体里告诉模型附件在哪', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('好的'),
    ]);
    await startWith(transport);

    await send(<dynamic>[
      <String, dynamic>{
        'name': '图片.png',
        'path': '.input/20261001/图片.png',
        'size': 2048,
        'type': 'png',
      },
    ]);

    // ① 落库：附件元数据完整保留（重启后 UI 与上下文都还在）
    final CoreMessage userMessage = server.store
        .messages(agentId, TreeStore.defaultSessionId)
        .firstWhere((CoreMessage m) => m.role == 'user');
    expect(userMessage.attachments, hasLength(1));
    expect(userMessage.attachments!.single['path'], '.input/20261001/图片.png');

    // ② 发给模型的请求：路径与说明段都在（这就是"附件真正生效"的判据）
    final LlmMessage sent = transport.requests.single.messages.last;
    expect(sent.role, LlmRole.user);
    expect(sent.content, contains('看这张图'));
    expect(sent.content, contains('.input/20261001/图片.png'));
    expect(sent.content, contains('相对工作空间根'));
  });

  test('只有附件、正文为空：消息照样到模型（不被整条丢掉）', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('我看到你发的文件了'),
    ]);
    await startWith(transport);

    await send(<dynamic>[
      <String, dynamic>{'name': 'b.txt', 'path': '.input/20261001/b.txt'},
    ], content: '');

    expect(
      transport.requests.single.messages.where(
        (LlmMessage m) => m.role == LlmRole.user,
      ),
      hasLength(1),
    );
    expect(
      transport.requests.single.messages.last.content,
      contains('.input/20261001/b.txt'),
    );
  });

  test('没有附件：请求体与改动前一致（不注入附件段）', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('好的'),
    ]);
    await startWith(transport);

    await send(null, content: '普通消息');

    expect(transport.requests.single.messages.last.content, '普通消息');
  });

  group('if_vision：图像经 Files API 上传后真正送达模型', () {
    late Directory workspace;
    late FakeFilesApi filesApi;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('vision-ws');
      filesApi = FakeFilesApi();
      await filesApi.start();
    });

    tearDown(() async {
      await filesApi.close();
      await workspace.delete(recursive: true);
    });

    /// 真把图片写进工作空间（走的是真实文件系统，不是内存假 IO）。
    Future<int> seedImage() async {
      final File file = File(
        '${workspace.path}${Platform.pathSeparator}.input'
        '${Platform.pathSeparator}20261001${Platform.pathSeparator}图片.png',
      );
      await file.parent.create(recursive: true);
      final List<int> bytes = <int>[
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        0x11,
        0x22,
      ];
      await file.writeAsBytes(bytes);
      return bytes.length;
    }

    WorkspaceVisionFileResolver resolver({String? cacheFile}) =>
        WorkspaceVisionFileResolver(
          // 与工具层同一份语义：按 agent 取工作空间 IO（这里就是本机目录）
          ioFor: (String id) async => LocalWorkspaceIO(workspace.path),
          cache: cacheFile == null ? null : VisionFileCache(file: cacheFile),
        );

    /// 起一台核心：模型 base_url 指向 [api]（真发 HTTP，端点是假的），
    /// 把 [vision] 接到引擎上，并建一个用于对话的 agent。
    Future<void> bootWith(
      FakeFilesApi api,
      FakeTransport transport,
      WorkspaceVisionFileResolver vision,
    ) async {
      final CoreSettings settings = CoreSettings();
      settings.createModel(<String, dynamic>{
        'model_id': 'demo',
        'name': '演示模型',
        'base_url': api.baseUrl,
        'api_key': 'sk-test',
        'max_seqlen': 64000,
        'if_vision': true,
      });
      server = await CoreServer.start(
        streamChunkDelay: Duration.zero,
        enableHeartbeat: false,
        settings: settings,
        engine: LlmAgentEngine(
          resolveModel: settings.model,
          toolRunner: const EmptyToolRunner(),
          transportFactory: (CoreModelConfig config) => transport,
          visionResolver: vision,
        ),
      );
      agentId = server.store
          .createAgent(name: '视觉端到端', systemPrompt: '你是助手', modelId: 'demo')
          .id;
    }

    test('开启 if_vision：图片→上传 File API→请求体带 file 块', () async {
      final int size = await seedImage();
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('我看到一只猫'),
      ]);
      final Directory cacheDir = await Directory.systemTemp.createTemp(
        'vision-c',
      );
      addTearDown(() => cacheDir.delete(recursive: true));
      final WorkspaceVisionFileResolver vision = resolver(
        cacheFile: '${cacheDir.path}${Platform.pathSeparator}vision_files.json',
      );
      addTearDown(vision.close);
      await bootWith(filesApi, transport, vision);

      await send(<dynamic>[
        <String, dynamic>{
          'name': '图片.png',
          'path': '.input/20261001/图片.png',
          'size': size,
          'type': 'png',
        },
      ]);

      // ① 真的发了 Files API 请求，且是文档要求的形态
      final CapturedRequest upload = filesApi.requests.single;
      expect(upload.method, 'POST');
      expect(upload.path, '/v1/files');
      expect(upload.text, contains('name="purpose"\r\n\r\nuser_data'));
      expect(upload.text, contains('604800'));

      // ② 发给模型的请求体里出现 file 引用块（图像真正生效的判据）
      final Map<String, dynamic> body = OpenAiCodec.requestBody(
        transport.requests.single,
        stream: true,
      );
      final Map<String, dynamic> user =
          (body['messages'] as List<dynamic>).last as Map<String, dynamic>;
      final List<dynamic> content = user['content'] as List<dynamic>;
      expect(content.last, <String, dynamic>{
        'type': 'file',
        'file_id': 'file-api-xyz',
      });
      expect(
        (content.first as Map<String, dynamic>)['text'],
        contains('.input/20261001/图片.png'),
      );

      // ③ 同一轮再请求一次（工具循环/下一轮）不会重复上传
      await send(<dynamic>[
        <String, dynamic>{
          'name': '图片.png',
          'path': '.input/20261001/图片.png',
          'size': size,
          'type': 'png',
        },
      ], content: '再看一次');
      expect(filesApi.requests, hasLength(1), reason: 'file_id 缓存应命中');
    });

    test('Files API 报错（500）：本轮照常结束，只是退回纯路径', () async {
      final int size = await seedImage();
      final FakeFilesApi brokenApi = FakeFilesApi(
        statusCode: 500,
        body: '{"error":{"message":"服务不可用"}}',
      );
      await brokenApi.start();
      addTearDown(brokenApi.close);
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('我看到你的文件了'),
      ]);
      final WorkspaceVisionFileResolver vision = resolver();
      addTearDown(vision.close);
      await bootWith(brokenApi, transport, vision);

      // send() 内部会等 agent 回到 idle —— 能走到下一行就说明本轮没被上传失败拖垮
      final TestWs ws = await send(<dynamic>[
        <String, dynamic>{
          'name': '图片.png',
          'path': '.input/20261001/图片.png',
          'size': size,
          'type': 'png',
        },
      ]);

      expect(brokenApi.requests, hasLength(1), reason: '试过上传，但失败了');
      expect(ws.types(), isNot(contains('error')), reason: '上传失败不该变成对话错误');
      final LlmMessage sent = transport.requests.single.messages.last;
      expect(sent.contentParts, isEmpty);
      expect(sent.content, contains('.input/20261001/图片.png'));
      expect(sent.toWire()['content'], isA<String>());
    });

    test('关闭 if_vision：一个 Files API 请求都不发（请求体逐字为文本）', () async {
      final int size = await seedImage();
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('好的'),
      ]);
      final WorkspaceVisionFileResolver vision = resolver();
      addTearDown(vision.close);
      await startWith(transport, vision: vision);

      await send(<dynamic>[
        <String, dynamic>{
          'name': '图片.png',
          'path': '.input/20261001/图片.png',
          'size': size,
          'type': 'png',
        },
      ]);

      expect(filesApi.requests, isEmpty, reason: '没开视觉就不该外发任何字节');
      final LlmMessage sent = transport.requests.single.messages.last;
      expect(sent.content, contains('.input/20261001/图片.png'));
      expect(sent.toWire()['content'], isA<String>());
    });
  });
}
