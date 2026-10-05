import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

import 'fake_files_api.dart';

/// 假工作空间 IO：只用到"读字节"（工具/文件面板的方法不在本任务范围）。
class _FakeIo implements WorkspaceIO, WorkspaceFiles {
  _FakeIo({
    required this.root,
    Map<String, List<int>>? files,
    this.staleOnRead = false,
    this.failure,
  }) : files = files ?? <String, List<int>>{};

  @override
  final String root;
  final Map<String, List<int>> files;

  /// 读字节时抛 "SSH 链路失活"（模拟远端链路断）。
  final bool staleOnRead;

  /// 读字节时抛的任意异常（模拟远端文件缺失等）。
  final Object? failure;

  int readBytesCalls = 0;

  @override
  Future<Uint8List> readBytes(String relativePath) async {
    readBytesCalls++;
    if (staleOnRead) throw SshLinkStaleException('SSH 链路已失活（测试注入）');
    final Object? error = failure;
    if (error != null) throw error;
    final List<int>? bytes = files[relativePath];
    if (bytes == null) throw WorkspaceIoException('文件不存在：$relativePath');
    return Uint8List.fromList(bytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 只实现 [WorkspaceIO]（**没有** [WorkspaceFiles]）：验证 base64 退化读取路径。
class _Base64OnlyIo implements WorkspaceIO {
  _Base64OnlyIo({required this.root, required this.bytes});

  @override
  final String root;
  final List<int> bytes;

  @override
  Future<FileContent> readFile(
    String relativePath, {
    int? startLine,
    int? lineCount,
    int? maxBytes,
  }) async =>
      FileContent(path: relativePath, text: '', base64: base64Encode(bytes));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 一个最小的 PNG 头（内容对上传逻辑无意义，只关心"字节原样送达"）。
final Uint8List _pngBytes = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x01,
  0x02,
  0x03,
]);

CoreModelConfig _config(String baseUrl) => CoreModelConfig(
  modelId: 'deepseek-flash',
  name: '视觉模型',
  baseUrl: baseUrl,
  apiKey: 'sk-test',
  ifVision: true,
);

Map<String, dynamic> _imageAttachment({int size = 11}) => <String, dynamic>{
  'name': '图片.png',
  'path': '.input/20261001/图片.png',
  'size': size,
  'type': 'png',
};

void main() {
  group('端点与类型判定（纯函数）', () {
    test('Files 端点拼接：常见 base_url 形态都拼对', () {
      expect(
        visionFilesEndpointFor('https://api.deepseek.com'),
        'https://api.deepseek.com/files',
      );
      expect(
        visionFilesEndpointFor('https://api.deepseek.com/v1'),
        'https://api.deepseek.com/v1/files',
      );
      expect(
        visionFilesEndpointFor('https://api.deepseek.com/v1/'),
        'https://api.deepseek.com/v1/files',
      );
      // 已经写到 /files 不重复拼（否则会 404）
      expect(
        visionFilesEndpointFor('https://api.deepseek.com/files'),
        'https://api.deepseek.com/files',
      );
      expect(
        visionFilesEndpointFor('  http://127.0.0.1:8000/v1  '),
        'http://127.0.0.1:8000/v1/files',
      );
      expect(visionFilesEndpointFor(''), '/files');
    });

    test('图像判定：白名单内的扩展名（含大写/无 type 时按 name 推断）', () {
      expect(isVisionImageAttachment(<String, dynamic>{'type': 'png'}), isTrue);
      expect(isVisionImageAttachment(<String, dynamic>{'type': 'JPG'}), isTrue);
      expect(
        isVisionImageAttachment(<String, dynamic>{'type': 'jpeg'}),
        isTrue,
      );
      expect(isVisionImageAttachment(<String, dynamic>{'type': 'gif'}), isTrue);
      expect(
        isVisionImageAttachment(<String, dynamic>{'type': 'webp'}),
        isTrue,
      );
      // 前端没给 type 时按 name / path 推断
      expect(
        isVisionImageAttachment(<String, dynamic>{'name': 'a.PNG'}),
        isTrue,
      );
      expect(
        isVisionImageAttachment(<String, dynamic>{'path': '.input/x/y.jpg'}),
        isTrue,
      );
      // 非图像一律不参与"上传 + 引用"
      for (final String type in <String>['pdf', 'txt', 'zip', 'svg', '']) {
        expect(
          isVisionImageAttachment(<String, dynamic>{'type': type}),
          isFalse,
          reason: 'type=$type 不该被当成图像',
        );
      }
    });

    test('MIME 映射', () {
      expect(visionContentType('png'), 'image/png');
      expect(visionContentType('jpg'), 'image/jpeg');
      expect(visionContentType('jpeg'), 'image/jpeg');
      expect(visionContentType('gif'), 'image/gif');
      expect(visionContentType('webp'), 'image/webp');
      expect(visionContentType('bmp'), 'application/octet-stream');
    });

    test('缓存键必须带工作空间身份（否则换 SSH 主机会串味）', () {
      final String local = visionCacheKey(
        baseUrl: 'https://api.deepseek.com',
        workspaceRoot: r'C:\ws\a1',
        path: '.input/x.png',
        size: 11,
      );
      final String remote = visionCacheKey(
        baseUrl: 'https://api.deepseek.com',
        workspaceRoot: '/home/u/ws/a1',
        path: '.input/x.png',
        size: 11,
      );
      expect(local, isNot(remote));
      expect(local, contains(r'C:\ws\a1'));
      expect(remote, contains('/home/u/ws/a1'));
    });
  });

  group('multipart 请求体（纯函数）', () {
    test('字段齐全：purpose / model / expires_after 两段 / 文件字节与文件名', () {
      final VisionMultipartBody body = visionMultipartBody(
        bytes: _pngBytes,
        filename: 'a.png',
        contentType: 'image/png',
        modelId: 'deepseek-v4.1-flash',
        boundary: 'BOUND',
      );
      expect(body.contentType, 'multipart/form-data; boundary=BOUND');
      // 二进制体里含非 UTF-8 字节，按 allowMalformed 解码只为做文本断言
      final String text = utf8.decode(body.body, allowMalformed: true);
      expect(text, contains('--BOUND\r\n'));
      expect(
        text,
        contains(
          'Content-Disposition: form-data; name="purpose"\r\n'
          '\r\nuser_data\r\n',
        ),
      );
      // **中转站（new-api）的硬要求**：表单不带 model 就 400
      // 「Model name not specified, model name cannot be empty」（真机现场）。
      expect(
        text,
        contains(
          'Content-Disposition: form-data; name="model"\r\n'
          '\r\ndeepseek-v4.1-flash\r\n',
        ),
      );
      expect(text, contains('name="expires_after[anchor]"\r\n\r\ncreated_at'));
      expect(
        text,
        contains('name="expires_after[seconds]"\r\n\r\n604800'),
        reason: '默认有效期 7 天 = 604800 秒',
      );
      expect(
        text,
        contains('name="file"; filename="a.png"\r\nContent-Type: image/png'),
      );
      // 字节原样出现在体里，且边界闭合
      expect(text, contains('\r\n--BOUND--\r\n'));
      final int at = body.body.indexOf(_pngBytes.first);
      expect(at > 0, isTrue);
      expect(
        body.body.sublist(at, at + _pngBytes.length),
        _pngBytes,
        reason: '图片字节必须原样送达（不能被编码/换行破坏）',
      );
    });

    test('有效期 0 = 不带有效期字段（文档：不传即永久有效）', () {
      final VisionMultipartBody body = visionMultipartBody(
        bytes: _pngBytes,
        filename: 'a.png',
        contentType: 'image/png',
        expiresAfterSeconds: 0,
        boundary: 'B',
      );
      expect(
        utf8.decode(body.body, allowMalformed: true),
        isNot(contains('expires_after')),
      );
    });

    test('modelId 为空 = 不带 model 字段（官方端点无需，与改动前逐字一致）', () {
      final VisionMultipartBody body = visionMultipartBody(
        bytes: _pngBytes,
        filename: 'a.png',
        contentType: 'image/png',
        boundary: 'B',
      );
      expect(
        utf8.decode(body.body, allowMalformed: true),
        isNot(contains('name="model"')),
      );
    });

    test('中文文件名：ASCII 兜底 + filename* 正规编码同时在', () {
      final VisionMultipartBody body = visionMultipartBody(
        bytes: _pngBytes,
        filename: '屏幕截图 1.png',
        contentType: 'image/png',
        boundary: 'B',
      );
      // 二进制体里含非 UTF-8 字节，按 allowMalformed 解码只为做文本断言
      final String text = utf8.decode(body.body, allowMalformed: true);
      // 4 个中文字 → 4 个下划线（ASCII 兜底，保留扩展名）
      expect(text, contains('filename="____ 1.png"'));
      expect(
        text,
        contains("filename*=UTF-8''${Uri.encodeComponent('屏幕截图 1.png')}"),
      );
    });
  });

  group('VisionFileUploader（真发 HTTP，端点是本机假服务）', () {
    late FakeFilesApi api;

    tearDown(() async => api.close());

    test('成功：POST {base}/files，带 Bearer 与 multipart（含 model），返回 id', () async {
      api = FakeFilesApi();
      await api.start();
      final List<String> logs = <String>[];
      final VisionFileUploader uploader = VisionFileUploader(
        baseUrl: api.baseUrl,
        apiKey: 'sk-test',
        modelId: 'deepseek-flash',
        log: logs.add,
      );
      addTearDown(uploader.close);

      final String? id = await uploader.upload(
        bytes: _pngBytes,
        filename: '图片.png',
        contentType: 'image/png',
      );

      expect(id, 'file-api-xyz');
      final CapturedRequest request = api.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/v1/files');
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer sk-test',
      );
      expect(
        request.headers.contentType.toString(),
        startsWith('multipart/form-data; boundary='),
      );
      expect(request.text, contains('name="purpose"\r\n\r\nuser_data'));
      // 上传请求必须带模型名：不带就被中转站 400「Model name not specified」
      expect(
        request.text,
        contains('name="model"\r\n\r\ndeepseek-flash'),
        reason: 'multipart 里必须带 model（修复 400 的关键）',
      );
      expect(request.text, contains('name="file"'));
      expect(logs.join('\n'), contains('file-api-xyz'));
      // 日志里绝不能出现密钥
      expect(logs.join('\n'), isNot(contains('sk-test')));
    });

    test('非 2xx：返回 null 且不抛（错误原文进日志，便于诊断）', () async {
      api = FakeFilesApi(
        statusCode: 400,
        body: '{"error":{"message":"purpose 不合法"}}',
      );
      await api.start();
      final List<String> logs = <String>[];
      final VisionFileUploader uploader = VisionFileUploader(
        baseUrl: api.baseUrl,
        apiKey: 'sk-test',
        log: logs.add,
      );
      addTearDown(uploader.close);

      expect(
        await uploader.upload(
          bytes: _pngBytes,
          filename: 'a.png',
          contentType: 'image/png',
        ),
        isNull,
      );
      expect(logs.join('\n'), contains('HTTP 400'));
      expect(logs.join('\n'), contains('purpose 不合法'));
    });

    test('响应坏 JSON / 没有 id：返回 null', () async {
      api = FakeFilesApi(body: '这不是 json');
      await api.start();
      final VisionFileUploader uploader = VisionFileUploader(
        baseUrl: api.baseUrl,
        apiKey: 'sk-test',
      );
      addTearDown(uploader.close);
      expect(
        await uploader.upload(
          bytes: _pngBytes,
          filename: 'a.png',
          contentType: 'image/png',
        ),
        isNull,
      );
      await api.close();

      api = FakeFilesApi(body: '{"object":"file"}');
      await api.start();
      final VisionFileUploader second = VisionFileUploader(
        baseUrl: api.baseUrl,
        apiKey: 'sk-test',
      );
      addTearDown(second.close);
      expect(
        await second.upload(
          bytes: _pngBytes,
          filename: 'a.png',
          contentType: 'image/png',
        ),
        isNull,
      );
    });

    test('超限 / 空文件 / 缺配置：直接返回 null，一个请求都不发', () async {
      api = FakeFilesApi();
      await api.start();
      final VisionFileUploader uploader = VisionFileUploader(
        baseUrl: api.baseUrl,
        apiKey: 'sk-test',
        maxBytes: 4,
      );
      addTearDown(uploader.close);
      expect(
        await uploader.upload(
          bytes: _pngBytes,
          filename: 'a.png',
          contentType: 'image/png',
        ),
        isNull,
        reason: '超过 maxBytes',
      );
      expect(
        await uploader.upload(
          bytes: const <int>[],
          filename: 'a.png',
          contentType: 'image/png',
        ),
        isNull,
        reason: '空文件',
      );
      final VisionFileUploader noKey = VisionFileUploader(
        baseUrl: api.baseUrl,
        apiKey: '',
      );
      addTearDown(noKey.close);
      expect(
        await noKey.upload(
          bytes: _pngBytes,
          filename: 'a.png',
          contentType: 'image/png',
        ),
        isNull,
        reason: '缺 api_key',
      );
      expect(api.requests, isEmpty);
    });
  });

  group('VisionFileCache', () {
    test('落盘往返 + 过期（TTL 用注入时钟推进）', () async {
      final Directory dir = await Directory.systemTemp.createTemp('vision-c');
      addTearDown(() => dir.delete(recursive: true));
      final String path =
          '${dir.path}${Platform.pathSeparator}vision_files.json';
      DateTime now = DateTime.fromMillisecondsSinceEpoch(1790000000000);
      final VisionFileCache cache = VisionFileCache(
        file: path,
        ttl: const Duration(days: 6),
        now: () => now,
      );
      await cache.put('k1', 'file-api-1');
      expect(await cache.get('k1'), 'file-api-1');

      // 另一个实例读同一份盘上数据（模拟核心重启）
      final VisionFileCache reopened = VisionFileCache(
        file: path,
        now: () => now,
      );
      expect(await reopened.get('k1'), 'file-api-1');

      now = now.add(const Duration(days: 7));
      expect(
        await reopened.get('k1'),
        isNull,
        reason: '超过 TTL 即视为未命中（重传比拿过期 id 更安全）',
      );
    });

    test('缓存文件损坏 / 不存在：不抛，当空缓存', () async {
      final Directory dir = await Directory.systemTemp.createTemp('vision-c2');
      addTearDown(() => dir.delete(recursive: true));
      final String path = '${dir.path}${Platform.pathSeparator}broken.json';
      await File(path).writeAsString('{不是 json');
      final VisionFileCache cache = VisionFileCache(file: path);
      expect(await cache.get('k'), isNull);
      await cache.put('k2', 'file-api-2');
      expect(await cache.get('k2'), 'file-api-2');
      expect(
        await VisionFileCache(
          file: '${dir.path}${Platform.pathSeparator}none.json',
        ).get('k'),
        isNull,
      );
    });
  });

  group('WorkspaceVisionFileResolver（工作空间 → 端点）', () {
    late FakeFilesApi api;

    tearDown(() async => api.close());

    Future<WorkspaceVisionFileResolver> resolverFor(
      Future<WorkspaceIO?> Function(String agentId) ioFor, {
      List<String>? logs,
      VisionFileCache? cache,
      int maxBytes = visionMaxFileBytes,
    }) async {
      api = FakeFilesApi();
      await api.start();
      return WorkspaceVisionFileResolver(
        ioFor: ioFor,
        cache: cache,
        log: logs?.add,
        maxBytes: maxBytes,
      );
    }

    test('本地/远端同一条路：读工作空间字节 → 上传 → 返回 file_id', () async {
      final _FakeIo io = _FakeIo(
        root: '/home/u/ws/a1',
        files: <String, List<int>>{'.input/20261001/图片.png': _pngBytes},
      );
      final WorkspaceVisionFileResolver resolver = await resolverFor(
        (String agentId) async => io,
      );
      addTearDown(resolver.close);

      final VisionImageRef? ref = await resolver.resolve(
        config: _config(api.baseUrl),
        agentId: 'agt_1',
        attachment: _imageAttachment(),
      );

      expect(ref?.isFile, isTrue);
      expect(ref?.fileId, 'file-api-xyz');
      expect(io.readBytesCalls, 1);
      expect(api.requests.single.path, '/v1/files');
      expect(
        api.requests.single.text,
        contains('name="model"\r\n\r\ndeepseek-flash'),
        reason: '解析器必须把模型配置里的 model_id 带进上传表单（不硬编码）',
      );
    });

    test('SSH：字节取自远端 IO 的 root；两个不同 root 不共用缓存', () async {
      final _FakeIo remoteA = _FakeIo(
        root: '/home/u/ws/a1',
        files: <String, List<int>>{'.input/20261001/图片.png': _pngBytes},
      );
      final _FakeIo remoteB = _FakeIo(
        root: '/home/u/ws/a2',
        files: <String, List<int>>{'.input/20261001/图片.png': _pngBytes},
      );
      final Directory dir = await Directory.systemTemp.createTemp('vision-k');
      addTearDown(() => dir.delete(recursive: true));
      final VisionFileCache cache = VisionFileCache(
        file: '${dir.path}${Platform.pathSeparator}vision_files.json',
      );
      final Map<String, _FakeIo> byAgent = <String, _FakeIo>{
        'agt_1': remoteA,
        'agt_2': remoteB,
      };
      final WorkspaceVisionFileResolver resolver = await resolverFor(
        (String agentId) async => byAgent[agentId],
        cache: cache,
      );
      addTearDown(resolver.close);

      await resolver.resolve(
        config: _config(api.baseUrl),
        agentId: 'agt_1',
        attachment: _imageAttachment(),
      );
      await resolver.resolve(
        config: _config(api.baseUrl),
        agentId: 'agt_2',
        attachment: _imageAttachment(),
      );

      expect(
        api.requests,
        hasLength(2),
        reason: '同 path/size 但工作空间 root 不同 → 必须各自上传（换机器不能串味）',
      );
      expect(remoteA.readBytesCalls, 1);
      expect(remoteB.readBytesCalls, 1);
    });

    test('缓存命中：第二轮不再读字节、不再发请求', () async {
      final _FakeIo io = _FakeIo(
        root: '/home/u/ws/a1',
        files: <String, List<int>>{'.input/20261001/图片.png': _pngBytes},
      );
      final Directory dir = await Directory.systemTemp.createTemp('vision-h');
      addTearDown(() => dir.delete(recursive: true));
      final String cacheFile =
          '${dir.path}${Platform.pathSeparator}vision_files.json';
      final WorkspaceVisionFileResolver resolver = await resolverFor(
        (String agentId) async => io,
        cache: VisionFileCache(file: cacheFile),
      );
      addTearDown(resolver.close);

      final CoreModelConfig config = _config(api.baseUrl);
      expect(
        (await resolver.resolve(
          config: config,
          agentId: 'agt_1',
          attachment: _imageAttachment(),
        ))?.fileId,
        'file-api-xyz',
      );
      expect(
        (await resolver.resolve(
          config: config,
          agentId: 'agt_1',
          attachment: _imageAttachment(),
        ))?.fileId,
        'file-api-xyz',
      );
      expect(api.requests, hasLength(1), reason: '同一张图只上传一次');
      expect(io.readBytesCalls, 1, reason: '命中缓存时连字节都不用读');
    });

    test('SSH 未配置完整（ioFor 返回 null）：零请求、降级', () async {
      final List<String> logs = <String>[];
      final WorkspaceVisionFileResolver resolver = await resolverFor(
        (String agentId) async => null,
        logs: logs,
      );
      addTearDown(resolver.close);

      expect(
        await resolver.resolve(
          config: _config(api.baseUrl),
          agentId: 'agt_ssh',
          attachment: _imageAttachment(),
        ),
        isNull,
      );
      expect(api.requests, isEmpty);
      expect(logs.join('\n'), contains('工作空间不可用'));
    });

    test('ioFor 抛异常：零请求、降级', () async {
      final List<String> logs = <String>[];
      final WorkspaceVisionFileResolver resolver = await resolverFor(
        (String agentId) async => throw WorkspaceIoException('SSH 认证失败'),
        logs: logs,
      );
      addTearDown(resolver.close);

      expect(
        await resolver.resolve(
          config: _config(api.baseUrl),
          agentId: 'agt_ssh',
          attachment: _imageAttachment(),
        ),
        isNull,
      );
      expect(api.requests, isEmpty);
      expect(logs.join('\n'), contains('降级为路径提示'));
    });

    test('SSH 链路失活（SshLinkStaleException）：日志点名"失活"，零请求', () async {
      final _FakeIo io = _FakeIo(root: '/home/u/ws/a1', staleOnRead: true);
      final List<String> logs = <String>[];
      final WorkspaceVisionFileResolver resolver = await resolverFor(
        (String agentId) async => io,
        logs: logs,
      );
      addTearDown(resolver.close);

      expect(
        await resolver.resolve(
          config: _config(api.baseUrl),
          agentId: 'agt_ssh',
          attachment: _imageAttachment(),
        ),
        isNull,
      );
      expect(api.requests, isEmpty);
      expect(logs.join('\n'), contains('SSH 链路失活'));
    });

    test('远端文件不存在：降级，不发请求', () async {
      final _FakeIo io = _FakeIo(
        root: '/home/u/ws/a1',
        failure: WorkspaceIoException('远端文件不存在或无法读取'),
      );
      final WorkspaceVisionFileResolver resolver = await resolverFor(
        (String agentId) async => io,
      );
      addTearDown(resolver.close);

      expect(
        await resolver.resolve(
          config: _config(api.baseUrl),
          agentId: 'agt_ssh',
          attachment: _imageAttachment(),
        ),
        isNull,
      );
      expect(api.requests, isEmpty);
    });

    test('只有 WorkspaceIO（无 WorkspaceFiles）：走 base64 退化读取', () async {
      final _Base64OnlyIo io = _Base64OnlyIo(
        root: '/home/u/ws/a1',
        bytes: _pngBytes,
      );
      final WorkspaceVisionFileResolver resolver = await resolverFor(
        (String agentId) async => io,
      );
      addTearDown(resolver.close);

      expect(
        (await resolver.resolve(
          config: _config(api.baseUrl),
          agentId: 'agt_1',
          attachment: _imageAttachment(),
        ))?.fileId,
        'file-api-xyz',
      );
      expect(api.requests, hasLength(1));
    });

    test('非图像附件 / 超限 / 空路径：不读字节、不发请求', () async {
      final _FakeIo io = _FakeIo(
        root: '/ws',
        files: <String, List<int>>{'.input/20261001/报告.pdf': _pngBytes},
      );
      final WorkspaceVisionFileResolver resolver = await resolverFor(
        (String agentId) async => io,
      );
      addTearDown(resolver.close);
      final CoreModelConfig config = _config(api.baseUrl);

      expect(
        await resolver.resolve(
          config: config,
          agentId: 'agt_1',
          attachment: <String, dynamic>{
            'name': '报告.pdf',
            'path': '.input/20261001/报告.pdf',
            'size': 11,
            'type': 'pdf',
          },
        ),
        isNull,
      );
      expect(
        await resolver.resolve(
          config: config,
          agentId: 'agt_1',
          attachment: _imageAttachment(size: visionMaxFileBytes + 1),
        ),
        isNull,
      );
      expect(
        await resolver.resolve(
          config: config,
          agentId: 'agt_1',
          attachment: <String, dynamic>{'type': 'png', 'path': '  '},
        ),
        isNull,
      );
      expect(io.readBytesCalls, 0);
      expect(api.requests, isEmpty);
    });

    test('模型缺 base_url / api_key：不发请求，直接内联 base64（照样送得出去）', () async {
      final _FakeIo io = _FakeIo(
        root: '/ws',
        files: <String, List<int>>{'.input/20261001/图片.png': _pngBytes},
      );
      final List<String> logs = <String>[];
      final WorkspaceVisionFileResolver resolver = await resolverFor(
        (String agentId) async => io,
        logs: logs,
      );
      addTearDown(resolver.close);

      final VisionImageRef? ref = await resolver.resolve(
        config: CoreModelConfig(modelId: 'm', ifVision: true),
        agentId: 'agt_1',
        attachment: _imageAttachment(),
      );

      // 没有上传端点可打 ⇒ 走内联：模型仍看得见像素（不再只剩路径）
      expect(ref?.isFile, isFalse);
      expect(ref?.base64, base64Encode(_pngBytes));
      expect(api.requests, isEmpty);
      expect(logs.join('\n'), contains('base_url'));
      expect(logs.join('\n'), contains('回退为内联 base64'));
    });

    test('端点不支持 Files API（400）：回退内联 base64，形状与 MIME 都对', () async {
      api = FakeFilesApi(
        statusCode: 400,
        body:
            '{"error":{"code":"","message":"Model name not specified, '
            'model name cannot be empty","type":"new_api_error"}}',
      );
      await api.start();
      final _FakeIo io = _FakeIo(
        root: '/ws',
        files: <String, List<int>>{'.input/20261001/图片.png': _pngBytes},
      );
      final List<String> logs = <String>[];
      final WorkspaceVisionFileResolver resolver = WorkspaceVisionFileResolver(
        ioFor: (String agentId) async => io,
        log: logs.add,
      );
      addTearDown(resolver.close);

      final VisionImageRef? ref = await resolver.resolve(
        config: _config(api.baseUrl),
        agentId: 'agt_1',
        attachment: _imageAttachment(),
      );

      expect(ref?.isFile, isFalse, reason: '上传失败 ⇒ 不是 file 引用');
      expect(ref?.base64, base64Encode(_pngBytes));
      expect(ref?.contentType, 'image/png');
      expect(
        ref?.dataUrl,
        'data:image/png;base64,${base64Encode(_pngBytes)}',
        reason: '内联块的 URL 就是 data URL（形状依据见 LlmContentPart.imageUrl）',
      );
      expect(api.requests, hasLength(1), reason: '先试上传，失败才回退');
      expect(logs.join('\n'), contains('HTTP 400'));
      expect(logs.join('\n'), contains('回退为内联 base64'));
      expect(logs.join('\n'), isNot(contains('sk-test')));
    });

    test('网络错（端点连不上）：同样回退内联 base64', () async {
      api = FakeFilesApi();
      await api.start();
      final String baseUrl = api.baseUrl;
      await api.close(); // 关掉假端点 ⇒ 连接被拒（真实网络错的等价物）
      final _FakeIo io = _FakeIo(
        root: '/ws',
        files: <String, List<int>>{'.input/20261001/图片.png': _pngBytes},
      );
      final List<String> logs = <String>[];
      final WorkspaceVisionFileResolver resolver = WorkspaceVisionFileResolver(
        ioFor: (String agentId) async => io,
        log: logs.add,
      );
      addTearDown(resolver.close);

      final VisionImageRef? ref = await resolver.resolve(
        config: _config(baseUrl),
        agentId: 'agt_1',
        attachment: _imageAttachment(),
      );

      expect(ref?.isFile, isFalse);
      expect(ref?.base64, base64Encode(_pngBytes));
      expect(logs.join('\n'), contains('回退为内联 base64'));
    });

    test('上传失败且超过内联上限：降级为路径提示（返回 null，不发请求）', () async {
      api = FakeFilesApi(statusCode: 400, body: '{"error":{}}');
      await api.start();
      final _FakeIo io = _FakeIo(
        root: '/ws',
        files: <String, List<int>>{'.input/20261001/图片.png': _pngBytes},
      );
      final List<String> logs = <String>[];
      final WorkspaceVisionFileResolver resolver = WorkspaceVisionFileResolver(
        ioFor: (String agentId) async => io,
        log: logs.add,
        maxInlineBytes: 4, // 真上限是 32 MiB，这里用小值触发这条分支
      );
      addTearDown(resolver.close);

      expect(
        await resolver.resolve(
          config: _config(api.baseUrl),
          agentId: 'agt_1',
          attachment: _imageAttachment(),
        ),
        isNull,
      );
      expect(logs.join('\n'), contains('超过内联上限'));
    });
  });
}
