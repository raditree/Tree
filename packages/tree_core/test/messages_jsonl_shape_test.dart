import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// **`messages.jsonl` 的形状没有变**（用断言钉住，不是"看起来没动"）。
///
/// 逐调用用量（本任务 ③）**另起一份** `<会话目录>/usage.jsonl`，一行一次调用；
/// 消息日志的行形状必须**逐键不变**——否则老前端、老会话文件、`CoreMessage`
/// 的既有契约都会被动到。这里用真 `FileTreeStore` + 真磁盘把这件事钉死。
void main() {
  late Directory root;
  late TreePaths paths;
  late FileTreeStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tree_messages_shape_');
    paths = TreePaths(root.path);
    store = FileTreeStore(paths);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 普通文本消息在 jsonl 里的**基线**键集（③ 之前就是这样，改完必须一模一样）。
  const Set<String> baselineKeys = <String>{
    'id',
    'agent_id',
    'session_id',
    'role',
    'content',
    'timestamp',
    'kind',
    'tool_name',
    'tool_arguments',
    'tool_result',
    'tool_call_id',
    'usage',
    'attachments',
    'options',
    'answered',
    'is_streaming',
  };

  /// 公开 usage map 允许出现的键（`agentUsageMap` 的既有契约）。
  const Set<String> usageKeys = <String>{
    'prompt_tokens',
    'completion_tokens',
    'total_tokens',
    'max_tokens',
    'cached_tokens',
    'estimated',
    'trimmed_messages',
  };

  List<Map<String, dynamic>> linesOf(String path) => <Map<String, dynamic>>[
    for (final String line in const LineSplitter().convert(
      File(path).readAsStringSync(),
    ))
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
  ];

  test('文本消息行的键集逐键不变；usage 也只含既有键', () async {
    final CoreAgent agent = store.createAgent(
      name: '用例',
      systemPrompt: 's',
      modelId: 'demo',
    );
    final CoreSession session = store.ensureDefaultSession(agent.id);
    store.appendMessage(
      CoreMessage(
        id: 'msg_with_usage',
        agentId: agent.id,
        sessionId: session.sessionId,
        role: 'agent',
        content: '你好',
        timestamp: 1000,
        // 逐调用用量**绝不**进这一份（内部键由引擎剥掉；这里直接给公开口径）
        usage: <String, dynamic>{
          'prompt_tokens': 10,
          'completion_tokens': 2,
          'total_tokens': 12,
          'max_tokens': 64000,
        },
      ),
    );
    store.appendMessage(
      CoreMessage(
        id: 'msg_plain',
        agentId: agent.id,
        sessionId: session.sessionId,
        role: 'user',
        content: 'hi',
        timestamp: 2000,
      ),
    );
    await store.flush();

    final String messagesPath = paths.messagesFile(agent.id, session.sessionId);
    final List<Map<String, dynamic>> lines = linesOf(messagesPath);
    expect(lines, hasLength(2));
    for (final Map<String, dynamic> line in lines) {
      expect(
        line.keys.toSet(),
        baselineKeys,
        reason: '③ 只新增 usage.jsonl，messages.jsonl 的行形状必须逐键不变',
      );
    }
    expect(
      (lines.first['usage'] as Map<String, dynamic>).keys.toSet().difference(
        usageKeys,
      ),
      isEmpty,
      reason: 'usage 里不许出现逐调用新增键（source / duration_ms …）',
    );
    expect(
      (lines.first['usage'] as Map<String, dynamic>)['cached_tokens'],
      isNull,
      reason: '没命中缓存时连键都不写（既有口径）',
    );

    // 老会话照常打开：同一行能被既有解析器原样读回
    final CoreMessage reopened = CoreMessage.fromJson(lines.last);
    expect(reopened.content, 'hi');
    expect(reopened.role, 'user');
    expect(reopened.usage, isNull);
    expect(
      CoreMessage.fromJson(lines.first).usage!['prompt_tokens'],
      10,
    );
  });

  test('写消息不会凭空创建 usage.jsonl（两份账互不相干）', () async {
    final CoreAgent agent = store.createAgent(name: 'a', modelId: 'demo');
    final CoreSession session = store.ensureDefaultSession(agent.id);
    store.appendMessage(
      CoreMessage(
        id: 'msg_1',
        agentId: agent.id,
        sessionId: session.sessionId,
        role: 'user',
        content: 'x',
        timestamp: 1,
      ),
    );
    await store.flush();
    expect(
      File(paths.usageFile(agent.id, session.sessionId)).existsSync(),
      isFalse,
    );
    expect(File(paths.messagesFile(agent.id, session.sessionId)).existsSync(), isTrue);
  });

  test('usage.jsonl 与 messages.jsonl 各写各的：互不覆盖、互不追加到对方', () async {
    final CoreAgent agent = store.createAgent(name: 'a', modelId: 'demo');
    final CoreSession session = store.ensureDefaultSession(agent.id);
    store.appendMessage(
      CoreMessage(
        id: 'msg_1',
        agentId: agent.id,
        sessionId: session.sessionId,
        role: 'user',
        content: 'x',
        timestamp: 1,
      ),
    );
    await store.flush();
    final String messagesPath = paths.messagesFile(agent.id, session.sessionId);
    final String before = File(messagesPath).readAsStringSync();

    final UsageLog usageLog = UsageLog(paths);
    usageLog.record(
      agent.id,
      session.sessionId,
      UsageCall(
        at: DateTime(2026, 10, 3, 12),
        source: UsageSource.turn,
        model: 'demo',
        promptTokens: 5,
        completionTokens: 1,
      ),
    );
    await usageLog.flush();

    expect(File(messagesPath).readAsStringSync(), before, reason: '消息日志逐字节不变');
    final List<Map<String, dynamic>> usageLines = linesOf(
      paths.usageFile(agent.id, session.sessionId),
    );
    expect(usageLines, hasLength(1));
    expect(usageLines.single['source'], 'turn');
  });

  test('删会话把两份账一起带走（布局同一目录的既有保证）', () async {
    final CoreAgent agent = store.createAgent(name: 'a', modelId: 'demo');
    final CoreSession session = store.createSession(agent.id, title: 't')!;
    final UsageLog usageLog = UsageLog(paths);
    usageLog.record(
      agent.id,
      session.sessionId,
      UsageCall(
        at: DateTime(2026, 10, 3, 12),
        source: UsageSource.turn,
        model: 'demo',
      ),
    );
    await usageLog.flush();
    expect(
      File(paths.usageFile(agent.id, session.sessionId)).existsSync(),
      isTrue,
    );

    expect(store.deleteSession(agent.id, session.sessionId), isTrue);
    await store.flush();
    expect(
      Directory(paths.sessionDir(agent.id, session.sessionId)).existsSync(),
      isFalse,
      reason: '删会话递归删目录 ⇒ usage.jsonl 随之消失，不残留到任何全局位置',
    );
  });
}
