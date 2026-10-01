import 'dart:convert';
import 'dart:io';

/// 一次被 [FakeFilesApi] 收到的请求（测试断言用）。
class CapturedRequest {
  CapturedRequest(this.method, this.path, this.headers, this.body);

  final String method;
  final String path;
  final HttpHeaders headers;
  final List<int> body;

  /// body 的文本形态（multipart 里含二进制字节，按 allowMalformed 解码）。
  String get text => utf8.decode(body, allowMalformed: true);
}

/// 本地**假 Files API**：真的起一个 loopback HTTP 服务，只有端点是假的。
///
/// 为什么不用 mock 掉 HttpClient：这条链路的价值全在"请求到底长什么样"——
/// multipart 边界、`purpose=user_data`、字节是否原样、Authorization 头。
/// 用真 HTTP 才能把这些连同连接层一起验证（仓里 `files_api_test.dart` 同思路）。
class FakeFilesApi {
  FakeFilesApi({
    this.statusCode = 200,
    this.body = '{"id":"file-api-xyz","object":"file"}',
  });

  final int statusCode;
  final String body;
  final List<CapturedRequest> requests = <CapturedRequest>[];
  late HttpServer _server;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest request) async {
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in request) {
        bytes.addAll(chunk);
      }
      requests.add(
        CapturedRequest(
          request.method,
          request.uri.path,
          request.headers,
          bytes,
        ),
      );
      request.response.statusCode = statusCode;
      request.response.headers.contentType = ContentType.json;
      request.response.write(body);
      await request.response.close();
    });
  }

  /// 模型配置口径的 base_url（带 `/v1`）。
  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  Future<void> close() => _server.close(force: true);
}
