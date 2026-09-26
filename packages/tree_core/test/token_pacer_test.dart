import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 可控时钟 + 可控睡眠（Q13）：token 管道的断言不依赖任何真实计时器。
///
/// [granularity] 模拟"每次睡眠都比请求的多睡一点"——Windows 的计时器粒度约
/// 15.6ms，正是旧的"每个增量延迟 1ms"被打回原形的原因。
class _FakeClock {
  _FakeClock({this.granularity = Duration.zero});

  DateTime now = DateTime(2026, 1, 1);
  Duration granularity;

  /// 每次"睡眠"实际消耗的时长（请求值 + 粒度）。
  final List<Duration> sleeps = <Duration>[];

  DateTime call() => now;

  Future<void> wait(Duration delay) async {
    final Duration actual = delay + granularity;
    sleeps.add(actual);
    now = now.add(actual);
  }

  Duration get elapsed => now.difference(DateTime(2026, 1, 1));

  Duration get totalSleep =>
      sleeps.fold(Duration.zero, (Duration sum, Duration item) => sum + item);
}

/// 可控引擎：按脚本一次性产出事件（不模拟任何时间）。
class _ScriptEngine implements AgentEngine {
  _ScriptEngine(this.events);

  final List<AgentEvent> events;

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    for (final AgentEvent event in events) {
      yield event;
    }
  }

  @override
  Future<void> close() async {}
}

/// 只记录、不发送的 hub：帧顺序与"推帧那一刻的管道消费量"都能被断言。
class _RecordingHub extends WsHub {
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  void Function(Map<String, dynamic> frame)? onFrame;

  @override
  void broadcast(Map<String, dynamic> frame) {
    frames.add(frame);
    onFrame?.call(frame);
  }
}

