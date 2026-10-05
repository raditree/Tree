// 一次性探针 v2：把「中转站 400 Model name not specified」逼到结论。
//
//  1) 中转站（token.ai-galaxy.com/v1）：不带 model / 表单带 model / **查询串带 model**
//  2) 官方端点（api.deepseek.com）：不带 model（基线）/ 表单带 model（回归检查）
//
// 只做文件上传（**不发任何 chat/completions**）；输出里**绝不**出现 api_key。
// 用完即删（不属于交付物）。
import 'dart:convert';
import 'dart:io';

import 'package:tree_core/tree_core.dart';

/// 1x1 透明 PNG。
const String _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Map<String, String> _readModelYaml(String path) {
  final Map<String, String> out = <String, String>{};
  for (final String line in File(path).readAsLinesSync()) {
    final int i = line.indexOf(':');
    if (i <= 0 || line.trimLeft().startsWith('#')) continue;
    final String key = line.substring(0, i).trim();
    String value = line.substring(i + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    out[key] = value;
  }
  return out;
}

String _home() => Platform.environment['APPDATA'] ?? '';

Future<void> _formUpload({
  required String label,
  required String baseUrl,
  required String apiKey,
  required String modelId,
  required List<int> bytes,
}) async {
  final VisionFileUploader uploader = VisionFileUploader(
    baseUrl: baseUrl,
    apiKey: apiKey,
    modelId: modelId,
    log: (String m) => stdout.writeln('     $m'),
  );
  final String? id = await uploader.upload(
    bytes: bytes,
    filename: 'probe.png',
    contentType: 'image/png',
  );
  stdout.writeln('  [$label] => ${id ?? 'null（失败）'}');
  await uploader.close();
}

/// 手搓一次「model 走查询串」的上传（uploader 不支持查询串）。
Future<void> _queryUpload({
  required String label,
  required String baseUrl,
  required String apiKey,
  required String modelId,
  required List<int> bytes,
}) async {
  final VisionMultipartBody body = visionMultipartBody(
    bytes: bytes,
    filename: 'probe.png',
    contentType: 'image/png',
  );
  final Uri uri = Uri.parse(
    '${visionFilesEndpointFor(baseUrl)}?model=${Uri.encodeQueryComponent(modelId)}',
  );
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client.postUrl(uri);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    req.headers.set(HttpHeaders.contentTypeHeader, body.contentType);
    req.headers.contentLength = body.body.length;
    req.add(body.body);
    final HttpClientResponse resp = await req.close();
    final String text = await utf8.decoder.bind(resp).join();
    stdout.writeln('  [$label] => HTTP ${resp.statusCode} ${text.substring(0, text.length > 200 ? 200 : text.length)}');
  } catch (error) {
    stdout.writeln('  [$label] => 异常 $error');
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  final List<int> bytes = base64Decode(_pngB64);
  stdout.writeln('探针图：${bytes.length} 字节 PNG；密钥只进 Authorization 头，不打印');

  final Map<String, String> relay = _readModelYaml(
    '${_home()}\\Tree\\config\\models\\deepseek-v4.1-flash.yaml',
  );
  final Map<String, String> official = _readModelYaml(
    '${_home()}\\Tree\\config\\models\\deepseek-flash.yaml',
  );

  stdout.writeln('\n== 1) 中转站 ${relay['base_url']}（模型 ${relay['model_id']}）==');
  await _formUpload(
    label: '不带 model',
    baseUrl: relay['base_url']!,
    apiKey: relay['api_key']!,
    modelId: '',
    bytes: bytes,
  );
  await _formUpload(
    label: '表单带 model',
    baseUrl: relay['base_url']!,
    apiKey: relay['api_key']!,
    modelId: relay['model_id']!,
    bytes: bytes,
  );
  await _queryUpload(
    label: '查询串带 model',
    baseUrl: relay['base_url']!,
    apiKey: relay['api_key']!,
    modelId: relay['model_id']!,
    bytes: bytes,
  );

  stdout.writeln('\n== 2) 官方 ${official['base_url']}（模型 ${official['model_id']}）==');
  await _formUpload(
    label: '不带 model（基线）',
    baseUrl: official['base_url']!,
    apiKey: official['api_key']!,
    modelId: '',
    bytes: bytes,
  );
  await _formUpload(
    label: '表单带 model（回归检查）',
    baseUrl: official['base_url']!,
    apiKey: official['api_key']!,
    modelId: official['model_id']!,
    bytes: bytes,
  );
}
