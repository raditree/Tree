import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_local_exec/tree_local_exec.dart';

import 'atomic_file.dart';
import '../util/ids.dart';
import 'tree_paths.dart';
import 'tree_store.dart';
import 'write_queue.dart';
import 'yaml_codec.dart';

/// 落盘存储实现：`~/.tree` 下的 YAML（配置）+ JSON/JSONL（会话数据）。
///
/// 设计要点：
/// - **懒加载 + 进程内缓存**：agent 列表、每 agent 的会话元数据、每会话的消息
///   都只在首次访问时读盘，之后走缓存；写入同时更新缓存与磁盘。
/// - **write-behind**：写操作立即返回，落盘任务排进 [WriteQueue]（每路径串行），
///   [flush] 可等待全部完成。详见 [TreeStore] 的写语义说明。
/// - **崩溃容错**：会话元数据原子快照（临时文件 + 改名），消息使用追加日志；
///   读取时对无法解析的行**跳过并计数**，绝不因为一行坏数据让整个会话打不开。
/// - **人类可手改**：agent/模型/设置是 YAML（多行文本用块标量），会话元数据是
///   缩进 JSON，消息是一行一条的 jsonl；用户可以直接打开、修改、再启动核心。
///
/// 注意：本实现不保证与**外部同时修改同一目录**的其他进程一致（桌面形态是
/// 单用户单实例；多实例会各自持有内存缓存，互不感知）。
class FileTreeStore implements TreeStore {
  FileTreeStore(this.paths, {this.log}) {
    // 首次启动即建好目录骨架，方便用户直接打开 ~/.tree 查看/手改配置
    unawaited(
      paths.ensureLayout().catchError((Object error) {
        log?.call('创建数据目录失败：$error');
      }),
    );
  }

  /// 路径布局。
  final TreePaths paths;

  /// 可读日志回调（落盘错误、跳过的损坏行等）。核心进程接到 stderr。
  final void Function(String message)? log;

  final Map<String, CoreAgent> _agents = <String, CoreAgent>{};
  final Map<String, Map<String, CoreSession>> _sessions =
      <String, Map<String, CoreSession>>{};
  final Map<String, List<CoreMessage>> _messages =
      <String, List<CoreMessage>>{};
  final Map<String, CoreMessage?> _preview = <String, CoreMessage?>{};
  final WriteQueue _queue = WriteQueue();

  bool _agentsScanned = false;
  final Set<String> _agentLoaded = <String>{};

  /// 累计跳过的损坏消息行数（自检与日志用）。
  int skippedMessageLines = 0;

  /// 预览只需读文件尾部，避免为列表页一行摘要读进整份历史。
  static const int _previewTailBytes = 32 * 1024;

  static const String _agentHeader =
      'Tree agent 配置：可直接手改（system_prompt 支持多行），'
      '改动在核心进程下次启动时生效。';

  // ── agent ────────────────────────────────────────────────────────────

