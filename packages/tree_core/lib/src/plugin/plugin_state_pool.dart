import 'dart:convert';

import 'station_scope.dart';

/// 插件可续跑状态快照在**核心进程内存**里的一站（20261015-hot-restart 阶段 1，D4）。
///
/// **为什么是内存池而不是磁盘**（D4 的定稿理由，后来者别改回去）：
/// 转储的用途极窄——只服务"这次热重启的下一世"。写盘换不来跨重启恢复（核心进程
/// 一退，那些文件就成了没人认领的残留），却要付三笔代价：磁盘 IO、残留文件清理、
/// 以及"用户在盘上看到一份插件内部状态"这条新的可读性/隐私面。
/// 因此这里刻意**不落盘**：核心退出即丢快照，那正是"热重启续跑"的作用域。
///
/// **丢了快照会怎样**（不变量 10：新能力必须有"它坏了会怎样"的显式路径）：
/// 新实例按冷启动跑，核心把"没有可续跑快照"这件事在 `hello` 里以 `dump_id: null`
/// 显式告知插件（不是让插件自己猜），并把降级原因写进日志与快照读数。
/// 会话侧的事实**不受影响**——消息与工具结果由 `store` 落库在先（不变量 8），
/// 插件状态不是任何事实的源头。
///
/// 索引键是 `(pluginId, generation)`：只用 pluginId 会让"重启失败的上一世"的快照
/// 被"下一世"取走（两个实例本来不是同一段人生），因此代际必须进键。
class PluginStatePool {
  PluginStatePool({
    this.maxEntryBytes = 1 << 20,
    this.maxTotalBytes = 8 << 20,
    this.maxEntries = 64,
    this.ttl = const Duration(minutes: 10),
    this.log,
  });

  /// **单条**快照的字节上限：超出直接拒收（不截断）。
  ///
  /// 为什么拒收而不是截断：截断后的"半截状态"被插件当完整状态恢复，比直接失败
  /// 更糟——它会带着一份自己没写过的数据继续跑，而现场看不出来。
  final int maxEntryBytes;

  /// 池的总字节上限（超限按 LRU 丢最旧的）。
  final int maxTotalBytes;

  /// 池的条目上限（防"插件 id 很多但每个都没消费"堆积）。
  final int maxEntries;

  /// 存活时长：到期即视为不存在（读时顺手清，不起定时器——本池不该有自己的时钟，
  /// 项目里时长判据只归心跳台账管，见 `util/liveness.dart`）。
  final Duration ttl;

  void Function(String message)? log;

  /// 索引：`(pluginId, generation)` → 条目。**不用 dumpId 做键**：
  /// 同一代际只应有一份可续跑状态，留两份会说不清哪份算数（重复放入 = 覆盖）。
  final Map<String, _PoolEntry> _entries = <String, _PoolEntry>{};

  /// 累计计数（快照与测试的读数点：收了几条、拒了几条、丢了几条）。
  int _putCount = 0;
  int _rejectedCount = 0;
  int _droppedCount = 0;
  int _deniedCount = 0;

  /// 池里当前的条数（不含已消费的留档）。
  int get length => _entries.values.where((_PoolEntry e) => !e.snapshot.consumed).length;

  /// 当前占用的总字节数。
  int get totalBytes => _entries.values.fold<int>(
    0,
    (int sum, _PoolEntry e) => sum + e.bytes,
  );

  int get putCount => _putCount;
  int get rejectedCount => _rejectedCount;
  int get droppedCount => _droppedCount;

  /// 归属被拒的累计次数（scope 不成立的取回尝试；排查"取不到快照"先看这个）。
  int get deniedCount => _deniedCount;

