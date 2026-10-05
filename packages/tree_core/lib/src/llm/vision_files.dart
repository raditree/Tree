/// **图像附件的"上传—引用"链路**（`if_vision` 的真正实现）。
///
/// 背景：`if_vision` 曾经只是个来回序列化的死字段——用户勾了它，请求体里
/// 依然只有"图片在工作空间的路径"，模型看不到任何像素（只能说"我拿不到图"）。
/// 本文件补上这条路：**先把图片上传到端点拿到 `file_id`，再在 chat 请求的
/// user 消息里用 `{"type":"file","file_id":...}` 引用**（见
/// `llm/llm_types.dart` 的 [LlmContentPart]）。
///
/// **`file_id` 是内容块的同级字段**（不是 OpenAI 那种 `{"file":{"file_id":…}}`
/// 嵌套）——真端点实测：嵌套形状一律 400
/// `file must have a file_id or file_data`，扁平形状 200 且模型看得见图。
/// 上传成功却一直 400 的根因就在这里，与密钥 / multipart / 缓存都无关。
///
/// **两条送达路径（优先级从高到低）**：[VisionImageRef] 就是这条约定的载体。
/// 1. **Files API（首选）**：`POST {base}/files` 拿 `file_id` → `file` 内容块。
///    单文件可到 **64 MiB**，同一张图可跨轮复用（我们做 `file_id` 缓存），
///    且不占请求体；
/// 2. **内联 base64（回退）**：端点不支持 Files API，或上传失败（非 2xx、网络错、
///    响应里没有 `id`、缺 `base_url`/`api_key`）时，改成把图像字节**内联**进请求
///    （`{"type":"image_url","image_url":{"url":"data:<mime>;base64,…"}}`，依据见
///    `llm/llm_types.dart` 的 [LlmContentPart.imageUrl]）。内联受官方限制
///    **单张 ≤ 32 MiB / 请求体 ≤ 48 MiB**（[visionMaxInlineBytes]），超限宁可
///    退回"只给路径"，也绝不把整轮请求撑爆。
///
/// `model` 字段：**保留，但别把它当成那次 400 的解药**——2026-10-05 在本机真机
/// 探针实测（探针 = 同一张 70 字节 PNG，只打 `/files`，不发 chat）：
/// - `token.ai-galaxy.com/v1`（new-api 中转站）的 `/files` 三种带法——**不带**、
///   **表单带 `model`**、**查询串带 `model`**——**一律 400**
///   `Model name not specified, model name cannot be empty`（`type: new_api_error`）
///   ⇒ **它就是不吃这个接口**，换字段位置也救不了；真实链路里图能送到模型，
///   靠的是上面第 2 条**内联 base64 回退**（那次事故的正解）；
/// - 官方 `api.deepseek.com`：不带 `model` 成功（基线），**带 `model` 也成功**
///   （未知表单字段被忽略）⇒ 带上它是**无害**的（某些 new-api 变体确实要它），
///   不引入回归。
///
/// **为什么会 400（new-api 侧源码，已核对其 main 分支）**：
/// ① `router/relay-router.go` 把 `POST /v1/files`（连同 `GET /v1/files*`）登记为
///    `controller.RelayNotImplemented`——**Files API 它压根没实现**；
/// ② `middleware/distributor.go` 的 `getModelRequest()` 只在
///    `!strings.Contains(Content-Type, "multipart/form-data")` 时才去解析模型，也就是
///    **对 multipart 请求根本不读表单字段**，模型名恒为空 ⇒ 中间件报
///    `i18n.MsgDistributorModelNameRequired`（就是我们看到的那句 400），而且这发生在
///    进 handler **之前**（所以连"未实现"那条路都轮不到）。
/// 两条合起来：这类中转站上**换任何字段位置都救不了**——能救场的只有内联回退。
///
/// 模型名取该 agent 解析出的模型配置的 `model_id`（[CoreModelConfig.modelId]），
/// **不硬编码**。
///
/// 三条硬约束（都是踩过的坑，改这里之前先读）：
/// 1. **只读工作空间 IO，不拼本机绝对路径**：SSH 成员的图片在**远端**，本机
///    根本没有这个文件（见 [WorkspaceVisionFileResolver]）；
/// 2. **失败一律降级**，绝不阻断本轮：上传失败 → **回退内联 base64**；连字节都
///    读不到 / 非图片 / 超内联上限 → 返回 null，调用方继续用"提示词里给路径"
///    的老路径。**任何情况都不抛、不中断本轮对话**；
/// 3. **密钥只进 Authorization 头**：日志里只出现端点、字节数、形状与 file_id，
///    绝不出现 api_key 与文件字节。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:tree_local_exec/tree_local_exec.dart';

