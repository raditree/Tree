import '../util/ids.dart';
import 'tree_store.dart';

/// 临时员工（subagent）的规模与命名口径。
abstract final class SubagentLimits {
  /// 会话内名册的**层级上限**（树深）：真实 agent 的直属临时员工 = 1 层。
  ///
  /// 为什么要有上限：临时员工可以再派发（"把同一个大任务拆细"），没有上限就是
  /// 无限套娃。超限时**显式报可读错误**（不静默截断、不悄悄拒绝），并在提示词里
  /// 写明"不许为绕开限制而套娃"。
  static const int maxDepth = 3;

  /// 临时员工 id 前缀（`store.agent(id)` 据此把它路由到内存名册）。
  static const String idPrefix = 'sub_';

  /// 未指定 name 时的显示名。
  static const String defaultName = '临时员工';
}

/// **会话级临时员工名册**（内存索引 + 落盘在 [persistence]）。
///
/// 三层职责（与 [TreeStore] 的分工）：
/// - **索引**：`id → 记录` 与 `会话键 → 记录列表`，让 `store.agent(sub_…)` 这类
///   只带 id 的查询路径查得到临时员工；
/// - **树**：`parentId` + `level` 维护会话内的层级（真实 agent → 临时员工 → 它的
///   临时员工……），提供"按树收"的清理与层级判据；
/// - **加载**：会话**第一次被打开**（名册查询 / 新建 / 复用）时把该会话的名册从
///   [persistence] 读进内存，之后只走内存。核心重启后打开同一会话 ⇒ 名册原样回来
///   （临时员工随会话持久化）。
///
/// **跨会话不保留是硬不变量**：所有查询都必须带 `(ownerAgentId, sessionId)`；
/// [handle] 只回答"这个 id 是否已在**本进程已加载**的某个会话里"，因此调用方
/// （找复用目标）必须**先** [ensureSession] 再查，跨会话复用才能被判成可读错误。
class SubagentRegistry {
  SubagentRegistry({required this.persistence, this.log});

  /// 真 store（`MemoryStore` 或 `FileTreeStore`）：名册的读写都落在这里。
  final TreeStore persistence;

  final void Function(String message)? log;

  /// id → 记录（只含已加载会话里的记录）。
  final Map<String, CoreSubagent> _byId = <String, CoreSubagent>{};

  /// 会话键 → 记录列表（按创建顺序；键存在 = 该会话已加载）。
  final Map<String, List<CoreSubagent>> _bySession =
      <String, List<CoreSubagent>>{};

  static String sessionKey(String agentId, String sessionId) =>
      '$agentId::$sessionId';

  /// 是否形如临时员工 id（前缀判据：不要求已加载，工具表裁剪与 id 路由要用它）。
  bool isSubagent(String id) => id.startsWith(SubagentLimits.idPrefix);

  /// 生成一个临时员工 id（`sub_<epoch_ms>_<rand>_<seq>`，见 [CoreIds]）。
  ///
  /// 为什么不是每个会话各自从 `sub_1` 数起：`store.agent(id)` **没有会话维度**，
  /// 两个会话各自叫 `sub_1` 时工作空间/SSH 解析会串号。全局唯一 + 前缀判据，
  /// 两条要求同时满足。
  String nextId() => CoreIds.next('sub');

  /// 确保某会话的名册已从盘上装载（幂等；会话第一次被打开时调用）。
  void ensureSession(String ownerAgentId, String sessionId) {
    final String key = sessionKey(ownerAgentId, sessionId);
    if (_bySession.containsKey(key)) return;
    final List<CoreSubagent> loaded = <CoreSubagent>[];
    _bySession[key] = loaded;
    try {
      for (final CoreSubagent s in persistence.subagents(
        ownerAgentId,
        sessionId,
      )) {
        loaded.add(s);
        _byId[s.id] = s;
      }
    } catch (error) {
      log?.call('装载临时员工名册失败（$ownerAgentId/$sessionId）：$error');
    }
  }

  /// 是否已装载某会话的名册（自检/测试用）。
  bool isSessionLoaded(String ownerAgentId, String sessionId) =>
      _bySession.containsKey(sessionKey(ownerAgentId, sessionId));

  /// 某会话的名册（**会先装载**；只含该会话的记录）。
  List<CoreSubagent> records(String ownerAgentId, String sessionId) {
    ensureSession(ownerAgentId, sessionId);
    return List<CoreSubagent>.unmodifiable(
      _bySession[sessionKey(ownerAgentId, sessionId)] ?? const <CoreSubagent>[],
    );
  }

  /// 按 id 取临时员工（没装载过就查不到——调用方负责先 [ensureSession]）。
  CoreSubagent? handle(String id) => _byId[id];

  /// 按 id 取它的运行配置（`store.agent(sub_…)` 的落点）。
  CoreAgent? agent(String id) => _byId[id]?.agent;

  /// 它所在的会话主人（树根）。未知 id 或非临时员工返回 null。
  String? ownerOf(String id) => _byId[id]?.ownerAgentId;

