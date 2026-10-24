// 片 F：日志与存储 API 的契约测试（核心永久面）。
//
// 锁住的口径（见 docs/pluginization/ui-pluginization.md §3.1 / §4.1、不变量 25）：
// 1. 日志源只有 `core` 与 `plugin:<id>`，非法 / 路径穿越一律 400；
// 2. 尾部读 `tail` 默认 200、上限 5000，`since` 是**行号（1 起）**，`next_since`
//    可直接续读；单次响应超过 1 MiB 只回最后一页并 `truncated:true`；
// 3. 存储是二进制原样存取，etag = 内容哈希；已存在的键必须带正确 etag（`*` 无条件），
//    不存在的键允许不带 etag 创建；
// 4. 命名空间隔离：调用方由 `X-Tree-Plugin-Id` 判定（缺省 = `core`），跨命名空间
//    一律 403，且不泄露目标命名空间是否存在；
// 5. 引导会话 token 不在日志/存储白名单内 ⇒ 403。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

class _Res {
  const _Res({
    required this.status,
    required this.bytes,
    this.etag,
    this.contentType,
  });

  final int status;
  final List<int> bytes;
  final String? etag;
  final String? contentType;

  Map<String, dynamic> get json => bytes.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

  String get detail => (json['detail'] ?? '').toString();

  String get text => utf8.decode(bytes);
}

class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(
    String method,
    String path, {
    List<int>? body,
    String? contentType,
    Map<String, String> headers = const <String, String>{},
    String? token,
  }) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${token ?? _server.token}',
    );
    for (final MapEntry<String, String> header in headers.entries) {
      request.headers.set(header.key, header.value);
    }
    if (body != null) {
      if (contentType != null) {
        request.headers.contentType = ContentType.parse(contentType);
      }
      request.add(body);
    }
    final HttpClientResponse response = await request.close();
    final String? etag = response.headers.value('etag');
    final String? mime = response.headers.contentType?.mimeType;
    final List<int> bytes = await response.fold<List<int>>(
      <int>[],
      (List<int> all, List<int> chunk) => all..addAll(chunk),
    );
    return _Res(
      status: response.statusCode,
      bytes: bytes,
      etag: etag,
      contentType: mime,
    );
  }

  void close() => _http.close(force: true);
}