import '../settings/core_settings.dart';
import '../store/atomic_file.dart';

/// 单个文件的字节上限（DeepSeek Files API 口径：64 MiB）。
const int visionMaxFileBytes = 64 * 1024 * 1024;

/// **内联 base64 图像**的字节上限（官方 Vision 口径：单张内联图 ≤ 32 MiB）。
///
/// 为什么单独设一个更小的上限：内联会把 base64（约为原字节的 4/3）直接放进
/// 请求体，而端点对请求体还有 48 MiB 的硬限制。一张 32 MiB 的图编码后≈42.7 MiB，
/// 已逼近该限制；**超过就不再内联**，退回"只给路径"——宁可模型少看一张图，
/// 也不能把整轮请求打成 400（那会比改动前更糟）。
const int visionMaxInlineBytes = 32 * 1024 * 1024;

/// 构造内联图像的 data URL：`data:<mime>;base64,<bytes>`（形状依据见
/// `llm/llm_types.dart` 的 [LlmContentPart.imageUrl]）。
///
/// 抽成纯函数的理由与 multipart 一样：让"字节 → 线上形状"这件事可单测，
/// 且全仓只有这一处拼 data URL 前缀。
String visionDataUrl({required String base64, required String contentType}) {
  final String mime = contentType.trim().isEmpty
      ? 'application/octet-stream'
      : contentType.trim();
  return 'data:$mime;base64,$base64';
}

/// 上传有效期（秒）。文档允许 3600 ~ 2592000，这里按需求取 7 天。
const int visionDefaultExpiresSeconds = 7 * 24 * 60 * 60;

/// 上传超时（文档要求 10 分钟内完成）。
const Duration visionUploadTimeout = Duration(minutes: 10);

/// 支持的图像扩展名（文档：JPEG / PNG / GIF / WebP，按实际内容判断，这里按扩展名预筛）。
const Set<String> visionImageExtensions = <String>{
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
};

/// Files API 端点：`{base}/files`（口径与 [OpenAiCodec.endpointFor] 一致）。
///
/// 已含 `/files` 时原样返回，避免出现 `/files/files`；`base_url` 为空时返回相对
/// 路径 `/files`（与 codec 的兜底一致，便于测试与诊断）。
String visionFilesEndpointFor(String baseUrl) {
  final String base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty) return '/files';
  if (base.endsWith('/files')) return base;
  return '$base/files';
}

/// 附件的图像扩展名（小写）。优先看前端给的 `type`，缺失时从 `name`/`path` 推断。
String visionAttachmentExtension(Map<String, dynamic> attachment) {
  final String rawType = (attachment['type'] ?? '').toString().trim();
  if (rawType.isNotEmpty) {
    final int dot = rawType.lastIndexOf('.');
    return (dot >= 0 ? rawType.substring(dot + 1) : rawType).toLowerCase();
  }
  for (final String key in <String>['name', 'path']) {
    final String value = (attachment[key] ?? '').toString().trim();
    if (value.isEmpty) continue;
    final String name = value.replaceAll('\\', '/').split('/').last;
    final int dot = name.lastIndexOf('.');
    if (dot > 0 && dot < name.length - 1) {
      return name.substring(dot + 1).toLowerCase();
    }
  }
  return '';
}

