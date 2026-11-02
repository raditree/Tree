// 插件发布源设置（顺序 + 令牌 + 连通性探测）：设置层、端点、下载器热应用。
//
// 钉住的口径：
// 1. 顺序与令牌落 settings.yaml（`plugin_release_order` / `gitee_token` /
//    `github_token`），未知键仍原样保留；
// 2. 令牌**只进不出**：端点响应只有 `token_set`，明文永不出现在回包里；
// 3. 保存后立即热应用到运行中的下载器（不必重启核心）；
// 4. 「测试连接」不写缓存：逐源回答"通没通、通到哪一版、有没有索引"。
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

void main() {
  group('CoreSettings 发布源', () {
    test('默认不配顺序（交给核心按环境变量 → 默认 Gitee → GitHub 解析）', () {
      final CoreSettings settings = CoreSettings();
      expect(settings.pluginReleaseOrder, isEmpty);
      expect(settings.giteeToken, '');
      expect(settings.githubToken, '');
    });

    test('applyMap / toMap 往返：顺序兼容列表与字符串，令牌写回', () {
      final CoreSettings settings = CoreSettings()
        ..applyMap(<String, dynamic>{
          'plugin_release_order': <String>['GitHub', 'gitee'],
          'gitee_token': ' g1 ',
          'github_token': 'gh1',
          'my_custom_key': 'x',
        });
      expect(settings.pluginReleaseOrder, <String>['github', 'gitee']);
      expect(settings.giteeToken, 'g1', reason: '两端空白要去掉');
      expect(settings.githubToken, 'gh1');
      expect(settings.extra.keys, contains('my_custom_key'));
      expect(
        settings.extra.keys,
        isNot(contains('plugin_release_order')),
        reason: '已知键不该留在 extra（否则会写两份）',
      );

      final Map<String, dynamic> out = settings.toMap();
      expect(out['plugin_release_order'], <String>['github', 'gitee']);
      expect(out['gitee_token'], 'g1');
      expect(out['github_token'], 'gh1');

      final CoreSettings again = CoreSettings()..applyMap(out);
      expect(again.toMap(), out);

      // 手写 yaml 的字符串形态也能读
      expect(
        (CoreSettings()..applyMap(<String, dynamic>{
              'plugin_release_order': 'github, gitee github',
            }))
            .pluginReleaseOrder,
        <String>['github', 'gitee'],
        reason: '逗号/空格分隔、重复去重',
      );
    });

    test('空令牌 = 清除（不能变成"保留那个看不见的旧值"）', () {
      final CoreSettings settings = CoreSettings()
        ..setPluginReleaseSettings(giteeToken: 'g1');
      expect(settings.giteeToken, 'g1');
      settings.setPluginReleaseSettings(giteeToken: '');
      expect(settings.giteeToken, '');
      // 不传该字段 = 保持原值
      settings.setPluginReleaseSettings(order: <String>['github', 'gitee']);
      expect(settings.giteeToken, '');
      expect(settings.pluginReleaseOrder, <String>['github', 'gitee']);
    });

    test('写入通知 settings.yaml', () {
      final _RecordingSink sink = _RecordingSink();
      final CoreSettings settings = CoreSettings()..sink = sink;
      settings.setPluginReleaseSettings(
        order: <String>['github', 'gitee'],
        giteeToken: 'g1',
      );
      expect(sink.settingsSaved, 1);
    });
  });

  group('发布源端点', () {
    late Directory root;
    late PluginDownloader downloader;
    late CoreServer server;
    late _Client client;

    // 假的发布仓库：Gitee 通、GitHub 403（模拟限流）。
    Future<PluginFetchResult> fetch(Uri url, {Map<String, String>? headers}) async {
      if (url.host == 'gitee.com') {
        return PluginFetchResult(
          statusCode: 200,
          bytes: utf8.encode(
            jsonEncode(<String, dynamic>{
              'tag_name': 'v0.2.0',
              'assets': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': kPluginIndexAsset,
                  'browser_download_url':
                      'https://gitee.com/raditree/tree-plugins/releases/download/v0.2.0/$kPluginIndexAsset',
                  'size': 10,
                },
              ],
            }),
          ),
        );
      }
      return const PluginFetchResult(statusCode: 403, error: 'HTTP 403');
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp('tree_release_settings_');
      downloader = PluginDownloader(
        cacheDir: root.path,
        installDir: root.path,
        fetcher: fetch,
      );
      server = await CoreServer.start(
        enableHeartbeat: false,
        pluginDownloader: downloader,
        settings: CoreSettings(),
      );
      client = _Client(server);
    });

    tearDown(() async {
      client.close();
      await server.close();
    });

    test('GET：默认顺序 + 令牌只给 token_set（无明文）', () async {
      final _Res res = await client.send(
        'GET',
        ApiPaths.settingsPluginReleaseSources,
      );
      expect(res.status, 200);
      expect(res.json['order'], <String>['gitee', 'github']);
      expect(res.json['default_order'], <String>['gitee', 'github']);
      expect(res.json['download_ready'], isTrue);
      final List<dynamic> sources = res.json['sources'] as List<dynamic>;
      expect(sources.length, 2);
      for (final dynamic raw in sources) {
        final Map<String, dynamic> source = raw as Map<String, dynamic>;
        expect(source['key'], anyOf('gitee', 'github'));
        expect(source['token_set'], isFalse);
        expect(source.containsKey('token'), isFalse, reason: '明文令牌永不出现在回包');
      }
    });

    test('POST：换顺序 + 存令牌，立即热应用，回包不含明文', () async {
      final _Res res = await client.send(
        'POST',
        ApiPaths.settingsPluginReleaseSources,
        body: <String, dynamic>{
          'order': <String>['github', 'gitee'],
          'gitee_token': 'gitee-secret',
          'github_token': 'github-secret',
        },
      );
      expect(res.status, 200);
      expect(res.json['order'], <String>['github', 'gitee']);
      expect(res.json['applied'], isTrue);
      expect(res.json.toString(), isNot(contains('gitee-secret')));
      expect(res.json.toString(), isNot(contains('github-secret')));

      expect(server.settings.giteeToken, 'gitee-secret');
      expect(server.settings.githubToken, 'github-secret');
      final List<PluginReleaseSource> applied = downloader.sources;
      expect(applied.map((PluginReleaseSource s) => s.key), <String>[
        'github',
        'gitee',
      ]);
      expect(
        applied[1].token,
        'gitee-secret',
        reason: '保存后立即套到运行中的下载器上（不用重启核心）',
      );
    });

    test('POST：认不出的顺序回 400，设置一字未动', () async {
      final _Res res = await client.send(
        'POST',
        ApiPaths.settingsPluginReleaseSources,
        body: <String, dynamic>{
          'order': <String>['foo', 'bar'],
        },
      );
      expect(res.status, 400);
      expect(res.json['detail'].toString(), contains('gitee'));
      expect(server.settings.pluginReleaseOrder, isEmpty);
    });

    test('测试连接：逐源给"通/不通 + 版本 + 有没有索引"，不落缓存', () async {
      final _Res res = await client.send(
        'POST',
        ApiPaths.settingsPluginReleaseSourcesTest,
        body: <String, dynamic>{'order': <String>['gitee', 'github']},
      );
      expect(res.status, 200);
      expect(res.json['ok'], isTrue, reason: 'Gitee 这一版带索引 ⇒ 至少一个源可用');
      final List<dynamic> sources = res.json['sources'] as List<dynamic>;
      expect(sources.length, 2);

      final Map<String, dynamic> gitee = sources[0] as Map<String, dynamic>;
      expect(gitee['key'], 'gitee');
      expect(gitee['ok'], isTrue);
      expect(gitee['usable'], isTrue);
      expect(gitee['tag'], 'v0.2.0');
      expect(gitee['has_index'], isTrue);

      final Map<String, dynamic> github = sources[1] as Map<String, dynamic>;
      expect(github['key'], 'github');
      expect(github['ok'], isFalse);
      expect(github['error'].toString(), contains('403'));

      expect(
        File(downloader.indexPath).existsSync(),
        isFalse,
        reason: '探测是只读的：不许顺手写缓存',
      );
    });

    test('未接入下载器时测试连接回可读 503', () async {
      final CoreServer bare = await CoreServer.start(enableHeartbeat: false);
      addTearDown(bare.close);
      final _Client bareClient = _Client(bare);
      addTearDown(bareClient.close);
      final _Res res = await bareClient.send(
        'POST',
        ApiPaths.settingsPluginReleaseSourcesTest,
        body: <String, dynamic>{},
      );
      expect(res.status, 503);
      expect(res.json['detail'].toString(), contains('发布仓库'));
    });
  });

  group('PluginDownloader.configureSources', () {
    test('空清单回落默认（Gitee → GitHub），非空时按给定顺序', () {
      final PluginDownloader downloader = PluginDownloader(
        cacheDir: 'C:/tmp/cache',
        installDir: 'C:/tmp/plugins',
      );
      downloader.configureSources(<PluginReleaseSource>[]);
      expect(downloader.sources.map((PluginReleaseSource s) => s.key), <String>[
        'gitee',
        'github',
      ]);
      downloader.configureSources(<PluginReleaseSource>[
        const PluginReleaseSource(
          name: 'GitHub',
          repo: kTreePluginsRepo,
          apiBase: kGitHubApiBase,
        ),
      ]);
      expect(downloader.sources.single.key, 'github');
    });
  });
}

/// 记录落盘调用的假 sink。
class _RecordingSink implements CoreSettingsSink {
  int settingsSaved = 0;

  @override
  void saveSettings(CoreSettings settings) => settingsSaved++;

  @override
  void saveModel(CoreModelConfig model) {}

  @override
  void deleteModel(String modelId) {}

  @override
  Future<void> flush() async {}
}

/// 极简 HTTP 客户端（与心跳用例里的同名实现等价）。
class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse(_server.handshake.httpBaseUrl + path),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_server.token}',
    );
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