  /// 层级：真实 agent（非临时员工）= 0，直属临时员工 = 1。
  int levelOf(String agentId) => _byId[agentId]?.level ?? 0;

  /// [id] 的**私有状态归属**：沿 `parentId` 一路找到树根（真实 agent）。
  ///
  /// 用途：`WorkspaceToolRunner` 的 `.tree/<agent>/.self` 分栏。临时员工与它的
  /// 发起者共享同一个工作空间，私有状态分栏也归到会话主人 ⇒ 不会在用户工作空间里
  /// 留下 `sub_*` 目录，且它读到的系统提示词文件与发起者是**同一份**。
  String privateOwnerOf(String id) {
    String current = id;
    final Set<String> seen = <String>{current};
    for (int depth = 0; depth < 64; depth++) {
      final CoreSubagent? record = _byId[current];
      if (record == null) return current;
      final String parent = record.parentId.trim();
      if (parent.isEmpty || !seen.add(parent)) return current;
      current = parent;
    }
    return current;
  }

  /// 写入/覆盖一条记录（同步落盘 + 更新内存索引）。
  void put(CoreSubagent subagent) {
    ensureSession(subagent.ownerAgentId, subagent.sessionId);
    _index(subagent);
    persistence.putSubagent(subagent);
  }

  /// 替换某个临时员工的**运行配置**（`putAgent(sub_…)` 的落点）；返回是否命中。
  bool putAgent(CoreAgent agent) {
    final CoreSubagent? record = _byId[agent.id];
    if (record == null) return false;
    record.agent = agent;
    record.updatedAt = DateTime.now().millisecondsSinceEpoch;
    persistence.putSubagent(record);
    return true;
  }

  /// 跑完一轮后记账（复用次数 + 时间戳），不改变配置与层级。
  void markRun(String id) {
    final CoreSubagent? record = _byId[id];
    if (record == null) return;
    record.runCount += 1;
    record.updatedAt = DateTime.now().millisecondsSinceEpoch;
    persistence.putSubagent(record);
  }

  /// 删除一条记录及其**全部下级**（同一会话内按树收）；返回删除条数。
  int removeTree(String ownerAgentId, String sessionId, String id) {
    ensureSession(ownerAgentId, sessionId);
    final List<CoreSubagent> list =
        _bySession[sessionKey(ownerAgentId, sessionId)] ?? <CoreSubagent>[];
    final Set<String> doomed = subagentTreeIds(list, id);
    for (final String victim in doomed) {
      _byId.remove(victim);
    }
    final int before = list.length;
    list.removeWhere((CoreSubagent s) => doomed.contains(s.id));
    final int removed = before - list.length;
    if (removed > 0) persistence.deleteSubagent(ownerAgentId, sessionId, id);
    return removed;
  }

  /// 清空某会话的名册（整棵树）；返回清掉的条数。
  int clearSession(String ownerAgentId, String sessionId) {
    ensureSession(ownerAgentId, sessionId);
    final String key = sessionKey(ownerAgentId, sessionId);
    final List<CoreSubagent> list = _bySession[key] ?? <CoreSubagent>[];
    for (final CoreSubagent s in list) {
      _byId.remove(s.id);
    }
    _bySession[key] = <CoreSubagent>[];
    final int removed = list.length;
    if (removed > 0) persistence.clearSubagents(ownerAgentId, sessionId);
    return removed;
  }

  /// 忘掉某会话的内存索引（删会话时调用；落盘由 store 的 `deleteSession` 负责）。
  void forgetSession(String ownerAgentId, String sessionId) {
    final String key = sessionKey(ownerAgentId, sessionId);
    final List<CoreSubagent>? list = _bySession.remove(key);
    if (list == null) return;
    for (final CoreSubagent s in list) {
      _byId.remove(s.id);
    }
  }

  /// 忘掉某 agent 名下全部会话的内存索引（删 agent 时调用）。
  void forgetAgent(String ownerAgentId) {
    final String prefix = '$ownerAgentId::';
    final List<String> keys = _bySession.keys
        .where((String key) => key.startsWith(prefix))
        .toList(growable: false);
    for (final String key in keys) {
      forgetSession(
        ownerAgentId,
        key.substring(prefix.length),
      );
    }
  }

  /// 进程收尾：丢掉全部内存索引（**不**删除落盘记录——临时员工随会话持久化）。
  void clear() {
    _byId.clear();
    _bySession.clear();
  }

  /// 已加载会话数 / 已索引的临时员工数（自检与测试用）。
  int get loadedSessionCount => _bySession.length;
  int get count => _byId.length;

  void _index(CoreSubagent subagent) {
    _byId[subagent.id] = subagent;
    final String key = sessionKey(subagent.ownerAgentId, subagent.sessionId);
    final List<CoreSubagent> list = _bySession.putIfAbsent(
      key,
      () => <CoreSubagent>[],
    );
    final int index = list.indexWhere((CoreSubagent s) => s.id == subagent.id);
    if (index >= 0) {
      list[index] = subagent;
    } else {
      list.add(subagent);
    }
  }
}
