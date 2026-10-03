import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 压缩可观测性（plan §4②）的定向用例：「压缩走了哪条路 / 插件为什么没接管」
/// 必须**带一句人话原因**上行，并且**刷新后仍在**。
///
/// 四层断言：
/// - 结论层：中转站没接管 ⇒ [CompactionResult.relaySkipReason] 非空、REST 响应里出现
///   **可选键** `relay_skip_reason`；接管 ⇒ 没有该键（形状与老前端零感知）；
/// - 接线层：原因真的能从**插件总线**（真 `PluginBus`，不启插件进程）上到压缩结论；
/// - 会话层：「压缩已发生 / 降级 / 插件没接管」**落库**成 `llm_hidden` 消息，重开
///   存储（= 刷新）后仍在——只发一帧不算数；
/// - 分级（2026-10-03 追加）：**REST 全量、会话通知只写"有订阅者却没接管"**——
///   早退（总开关关 / 作用域不匹配 / 无点位 / 无订阅者）不写进历史，否则没装压缩
///   插件的用户每条通知都多一句废话；
/// - 手动压缩（REST `POST /api/agents/{id}/compact`）与自动压缩走**同一条**文案口径，
///   同样落库。
void main() {
  late Directory temp;
  late CoreSettings settings;
  int clock = 0;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_compact_skip_');
    clock = 0;
    settings = CoreSettings()
      ..putModel(
        CoreModelConfig(
          modelId: 'demo',
          name: '演示',
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'sk-test',
          maxSeqlen: 1000,
        ),
      );
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上文件句柄可能还没释放：临时目录清不掉不影响断言
    }
  });

  TreePaths paths() => TreePaths(temp.path);

  void add(
    TreeStore store,
    CoreAgent agent,
    CoreSession session,
    String role,
    String content,
  ) {
    clock++;
    store.appendMessage(
      CoreMessage(
        id: 'msg_$clock',
        agentId: agent.id,
        sessionId: session.sessionId,
        role: role,
        content: content,
        timestamp: clock,
      ),
    );
  }

  /// 造 [turns] 轮「需求/回答」（与 compaction_test 的 `addTurn` 同口径）。
  void addTurns(
    TreeStore store,
    CoreAgent agent,
    CoreSession session,
    int turns,
  ) {
    for (int i = 1; i <= turns; i++) {
      add(store, agent, session, 'user', '需求$i');
      add(store, agent, session, 'agent', '回答$i');
    }
  }

  CoreAgent seedAgent(TreeStore store) {
    final CoreAgent agent = store.createAgent(name: '压缩来源可见', modelId: 'demo');
    agent.systemPrompt = '你是助手';
    agent.compressThreshold = 0.5;
    store.putAgent(agent);
    return agent;
  }

  CoreSession seedSession(TreeStore store, CoreAgent agent) =>
      store.session(agent.id, TreeStore.defaultSessionId)!;

  CompactionService newService(
    TreeStore store, {
    ContextSummarizer? summarizer,
  }) => CompactionService(
    store: store,
    settings: settings,
    summarizer: summarizer ?? _FakeSummarizer(),
    keepRecentUserMessages: 2,
    keepTailLength: 2,
    minSummarizeMessages: 4,
  );

  /// 一个**什么都不做**的中转点：回 null = 不接管，但同时按总线的做法上报一条原因。
  ///
  /// [hasSubscriber] 与总线同义：`false` = 早退（没插件在这条路上），
  /// `true` = 有订阅者却没交出可用结果。
  CompactionRelayHook decliningHook(
    CompactionService service,
    String reason, {
    bool hasSubscriber = false,
  }) =>
      ({
        required CoreAgent agent,
        required CoreSession session,
        required String systemPrompt,
        required int totalMessageCount,
        required int compactedMessageCount,
        required String existingSummary,
        required Map<String, dynamic>? wireRequest,
      }) async {
        service.noteRelaySkip(
          agent.id,
          session.sessionId,
          reason,
          hasSubscriber: hasSubscriber,
        );
        return null;
      };

  /// 一个**接管**的中转点：回一份整份上下文 + 覆盖条数。
  CompactionRelayHook acceptingHook({int covered = 6}) =>
      ({
        required CoreAgent agent,
        required CoreSession session,
        required String systemPrompt,
        required int totalMessageCount,
        required int compactedMessageCount,
        required String existingSummary,
        required Map<String, dynamic>? wireRequest,
      }) async => CompactionRelayReply(
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': '插件产出的上下文'},
        ],
        coveredMessageCount: covered,
      );

  /// 真插件总线，但**不启任何插件进程**（配置为空 ⇒ 该点位没有订阅者）。
  ///
  /// 这样"没接管"的原因来自真总线，且用例是秒级的——真进程那条路已经由
  /// `plugin_llm_relay_test.dart` ⑦ 覆盖。
  PluginBus newBus() {
    final PluginBus bus = PluginBus(
      configFile: p.join(temp.path, 'plugins.yaml'),
    );
    bus.callSiteContext = (String agentId, String sessionId) =>
        StationScopeContext(
          teamId: 'team-1',
          agentId: agentId,
          sessionId: sessionId,
        );
    return bus;
  }

  /// 落库之外还留在会话里的"压缩已发生"通知（可能有 0/1/多条）。
  List<CoreMessage> compactionNotices(TreeStore store, String agentId) => store
      .messages(agentId, TreeStore.defaultSessionId)
      .where((CoreMessage m) => m.content.contains('上下文已压缩'))
      .toList();

  group('结论层：插件没接管 ⇒ 带人话原因（可选键）', () {
    test('早退不接管 ⇒ relaySkipReason 非空、JSON 有键、sink 收到分级位 false', () async {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = seedAgent(store);
      final CoreSession session = seedSession(store, agent);
      addTurns(store, agent, session, 3);
      final CompactionService service = newService(store);
      final List<bool> flags = <bool>[];
      service.relaySkipSink =
          (String a, String s, String r, {required bool hasSubscriber}) =>
              flags.add(hasSubscriber);
      service.relayHook = decliningHook(
        service,
        '没有插件订阅该点位（未声明 system.relay.context.compact）',
      );

      final CompactionResult result = await service.compact(
        agent.id,
        session.sessionId,
      );

      expect(result.compressed, isTrue, reason: '插件不接管不影响内置兜底照常压');
      expect(result.source, compactionSourceBuiltin);
      expect(result.relaySkipReason, contains('没有插件订阅'));
      expect(
        result.toJson()['relay_skip_reason'],
        result.relaySkipReason,
        reason: 'REST 响应必须把原因带出去（可选键、全量）',
      );
      expect(result.relaySkipHasSubscriber, isFalse);
      expect(
        flags,
        <bool>[false],
        reason: '分级位也要同步给观察者（决定要不要写进会话历史）',
      );
    });

    test('接管 ⇒ 结论**不带**该键（形状：老前端零感知）', () async {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = seedAgent(store);
      final CoreSession session = seedSession(store, agent);
      addTurns(store, agent, session, 3);
      final CompactionService service = newService(store);
      final List<String> seen = <String>[];
      service.relaySkipSink =
          (String a, String s, String r, {required bool hasSubscriber}) =>
              seen.add(r);
      service.relayHook = acceptingHook();

      final CompactionResult result = await service.compact(
        agent.id,
        session.sessionId,
      );

      expect(result.source, compactionSourceRelay);
      expect(result.relaySkipReason, isEmpty);
      expect(result.relaySkipHasSubscriber, isFalse);
      expect(
        result.toJson().containsKey('relay_skip_reason'),
        isFalse,
        reason: '接管成功就没有"没接管的原因"，键不该出现',
      );
      expect(seen, isEmpty, reason: '接管成功不该往 sink 上报原因');
    });

    test('水位线越界 / 中转点抛异常 ⇒ 原因说清是哪一种（都算"有订阅者却没接管"）', () async {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = seedAgent(store);
      final CoreSession session = seedSession(store, agent);
      addTurns(store, agent, session, 3);
      final CompactionService service = newService(store);

      // ① 回传的覆盖条数越界（原文只有 6 条）
      service.relayHook = acceptingHook(covered: 99);
      final CompactionResult overflow = await service.compact(
        agent.id,
        session.sessionId,
      );
      expect(overflow.source, compactionSourceBuiltin);
      expect(overflow.relaySkipReason, contains('covered_message_count'));
      expect(
        overflow.relaySkipHasSubscriber,
        isTrue,
        reason: '插件在场、回了包只是不合法 ⇒ 值得写进会话历史',
      );
      expect(
        store.session(agent.id, session.sessionId)!.compactedContext,
        isEmpty,
        reason: '越界的回包绝不能被采纳',
      );

      // ② 中转点自己抛异常
      service.relayHook =
          ({
            required CoreAgent agent,
            required CoreSession session,
            required String systemPrompt,
            required int totalMessageCount,
            required int compactedMessageCount,
            required String existingSummary,
            required Map<String, dynamic>? wireRequest,
          }) async => throw StateError('插件炸了');
      final CompactionResult thrown = await service.compact(
        agent.id,
        session.sessionId,
      );
      expect(thrown.relaySkipReason, contains('压缩中转点异常'));
      expect(thrown.relaySkipReason, contains('插件炸了'));
      expect(thrown.relaySkipHasSubscriber, isTrue);
    });

    test('压根没接中转点 ⇒ 不带原因（旧的响应形状逐字不变）', () async {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = seedAgent(store);
      final CoreSession session = seedSession(store, agent);
      addTurns(store, agent, session, 3);
      final CompactionService service = newService(store);
      expect(service.relayHook, isNull);

      final CompactionResult result = await service.compact(
        agent.id,
        session.sessionId,
      );

      expect(result.source, compactionSourceBuiltin);
      expect(result.relaySkipReason, isEmpty);
      expect(result.relaySkipHasSubscriber, isFalse);
      expect(result.toJson().containsKey('relay_skip_reason'), isFalse);
    });
  });

  group('接线层：真插件总线的"没接管"原因能上到结论', () {
    test('没有插件订阅 ⇒ 原因来自总线，且分级位 = false（早退）', () async {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = seedAgent(store);
      final CoreSession session = seedSession(store, agent);
      addTurns(store, agent, session, 3);
      final CompactionService service = newService(store);
      final List<bool> flags = <bool>[];
      service.relaySkipSink =
          (String a, String s, String r, {required bool hasSubscriber}) =>
              flags.add(hasSubscriber);
      final PluginBus bus = newBus();
      addTearDown(() async => bus.close());
      // 与 CoreServer._wirePluginRelayPoints 完全同一接法
      service.relayHook = bus.relayCompaction;
      bus.compactionSkipSink = service.noteRelaySkip;

      final CompactionResult result = await service.compact(
        agent.id,
        session.sessionId,
      );

      expect(result.source, compactionSourceBuiltin);
      expect(
        result.relaySkipReason,
        contains('没有插件订阅'),
        reason: '总线的订阅者判空必须能解释"插件为什么不生效"',
      );
      expect(result.toJson()['relay_skip_reason'], result.relaySkipReason);
      expect(
        result.relaySkipHasSubscriber,
        isFalse,
        reason: '没人订阅 = 早退：REST 要说，会话历史不该写',
      );
      expect(flags, <bool>[false]);
    });

    test('插件总开关关闭 ⇒ 原因区分"哪一层挡的"，同样是早退', () async {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = seedAgent(store);
      final CoreSession session = seedSession(store, agent);
      addTurns(store, agent, session, 3);
      final CompactionService service = newService(store);
      final PluginBus bus = newBus();
      addTearDown(() async => bus.close());
      bus.load(); // 先读盘（_loaded），否则后面的 relay 会把 enabled 重新覆盖成 true
      bus.enabled = false;
      service.relayHook = bus.relayCompaction;
      bus.compactionSkipSink = service.noteRelaySkip;

      final CompactionResult result = await service.compact(
        agent.id,
        session.sessionId,
      );

      expect(result.relaySkipReason, contains('插件总开关已关闭'));
      expect(result.relaySkipHasSubscriber, isFalse);
    });
  });

  group('会话层：压缩通知落库（刷新后仍在）+ 早退原因不进历史', () {
    /// 造一个"压缩真的会跑"的会话服务（工具循环内压缩那条入口最好驱动）。
    LlmAgentEngine wireConversation(TreeStore store, CompactionService service) {
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => null,
      );
      ConversationService(
        store: store,
        hub: WsHub(),
        settings: settings,
        compaction: service,
        engine: engine,
      );
      return engine;
    }

    test('内置压缩 + 早退不接管 ⇒ 写进 messages.jsonl、重开仍在、**不带**未接管原因', () async {
      final FileTreeStore store = FileTreeStore(paths());
      final CoreAgent agent = seedAgent(store);
      final CoreSession session = seedSession(store, agent);
      addTurns(store, agent, session, 3);
      final CompactionService service = newService(store);
      final List<String> reported = <String>[];
      service.relaySkipSink =
          (String a, String s, String r, {required bool hasSubscriber}) =>
              reported.add(r);
      final PluginBus bus = newBus();
      addTearDown(() async => bus.close());
      service.relayHook = bus.relayCompaction;
      bus.compactionSkipSink = service.noteRelaySkip;

      final LlmAgentEngine engine = wireConversation(store, service);
      final AgentRunContext? refreshed = await engine.toolTurnCompactor!(
        agent.id,
        session.sessionId,
        force: true,
      );

      expect(refreshed, isNotNull, reason: '压缩本身照常发生在内置路径上');
      final List<CoreMessage> notices = compactionNotices(store, agent.id);
      expect(notices, hasLength(1), reason: '每次都记一条（不去重），压缩了几次才查得出');
      final CoreMessage notice = notices.single;
      expect(
        notice.llmHidden,
        isTrue,
        reason: '落库但模型看不到：不插进下一轮提示词',
      );
      expect(notice.role, 'agent');
      expect(notice.kind, 'text');
      expect(notice.content, contains('来源：内置压缩'));
      expect(
        notice.content,
        isNot(contains('插件没有接管')),
        reason: '早退（没订阅者）只是"没人干这事"，不该写进历史当噪声',
      );
      expect(
        reported,
        isNot(isEmpty),
        reason: '原因本身照旧上报（REST/诊断要全量），只是没写进会话历史',
      );
      expect(reported.last, contains('没有插件订阅'));

      // 「刷新后仍在」：关掉存储再重开（= 刷新/重连），消息还在
      await store.close();
      final FileTreeStore reopened = FileTreeStore(paths());
      addTearDown(() async => reopened.close());
      final CoreMessage restored = compactionNotices(
        reopened,
        agent.id,
      ).single;
      expect(restored.content, notice.content);
      expect(restored.llmHidden, isTrue);
    });

    test('有订阅者但没接管 ⇒ 会话通知**带**原因', () async {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = seedAgent(store);
      final CoreSession session = seedSession(store, agent);
      addTurns(store, agent, session, 3);
      final CompactionService service = newService(store);
      service.relayHook = decliningHook(
        service,
        '插件回包的 messages 不是非空数组',
        hasSubscriber: true,
      );

      final LlmAgentEngine engine = wireConversation(store, service);
      await engine.toolTurnCompactor!(agent.id, session.sessionId, force: true);

      final CoreMessage notice = compactionNotices(store, agent.id).single;
      expect(notice.llmHidden, isTrue);
      expect(notice.content, contains('来源：内置压缩'));
      expect(notice.content, contains('这次插件没有接管'));
      expect(notice.content, contains('messages 不是非空数组'));
    });

    test('总结降级 ⇒ 降级原因也随同一条落库通知带出', () async {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = seedAgent(store);
      final CoreSession session = seedSession(store, agent);
      addTurns(store, agent, session, 3);
      final CompactionService service = newService(
        store,
        summarizer: _FakeSummarizer(error: '端点 429'),
      );
      service.relayHook = decliningHook(
        service,
        '插件回 null（原数据放行 = 不改动，未接管）',
        hasSubscriber: true,
      );

      final LlmAgentEngine engine = wireConversation(store, service);
      await engine.toolTurnCompactor!(agent.id, session.sessionId, force: true);

      final CoreMessage notice = compactionNotices(store, agent.id).single;
      expect(notice.llmHidden, isTrue);
      expect(notice.content, contains('截断摘要'));
      expect(notice.content, contains('失败原因'));
      expect(notice.content, contains('端点 429'));
      expect(notice.content, contains('原数据放行'));
    });

    test('插件接管 ⇒ 通知说清来源，不再谈"没接管"', () async {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = seedAgent(store);
      final CoreSession session = seedSession(store, agent);
      addTurns(store, agent, session, 3);
      final CompactionService service = newService(store);
      service.relayHook = acceptingHook();

      final LlmAgentEngine engine = wireConversation(store, service);
      await engine.toolTurnCompactor!(agent.id, session.sessionId, force: true);

      final CoreMessage notice = compactionNotices(store, agent.id).single;
      expect(notice.content, contains('来源：插件中转站压缩'));
      expect(notice.content, isNot(contains('插件没有接管')));
      expect(notice.llmHidden, isTrue);
    });
  });

  group('手动压缩（REST /compact）也落库，且与自动压缩同一条口径', () {
    /// 起一个真核心（真 HTTP 回环 + 真路由）。
    Future<CoreServer> startServer(
      TreeStore store,
      CompactionService service, {
      PluginBus? bus,
    }) => CoreServer.start(
      store: store,
      settings: settings,
      compaction: service,
      pluginBus: bus,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
    );

    /// 极简 REST 客户端：只发一个带 token 的 POST。
    Future<Map<String, dynamic>> postCompact(
      CoreServer server,
      String agentId,
    ) async {
      final HttpClient http = HttpClient();
      try {
        final HttpClientRequest request = await http.openUrl(
          'POST',
          Uri.parse(
            '${server.handshake.httpBaseUrl}/api/agents/$agentId/compact',
          ),
        );
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${server.token}',
        );
        request.headers.contentType = ContentType.json;
        request.add(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'session_id': TreeStore.defaultSessionId,
            }),
          ),
        );
        final HttpClientResponse response = await request.close();
        final String text = await utf8.decodeStream(response);
        final Object? decoded = text.trim().isEmpty ? null : jsonDecode(text);
        return decoded is Map<String, dynamic>
            ? decoded
            : <String, dynamic>{};
      } finally {
        http.close(force: true);
      }
    }

    test('点一次压缩：REST 带全量原因（早退也有）、通知落库且不含早退原因、重开仍在', () async {
      final FileTreeStore store = FileTreeStore(paths());
      final CoreAgent agent = seedAgent(store);
      final CoreSession session = seedSession(store, agent);
      addTurns(store, agent, session, 3);
      final CompactionService service = newService(store);
      // 真总线（空配置 ⇒ 没订阅者）+ 真接线由 CoreServer 自己做
      final PluginBus bus = newBus();
      addTearDown(() async => bus.close());
      final CoreServer server = await startServer(store, service, bus: bus);
      addTearDown(() async => server.close());

      final Map<String, dynamic> json = await postCompact(server, agent.id);

      expect(json['compressed'], isTrue, reason: '内置路径照常压');
      expect(json['source'], 'builtin');
      expect(
        json['relay_skip_reason'],
        contains('没有插件订阅'),
        reason: 'REST 是排障面：早退原因也要全量给出',
      );

      final CoreMessage notice = compactionNotices(store, agent.id).single;
      expect(notice.llmHidden, isTrue);
      expect(notice.content, contains('来源：内置压缩'));
      expect(
        notice.content,
        isNot(contains('插件没有接管')),
        reason: '会话通知过滤早退：没装插件的用户不该每条都看到这句',
      );

      // 手动压缩的通知同样"刷新后仍在"
      await server.close();
      await store.close();
      final FileTreeStore reopened = FileTreeStore(paths());
      addTearDown(() async => reopened.close());
      expect(compactionNotices(reopened, agent.id).single.content,
          notice.content);
    });

    test('有订阅者却没接管：REST 与通知都带原因（同一条文案口径）', () async {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = seedAgent(store);
      final CoreSession session = seedSession(store, agent);
      addTurns(store, agent, session, 3);
      final CompactionService service = newService(store);
      // 不传 pluginBus ⇒ 核心不动这条接线，我们直接摆一个"插件在场却没接管"的 hook
      service.relayHook = decliningHook(
        service,
        '插件回包不是对象（回 String），无法当上下文用',
        hasSubscriber: true,
      );
      final CoreServer server = await startServer(store, service);
      addTearDown(() async => server.close());

      final Map<String, dynamic> json = await postCompact(server, agent.id);

      expect(json['compressed'], isTrue);
      expect(json['relay_skip_reason'], contains('插件回包不是对象'));
      final CoreMessage notice = compactionNotices(store, agent.id).single;
      expect(notice.llmHidden, isTrue);
      expect(notice.content, contains('这次插件没有接管'));
      expect(notice.content, contains('插件回包不是对象'));
    });

    test('没压动（消息太少）⇒ 不落库，只有 REST 的 reason', () async {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = seedAgent(store);
      seedSession(store, agent); // 一条消息都没有：内置判 too_few_messages
      final CompactionService service = newService(store);
      final CoreServer server = await startServer(store, service);
      addTearDown(() async => server.close());

      final Map<String, dynamic> json = await postCompact(server, agent.id);

      expect(json['compressed'], isFalse);
      expect(json['reason'], 'too_few_messages');
      expect(
        compactionNotices(store, agent.id),
        isEmpty,
        reason: '"无事发生"不该往历史里塞消息',
      );
    });
  });
}

/// 假总结器：可配置"总结失败"（验降级路径）。
class _FakeSummarizer implements ContextSummarizer {
  _FakeSummarizer({this.error});

  final Object? error;
  int calls = 0;

  @override
  Future<String> summarize(
    CoreAgent agent,
    String prompt, {
    void Function(String notice)? onNotice,
    UsageSink? usageSink,
  }) async {
    calls++;
    if (error != null) throw StateError('$error');
    return '总结正文';
  }

  @override
  Future<void> close() async {}
}
