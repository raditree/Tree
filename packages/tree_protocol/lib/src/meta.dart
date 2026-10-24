/// `GET /api/meta` 的回包值对象（**发现面**，设计见
/// `docs/pluginization/ui-pluginization.md` §3.1 / §4.1）。
///
/// 发现面**只聚合、不硬编码**（不变量 13）：`routes` / `stations` /
/// `capabilities` 全部来自收集站，核心不得维护第二份静态清单。本文件只定义
/// 线格式与宽容解析，不产生数据。
///
/// 回包形状：
/// ```json
/// {
///   "core_version": "1.0.4",
///   "api_version": "1.0",
///   "ui": [
///     { "plugin_id": "tree_ui_default", "version": "1.0.0",
///       "capabilities": ["plugin.manage"], "connections": 2 }
///   ],
///   "can_manage_plugins": true,
///   "routes": [
///     { "method": "GET", "pattern": "/api/files/{ws}", "owner": "files" }
///   ],
///   "stations": [
///     { "station_id": "system.broadcast", "point": "system.broadcast",
///       "owner_plugin_id": "core", "description": "通用公告板" }
///   ],
///   "capabilities": [ ...插件原样申报的任意 JSON... ]
/// }
/// ```
///
/// 全部解析都是**未知字段忽略**、缺失字段取默认值：UI 与核心独立发版，
/// 任何一侧多带一个字段都不应让另一侧报错。
library;

/// `/api/meta` 回包。
class ApiMeta {
  const ApiMeta({
    this.coreVersion = '',
    this.apiVersion = '',
    this.ui = const <ApiMetaUi>[],
    this.canManagePlugins = false,
    this.routes = const <ApiMetaRoute>[],
    this.stations = const <ApiMetaStation>[],
    this.capabilities = const <Object?>[],
  });

  /// 核心版本（展示 / 兼容诊断用）。
  final String coreVersion;

  /// 协议 API 版本（插件用 `requires.api` 与它比对）。
  final String apiVersion;

  /// 当前存活的 UI 连接（按连接聚合；同一插件多窗口 ⇒ 多条记录）。
  final List<ApiMetaUi> ui;

  /// 是否存在**存活且声明** `plugin.manage` 的 UI 连接（引导页判据）。
  final bool canManagePlugins;

  /// 已委派路由（`method + pattern → owner`）。
  final List<ApiMetaRoute> routes;

  /// **仅可订阅的广播站**（收集 / 中转 / 执行站不得出现在这里）。
  final List<ApiMetaStation> stations;

  /// 插件申报的 capability，**原样透传**（核心不解释、不校验）。
  final List<Object?> capabilities;

  /// 宽容解析（非 Map 入参由调用方先归一；未知键忽略）。
  factory ApiMeta.fromJson(Map<String, dynamic> json) => ApiMeta(
    coreVersion: _asString(json['core_version']),
    apiVersion: _asString(json['api_version']),
    ui: _asMaps(json['ui']).map(ApiMetaUi.fromJson).toList(growable: false),
    canManagePlugins: json['can_manage_plugins'] == true,
    routes: _asMaps(json['routes'])
        .map(ApiMetaRoute.fromJson)
        .toList(growable: false),
    stations: _asMaps(json['stations'])
        .map(ApiMetaStation.fromJson)
        .toList(growable: false),
    capabilities: _asList(json['capabilities']),
  );

  /// 序列化（字段全写；列表为空也保留，便于 UI 区分「空」与「老核心没给」）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'core_version': coreVersion,
    'api_version': apiVersion,
    'ui': ui.map((ApiMetaUi item) => item.toJson()).toList(),
    'can_manage_plugins': canManagePlugins,
    'routes': routes.map((ApiMetaRoute item) => item.toJson()).toList(),
    'stations': stations.map((ApiMetaStation item) => item.toJson()).toList(),
    'capabilities': capabilities,
  };

  @override
  String toString() =>
      'ApiMeta(core=$coreVersion, api=$apiVersion, ui=${ui.length}, '
      'routes=${routes.length}, stations=${stations.length})';
}