void main() {
  group('TokenPacer（目标时间轴 + 累计欠账）', () {
    test('平均速率等于配置值，且与增量切分方式无关', () async {
      final _FakeClock clock = _FakeClock();
      final TokenPacer pacer = TokenPacer(
        tokensPerSecond: 1000,
        clock: clock.call,
        wait: clock.wait,
      );
      // 100 个 1 token 的增量：应到达时刻 = 100/1000 s
      for (int i = 0; i < 100; i++) {
        await pacer.consume(1);
      }
      expect(pacer.consumedTokens, 100);
      expect(clock.elapsed, const Duration(milliseconds: 100));

      // 同样的 100 token 一次消费完：总时长一致（速率口径统一）
      final _FakeClock bulk = _FakeClock();
      final TokenPacer other = TokenPacer(
        tokensPerSecond: 1000,
        clock: bulk.call,
        wait: bulk.wait,
      );
      await other.consume(100);
      expect(bulk.elapsed, const Duration(milliseconds: 100));
    });

    test('OS 计时器粒度不累积：1000 token 只多付一次粒度，而不是每个增量都付', () async {
      final _FakeClock clock = _FakeClock(
        granularity: const Duration(milliseconds: 15, microseconds: 600),
      );
      final TokenPacer pacer = TokenPacer(
        tokensPerSecond: 1000,
        clock: clock.call,
        wait: clock.wait,
      );
      for (int i = 0; i < 1000; i++) {
        await pacer.consume(1);
      }
      // 旧实现（每增量延迟 1ms）在这里要 `1000 × (1ms + 15.6ms)` ≈ 16.6s；
      // 目标时间轴只允许"每次补账时多付一次粒度"，总时长贴住 1s。
      expect(clock.elapsed, greaterThanOrEqualTo(const Duration(seconds: 1)));
      expect(
        clock.elapsed,
        lessThan(const Duration(milliseconds: 1100)),
        reason: '平均速率必须贴住配置值，不能被计时器粒度拖走',
      );
      // 实际睡眠次数远少于增量数（欠账一次性补掉 = 允许突发）
      expect(clock.sleeps.length, lessThan(100));
    });

    test('落后目标时刻时直接放行（可突发），不再等待', () async {
      final _FakeClock clock = _FakeClock();
      final TokenPacer pacer = TokenPacer(
        tokensPerSecond: 100,
        clock: clock.call,
        wait: clock.wait,
      );
      await pacer.consume(10); // 目标 100ms
      expect(clock.sleeps, hasLength(1));
      // 外部耗时（例如 LLM 网络往返）已经远超目标时刻
      clock.now = clock.now.add(const Duration(seconds: 5));
      await pacer.consume(10);
      expect(clock.sleeps, hasLength(1), reason: '落后就该放行，不能倒扣欠账');
    });

    test('关闭开关：enabled=false 不等待、不累计', () async {
      final _FakeClock clock = _FakeClock();
      final TokenPacer pacer = TokenPacer(
        tokensPerSecond: 100,
        enabled: false,
        clock: clock.call,
        wait: clock.wait,
      );
      for (int i = 0; i < 50; i++) {
        await pacer.consume(10);
      }
      expect(clock.sleeps, isEmpty);
      expect(pacer.consumedTokens, 0);
    });
  });

  group('Q13 token 管道接线', () {
    test('工具参数与思考/正文共用同一条管道：tool_start 推出去时参数已计量', () async {
      final _FakeClock clock = _FakeClock();
      final TokenPacer pacer = TokenPacer(
        tokensPerSecond: 1000,
        clock: clock.call,
        wait: clock.wait,
      );
      final _RecordingHub hub = _RecordingHub();
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(name: '管道用例');

      const Map<String, dynamic> readArgs = <String, dynamic>{
        'file_path': 'a.txt',
      };
      final Map<String, dynamic> writeArgs = <String, dynamic>{
        'file_path': 'b.txt',
        'content': '很长的一段内容' * 20,
      };
      final ConversationService service = ConversationService(
        store: store,
        hub: hub,
        settings: CoreSettings(),
        pacer: pacer,
        engine: _ScriptEngine(<AgentEvent>[
          const AgentThinking('想一想'),
          const AgentText('读一下'),
          AgentToolStart(
            id: 'tool_a',
            callId: 'call_a',
            name: 'read',
            arguments: readArgs,
          ),
          const AgentToolEnd(id: 'tool_a', name: 'read', result: 'A'),
          AgentToolStart(
            id: 'tool_b',
            callId: 'call_b',
            name: 'write',
            arguments: writeArgs,
          ),
          const AgentToolEnd(id: 'tool_b', name: 'write', result: '已写入'),
          const AgentText('完成'),
          const AgentDone(finishReason: 'stop'),
        ]),
      );

      // 推 tool_start 的那一刻，参数 token 必须已经进过管道（顺序证据）
      final Map<String, double> consumedAt = <String, double>{};
      hub.onFrame = (Map<String, dynamic> frame) {
        final String type = frame['type'] as String? ?? '';
        if (type == 'tool_start' || type == 'tool_end') {
          consumedAt['$type:${frame['name']}'] = pacer.consumedTokens;
        }
      };

      await service.handleUserMessage(<String, dynamic>{
        'agent_id': agent.id,
        'content': '干活',
      });

      // 思考 + 正文 + read 参数：三者在 read 卡片推出前都走完了管道
      final int readTokens = estimateTokens(
        '{"file_path":"a.txt"}',
      ); // 参数按 jsonEncode 后的字符数折算
      expect(
        consumedAt['tool_start:read'],
        estimateTokens('想一想') + estimateTokens('读一下') + readTokens,
      );
      // write 的大参数同样过管道，且明显多于 read（"write 自然产生等待"）
      final int writeTokens = estimateTokens(
        '{"file_path":"b.txt","content":"${'很长的一段内容' * 20}"}',
      );
      expect(
        consumedAt['tool_start:write'],
        consumedAt['tool_start:read']! + writeTokens,
      );
      // read 的参数小（几乎不等），write 的参数大（自然产生等待）
      expect(writeTokens, greaterThan(readTokens * 5));
      // 工具结果**直接推**：tool_end 不消费任何 token
      expect(consumedAt['tool_end:read'], consumedAt['tool_start:read']);
      expect(consumedAt['tool_end:write'], consumedAt['tool_start:write']);
      // 最终正文也走同一条管道
      expect(pacer.consumedTokens, greaterThan(consumedAt['tool_end:write']!));

      // 帧顺序不受影响：工具卡片仍然先立后填
      expect(
        hub.frames
            .where(
              (Map<String, dynamic> f) =>
                  f['type'] == WsOutboundType.toolStart ||
                  f['type'] == WsOutboundType.toolEnd,
            )
            .map((Map<String, dynamic> f) => '${f['type']}:${f['name']}')
            .toList(),
        <String>[
          'tool_start:read',
          'tool_end:read',
          'tool_start:write',
          'tool_end:write',
        ],
      );
    });

    test('零延迟占位引擎 = 节奏控制自动关闭（默认路径不必注入节拍器）', () async {
      // 测试旋钮 streamChunkDelay: Duration.zero 的落点就是这个引擎：它"不模拟
      // 时间"，若还按 token 速率节流，一轮回复会被真实计时器拖成好几秒。下面把
      // 速率压到下限 20 token/s，正是为了让"没关掉"变得肉眼可见。
      final CoreSettings settings = CoreSettings()..setTokenAcquisitionRate(20);
      final MemoryStore store = MemoryStore();
      final _RecordingHub hub = _RecordingHub();
      final ConversationService service = ConversationService(
        store: store,
        hub: hub,
        settings: settings,
        engine: ScriptedAgent(chunkDelay: Duration.zero),
      );
      expect(service.pacingEnabled, isNull, reason: '未显式设置 = 自动判断');
      final CoreAgent agent = store.createAgent(name: '零延迟');

      final DateTime started = DateTime.now();
      await service.handleUserMessage(<String, dynamic>{
        'agent_id': agent.id,
        'content': '合并一下',
        'session_id': TreeStore.defaultSessionId,
      });
      // 一轮回复 120+ 字符 = 60+ token：20 token/s 的管道要 3s 以上
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 1)),
        reason: '零延迟引擎必须关掉节奏控制，否则测试会被真实计时器拖垮',
      );
      expect(
        hub.frames.where(
          (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgChunk,
        ),
        hasLength(1),
        reason: '没有帧窗口定时器时，整轮增量在 dispose 时合并成一帧',
      );
      expect(
        store.messages(agent.id, TreeStore.defaultSessionId).last.content,
        ScriptedAgent.replyFor('合并一下'),
      );
    });
  });
}