/// 该附件是否按图像走"上传 + file_id 引用"。
///
/// 非图片（pdf/txt/zip…）继续只给路径：DeepSeek 的 file 内容块口径就是图像，
/// 把别的类型塞进去只会换来 400。
bool isVisionImageAttachment(Map<String, dynamic> attachment) =>
    visionImageExtensions.contains(visionAttachmentExtension(attachment));

/// 图像扩展名 → MIME（端点用它判断文件类型，不能漏）。
String visionContentType(String extension) => switch (extension) {
  'png' => 'image/png',
  'jpg' || 'jpeg' => 'image/jpeg',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  _ => 'application/octet-stream',
};

/// file_id 缓存的键。
///
/// **必须带工作空间身份（[WorkspaceIO.root]）**：SSH 成员的 `root` 是远端目录，
/// 本地成员是规范化后的本机目录。少了这一段，换 SSH 主机（或换工作空间目录）后
/// 同一个 `(agentId, path, size)` 会命中**另一台机器上**的旧 file_id —— 用户看到
/// 的就是"我发的明明是另一张图，模型却答的是老图"。
String visionCacheKey({
  required String baseUrl,
  required String workspaceRoot,
  required String path,
  required int size,
}) => '${baseUrl.trim()}|${workspaceRoot.trim()}|${path.trim()}|$size';

/// 一份手写好的 multipart 请求体（把纯函数与网络分开，便于单测断言字节）。
class VisionMultipartBody {
  const VisionMultipartBody({
    required this.boundary,
    required this.contentType,
    required this.body,
  });

  /// multipart 边界（同时出现在 header 与 body 里）。
  final String boundary;

  /// 完整的 `Content-Type` 头值（含 boundary）。
  final String contentType;

  /// 请求体字节。
  final List<int> body;
}

/// 构造 Files API 的 multipart 请求体（**纯函数**）。
///
/// 字段顺序：`purpose` → `model`（非空时才带）→ `expires_after[anchor]` →
/// `expires_after[seconds]` → `file`。[expiresAfterSeconds] <= 0 时不带有效期字段
/// （文档：不传即永久有效）。
///
/// **`model` 字段不是"不带就 400"的解药**：2026-10-05 真机探针对
/// `token.ai-galaxy.com/v1` 的 `/files` 试了不带 / 表单带 / 查询串带三种，
/// **全部 400** `Model name not specified`（详见文件头）；官方 `api.deepseek.com`
/// 不带与带都成功（字段被忽略）。保留它是为了兼容"确实要求该字段"的 new-api 变体，
/// 并对官方端点零回归；[modelId] 为空（模型名未知）时不发该字段——与改动前逐字一致。
VisionMultipartBody visionMultipartBody({
  required List<int> bytes,
  required String filename,
  required String contentType,
  String modelId = '',
  int expiresAfterSeconds = visionDefaultExpiresSeconds,
  String purpose = 'user_data',
  String? boundary,
}) {
  final String mark = boundary ?? _newBoundary();
  final BytesBuilder builder = BytesBuilder(copy: false);

  void field(String name, String value) {
    builder.add(
      utf8.encode(
        '--$mark\r\n'
        'Content-Disposition: form-data; name="$name"\r\n\r\n'
        '$value\r\n',
      ),
    );
  }

  field('purpose', purpose);
  final String model = modelId.trim();
  if (model.isNotEmpty) field('model', model);
  if (expiresAfterSeconds > 0) {
    field('expires_after[anchor]', 'created_at');
    field('expires_after[seconds]', '$expiresAfterSeconds');
  }

  final String safeName = _asciiFilename(filename);
  final String disposition = safeName == filename
      ? 'Content-Disposition: form-data; name="file"; filename="$safeName"\r\n'
      // 中文文件名：ASCII 版给不接受 RFC 5987 的解析器兜底，filename* 给正规解析器
      : 'Content-Disposition: form-data; name="file"; filename="$safeName"; '
            "filename*=UTF-8''${Uri.encodeComponent(filename)}\r\n";
  builder.add(
    utf8.encode('--$mark\r\n${disposition}Content-Type: $contentType\r\n\r\n'),
  );
  builder.add(bytes);
  builder.add(utf8.encode('\r\n--$mark--\r\n'));

  return VisionMultipartBody(
    boundary: mark,
    contentType: 'multipart/form-data; boundary=$mark',
    body: builder.takeBytes(),
  );
}

