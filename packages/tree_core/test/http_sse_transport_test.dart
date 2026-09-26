import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 起一个**真实的** HTTP + SSE 假端点，验证传输层与 `dart:io` 的交互
/// （分片边界、非 200、流中错误、取消、空闲超时）——这些是假传输测不到的。
void main() {
  late HttpServer server;
  late int port;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    unawaited(() async {
      await for (final HttpRequest request in server) {
        await _handle(request);
      }
    }());
  });

  tearDown(() async {
    await server.close(force: true);
  });

  HttpSseTransport transport({
    Duration idleTimeout = const Duration(seconds: 5),
  }) => HttpSseTransport(
    baseUrl: 'http://127.0.0.1:$port/v1',
    apiKey: 'sk-test',
    idleTimeout: idleTimeout,
  );

  const LlmRequest request = LlmRequest(
    model: 'ok',
    messages: <LlmMessage>[LlmMessage.user('hi')],
  );

  test('正常流：正文/思考/工具/usage/[DONE] 全部解析；行被切在中间也能还原', () async {
    final List<LlmStreamEvent> events = await transport()
        .stream(
          const LlmRequest(
            model: 'split',
            messages: <LlmMessage>[LlmMessage.user('hi')],
          ),
        )
        .toList();
    final String text = events
        .whereType<LlmTextDelta>()
        .map((LlmTextDelta e) => e.text)
        .join();
    expect(text, '你好，我是被切开的');
    expect(events.whereType<LlmThinkingDelta>().single.text, '思考中');
    expect(events.whereType<LlmToolCallDelta>().single.name, 'read_file');
    expect(events.whereType<LlmUsageEvent>().single.usage.totalTokens, 42);
    expect((events.last as LlmFinishEvent).reason, 'stop');
  });

  test('HTTP 非 200：错误文案带状态码与端点响应体', () async {
    final List<LlmStreamEvent> events = await transport()
        .stream(
          const LlmRequest(
            model: 'unauthorized',
            messages: <LlmMessage>[LlmMessage.user('hi')],
          ),
        )
        .toList();
    final LlmFailureEvent failure = events.single as LlmFailureEvent;
    expect(failure.statusCode, 401);
    expect(failure.message, contains('401'));
    expect(failure.message, contains('invalid api key'));
  });

  test('流中 error 帧 → 失败事件（保留已收到的正文）', () async {
    final List<LlmStreamEvent> events = await transport()
        .stream(
          const LlmRequest(
            model: 'mid-error',
            messages: <LlmMessage>[LlmMessage.user('hi')],
          ),
        )
        .toList();
    expect(events.whereType<LlmTextDelta>().single.text, '开始');
    expect(
      (events.whereType<LlmFailureEvent>().single).message,
      contains('配额用尽'),
    );
  });

  test('连接被拒（端口无人监听）→ 可读的失败事件', () async {
    final HttpSseTransport dead = HttpSseTransport(
      baseUrl: 'http://127.0.0.1:1/v1',
      apiKey: 'k',
    );
    final List<LlmStreamEvent> events = await dead.stream(request).toList();
    expect(events.single, isA<LlmFailureEvent>());
    expect((events.single as LlmFailureEvent).message, contains('无法连接'));
    await dead.close();
  });

  test('空闲超时：端点长时间不返回数据 → 失败事件', () async {
    final List<LlmStreamEvent> events =
        await transport(idleTimeout: const Duration(milliseconds: 300))
            .stream(
              const LlmRequest(
                model: 'stall',
                messages: <LlmMessage>[LlmMessage.user('hi')],
              ),
            )
            .toList();
    expect((events.last as LlmFailureEvent).message, contains('没有返回任何数据'));
  });

  test('取消：返回值带 cancelled 标记，且流很快结束', () async {
    bool cancelled = false;
    final Stream<LlmStreamEvent> stream = transport().stream(
      const LlmRequest(
        model: 'endless',
        messages: <LlmMessage>[LlmMessage.user('hi')],
      ),
      isCancelled: () => cancelled,
    );
    final List<LlmStreamEvent> events = <LlmStreamEvent>[];
    await for (final LlmStreamEvent event in stream) {
      events.add(event);
      if (event is LlmTextDelta) cancelled = true; // 收到第一段就取消
    }
    expect(events.whereType<LlmFailureEvent>().single.cancelled, isTrue);
    expect(events.whereType<LlmTextDelta>(), hasLength(1));
  });

  test('关闭后再次调用直接失败（不抛异常）', () async {
    final HttpSseTransport t = transport();
    await t.close();
    final List<LlmStreamEvent> events = await t.stream(request).toList();
    expect(events.single, isA<LlmFailureEvent>());
  });
}

Future<void> _handle(HttpRequest request) async {
  final String body = await utf8.decoder.bind(request).join();
  final Map<String, dynamic> payload = body.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(body) as Map<String, dynamic>;
  final String model = payload['model'] as String? ?? '';

  switch (model) {
    case 'unauthorized':
      request.response.statusCode = 401;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, dynamic>{
          'error': <String, dynamic>{'message': 'invalid api key'},
        }),
      );
      await request.response.close();
      return;
    case 'stall':
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"content":"等"}}]}\n\n',
      );
      await request.response.flush();
      await Future<void>.delayed(const Duration(seconds: 5));
      await request.response.close();
      return;
    case 'endless':
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      for (int i = 0; i < 500; i++) {
        request.response.write(
          'data: {"choices":[{"delta":{"content":"第$i段"}}]}\n\n',
        );
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await request.response.close();
      return;
    case 'mid-error':
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"content":"开始"}}]}\n\n',
      );
      await request.response.flush();
      request.response.write('data: {"error":{"message":"配额用尽，请充值"}}\n\n');
      await request.response.flush();
      await request.response.close();
      return;
    case 'split':
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      // 故意把一行 data 切成两段写，模拟真实网络的任意分片
      const String line =
          'data: {"choices":[{"delta":{"content":"你好，我是被切开的"}}]}\n\n';
      request.response.add(utf8.encode(line.substring(0, 20)));
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      request.response.add(utf8.encode(line.substring(20)));
      await request.response.flush();
      // 思考 + 工具调用 + usage
      for (final String extra in <String>[
        'data: {"choices":[{"delta":{"reasoning_content":"思考中"}}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{}"}}]}}]}\n\n',
        'data: {"choices":[{"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":32,"total_tokens":42}}\n\n',
        'data: [DONE]\n\n',
      ]) {
        request.response.add(utf8.encode(extra));
        await request.response.flush();
      }
      await request.response.close();
      return;
    default:
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
  }
}
