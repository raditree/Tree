import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// M9 规约 1.1（修正版）：LLM 传输**没有任何总时长上限**，判死只看**心跳丢失**。
///
/// 这些用例起一个真实 HTTP+SSE 假端点：
/// - 握手后彻底静默 ⇒ 连续 N 次心跳未达 ⇒ 以显式错误（含「心跳丢失」）结束；
/// - 每 50ms 吐一次数据的长响应（总时长远超静默窗口）⇒ 一个字节都不丢、不报错。
void main() {
  late HttpServer server;
  late int port;

  /// 假端点行为：`silent` = 握手后一言不发；`chatty` = 持续吐数据；
  /// `stall-after-first` = 先给一段再沉默。
  late String mode;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    unawaited(() async {
      await for (final HttpRequest request in server) {
        unawaited(_handle(request, mode));
      }
    }());
  });

  tearDown(() async {
    await server.close(force: true);
  });

  /// 心跳间隔 100ms × 允许丢 3 次 = 300ms 判失活（测试要快，所以把常量压小）。
  ///
  /// **关掉重试**：本文件测的是"一次尝试"的心跳判活；重试口径（含"心跳丢失算
  /// 可重试失败"）由 `http_sse_transport_test` 的『有限重试』组覆盖。
  HttpSseTransport transport() => HttpSseTransport(
    baseUrl: 'http://127.0.0.1:$port/v1',
    apiKey: 'sk-test',
    heartbeatInterval: const Duration(milliseconds: 100),
    missedHeartbeatLimit: 3,
    retryBackoff: const <Duration>[],
  );

  const LlmRequest request = LlmRequest(
    model: 'ok',
    messages: <LlmMessage>[LlmMessage.user('hi')],
  );

  test('握手后静默：连续 3 次心跳未达 → 心跳丢失错误（不是静默挂死）', () async {
    mode = 'silent';
    final HttpSseTransport t = transport();
    addTearDown(t.close);

    final List<LlmStreamEvent> events = await t
        .stream(request)
        .timeout(const Duration(seconds: 10))
        .toList();

    final LlmFailureEvent failure = events.single as LlmFailureEvent;
    expect(failure.livenessLost, isTrue, reason: '要能被上层识别成链路失活');
    expect(failure.message, contains('心跳丢失'));
    expect(failure.message, contains('链路失活'));
    expect(failure.message, contains('没有返回任何数据'));
    expect(failure.cancelled, isFalse);
    // 活性观测：心跳计数涨上去了，且流结束后不再标记为活跃
    expect(t.missedHeartbeats, greaterThan(0), reason: '静默期间要能看见连续丢失');
    expect(t.lastHeartbeatAt, isNotNull, reason: '握手注释行也算一次心跳');
    expect(t.isAlive, isFalse);
  });

  test('流中途静默：同样判心跳丢失（不静默丢弃已收到的数据）', () async {
    mode = 'stall-after-first';
    final HttpSseTransport t = transport();
    addTearDown(t.close);

    final List<LlmStreamEvent> events = await t
        .stream(request)
        .timeout(const Duration(seconds: 10))
        .toList();

    expect(
      events.whereType<LlmTextDelta>().single.text,
      '第一段',
      reason: '已经收到的数据照常交给上层',
    );
    final LlmFailureEvent failure = events.whereType<LlmFailureEvent>().single;
    expect(failure.livenessLost, isTrue);
    expect(failure.message, contains('心跳丢失'));
    expect(t.lastHeartbeatAt, isNotNull, reason: '收到过数据就要有最近心跳时间');
  });

  test('心跳正常的长响应：总时长远超静默窗口也不被打断', () async {
    mode = 'chatty';
    final HttpSseTransport t = transport();
    addTearDown(t.close);

    // 30 片 × 50ms ≈ 1.5s，是静默窗口（300ms）的 5 倍
    final List<LlmStreamEvent> events = await t
        .stream(request)
        .timeout(const Duration(seconds: 20))
        .toList();

    expect(events.whereType<LlmFailureEvent>(), isEmpty);
    expect(events.whereType<LlmTextDelta>(), hasLength(30));
    expect(
      events.whereType<LlmTextDelta>().map((LlmTextDelta e) => e.text).join(),
      List<String>.generate(30, (int i) => '第$i段').join(),
    );
    expect(t.missedHeartbeats, 0, reason: '一直在收数据，就不该记丢失');
    expect(t.lastHeartbeatAt, isNotNull);
    expect(t.isAlive, isFalse, reason: '流结束后复位');
  });

  test('心跳丢失经 LlmSession 变成可见的 AgentError（文案透传，不静默）', () async {
    mode = 'silent';
    final HttpSseTransport t = transport();
    addTearDown(t.close);
    final LlmSession session = LlmSession(
      transport: t,
      model: 'demo',
      maxOutputTokens: 128,
    );

    final List<AgentEvent> events = await session
        .run(
          messages: <LlmMessage>[const LlmMessage.user('hi')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        )
        .timeout(const Duration(seconds: 10))
        .toList();

    final AgentError error = events.whereType<AgentError>().single;
    expect(error.message, contains('心跳丢失'));
    expect(events.last, isA<AgentDone>());
  });
}

Future<void> _handle(HttpRequest request, String mode) async {
  // 请求体必须读完，否则连接上的数据会让 curl/客户端语义不完整
  await utf8.decoder.bind(request).join();
  final HttpResponse response = request.response;
  // 真实 SSE 端点必须"写一点发一点"：Dart 服务端默认 bufferOutput=true 会把整个
  // 响应攒到 close 才发，那样客户端在窗口内一个字节都收不到，测的就不是心跳了。
  response.bufferOutput = false;
  response.statusCode = 200;
  response.headers.contentType = ContentType(
    'text',
    'event-stream',
    charset: 'utf-8',
  );
  Future<void> send(String text) async {
    response.write('data: {"choices":[{"delta":{"content":"$text"}}]}\n\n');
    await response.flush();
  }

  try {
    switch (mode) {
      case 'chatty':
        for (int i = 0; i < 30; i++) {
          await send('第$i段');
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        response.write('data: [DONE]\n\n');
        await response.flush();
        await response.close();
        return;
      case 'stall-after-first':
        await send('第一段');
        await Future<void>.delayed(const Duration(seconds: 3));
        await response.close();
        return;
      default:
        // silent：先推一行 SSE 注释（真实端点的 keepalive 长这样）把响应头带出去，
        // 之后就一言不发——心跳窗口要从"最后一个字节"开始算。
        response.write(': connected\n\n');
        await response.flush();
        await Future<void>.delayed(const Duration(seconds: 3));
        await response.close();
    }
  } catch (_) {
    // 客户端判失活后会直接断流，这里的写入失败属于预期
  }
}