/// 把文件名压成可安全放进 header 的 ASCII 形态（保留扩展名；非法字符换 `_`）。
///
/// 为什么不能直接塞原始文件名：非 ASCII 字节在 header 里是未定义行为，中文文件名
/// 会让一部分解析器直接报错——而这个 header 只是"给文件起个名"，坏了不值当。
String _asciiFilename(String raw) {
  final String base = raw.replaceAll('\\', '/').split('/').last.trim();
  final StringBuffer out = StringBuffer();
  for (final int unit in base.codeUnits) {
    final bool printable = unit >= 0x20 && unit < 0x7f;
    final bool illegal = unit == 0x22 /* " */ || unit == 0x5c /* \ */;
    out.writeCharCode(printable && !illegal ? unit : 0x5f /* _ */);
  }
  final String safe = out.toString().trim();
  return safe.isEmpty ? 'upload' : safe;
}

String _newBoundary() =>
    '----treevision'
    '${Random().nextInt(0x7fffffff).toRadixString(16)}'
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

/// 往端点上传一个文件，返回 `file_id`（失败返回 null 并记日志，不抛）。
class VisionFileUploader {
  VisionFileUploader({
    required this.baseUrl,
    required this.apiKey,
    this.modelId = '',
    HttpClient? client,
    this.log,
    this.maxBytes = visionMaxFileBytes,
    this.timeout = visionUploadTimeout,
    this.expiresAfterSeconds = visionDefaultExpiresSeconds,
  }) : _client = client ?? HttpClient(),
       _ownsClient = client == null;

  /// 模型配置里的 `base_url`。
  final String baseUrl;

  /// 模型配置里的 `api_key`（**只进 Authorization 头，不进日志**）。
  final String apiKey;

  /// 模型配置里的 `model_id`（**中转站的 `/files` 要求表单带它**，见文件头）。
  ///
  /// 为空时不发该字段（官方端点无需、旧行为保持）。取值来自
  /// `CoreModelConfig.modelId`，由调用方（[WorkspaceVisionFileResolver]）注入，
  /// **不在这里硬编码任何模型名**。
  final String modelId;

  /// 可读日志（核心走 stderr）。
  final void Function(String message)? log;

  /// 字节上限。
  final int maxBytes;

  /// 单次请求超时（建连 + 上传 + 读响应）。
  final Duration timeout;

  /// 有效期（秒）。
  final int expiresAfterSeconds;

  final HttpClient _client;
  final bool _ownsClient;
  bool _closed = false;

  /// 上传一个文件；成功返回 `file_id`。
  ///
  /// 失败（缺配置 / 超限 / 网络错 / 非 2xx / 响应里没有 `id`）一律返回 null：
  /// 调用方据此降级为"提示词给路径"，本轮对话不受影响。
  Future<String?> upload({
    required List<int> bytes,
    required String filename,
    required String contentType,
  }) async {
    if (_closed) {
      _log('上传器已关闭，跳过上传');
      return null;
    }
    if (baseUrl.trim().isEmpty || apiKey.trim().isEmpty) {
      _log('缺少 base_url 或 api_key，无法上传图像');
      return null;
    }
    if (bytes.isEmpty) {
      _log('文件「$filename」是空文件，跳过上传');
      return null;
    }
    if (bytes.length > maxBytes) {
      _log('文件「$filename」${bytes.length} 字节超过上限 $maxBytes，跳过上传');
      return null;
    }

    final Uri uri = Uri.parse(visionFilesEndpointFor(baseUrl));
    final VisionMultipartBody multipart = visionMultipartBody(
      bytes: bytes,
      filename: filename,
      contentType: contentType,
      modelId: modelId,
      expiresAfterSeconds: expiresAfterSeconds,
    );
    try {
      final HttpClientRequest request = await _client
          .postUrl(uri)
          .timeout(timeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.headers.set(HttpHeaders.contentTypeHeader, multipart.contentType);
      request.headers.contentLength = multipart.body.length;
      request.add(multipart.body);
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final String body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // 端点原文对用户有诊断价值（密钥无效 / 格式不支持 / 超限），截断防刷屏
        _log('上传失败：HTTP ${response.statusCode} ${_clip(body)}');
        return null;
      }
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) {
        _log('上传响应不是 JSON 对象：${_clip(body)}');
        return null;
      }
      final Object? id = decoded['id'];
      if (id is! String || id.trim().isEmpty) {
        _log('上传响应里没有 file_id：${_clip(body)}');
        return null;
      }
      _log('图像已上传（${bytes.length} 字节）→ ${id.trim()}');
      return id.trim();
    } catch (error) {
      _log('上传异常：${_brief(error)}');
      return null;
    }
  }

  /// 释放底层连接（幂等）。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close(force: true);
  }

  void _log(String message) => log?.call('[vision] $message');
}