  /// **放入**一份快照。返回 dumpId（成功）或 null（失败，原因同时写日志）。
  ///
  /// [payload] 必须是 JSON 可编码对象——它是跨进程的边界，不是进程内引用。
  PluginStatePutResult put({
    required String pluginId,
    required int generation,
    required Map<String, dynamic> payload,
    required StationScope scope,
  }) {
    _pruneExpired();
    final String encoded;
    try {
      encoded = jsonEncode(payload);
    } catch (error) {
      final String reason = '插件 $pluginId 的转储不是合法 JSON，已拒收：$error';
      log?.call(reason);
      _rejectedCount++;
      return PluginStatePutResult.denied(reason);
    }
    final int bytes = encoded.length;
    if (bytes > maxEntryBytes) {
      final String reason =
          '插件 $pluginId 的转储过大（$bytes > 单条上限 $maxEntryBytes 字节），'
          '已整条拒收（不截断——半截状态被当成完整状态恢复比失败更糟）';
      log?.call(reason);
      _rejectedCount++;
      return PluginStatePutResult.denied(reason);
    }
    // dumpId 就是索引键：新实例不需要猜“上一世叫什么”，核心在 hello 里直接
    // 把旧代际的 dump_id 端给它（= pluginId#generation）。
    final String dumpId = '$pluginId#$generation';
    final _PoolEntry entry = _PoolEntry(
      snapshot: PluginStateSnapshot(
        dumpId: dumpId,
        pluginId: pluginId,
        generation: generation,
        payload: payload,
        scope: scope,
        bytes: bytes,
      ),
      bytes: bytes,
    );
    // 同键重复放入 = 覆盖（新一份算数，旧的不能留着被第二次取回）。
    _entries[dumpId] = entry;
    _putCount++;
    _enforceCaps(dumpId);
    return PluginStatePutResult.accepted(dumpId);
  }

  /// **取回**一份快照。找不到 / 已消费 / 归属不符 ⇒ null（原因写日志，不静默）。
  ///
  /// 归属校验是 **fail-closed 精确相等**（不是通配匹配）：快照是插件自己的内部状态，
  /// "谁能取"必须与"谁写的"逐字一致，否则一次重启就可能把 A 团队的状态递给 B 团队。
  /// [consume] = false 只用于展示/诊断（不改消费位），业务恢复路径必须给 true。
  PluginStateSnapshot? take({
    required String pluginId,
    required int generation,
    required StationScope scope,
    bool consume = true,
  }) {
    _pruneExpired();
    final String wanted = '$pluginId#$generation';
    final _PoolEntry? hit = _entries[wanted];
    if (hit == null) {
      log?.call('插件 $pluginId 第 $generation 代没有可续跑快照（按冷启动继续）');
      return null;
    }
    if (hit.snapshot.consumed) {
      log?.call(
        '插件 $pluginId 第 $generation 代的快照已被取走（一份快照只喂一世），'
        '本次按冷启动继续',
      );
      return null;
    }
    if (!hit.snapshot.scope.exactEquals(scope)) {
      _deniedCount++;
      log?.call(
        '拒绝插件 $pluginId 取回快照：归属不符（快照写在 ${hit.snapshot.scope.describe()}，'
        '请求来自 ${scope.describe()}）',
      );
      return null;
    }
    if (consume) hit.markConsumed();
    return hit.snapshot;
  }

  /// 把一份**已消费**的快照退回可取状态。
  ///
  /// 唯一的正当用法：核心取回快照后、新实例在真正就绪前就退了（那次消费作废）。
  /// 不做这件事的话，一次偶发的启动失败会永久吃掉用户显式声明要保的在途状态。
  bool release(String dumpId) {
    final _PoolEntry? entry = _entries[dumpId];
    if (entry == null || !entry.snapshot.consumed) return false;
    entry.markUnconsumed();
    log?.call('退回快照 $dumpId 的消费标记（新实例未就绪，允许再取一次）');
    return true;
  }

  /// 显式丢弃（热重启失败后不留残档，或用户停用了这个插件）。
  void discard(String pluginId, {int? generation}) {
    final List<String> keys = _entries.entries
        .where(
          (MapEntry<String, _PoolEntry> e) =>
              e.value.snapshot.pluginId == pluginId &&
              (generation == null || e.value.snapshot.generation == generation),
        )
        .map((MapEntry<String, _PoolEntry> e) => e.key)
        .toList(growable: false);
    for (final String key in keys) {
      _entries.remove(key);
      _droppedCount++;
    }
    if (keys.isNotEmpty) {
      log?.call(
        '丢弃插件 $pluginId 的 ${keys.length} 份快照'
        '${generation == null ? '' : '（第 $generation 代）'}',
      );
    }
  }

