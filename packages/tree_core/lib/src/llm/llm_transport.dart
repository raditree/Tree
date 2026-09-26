import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'llm_types.dart';
import 'openai_codec.dart';
import 'sse_parser.dart';

/// LLM 传输层：把一次 [LlmRequest] 变成一串 [LlmStreamEvent]。
///
/// 抽象出这一层的目的：会话逻辑（上下文装配、工具循环、用量累计）与
/// "怎么跟端点说话"解耦。测试用假传输直接构造事件序列，无需网络；
/// 将来若要换成 `openai_dart`，也只是再实现一个本接口。
abstract interface class LlmTransport {
  /// 流式请求。[isCancelled] 在每帧后被检查，为真时尽快中断并释放连接。
  Stream<LlmStreamEvent> stream(
    LlmRequest request, {
    bool Function()? isCancelled,
  });

  /// 释放底层资源（幂等）。
  Future<void> close();
}

/// 基于 `dart:io HttpClient` 的 SSE 传输（OpenAI 兼容 `chat/completions`）。
///
/// 关注点：
/// - **连接/空闲超时**分开：连接超时短（10s），流内空闲超时长（120s）——
///   推理模型可能长时间不吐字，但不该无限等。
/// - **取消即断流**：退出 `await for` 会取消对响应流的订阅，Dart 会关闭该
///   连接，不再继续消耗端点配额。
/// - **错误可读**：非 200 时把响应体（截断）带进错误文案，便于用户直接看到
///   "密钥无效 / 模型不存在 / 余额不足"这类端点原文。
class HttpSseTransport implements LlmTransport {
  HttpSseTransport({
    required this.baseUrl,
    required this.apiKey,
    HttpClient? client,
    this.connectTimeout = const Duration(seconds: 10),
    this.idleTimeout = const Duration(seconds: 120),
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = connectTimeout;
  }

  /// 模型配置里的 base_url（如 `https://api.example.com/v1`）。
  final String baseUrl;

  /// API 密钥。
  final String apiKey;

  /// 建连超时。
  final Duration connectTimeout;

  /// 流内空闲超时（超过即判定端点卡死）。
  final Duration idleTimeout;

  final HttpClient _client;
  bool _closed = false;

  @override
  Stream<LlmStreamEvent> stream(
    LlmRequest request, {
    bool Function()? isCancelled,
  }) async* {
    if (_closed) {
      yield const LlmFailureEvent('传输层已关闭');
      return;
    }
    final Uri uri = Uri.parse(OpenAiCodec.endpointFor(baseUrl));
    final HttpClientRequest httpRequest;
    try {
      httpRequest = await _client.postUrl(uri).timeout(connectTimeout);
      httpRequest.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $apiKey',
      );
      httpRequest.headers.contentType = ContentType.json;
      httpRequest.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      httpRequest.add(
        utf8.encode(jsonEncode(OpenAiCodec.requestBody(request, stream: true))),
      );
    } catch (error) {
      yield LlmFailureEvent('无法连接模型端点 $uri：${_brief(error)}');
      return;
    }

    final HttpClientResponse response;
    try {
      response = await httpRequest.close().timeout(connectTimeout);
    } catch (error) {
      yield LlmFailureEvent('模型端点无响应（$uri）：${_brief(error)}');
      return;
    }

    if (response.statusCode != 200) {
      String body = '';
      try {
        body = await utf8.decoder.bind(response).join();
      } catch (_) {
        // 读不到响应体也无妨，状态码已经足够定位问题
      }
      yield LlmFailureEvent(
        '模型端点返回 HTTP ${response.statusCode}：${_brief(body)}',
        statusCode: response.statusCode,
      );
      return;
    }

    if (isCancelled?.call() ?? false) {
      yield const LlmFailureEvent('已取消', cancelled: true);
      return;
    }

    final SseParser parser = SseParser();
    final Stream<String> lines = response
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(
          idleTimeout,
          onTimeout: (EventSink<String> sink) {
            sink.addError(
              TimeoutException('模型端点 ${idleTimeout.inSeconds}s 内没有返回任何数据'),
            );
            sink.close();
          },
        );

    try {
      await for (final String line in lines) {
        final String? payload = parser.accept(line);
        if (payload == null) continue;
        if (payload.trim() == '[DONE]') break;
        for (final LlmStreamEvent event in OpenAiCodec.decodeChunk(payload)) {
          yield event;
        }
        if (isCancelled?.call() ?? false) {
          yield const LlmFailureEvent('已取消', cancelled: true);
          return;
        }
      }
    } on TimeoutException catch (error) {
      yield LlmFailureEvent('$error');
      return;
    } catch (error) {
      yield LlmFailureEvent('读取模型响应失败：${_brief(error)}');
      return;
    }

    // 部分端点省掉末尾空行：把残留数据当最后一个事件处理
    final String? tail = parser.flush();
    if (tail != null && tail.trim() != '[DONE]') {
      for (final LlmStreamEvent event in OpenAiCodec.decodeChunk(tail)) {
        yield event;
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }

  /// 把错误/响应体压成一行短文本（日志与 UI 都只该看到摘要）。
  static String _brief(Object? value, {int limit = 300}) {
    final String text = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= limit ? text : '${text.substring(0, limit)}…';
  }
}