/// file_id 的**跨轮缓存**（同一个文件不重复上传）。
///
/// 为什么必须持久化：`_buildMessages` 每一轮都会重新装配（工具循环里还会重建），
/// 不缓存就等于每轮把整张图重传一遍——既慢又白烧配额。
///
/// 存储形态是"人类可读可删"的 JSON（与仓库其它落盘一致）：
/// ```json
/// {"<key>": {"file_id": "file-api-xxx", "uploaded_at": 1790839500000}}
/// ```
/// 删掉这个文件只会让下一次请求重新上传，没有任何其它副作用。
class VisionFileCache {
  VisionFileCache({
    this.file,
    this.ttl = const Duration(days: 6),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 落盘路径；null = 只走内存（测试与无盘场景）。
  final String? file;

  /// 缓存有效期。默认 6 天：**早于**服务端 7 天过期，避免"缓存还在、端点已删"。
  final Duration ttl;

  final DateTime Function() _now;
  final Map<String, Map<String, dynamic>> _entries =
      <String, Map<String, dynamic>>{};
  bool _loaded = false;

  /// 取缓存里的 file_id（不存在 / 已过期 / 记录损坏 → null）。
  Future<String?> get(String key) async {
    await _load();
    final Map<String, dynamic>? entry = _entries[key];
    if (entry == null) return null;
    final Object? id = entry['file_id'];
    final Object? uploadedAt = entry['uploaded_at'];
    if (id is! String || id.trim().isEmpty || uploadedAt is! num) {
      _entries.remove(key);
      return null;
    }
    final DateTime stamp = DateTime.fromMillisecondsSinceEpoch(
      uploadedAt.toInt(),
    );
    if (_now().difference(stamp) > ttl) {
      // 过期不是错误：下次请求重新上传即可（顺手把死记录清掉）
      _entries.remove(key);
      await _save();
      return null;
    }
    return id;
  }

  /// 记一条 file_id。
  Future<void> put(String key, String fileId) async {
    await _load();
    _entries[key] = <String, dynamic>{
      'file_id': fileId,
      'uploaded_at': _now().millisecondsSinceEpoch,
    };
    await _save();
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final String? path = file;
    if (path == null) return;
    final String? text = await AtomicFile.readStringOrNull(path);
    if (text == null || text.trim().isEmpty) return;
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map) return;
      for (final MapEntry<Object?, Object?> entry in decoded.entries) {
        final String key = entry.key?.toString() ?? '';
        final Object? value = entry.value;
        if (key.isEmpty || value is! Map) continue;
        _entries[key] = <String, dynamic>{
          'file_id': (value['file_id'] ?? '').toString(),
          'uploaded_at': (value['uploaded_at'] as num?)?.toInt() ?? 0,
        };
      }
    } catch (_) {
      // 缓存坏了不该影响对话：当作空缓存（下一次上传会重写这个文件）
    }
  }

