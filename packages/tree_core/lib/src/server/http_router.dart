import 'dart:io';

import 'package:tree_protocol/tree_protocol.dart'
    show ApiMetaRoute, ApiPaths;

/// HTTP 路由处理函数。
///
/// [pathParams] 是模式中 `{name}` 占位符的取值（已由 `Uri.pathSegments`
/// 解码，故此处**不再二次解码**，避免含 `%` 的 id 被误解）。
typedef HttpRouteHandler = Future<void> Function(
  HttpRequest request,
  Map<String, String> pathParams,
);

/// 一次成功匹配：命中的路由 + 路径参数。
class HttpRouteMatch {
  const HttpRouteMatch(this.route, this.params);

  final HttpRoute route;
  final Map<String, String> params;
}

/// 单条路由（方法 + 模式 + 处理函数）。
class HttpRoute {
  HttpRoute(this.method, this.pattern, this.handler)
    // 必须去掉**前导空段**：`'/api/models'.split('/')` 是
    // `['', 'api', 'models']`，而 `Uri.pathSegments` 为 `['api','models']`，
    // 不去掉则长度永远差 1、任何路由都匹配不上。
    : _segments = (pattern.startsWith('/') ? pattern.substring(1) : pattern)
          .split('/');

  /// HTTP 方法（大写）。
  final String method;

  /// 模式，形如 `/api/agents/{agentId}/sessions`。
  final String pattern;

  final HttpRouteHandler handler;
  final List<String> _segments;

  /// 匹配 [method] + 路径分段；不匹配返回 null，匹配返回路径参数。
  Map<String, String>? match(String method, List<String> segments) {
    if (method != this.method) return null;
    if (segments.length != _segments.length) return null;
    final Map<String, String> params = <String, String>{};
    for (int i = 0; i < segments.length; i++) {
      final String expected = _segments[i];
      final String actual = segments[i];
      if (expected.length >= 2 &&
          expected.startsWith('{') &&
          expected.endsWith('}')) {
        if (actual.isEmpty) return null;
        params[expected.substring(1, expected.length - 1)] = actual;
      } else if (expected != actual) {
        return null;
      }
    }
    return params;
  }
}

/// 核心进程的极简路由表。
///
/// 不用 shelf 等第三方框架：核心进程要保持零第三方依赖（便于
/// `dart compile exe` 单文件分发），而需求只是"精确路径 + 占位符"匹配。
class CoreRouter {
  final List<HttpRoute> _routes = <HttpRoute>[];

  /// 注册一条路由。
  void add(String method, String pattern, HttpRouteHandler handler) {
    _routes.add(HttpRoute(method.toUpperCase(), pattern, handler));
  }

  /// 已注册路由的 `METHOD pattern` 列表（自检/覆盖度测试用）。
  List<String> get routes => _routes
      .map((HttpRoute r) => '${r.method} ${r.pattern}')
      .toList(growable: false);

  /// 已注册的路径模式集合（不含方法；覆盖度测试用）。
  Set<String> get patterns => _routes.map((HttpRoute r) => r.pattern).toSet();

  /// 查找匹配路由。
  HttpRouteMatch? match(String method, List<String> segments) {
    for (final HttpRoute route in _routes) {
      final Map<String, String>? params = route.match(method, segments);
      if (params != null) return HttpRouteMatch(route, params);
    }
    return null;
  }
}

/// 插件通过 `system.collect.api.routes` 申报的一条委派路由。
class DelegatedRouteDeclaration {
  DelegatedRouteDeclaration({
    required String method,
    required this.pattern,
    required this.pluginId,
  }) : method = method.toUpperCase(),
       _segments = (pattern.startsWith('/') ? pattern.substring(1) : pattern)
           .split('/');

  /// HTTP 方法（已归一为大写）。
  final String method;

  /// 路径模式（必须满足 [ApiPaths.delegationPatternError] 的命名空间规则）。
  final String pattern;

  /// 归属插件 id。
  final String pluginId;

  final List<String> _segments;

  /// 归属键：`METHOD pattern`。
  ///
  /// 同一键只允许一家插件；[DelegatedRouter] 用它做冲突检测。
  String get key => '$method $pattern';

  /// 匹配给定方法 + 路径分段；命中返回路径参数。
  Map<String, String>? match(String method, List<String> segments) {
    if (method != this.method) return null;
    if (segments.length != _segments.length) return null;
    final Map<String, String> params = <String, String>{};
    for (int i = 0; i < segments.length; i++) {
      final String expected = _segments[i];
      final String actual = segments[i];
      if (expected.length >= 2 &&
          expected.startsWith('{') &&
          expected.endsWith('}')) {
        if (actual.isEmpty) return null;
        params[expected.substring(1, expected.length - 1)] = actual;
      } else if (expected != actual) {
        return null;
      }
    }
    return params;
  }
}

