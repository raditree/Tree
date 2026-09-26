import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'store_contract.dart';

void main() {
  late Directory tempDir;
  late TreePaths paths;
  final List<String> logs = <String>[];

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('tree_store_test_');
    paths = TreePaths(tempDir.path);
    logs.clear();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  FileTreeStore newStore() => FileTreeStore(paths, log: logs.add);

  // ① 与内存实现共享的行为契约
  runStoreContract('FileTreeStore', () => FileTreeStore(paths));

  // ② 落盘特有：文件布局、重开、手改、损坏容错
  group('FileTreeStore 落盘', () {
    test('首次构造即建立 ~/.tree 目录骨架', () async {
      newStore();
      // ensureLayout 是异步的：给它一个事件循环
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (final String dir in <String>[
        paths.root,
        paths.configDir,
        paths.modelsDir,
        paths.agentsDir,
        paths.sessionsDataDir,
      ]) {
        expect(Directory(dir).existsSync(), isTrue, reason: dir);
      }
    });

    test('文件布局与方案一致：agent yaml + 会话 json + 消息 jsonl', () async {
      final FileTreeStore store = newStore();
      final CoreAgent agent = store.createAgent(
        name: '布局',
        systemPrompt: '第一行\n第二行',
        modelId: 'm1',
      );
      store.createSession(agent.id, title: '第二个');
      store.appendMessage(
        CoreMessage(
          id: 'msg_1',
          agentId: agent.id,
          sessionId: TreeStore.defaultSessionId,
          role: 'user',
          content: '你好',
          timestamp: 1700000000000,
        ),
      );
      await store.flush();

      final File agentFile = File(paths.agentFile(agent.id));
      expect(agentFile.existsSync(), isTrue);
      final String agentYaml = agentFile.readAsStringSync();
      // 多行 system_prompt 应写成块标量而不是转义字符串（人类可读）
      expect(agentYaml, contains('|-'));

      final File meta = File(
        paths.sessionMetaFile(agent.id, TreeStore.defaultSessionId),
      );
      expect(meta.existsSync(), isTrue);
      // 会话元数据是缩进 JSON，便于手看
      expect(meta.readAsStringSync(), contains('\n  "session_id"'));

      final File messages = File(
        paths.messagesFile(agent.id, TreeStore.defaultSessionId),
      );
      expect(messages.existsSync(), isTrue);
      final List<String> lines = const LineSplitter()
          .convert(messages.readAsStringSync())
          .where((String l) => l.trim().isNotEmpty)
          .toList();
      expect(lines, hasLength(1));
      expect(jsonDecode(lines.first), containsPair('content', '你好'));

      // 原子写不残留临时文件
      expect(
        tempDir
            .listSync(recursive: true)
            .where((FileSystemEntity e) => e.path.endsWith('.tmp')),
        isEmpty,
      );
      await store.close();
    });

    test('重开（模拟重启核心进程）后 agent/会话/消息完整保留且顺序不变', () async {
      final FileTreeStore first = newStore();
      final CoreAgent agent = first.createAgent(
        name: '持久',
        systemPrompt: '提示词',
        modelId: 'm1',
      );
      first.updateAgent(agent.id, name: '改名后');
      final CoreSession session = first.createSession(agent.id, title: '第二会话')!;
      first.setSelectedSpecs(agent.id, session.sessionId, <String>['spec_a']);
      for (int i = 0; i < 5; i++) {
        first.appendMessage(
          CoreMessage(
            id: 'msg_$i',
            agentId: agent.id,
            sessionId: session.sessionId,
            role: i.isEven ? 'user' : 'agent',
            content: '第$i条',
            timestamp: 1700000000000 + i,
          ),
        );
      }
      await first.close();

      final FileTreeStore second = newStore();
      final CoreAgent? restored = second.agent(agent.id);
      expect(restored, isNotNull);
      expect(restored!.name, '改名后');
      expect(restored.systemPrompt, '提示词');
      expect(restored.modelId, 'm1');
      expect(
        second.sessions(agent.id).map((CoreSession s) => s.sessionId),
        contains(session.sessionId),
      );
      expect(second.session(agent.id, session.sessionId)?.title, '第二会话');
      expect(
        second.session(agent.id, session.sessionId)?.selectedSpecIds,
        <String>['spec_a'],
      );
      expect(
        second
            .messages(agent.id, session.sessionId)
            .map((CoreMessage m) => m.content)
            .toList(),
        <String>['第0条', '第1条', '第2条', '第3条', '第4条'],
      );
      expect(second.messageCount(agent.id, session.sessionId), 5);
      expect(second.lastTextMessage(agent.id)?.content, '第3条');
      await second.close();
    });

    test('用户手改 agent yaml 后重启即生效（含多行 system_prompt）', () async {
      final FileTreeStore first = newStore();
      final CoreAgent agent = first.createAgent(name: '原名字', modelId: 'm1');
      await first.close();

      File(paths.agentFile(agent.id)).writeAsStringSync('''
id: ${agent.id}
name: 手改后的名字
system_prompt: |-
  你是助手。
  请简短回答。
model_id: m2
workspace_id: ws_hand
team_member_count: 0
max_level: 1
max_members_per_level: 0
created_at: 2026-01-01T00:00:00.000
updated_at: 2026-01-02T00:00:00.000
''');

      final FileTreeStore second = newStore();
      final CoreAgent? restored = second.agent(agent.id);
      expect(restored?.name, '手改后的名字');
      expect(restored?.systemPrompt, '你是助手。\n请简短回答。');
      expect(restored?.modelId, 'm2');
      await second.close();
    });

    test('messages.jsonl 的损坏行被跳过，其余消息照常可读', () async {
      final FileTreeStore first = newStore();
      final CoreAgent agent = first.createAgent(name: 'a');
      first.appendMessage(
        CoreMessage(
          id: 'm1',
          agentId: agent.id,
          sessionId: TreeStore.defaultSessionId,
          role: 'user',
          content: '好的一',
          timestamp: 1,
        ),
      );
      await first.close();

      // 模拟"崩溃时写了一半"与"用户手改坏了一行"
      final File file = File(
        paths.messagesFile(agent.id, TreeStore.defaultSessionId),
      );
      file.writeAsStringSync(
        '${file.readAsStringSync()}'
        '{"id":"m2","agent_id":"${agent.id}","role":"agent",\n'
        '这不是 JSON\n'
        '{"id":"m3","agent_id":"${agent.id}","session_id":"session_default",'
        '"role":"agent","content":"第三","kind":"text","timestamp":3}\n',
      );

      final FileTreeStore second = newStore();
      final List<CoreMessage> messages = second.messages(
        agent.id,
        TreeStore.defaultSessionId,
      );
      expect(messages.map((CoreMessage m) => m.content).toList(), <String>[
        '好的一',
        '第三',
      ]);
      expect(second.skippedMessageLines, 2);
      expect(logs.join('\n'), contains('无法解析'));
      await second.close();
    });

    test('单个 session.json 损坏只影响该会话，不影响其他会话与 agent', () async {
      final FileTreeStore first = newStore();
      final CoreAgent agent = first.createAgent(name: 'a');
      final CoreSession good = first.createSession(agent.id, title: '好的')!;
      final CoreSession bad = first.createSession(agent.id, title: '坏的')!;
      await first.close();

      File(paths.sessionMetaFile(agent.id, bad.sessionId))
          .writeAsStringSync('{ 这不是合法 JSON');

      final FileTreeStore second = newStore();
      final List<String> ids = second
          .sessions(agent.id)
          .map((CoreSession s) => s.sessionId)
          .toList();
      expect(ids, contains(good.sessionId));
      expect(ids, isNot(contains(bad.sessionId)));
      expect(second.agent(agent.id), isNotNull);
      expect(logs.join('\n'), contains('会话元数据损坏'));
      await second.close();
    });

    test('deleteAgent 会连同其数据目录一起删除', () async {
      final FileTreeStore store = newStore();
      final CoreAgent agent = store.createAgent(name: 'a');
      store.appendMessage(
        CoreMessage(
          id: 'm1',
          agentId: agent.id,
          sessionId: TreeStore.defaultSessionId,
          role: 'user',
          content: 'x',
          timestamp: 1,
        ),
      );
      await store.flush();
      expect(Directory(paths.agentDataDir(agent.id)).existsSync(), isTrue);
      expect(store.deleteAgent(agent.id), isTrue);
      await store.flush();
      expect(Directory(paths.agentDataDir(agent.id)).existsSync(), isFalse);
      expect(File(paths.agentFile(agent.id)).existsSync(), isFalse);
      await store.close();
    });

    test('clearMessages 删除 jsonl 文件；之后仍可继续追加', () async {
      final FileTreeStore store = newStore();
      final CoreAgent agent = store.createAgent(name: 'a');
      store.appendMessage(
        CoreMessage(
          id: 'm1',
          agentId: agent.id,
          sessionId: TreeStore.defaultSessionId,
          role: 'user',
          content: 'x',
          timestamp: 1,
        ),
      );
      await store.flush();
      final File file = File(
        paths.messagesFile(agent.id, TreeStore.defaultSessionId),
      );
      expect(file.existsSync(), isTrue);
      expect(store.clearMessages(agent.id, sessionId: 'all'), 1);
      await store.flush();
      expect(file.existsSync(), isFalse);
      store.appendMessage(
        CoreMessage(
          id: 'm2',
          agentId: agent.id,
          sessionId: TreeStore.defaultSessionId,
          role: 'user',
          content: 'y',
          timestamp: 2,
        ),
      );
      await store.close();
      final FileTreeStore reopened = newStore();
      expect(
        reopened
            .messages(agent.id, TreeStore.defaultSessionId)
            .map((CoreMessage m) => m.content),
        <String>['y'],
      );
      await reopened.close();
    });

    test('路径穿越的 id 在触达文件系统时被拒绝（写入不会逃出数据根）', () {
      final FileTreeStore store = newStore();
      // 纯内存查找只返回 null（不构造路径，也不会误报）
      expect(store.session('agt_1', '../../evil'), isNull);
      expect(store.agent('../evil'), isNull);
      // 任何会落到磁盘的入口都必须先过 safeSegment
      final CoreAgent agent = store.createAgent(name: '穿越');
      expect(
        () => store.createSession(agent.id, sessionId: '../evil'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => store.appendMessage(
          CoreMessage(
            id: 'm1',
            agentId: 'agt_1',
            sessionId: '../../evil',
            role: 'user',
            content: 'x',
            timestamp: 1,
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => store.putAgent(
          CoreAgent(id: '../evil', name: 'x', createdAt: 1, updatedAt: 1),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(() => TreePaths.safeSegment('a/b'), throwsA(isA<ArgumentError>()));
      expect(() => TreePaths.safeSegment('..'), throwsA(isA<ArgumentError>()));
      expect(TreePaths.safeSegment('agt_1-x.y'), 'agt_1-x.y');
    });

    test('大量消息只读尾部即可得到预览（lastTextMessage 不依赖整份历史）', () async {
      final FileTreeStore store = newStore();
      final CoreAgent agent = store.createAgent(name: 'a');
      final StringBuffer big = StringBuffer();
      for (int i = 0; i < 50; i++) {
        big.write('填充' * 200);
        store.appendMessage(
          CoreMessage(
            id: 'msg_$i',
            agentId: agent.id,
            sessionId: TreeStore.defaultSessionId,
            role: 'user',
            content: '用户$i',
            timestamp: i,
          ),
        );
      }
      store.appendMessage(
        CoreMessage(
          id: 'last',
          agentId: agent.id,
          sessionId: TreeStore.defaultSessionId,
          role: 'agent',
          content: '最后一条',
          timestamp: 999,
        ),
      );
      await store.close();

      final FileTreeStore second = newStore();
      expect(second.lastTextMessage(agent.id)?.content, '最后一条');
      await second.close();
    });
  });
}
