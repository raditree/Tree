import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'llm_types.dart';
import 'openai_codec.dart';
import 'sse_parser.dart';

/// 默认重试退避：**5 次重试**，累计等待 5+10+20+40+80 = 155s（≈2.6 分钟）。
///
/// 为什么是分钟级：这一层要覆盖"端点重启 / 网关抖动几分钟后自动接续任务"，
/// 而不是"快速失败"。次数不再往上加的理由：等待期间用户可以随时取消，但每多一次
/// 重试就把"用户按 stop 之前要看的空白"拉长一截。
///
/// 序列长度 = 重试次数上限；空列表 = 关闭重试（测试与"只想快速失败"的场合）。
const List<Duration> kDefaultRetryBackoff = <Duration>[
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 20),
  Duration(seconds: 40),
  Duration(seconds: 80),
];

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
/// **超时口径（M9 规约 1.1，修正版：不看静态时间，只看心跳活性）**：
/// - **没有任何总时长上限**：本地执行不存在"多用户占着连接不放导致资源耗尽"的
///   后果，所以推理模型想跑多久都行，绝不会因为"总耗时到了"被丢掉；
/// - 判死的唯一依据是**心跳丢失（链路失活）**：流式读取期间**收到任意字节即算
///   一次心跳**；连续 [missedHeartbeatLimit] 次 [heartbeatInterval] 一个字节都
///   没收到，才判定链路已死，并以**显式错误**结束本次请求（既不静默挂死，也不
///   静默丢弃）。错误事件 [LlmFailureEvent.livenessLost] 为真，上层据此重连或
///   提示用户；
/// - 唯一保留的短超时是 [connectTimeout]（建连 + 等响应头）：它只服务**可诊断**
///   ——"端点根本没起"要立刻说得清，而不是让界面一直转圈；它不限制推理时长。
///
/// **重试口径（默认最多 5 次，退避 5/10/20/40/80s）**：
/// - **只在"这一次尝试一个事件都还没交给上层"时重试**：上层因此完全看不见重试，
///   不存在重复输出、重复计费。已经吐出增量的失败（半路断流）**不重试**——重放会与
///   已经渲染的正文并列；那种情况如实报错，由用户决定要不要再说一句"继续"；
/// - **可重试**：没有 HTTP 响应（建连失败 / 等响应头超时 / 心跳丢失 / 读取中断，
///   例如 `HttpException: Connection closed while receiving data`）、408、429、5xx；
/// - **不重试**：4xx（密钥 / 模型 / 参数错——重试只是白花 5 次配额）、流中 error 帧
///   （[LlmFailureEvent.retryable] 为 false）、已取消、传输层已关闭；
/// - 等待期间**可取消**：用户按 stop 立刻结束，不会等满退避；每次重试前先产出一个
///   [LlmRetryNotice]（用户看得到"在重试第几次"，它不算"已产出的内容"）；
/// - 为什么需要它：端点重启 / 网关抖动是**分钟级**的，一次失败就把整轮任务丢掉
///   代价太大（用户得从头再讲一遍）。
///
/// 活性观测：[missedHeartbeats] / [lastHeartbeatAt] / [isAlive] 供上层做重连决策
/// 与 UI 展示（并发多条流时，这几个值反映**最近一条**流的活性）。
///
/// 其它关注点：
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
    this.heartbeatInterval = const Duration(seconds: 10),
    this.missedHeartbeatLimit = 3,
    this.retryBackoff = kDefaultRetryBackoff,
    Duration? idleTimeout,
  }) : _idleOverride = idleTimeout,
       _client = client ?? HttpClient() {
    _client.connectionTimeout = connectTimeout;
  }

  /// 模型配置里的 base_url（如 `https://api.example.com/v1`）。
  final String baseUrl;

  /// API 密钥。
  final String apiKey;

  /// 建连（含等响应头）超时。
  ///
  /// 保留它纯粹是为了**可诊断**：连不上要立刻说"连不上"，而不是让用户对着一个
  /// 转圈的界面等下去。它不限制推理时长（那由心跳判据管）。
  final Duration connectTimeout;

  /// 心跳间隔：活性检查的基准节拍。
  ///
  /// 含义是"每这么长时间应至少收到一次数据"——收到任意字节即算心跳，节拍本身
  /// 不会打断任何请求。
  final Duration heartbeatInterval;

  /// 允许**连续丢失**多少次心跳（默认 3 次）。
  ///
  /// 连续 [missedHeartbeatLimit] 次 [heartbeatInterval] 都没收到任何字节 ⇒ 判
  /// 心跳丢失。默认 10s × 3 = 30s 静默即失活；常量可配。
  final int missedHeartbeatLimit;

  /// 重试退避序列：**长度就是重试次数上限**（默认 [kDefaultRetryBackoff] = 5 次）。
  ///
  /// 空列表 = 关闭重试。
  final List<Duration> retryBackoff;

  /// 显式覆盖静默窗口（老口径 / 测试要极短窗口时使用；null = 用推导值）。
  final Duration? _idleOverride;

  /// 判失活的静默窗口 = [heartbeatInterval] × [missedHeartbeatLimit]。
  ///
  /// 它**不是总时长上限**：只要还有字节进来，窗口就一直往后滚。
  Duration get livenessWindow =>
      _idleOverride ??
      heartbeatInterval * (missedHeartbeatLimit < 1 ? 1 : missedHeartbeatLimit);

  final HttpClient _client;
  bool _closed = false;
  bool _alive = false;
  _HeartbeatCounter? _monitor;

  /// 传输层是否已关闭。
  bool get isClosed => _closed;

  /// 当前是否有一条流在活跃接收（尚未判失活 / 尚未结束）。
  bool get isAlive => _alive;

  /// 最近一条流的**连续丢失心跳次数**（收到任意字节即清零）。
  int get missedHeartbeats => _monitor?.missed ?? 0;

  /// 最近一条流**最后一次收到数据的时间**（null = 该流一个字节都没收到过）。
  DateTime? get lastHeartbeatAt => _monitor?.lastBeatAt;

  /// 一次 [LlmRequest] → 事件流（**含有限重试**）。
  ///
  /// 重试口径见类注释；上层（LlmSession / 总结器 / llm.call）拿到的因此只是
  /// "一次可能稍慢的调用"，看不见重试。
  @override
  Stream<LlmStreamEvent> stream(
    LlmRequest request, {
    bool Function()? isCancelled,
  }) async* {
    for (int attempt = 0; ; attempt++) {
      LlmFailureEvent? failure;
      bool produced = false;
      await for (final LlmStreamEvent event in _attemptOnce(
        request,
        isCancelled: isCancelled,
      )) {
        // 已经交给上层的事件**收不回来**：从这一刻起失败就不该重试（重放会与它并列）
        if (event is LlmFailureEvent) {
          failure = event;
          break;
        }
        produced = true;
        yield event;
      }
      if (failure == null) return;
      final bool canRetry =
          !produced &&
          _retryable(failure) &&
          attempt < retryBackoff.length &&
          !(isCancelled?.call() ?? false);
      if (!canRetry) {
        yield failure;
        return;
      }
      final Duration wait = retryBackoff[attempt];
      // 先说给用户听（上层据此落一条 llm_hidden 的消息），再退避等待：最长两分多钟的
      // 空白里，用户必须看得到"在重试"。
      yield LlmRetryNotice(
        '模型端点调用失败（第 ${attempt + 1}/${retryBackoff.length} 次重试，'
        '${_formatDuration(wait)} 后重试）：${failure.message}',
        attempt: attempt + 1,
        total: retryBackoff.length,
      );
      if (!await _waitBeforeRetry(wait, isCancelled)) {
        // 退避等待期间被停止：与"请求中途取消"同一口径
        yield const LlmFailureEvent('已取消', cancelled: true);
        return;
      }
    }
  }

  /// 单次尝试：把一次请求变成一串事件（**不含重试**）。
  ///
  /// 一次尝试**最多产出一个** [LlmFailureEvent] 并以它收尾；正常结束时自然结束。
  Stream<LlmStreamEvent> _attemptOnce(
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

    // ── 活性看门狗 ───────────────────────────────────────────────────────
    final _HeartbeatCounter beats = _HeartbeatCounter(
      interval: heartbeatInterval,
      limit: missedHeartbeatLimit,
    )..start();
    _monitor = beats;
    _alive = true;

    final SseParser parser = SseParser();
    try {
      // 心跳打在**字节流**上（而不是解析后的行）：收到任意字节就续期，哪怕那半行
      // 还没换行。这样"慢而持续"的流永远不会被时间判死。
      Stream<String> decoded = response.transform(utf8.decoder).map((
        String chunk,
      ) {
        beats.beat();
        return chunk;
      });
      // 静默窗口内一个事件都没有 ⇒ 判心跳丢失。Stream.timeout 每收到一个事件就
      // 重新计时，所以它与"连续 N 次心跳未达"是同一件事；区别只在于计数交给
      // [beats] 暴露给上层观测（[missedHeartbeats] / [lastHeartbeatAt]）。
      decoded = decoded.timeout(
        livenessWindow,
        onTimeout: (EventSink<String> sink) {
          sink.addError(TimeoutException(_heartbeatLostMessage()));
          sink.close();
        },
      );
      await for (final String line in decoded.transform(const LineSplitter())) {
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
      // 心跳丢失：显式失败（不静默挂死、也不静默丢弃），文案里带"心跳丢失"，
      // livenessLost 供上层做重连/提示决策。
      yield LlmFailureEvent('$error', livenessLost: true);
      return;
    } catch (error) {
      yield LlmFailureEvent('读取模型响应失败：${_brief(error)}');
      return;
    } finally {
      beats.stop();
      _alive = false;
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

  /// 这次失败是否**值得重试**（判定口径见类注释「重试口径」）。
  bool _retryable(LlmFailureEvent event) {
    if (_closed) return false;
    if (event.cancelled) return false;
    if (!event.retryable) return false;
    final int? code = event.statusCode;
    // 没有 HTTP 状态码 = 根本没走到"端点给了答复"那一步：建连失败 / 等响应头超时 /
    // 心跳丢失 / 读取中断。端点恢复后这类失败最可能自愈，正是重试要覆盖的场景。
    if (code == null || code == 0) return true;
    if (code == 408 || code == 429) return true; // 请求超时 / 限流：等一等再来
    return code >= 500; // 5xx：端点自己出问题了
  }

  /// 退避等待：切成 250ms 的小片，**每片都看一次取消**。
  ///
  /// 直接 await 一次 [Future.delayed] 会让"用户按了 stop"最多等到退避结束（80s）——
  /// 那等于把"可取消"做成假的。返回 false = 等待期间被取消。
  Future<bool> _waitBeforeRetry(
    Duration total,
    bool Function()? isCancelled,
  ) async {
    const int slice = 250;
    final int totalMs = total.inMilliseconds;
    for (int elapsed = 0; elapsed < totalMs; elapsed += slice) {
      if (isCancelled?.call() ?? false) return false;
      final int remain = totalMs - elapsed;
      await Future<void>.delayed(
        Duration(milliseconds: remain < slice ? remain : slice),
      );
    }
    return !(isCancelled?.call() ?? false);
  }

  /// 心跳丢失的错误文案。
  ///
  /// 必须同时点明「心跳丢失/链路失活」与"没有任何数据"：前者让日志与 UI 能一眼
  /// 区分"链路死了"和"端点在思考"，后者是历史口径（老前端/测试按这句话判断空闲）。
  String _heartbeatLostMessage() {
    final Duration window = livenessWindow;
    return '模型端点心跳丢失（链路失活）：${_formatDuration(window)} 内没有返回任何数据'
        '（连续 $missedHeartbeatLimit 次心跳未达，'
        '心跳间隔 ${_formatDuration(heartbeatInterval)}；'
        '收到任意字节即续期，这不是总时长上限）';
  }

  /// 人类可读的时长（不足 1s 用毫秒，避免出现"0s"）。
  static String _formatDuration(Duration value) => value.inSeconds >= 1
      ? '${value.inSeconds}s'
      : '${value.inMilliseconds}ms';

  /// 把错误/响应体压成一行短文本（日志与 UI 都只该看到摘要）。
  static String _brief(Object? value, {int limit = 300}) {
    final String text = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= limit ? text : '${text.substring(0, limit)}…';
  }
}

/// 心跳计数（活性观测）：每 [interval] 检查一次，这一拍里收到过字节就清零，
/// 否则累加。
///
/// 判死由 [HttpSseTransport.livenessWindow] 上的 timeout 完成（两者判据等价：
/// 窗口 = 间隔 × 允许丢失次数），本类只负责把"最近心跳时间 / 连续丢失次数"
/// 暴露出去，供上层重连决策与 UI 展示。每条流一个实例，互不干扰。
class _HeartbeatCounter {
  _HeartbeatCounter({required this.interval, required this.limit});

  final Duration interval;

  /// 允许连续丢失的次数（与 [HttpSseTransport.missedHeartbeatLimit] 同源）。
  final int limit;

  Timer? _timer;
  bool _beatSinceTick = false;

  /// 连续丢失的心跳次数。
  int missed = 0;

  /// 最近一次收到数据的时间。
  DateTime? lastBeatAt;

  /// 启动节拍（间隔非正时不启动——等价于关闭观测）。
  void start() {
    if (interval <= Duration.zero) return;
    _timer = Timer.periodic(interval, (Timer _) {
      if (_beatSinceTick) {
        _beatSinceTick = false;
        missed = 0;
        return;
      }
      missed++;
    });
  }

  /// 是否已经判为**心跳丢失**（连续 [limit] 次未达）。
  ///
  /// 判死由静默窗口上的 timeout 执行，两者判据等价；这个 getter 让"判据"在代码里
  /// 也显式存在（供上层观测/测试断言），而不是只藏在窗口计算里。
  bool get lost => missed >= limit;

  /// 收到任意字节：刷新最近心跳时间，并让下一拍清零。
  void beat() {
    _beatSinceTick = true;
    missed = 0;
    lastBeatAt = DateTime.now();
  }

  /// 停止节拍（幂等）。
  void stop() => _timer?.cancel();
}
