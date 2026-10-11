import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// `GET /api/agents/{agentId}/subagents/{subagentId}/transcript?session_id=`
/// ——**按 id 复查某临时员工的全部落盘工作数据**（对话与工具调用）。
///
/// 背景（用户 2026-10-11 断言：「subagent 的工作数据不落盘，导致非常不稳定」）：
/// 临时员工的对话与工具调用**物理上落在父会话的 `messages.jsonl`**（带 `subagent_id`
/// 标记），核心侧 `store.messages(sub_…, session)` 能把它"自己那一段"过滤出来——数据
/// 是在盘上的。但既有 REST 只有 `GET …/subagents`（只回身份，无过程），前端详情页只能
/// 从**窗口化加载**的中栏消息流里分栏（`lib/README.md` 不变量 19：只热视口附近）——
/// 老过程被窗口淘汰、或重启后只加载末尾页时，入口（名册落盘）还在、点进去却是空的。
///
/// 这条端点补的就是那条**复查通路**：直读落盘，不受中栏窗口 / 历史分页影响。
/// 「跨会话不保留」照旧是硬不变量（store/README.md 不变量 11）：只认**本会话**的那一份。
class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(String method, String path) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_server.token}',
    );
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder.bind(response).join();
    return _Res(
      response.statusCode,
      text.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  void close() => _http.close(force: true);
}

class _Res {
  const _Res(this.status, this.json);
  final int status;
  final Map<String, dynamic> json;
}