  Future<void> _save() async {
    final String? path = file;
    if (path == null) return;
    try {
      await AtomicFile.writeStringAtomic(path, jsonEncode(_entries));
    } catch (_) {
      // 落盘失败只影响"少一次复用"，不影响本轮结果
    }
  }
}

/// 一张图像**怎样送达端点**：能用 Files API 就用 `file_id` 引用，否则内联 base64。
///
/// 这就是"两条送达路径"的载体（见文件头）：引擎按变体产出不同的内容块，
/// 自己完全不需要知道上传细节，也不需要认识 HTTP。
class VisionImageRef {
  /// 端点文件引用（Files API 上传成功）。
  const VisionImageRef.file(this.fileId) : base64 = '', contentType = '';

  /// 内联 base64 图像（Files API 走不通时的回退）。
  const VisionImageRef.inline({
    required this.base64,
    required this.contentType,
  }) : fileId = '';

  /// 端点文件 id（空 = 这条不是 file 引用）。
  final String fileId;

  /// 内联图像的原始 base64（不含 data URL 前缀）。
  final String base64;

  /// 内联图像的 MIME（`image/png` 等）。
  final String contentType;

  /// 是否走 `file_id` 引用（false 表示内联 base64）。
  bool get isFile => fileId.isNotEmpty;

  /// 内联图像的 data URL（形状依据见 `llm/llm_types.dart` 的
  /// [LlmContentPart.imageUrl]）；file 引用时为空串。
  String get dataUrl => isFile
      ? ''
      : visionDataUrl(base64: base64, contentType: contentType);

  /// 这个引用**什么也送不出去**（引擎据此跳过，别产出空内容块）。
  bool get isEmpty => fileId.isEmpty && base64.isEmpty;

  @override
  String toString() => isFile
      ? 'VisionImageRef.file($fileId)'
      : 'VisionImageRef.inline(${base64.length} 字节 base64, $contentType)';
}

/// 把"某条用户消息里的图像附件"解析成端点能收的**图像引用**（注入点）。
///
/// 引擎只认这个接口：`if_vision` 打开且解析出引用时，就把它变成内容块（`file_id`
/// 引用或内联 base64）；返回 null（读不到字节 / 非图片 / 超限）就照旧只发路径。
/// 这样引擎可以完全脱离 HTTP 单测。
///
/// **失败不抛、不阻断本轮**是这条接口的约定（见文件头硬约束 2）：解析不出来就是
/// null，调用方降级。
abstract interface class VisionFileResolver {
  /// 解析该附件的图像引用。
  ///
  /// 返回 `VisionImageRef.file` = 已上传（首选路径）；`VisionImageRef.inline` =
  /// 上传失败/不支持，改走内联 base64；返回 null = 本轮降级为"只给路径"。
  Future<VisionImageRef?> resolve({
    required CoreModelConfig config,
    required String agentId,
    required Map<String, dynamic> attachment,
  });

  /// 释放资源（幂等）。
  Future<void> close();
}

/// 工作空间 → 端点 的默认实现（生产用）。
///
/// 与工具层共用同一份工作空间 IO（[ioFor] 就是
/// `WorkspaceToolRunner.ioFor`）：本地模式读本机目录，SSH 模式走 SFTP 读**远端**
/// 工作空间——图片在哪台机器上，这里就跟着去哪台机器读，绝不拼本机绝对路径。
class WorkspaceVisionFileResolver implements VisionFileResolver {
  WorkspaceVisionFileResolver({
    required this.ioFor,
    this.cache,
    this.log,
    this.maxBytes = visionMaxFileBytes,
    this.maxInlineBytes = visionMaxInlineBytes,
    this.timeout = visionUploadTimeout,
    this.expiresAfterSeconds = visionDefaultExpiresSeconds,
  });

  /// 取该 agent 的工作空间 IO（null = 工作空间不可用，例如 SSH 未配置完整）。
  final Future<WorkspaceIO?> Function(String agentId) ioFor;

  /// file_id 缓存（null = 不缓存，每次都传）。
  final VisionFileCache? cache;

  /// 可读日志。
  final void Function(String message)? log;

  final int maxBytes;