  @override
  List<CoreAgent> agents() => _scanAgents().toList()
    ..sort((CoreAgent a, CoreAgent b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  CoreAgent? agent(String id) {
    _scanAgents();
    return _agents[id];
  }

  @override
  List<CoreAgent> teams() =>
      agents().where((CoreAgent a) => a.teamId.isEmpty).toList(growable: false);

  @override
  List<CoreAgent> members(String teamId) =>
      agents()
          .where((CoreAgent a) => a.teamId == teamId)
          .toList(growable: false)
        ..sort(
          (CoreAgent a, CoreAgent b) => a.createdAt == b.createdAt
              ? a.id.compareTo(b.id)
              : a.createdAt.compareTo(b.createdAt),
        );

  @override
  CoreAgent createAgent({
    required String name,
    String systemPrompt = '',
    String modelId = '',
    int teamMemberCount = 0,
    int maxLevel = TeamLimits.defaultMaxLevel,
    int maxMembersPerLevel = TeamLimits.defaultMaxMembersPerLevel,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String id = CoreIds.next('agt');
    final CoreAgent agent = CoreAgent(
      id: id,
      name: name.isEmpty ? '新 Agent' : name,
      systemPrompt: systemPrompt,
      modelId: modelId,
      // 桌面端工作空间就是本机目录（M4 由用户指定）；此处先给稳定占位 id
      workspaceId: 'ws_$id',
      teamMemberCount: teamMemberCount,
      maxLevel: maxLevel,
      maxMembersPerLevel: maxMembersPerLevel,
      createdAt: now,
      updatedAt: now,
    );
    _agents[id] = agent;
    _agentLoaded.add(id); // 新 agent 磁盘上还没有任何会话，无需扫描
    _sessions[id] = <String, CoreSession>{};
    _writeAgent(agent);
    ensureDefaultSession(id);
    return agent;
  }

  @override
  void putAgent(CoreAgent agent) {
    _loadAgent(agent.id);
    _agents[agent.id] = agent;
    _writeAgent(agent);
    ensureDefaultSession(agent.id);
  }

  @override
  CoreAgent? updateAgent(
    String id, {
    String? name,
    String? systemPrompt,
    String? modelId,
  }) {
    final CoreAgent? agent = this.agent(id);
    if (agent == null) return null;
    if (name != null) agent.name = name;
    if (systemPrompt != null) agent.systemPrompt = systemPrompt;
    if (modelId != null) agent.modelId = modelId;
    agent.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _writeAgent(agent);
    return agent;
  }

  @override
  bool deleteAgent(String id) {
    _loadAgent(id);
    final bool inCache = _agents.remove(id) != null;
    _agentLoaded.remove(id);
    // 缓存里没有也可能是磁盘上存在但尚未装载的情形（`_scanAgents` 之前）
    if (!inCache && !File(paths.agentFile(id)).existsSync()) return false;
    _sessions.remove(id);
    _messages.removeWhere((String key, _) => key.startsWith('$id::'));
    _preview.removeWhere((String key, _) => key.startsWith('$id::'));
    final String agentFile = paths.agentFile(id);
    final String dataDir = paths.agentDataDir(id);
    _queue.enqueue(agentFile, () async {
      final File file = File(agentFile);
      if (await file.exists()) await file.delete();
    });
    _queue.enqueue(dataDir, () async {
      final Directory dir = Directory(dataDir);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return true;
  }

  @override
  CoreMessage? lastTextMessage(String agentId) {
    _loadAgent(agentId);
    final List<CoreSession> ordered = sessions(agentId);
    for (final CoreSession session in ordered) {
      final CoreMessage? preview = _previewFor(agentId, session.sessionId);
      if (preview != null) return preview;
    }
    return null;
  }

  // ── 会话 ─────────────────────────────────────────────────────────────

  @override
  List<CoreSession> sessions(String agentId) {
    _loadAgent(agentId);
    final Map<String, CoreSession>? byId = _sessions[agentId];
    if (byId == null) return <CoreSession>[];
    return byId.values.toList()..sort(
      (CoreSession a, CoreSession b) => b.updatedAt.compareTo(a.updatedAt),
    );
  }

  @override
  CoreSession? session(String agentId, String sessionId) {
    _loadAgent(agentId);
    return _sessions[agentId]?[sessionId];
  }

  @override
  CoreSession ensureDefaultSession(String agentId) {
    _loadAgent(agentId);
    final CoreSession? existing = session(agentId, TreeStore.defaultSessionId);
    if (existing != null) return existing;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final CoreSession created = CoreSession(
      sessionId: TreeStore.defaultSessionId,
      agentId: agentId,
      title: '默认会话',
      createdAt: now,
      updatedAt: now,
    );
    _sessions.putIfAbsent(
      agentId,
      () => <String, CoreSession>{},
    )[created.sessionId] = created;
    _writeSession(created);
    return created;
  }

  @override
  CoreSession? createSession(
    String agentId, {
    String title = '',
    String? sessionId,
  }) {
    _loadAgent(agentId);
    if (_agents[agentId] == null) return null;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String id = (sessionId != null && sessionId.isNotEmpty)
        ? sessionId
        : CoreIds.next('ses');
    final CoreSession? existing = _sessions[agentId]?[id];
    if (existing != null) return existing;
    final CoreSession created = CoreSession(
      sessionId: id,
      agentId: agentId,
      title: title.isEmpty ? '新会话' : title,
      createdAt: now,
      updatedAt: now,
    );
    _sessions.putIfAbsent(agentId, () => <String, CoreSession>{})[id] = created;
    _writeSession(created);
    return created;
  }

  @override
  bool renameSession(String agentId, String sessionId, String title) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    session.title = title.isEmpty ? session.title : title;
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _writeSession(session);
    return true;
  }

  @override
  bool deleteSession(String agentId, String sessionId) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    _sessions[agentId]?.remove(sessionId);
    final String key = _key(agentId, sessionId);
    _messages.remove(key);
    _preview.remove(key);
    final String dir = paths.sessionDir(agentId, sessionId);
    _queue.enqueue(dir, () async {
      final Directory target = Directory(dir);
      if (await target.exists()) await target.delete(recursive: true);
    });
    return true;
  }

  @override
  int setSelectedSpecs(String agentId, String sessionId, List<String> specIds) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return 0;
    session.selectedSpecIds = List<String>.of(specIds);
    _writeSession(session);
    return session.selectedSpecIds.length;
  }

  @override
  bool setCompacted(
    String agentId,
    String sessionId, {
    required String summary,
    required int messageCount,
  }) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    session.compactedSummary = summary;
    // 内置摘要路径接管：中转站产出的列表作废（两者互斥，见 CoreSession）
    session.compactedContext = <Map<String, dynamic>>[];
    session.compactedMessageCount = messageCount < 0 ? 0 : messageCount;
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _writeSession(session);
    return true;
  }

  @override
  bool setCompactedContext(
    String agentId,
    String sessionId, {
    required List<Map<String, dynamic>> context,
    required int coveredMessageCount,
  }) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    session.compactedContext = context;
    // 中转站路径接管：内置摘要作废（下一次内置压缩会重新总结当前前缀）
    session.compactedSummary = '';
    session.compactedMessageCount = coveredMessageCount < 0
        ? 0
        : coveredMessageCount;
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _writeSession(session);
    return true;
  }