void main() {
  const String session = TreeStore.defaultSessionId;

  late MemoryStore inner;
  late SubagentRegistry registry;
  late SubagentStore store;
  late CoreSettings settings;
  late CoreServer server;
  late _Client client;
  late CoreAgent owner;

  setUp(() async {
    inner = MemoryStore();
    settings = CoreSettings();
    registry = SubagentRegistry(persistence: inner);
    store = SubagentStore(inner: inner, registry: registry);
    server = await CoreServer.start(
      store: store,
      subagents: registry,
      settings: settings,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    owner = store.createAgent(name: '队长', modelId: 'demo');
    client = _Client(server);
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  /// 名字册 + 往会话里喂**带标记**的消息（与 `ConversationService.persistSegment`
  /// 同一形态：`agentId = 会话主人`，靠 `subagent_id` 区分归属）。
  void seedSubagent(
    String subId, {
    String name = '甲',
    String sessionId = session,
  }) {
    store.putSubagent(
      CoreSubagent(
        id: subId,
        name: name,
        ownerAgentId: owner.id,
        sessionId: sessionId,
        parentId: owner.id,
        level: 1,
        agent: CoreAgent(
          id: subId,
          name: name,
          modelId: 'demo',
          createdAt: 100,
          updatedAt: 200,
        ),
        createdAt: 100,
        updatedAt: 200,
      ),
    );
  }

  void feed(
    String subId, {
    String sessionId = session,
    int from = 1000,
  }) {
    store.appendMessage(
      CoreMessage(
        id: 'task_$subId',
        agentId: owner.id,
        sessionId: sessionId,
        role: 'agent',
        content: '把 a.txt 改成 b',
        kind: MessageKinds.subagentTask,
        timestamp: from,
        subagentId: subId,
        subagentName: '甲',
        subagentParentId: owner.id,
        subagentLevel: 1,
      ),
    );
    store.appendMessage(
      CoreMessage(
        id: 'text_$subId',
        agentId: owner.id,
        sessionId: sessionId,
        role: 'agent',
        content: '我先看一眼文件',
        kind: MessageKinds.text,
        timestamp: from + 1,
        subagentId: subId,
        subagentName: '甲',
        subagentParentId: owner.id,
        subagentLevel: 1,
      ),
    );
    store.appendMessage(
      CoreMessage(
        id: 'tool_$subId',
        agentId: owner.id,
        sessionId: sessionId,
        role: 'agent',
        content: '',
        kind: MessageKinds.tool,
        toolName: 'read',
        toolCallId: 'call_$subId',
        timestamp: from + 2,
        subagentId: subId,
        subagentName: '甲',
        subagentParentId: owner.id,
        subagentLevel: 1,
      ),
    );
  }

  /// 主 agent 自己的消息 + 给它的完成报告（都不该进临时员工的工作数据）。
  void feedNoise(String otherId) {
    store.appendMessage(
      CoreMessage(
        id: 'main_text',
        agentId: owner.id,
        sessionId: session,
        role: 'agent',
        content: '主 agent 说话',
        kind: MessageKinds.text,
        timestamp: 900,
      ),
    );
    // 给发起者的后台完成报告：带标记，但它是**发起者**的输入，不进员工自己的历史
    store.appendMessage(
      CoreMessage(
        id: 'report_sub_a',
        agentId: owner.id,
        sessionId: session,
        role: 'agent',
        content: '做完了（甲）',
        kind: MessageKinds.subagentReport,
        timestamp: 5000,
        subagentId: 'sub_a',
        subagentName: '甲',
        subagentParentId: owner.id,
        subagentLevel: 1,
      ),
    );
    // 另一个临时员工的消息（按 id 复查时必须排掉）
    store.appendMessage(
      CoreMessage(
        id: 'text_$otherId',
        agentId: owner.id,
        sessionId: session,
        role: 'agent',
        content: '乙的过程',
        kind: MessageKinds.text,
        timestamp: 5001,
        subagentId: otherId,
        subagentName: '乙',
        subagentParentId: owner.id,
        subagentLevel: 1,
      ),
    );
  }

  test('按 id 复查：它自己的任务/正文/工具卡片都在，顺序按落库时间', () async {
    seedSubagent('sub_a');
    feed('sub_a');
    feedNoise('sub_b');

    final _Res res = await client.send(
      'GET',
      '/api/agents/${owner.id}/subagents/sub_a/transcript?session_id=$session',
    );
    expect(res.status, 200, reason: jsonEncode(res.json));
    expect(res.json['agent_id'], owner.id);
    expect(res.json['subagent_id'], 'sub_a');
    expect(res.json['session_id'], session);

    final List<dynamic> list = res.json['messages'] as List<dynamic>;
    final List<String> ids = list
        .map((dynamic m) => (m as Map<String, dynamic>)['id'] as String)
        .toList();
    expect(
      ids,
      <String>['task_sub_a', 'text_sub_a', 'tool_sub_a'],
      reason: '任务输入 / 正文 / 工具卡片三类都是它的工作数据；主 agent 的、'
          '给发起者的报告、别的员工的一律不进',
    );
    expect(res.json['total'], 3);
    // 工具卡片带工具字段（详情页要渲染调用与结果）
    final Map<String, dynamic> tool = list.last as Map<String, dynamic>;
    expect(tool['kind'], MessageKinds.tool);
    expect(tool['tool_name'], 'read');
    expect(tool['subagent_id'], 'sub_a');
  });

  test('跨会话不保留：查别的会话只得到空表（入口照旧随会话走）', () async {
    seedSubagent('sub_a');
    feed('sub_a');
    final CoreSession other =
        store.createSession(owner.id, title: '另一个会话')!;

    final _Res res = await client.send(
      'GET',
      '/api/agents/${owner.id}/subagents/sub_a/transcript'
          '?session_id=${other.sessionId}',
    );
    // 名册按会话隔离：sub_a 属于 default 会话，在别的会话里查不到 ⇒ 可读错误
    expect(res.status, 404, reason: jsonEncode(res.json));
    expect(res.json['detail'].toString(), contains('会话'));
  });

  test('未知 id ⇒ 404 + 可读原因（不静默回空表）', () async {
    final _Res res = await client.send(
      'GET',
      '/api/agents/${owner.id}/subagents/sub_missing/transcript'
          '?session_id=$session',
    );
    expect(res.status, 404);
    expect(res.json['detail'], contains('临时员工'));
  });

  test('agent 不存在 ⇒ 404（与邻居端点同口径）', () async {
    final _Res res = await client.send(
      'GET',
      '/api/agents/agt_missing/subagents/sub_a/transcript?session_id=$session',
    );
    expect(res.status, 404);
    expect(res.json['detail'], contains('agent 不存在'));
  });

  test('重启复查：换一套装配（内存全空）读同一份落盘，过程仍在', () async {
    seedSubagent('sub_a');
    feed('sub_a');
    final String id = 'sub_a';

    // "重启"：全新 registry / store，内存索引全空，只共享盘（MemoryStore 不落真盘，
    // 这里用新 FileTreeStore 才能验证真落盘；MemoryStore 场景退化为同进程索引丢失）
    final Directory temp = Directory.systemTemp.createTempSync('tree_replay_');
    try {
      final TreePaths paths = TreePaths(temp.path);
      paths.ensureLayoutSync();
      final FileTreeStore fileStore = FileTreeStore(paths);
      final SubagentRegistry fileRegistry =
          SubagentRegistry(persistence: fileStore);
      final SubagentStore fileWrapped =
          SubagentStore(inner: fileStore, registry: fileRegistry);
      // 直接按真落盘语义跑一遍：append 后 flush，再换新装配读
      final CoreAgent o = fileWrapped.createAgent(name: '队长', modelId: 'demo');
      fileWrapped.ensureDefaultSession(o.id);
      fileWrapped.putSubagent(
        CoreSubagent(
          id: id,
          name: '甲',
          ownerAgentId: o.id,
          sessionId: session,
          parentId: o.id,
          level: 1,
          agent: CoreAgent(
            id: id,
            name: '甲',
            modelId: 'demo',
            createdAt: 100,
            updatedAt: 200,
          ),
          createdAt: 100,
          updatedAt: 200,
        ),
      );
      for (final CoreMessage m in <CoreMessage>[
        CoreMessage(
          id: 't1',
          agentId: o.id,
          sessionId: session,
          role: 'agent',
          content: '开工',
          kind: MessageKinds.text,
          timestamp: 10,
          subagentId: id,
        ),
        CoreMessage(
          id: 't2',
          agentId: o.id,
          sessionId: session,
          role: 'agent',
          content: '交活',
          kind: MessageKinds.text,
          timestamp: 20,
          subagentId: id,
        ),
      ]) {
        fileWrapped.appendMessage(m);
      }
      await fileStore.flush();

      final FileTreeStore reopened = FileTreeStore(paths);
      final SubagentRegistry reopenedRegistry =
          SubagentRegistry(persistence: reopened);
      final SubagentStore reopenedStore =
          SubagentStore(inner: reopened, registry: reopenedRegistry);
      expect(reopenedRegistry.count, 0, reason: '新进程内存里还没有任何临时员工');
      final List<CoreMessage> replay =
          reopenedStore.messages(id, session);
      expect(
        replay.map((CoreMessage m) => m.id).toList(),
        <String>['t1', 't2'],
        reason: '复查读的是落盘的 messages.jsonl（按 subagent_id 过滤），与内存无关',
      );
    } finally {
      for (int i = 0; i < 5; i++) {
        try {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
          break;
        } catch (_) {
          // Windows 落盘句柄晚一拍释放
        }
      }
    }
  });
}