/// 一条 UI 连接记录（`/api/meta.ui[]`）。
class ApiMetaUi {
  const ApiMetaUi({
    required this.pluginId,
    this.version = '',
    this.capabilities = const <String>[],
    this.connections = 0,
  });

  /// UI 插件 id（与 `plugins.yaml` 中 `runtime: ui` 条目同串）。
  final String pluginId;

  /// 插件版本。
  final String version;

  /// 该连接 `ui.hello` 自报的能力（未知 capability 原样透传）。
  final List<String> capabilities;

  /// 该插件的连接数（多窗口 = 多条连接）。
  final int connections;

  /// 宽容解析。
  factory ApiMetaUi.fromJson(Map<String, dynamic> json) => ApiMetaUi(
    pluginId: _asString(json['plugin_id']),
    version: _asString(json['version']),
    capabilities: _asStrings(json['capabilities']),
    connections: _asInt(json['connections']),
  );

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'plugin_id': pluginId,
    'version': version,
    'capabilities': capabilities,
    'connections': connections,
  };
}

/// 一条委派路由（`/api/meta.routes[]`）。
class ApiMetaRoute {
  const ApiMetaRoute({
    required this.method,
    required this.pattern,
    required this.owner,
  });

  /// HTTP 方法（大写，如 `GET`）。
  final String method;

  /// 路径模式（含 `{param}` 占位，与 `ApiPaths` 同形）。
  final String pattern;

  /// 归属插件 id（同一 `method + pattern` 只允许一家）。
  final String owner;

  /// 宽容解析。
  factory ApiMetaRoute.fromJson(Map<String, dynamic> json) => ApiMetaRoute(
    method: _asString(json['method']),
    pattern: _asString(json['pattern']),
    owner: _asString(json['owner']),
  );

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'method': method,
    'pattern': pattern,
    'owner': owner,
  };
}

/// 一条**可订阅的广播站**（`/api/meta.stations[]`）。
///
/// 收集 / 中转 / 执行站一律不得出现在该列表（§6.4 的订阅权限）。
class ApiMetaStation {
  const ApiMetaStation({
    required this.stationId,
    this.point = '',
    this.ownerPluginId = '',
    this.description = '',
  });

  /// 站点全局 id（订阅时用它）。
  final String stationId;

  /// 内置点位 id / 别名（自建站可空）。
  final String point;

  /// 归属插件 id（内置站点归 `core` / 对应插件，自建站归注册方）。
  final String ownerPluginId;

  /// 站点介绍（面板展示用）。
  final String description;

  /// 宽容解析。
  factory ApiMetaStation.fromJson(Map<String, dynamic> json) => ApiMetaStation(
    stationId: _asString(json['station_id']),
    point: _asString(json['point']),
    ownerPluginId: _asString(json['owner_plugin_id']),
    description: _asString(json['description']),
  );

  /// 序列化（可选字段缺省时省略）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'station_id': stationId,
    if (point.isNotEmpty) 'point': point,
    if (ownerPluginId.isNotEmpty) 'owner_plugin_id': ownerPluginId,
    if (description.isNotEmpty) 'description': description,
  };
}

/// 字符串归一（缺失 ⇒ 空串）。
String _asString(Object? value) => value == null ? '' : value.toString();

/// 整数归一（缺失 / 非数值 ⇒ 0）。
int _asInt(Object? value) => value is num ? value.toInt() : 0;

/// 只保留 Map 元素（坏条目跳过，避免一条脏数据让整包解析失败）。
List<Map<String, dynamic>> _asMaps(Object? value) {
  if (value is! List) {
    return const <Map<String, dynamic>>[];
  }
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  for (final Object? item in value) {
    if (item is Map) {
      out.add(Map<String, dynamic>.from(item));
    }
  }
  return out;
}

/// 字符串列表（非列表 ⇒ 空；元素按 `toString()` 归一）。
List<String> _asStrings(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  return value
      .where((Object? item) => item != null)
      .map((Object? item) => item.toString())
      .toList(growable: false);
}

/// 原样列表（非列表 ⇒ 空；**不做任何元素转换**，capability 要原样透传）。
List<Object?> _asList(Object? value) =>
    value is List ? List<Object?>.unmodifiable(value) : const <Object?>[];
