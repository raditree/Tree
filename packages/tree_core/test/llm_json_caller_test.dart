// `llm.call` 的**返回形式**（2026-10-04 新增 text 覆盖）。
//
// 缺省 = 站点硬设 `response_format = {"type":"json_object"}`（语义与新增前逐字一致）；
// 显式 `responseFormat: 'text'` = **不发**该字段 —— 这是"复用对话前缀缓存"的机械保证。
//
// 为什么必须有这条：真机实测（`token.ai-galaxy.com/v1` 与 `api.deepseek.com` 两端点一致）
// 同一 492 token 前缀：plain 重发命中 **384/256**，**只加 `json_object` 就掉到 0**——
// 端点会为 JSON 模式改写提示词（同一批 messages 恒定 **+22 token**，且改写落在 messages
// 区域之前/其中），于是"逐字复用对话 messages+tools"的前缀整段不可复用。
// `tools` **没有**被丢弃（+270 token 在两种模式下都在），所以病根不是 tool。
// 证据与机制见 `docs/known-issues.md` #27。
import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 只做两件事：记下"这次请求体长什么样"、回一段可解析的 JSON 文本。
class _CapturingTransport implements LlmTransport {
  _CapturingTransport(this.reply);

  final String reply;
  LlmRequest? seen;

  @override
  Stream<LlmStreamEvent> stream(
    LlmRequest request, {
    bool Function()? isCancelled,
  }) async* {
    seen = request;
    yield LlmTextDelta(reply);
    yield const LlmUsageEvent(LlmUsage(promptTokens: 10, completionTokens: 5));
  }

  @override
  Future<void> close() async {}
}

void main() {
  final CoreModelConfig config = CoreModelConfig(
    modelId: 'demo',
    name: '演示',
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'sk-test',
    maxSeqlen: 64000,
  );

  const List<Map<String, dynamic>> oneUser = <Map<String, dynamic>>[
    <String, dynamic>{'role': 'user', 'content': '给我一个 JSON'},
  ];

  LlmJsonCaller callerOf(_CapturingTransport transport) => LlmJsonCaller(
    resolveModel: (String id) => id == 'demo' ? config : null,
    transportFactory: (CoreModelConfig _) => transport,
  );

  test('缺省：硬设 response_format={"type":"json_object"}（与改动前逐字一致）', () async {
    final _CapturingTransport transport = _CapturingTransport('{"ok":true}');
    await callerOf(transport).call(
      agentId: 'agt_1',
      modelId: 'demo',
      messages: oneUser,
    );
    final LlmRequest request = transport.seen!;
    expect(request.extra, <String, dynamic>{
      'response_format': <String, dynamic>{'type': 'json_object'},
    });
    expect(request.toWire()['response_format'], <String, dynamic>{
      'type': 'json_object',
    });
  });

  test('显式 text：请求体**不含** response_format（与对话那一轮同形态 ⇒ 前缀才可比）', () async {
    final _CapturingTransport transport = _CapturingTransport('{"ok":true}');
    await callerOf(transport).call(
      agentId: 'agt_1',
      modelId: 'demo',
      messages: oneUser,
      responseFormat: 'text',
    );
    final LlmRequest request = transport.seen!;
    expect(
      request.extra.containsKey('response_format'),
      isFalse,
      reason: 'text 形态必须一个字节都不多加，否则前缀与对话不一致、缓存全丢',
    );
    expect(request.toWire().containsKey('response_format'), isFalse);
  });

  test('text 也照旧把回包解析成 json（插件读 result.json 的契约不变）', () async {
    final _CapturingTransport transport = _CapturingTransport('{"ok":true}');
    final Map<String, dynamic> result = await callerOf(transport).call(
      agentId: 'agt_1',
      modelId: 'demo',
      messages: oneUser,
      responseFormat: 'text',
    );
    expect(result['ok'], isTrue, reason: result['error']?.toString());
    expect(result['json'], <String, dynamic>{'ok': true});
    expect(result['text'], '{"ok":true}');
  });
}
