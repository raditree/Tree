import 'package:path/path.dart' as p;

import '../store/atomic_file.dart';
import '../store/yaml_codec.dart';
import 'station_ids.dart';
import 'station_instance.dart';
import 'station_points.dart';
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
  /// **没有升版本号**（两次口径变更都只动 id 取值，结构未变：仍是
  /// id/kind/…/subscribers），因此用**读侧迁移**接住旧文件：
  /// - 第一代 `baseId@team@mode` ⇒ 按 base 归并成一个点位；
  /// - 第二代全局 id（`system.relay` / `system.execute`）⇒ [migrateLegacy] 的
  ///   **退役映射**：`system.relay` 拆成工具前/后两个点位（订阅复制过去），
  ///   `system.execute` 丢弃（执行站不可订阅）。
  /// 旧文件仍可被人工阅读；新文件给旧核心时"未知 kind 丢该条、已知 kind 原样保留"。
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

  /// 把旧格式（`baseId@team@mode`）与**已退役点位**归并到当前点位 id（幂等；纯函数）。
  ///
  /// 归并规则：
  /// - **退役 id 迁移**（点位化，2026-10-01）：
  ///   - `system.relay`（旧：工具前/后共用一个实例、靠 payload.phase 区分）⇒ 拆成
  ///     [StationHubIds.relayToolPre] 与 [StationHubIds.relayToolPost] **两个点位**，
  ///     旧订阅**复制**到两处（原订阅者行为等价：照样 pre / post 都收到，想只收
  ///     一个的自己退订另一个）；
  ///   - `system.execute`（旧：九条命令共用一个实例）⇒ **直接丢弃**：执行站不可订阅，
  ///     没有订阅需要迁移；
  /// - **按基础 id 分组**（含 `@` 的旧 `baseId@team@mode`）：每组只留**一个**实例，
  ///   id 换成点位常量；
  /// - 组的类型以**基础 id 对应的点位**为准；`plugin.` 开头的自建站 id 不含 `@`
  ///   语义，原样保留、不参与归并；
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
    // 分组：点位 id → 该组已收集的旧实例（同组会被 [_mergeGroup] 合成一个实例）
    final Map<String, List<StationInstance>> groups =
        <String, List<StationInstance>>{};

    String baseOf(String id) {
      final int at = id.indexOf('@');
      return at < 0 ? id : id.substring(0, at);
    }

    for (final StationInstance station in parsed) {
      final String id = station.id.trim();
      final String base = baseOf(id);
      // **退役 id 映射**（含更早一代的 `system.relay@team@mode`：base 一样是
      // `system.relay`，绝不能因为"点位表里查不到它"就把订阅丢掉）。
      final List<String>? retired = _retiredTargets(base);
      if (retired != null) {
        migrated = true;
        for (final String target in retired) {
          groups.putIfAbsent(target, () => <StationInstance>[]).add(station);
        }
        continue;
      }
      if (!id.contains('@')) {
        // 已是点位常量 id（或插件自建 id）：原样保留
        out.add(station);
        continue;
      }
      if (base.isEmpty) {
        out.add(station);
        continue;
      }
      migrated = true;
      groups.putIfAbsent(base, () => <StationInstance>[]).add(station);
    }

    for (final MapEntry<String, List<StationInstance>> entry in groups.entries) {
      final String base = entry.key;
      final List<StationInstance> members = entry.value;
      final StationInstance? merged = _mergeGroup(base, members);
      if (merged != null) out.add(merged);
    }
    return (stations: out, migrated: migrated);
  }

  /// 退役 id → 现在的点位 id（null = 不是退役 id）。
  ///
  /// - `system.relay` ⇒ 工具前 / 工具后**两个点位**（旧订阅复制到两处，行为等价：
  ///   原订阅者照样 pre / post 都收到，想只收一个的自己退订另一个）；
  /// - `system.execute` ⇒ **空列表 = 丢弃**（执行站不可订阅，没有订阅需要迁移）。
  static List<String>? _retiredTargets(String base) {
    if (base == StationHubIds.legacyRelay) {
      return <String>[
        StationHubIds.relayToolPre,
        StationHubIds.relayToolPost,
      ];
    }
    if (base == StationHubIds.legacyExecute) return const <String>[];
    return null;
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

    // 类型与说明由**点位表**决定（不再写死四个 base id 的 switch）。
    final StationPointSpec? spec = StationPoints.byId(base);
    if (spec == null) {
      // 未知基础 id 的旧格式条目：无法判定类型，丢弃（不猜）
      return null;
    }
    switch (spec.kind) {
      case StationKind.broadcast:
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
          id: spec.id,
          description: _descriptionOf(members, spec.label),
          maxSubscriptions: spec.maxSubscriptions,
          builtin: true,
          createdAt: created,
          subscribers: subscribers,
          boardLimit: boardLimit,
          boardSeq: boardSeq,
          board: trimmed,
        );
      case StationKind.execute:
        return ExecuteStation(
          id: spec.id,
          description: _descriptionOf(members, spec.label),
          maxSubscriptions: spec.maxSubscriptions,
          builtin: true,
          createdAt: created,
          subscribers: subscribers,
          commands: spec.commands,
        );
      case StationKind.relay:
        return RelayStation(
          id: spec.id,
          description: _descriptionOf(members, spec.label),
          maxSubscriptions: spec.maxSubscriptions,
          builtin: true,
          createdAt: created,
          subscribers: subscribers,
        );
      case StationKind.collect:
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
          id: spec.id,
          description: _descriptionOf(members, spec.label),
          schema: schema,
          maxSubscriptions: spec.maxSubscriptions,
          builtin: true,
          createdAt: created,
          subscribers: subscribers,
        );
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
            'Tree 站点实例（M9 站点体系；2026-10-01 点位化）\n'
            '站点类型四种（广播 / 执行 / 中转 / 收集），每类下有若干**点位**，'
            '每个点位是一个独立实例：\n'
            '  广播 system.broadcast[.tool.pre|.tool.post]\n'
            '  执行 system.execute.fs|terminal|agent|ui|llm|tool|session\n'
            '  中转 system.relay.tool.pre|tool.post|llm.handle|llm.request|'
            'context.compact|prompt.system\n'
            '  收集 plugin.tool.define\n'
            'id 不含 team / mode——team / agent / session / mode 是每次交互携带的消息 scope，'
            '只用于匹配订阅者。\n'
            '字段：id / 类型 / 订阅上限 / 订阅者列表（+ 收集站 schema、广播站公告板）。\n'
            '本文件可手工编辑；改动在核心下次启动时生效。',
      ),
    );
  }
}
