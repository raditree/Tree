import 'package:path/path.dart' as p;

import '../store/atomic_file.dart';
import '../store/yaml_codec.dart';
import 'station_ids.dart';
import 'station_instance.dart';
import 'station_runtime.dart';
import 'station_schema.dart';

/// 站点实例落盘（M9 §3：站点 = 持久化实例，跨重启保留）。
///
/// 落点：与 plugins.yaml / mcp.yaml **同目录同风格**的
/// 「<数据根>/config/stations.yaml」（人类可直接阅读与手改）。形状：
///
///   version: 1
///   stations:
///     - id: system.broadcast
///       kind: broadcast
///       description: 广播站（系统自带）
///       max_subscriptions: 32
///       builtin: true
///       created_at: 1789000000
///       subscribers:
///         - {plugin_id: sample, scope: {...}, subscribed_at: 1789000001}
///       board_limit: 50
///       board_seq: 3
///       board: [...]
///
/// **站点 id = 类型常量，不含 team / mode**（用户定稿语义）：每类站全局一个实例，
/// team / agent / session / mode 只作为订阅声明与消息信封存在。
///
/// 为什么用 yaml 而不是 jsonl：站点实例数量少、每条都很小，但**用户要能直接看懂
/// 与手改**（订阅上限、订阅者 scope、收集站 schema、公告板都要求可读）；一次性原子
/// 快照写即可，不需要 messages.jsonl 那种追加日志。
class StationStore {
  StationStore(this.path);

  /// 文件路径。
  final String path;

  /// 落盘格式版本（将来结构变更时用于迁移；未知版本按当前结构宽容解析）。
  ///
  /// 站点全局化**没有**升版本号：结构未变（仍是 id/kind/.../subscribers），
  /// 变的只是 id 的取值口径，因此用**读侧迁移**把旧 `base@team@mode` 归并到常量 id，
  /// 旧文件仍可被旧代码与人工阅读。
  static const int version = 1;

  /// 由插件配置文件路径推导（保持 <数据根>/config/ 同目录，风格一致）。
  static String pathFor(String pluginConfigFile) =>
      p.join(p.dirname(pluginConfigFile), 'stations.yaml');

  /// 读取全部站点实例，并把旧格式（`baseId@team@mode`）**归并**到全局常量 id。
  ///
  /// 返回 `(stations, migrated)`：[migrated] 为 true 表示读到了旧格式并已归并，
  /// 调用方应把结果写回一次（此后幂等：文件里没有旧 id 就不会再触发迁移）。
  ///
  /// 文件不存在 = 空表；坏条目跳过而不是整库失败。
  ({List<StationInstance> stations, bool migrated}) load() {
    final String? text = AtomicFile.readStringOrNullSync(path);
    if (text == null || text.trim().isEmpty) {
      return (stations: <StationInstance>[], migrated: false);
    }
    final List<StationInstance> parsed = <StationInstance>[];
    try {
      final Map<String, dynamic> data = YamlCodec.decode(text);
      final Object? raw = data['stations'];
      if (raw is List) {
        for (final Object? item in raw) {
          final StationInstance? station = StationInstance.tryParse(item);
          if (station != null) parsed.add(station);
        }
      }
    } catch (_) {
      // 文件被手工改坏：按空表启动（站点可重建），不阻塞核心
      return (stations: <StationInstance>[], migrated: false);
    }
    return migrateLegacy(parsed);
  }

  /// 把旧 `baseId@team@mode` 站点归并到全局常量 id（幂等；纯函数，便于测试）。
  ///
  /// 归并规则：
  /// - **按基础 id 分组**（`system.relay` / `system.broadcast` / `system.execute` /
  ///   `plugin.tool.define`），每组只留**一个**实例，id 换成常量；
  /// - 组的类型以**基础 id 对应的类型**为准（`system.*` 与 `plugin.tool.define`）；
  ///   `plugin.` 开头的自建站 id 不含 `@` 语义，原样保留、不参与归并；
  /// - **订阅者合并去重**（键 = `pluginId|scope.key`），保留最早 `subscribed_at`；
  /// - `created_at` 取最小（站的"资历"跨迁移保留）；
  /// - 广播站公告板按 `(ts, seq)` 合并排序、去掉重复 seq、按 `board_limit` 截尾；
  ///   `board_seq` 取最大水位（序号跨重启不回退）；
  /// - 收集站 schema：取**第一个非空**的；多份不一致时保留先见者（调用方记日志）。
  static ({List<StationInstance> stations, bool migrated}) migrateLegacy(
    List<StationInstance> parsed,
  ) {
    bool migrated = false;
    final List<StationInstance> out = <StationInstance>[];
    // 分组：常量 id → 该组已收集的旧实例
    final Map<String, List<StationInstance>> groups =
        <String, List<StationInstance>>{};
    final Map<String, String> groupBase = <String, String>{};

    String baseOf(String id) {
      final int at = id.indexOf('@');
      return at < 0 ? id : id.substring(0, at);
    }

    for (final StationInstance station in parsed) {
      final String id = station.id.trim();
      if (!id.contains('@')) {
        // 已是全局常量 id（或插件自建 id）：原样保留
        out.add(station);
        continue;
      }
      final String base = baseOf(id);
      if (base.isEmpty) {
        out.add(station);
        continue;
      }
      migrated = true;
      groups.putIfAbsent(base, () => <StationInstance>[]).add(station);
      groupBase[base] = base;
    }

    for (final MapEntry<String, List<StationInstance>> entry in groups.entries) {
      final String base = entry.key;
      final List<StationInstance> members = entry.value;
      final StationInstance? merged = _mergeGroup(base, members);
      if (merged != null) out.add(merged);
    }
    return (stations: out, migrated: migrated);
  }