  /// **内联**图像的字节上限（默认 [visionMaxInlineBytes]；0 = 不限）。
  ///
  /// 可注入只为单测能拿小值触发这条分支——真上限是官方口径（单张 32 MiB）。
  final int maxInlineBytes;

  final Duration timeout;
  final int expiresAfterSeconds;

  /// 按 `baseUrl|apiKey` 复用上传器（换模型不重建连接池）。
  final Map<String, VisionFileUploader> _uploaders =
      <String, VisionFileUploader>{};

  bool _closed = false;

  @override
  Future<VisionImageRef?> resolve({
    required CoreModelConfig config,
    required String agentId,
    required Map<String, dynamic> attachment,
  }) async {
    if (_closed) return null;
    if (!isVisionImageAttachment(attachment)) return null;
    final String path = (attachment['path'] ?? '').toString().trim();
    if (path.isEmpty) return null;
    final int size = (attachment['size'] as num?)?.toInt() ?? 0;
    if (maxBytes > 0 && size > maxBytes) {
      _log('附件「$path」$size 字节超过上限 $maxBytes，降级为路径提示');
      return null;
    }

    final WorkspaceIO? io;
    try {
      io = await ioFor(agentId);
    } catch (error) {
      // ioFor 自身可能撞上"SSH 连接建立失败"这类异常：降级，不阻断本轮
      _logReadFailure(agentId, path, error);
      return null;
    }
    if (io == null) {
      _log(
        'agent $agentId 的工作空间不可用（SSH 未配置完整或连接失败），'
        '本轮降级为路径提示',
      );
      return null;
    }

    final String key = visionCacheKey(
      baseUrl: config.baseUrl,
      workspaceRoot: io.root,
      path: path,
      size: size,
    );
    final String? cached = await cache?.get(key);
    if (cached != null) return VisionImageRef.file(cached);

    final Uint8List bytes;
    try {
      bytes = await _readBytes(io, path);
    } catch (error) {
      _logReadFailure(agentId, path, error);
      return null;
    }
    if (bytes.isEmpty) {
      _log('附件「$path」是空文件，降级为路径提示');
      return null;
    }
    if (maxBytes > 0 && bytes.length > maxBytes) {
      _log('附件「$path」${bytes.length} 字节超过上限 $maxBytes，降级为路径提示');
      return null;
    }

    final String extension = visionAttachmentExtension(attachment);
    final String contentType = visionContentType(
      extension.isEmpty ? 'png' : extension,
    );

    // ① 首选：Files API 上传 → file_id 引用（同一张图可跨轮复用，不做重复编码）。
    final VisionFileUploader? uploader = _uploaderFor(config);
    if (uploader == null) {
      _log('模型「${config.modelId}」缺少 base_url / api_key，无法上传图像');
    } else {
      final String? fileId = await uploader.upload(
        bytes: bytes,
        filename: _fileNameOf(attachment, path),
        contentType: contentType,
      );
      if (fileId != null) {
        await cache?.put(key, fileId);
        return VisionImageRef.file(fileId);
      }
    }
    _log('上传不可用（端点不支持 Files API 或本张图上传失败），回退为内联 base64');

    // ② 回退：内联 base64（端点不收 file 块时，这是唯一还能让模型看见像素的形态）。
    if (maxInlineBytes > 0 && bytes.length > maxInlineBytes) {
      _log(
        '附件「$path」${bytes.length} 字节超过内联上限 $maxInlineBytes'
        '（官方口径单张 ≤ 32 MiB），本轮降级为路径提示',
      );
      return null;
    }
    _log(
      '内联图像「${_fileNameOf(attachment, path)}」'
      '（${bytes.length} 字节，$contentType）随请求体送达模型',
    );
    return VisionImageRef.inline(
      base64: base64Encode(bytes),
      contentType: contentType,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final VisionFileUploader uploader in _uploaders.values) {
      await uploader.close();
    }
    _uploaders.clear();
  }

