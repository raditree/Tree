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

  /// 裸 socket 端点：用来**真的半路掐断**连接（见 [_handleRaw]）。
  late ServerSocket raw;
  late int rawPort;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    unawaited(() async {
      await for (final HttpRequest request in server) {
        await _handle(request);
      }
    }());
    raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    rawPort = raw.port;
    unawaited(() async {
      await for (final Socket socket in raw) {
        await _handleRaw(socket);
      }
    }());
  });

  tearDown(() async {
    await server.close(force: true);
    await raw.close();
  });

  /// 默认**关掉重试**：这些用例测的是"一次尝试"的行为（错误文案 / 空闲超时 / 取消），
  /// 重试口径由下面的『有限重试』组用极短退避单独验证。
  HttpSseTransport transport({
    Duration idleTimeout = const Duration(seconds: 5),
    List<Duration> retryBackoff = const <Duration>[],
  }) => HttpSseTransport(
    baseUrl: 'http://127.0.0.1:$port/v1',
    apiKey: 'sk-test',
    idleTimeout: idleTimeout,
    retryBackoff: retryBackoff,
  );

  /// 走裸 socket 端点（可半路掐断）；默认**开着重试**，掐断几次由 [_rawRemaining] 控制。
  HttpSseTransport rawTransport({
    List<Duration> retryBackoff = kDefaultRetryBackoff,
  }) => HttpSseTransport(
    baseUrl: 'http://127.0.0.1:$rawPort/v1',
    apiKey: 'sk-test',
    retryBackoff: retryBackoff,
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
      retryBackoff: const <Duration>[], // 本用例只关心"一次尝试"的文案
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

  /// 有限重试（生产默认：5 次，退避 5/10/20/40/80s）。
  ///
  /// 用例注入 1ms 退避：测的是**重试的判据与次数**，不是退避的时长——真实的
  /// 分钟级窗口交给代码里的常量与注释说明，测试不该花时间等它。
  group('有限重试', () {
    const List<Duration> fast = <Duration>[
      Duration(milliseconds: 1),
      Duration(milliseconds: 1),
      Duration(milliseconds: 1),
      Duration(milliseconds: 1),
      Duration(milliseconds: 1),
    ];

    setUp(() {
      _rawRemaining = 1; // 第一次掐断，之后正常返回
      _rawHits = 0;
      _rawPartial = _partialEvent;
    });

    const LlmRequest flakyRequest = LlmRequest(
      model: 'flaky',
      messages: <LlmMessage>[LlmMessage.user('hi')],
    );

    test('连接被掐断（零事件）→ 自动重试后成功：上层只看到一条正常流', () async {
      final HttpSseTransport t = rawTransport(retryBackoff: fast);
      addTearDown(t.close);

      final List<LlmStreamEvent> events = await t.stream(flakyRequest).toList();

      expect(
        events.whereType<LlmFailureEvent>(),
        isEmpty,
        reason: '重试成功就不该让上层看到失败',
      );
      expect(
        events
            .whereType<LlmTextDelta>()
            .map((LlmTextDelta e) => e.text)
            .join(),
        '第二次就好了',
      );
      expect(_rawHits, 2, reason: '端点应收到两次请求');
      final List<LlmRetryNotice> notices = events
          .whereType<LlmRetryNotice>()
          .toList();
      expect(notices, hasLength(1), reason: '重试前先告诉用户一声');
      expect(notices.single.attempt, 1);
      expect(notices.single.total, 5);
      expect(notices.single.message, contains('第 1/5 次重试'));
    });

    test('一直掐断：重试到上限后如实报错（初次 + 5 次重试 = 6 次请求）', () async {
      _rawRemaining = -1; // 一直掐断
      final HttpSseTransport t = rawTransport(retryBackoff: fast);
      addTearDown(t.close);

      final List<LlmStreamEvent> events = await t.stream(flakyRequest).toList();

      final LlmFailureEvent failure = events.whereType<LlmFailureEvent>().single;
      expect(failure.message, contains('读取模型响应失败'));
      expect(failure.statusCode, isNull, reason: '没走到"端点给了答复"那一步');
      expect(_rawHits, 6, reason: '初次 + 5 次重试');
      final List<LlmRetryNotice> notices = events
          .whereType<LlmRetryNotice>()
          .toList();
      expect(notices, hasLength(5), reason: '每次重试前各报一声');
      expect(notices.last.attempt, 5);
      expect(notices.last.message, contains('第 5/5 次重试'));
    });

    test('已经吐出正文再断流：不重试（重放会与已渲染的正文并列）', () async {
      _rawRemaining = -1; // 一直掐断
      _rawPartial = _fullEvent; // 但先给一个**完整**事件：这一跳已经有增量了
      final HttpSseTransport t = rawTransport(retryBackoff: fast);
      addTearDown(t.close);

      final List<LlmStreamEvent> events = await t
          .stream(
            const LlmRequest(
              model: 'drop-after-text',
              messages: <LlmMessage>[LlmMessage.user('hi')],
            ),
          )
          .toList();

      expect(events.whereType<LlmTextDelta>().single.text, '先给一段');
      expect(
        (events.last as LlmFailureEvent).message,
        contains('读取模型响应失败'),
      );
      expect(
        events.whereType<LlmRetryNotice>(),
        isEmpty,
        reason: '已经产出增量就不该重放',
      );
    });

    test('流中 error 帧：不重试（端点已经明确回答）', () async {
      final HttpSseTransport t = transport(retryBackoff: fast);
      addTearDown(t.close);

      final List<LlmStreamEvent> events = await t
          .stream(
            const LlmRequest(
              model: 'mid-error',
              messages: <LlmMessage>[LlmMessage.user('hi')],
            ),
          )
          .toList();

      expect(
        (events.whereType<LlmFailureEvent>().single).message,
        contains('配额用尽'),
      );
      expect(events.whereType<LlmRetryNotice>(), isEmpty);
    });

    test('4xx（401）不重试：密钥错了重试只是白花配额', () async {
      final HttpSseTransport t = transport(retryBackoff: fast);
      addTearDown(t.close);

      final List<LlmStreamEvent> events = await t
          .stream(
            const LlmRequest(
              model: 'unauthorized',
              messages: <LlmMessage>[LlmMessage.user('hi')],
            ),
          )
          .toList();

      expect((events.single as LlmFailureEvent).statusCode, 401);
      expect(events.whereType<LlmRetryNotice>(), isEmpty);
    });

    test('退避等待期间取消：立刻结束，不等满退避', () async {
      _rawRemaining = -1; // 一直掐断
      bool cancelled = false;
      // 真实退避 30s：若实现是"先睡满再判断取消"，下面的 10s 超时会直接判失败
      final HttpSseTransport t = HttpSseTransport(
        baseUrl: 'http://127.0.0.1:$rawPort/v1',
        apiKey: 'sk-test',
        retryBackoff: const <Duration>[Duration(seconds: 30)],
      );
      addTearDown(t.close);

      final List<LlmStreamEvent> events = <LlmStreamEvent>[];
      await for (final LlmStreamEvent event in t
          .stream(flakyRequest, isCancelled: () => cancelled)
          .timeout(const Duration(seconds: 10))) {
        events.add(event);
        // 刚被告知"要重试了"就按 stop：退避等待必须立刻发现它，而不是睡满 30s
        if (event is LlmRetryNotice) cancelled = true;
      }

      expect(events.whereType<LlmFailureEvent>().single.cancelled, isTrue);
      expect(_rawHits, 1, reason: '取消之后不得再打请求');
    });
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

/// 裸 socket 端点状态：[_rawRemaining] 次请求"半路掐断"，其后正常返回
/// （`-1` = 一直掐断）；[_rawHits] 数端点**实际收到**的请求次数——重试次数由它可证；
/// [_rawPartial] 是写进"掐断响应"的那段正文：凑不成一个 SSE 事件（零增量 ⇒ 可重试）
/// 还是已经凑成一个（有增量 ⇒ 不可重试），两种行为分别验证。
int _rawRemaining = 0;
int _rawHits = 0;
String _rawPartial = _partialEvent;

/// 一个**完整**的 SSE 事件（含空行）：客户端会先收到它，再遇到断连。
const String _fullEvent =
    'data: {"choices":[{"delta":{"content":"先给一段"}}]}\n\n';

/// 半行（没有空行）：解析器一个事件都产不出来 ⇒ 这一跳失败是"零增量"。
const String _partialEvent = 'data: {"choices":[{"delta":{"content":"半';

/// 裸 socket 端点：可以**真的半路掐断**连接。
///
/// 为什么不用 [HttpServer] 掐断：它一旦发出响应头，`detachSocket` 就抛
/// "Headers already sent"；而在客户端看来"优雅 close"是**正常结束**，测不到真实
/// 世界里那条 `HttpException: Connection closed while receiving data`。
/// 裸 socket 用"声明的 Content-Length 远大于实际写入"+ 干净关闭复现它：客户端读完
/// 已到的字节后遇到"正文没发完"，抛 HttpException（与真实断流同一类错误）。
Future<void> _handleRaw(Socket socket) async {
  _rawHits++;
  final bool drop = _rawRemaining != 0;
  if (_rawRemaining > 0) _rawRemaining--;
  if (!drop) {
    socket.write(
      'HTTP/1.1 200 OK\r\n'
      'Content-Type: text/event-stream\r\n'
      'Connection: close\r\n\r\n',
    );
    socket.write(
      'data: {"choices":[{"delta":{"content":"第二次就好了"}}]}\n\n',
    );
    socket.write('data: [DONE]\n\n');
    await socket.flush();
    await socket.close();
    return;
  }
  socket.write(
    'HTTP/1.1 200 OK\r\n'
    'Content-Type: text/event-stream\r\n'
    'Content-Length: 4096\r\n\r\n',
  );
  socket.write(_rawPartial);
  await socket.flush();
  await socket.close();
}