  /// 归并同基础 id 的一组旧实例（类型由基础 id 决定；未知基础 id 返回 null = 丢弃）。
  static StationInstance? _mergeGroup(
    String base,
    List<StationInstance> members,
  ) {
    final List<StationSubscriber> subscribers = <StationSubscriber>[];
    final Map<String, StationSubscriber> seen = <String, StationSubscriber>{};
    int createdAt = 0;
    for (final StationInstance station in members) {
      if (station.createdAt > 0 &&
          (createdAt == 0 || station.createdAt < createdAt)) {
        createdAt = station.createdAt;
      }
      for (final StationSubscriber subscriber in station.subscribers) {
        final StationSubscriber? existing = seen[subscriber.key];
        if (existing == null) {
          seen[subscriber.key] = subscriber;
          subscribers.add(subscriber);
        } else if (subscriber.subscribedAt > 0 &&
            (existing.subscribedAt == 0 ||
                subscriber.subscribedAt < existing.subscribedAt)) {
          // 同一订阅者出现在多个旧实例上：保留最早订阅时间
          final int index = subscribers.indexOf(existing);
          final StationSubscriber earlier = StationSubscriber(
            pluginId: existing.pluginId,
            scope: existing.scope,
            subscribedAt: subscriber.subscribedAt,
          );
          seen[subscriber.key] = earlier;
          subscribers[index] = earlier;
        }
      }
    }
    final int? created = createdAt == 0 ? null : createdAt;

    switch (base) {
      case StationHubIds.broadcast:
        final List<StationBoardEntry> board = <StationBoardEntry>[];
        final Set<int> seqs = <int>{};
        int boardSeq = 0;
        int boardLimit = 50;
        for (final StationInstance station in members) {
          if (station is! BroadcastStation) continue;
          boardLimit = station.boardLimit;
          if (station.boardSeq > boardSeq) boardSeq = station.boardSeq;
          for (final StationBoardEntry item in station.board) {
            if (seqs.add(item.seq)) board.add(item);
          }
        }
        board.sort((StationBoardEntry a, StationBoardEntry b) {
          final int byTime = a.ts.compareTo(b.ts);
          return byTime != 0 ? byTime : a.seq.compareTo(b.seq);
        });
        final List<StationBoardEntry> trimmed = boardLimit > 0 && board.length > boardLimit
            ? board.sublist(board.length - boardLimit)
            : board;
        return BroadcastStation(
          id: StationHubIds.broadcast,
          description: _descriptionOf(members, '广播站'),
          builtin: true,
          createdAt: created,
          subscribers: subscribers,
          boardLimit: boardLimit,
          boardSeq: boardSeq,
          board: trimmed,
        );
      case StationHubIds.execute:
        return ExecuteStation(
          id: StationHubIds.execute,
          description: _descriptionOf(members, '执行站'),
          builtin: true,
          createdAt: created,
          subscribers: subscribers,
        );
      case StationHubIds.relay:
        return RelayStation(
          id: StationHubIds.relay,
          description: _descriptionOf(members, '中转站'),
          maxSubscriptions: 16,
          builtin: true,
          createdAt: created,
          subscribers: subscribers,
        );
      case StationHubIds.collect:
        final StationSchema? schema = members
            .whereType<CollectStation>()
            .map((CollectStation s) => s.schema)
            .cast<StationSchema?>()
            .firstWhere(
              (StationSchema? s) => s != null && s.fields.isNotEmpty,
              orElse: () => null,
            );
        if (schema == null) return null;
        return CollectStation(
          id: StationHubIds.collect,
          description: _descriptionOf(members, '收集站'),
          schema: schema,
          builtin: true,
          createdAt: created,
          subscribers: subscribers,
        );
      default:
        // 未知基础 id 的旧格式条目：无法判定类型，丢弃（不猜）
        return null;
    }
  }

  /// 归并后的说明：优先用组内第一条自带说明（保留既有文案），否则给兜底。
  static String _descriptionOf(List<StationInstance> members, String fallback) {
    for (final StationInstance station in members) {
      if (station.description.trim().isNotEmpty) return station.description;
    }
    return fallback;
  }

  /// 原子覆盖写（先写 .tmp 再改名，任何时刻磁盘上不是半截文件）。
  void save(Iterable<StationInstance> stations) {
    final Map<String, dynamic> data = <String, dynamic>{
      'version': version,
      'stations': stations
          .map((StationInstance s) => s.toJson())
          .toList(growable: false),
    };
    AtomicFile.writeStringAtomicSync(
      path,
      YamlCodec.encode(
        data,
        header:
            'Tree 站点实例（M9 站点体系）\n'
            '站点 = 持久化实例，**每类站全局一个**：id 就是类型常量'
            '（system.broadcast / system.execute / system.relay / plugin.tool.define），\n'
            '不含 team / mode——team / agent / session / mode 是每次交互携带的消息 scope，'
            '只用于匹配订阅者。\n'
            '字段：id / 类型 / 订阅上限 / 订阅者列表（+ 收集站 schema、广播站公告板）。\n'
            '本文件可手工编辑；改动在核心下次启动时生效。',
      ),
    );
  }
}
