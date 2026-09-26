import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 可控引擎：按脚本一次性产出全部事件（不模拟任何时间）。
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

/// 只记录、不发送的 hub（与 token_pacer_test 同一形态）：帧顺序与字段可直接断言。
class _RecordingHub extends WsHub {
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  @override
  void broadcast(Map<String, dynamic> frame) => frames.add(frame);
}

/// 流式增量的**单调序号**（M9 断线补发重播去重）：核心侧产出契约见
/// `WsStreamSeq`（字段名 / 起点 / 一帧一个序号 / 跨 id 独立 / msg_end 封口水位）。
///
/// 测试为什么能"一遍跑完就断言"：这里直接构造 [ConversationService] 并把节奏控制
/// 整体关掉（`pacingEnabled: false`）——token 管道直接放行（不花真实时间），
/// `_ChunkPump` 也不挂帧窗口定时器，攒下的增量**只在显式 flush 点落地**。
/// 于是"一条增量帧"的边界完全由脚本里的 flush 点决定，序号断言不依赖 OS 计时器
/// 粒度与机器负载（帧窗口落在哪一毫秒在 Windows 上是不可复现的）。
void main() {
  late MemoryStore store;
  late _RecordingHub hub;
  late ConversationService service;
  late CoreAgent agent;
  const String sessionId = TreeStore.defaultSessionId;

  /// 按脚本建好服务与 agent（不跑生成）。
  void build(List<AgentEvent> events) {
    store = MemoryStore();
    hub = _RecordingHub();
    service = ConversationService(
      store: store,
      hub: hub,
      settings: CoreSettings(),
      engine: _ScriptEngine(events),
      pacingEnabled: false,
    );
    agent = store.createAgent(name: '序号用例');
  }

  /// 发一条用户消息并等这一轮生成跑完。
  Future<void> send() => service.handleUserMessage(<String, dynamic>{
    'agent_id': agent.id,
    'content': '跑一遍',
    'session_id': sessionId,
  });

  /// 某个 type 的帧 id（按到达顺序）。
  List<String> idsOf(String type) => <String>[
    for (final Map<String, dynamic> frame in hub.frames)
      if (frame['type'] == type) frame['id'] as String? ?? '',
  ];

  /// 某个 id 的增量帧序号（按到达顺序；msg_chunk 缺序号视为实现违约）。
  List<int> chunkSeqs(String id) {
    final List<int> seqs = <int>[];
    for (final Map<String, dynamic> frame in hub.frames) {
      if (frame['type'] != WsOutboundType.msgChunk) continue;
      if (frame['id'] != id) continue;
      final int? seq = WsStreamSeq.of(frame);
      expect(seq, isNotNull, reason: 'msg_chunk 必带序号字段：$frame');
      seqs.add(seq!);
    }
    return seqs;
  }

  /// 某个 id 的增量正文（按到达顺序）。
  List<String> chunkTexts(String id) => <String>[
    for (final Map<String, dynamic> frame in hub.frames)
      if (frame['type'] == WsOutboundType.msgChunk && frame['id'] == id)
        frame['chunk'] as String? ?? '',
  ];

  /// 某个 id 的 msg_end 帧。
  Map<String, dynamic> endFrameOf(String id) => hub.frames.firstWhere(
    (Map<String, dynamic> frame) =>
        frame['type'] == WsOutboundType.msgEnd && frame['id'] == id,
    orElse: () => throw StateError('没有 id=$id 的 msg_end'),
  );

  /// 无跳号 = 观察到的序号正是从 [WsStreamSeq.firstSeq] 起的连续编号。
  ///
  /// 缺口的**唯一**合法来源是补发队列溢出丢帧（核心只保证递增），本测试里没有
  /// 丢帧路径，所以"缺号"就是记账 bug。
  void expectNoGap(List<int> seqs) {
    expect(
      seqs,
      List<int>.generate(seqs.length, (int i) => WsStreamSeq.firstSeq + i),
      reason: '同一 id 内序号必须严格递增且无跳号：$seqs',
    );
  }

  test('同一 id 多帧：0,1,2 严格递增无跳号，msg_end 封口水位 = 末帧序号', () async {
    // 两次 msg_usage 是同一段内的显式 flush 点：三段增量因此各自成一帧。
    // （没有帧窗口定时器时，flush 点是唯一能造出"同一 id 多帧"的确定性手段。）
    build(<AgentEvent>[
      const AgentText('甲'),
      const AgentUsage(<String, dynamic>{'total_tokens': 1}),
      const AgentText('乙'),
      const AgentUsage(<String, dynamic>{'total_tokens': 2}),
      const AgentText('丙'),
      const AgentDone(finishReason: 'stop'),
    ]);
    await send();

    final List<String> starts = idsOf(WsOutboundType.msgStart);
    expect(starts, hasLength(1), reason: '整轮只有一个正文段');
    final String id = starts.single;

    // msg_start 不带序号：它的"基线"恒为 firstSeq，带上只会与已消费水位混淆
    final Map<String, dynamic> start = hub.frames.firstWhere(
      (Map<String, dynamic> frame) => frame['type'] == WsOutboundType.msgStart,
    );
    expect(
      start.containsKey(WsStreamSeq.field),
      isFalse,
      reason: 'msg_start 不下发序号字段',
    );

    expect(chunkSeqs(id), <int>[0, 1, 2], reason: '严格递增且从 0 起');
    expectNoGap(chunkSeqs(id));
    expect(chunkTexts(id), <String>['甲', '乙', '丙'], reason: '帧序与事件序一致');

    // 封口水位 = 本段最后一条增量帧的序号（前端据此把已消费水位推进到段末）
    final Map<String, dynamic> end = endFrameOf(id);
    expect(WsStreamSeq.of(end), 2, reason: 'msg_end 的封口水位 = 末帧序号');
    expect(end['usage'], isNotNull, reason: 'usage 仍挂在最后一段上');

    expect(
      store.messages(agent.id, sessionId).last.content,
      '甲乙丙',
      reason: '序号只影响下发，落库仍是完整正文',
    );
  });

  test('跨 id 独立：思考段 0,1 不影响正文段从 0 起算', () async {
    build(<AgentEvent>[
      const AgentThinking('想一'),
      const AgentUsage(<String, dynamic>{'total_tokens': 1}), // flush：思考段第一帧
      const AgentThinking('想二'),
      const AgentText('答案'), // 关闭思考段（第二帧）+ 立正文段
      const AgentDone(finishReason: 'stop'),
    ]);
    await send();

    final List<String> starts = idsOf(WsOutboundType.msgStart);
    expect(starts, hasLength(2), reason: '思考段 + 正文段');
    final String thinkingId = starts[0];
    final String textId = starts[1];
    expect(thinkingId, isNot(textId));

    expect(chunkSeqs(thinkingId), <int>[0, 1]);
    expect(chunkSeqs(textId), <int>[
      0,
    ], reason: '正文段按自己的 id 从 firstSeq 起算，不接在思考段之后');
    expectNoGap(chunkSeqs(thinkingId));
    expectNoGap(chunkSeqs(textId));

    // 封口水位也各算各的：若做成整轮全局计数器，正文段会是 2
    expect(WsStreamSeq.of(endFrameOf(thinkingId)), 1);
    expect(WsStreamSeq.of(endFrameOf(textId)), 0);
  });

  test('一个帧窗口内合并的多个增量只占一个序号', () async {
    build(<AgentEvent>[
      const AgentText('一'),
      const AgentText('二'),
      const AgentText('三'),
      const AgentDone(finishReason: 'stop'),
    ]);
    await send();

    final String id = idsOf(WsOutboundType.msgStart).single;
    // 无 flush 点、无帧窗口定时器 ⇒ 三条增量落在同一个窗口里，合并成一帧
    expect(chunkTexts(id), <String>['一二三']);
    expect(chunkSeqs(id), <int>[
      WsStreamSeq.firstSeq,
    ], reason: '攒帧合并后的一帧只占一个序号（序号是"第几帧"，不是"第几次增量"）');
    expect(WsStreamSeq.of(endFrameOf(id)), WsStreamSeq.firstSeq);
  });

  test('本段没下发过增量：msg_end 省略序号字段（不是 0）', () async {
    build(<AgentEvent>[
      const AgentText(''),
      const AgentDone(finishReason: 'stop'),
    ]);
    await send();

    final String id = idsOf(WsOutboundType.msgStart).single;
    expect(chunkSeqs(id), isEmpty, reason: '空增量不落帧');
    final Map<String, dynamic> end = endFrameOf(id);
    expect(
      end.containsKey(WsStreamSeq.field),
      isFalse,
      reason: '没有增量就没有封口水位：写 0 会让前端把第一条增量判成重播',
    );
    expect(WsStreamSeq.of(end), isNull);
    expect(
      store.messages(agent.id, sessionId),
      hasLength(1),
      reason: '空正文不落库（只有用户消息）',
    );
  });

  test('第二条用户消息：新一轮计数从 firstSeq 重新起算', () async {
    build(<AgentEvent>[
      const AgentText('答复'),
      const AgentDone(finishReason: 'stop'),
    ]);
    await send();
    final List<String> firstRound = idsOf(WsOutboundType.msgStart);
    expect(chunkSeqs(firstRound.single), <int>[0]);

    // 同一服务再跑一轮：message id 是新生成的，计数器也随本轮 pump 重建
    await send();
    final List<String> allStarts = idsOf(WsOutboundType.msgStart);
    expect(allStarts, hasLength(2));
    final String secondId = allStarts[1];
    expect(secondId, isNot(firstRound.single));
    expect(chunkSeqs(secondId), <int>[
      WsStreamSeq.firstSeq,
    ], reason: '跨轮不复用旧水位（id 与 pump 都是新的）');
  });
}
