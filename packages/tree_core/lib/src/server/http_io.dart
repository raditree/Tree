import 'dart:convert';
import 'dart:io';

/// 以 UTF-8 JSON 写回响应。
///
/// 前端 `ApiService._handleResponse` 强制按 UTF-8 解码 `bodyBytes`，
/// 因此这里必须自行 UTF-8 编码（`dart:io` 默认 latin-1 会毁掉中文）。
Future<void> writeJson(
  HttpRequest request,
  int statusCode,
  Object? body,
) async {
  final HttpResponse response = request.response;
  response.statusCode = statusCode;
  response.headers.contentType = ContentType(
    'application',
    'json',
    charset: 'utf-8',
  );
  response.add(utf8.encode(jsonEncode(body ?? <String, dynamic>{})));
  await response.close();
}

/// 读取并解析 JSON 请求体；空体返回空 Map。
///
/// 请求体非法 JSON 时抛 [FormatException]（调用方转 400）。
Future<Map<String, dynamic>> readJsonBody(HttpRequest request) async {
  final String raw = await utf8.decoder.bind(request).join();
  if (raw.trim().isEmpty) return <String, dynamic>{};
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('请求体必须是 JSON 对象');
  }
  return decoded;
}

/// 统一的 501 响应体：前端 `_handleResponse` 对 501 有专门文案（功能开发中）。
Map<String, dynamic> notImplementedBody(String path) => <String, dynamic>{
  'detail': '功能开发中：$path 尚未在核心进程实现',
};

/// 以原始字节写回（文件下载）：调用方给 content type 与可选文件名。
Future<void> writeBytes(
  HttpRequest request,
  int statusCode,
  List<int> bytes, {
  String contentType = 'application/octet-stream',
  String? filename,
}) async {
  final HttpResponse response = request.response;
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.parse(contentType);
  response.headers.contentLength = bytes.length;
  if (filename != null && filename.isNotEmpty) {
    // HTTP 头只能是 ASCII：中文文件名直接塞进 Content-Disposition 会被
    // `HttpHeaders.set` 以 FormatException 拒绝（真 exe 冒烟测试才暴露出来，
    // 表现为"连接被关掉"）。因此 ASCII 回退名 + RFC 5987 的 filename*。
    final String ascii = filename
        .replaceAll(RegExp(r'[^\x20-\x7e]'), '_')
        .replaceAll(RegExp(r'["\\]'), '_');
    response.headers.set(
      'content-disposition',
      'attachment; filename="$ascii"; '
          "filename*=UTF-8''${Uri.encodeComponent(filename)}",
    );
  }
  response.add(bytes);
  await response.close();
}

/// 统一的错误响应体。
Map<String, dynamic> errorBody(String message) => <String, dynamic>{
  'detail': message,
};
