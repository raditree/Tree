import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 核心 HTTP 骨架的**平台面**测试（A5：领域面已整体移交插件）。
///
/// 保留的覆盖：
/// - 启动 / 握手 / 随机端口；
/// - 本地 token 鉴权（HTTP + WS 升级拒绝）；
/// - 路由覆盖度不变量：核心 router **恰好**是 [ApiPaths.coreOwned] 的 39 条；
/// - 未知路径一律 404（M7 起无 501 桩）；
/// - 核心仍实现的传输设置端点（帧率 / 数据收集开关）。
///
/// 领域路由（agents / models / sessions / files / specs / todos / questions /
/// tools-running / token-rate …）的实现已随 A5 删除，其行为测试在插件仓。
class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
    bool omitAuth = false,
  }) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    if (!omitAuth) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${token ?? _server.token}',
      );
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder.bind(response).join();
    return _Res(
      response.statusCode,
      text.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  void close() => _http.close(force: true);
}

class _Res {
  const _Res(this.status, this.json);

  final int status;
  final Map<String, dynamic> json;

  @override
  String toString() => 'HTTP $status $json';
}

void main() {
  late CoreServer server;
  late _Client client;

  setUp(() async {
    server = await CoreServer.start(enableHeartbeat: false);
    client = _Client(server);
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  group('启动与握手', () {
    test('监听回环随机端口，且 token 具备足够熵', () async {
      expect(server.address.address, '127.0.0.1');
      expect(server.port, greaterThan(0));
      expect(server.handshake.httpBaseUrl, 'http://127.0.0.1:${server.port}');
      expect(server.handshake.wsBaseUrl, 'ws://127.0.0.1:${server.port}');
      expect(server.token.length, greaterThanOrEqualTo(42));
      expect(server.processId, pid);

      // 握手行必须能被协议包的解析器读回（前端父进程即按此解析）
      final CoreHandshake? decoded = CoreHandshake.decode(
        server.handshake.encode(),
      );
      expect(decoded, isNotNull);
      expect(decoded!.port, server.port);
      expect(decoded.token, server.token);
      expect(decoded.pid, pid);
    });

    test('两个实例端口互不冲突（内核分配）', () async {
      final CoreServer other = await CoreServer.start(enableHeartbeat: false);
      expect(other.port, isNot(server.port));
      await other.close();
    });
  });

  group('本地 token 鉴权', () {
    test('缺 Authorization 头 -> 401', () async {
      final _Res res = await client.send('GET', ApiPaths.meta, omitAuth: true);
      expect(res.status, 401);
      expect(server.rejectedRequests, 1);
    });

    test('token 错误 -> 401；正确 -> 200', () async {
      expect(
        (await client.send('GET', ApiPaths.meta, token: 'bad')).status,
        401,
      );
      expect((await client.send('GET', ApiPaths.meta)).status, 200);
    });

    test('WS token 错误 -> 401（拒绝升级）', () async {
      final _Res res = await client.send(
        'GET',
        '${CoreServer.wsPath}?token=bad',
      );
      expect(res.status, 401);
    });
  });

  group('路由覆盖度不变量', () {
    test('核心 router 键集 == coreOwned（A5 后只有平台面 40 条）', () {
      final Set<String> registered = server.router.routes.toSet();
      final Set<String> stubs = server.stubRouter.patterns;
      final Set<String> coreOwned = ApiPaths.coreOwned;

      expect(
        coreOwned.length,
        40,
        reason: '核心永久面 40 条（36 + UI 多窗口 3 + 本地安装 1）',
      );
      expect(
        registered,
        coreOwned,
        reason: 'A5 后核心只注册 coreOwned：领域路由全部由插件委派承接',
      );
      expect(
        coreOwned.intersection(ApiPaths.delegated),
        isEmpty,
        reason: '核心永久面不得同时出现在插件契约面',
      );
      expect(
        ApiPaths.pendingHandoffRoutes,
        isEmpty,
        reason: 'A5 已完成迁移债清零（git 3 已按用户决定删除，不再登记 pending）',
      );
      expect(
        registered
            .map((String key) => key.substring(key.indexOf(' ') + 1))
            .toSet()
            .difference(ApiPaths.kept),
        isEmpty,
        reason: '核心 router 的路径必须在 ApiPaths.kept 内（前端可调用面不脱契约）',
      );

      expect(
        server.router.patterns.intersection(stubs),
        isEmpty,
        reason: '同一路径不应既实现又声明为未实现',
      );
      expect(stubs, CoreServer.stubApiPaths);
      expect(
        CoreServer.stubApiPaths,
        isEmpty,
        reason:
            'M7 已把最后一项桩（PDF 预览）改成前端渲染；新增接口时要么实现、'
            '要么显式登记，别让这条空集合悄悄长回来',
      );
    });

    test('未知路径 -> 404；M7 之后已无 501 桩', () async {
      expect((await client.send('GET', '/api/nope')).status, 404);
      expect(server.notFoundRequests, 1);

      // M7 把最后一项桩（PDF 预览）改为前端渲染：此时任何未实现路径都该是 404，
      // 且 stubRequests 计数保持 0（501 只在真登记了桩时才可能出现）。
      expect((await client.send('POST', '/api/nope')).status, 404);
      expect(server.stubRequests, 0);
    });
  });

  group('设置（核心永久面）', () {
    test('帧率夹取与数据收集开关', () async {
      final _Res initial = await client.send('GET', ApiPaths.settingsFrameRate);
      expect(initial.json['frame_rate'], CoreSettings.frameRateMin);
      expect(initial.json['min'], CoreSettings.frameRateMin);
      expect(initial.json['max'], CoreSettings.frameRateMax);

      final _Res set = await client.send(
        'POST',
        ApiPaths.settingsFrameRate,
        body: <String, dynamic>{'frame_rate': 99999},
      );
      expect(set.json['frame_rate'], CoreSettings.frameRateMax);

      expect(
        (await client.send(
          'POST',
          ApiPaths.settingsDataCollection,
          body: <String, dynamic>{'enabled': true},
        )).status,
        200,
      );
      expect(server.settings.dataCollectionEnabled, isTrue);
    });
  });
}
