// 插件管理的前端请求形状（M9 §4.2）：路径 / 方法 / 请求体 / 错误文本。
//
// 用一个假的"核心进程"（本机 HttpServer）验证 ApiService 打到的是协议声明的路径，
// 且请求体字段与核心的校验口径一致——前端与核心的字段名一旦漂移，这些用例会先红。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/api_service.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 假核心：实现插件管理端点并记录收到的全部请求。
class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  /// 收到的请求（方法 / 路径 / 查询 / 请求体）。
  final List<
    ({String method, String path, String query, Map<String, dynamic> body})
  >
  requests =
      <({String method, String path, String query, Map<String, dynamic> body})>[];

  static Future<_FakeCore> start() async {
    final HttpServer http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeCore core = _FakeCore._(http);
    http.listen(core._handle);
    return core;
  }

  String get baseUrl => 'http://127.0.0.1:${_http.port}';

  Future<void> close() => _http.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final String rawBody = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> body = rawBody.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(rawBody) as Map<String, dynamic>;
    requests.add((
      method: request.method,
      path: request.uri.path,
      query: request.uri.query,
      body: body,
    ));

    final String path = request.uri.path;
    Map<String, dynamic> payload;
    int status = 200;
    if (path == ApiPaths.pluginConfigs && request.method == 'GET') {
      payload = <String, dynamic>{
        'path': 'C:/data/config/plugins.yaml',
        'enabled': true,
        'configs': <dynamic>[
          <String, dynamic>{'id': 'demo', 'command': 'python', 'enabled': true},
        ],
        'runtime': <String, dynamic>{
          'demo': <String, dynamic>{'running': false, 'known': false},
        },
      };
    } else if (path == ApiPaths.pluginConfigs) {
      // 新增：核心在 command 为空时回可读 400（这里用 'boom' 触发）
      if (body['command'] == 'boom') {
        status = 400;
        payload = <String, dynamic>{'detail': '插件 x 的 command 不能为空'};
      } else {
        payload = <String, dynamic>{
          'ok': true,
          'hot_applied': false,
          'notice': '配置已保存，但本次热应用失败，重启核心后生效',
          'hot_apply_detail': '该条目不在核心启动时读取的配置里（新增条目）',
        };
      }
    } else if (path == ApiPaths.pluginBuiltins && request.method == 'GET') {
      payload = <String, dynamic>{
        'path': 'C:/data/config/plugins.yaml',
        'builtins': <dynamic>[
          <String, dynamic>{'id': 'sample', 'enabled': false},
        ],
      };
    } else if (path.startsWith('/api/plugin')) {
      // 单条操作（PATCH / DELETE / restart / builtins 开关）统一回成功体
      payload = <String, dynamic>{
        'ok': true,
        'hot_applied': false,
        'notice': '配置已保存，但本次热应用失败，重启核心后生效',
      };
    } else {
      status = 404;
      payload = <String, dynamic>{'detail': '未知接口'};
    }
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

void main() {
  late _FakeCore core;

  setUp(() async {
    // flutter_test 默认装了 HttpOverrides：请求会被拦成 400、不真发出去。
    // 这里要打本机假核心（真 socket 往返），所以摘掉它。
    HttpOverrides.global = null;
    core = await _FakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
  });

  tearDown(() async {
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
  });

  test('读清单 / 读内置目录：路径与 refresh 查询参数', () async {
    final Map<String, dynamic> configs = await ApiService.getPluginConfigs();
    expect(core.requests.single.method, 'GET');
    expect(core.requests.single.path, ApiPaths.pluginConfigs);
    expect(configs['path'], contains('plugins.yaml'));
    expect((configs['configs'] as List<dynamic>).single['id'], 'demo');

    await ApiService.getPluginBuiltins();
    expect(core.requests.last.path, ApiPaths.pluginBuiltins);
    expect(core.requests.last.query, isEmpty);

    await ApiService.getPluginBuiltins(refresh: true);
    expect(core.requests.last.query, 'refresh=1', reason: 'refresh=1 强制核心重探运行时');
  });

  test('新增：POST /api/plugin/configs，字段与核心校验口径一致', () async {
    final Map<String, dynamic> result = await ApiService.createPluginConfig(
      id: 'demo',
      name: '演示',
      command: 'python',
      args: <String>['demo.py', '--x'],
      env: <String, String>{'A': '1'},
      granularity: 'session',
      scope: <String, String>{'team_id': 't1'},
      enabled: false,
    );
    final ({
      String method,
      String path,
      String query,
      Map<String, dynamic> body,
    })
    request = core.requests.single;
    expect(request.method, 'POST');
    expect(request.path, ApiPaths.pluginConfigs);
    expect(request.body, <String, dynamic>{
      'id': 'demo',
      'name': '演示',
      'command': 'python',
      'args': <String>['demo.py', '--x'],
      'env': <String, String>{'A': '1'},
      'enabled': false,
      'granularity': 'session',
      'scope': <String, String>{'team_id': 't1'},
    });
    // 热应用失败话术必须原样回给调用方（前端负责显示）
    expect(result['hot_applied'], isFalse);
    expect(result['notice'], '配置已保存，但本次热应用失败，重启核心后生效');
  });

  test('开关 / 编辑 / 删除 / 重启：单条路径带 id 转义', () async {
    await ApiService.updatePluginConfig('demo', <String, dynamic>{
      'enabled': false,
    });
    expect(core.requests.last.method, 'PATCH');
    expect(core.requests.last.path, '/api/plugin/configs/demo');
    expect(core.requests.last.body, <String, dynamic>{'enabled': false});

    await ApiService.deletePluginConfig('demo');
    expect(core.requests.last.method, 'DELETE');
    expect(core.requests.last.path, '/api/plugin/configs/demo');

    await ApiService.restartPluginConfig('demo');
    expect(core.requests.last.method, 'POST');
    expect(core.requests.last.path, '/api/plugin/configs/demo/restart');

    // id 里的特殊字符必须转义（核心的 id 字符集本不允许，但 URL 层要防御）
    await ApiService.deletePluginConfig('a b');
    expect(core.requests.last.path, '/api/plugin/configs/a%20b');
  });

  test('内置插件开关：enable / disable 两个端点', () async {
    await ApiService.setBuiltinPluginEnabled('sample', enabled: true);
    expect(core.requests.last.method, 'POST');
    expect(core.requests.last.path, '/api/plugin/builtins/sample/enable');

    await ApiService.setBuiltinPluginEnabled('sample', enabled: false);
    expect(core.requests.last.path, '/api/plugin/builtins/sample/disable');
  });

  test('核心的可读 400 会变成异常文本（面板直接显示给用户）', () async {
    await expectLater(
      ApiService.createPluginConfig(
        id: 'x',
        name: '',
        command: 'boom',
      ),
      throwsA(
        predicate(
          (Object? e) => '$e'.contains('command 不能为空'),
          '异常文本里带核心给的可读原因',
        ),
      ),
    );
  });
}
