import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  group('SseParser', () {
    test('标准事件：data 行 + 空行结束', () {
      final SseParser parser = SseParser();
      expect(parser.accept('data: {"a":1}'), isNull);
      expect(parser.accept(''), '{"a":1}');
      expect(parser.hasPending, isFalse);
    });

    test('多行 data 用换行连接；注释与非 data 字段被忽略', () {
      final SseParser parser = SseParser();
      expect(parser.accept(': keep-alive'), isNull); // 心跳注释
      expect(parser.accept('event: message'), isNull);
      expect(parser.accept('id: 42'), isNull);
      expect(parser.accept('data: line1'), isNull);
      expect(parser.accept('data: line2'), isNull);
      expect(parser.accept(''), 'line1\nline2');
    });

    test('只去掉值前的第一个空格，其余空格保留（JSON 缩进不能吃）', () {
      final SseParser parser = SseParser();
      expect(parser.accept('data:  {"x": 1}'), isNull);
      expect(parser.accept(''), ' {"x": 1}');
    });

    test('无冒号的 data 视为空值行；多个事件依次返回', () {
      final SseParser parser = SseParser();
      parser.accept('data');
      expect(parser.accept(''), '');
      parser.accept('data: a');
      expect(parser.accept(''), 'a');
    });

    test('flush 取回残留（端点省掉末尾空行）', () {
      final SseParser parser = SseParser();
      expect(parser.accept('data: [DONE]'), isNull);
      expect(parser.hasPending, isTrue);
      expect(parser.flush(), '[DONE]');
      expect(parser.flush(), isNull);
    });

    test('空行不产生空事件', () {
      final SseParser parser = SseParser();
      expect(parser.accept(''), isNull);
      expect(parser.accept(''), isNull);
    });
  });

  group('OpenAiCodec 端点拼接', () {
    test('常见 base_url 形态都拼对', () {
      expect(
        OpenAiCodec.endpointFor('https://api.example.com/v1'),
        'https://api.example.com/v1/chat/completions',
      );
      expect(
        OpenAiCodec.endpointFor('https://api.example.com/v1/'),
        'https://api.example.com/v1/chat/completions',
      );
      expect(
        OpenAiCodec.endpointFor('https://api.example.com'),
        'https://api.example.com/chat/completions',
      );
      expect(
        OpenAiCodec.endpointFor('https://api.example.com/v1/chat/completions'),
        'https://api.example.com/v1/chat/completions',
      );
      expect(
        OpenAiCodec.endpointFor('  http://127.0.0.1:8000/v1  '),
        'http://127.0.0.1:8000/v1/chat/completions',
      );
    });
  });

  group('OpenAiCodec 请求体', () {
    test('消息/工具/参数/思考强度/usage 选项', () {
      final Map<String, dynamic> body = OpenAiCodec.requestBody(
        const LlmRequest(
          model: 'demo',
          messages: <LlmMessage>[
            LlmMessage.system('你是助手'),
            LlmMessage.user('你好'),
          ],
          tools: <LlmToolSpec>[
            LlmToolSpec(name: 'read_file', description: '读文件'),
          ],
          maxOutputTokens: 512,
          reasoningEffort: 'high',
          temperature: 0.3,
        ),
        stream: true,
      );
      expect(body['model'], 'demo');
      expect(body['stream'], isTrue);
      expect(body['stream_options'], <String, dynamic>{'include_usage': true});
      expect(body['max_tokens'], 512);
      expect(body['reasoning_effort'], 'high');
      expect(body['temperature'], 0.3);
      final List<dynamic> messages = body['messages'] as List<dynamic>;
      expect((messages.first as Map<String, dynamic>)['role'], 'system');
      expect((messages.first as Map<String, dynamic>)['content'], '你是助手');
      final Map<String, dynamic> tool =
          ((body['tools'] as List<dynamic>).first as Map<String, dynamic>);
      expect(tool['type'], 'function');
      expect((tool['function'] as Map<String, dynamic>)['name'], 'read_file');
    });

    test('空的可选字段不下发（避免端点拒绝 null）', () {
      final Map<String, dynamic> body = OpenAiCodec.requestBody(
        const LlmRequest(
          model: 'm',
          messages: <LlmMessage>[LlmMessage.user('x')],
        ),
        stream: true,
      );
      expect(body.containsKey('tools'), isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body.containsKey('temperature'), isFalse);
    });

    test('内容块（图像 file_id 引用）：content 输出成数组，正文块在前', () {
      final Map<String, dynamic> body = OpenAiCodec.requestBody(
        LlmRequest(
          model: 'deepseek-flash',
          messages: <LlmMessage>[
            LlmMessage(
              role: LlmRole.user,
              content: '这张图片里有什么？',
              contentParts: const <LlmContentPart>[
                LlmContentPart.file('file-api-xxxx'),
              ],
            ),
            // 没有内容块的消息必须仍是**字符串**（非视觉路径逐字不变）
            LlmMessage.user('普通消息'),
          ],
        ),
        stream: true,
      );
      final List<dynamic> messages = body['messages'] as List<dynamic>;
      expect(
        (messages[0] as Map<String, dynamic>)['content'],
        <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': '这张图片里有什么？'},
          // **file_id 是块的同级字段**（不再套一层 file 对象）——实测真端点：
          // 嵌套形状一律 400「file must have a file_id or file_data」，
          // 扁平形状 200 且模型真的看得见图。
          <String, dynamic>{'type': 'file', 'file_id': 'file-api-xxxx'},
        ],
      );
      expect((messages[1] as Map<String, dynamic>)['content'], '普通消息');
    });

    test('file 块**不得**套一层 file 对象（真端点会 400，别改回去）', () {
      // 这条是"防回潮"：OpenAI 那套 {"type":"file","file":{"file_id":…}} 看起来更
      // 眼熟，很容易被误"修正"回去。真端点实测（2026-10-01，真图逐形状探针）：
      //   {"type":"file","file":{"file_id":…}} ⇒ 400 file must have a file_id or file_data
      //   {"type":"file","file_id":…}         ⇒ 200，模型真的看得见图
      final Map<String, dynamic> wire =
          const LlmContentPart.file('file-api-1').toWire();
      expect(wire['file_id'], 'file-api-1');
      expect(
        wire.containsKey('file'),
        isFalse,
        reason: '嵌套 file 对象是错的形状：端点会说它"没有 file_id"，整轮请求 400',
      );
      expect(wire.keys.toSet(), <String>{'type', 'file_id'});
    });

    test('内容块：正文为空时不塞空文本块；文本块构造同形', () {
      const LlmMessage onlyFile = LlmMessage(
        role: LlmRole.user,
        content: '',
        contentParts: <LlmContentPart>[LlmContentPart.file('f1')],
      );
      expect(onlyFile.toWire()['content'], <Map<String, dynamic>>[
        <String, dynamic>{'type': 'file', 'file_id': 'f1'},
      ]);
      // system 与 user 共用同一条线形态（正文块在前）
      const LlmMessage withText = LlmMessage(
        role: LlmRole.system,
        content: '你是助手',
        contentParts: <LlmContentPart>[LlmContentPart.text('附加')],
      );
      expect(withText.toWire()['content'], <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': '你是助手'},
        <String, dynamic>{'type': 'text', 'text': '附加'},
      ]);
    });

    test('assistant 工具调用轮与 tool 结果的消息形态', () {
      final LlmMessage assistant = LlmMessage(
        role: LlmRole.assistant,
        content: '',
        toolCalls: const <LlmToolCall>[
          LlmToolCall(
            id: 'call_1',
            name: 'read_file',
            arguments: '{"path":"a"}',
          ),
        ],
      );
      final Map<String, dynamic> wire = assistant.toWire();
      expect(wire['content'], isNull);
      expect((wire['tool_calls'] as List<dynamic>).length, 1);
      final Map<String, dynamic> tool = LlmMessage.toolResult(
        content: '内容',
        toolCallId: 'call_1',
      ).toWire();
      expect(tool['role'], 'tool');
      expect(tool['tool_call_id'], 'call_1');
      expect(tool['content'], '内容');
    });
  });

  group('OpenAiCodec 分片解码', () {
    List<LlmStreamEvent> decode(Map<String, dynamic> chunk) =>
        OpenAiCodec.decodeChunk(jsonEncode(chunk));

    test('正文增量', () {
      final List<LlmStreamEvent> events = decode(<String, dynamic>{
        'choices': <dynamic>[
          <String, dynamic>{
            'delta': <String, dynamic>{'content': '你好'},
          },
        ],
      });
      expect(events, hasLength(1));
      expect((events.first as LlmTextDelta).text, '你好');
    });

    test('思考增量：reasoning_content 与 reasoning 都认', () {
      for (final String key in <String>['reasoning_content', 'reasoning']) {
        final List<LlmStreamEvent> events = decode(<String, dynamic>{
          'choices': <dynamic>[
            <String, dynamic>{
              'delta': <String, dynamic>{key: '想一想'},
            },
          ],
        });
        expect((events.first as LlmThinkingDelta).text, '想一想', reason: key);
      }
    });

    test('工具调用增量（含分片参数）与 finish_reason', () {
      final List<LlmStreamEvent> events = decode(<String, dynamic>{
        'choices': <dynamic>[
          <String, dynamic>{
            'delta': <String, dynamic>{
              'tool_calls': <dynamic>[
                <String, dynamic>{
                  'index': 0,
                  'id': 'call_9',
                  'function': <String, dynamic>{
                    'name': 'grep',
                    'arguments': '{"q"',
                  },
                },
                <String, dynamic>{
                  'index': 1,
                  'function': <String, dynamic>{'arguments': '{}'},
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      });
      expect(events.whereType<LlmToolCallDelta>().length, 2);
      final LlmToolCallDelta first = events.whereType<LlmToolCallDelta>().first;
      expect(first.index, 0);
      expect(first.id, 'call_9');
      expect(first.name, 'grep');
      expect(first.argumentsDelta, '{"q"');
      expect(events.last, isA<LlmFinishEvent>());
      expect((events.last as LlmFinishEvent).reason, 'tool_calls');
    });

    test('usage 解码（含缓存明细与 input/output 别名）', () {
      final List<LlmStreamEvent> events = decode(<String, dynamic>{
        'usage': <String, dynamic>{
          'prompt_tokens': 10,
          'completion_tokens': 3,
          'total_tokens': 13,
          'prompt_tokens_details': <String, dynamic>{'cached_tokens': 8},
        },
      });
      final LlmUsage usage = (events.first as LlmUsageEvent).usage;
      expect(usage.promptTokens, 10);
      expect(usage.completionTokens, 3);
      expect(usage.totalTokens, 13);
      expect(usage.cachedTokens, 8);

      final List<LlmStreamEvent> alias = decode(<String, dynamic>{
        'usage': <String, dynamic>{'input_tokens': 4, 'output_tokens': 6},
      });
      final LlmUsage usage2 = (alias.first as LlmUsageEvent).usage;
      expect(usage2.promptTokens, 4);
      expect(usage2.completionTokens, 6);
      expect(usage2.totalTokens, 10, reason: '缺 total 时用 prompt+completion 兜底');
    });

    test('流中 error 帧被识别为失败', () {
      final List<LlmStreamEvent> events = decode(<String, dynamic>{
        'error': <String, dynamic>{'message': 'rate limit exceeded'},
      });
      expect(events, hasLength(1));
      expect((events.first as LlmFailureEvent).message, 'rate limit exceeded');
    });

    test('坏 JSON / 非对象 / 空 delta 都安全返回空或忽略', () {
      expect(OpenAiCodec.decodeChunk('{不是 json'), isEmpty);
      expect(OpenAiCodec.decodeChunk('[1,2,3]'), isEmpty);
      expect(OpenAiCodec.decodeChunk(''), isEmpty);
      expect(
        OpenAiCodec.decodeChunk(
          jsonEncode(<String, dynamic>{
            'choices': <dynamic>[
              <String, dynamic>{'delta': <String, dynamic>{}},
            ],
          }),
        ),
        isEmpty,
      );
      expect(
        OpenAiCodec.decodeChunk(
          jsonEncode(<String, dynamic>{
            'usage': <String, dynamic>{
              'prompt_tokens': 0,
              'completion_tokens': 0,
            },
          }),
        ),
        isEmpty,
        reason: '全 0 的 usage 视为没有用量',
      );
    });
  });
}