void main() {
  late Directory temp;
  late PluginBus bus;
  late CoreServer server;
  late _Client client;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tree-log-store-');
    final File config = File(p.join(temp.path, 'config', 'plugins.yaml'));
    config.parent.createSync(recursive: true);
    config.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: tree.alpha\n'
      '    command: dart\n'
      '  - id: tree.beta\n'
      '    command: dart\n',
    );
    bus = PluginBus(configFile: config.path, coreVersion: 'test');
    server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      dataDir: temp.path,
      pluginBus: bus,
    );
    client = _Client(server);
  });

  tearDown(() async {
    client.close();
    await server.close();
    await bus.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  String logPath(String source) => source == 'core'
      ? p.join(temp.path, 'logs', 'core.log')
      : p.join(temp.path, 'logs', 'plugins', '$source.log');

  void seedLog(String source, List<String> lines, {bool trailing = true}) {
    final File file = File(logPath(source));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      lines.join('\n') + (trailing ? '\n' : ''),
    );
  }

  Map<String, String> asPlugin(String id) => <String, String>{
    CoreServer.pluginIdHeader: id,
  };

  group('日志 API', () {
    test('sources 枚举 core / 已配置插件 / 已存在文件', () async {
      seedLog('core', <String>['{"n":1}']);
      seedLog('tree.alpha', <String>['alpha-1']);
      // 未配置但已有日志文件（例如卸载后残留）也要能作为源读。
      seedLog('tree.gamma', <String>['gamma-1']);
      final _Res res = await client.send('GET', ApiPaths.logSources);
      expect(res.status, 200);
      final List<Map<String, dynamic>> sources =
          (res.json['sources'] as List<dynamic>? ?? <dynamic>[])
              .cast<Map<String, dynamic>>();
      final Map<String, Map<String, dynamic>> byId =
          <String, Map<String, dynamic>>{
            for (final Map<String, dynamic> row in sources)
              row['id'] as String: row,
          };
      expect(byId.keys, containsAll(<String>[
        'core',
        'plugin:tree.alpha',
        'plugin:tree.beta',
        'plugin:tree.gamma',
      ]));
      expect(byId['core']!['kind'], 'core');
      expect(byId['plugin:tree.alpha']!['kind'], 'plugin');
      expect(byId['plugin:tree.alpha']!['size'], greaterThan(0));
      // 已配置但还没有日志文件：仍在枚举里，但无 size/modified。
      expect(byId['plugin:tree.beta']!.containsKey('size'), isFalse);
    });

    test('tail 默认 200；since 是行号，next_since 可续读', () async {
      seedLog('core', <String>[
        for (int index = 1; index <= 300; index++) '{"n":$index}',
      ]);
      final _Res defaulted = await client.send(
        'GET',
        '${ApiPaths.logSources.replaceFirst('/sources', '')}/core',
      );
      final List<dynamic> defaultLines =
          defaulted.json['lines'] as List<dynamic>;
      expect(defaultLines.length, 200);
      expect(defaultLines.first, '{"n":101}');
      expect(defaultLines.last, '{"n":300}');
      expect(defaulted.json['next_since'], 301);
      expect(defaulted.json['truncated'], false);

      final _Res first = await client.send(
        'GET',
        '/api/logs/core?tail=10&since=11',
      );
      expect((first.json['lines'] as List<dynamic>).length, 10);
      expect((first.json['lines'] as List<dynamic>).first, '{"n":11}');
      expect(first.json['next_since'], 21);

      final _Res next = await client.send(
        'GET',
        '/api/logs/core?tail=10&since=${first.json['next_since']}',
      );
      expect((next.json['lines'] as List<dynamic>).first, '{"n":21}');
      expect(next.json['next_since'], 31);

      // 没有新行时 next_since = EOF + 1（轮询不会倒退）。
      final _Res empty = await client.send(
        'GET',
        '/api/logs/core?tail=10&since=301',
      );
      expect(empty.json['lines'], isEmpty);
      expect(empty.json['next_since'], 301);

      // since 越过 EOF（例如清空后又从第 1 行写起）⇒ 回到 EOF+1，不永久跳过新日志。
      final _Res stale = await client.send(
        'GET',
        '/api/logs/core?tail=10&since=9999',
      );
      expect(stale.json['lines'], isEmpty);
      expect(stale.json['next_since'], 301);
    });

    test('tail 上限 5000', () async {
      seedLog('core', <String>[
        for (int index = 1; index <= 6000; index++) 'line-$index',
      ]);
      final _Res res = await client.send(
        'GET',
        '/api/logs/core?tail=999999',
      );
      expect(res.status, 200);
      expect(res.json['tail'], 5000);
      expect((res.json['lines'] as List<dynamic>).length, 5000);
      expect(res.json['next_since'], 6001);
    });

    test('单次响应超过 1 MiB ⇒ 只回最后一页 + truncated', () async {
      final String long = 'x' * 300;
      seedLog('core', <String>[
        for (int index = 1; index <= 6000; index++) '$long-$index',
      ]);
      final _Res res = await client.send('GET', '/api/logs/core?tail=5000');
      expect(res.status, 200);
      expect(res.json['truncated'], true);
      final List<dynamic> lines = res.json['lines'] as List<dynamic>;
      expect(lines.length, lessThan(5000));
      expect(utf8.encode(res.text).length, lessThan(1200 * 1024));
      // next_since 仍是文件总行数 + 1（续读从新一轮追加处开始）。
      expect(res.json['next_since'], 6001);
    });

    test('plugin 源可读', () async {
      seedLog('tree.alpha', <String>['a1', 'a2']);
      final _Res res = await client.send(
        'GET',
        '/api/logs/plugin:tree.alpha?tail=1',
      );
      expect(res.status, 200);
      expect(res.json['lines'], <String>['a2']);
      expect(res.json['next_since'], 3);
    });

    test('清空并轮转：当前份 → .1.log，返回字节数与备份路径', () async {
      seedLog('core', <String>['one', 'two', 'three']);
      final _Res res = await client.send('DELETE', '/api/logs/core');
      expect(res.status, 200);
      expect(res.json['cleared_bytes'], greaterThan(0));
      final String backup = res.json['backup_path'] as String;
      expect(backup, p.join(temp.path, 'logs', 'core.1.log'));
      expect(File(backup).existsSync(), isTrue);
      expect(File(p.join(temp.path, 'logs', 'core.log')).existsSync(), isFalse);

      final _Res after = await client.send('GET', '/api/logs/core');
      expect(after.status, 200);
      expect(after.json['lines'], isEmpty);
      expect(after.json['size'], 0);

      // 再清一次：文件不存在 ⇒ 0 字节、无备份。
      final _Res again = await client.send('DELETE', '/api/logs/core');
      expect(again.json['cleared_bytes'], 0);
      expect(again.json['backup_path'], isNull);
    });

    test('非法 source / 路径穿越 ⇒ 400', () async {
      final List<String> paths = <String>[
        '/api/logs/other',
        '/api/logs/plugin:',
        '/api/logs/plugin:%2E%2E%2Fcore',
        '/api/logs/plugin:tree%2Falpha',
        '/api/logs/plugin:tree.beta%2E%2E',
      ];
      for (final String path in paths) {
        final _Res res = await client.send('GET', path);
        expect(res.status, 400, reason: '$path -> ${res.text}');
        expect(res.detail, isNotEmpty, reason: path);
      }
    });
  });

  group('存储 API', () {
    test('无 etag 创建 → 读取原样字节 + etag 头', () async {
      final List<int> value = <int>[0x00, 0xFF, 0x01, 0xFE, 0x0A, 0x0D];
      final _Res created = await client.send(
        'PUT',
        '/api/store/tree.alpha/bin',
        body: value,
        headers: asPlugin('tree.alpha'),
        contentType: 'application/octet-stream',
      );
      expect(created.status, 200, reason: created.text);
      expect(created.json['created'], true);
      final String etag = created.json['etag'] as String;

      final _Res read = await client.send(
        'GET',
        '/api/store/tree.alpha/bin',
        headers: asPlugin('tree.alpha'),
      );
      expect(read.status, 200);
      expect(read.bytes, value);
      expect(read.contentType, 'application/octet-stream');
      expect(read.etag, '"$etag"');
    });

    test('已存在必须带正确 etag；错误 / 缺失 ⇒ 409', () async {
      final _Res created = await client.send(
        'PUT',
        '/api/store/tree.alpha/k',
        body: utf8.encode('v1'),
        headers: asPlugin('tree.alpha'),
        contentType: 'application/octet-stream',
      );
      final String etag = created.json['etag'] as String;

      final _Res missing = await client.send(
        'PUT',
        '/api/store/tree.alpha/k',
        body: utf8.encode('v2'),
        headers: asPlugin('tree.alpha'),
        contentType: 'application/octet-stream',
      );
      expect(missing.status, 409);
      expect(missing.detail, contains('etag'));

      final _Res wrong = await client.send(
        'PUT',
        '/api/store/tree.alpha/k',
        body: utf8.encode('v2'),
        headers: <String, String>{
          ...asPlugin('tree.alpha'),
          'if-match': '"deadbeef"',
        },
        contentType: 'application/octet-stream',
      );
      expect(wrong.status, 409);

      final _Res updated = await client.send(
        'PUT',
        '/api/store/tree.alpha/k',
        body: utf8.encode('v2'),
        headers: <String, String>{
          ...asPlugin('tree.alpha'),
          'if-match': '"$etag"',
        },
        contentType: 'application/octet-stream',
      );
      expect(updated.status, 200);
      expect(updated.json['created'], false);
      expect(updated.json['etag'], isNot(etag));

      // `*` = 无条件覆盖。
      final _Res forced = await client.send(
        'PUT',
        '/api/store/tree.alpha/k',
        body: utf8.encode('v3'),
        headers: <String, String>{
          ...asPlugin('tree.alpha'),
          'if-match': '*',
        },
        contentType: 'application/octet-stream',
      );
      expect(forced.status, 200);

      // 新键带具体 etag ⇒ 409（不存在的键不许"凭空"匹配）。
      final _Res newWithEtag = await client.send(
        'PUT',
        '/api/store/tree.alpha/fresh',
        body: utf8.encode('x'),
        headers: <String, String>{
          ...asPlugin('tree.alpha'),
          'if-match': '"$etag"',
        },
        contentType: 'application/octet-stream',
      );
      expect(newWithEtag.status, 409);
    });

    test('JSON 信封体：etag 也可以放在 body 里', () async {
      final _Res created = await client.send(
        'PUT',
        '/api/store/tree.alpha/env',
        body: utf8.encode(jsonEncode(<String, dynamic>{
          'etag': '*',
          'value': <String, dynamic>{'answer': 42},
        })),
        headers: asPlugin('tree.alpha'),
        contentType: 'application/json',
      );
      expect(created.status, 200, reason: created.text);
      final String etag = created.json['etag'] as String;

      // value 按 JSON 原样落盘（核心不解释语义，只存字节）。
      final _Res got = await client.send(
        'GET',
        '/api/store/tree.alpha/env',
        headers: asPlugin('tree.alpha'),
      );
      expect(utf8.decode(got.bytes), '{"answer":42}');

      final _Res conflict = await client.send(
        'PUT',
        '/api/store/tree.alpha/env',
        body: utf8.encode(jsonEncode(<String, dynamic>{
          'etag': 'deadbeef',
          'value': 'x',
        })),
        headers: asPlugin('tree.alpha'),
        contentType: 'application/json',
      );
      expect(conflict.status, 409);

      final _Res updated = await client.send(
        'PUT',
        '/api/store/tree.alpha/env',
        body: utf8.encode(jsonEncode(<String, dynamic>{
          'etag': etag,
          'value': 'next',
        })),
        headers: asPlugin('tree.alpha'),
        contentType: 'application/json',
      );
      expect(updated.status, 200);
    });

    test('删除；不存在 ⇒ 404 可读', () async {
      await client.send(
        'PUT',
        '/api/store/tree.alpha/tmp',
        body: utf8.encode('12345'),
        headers: asPlugin('tree.alpha'),
        contentType: 'application/octet-stream',
      );
      final _Res deleted = await client.send(
        'DELETE',
        '/api/store/tree.alpha/tmp',
        headers: asPlugin('tree.alpha'),
      );
      expect(deleted.status, 200);
      expect(deleted.json['freed_bytes'], 5);

      final _Res getAfter = await client.send(
        'GET',
        '/api/store/tree.alpha/tmp',
        headers: asPlugin('tree.alpha'),
      );
      expect(getAfter.status, 404);
      expect(getAfter.detail, isNotEmpty);

      final _Res again = await client.send(
        'DELETE',
        '/api/store/tree.alpha/tmp',
        headers: asPlugin('tree.alpha'),
      );
      expect(again.status, 404);
      expect(again.detail, isNotEmpty);
    });

    test('分页：limit + cursor 走完所有键', () async {
      for (final String key in <String>['a', 'b', 'c', 'd', 'e']) {
        final _Res res = await client.send(
          'PUT',
          '/api/store/tree.alpha/$key',
          body: utf8.encode(key),
          headers: asPlugin('tree.alpha'),
          contentType: 'application/octet-stream',
        );
        expect(res.status, 200, reason: res.text);
      }
      final _Res page1 = await client.send(
        'GET',
        '/api/store/tree.alpha?limit=2',
        headers: asPlugin('tree.alpha'),
      );
      expect(
        (page1.json['keys'] as List<dynamic>)
            .map((dynamic row) => (row as Map<String, dynamic>)['key'])
            .toList(),
        <String>['a', 'b'],
      );
      expect(page1.json['next_cursor'], 'b');
      final List<dynamic> keys = page1.json['keys'] as List<dynamic>;
      final Map<String, dynamic> first = keys.first as Map<String, dynamic>;
      expect(first['size'], 1);
      expect(first['etag'], isA<String>());
      expect(first['updated_at'], isA<String>());

      final _Res page2 = await client.send(
        'GET',
        '/api/store/tree.alpha?limit=2&cursor=${page1.json['next_cursor']}',
        headers: asPlugin('tree.alpha'),
      );
      expect(
        (page2.json['keys'] as List<dynamic>)
            .map((dynamic row) => (row as Map<String, dynamic>)['key'])
            .toList(),
        <String>['c', 'd'],
      );
      expect(page2.json['next_cursor'], 'd');

      final _Res page3 = await client.send(
        'GET',
        '/api/store/tree.alpha?limit=2&cursor=d',
        headers: asPlugin('tree.alpha'),
      );
      expect(
        (page3.json['keys'] as List<dynamic>)
            .map((dynamic row) => (row as Map<String, dynamic>)['key'])
            .toList(),
        <String>['e'],
      );
      expect(page3.json['next_cursor'], isNull);
    });

    test('跨命名空间一律 403，且不泄露目标是否存在', () async {
      final List<_Res> responses = <_Res>[
        await client.send(
          'GET',
          '/api/store/tree.beta',
          headers: asPlugin('tree.alpha'),
        ),
        // 不存在的命名空间也给 403（而不是 404）。
        await client.send(
          'GET',
          '/api/store/tree.ghost',
          headers: asPlugin('tree.alpha'),
        ),
        await client.send(
          'GET',
          '/api/store/core',
          headers: asPlugin('tree.alpha'),
        ),
        await client.send(
          'GET',
          '/api/store/tree.alpha',
          headers: asPlugin('unknown.plugin'),
        ),
        await client.send(
          'GET',
          '/api/store/core',
          headers: asPlugin('core'),
        ),
      ];
      for (final _Res res in responses) {
        expect(res.status, 403, reason: res.text);
        expect(res.detail, isNotEmpty);
      }
    });

    test('主 token（无插件头）视为 core 命名空间', () async {
      final _Res put = await client.send(
        'PUT',
        '/api/store/core/host',
        body: utf8.encode('core-value'),
        contentType: 'application/octet-stream',
      );
      expect(put.status, 200, reason: put.text);
      final _Res get = await client.send('GET', '/api/store/core/host');
      expect(get.status, 200);
      expect(utf8.decode(get.bytes), 'core-value');
    });

    test('key 路径安全：分隔符 / .. / 盘符 / Windows 保留名 ⇒ 400', () async {
      final List<String> paths = <String>[
        '/api/store/tree.alpha/a%2Fb',
        '/api/store/tree.alpha/a%5Cb',
        // 裸 `..` 会被 Dart Uri 归一化掉（根本到不了处理器，仍是安全的 404）；
        // 这里用解码后仍含 `..` 的段验证 key 校验本身会回 400。
        '/api/store/tree.alpha/%2E%2E%5Cfoo',
        '/api/store/tree.alpha/C%3A%5Cx',
        '/api/store/tree.alpha/CON',
        '/api/store/tree.alpha/nul.txt',
      ];
      for (final String path in paths) {
        final _Res res = await client.send(
          'PUT',
          path,
          body: utf8.encode('x'),
          headers: asPlugin('tree.alpha'),
          contentType: 'application/octet-stream',
        );
        expect(res.status, 400, reason: '$path -> ${res.text}');
      }
    });

    test('非法命名空间 ⇒ 400', () async {
      final List<String> paths = <String>[
        // 同 key：裸 `..` 被 Uri 归一化后是安全 404，这里验证段内 `..` 会被 400。
        '/api/store/%2E%2E%5Cfoo',
        '/api/store/a%2Fb',
        '/api/store/CON',
      ];
      for (final String path in paths) {
        final _Res res = await client.send(
          'GET',
          path,
          headers: asPlugin('tree.alpha'),
        );
        expect(res.status, 400, reason: '$path -> ${res.text}');
      }
    });

    test('单值超过 1 MiB ⇒ 413 且不落盘', () async {
      final List<int> big = List<int>.filled(1024 * 1024 + 1, 0x41);
      final _Res res = await client.send(
        'PUT',
        '/api/store/tree.alpha/big',
        body: big,
        headers: asPlugin('tree.alpha'),
        contentType: 'application/octet-stream',
      );
      expect(res.status, 413);
      expect(res.detail, isNotEmpty);
      final _Res get = await client.send(
        'GET',
        '/api/store/tree.alpha/big',
        headers: asPlugin('tree.alpha'),
      );
      expect(get.status, 404);
    });

    test('引导会话 token 不在白名单 ⇒ 日志/存储都 403', () async {
      final String session = server.tokens.issueBootstrapSession();
      final _Res logs = await client.send(
        'GET',
        ApiPaths.logSources,
        token: session,
      );
      expect(logs.status, 403);
      final _Res store = await client.send(
        'GET',
        '/api/store/core/x',
        token: session,
      );
      expect(store.status, 403);
    });
  });

  group('PluginStore 单元（配额 / 路径编码）', () {
    test('命名空间配额超限 ⇒ 413 语义，且不做部分写入', () async {
      final TreePaths paths = TreePaths(temp.path);
      final PluginStore store = PluginStore(
        paths: paths,
        namespaceQuotaBytes: 10,
      );
      final StorePutResult first = await store.put(
        'core',
        'a',
        List<int>.filled(6, 1),
      );
      expect(first.ok, isTrue);
      final StorePutResult second = await store.put(
        'core',
        'b',
        List<int>.filled(6, 2),
      );
      expect(second.status, StorePutStatus.quotaExceeded);
      // 没有部分写入：b 完全不存在。
      expect(await store.read('core', 'b'), isNull);
      expect(await store.namespaceBytes('core'), 6);
    });

    test('单值上限与 key 编码可逆', () async {
      final PluginStore store = PluginStore(
        paths: TreePaths(temp.path),
        maxValueBytes: 4,
      );
      final StorePutResult tooLarge = await store.put(
        'core',
        'a',
        List<int>.filled(5, 0),
      );
      expect(tooLarge.status, StorePutStatus.tooLarge);

      final StorePutResult ok = await store.put(
        'core',
        '中文 key-1',
        utf8.encode('值'),
      );
      expect(ok.ok, isTrue);
      final StorePage page = await store.list('core');
      expect(page.entries.single.key, '中文 key-1');
      // 落盘文件名是 base64url，不含分隔符 / 原字符。
      final List<String> names = Directory(
        store.namespaceDir('core'),
      ).listSync().map((FileSystemEntity e) => p.basename(e.path)).toList();
      expect(names.single, startsWith('k_'));
      expect(names.single, isNot(contains('中文')));
    });
  });
}