  // ── 消息 ─────────────────────────────────────────────────────────────

  @override
  List<CoreMessage> messages(String agentId, String sessionId) {
    _loadMessages(agentId, sessionId);
    return List<CoreMessage>.unmodifiable(
      _messages[_key(agentId, sessionId)] ?? const <CoreMessage>[],
    );
  }

  @override
  int messageCount(String agentId, String sessionId) =>
      messages(agentId, sessionId).where((CoreMessage m) => !m.isTool).length;

  @override
  CoreMessage appendMessage(CoreMessage message) {
    _loadAgent(message.agentId);
    _loadMessages(message.agentId, message.sessionId);
    final String key = _key(message.agentId, message.sessionId);
    final List<CoreMessage> list = _messages.putIfAbsent(
      key,
      () => <CoreMessage>[],
    );
    // 单调序号（Q3）：同毫秒的多条消息在"按时间戳排序"的历史接口里会重排
    // （`List.sort` 不保证稳定），把落库顺序直接压进时间戳就不会漂移。
    message.timestamp = monotonicStamp(
      message.timestamp,
      list.isEmpty ? 0 : list.last.timestamp,
    );
    list.add(message);
    // 预览只关心"最后一条 agent 文本消息"，工具卡片与用户消息不覆盖它
    if (!message.isTool && message.role == 'agent') {
      _preview[key] = message;
    }
    // updated_at 只前进不后退（与 MemoryStore 同一语义，见契约测试）
    final CoreSession? session = _sessions[message.agentId]?[message.sessionId];
    if (session != null && message.timestamp > session.updatedAt) {
      session.updatedAt = message.timestamp;
      _writeSession(session);
    }
    final CoreAgent? agent = _agents[message.agentId];
    if (agent != null && message.timestamp > agent.updatedAt) {
      agent.updatedAt = message.timestamp;
      _writeAgent(agent);
    }
    final String line = jsonEncode(message.toJson());
    final String file = paths.messagesFile(message.agentId, message.sessionId);
    _queue.enqueue(
      paths.sessionDir(message.agentId, message.sessionId),
      () => AtomicFile.appendLine(file, line),
    );
    return message;
  }

