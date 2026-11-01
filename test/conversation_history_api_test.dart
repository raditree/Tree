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

  /// 单页上限（对齐核心侧 `kHistoryPageMax` 的行为；0 = 不设上限）。
  int pageCap = 0;

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
    final String path = Uri.decodeComponent(request.uri.path);
    queries.add(request.uri.query);
    final Map<String, String> q = request.uri.queryParameters;
    // 详情端点：GET /api/conversations/{agentId}/messages/{messageId}
    // —— 回扁平单条**全字段** JSON（显示/详细两分的"详细"侧）。
    final Match? detail =
        RegExp(r'^/api/conversations/[^/]+/messages/(.+)$').firstMatch(path);
    if (detail != null) {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(<String, dynamic>{
        'id': detail.group(1),
        'role': 'agent',
        'kind': 'tool',
        'content': '',
        'timestamp': DateTime(2026, 1, 1).millisecondsSinceEpoch,
        'tool_name': 'read',
        'tool_arguments': <String, dynamic>{'file_path': 'lib/main.dart'},
        'tool_result': '完整结果正文\n第二行',
        'usage': <String, dynamic>{'input_tokens': 1234},
      }));
      await request.response.close();
      return;
    }
    final int limit = int.tryParse(q['limit'] ?? '') ?? 0;
    final int? from = int.tryParse(q['from'] ?? '');
    final String at = (q['at'] ?? '').trim();
    final String before = (q['before'] ?? '').trim();
    final int cap = pageCap > 0 && limit > pageCap ? pageCap : limit;
    int start;
    if (at.isNotEmpty) {
      start = 500;
    } else if (from != null) {
      start = from;
    } else if (before.isNotEmpty) {
      // 游标分页：回 before 那条之前的**至多一页**（与核心同口径）
      final int idx = int.tryParse(before.replaceFirst('m', '')) ?? 0;
      start = (idx - cap).clamp(0, total);
    } else {
      start = limit > 0 ? (total - cap).clamp(0, total) : 0;
    }
    final int upper = before.isNotEmpty
        ? (int.tryParse(before.replaceFirst('m', '')) ?? 0)
        : total;
    final int count =
        ((limit > 0 ? cap : 10).clamp(0, (upper - start).clamp(0, upper)));
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

  // ---- F3 显示/详细两分（规格 §3.1.3 / §3.1.4）----

  test('首屏显示行整段：total ≤ 上限时一发 limit=9999 拉满，不翻页', () async {
    final HistoryPage page = await ApiService.getConversationDisplayRows('a1');
    expect(core.queries.single, contains('limit=9999'));
    expect(core.queries.single, isNot(contains('from=')));
    expect(page.offset, 0);
    expect(page.hasMore, isFalse, reason: '1000 条装得进缓存上限 ⇒ 没有更早段');
    expect(page.messages, hasLength(1000));
    expect(page.total, 1000);
  });

  test('首屏显示行整段：核心有单页上限时用 before=<最旧 id> 逐页补拉到 offset=0', () async {
    core.total = 500;
    core.pageCap = 200; // 模拟核心 kHistoryPageMax：单页封顶，UI 侧逐页往前补
    final HistoryPage page = await ApiService.getConversationDisplayRows('a1');
    expect(core.queries, hasLength(3), reason: '末尾 200 + 200 + 100');
    expect(core.queries.first, contains('limit=9999'));
    expect(core.queries[1], contains('before=m300'));
    expect(core.queries[2], contains('before=m100'));
    expect(page.offset, 0);
    expect(page.hasMore, isFalse);
    expect(page.messages, hasLength(500));
    expect(page.messages.first['id'], 'm0');
    expect(page.messages.last['id'], 'm499');
  });

  test('首屏显示行整段：超过上限只留最近 9999，更早段留给窗口机制（hasMore）', () async {
    core.total = 12000;
    final HistoryPage page = await ApiService.getConversationDisplayRows('a1');
    expect(core.queries.single, contains('limit=9999'),
        reason: '一发就攒满 9999 ⇒ 补拉循环不触发');
    expect(page.messages, hasLength(9999));
    expect(page.offset, 2001);
    expect(page.hasMore, isTrue, reason: '更早段存在：由 gapsFor 窗口补拉');
  });

  test('详情端点：getMessageDetail 按 id 取单条全字段 JSON', () async {
    final Map<String, dynamic> detail =
        await ApiService.getMessageDetail('a1', 'm42');
    expect(core.queries.single, contains('session_id=session_default'));
    expect(detail['id'], 'm42');
    expect(detail['tool_arguments'], isA<Map<String, dynamic>>(),
        reason: '显示行不带参数表，详情必须带');
    expect(detail['tool_result'], contains('完整结果正文'));
    expect(detail['usage'], isNotNull);
  });
}