/// 一次委派命中：归属插件 + 路径参数。
class DelegatedRouteMatch {
  const DelegatedRouteMatch(this.declaration, this.params);

  final DelegatedRouteDeclaration declaration;
  final Map<String, String> params;

  String get pluginId => declaration.pluginId;
}

/// **委派路由归属表**（核心侧缓存，§3.3 / §5.4）。
///
/// 设计要点：
/// - 表里只保存**插件申报**的 `method + pattern`，核心不据此推断插件能力；
/// - 同一 `method + pattern` 被两家以上插件申报 ⇒ **整条拒收**（不按启动顺序择一），
///   冲突键不出现在匹配与 `/api/meta` 里，[notes] 里留可读原因；
/// - 插件重新申报时按 `plugin_id` 整组替换；插件被卸载时 [removePlugin] 销账；
/// - **命名空间规则，不设静态白名单**（L-28）：路径必须满足
///   [ApiPaths.delegationPatternError]，且不得命中核心永久面（[ApiPaths.coreOwned]）；
/// - **迁移期同键申报接受但标注 shadowed**：命中「核心当前已实现」的键不拒收，
///   只在 [notes] 里写明「暂由核心承接」；查表顺序保证核心优先，核心删除该实现后
///   同一申报自动生效——这是双跑期（A2~A4）能先申报、后交接的前提。
class DelegatedRouter {
  DelegatedRouter({Set<String>? coreRouteKeys})
    : _coreRouteKeys = <String>{...?coreRouteKeys};

  /// 核心**当前已实现**的方法路由键集（`METHOD /pattern`）。
  ///
  /// 由 `CoreServer` 在 `_registerRoutes` 之后绑定。申报命中这些键 ⇒ **接受**，
  /// 但在 [notes] 里标注 shadowed：核心 router 优先承接，交接删除后同一申报
  /// 自动生效。拒收只留给核心永久面（`coreOwned`）与保留前缀。
  Set<String> _coreRouteKeys;

  /// 绑定核心已实现路由（服务器启动时调用一次；键格式同 [CoreRouter.routes]）。
  void bindCoreRoutes(Iterable<String> keys) {
    _coreRouteKeys = keys.toSet();
  }

  /// 允许的 HTTP 方法。只覆盖 REST 委派实际会用到的方法。
  static const Set<String> allowedMethods = <String>{
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
  };

  /// plugin_id → 该插件当前申报的全部路由（按 key 去重后）。
  final Map<String, Map<String, DelegatedRouteDeclaration>> _byPlugin =
      <String, Map<String, DelegatedRouteDeclaration>>{};

  /// 无冲突的归属键 → 声明。
  final Map<String, DelegatedRouteDeclaration> _owners =
      <String, DelegatedRouteDeclaration>{};

  /// 冲突键 → 申报它的插件 id 集合（键本身**没有**归属）。
  final Map<String, Set<String>> _conflicts = <String, Set<String>>{};

  /// 最近一次重建留下的可读拒收原因（冲突 / 白名单外 / 方法非法）。
  final List<String> _notes = <String>[];

  /// 可读的拒收原因（按最近一次重建的顺序）。
  List<String> get notes => List<String>.unmodifiable(_notes);

  /// 当前有效归属数（冲突条目不计）。
  int get routeCount => _owners.length;

  /// 冲突键数量。
  int get conflictCount => _conflicts.length;

  /// `/api/meta.routes` 数据源：只返回**唯一归属**的路由（冲突条目不出现）。
  List<ApiMetaRoute> metaRoutes() {
    final List<DelegatedRouteDeclaration> routes = _owners.values.toList()
      ..sort((DelegatedRouteDeclaration a, DelegatedRouteDeclaration b) {
        final int byMethod = a.method.compareTo(b.method);
        return byMethod != 0 ? byMethod : a.pattern.compareTo(b.pattern);
      });
    return <ApiMetaRoute>[
      for (final DelegatedRouteDeclaration route in routes)
        ApiMetaRoute(
          method: route.method,
          pattern: route.pattern,
          owner: route.pluginId,
        ),
    ];
  }

