// 本地 zip 插件安装（`POST /api/plugin/install/local`）的用例。
//
// 锁住的口径（L-10 / D-1 / known-issues #38）：
// 1. 装的是**目录形态** `plugins/<id>/`（UI 插件带 `data/`、多个 dll，扁平放不下）；
// 2. `plugin.json` 是唯一的合同：缺它 / 缺 id / command 不在包内都当场拒，
//    且**一个文件都不落**；
// 3. zip 是外部输入：条目路径必须相对、无 `..`、无盘符；
// 4. 放置顺序与仓库通道同一条纪律：解到 `.part-<nonce>` → 过闸门 → 旧目录改名
//    占位 → 新目录原子改名；闸门拒绝或任一步失败时旧目录一字未动；
// 5. 端点复用仓库通道的后处理：落盘 `plugins.yaml` + 热应用，回包带 `install`
//    段（`source: local`）；没接下载器 ⇒ 503。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 极简 HTTP 客户端（带 token，只发 POST JSON）。
class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> post(String path, {Map<String, dynamic>? body}) async {
    final HttpClientRequest request = await _http.openUrl(
      'POST',
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_server.token}',
    );
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
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

  /// 可读错误文本（detail 字段）。
  String get detail => (json['detail'] ?? '').toString();
}

/// 拼一份 zip（条目名 → 字节）。[prefix] 模拟 `tar -C dir .` 产物的 `./` 前缀。
List<int> _zipBytes(Map<String, List<int>> files, {String prefix = ''}) {
  final Archive archive = Archive();
  for (final MapEntry<String, List<int>> entry in files.entries) {
    archive.add(
      ArchiveFile(
        '$prefix${entry.key}',
        entry.value.length,
        entry.value,
      ),
    );
  }
  return ZipEncoder().encode(archive);
}

/// 一条本地包清单（默认合法：命令指向包内的 `tree_local.exe`）。
Map<String, dynamic> _manifest({
  String id = 'local_demo',
  String name = '本地包插件',
  String version = '1.0.0',
  String command = 'tree_local.exe',
  String runtime = 'binary',
  Map<String, dynamic>? requires,
}) {
  final Map<String, dynamic> out = <String, dynamic>{
    'id': id,
    'name': name,
    'version': version,
    'runtime': runtime,
    'command': command,
    'args': const <String>[],
    'granularity': 'team',
    'scope': <String, dynamic>{},
  };
  if (requires != null) out['requires'] = requires;
  return out;
}

/// 把清单 + 文件打成一份 zip，返回路径。
String _writePluginZip(
  String dir,
  Map<String, dynamic> manifest, {
  Map<String, List<int>>? extra,
  String fileName = 'plugin.zip',
  String prefix = '',
}) {
  final List<int> bytes = _zipBytes(
    <String, List<int>>{
      'plugin.json': utf8.encode(jsonEncode(manifest)),
      ...?extra,
    },
    prefix: prefix,
  );
  final File file = File(p.join(dir, fileName));
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes, flush: true);
  return file.path;
}

