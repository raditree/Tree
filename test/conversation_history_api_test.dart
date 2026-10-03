// 历史分页的**前端请求形状**（用户 2026-10-04：窗口化懒加载 / 滑到哪加载哪 /
// 回到底部直接重载末尾一段）。
//
// 用一个假的"核心进程"（本机 HttpServer）钉住前端发出去的查询串与解析回来的
// offset：核心侧的行为在 packages/tree_core/test/conversation_history_paging_test.dart，
// 这里只管"前端问得对不对、答得接不接得住"。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/api_service.dart';

class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  /// 收到过的查询串（按到达顺序）。
  final List<String> queries = <String>[];

  /// 会话一共有多少条。
  int total = 1000;

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
    queries.add(request.uri.query);
    final Map<String, String> q = request.uri.queryParameters;
    final int limit = int.tryParse(q['limit'] ?? '') ?? 0;
    final int? from = int.tryParse(q['from'] ?? '');
    final String at = (q['at'] ?? '').trim();
    final String before = (q['before'] ?? '').trim();
    int start;
    if (at.isNotEmpty) {
      start = 500;
    } else if (from != null) {
      start = from;
    } else if (before.isNotEmpty) {
      start = 200;
    } else {
      start = limit > 0 ? total - limit : 0;
    }
    final int count = limit > 0 ? limit : 10;
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(<String, dynamic>{
      'agent_id': 'a1',
      'session_id': 'session_default',
      'messages': <Map<String, dynamic>>[
        for (int i = 0; i < count; i++)
          <String, dynamic>{
            'id': 'm${start + i}',
            'role': 'agent',
            'content': '第 ${start + i} 条',
            'timestamp': DateTime(2026, 1, 1).millisecondsSinceEpoch,
          },
      ],
      'total': total,
      'offset': start,
      'has_more': start > 0,
    }));
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

  test('拉末尾一段：只带 limit，offset/total 如实解析回来（首屏与"回到底部"用）',
      () async {
    final HistoryPage page = await ApiService.getConversationHistoryPage(
      'a1',
      limit: 200,
    );
    expect(core.queries.single, contains('limit=200'));
    expect(core.queries.single, isNot(contains('from=')));
    expect(page.total, 1000);
    expect(page.offset, 800, reason: '末尾一页的第一条下标 = total - limit');
    expect(page.messages, hasLength(200));
    expect(page.messages.first['id'], 'm800');
    expect(page.hasMore, isTrue);
  });

  test('滑到哪加载哪：from=<下标>，offset 就是那一段的起点', () async {
    final HistoryPage page = await ApiService.getConversationHistoryPage(
      'a1',
      from: 300,
      limit: 200,
    );
    expect(core.queries.single, contains('from=300'));
    expect(page.offset, 300);
    expect(page.messages.first['id'], 'm300');
  });

  test('定位不在窗口里的消息：at=<id>', () async {
    final HistoryPage page = await ApiService.getConversationHistoryPage(
      'a1',
      atId: 'm500',
      limit: 200,
    );
    expect(core.queries.single, contains('at=m500'));
    expect(page.offset, 500);
    expect(
      page.messages.map((Map<String, dynamic> m) => m['id']),
      contains('m500'),
    );
  });

  test('往回翻页：before=<id>（老口径还在，别的调用方还在用）', () async {
    final HistoryPage page = await ApiService.getConversationHistoryPage(
      'a1',
      beforeId: 'm400',
      limit: 200,
    );
    expect(core.queries.single, contains('before=m400'));
    expect(page.offset, 200);
  });

  test('不带 limit：老行为（整份，offset=0，查询串里不出现 limit）', () async {
    final HistoryPage page = await ApiService.getConversationHistoryPage('a1');
    expect(core.queries.single, isNot(contains('limit=')));
    expect(page.offset, 0);
    expect(page.total, 1000);
  });
}