  @override
  int clearMessages(String agentId, {String? sessionId}) {
    _loadAgent(agentId);
    final bool all =
        sessionId == null || sessionId.isEmpty || sessionId == 'all';
    final Iterable<String> targets = all
        ? sessions(agentId).map((CoreSession s) => s.sessionId)
        : <String>[sessionId];
    int deleted = 0;
    for (final String id in targets) {
      final String key = _key(agentId, id);
      _loadMessages(agentId, id);
      deleted += _messages[key]?.length ?? 0;
      _messages[key] = <CoreMessage>[];
      _preview.remove(key);
      final String file = paths.messagesFile(agentId, id);
      _queue.enqueue(paths.sessionDir(agentId, id), () async {
        final File target = File(file);
        if (await target.exists()) await target.delete();
      });
    }
    return deleted;
  }

  @override
  int get totalMessageCount => _messages.values.fold<int>(
    0,
    (int sum, List<CoreMessage> l) => sum + l.length,
  );

  @override
  Future<void> flush() => _queue.flush();

  @override
  Future<void> close() async {
    await flush();
    final Object? error = _queue.lastError;
    if (error != null) log?.call('落盘期间出现错误（最后一次）：$error');
  }

  // ── 装载 ─────────────────────────────────────────────────────────────

  /// 扫描 `agents/` 下的全部 agent 配置（一次）。
  Iterable<CoreAgent> _scanAgents() {
    if (_agentsScanned) return _agents.values;
    _agentsScanned = true;
    final Directory dir = Directory(paths.agentsDir);
    if (!dir.existsSync()) return _agents.values;
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.yaml')) continue;
      final CoreAgent? agent = _readAgentFile(entity);
      if (agent != null) _agents[agent.id] = agent;
    }
    return _agents.values;
  }

  CoreAgent? _readAgentFile(File file) {
    try {
      // 手改坏的 yaml 不该让整个 agent 列表读不出来：容错解码（非法字节 U+FFFD 顶替），
      // 真解析不了会走下面的 catch 记日志跳过。
      final DecodedText decoded = PlatformTextDecoder.decodeTolerant(
        file.readAsBytesSync(),
      );
      if (decoded.decoding == TextDecoding.utf8Malformed) {
        log?.call('agent 配置含非法 UTF-8 字节，已按 U+FFFD 顶替后解析：${file.path}');
      }
      final Map<String, dynamic> map = YamlCodec.decode(decoded.text);
      final CoreAgent agent = CoreAgent.fromJson(map);
      if (agent.id.isEmpty) {
        log?.call('agent 配置缺少 id，已跳过：${file.path}');
        return null;
      }
      return agent;
    } catch (error) {
      log?.call('agent 配置解析失败（已跳过，不影响其他 agent）：${file.path}：$error');
      return null;
    }
  }

  /// 装载某 agent 的配置与其全部会话元数据（幂等，只做一次）。
  void _loadAgent(String agentId) {
    _scanAgents();
    if (!_agentLoaded.add(agentId)) return;
    _sessions[agentId] = <String, CoreSession>{};
    final File agentFile = File(paths.agentFile(agentId));
    if (agentFile.existsSync()) {
      final CoreAgent? agent = _readAgentFile(agentFile);
      // 磁盘是权威：缓存里若有同名（本轮新建）以磁盘为准
      if (agent != null) _agents[agentId] = agent;
    }
    final Directory agentDir = Directory(paths.agentDataDir(agentId));
    if (!agentDir.existsSync()) return;
    for (final FileSystemEntity entity in agentDir.listSync()) {
      if (entity is! Directory) continue;
      final File meta = File(p.join(entity.path, 'session.json'));
      if (!meta.existsSync()) continue;
      try {
        final DecodedText text = PlatformTextDecoder.decodeTolerant(
          meta.readAsBytesSync(),
        );
        if (text.decoding == TextDecoding.utf8Malformed) {
          log?.call('会话元数据含非法 UTF-8 字节，已按 U+FFFD 顶替后解析：${meta.path}');
        }
        final Object? decoded = jsonDecode(text.text);
        if (decoded is! Map<String, dynamic>) continue;
        final CoreSession session = CoreSession.fromJson(decoded);
        if (session.sessionId.isEmpty) continue;
        _sessions[agentId]![session.sessionId] = session;
      } catch (error) {
        log?.call('会话元数据损坏（已跳过）：${meta.path}：$error');
      }
    }
  }

  /// 装载某会话的全部消息（幂等）。
  void _loadMessages(String agentId, String sessionId) {
    _loadAgent(agentId);
    final String key = _key(agentId, sessionId);
    if (_messages.containsKey(key)) return;
    _messages[key] = <CoreMessage>[];
    final String file = paths.messagesFile(agentId, sessionId);
    final String? text = AtomicFile.readStringOrNullSync(file);
    if (text == null || text.isEmpty) return;
    final JsonlReadResult result = AtomicFile.decodeJsonl(text);
    if (result.skipped > 0) {
      skippedMessageLines += result.skipped;
      log?.call('messages.jsonl 有 ${result.skipped} 行无法解析，已跳过：$file');
    }
    _messages[key] = result.records.map(CoreMessage.fromJson).toList();
  }

  /// 会话最后一条 agent 文本消息（读文件尾部即可，避免整份历史进内存）。
  CoreMessage? _previewFor(String agentId, String sessionId) {
    final String key = _key(agentId, sessionId);
    if (_preview.containsKey(key)) return _preview[key];
    CoreMessage? found;
    final String? tail = AtomicFile.readTailOrNullSync(
      paths.messagesFile(agentId, sessionId),
      _previewTailBytes,
    );
    if (tail != null && tail.isNotEmpty) {
      final JsonlReadResult result = AtomicFile.decodeJsonl(tail);
      for (final Map<String, dynamic> record in result.records.reversed) {
        final CoreMessage message = CoreMessage.fromJson(record);
        if (message.isTool || message.role != 'agent') continue;
        found = message;
        break;
      }
    }
    _preview[key] = found;
    return found;
  }

  // ── 落盘 ─────────────────────────────────────────────────────────────

  static String _key(String agentId, String sessionId) =>
      '$agentId::$sessionId';

  void _writeAgent(CoreAgent agent) {
    final String file = paths.agentFile(agent.id);
    final String content = YamlCodec.encode(
      agent.toJson(),
      header: _agentHeader,
    );
    _queue.enqueue(file, () => AtomicFile.writeStringAtomic(file, content));
  }

  void _writeSession(CoreSession session) {
    final String file = paths.sessionMetaFile(
      session.agentId,
      session.sessionId,
    );
    final String content = const JsonEncoder.withIndent('  ')
        .convert(session.toJson());
    _queue.enqueue(
      paths.sessionDir(session.agentId, session.sessionId),
      () => AtomicFile.writeStringAtomic(file, '$content\n'),
    );
  }
}