void main() {
  late Directory temp;
  late String installDir;
  late String cacheDir;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_local_');
    installDir = p.join(temp.path, 'plugins');
    cacheDir = p.join(temp.path, 'plugins_release');
    Directory(installDir).createSync(recursive: true);
  });

  tearDown(() {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        sleep(const Duration(milliseconds: 50));
      }
    }
  });

  PluginDownloader downloader() => PluginDownloader(
    cacheDir: cacheDir,
    installDir: installDir,
    isWindows: true,
    nonce: () => 'nonce',
    fetcher: (Uri uri, {Map<String, String>? headers}) async =>
        PluginFetchResult.failure('本地安装不该联网：$uri'),
  );

  Future<String> allowSwap(String id) async => '';

  group('PluginDownloader.installFromZip', () {
    test('合法 zip ⇒ 落到 plugins/<id>/，条目 command 改成绝对路径', () async {
      final String zip = _writePluginZip(
        temp.path,
        _manifest(),
        extra: <String, List<int>>{
          'tree_local.exe': utf8.encode('placeholder'),
          'data/config.json': utf8.encode('{}'),
        },
      );
      final PluginInstallResult result = await downloader().installFromZip(
        zip,
        swapGate: allowSwap,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(result.source, kLocalSourceValue);
      expect(result.pluginId, 'local_demo');
      expect(result.version, '1.0.0');
      expect(result.swapped, isTrue);

      final String targetDir = p.join(installDir, 'local_demo');
      expect(Directory(targetDir).existsSync(), isTrue);
      expect(File(p.join(targetDir, 'tree_local.exe')).existsSync(), isTrue);
      expect(File(p.join(targetDir, 'data', 'config.json')).existsSync(), isTrue);
      expect(
        result.entry!['command'],
        p.join(targetDir, 'tree_local.exe'),
        reason: '条目写进 plugins.yaml 前必须指到落盘后的真路径',
      );
      expect(result.entry!['id'], 'local_demo');
      expect(result.entry![kRepoSourceKey], kLocalSourceValue);
    });

    test('zip 条目带 ./ 前缀（tar -C dir . 的产物）也能装', () async {
      final String zip = _writePluginZip(
        temp.path,
        _manifest(),
        extra: <String, List<int>>{
          'tree_local.exe': utf8.encode('placeholder'),
        },
        prefix: './',
      );
      final PluginInstallResult result = await downloader().installFromZip(
        zip,
        swapGate: allowSwap,
      );
      expect(result.ok, isTrue, reason: result.error);
    });

    test('缺 plugin.json ⇒ 拒，一个文件都不落', () async {
      final String zip = _writePluginZip(
        temp.path,
        _manifest(),
        extra: <String, List<int>>{'tree_local.exe': utf8.encode('x')},
      );
      final File file = File(zip);
      // 抹掉清单：只留文件
      file.writeAsBytesSync(
        _zipBytes(<String, List<int>>{'tree_local.exe': utf8.encode('x')}),
        flush: true,
      );
      final PluginInstallResult result = await downloader().installFromZip(
        zip,
        swapGate: allowSwap,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('plugin.json'));
      expect(
        Directory(p.join(installDir, 'local_demo')).existsSync(),
        isFalse,
        reason: '没有清单就无法判断 id / 版本 / 怎么拉起 ⇒ 不许猜',
      );
    });

    test('command 不在包内 ⇒ 拒（不装一个起不来的插件）', () async {
      final String zip = _writePluginZip(
        temp.path,
        _manifest(command: 'tree_missing.exe'),
        extra: <String, List<int>>{'tree_local.exe': utf8.encode('x')},
      );
      final PluginInstallResult result = await downloader().installFromZip(
        zip,
        swapGate: allowSwap,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('在 zip 里不存在'));
      expect(Directory(p.join(installDir, 'local_demo')).existsSync(), isFalse);
    });

    test('路径穿越（../）⇒ 拒，且不写任何文件', () async {
      final List<int> bytes = _zipBytes(<String, List<int>>{
        'plugin.json': utf8.encode(jsonEncode(_manifest())),
        '../evil.txt': utf8.encode('boom'),
        'tree_local.exe': utf8.encode('x'),
      });
      final String zip = p.join(temp.path, 'evil.zip');
      File(zip).writeAsBytesSync(bytes, flush: true);
      final PluginInstallResult result = await downloader().installFromZip(
        zip,
        swapGate: allowSwap,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('路径不安全'));
      expect(
        File(p.join(temp.path, 'evil.txt')).existsSync(),
        isFalse,
        reason: 'zip 是外部输入：佐罗式条目必须在解之前就被拒',
      );
    });

    test('闸门拒绝 ⇒ 旧目录一字未动，也不留 .part 残骸', () async {
      final String targetDir = p.join(installDir, 'local_demo');
      Directory(targetDir).createSync(recursive: true);
      File(p.join(targetDir, 'old.txt')).writeAsStringSync('old');
      final String zip = _writePluginZip(
        temp.path,
        _manifest(),
        extra: <String, List<int>>{'tree_local.exe': utf8.encode('x')},
      );
      final PluginInstallResult result = await downloader().installFromZip(
        zip,
        swapGate: (String id) async => '插件进程还没确认退出',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('还没确认退出'));
      expect(File(p.join(targetDir, 'old.txt')).existsSync(), isTrue);
      expect(File(p.join(targetDir, 'tree_local.exe')).existsSync(), isFalse);
      final List<String> leftovers = Directory(installDir)
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .where((String name) => name.contains('.part-'))
          .toList();
      expect(leftovers, isEmpty, reason: '失败路径不许留半装目录');
    });

    test('同 id 再装 ⇒ 整目录替换（旧文件清掉）', () async {
      final String targetDir = p.join(installDir, 'local_demo');
      Directory(targetDir).createSync(recursive: true);
      File(p.join(targetDir, 'old.txt')).writeAsStringSync('old');
      final String zip = _writePluginZip(
        temp.path,
        _manifest(),
        extra: <String, List<int>>{'tree_local.exe': utf8.encode('x')},
      );
      final PluginInstallResult result = await downloader().installFromZip(
        zip,
        swapGate: allowSwap,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(File(p.join(targetDir, 'old.txt')).existsSync(), isFalse);
      expect(File(p.join(targetDir, 'tree_local.exe')).existsSync(), isTrue);
    });

    test('zip 不存在 / 不是 zip ⇒ 可读原因', () async {
      final PluginInstallResult missing = await downloader().installFromZip(
        p.join(temp.path, 'nope.zip'),
        swapGate: allowSwap,
      );
      expect(missing.ok, isFalse);
      expect(missing.error, contains('不存在'));

      final String fake = p.join(temp.path, 'fake.zip');
      File(fake).writeAsStringSync('这不是 zip');
      final PluginInstallResult broken = await downloader().installFromZip(
        fake,
        swapGate: allowSwap,
      );
      expect(broken.ok, isFalse);
      // 解不开的字节既可能被 ZipDecoder 当场拒，也可能解出空包（缺清单）——
      // 两条都必须给可读原因，不能静默“装成功”。
      expect(
        broken.error,
        anyOf(contains('不是一个能解开的 zip'), contains('plugin.json')),
      );
    });

    test('卸载目标包含目录形态 plugins/<id>/，删除时整目录递归', () async {
      final String targetDir = p.join(installDir, 'local_demo');
      Directory(p.join(targetDir, 'data')).createSync(recursive: true);
      File(p.join(targetDir, 'tree_local.exe')).writeAsStringSync('x');
      File(p.join(targetDir, 'data', 'config.json')).writeAsStringSync('{}');
      final List<String> targets = downloader().uninstallTargets(
        'local_demo',
        <String, dynamic>{'command': p.join(targetDir, 'tree_local.exe')},
      );
      expect(targets, contains(p.normalize(targetDir)));
      final ({List<String> deleted, Map<String, String> failed}) removed =
          downloader().removeUninstallTargets(targets);
      expect(removed.failed, isEmpty);
      expect(removed.deleted, contains('local_demo'));
      expect(Directory(targetDir).existsSync(), isFalse);
    });
  });

  group('POST /api/plugin/install/local', () {
    late String configFile;
    late PluginBus bus;
    late CoreServer server;
    late _Client client;

    Future<void> serve({bool withDownloader = true}) async {
      final File file = File(configFile);
      file.createSync(recursive: true);
      file.writeAsStringSync('enabled: true\nplugins: []\n');
      bus = PluginBus(
        configFile: configFile,
        heartbeatInterval: const Duration(seconds: 30),
      );
      await bus.start();
      server = await CoreServer.start(
        pluginBus: bus,
        builtinPlugins: BuiltinPluginCatalog(
          scriptRoots: <String>[installDir],
          isWindows: true,
        ),
        pluginDownloader: withDownloader ? downloader() : null,
        enableHeartbeat: false,
      );
      client = _Client(server);
    }

    setUp(() {
      configFile = p.join(temp.path, 'config', 'plugins.yaml');
    });

    tearDown(() async {
      client.close();
      await server.close();
    });

    test('成功：目录落盘 + plugins.yaml 写入 + 回包带 install（source=local）', () async {
      await serve();
      final String zip = _writePluginZip(
        temp.path,
        _manifest(),
        extra: <String, List<int>>{'tree_local.exe': utf8.encode('x')},
      );
      final _Res res = await client.post(
        ApiPaths.pluginInstallLocal,
        body: <String, dynamic>{'zip_path': zip},
      );
      expect(res.status, 200, reason: res.detail);
      final Map<String, dynamic> install =
          res.json['install'] as Map<String, dynamic>;
      expect(install['ok'], isTrue);
      expect(install['source'], kLocalSourceValue);
      expect(install['plugin_id'], 'local_demo');
      final Map<String, dynamic> entry =
          res.json['config'] as Map<String, dynamic>;
      expect(entry['id'], 'local_demo');
      expect(
        entry['command'],
        p.join(installDir, 'local_demo', 'tree_local.exe'),
      );

      final Map<String, dynamic> doc = YamlCodec.decode(
        File(configFile).readAsStringSync(),
      );
      final List<Map<String, dynamic>> plugins = <Map<String, dynamic>>[
        for (final Object? item in (doc['plugins'] as List<dynamic>))
          Map<String, dynamic>.from(item as Map),
      ];
      expect(plugins, hasLength(1));
      expect(plugins.single['id'], 'local_demo');
      expect(plugins.single['source'], kLocalSourceValue);
      expect(
        Directory(p.join(installDir, 'local_demo')).existsSync(),
        isTrue,
      );
    });

    test('缺 zip_path ⇒ 400 + 可读原因', () async {
      await serve();
      final _Res res = await client.post(ApiPaths.pluginInstallLocal, body: <String, dynamic>{});
      expect(res.status, 400);
      expect(res.detail, contains('zip_path'));
    });

    test('包不合法 ⇒ 400 + 下载器给的原因（条目与磁盘都不动）', () async {
      await serve();
      final _Res res = await client.post(
        ApiPaths.pluginInstallLocal,
        body: <String, dynamic>{'zip_path': p.join(temp.path, 'nope.zip')},
      );
      expect(res.status, 400);
      expect(res.detail, contains('不存在'));
      expect(File(configFile).readAsStringSync(), contains('plugins: []'));
    });

    test('没接下载器 ⇒ 503 + 可读原因（不默默空转）', () async {
      await serve(withDownloader: false);
      final _Res res = await client.post(
        ApiPaths.pluginInstallLocal,
        body: <String, dynamic>{'zip_path': p.join(temp.path, 'x.zip')},
      );
      expect(res.status, 503);
      expect(res.detail, contains('没接发布仓库下载器'));
    });
  });
}