  /// 取（或新建）该模型配置的上传器；缺 base_url / api_key 时返回 null。
  ///
  /// 复用键里带上 `modelId`：上传表单会发 `model`（对官方端点无害、对要求该字段的
  /// new-api 变体可能必需），同一 `base_url|api_key` 下的不同模型因此各持一个上传器。
  /// **file_id 缓存键不带 model**——file_id 属于"账号 + 端点"，与模型无关，
  /// 带上它只会让所有老缓存失效。
  VisionFileUploader? _uploaderFor(CoreModelConfig config) {
    final String baseUrl = config.baseUrl.trim();
    final String apiKey = config.apiKey.trim();
    if (baseUrl.isEmpty || apiKey.isEmpty) return null;
    final String modelId = config.modelId.trim();
    final String key = '$baseUrl|$apiKey|$modelId';
    return _uploaders.putIfAbsent(
      key,
      () => VisionFileUploader(
        baseUrl: baseUrl,
        apiKey: apiKey,
        modelId: modelId,
        log: log,
        maxBytes: maxBytes,
        timeout: timeout,
        expiresAfterSeconds: expiresAfterSeconds,
      ),
    );
  }

  /// 读原始字节：优先 [WorkspaceFiles.readBytes]（本地与 SSH 都实现了），
  /// 否则退回 [WorkspaceIO.readFile] 的 base64（图像走这条也会带 base64）。
  ///
  /// 用 `Object` 接收再判断，是因为 [WorkspaceIO] 与 [WorkspaceFiles] 是**并列**
  /// 接口（谁也不是谁的子类型），直接对 `WorkspaceIO` 做 `is WorkspaceFiles` 拿
  /// 不到可用的提升——`core_server.dart` 的 `remoteFilesFor` 出于同一原因这么写。
  Future<Uint8List> _readBytes(WorkspaceIO io, String path) async {
    final Object source = io;
    if (source is WorkspaceFiles) return source.readBytes(path);
    final FileContent content = await io.readFile(path);
    final String? base64 = content.base64;
    if (base64 == null || base64.isEmpty) {
      throw WorkspaceIoException('$path 不是二进制内容，无法作为图像上传');
    }
    return base64Decode(base64);
  }

  /// 读取失败要**分类说清**：SSH 链路失活与远端文件缺失的处理方式不同
  /// （前者多半是网络/心跳断了，重连后下一轮会自然重试；后者多半是文件被删或
  /// 被换，用户需要知道提示词里那条路径已经不是图片了）。
  void _logReadFailure(String agentId, String path, Object error) {
    if (error is SshLinkStaleException) {
      _log(
        '读取附件「$path」失败（agent $agentId）：SSH 链路失活——'
        '本轮降级为路径提示，链路恢复后下一轮会自动重试上传。',
      );
      return;
    }
    if (error is WorkspaceIoException) {
      _log('读取附件「$path」失败（agent $agentId）：${error.message}；本轮降级为路径提示');
      return;
    }
    _log(
      '读取附件「$path」失败（agent $agentId，${error.runtimeType}）：$error；'
      '本轮降级为路径提示',
    );
  }

  void _log(String message) => log?.call('[vision] $message');
}

/// 附件文件名（前端给了 `name` 就用它，否则从路径取末段）。
String _fileNameOf(Map<String, dynamic> attachment, String path) {
  final String name = (attachment['name'] ?? '').toString().trim();
  if (name.isNotEmpty) return name;
  final String normalized = path.replaceAll('\\', '/');
  final int idx = normalized.lastIndexOf('/');
  final String base = idx >= 0 ? normalized.substring(idx + 1) : normalized;
  return base.isEmpty ? 'upload' : base;
}

String _clip(String text, [int max = 300]) =>
    text.length <= max ? text : '${text.substring(0, max)}…';

/// 错误文案：只取类型与 message，避免异常 toString 里夹带超长栈或敏感内容。
String _brief(Object error) {
  if (error is WorkspaceIoException) return error.message;
  if (error is SocketException) return '网络错误：${error.message}';
  if (error is TimeoutException) return '超时（${error.duration}）';
  if (error is HttpException) return error.message;
  return error.toString();
}