  /// 校验一条原始申报；合法返回声明，否则返回 null 并把原因写进 [notes]。
  ///
  /// [method] / [pattern] 由调用方从 JSON 里取字符串（schema 已保证类型）。
  DelegatedRouteDeclaration? declarationFor({
    required String pluginId,
    required String method,
    required String pattern,
  }) {
    final String normalizedMethod = method.trim().toUpperCase();
    final String normalizedPattern = pattern.trim();
    if (!allowedMethods.contains(normalizedMethod)) {
      _notes.add(
        '插件 $pluginId 的路由申报被拒：方法 "$method" 不在允许集合 '
        '${allowedMethods.join('/')} 中',
      );
      return null;
    }
    final String? contract = ApiPaths.delegationKeyError(
      normalizedMethod,
      normalizedPattern,
    );
    if (contract != null) {
      _notes.add('插件 $pluginId 的路由申报被拒：$pattern —— $contract');
      return null;
    }
    final String key = ApiPaths.routeKey(normalizedMethod, normalizedPattern);
    if (_coreRouteKeys.contains(key)) {
      // 双跑期（A2~A4）：先申报、后交接。核心 router 永远优先，所以接受这份
      // 申报不会改变线上行为；但必须留一条可读记录，免得读者以为它已在承接。
      _notes.add(
        '插件 $pluginId 申报 $key：核心仍在实现该路由，暂由核心承接；'
        '核心交接删除后同一申报自动生效（shadowed）',
      );
    }
    return DelegatedRouteDeclaration(
      method: normalizedMethod,
      pattern: normalizedPattern,
      pluginId: pluginId,
    );
  }

  /// **整组替换**某个插件的申报（插件重新申报时按 `plugin_id` 销账）。
  ///
  /// 传空列表 = 该插件当前没有有效申报；传 null 表示不触碰（插件没响应时
  /// 保留上一份，以便请求仍能定位到归属插件并给 503）。
  void replacePlugin(
    String pluginId,
    List<DelegatedRouteDeclaration>? declarations,
  ) {
    if (declarations == null) return;
    final Map<String, DelegatedRouteDeclaration> byKey =
        <String, DelegatedRouteDeclaration>{};
    for (final DelegatedRouteDeclaration declaration in declarations) {
      // 同一插件重复申报同一条只保留一次（后申报的覆盖前者，值相同）。
      byKey[declaration.key] = declaration;
    }
    if (byKey.isEmpty) {
      _byPlugin.remove(pluginId);
    } else {
      _byPlugin[pluginId] = byKey;
    }
    _rebuild();
  }

  /// 按 `plugin_id` 销账（插件被卸载时调用）。幂等。
  void removePlugin(String pluginId) {
    if (_byPlugin.remove(pluginId) != null) _rebuild();
  }

  /// 开始一轮新的申报收集：清掉上一轮的可读原因（冲突原因会在重建时重新生成）。
  void beginRound() => _notes.clear();

  /// 清空归属表（总线关闭 / 测试重置用）。
  void clear() {
    _byPlugin.clear();
    _owners.clear();
    _conflicts.clear();
    _notes.clear();
  }

  /// 查找归属插件；未申报或处于冲突状态的路径返回 null（由上层决定 404 / 501）。
  DelegatedRouteMatch? match(String method, List<String> segments) {
    final String normalizedMethod = method.toUpperCase();
    for (final DelegatedRouteDeclaration declaration in _owners.values) {
      final Map<String, String>? params = declaration.match(
        normalizedMethod,
        segments,
      );
      if (params != null) return DelegatedRouteMatch(declaration, params);
    }
    return null;
  }

  /// 按插件整理后重建全局归属表。
  ///
  /// 先聚合再判冲突，因此结果**与插件申报顺序无关**；冲突只在当前申报集上成立，
  /// 某一家下线后另一家会自然恢复为唯一归属（下一次重建时生效）。
  void _rebuild() {
    _owners.clear();
    _conflicts.clear();
    // 冲突原因每轮重建，先清掉上一轮的冲突注记；本轮的申报校验原因（白名单 /
    // 方法非法）保留，它们发生在 replacePlugin 之前。
    _notes.removeWhere((String note) => note.startsWith('路由冲突：'));
    final Map<String, Map<String, DelegatedRouteDeclaration>> byKey =
        <String, Map<String, DelegatedRouteDeclaration>>{};
    for (final MapEntry<String, Map<String, DelegatedRouteDeclaration>> entry
        in _byPlugin.entries) {
      for (final MapEntry<String, DelegatedRouteDeclaration> route
          in entry.value.entries) {
        (byKey[route.key] ??= <String, DelegatedRouteDeclaration>{})[entry.key] =
            route.value;
      }
    }
    for (final MapEntry<String, Map<String, DelegatedRouteDeclaration>> entry
        in byKey.entries) {
      if (entry.value.length == 1) {
        _owners[entry.key] = entry.value.values.single;
      } else {
        _conflicts[entry.key] = entry.value.keys.toSet();
        _notes.add(
          '路由冲突：${entry.key} 被 ${entry.value.keys.join('、')} 同时申报 '
          '⇒ 整条拒收（不按启动顺序择一）',
        );
      }
    }
  }
}
