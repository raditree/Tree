import 'dart:io';

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