  /// 当前池内快照的**只读**读数（面板 / `plugin_status` 的池水位用）。
  ///
  /// 刻意不回 payload 内容：池水位是运维读数，不该把插件内部状态顺手端出去。
  List<PluginStateReading> readings() => _entries.values
      .map((_PoolEntry e) => PluginStateReading(
        dumpId: e.snapshot.dumpId,
        pluginId: e.snapshot.pluginId,
        generation: e.snapshot.generation,
        bytes: e.bytes,
        consumed: e.snapshot.consumed,
        ageMs: DateTime.now().difference(e.createdAt).inMilliseconds,
      ))
      .toList(growable: false);

  /// 清空（测试与核心退出路径用）。
  void clear() => _entries.clear();

  /// TTL 到期即清（读时顺手做，不引入定时器）。
  void _pruneExpired() {
    final DateTime now = DateTime.now();
    final List<String> stale = _entries.entries
        .where(
          (MapEntry<String, _PoolEntry> e) => now.difference(e.value.createdAt) > ttl,
        )
        .map((MapEntry<String, _PoolEntry> e) => e.key)
        .toList(growable: false);
    for (final String key in stale) {
      _entries.remove(key);
      _droppedCount++;
      log?.call('快照 $key 超过存活时长（${ttl.inSeconds}s）被丢弃：新实例按冷启动继续');
    }
  }

  /// 条数与总字节的上限执行（LRU：丢最旧的那条，Map 保持插入序）。
  ///
  /// [freshKey] 永远保留——刚放进去又立刻被丢掉会让"取回"这条路莫名其妙地断。
  void _enforceCaps(String freshKey) {
    void dropOldest(String why) {
      String? victim;
      for (final String key in _entries.keys) {
        if (key != freshKey) {
          victim = key;
          break;
        }
      }
      if (victim == null) return; // 只剩刚放进去的那条：不能把自己丢掉
      _entries.remove(victim);
      _droppedCount++;
      log?.call('丢弃快照 $victim：$why');
    }

    while (_entries.length > maxEntries) {
      dropOldest('超出条目上限 $maxEntries');
    }
    while (totalBytes > maxTotalBytes) {
      dropOldest('超出总字节上限 $maxTotalBytes');
    }
  }
}

/// 一次放入的结果（成功给 dumpId，失败给可读原因）。
class PluginStatePutResult {
  const PluginStatePutResult._(this.dumpId, this.error);

  const PluginStatePutResult.accepted(String dumpId) : this._(dumpId, '');

  const PluginStatePutResult.denied(String error) : this._(null, error);

  /// 成功时的 dumpId（`hello` 要回给新实例的那个）；失败为 null。
  final String? dumpId;

  /// 失败原因（成功时为空串）。
  final String error;

  bool get accepted => dumpId != null;
}

/// 一份可续跑状态快照。
class PluginStateSnapshot {
  PluginStateSnapshot({
    required this.dumpId,
    required this.pluginId,
    required this.generation,
    required this.payload,
    required this.scope,
    required this.bytes,
  });

  final String dumpId;
  final String pluginId;

  /// 插件实例的**代际**（每次启动 +1）：与 pluginId 合起来才是这份快照的主人。
  final int generation;

  final Map<String, dynamic> payload;

  /// 写入时的归属（取回时要求精确相等）。
  final StationScope scope;

  final int bytes;

  /// 是否已被取走（一份快照只喂一世）。
  bool consumed = false;

  /// 索引键（不含 dumpId 的尾序号：同一代际只留最新一份）。
  String get key => '$pluginId#$generation';
}

/// 池内一条记录的持有者（消费位与时间戳都在这里，[PluginStateSnapshot] 保持纯数据）。
class _PoolEntry {
  _PoolEntry({required this.snapshot, required this.bytes})
    : createdAt = DateTime.now();

  final PluginStateSnapshot snapshot;
  final int bytes;
  final DateTime createdAt;

  void markConsumed() => snapshot.consumed = true;
  void markUnconsumed() => snapshot.consumed = false;
}

/// 池水位读数（面板 / `plugin_status` 快照用；不含 payload 内容）。
class PluginStateReading {
  const PluginStateReading({
    required this.dumpId,
    required this.pluginId,
    required this.generation,
    required this.bytes,
    required this.consumed,
    required this.ageMs,
  });

  final String dumpId;
  final String pluginId;
  final int generation;
  final int bytes;
  final bool consumed;
  final int ageMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'dump_id': dumpId,
    'plugin_id': pluginId,
    'generation': generation,
    'bytes': bytes,
    'consumed': consumed,
    'age_ms': ageMs,
  };
}
