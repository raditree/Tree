import 'package:path/path.dart' as p;

import '../store/atomic_file.dart';
import '../store/yaml_codec.dart';
import 'station_instance.dart';

/// 站点实例落盘（M9 §3：站点 = 持久化实例，跨重启保留）。
///
/// 落点：与 plugins.yaml / mcp.yaml **同目录同风格**的
/// 「<数据根>/config/stations.yaml」（人类可直接阅读与手改）。形状：
///
///   version: 1
///   stations:
///     - id: system.broadcast@team-1@local
///       kind: broadcast
///       description: 广播站（系统自带）
///       scope: {team_id: team-1, agent_id: "", session_id: "", mode_key: local}
///       max_subscriptions: 32
///       builtin: true
///       created_at: 1789000000
///       subscribers:
///         - {plugin_id: sample, scope: {...}, subscribed_at: 1789000001}
///       board_limit: 50
///       board_seq: 3
///       board: [...]
///
/// 为什么用 yaml 而不是 jsonl：站点实例数量少、每条都很小，但**用户要能直接看懂
/// 与手改**（订阅上限、scope 绑定、收集站 schema、公告板都要求可读）；一次性原子
/// 快照写即可，不需要 messages.jsonl 那种追加日志。
class StationStore {
  StationStore(this.path);

  /// 文件路径。
  final String path;

  /// 落盘格式版本（将来结构变更时用于迁移；未知版本按当前结构宽容解析）。
  static const int version = 1;

  /// 由插件配置文件路径推导（保持 <数据根>/config/ 同目录，风格一致）。
  static String pathFor(String pluginConfigFile) =>
      p.join(p.dirname(pluginConfigFile), 'stations.yaml');

  /// 读取全部站点实例（文件不存在 = 空表；坏条目跳过而不是整库失败）。
  List<StationInstance> load() {
    final String? text = AtomicFile.readStringOrNullSync(path);
    if (text == null || text.trim().isEmpty) return <StationInstance>[];
    final List<StationInstance> stations = <StationInstance>[];
    try {
      final Map<String, dynamic> data = YamlCodec.decode(text);
      final Object? raw = data['stations'];
      if (raw is List) {
        for (final Object? item in raw) {
          final StationInstance? station = StationInstance.tryParse(item);
          if (station != null) stations.add(station);
        }
      }
    } catch (_) {
      // 文件被手工改坏：按空表启动（站点可重建），不阻塞核心
      return <StationInstance>[];
    }
    return stations;
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
            '站点 = 持久化实例：id / 类型 / scope 绑定 / 订阅上限 / 订阅者列表'
            '（+ 收集站 schema、广播站公告板）。\n'
            '本文件可手工编辑；改动在核心下次启动时生效。',
      ),
    );
  }
}
