// 设置页「插件发布源」区：读设置、换顺序、填令牌、保存、测试连接的来回。
//
// 用一个假的"核心进程"（本机 HttpServer）验证：
// 1. 页面一打开就把核心的顺序 / 令牌是否已配读进来（明文令牌拿不到，只能显示状态）；
// 2. 换顺序 + 填令牌后点保存，请求体带**新顺序**与**本轮填的令牌**（空输入框不发，
//    即"留空保持原值"）；
// 3. 「测试连接」带**未保存的草稿值**，并把逐源结果（通/不通 + 版本 + 有无索引）
//    显示出来。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/api_service.dart';
import 'package:tree/ui/pages/settings_page.dart';
import 'package:tree_protocol/tree_protocol.dart';

class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  final List<({String method, String path, Map<String, dynamic> body})>
  requests = <({String method, String path, Map<String, dynamic> body})>[];

  List<String> order = <String>['gitee', 'github'];
  bool giteeTokenSet = false;
  bool githubTokenSet = false;

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
    final String raw = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> body = raw.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    requests.add((method: request.method, path: request.uri.path, body: body));

    if (request.uri.path == ApiPaths.settingsPluginReleaseSourcesTest &&
        request.method == 'POST') {
      final List<String> sent = (body['order'] as List<dynamic>? ?? order)
          .map((dynamic e) => e.toString())
          .toList();
      await _json(request, <String, dynamic>{
        'ok': true,
        'order': sent,
        'sources': <Map<String, dynamic>>[
          <String, dynamic>{
            'key': 'gitee',
            'name': 'Gitee',
            'ok': true,
            'usable': true,
            'tag': 'v0.2.0',
            'asset_count': 3,
            'has_index': true,
            'error': '',
          },
          <String, dynamic>{
            'key': 'github',
            'name': 'GitHub',
            'ok': false,
            'usable': false,
            'tag': '',
            'asset_count': 0,
            'has_index': false,
            'error': 'HTTP 403（限流）',
          },
        ],
      });
      return;
    }

    if (request.uri.path == ApiPaths.settingsPluginReleaseSources) {
      if (request.method == 'POST') {
        final Object? rawOrder = body['order'];
        if (rawOrder is List) {
          order = rawOrder.map((dynamic e) => e.toString()).toList();
        }
        if (body.containsKey('gitee_token')) {
          giteeTokenSet = (body['gitee_token'] as String? ?? '').isNotEmpty;
        }
        if (body.containsKey('github_token')) {
          githubTokenSet = (body['github_token'] as String? ?? '').isNotEmpty;
        }
      }
      await _json(request, <String, dynamic>{
        'order': order,
        'default_order': <String>['gitee', 'github'],
        'sources': <Map<String, dynamic>>[
          <String, dynamic>{
            'key': 'gitee',
            'name': 'Gitee',
            'repo': 'raditree/tree-plugins',
            'api_base': 'https://gitee.com/api/v5',
            'token_set': giteeTokenSet,
          },
          <String, dynamic>{
            'key': 'github',
            'name': 'GitHub',
            'repo': 'raditree/tree-plugins',
            'api_base': 'https://api.github.com',
            'token_set': githubTokenSet,
          },
        ],
        'download_ready': true,
        'applied': request.method == 'POST',
      });
      return;
    }

    request.response.statusCode = 404;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(<String, dynamic>{'detail': '未知接口'}));
    await request.response.close();
  }

  Future<void> _json(HttpRequest request, Map<String, dynamic> body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

/// 反复 pump 直到条件成立（真实 socket 事件只在 runAsync 里送达）。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  String reason = '条件',
}) async {
  for (int i = 0; i < 600; i++) {
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  fail('等待$reason 超时');
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

void main() {
  late _FakeCore core;

  setUp(() async {
    // flutter_test 默认拦掉全部 HTTP（一律 400），这里摘掉才能打本机假核心。
    HttpOverrides.global = null;
    core = await _FakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
  });

  tearDown(() async {
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
    await core.close();
  });

  testWidgets('读到顺序与令牌状态；换顺序 + 填令牌保存；测试连接显示逐源结果', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      // 设置页本身只是长列表（真实应用里由外层 Scaffold 承载）：保存成功的
      // SnackBar 需要祖先 Scaffold，这里补一个。
      const MaterialApp(
        home: Scaffold(body: SettingsPage(embedded: true)),
      ),
    );
    // 卡片在长列表下方（懒构建），先等首屏的 GET 回来，再滚过去。
    await _pumpUntil(
      tester,
      () => core.requests.any(
        (r) =>
            r.method == 'GET' &&
            r.path == ApiPaths.settingsPluginReleaseSources,
      ),
      reason: '发布源设置加载完成',
    );

    final Finder saveFinder = find.byKey(const Key('plugin-release-save'));
    final Finder giteeRadio = find.byKey(
      const Key('plugin-release-order-gitee-first'),
    );
    await _scrollTo(tester, giteeRadio);

    // 默认顺序是 Gitee 优先：直接保存，请求体应带 gitee → github
    await _scrollTo(tester, saveFinder);
    // GET 的响应落地后按钮才解禁（`_releaseSourcesLoaded`），先等它可点，
    // 否则 tap 落在 disabled 按钮上什么都不会发生。
    await _pumpUntil(
      tester,
      () => tester.widget<FilledButton>(saveFinder).onPressed != null,
      reason: '保存按钮可点',
    );
    await tester.ensureVisible(saveFinder);
    await tester.pump();
    await tester.tap(saveFinder);
    await _pumpUntil(
      tester,
      () => core.requests.any(
        (r) =>
            r.method == 'POST' &&
            r.path == ApiPaths.settingsPluginReleaseSources,
      ),
      reason: '保存请求',
    );
    final Map<String, dynamic> firstSave = core.requests
        .lastWhere(
          (r) =>
              r.method == 'POST' &&
              r.path == ApiPaths.settingsPluginReleaseSources,
        )
        .body;
    expect(firstSave['order'], <String>['gitee', 'github']);
    expect(
      firstSave.containsKey('gitee_token'),
      isFalse,
      reason: '空输入框 = 保持原值，不该把空串发过去（那会变成"清除"）',
    );

    // 换成 GitHub 优先
    // 先等第一次保存的**回包**真的落到 setState 上：回包会把界面顺序重置成
    // 服务端那一份，若它晚于下面那次单选到达，切换就被悄悄盖回去（并发/慢机必现）。
    await _pumpUntil(
      tester,
      () => tester.widget<FilledButton>(saveFinder).onPressed != null,
      reason: '第一次保存回包落地',
    );
    // 第一次保存的 SnackBar 浮在底部，会截走下面那次点击：先让它自己退场。
    await tester.pump(const Duration(seconds: 3));
    final Finder githubRadio = find.byKey(
      const Key('plugin-release-order-github-first'),
    );
    await _scrollTo(tester, githubRadio);
    await tester.ensureVisible(githubRadio);
    await tester.pump();
    await tester.tap(githubRadio);
    await tester.pump();
    expect(
      tester
          .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
          .groupValue,
      'github',
      reason: '单选没落到 GitHub 优先：后面的保存断言会跟着错',
    );

    // 填两个令牌
    final Finder giteeField = find.byKey(
      const Key('plugin-release-gitee-token'),
    );
    await _scrollTo(tester, giteeField);
    await tester.enterText(giteeField, 'gitee-secret');
    await tester.enterText(
      find.byKey(const Key('plugin-release-github-token')),
      'github-secret',
    );
    await tester.pump();

    await tester.ensureVisible(saveFinder);
    await tester.pump();
    // 第一次保存的回包落地前按钮是禁用的（_savingReleaseSources）：全量并发跑时
    // 回包可能晚于下一次点击，先等它解禁再点，否则这一击会落在 disabled 按钮上。
    await _pumpUntil(
      tester,
      () => tester.widget<FilledButton>(saveFinder).onPressed != null,
      reason: '第二次保存可用',
    );
    await tester.tap(saveFinder);
    await _pumpUntil(
      tester,
      () =>
          core.requests
              .where(
                (r) =>
                    r.method == 'POST' &&
                    r.path == ApiPaths.settingsPluginReleaseSources,
              )
              .length >=
          2,
      reason: '第二次保存',
    );
    final Map<String, dynamic> secondSave = core.requests
        .lastWhere(
          (r) =>
              r.method == 'POST' &&
              r.path == ApiPaths.settingsPluginReleaseSources,
        )
        .body;
    expect(secondSave['order'], <String>['github', 'gitee']);
    expect(secondSave['gitee_token'], 'gitee-secret');
    expect(secondSave['github_token'], 'github-secret');

    // 测试连接：带草稿值 + 显示逐源结果
    final Finder testFinder = find.byKey(const Key('plugin-release-test'));
    await tester.ensureVisible(testFinder);
    await tester.pump();
    await tester.tap(testFinder);
    await _pumpUntil(
      tester,
      () => core.requests.any(
        (r) =>
            r.method == 'POST' &&
            r.path == ApiPaths.settingsPluginReleaseSourcesTest,
      ),
      reason: '测试连接请求',
    );
    await tester.pump();
    final Finder giteeProbe = find.byKey(
      const Key('plugin-release-probe-gitee'),
    );
    // 请求到达假核心 ≠ 响应已画到界面上：等探测结果真的出现在树里再断言
    // （滚动策略在"还没内容"时会一路拖到底，最后报 Bad state: No element）。
    await _pumpUntil(
      tester,
      () => giteeProbe.evaluate().isNotEmpty,
      reason: '探测结果显示',
    );
    await tester.ensureVisible(giteeProbe);
    await tester.pump();
    expect(
      tester.widget<Text>(giteeProbe).data,
      contains('含索引'),
      reason: '通了要给出"通到哪一版、有没有索引"',
    );
    final Finder githubProbe = find.byKey(
      const Key('plugin-release-probe-github'),
    );
    expect(
      tester.widget<Text>(githubProbe).data,
      contains('不通'),
      reason: '没通要把原因显示出来',
    );
  });
}
