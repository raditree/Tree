// 插件自定义点位（capability）的申报汇聚（20261015-hot-restart 阶段 6，A 级点位批）。
//
// 这一份存在的理由只有一个：**「核心里那个 switch 不认识的新事件」不该每次都要求
// 核心加一个点位常量 + 一个投递口**——那是"核心要频繁更新"最直接的来源。所以收集站
// `plugin.capability.define` 让插件把自己认得的点位**声明**出来（点位名 / 方向 /
// 事件名 / **字段表**），核心只负责登记与展示。
//
// 三条口径（钉死在这里，不随调用点漂）：
// 1. **申报只是描述，不产生投递路**：核心不认识的 event 不会因此开始发（否则插件可以
//    凭一个字符串骗过订阅者，说"这个事件有人发"）；
// 2. **schema 必须非空**：没有字段表的点位，面板与插件之间一定漂 ⇒ 那一条不登记，
//    并显式列出原因（只丢那一条，同插件其余条目照常登记 —— 与工具申报同一语义）；
// 3. **按 plugin_id 整批销账**：申报结果每轮重建（插件下线 / 热重启旧世代 / 没回包
//    ⇒ 那一份自然不在新表里），不给"上一条还在但没人发"留活口。
//
// 校验与汇聚写成**纯函数**（[absorbCapabilityRows]）：这样"缺 schema 就拒"这条纪律
// 可以直接单测，不必拉起真插件进程。
import 'station_runtime.dart';

/// 一个申报合格后的点位（进 `plugin_status` 行的 `capabilities` 键）。
///
/// `station_id` 是**命名空间化后**的全局 id（`plugin.{plugin_id}.{capability_id}`），
/// 与插件自建站同一套前缀规则：不加前缀就会有两个插件用同一个点位名互相顶掉。
class PluginCapability {
  const PluginCapability({
    required this.pluginId,
    required this.capabilityId,
    required this.event,
    required this.direction,
    required this.description,
    required this.schema,
  });

  /// 申报方（插件 id）。
  final String pluginId;

  /// 插件内唯一的点位名。
  final String capabilityId;

  /// 事件名（对方按它过滤）。
  final String event;

  /// 方向：`push`（插件往外发）| `pull`（核心来采集）。
  final String direction;

  /// 人话说明（可空：面板上显示点位名）。
  final String description;

  /// 字段表（**保证非空**，见文件头口径 2）。
  final Map<String, dynamic> schema;

  /// 全局点位 id（命名空间化）。
  String get stationId => 'plugin.$pluginId.$capabilityId';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'plugin_id': pluginId,
    'capability_id': capabilityId,
    'station_id': stationId,
    'event': event,
    'direction': direction,
    'description': description,
    'schema': schema,
  };
}

/// 一轮汇聚的结果：登记上的点位 + **显式列出的丢弃原因**。
class CapabilityAbsorption {
  const CapabilityAbsorption({required this.byPlugin, required this.notes});

  /// 按插件分组的合格点位（**每轮重建**：没出现在这里的插件就是没有申报）。
  final Map<String, List<PluginCapability>> byPlugin;

  /// 被丢掉的那几条（含未响应者），每条都说清"为什么这条没登记上"。
  final List<String> notes;

  /// 全部点位的扁平列表（按插件 id 顺序，供面板与 `plugin_status` 用）。
  List<PluginCapability> get all => <PluginCapability>[
    for (final List<PluginCapability> rows in byPlugin.values) ...rows,
  ];

  int get count => all.length;
}

/// 把收集站的采集产物汇成点位表（纯函数；口径见文件头）。
///
/// [items] 已通过收集站 schema 的**形状**校验（CollectStation 负责），这里只补
/// schema 校验管不到的两条：**字段表非空** 与 **方向取值**，以及命名空间化。
CapabilityAbsorption absorbCapabilityRows({
  required List<StationCollectedItem> items,
  List<StationUnresponsive> unresponsive = const <StationUnresponsive>[],
  List<String> skipped = const <String>[],
}) {
  final Map<String, List<PluginCapability>> byPlugin =
      <String, List<PluginCapability>>{};
  final List<String> notes = <String>[];

  for (final StationCollectedItem item in items) {
    final String pluginId = item.pluginId.trim();
    final Object? payload = item.payload;
    if (payload is! Map) {
      notes.add('插件 $pluginId 的点位申报不是对象（$payload），这一份不登记');
      continue;
    }
    final Object? raw = payload['capabilities'];
    if (raw is! List) {
      notes.add('插件 $pluginId 的点位申报缺 capabilities 数组，这一份不登记');
      continue;
    }
    // 同一次采集里同名点位只留第一条（避免一个插件自己顶自己）
    final Set<String> seen = <String>{};
    for (final Object? entry in raw) {
      if (entry is! Map) {
        notes.add('插件 $pluginId 有一条点位申报不是对象，丢掉那一条');
        continue;
      }
      final String capabilityId = '${entry['capability_id'] ?? ''}'.trim();
      final String event = '${entry['event'] ?? ''}'.trim();
      final String direction = '${entry['direction'] ?? ''}'.trim();
      final String description = '${entry['description'] ?? ''}'.trim();
      final Object? schema = entry['schema'];
      if (capabilityId.isEmpty) {
        notes.add('插件 $pluginId 有一条点位申报缺 capability_id，丢掉那一条');
        continue;
      }
      if (event.isEmpty) {
        notes.add(
          '插件 $pluginId 的点位 $capabilityId 缺事件名（event）：'
          '对方没法按它过滤，丢掉那一条',
        );
        continue;
      }
      if (direction != 'push' && direction != 'pull') {
        notes.add(
          '插件 $pluginId 的点位 $capabilityId 的 direction="$direction" 非法'
          '（只能是 push | pull），丢掉那一条',
        );
        continue;
      }
      if (schema is! Map || schema.isEmpty) {
        notes.add(
          '插件 $pluginId 的点位 $capabilityId 没有字段表（schema 为空）：'
          '不申报字段表的点位不会被登记（面板与插件之间必然漂），丢掉那一条',
        );
        continue;
      }
      if (!seen.add(capabilityId)) {
        notes.add('插件 $pluginId 重复申报点位 $capabilityId：只留第一条，其余丢掉');
        continue;
      }
      byPlugin
          .putIfAbsent(pluginId, () => <PluginCapability>[])
          .add(
            PluginCapability(
              pluginId: pluginId,
              capabilityId: capabilityId,
              event: event,
              direction: direction,
              description: description,
              schema: schema.map(
                (dynamic k, dynamic v) =>
                    MapEntry<String, dynamic>(k.toString(), v),
              ),
            ),
          );
    }
  }
  // 未响应者同样显式列出（与工具申报同口径：不静默，但也不影响别人那一份）
  for (final StationUnresponsive dead in unresponsive) {
    notes.add(
      '插件 ${dead.subscriber.pluginId} 没有交出点位申报（${dead.reason}）：'
      '这一轮它没有点位在册',
    );
  }
  notes.addAll(skipped);
  return CapabilityAbsorption(byPlugin: byPlugin, notes: notes);
}
