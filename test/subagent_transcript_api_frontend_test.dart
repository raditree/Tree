// 临时员工**工作数据复查通路**的前端请求形状（用户 2026-10-11：「subagent 的工作
// 数据不落盘，导致非常不稳定」——断言：保持跨会话不保留，但临时员工的工作数据落盘，
// 方便后期复查）。
//
// 核心侧行为在 packages/tree_core/test/subagent_transcript_api_test.dart；这里只管
// "前端问得对不对（路径 + session_id 查询串）、答得接不接得住（解析成 ChatMessage，
// subagent 标记与工具字段都在）"。用本机假核心钉形状，与 conversation_history_api_test.dart
// 同一范式。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/api_service.dart';
import 'package:tree/ui/models/message.dart';

class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  /// 收到过的请求路径（按到达顺序）。
  final List<String> paths = <String>[];
  final List<String> queries = <String>[];

  /// 下一次响应（假核心按它回包）。
  int status = 200;
  Map<String, dynamic> body = <String, dynamic>{};

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
    paths.add(request.uri.path);
    queries.add(request.uri.query);
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

void main() {
  late _FakeCore core;

  setUp(() async {
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

  test('请求形状：路径带 subagent id，会话作为查询串（复查读的是那一会话的落盘）',
      () async {
    core.body = <String, dynamic>{
      'agent_id': 'agt_1',
      'subagent_id': 'sub_a',
      'session_id': 'ses_9',
      'total': 0,
      'messages': <Map<String, dynamic>>[],
    };
    await ApiService.getSubagentTranscript('agt_1', 'sub_a', sessionId: 'ses_9');
    expect(
      core.paths.single,
      '/api/agents/agt_1/subagents/sub_a/transcript',
      reason: '端点路径 = 名册端点的同族（{agentId}/subagents/{subagentId}/transcript）',
    );
    expect(core.queries.single, contains('session_id=ses_9'));
  });

  test('缺省会话：不带 session_id 也要能问（核心自己落默认会话，与邻居端点同口径）',
      () async {
    core.body = <String, dynamic>{'messages': <Map<String, dynamic>>[]};
    await ApiService.getSubagentTranscript('agt_1', 'sub_a');
    expect(core.queries.single, isEmpty);
  });

  test('响应解析：任务/正文/工具卡片三类都还原成带标记的 ChatMessage', () async {
    final int t = DateTime(2026, 10, 11).millisecondsSinceEpoch;
    core.body = <String, dynamic>{
      'agent_id': 'agt_1',
      'subagent_id': 'sub_a',
      'session_id': 'session_default',
      'total': 3,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'task1',
          'role': 'agent',
          'content': '把 a.txt 改成 b',
          'kind': 'subagent_task',
          'timestamp': t,
          'subagent_id': 'sub_a',
          'subagent_name': '甲',
          'subagent_level': 1,
        },
        <String, dynamic>{
          'id': 'text1',
          'role': 'agent',
          'content': '我先看一眼文件',
          'kind': 'text',
          'timestamp': t + 1,
          'subagent_id': 'sub_a',
          'subagent_name': '甲',
        },
        <String, dynamic>{
          'id': 'tool1',
          'role': 'agent',
          'content': '',
          'kind': 'tool',
          'timestamp': t + 2,
          'tool_name': 'read',
          'tool_result': 'a.txt 的内容…',
          'subagent_id': 'sub_a',
        },
      ],
    };
    final List<ChatMessage> transcript = await ApiService.getSubagentTranscript(
      'agt_1',
      'sub_a',
    );
    expect(transcript.map((ChatMessage m) => m.id).toList(),
        <String>['task1', 'text1', 'tool1']);
    expect(transcript.every((ChatMessage m) => m.isSubagentMessage), isTrue,
        reason: '复查回来的每条都必须仍带归属标记（换会话/切视角的判据）');
    expect(transcript[1].subagentName, '甲');
    expect(transcript[2].kind, 'tool');
    expect(transcript[2].toolName, 'read');
    expect(transcript[2].toolResult, contains('a.txt'));
  });

  test('404（跨会话 / 未知 id）抛中文可读异常——调用方兜底显示，不静默回空', () async {
    core.status = 404;
    core.body = <String, dynamic>{
      'detail': '临时员工「甲」属于会话 ses_a，不在这个会话（ses_b）里——跨会话不保留是硬不变量。',
    };
    await expectLater(
      ApiService.getSubagentTranscript('agt_1', 'sub_a', sessionId: 'ses_b'),
      throwsA(predicate((Object? e) =>
          e.toString().contains('会话') && e.toString().contains('跨会话'))),
      reason: 'detail 原样抛出，调用方兜底显示，不静默回空表',
    );
  });
}
