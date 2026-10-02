import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 测试用假插件：**中转站 LLM 点位（含 `station/stream` 流式回填）**的夹具。
///
/// 为什么另起一个文件而不扩 `fake_plugin.dart`：那一个是通用骨架（工具申报 / 事件 /
/// 命令），本夹具只服务「LLM 处理 / 投入 LLM 前 / 上下文压缩 / 系统提示词」四个中转
/// 点位与流式数据面，选项少一半、意图也更明白。
///
/// 选项（全部可选；给哪个用哪个）：
/// - `--subscribe-point ID`：起进程后按 `station_id` 直连订阅该点位（`replace: true`），
///   把回包写进 stderr（诊断用）。
/// - `--llm-mode MODE`：`system.relay.llm.handle` 的接管方式——
///   `once`（裸 message 一次性接管）/ `once-openai`（OpenAI 非流式响应）/
///   `stream`（流式：3 类增量 + OpenAI 分片写法 + done）/ `stream-hold`（推一条后
///   等 `--finish-file` 出现再 done）/ `stream-error`（推一条后以 error 收尾）/
///   `silent`（声明 stream:true 后什么都不推）/ `exit-after-stream`（回包后退出进程）。
/// - `--llm-request-mode MODE`：`system.relay.llm.request` 的回包——
///   `rewrite`（改写后的请求体）/ `invalid`（`{"model": ""}`）/
///   `invalid-messages`（messages 不是数组）：后两者都应被核心放行原请求。
/// - `--compact-mode MODE`：`system.relay.context.compact` 的回包——
///   `list`（接管：回 `{messages:[system,user,tool], covered_message_count:2}`）/
///   `bad-messages`（messages 里有非法元素 ⇒ 核心必须回退内置 compact）/
///   `bad-count`（缺 covered_message_count ⇒ 同样回退）/
///   `bare-list`（裸数组回包 ⇒ 缺水位线，回退）/ 空 = 回 null（不接管）。
/// - `--compact-log FILE`：把每个 `context.compact` 请求的**完整 params** 逐行追加为
///   JSON（载荷契约用例据此断言核心真的把完整原文列表 / 系统提示词发出来了）。
/// - `--prompt-mode MODE`：`system.relay.prompt.system` 的回包——
///   `text`（`"插件改写后的提示词"`）/ `empty`（空串 = 明确不要系统提示词）/
///   `map`（`{"prompt": "..."}`）。
/// - `--record FILE`：把收到的**每条通知**（method + params）逐行追加为 JSON；
///   取消用例据此查证插件确实收到了核心下发的 `station/cancel`。
/// - `--request-log FILE`：把每个 `llm.handle` 请求的 `request_id` 写成一行
///   （归属校验用例靠它把「别人的 request_id」交给第二个插件）。
/// - `--finish-file FILE`：`stream-hold` 模式下等这个文件出现再推 `done`。
/// - `--stream-delay-ms N`：相邻增量之间的间隔（默认 40ms）。
/// - `--foreign-stream FILE`：轮询 FILE 拿到**别的插件**那条流的 request_id，然后
///   冒名推一条 `station/stream`（验证核心的归属校验拒绝它）。
/// - `--foreign-marker FILE`：冒名推完写一个标记文件（测试据此确认"它真的推了"，
///   否则"没收到外来增量"可能只是它压根没推）。
/// - `--foreign-delay-ms N`：读到 request_id 后再等 N 毫秒才冒名推（让核心那条流
///   先稳定打开，避免撞上"未知 request_id"分支而不是"归属校验"分支）。
/// - `--late-delta-after-cancel`：收到 `station/cancel` 后再推一条 `LATE` 增量
///   （验证取消后到达的增量被丢弃、不会报错）。
/// - `--bogus-stream`：订阅成功后立刻用一个不存在的 request_id 推一条增量
///   （验证未知 request_id 被丢弃且不影响任何在途流）。
/// - `--ignore-ping`：完全不回 `ping`（验证心跳丢失 ⇒ 接管流以失败收尾）。
void main(List<String> args) {
  String arg(String name, [String fallback = '']) {
    for (int i = 0; i < args.length - 1; i++) {
      if (args[i] == name) return args[i + 1];
    }
    return fallback;
  }

  bool flag(String name) => args.contains(name);

  final String subscribePoint = arg('--subscribe-point');
  final String llmMode = arg('--llm-mode', 'silent');
  final String llmRequestMode = arg('--llm-request-mode');
  final String compactMode = arg('--compact-mode');
  final String compactLogFile = arg('--compact-log');
  final String promptMode = arg('--prompt-mode');
  final String recordFile = arg('--record');
  final String requestLogFile = arg('--request-log');
  final String finishFile = arg('--finish-file');
  final String foreignStreamFile = arg('--foreign-stream');
  final String foreignMarkerFile = arg('--foreign-marker');
  final int foreignDelayMs =
      int.tryParse(arg('--foreign-delay-ms', '500')) ?? 500;
  final bool lateDeltaAfterCancel = flag('--late-delta-after-cancel');
  final bool bogusStream = flag('--bogus-stream');
  final bool ignorePing = flag('--ignore-ping');
  final int streamDelayMs = int.tryParse(arg('--stream-delay-ms', '40')) ?? 40;

  /// 插件**主动**发起的请求（station/subscribe）：id → 等核心响应的 completer。
  final Map<String, Completer<Map<String, dynamic>>> pending =
      <String, Completer<Map<String, dynamic>>>{};
  int nextId = 0;

  void send(Map<String, dynamic> message) =>
      stdout.writeln(jsonEncode(message));

  void notify(String method, Map<String, dynamic> params) => send(
    <String, dynamic>{'jsonrpc': '2.0', 'method': method, 'params': params},
  );

  void log(String message) => stderr.writeln('[fake-llm] $message');

  void appendLine(String path, String line) {
    if (path.isEmpty) return;
    try {
      File(path)
          .writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (error) {
      log('写记录文件失败 $path：$error');
    }
  }

  /// 主动发一条 JSON-RPC 请求并等核心响应（10s 兜底只为失败可读，不会永久挂住）。
  Future<Map<String, dynamic>> requestCore(
    String method,
    Map<String, dynamic> params,
  ) {
    final String id = 'plugin-req-${++nextId}';
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    pending[id] = completer;
    send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        pending.remove(id);
        return <String, dynamic>{'timeout': true, 'method': method};
      },
    );
  }

  /// 轮询等一个文件出现（有上限：夹具绝不永久挂住）。
  Future<bool> waitForFile(
    String path, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (path.isEmpty) return false;
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (File(path).existsSync()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    log('等待文件超时：$path');
    return false;
  }

  Future<void> gap() =>
      Future<void>.delayed(Duration(milliseconds: streamDelayMs));

  /// 流式接管：回包声明 `stream:true` 之后由这里推增量 / 收尾。
  ///
  /// 刻意**不在请求处理器里 await**：读循环必须随时能处理 `ping` 与 `station/cancel`
  /// （见开发指南 §1 铁律 2），所以它挂在 `unawaited` 上自己跑。
  Future<void> pushStream(String requestId) async {
    switch (llmMode) {
      case 'stream':
        await gap();
        notify('station/stream', <String, dynamic>{
          'request_id': requestId,
          'delta': <String, dynamic>{'kind': 'text', 'text': '流式1'},
        });
        await gap();
        notify('station/stream', <String, dynamic>{
          'request_id': requestId,
          'delta': <String, dynamic>{'kind': 'thinking', 'text': '先看文件'},
        });
        await gap();
        notify('station/stream', <String, dynamic>{
          'request_id': requestId,
          'delta': <String, dynamic>{
            'kind': 'tool_call',
            'index': 0,
            'id': 'call_s1',
            'name': 'read',
            'arguments_delta': '{"pa',
          },
        });
        await gap();
        notify('station/stream', <String, dynamic>{
          'request_id': requestId,
          'delta': <String, dynamic>{
            'kind': 'tool_call',
            'index': 0,
            'arguments_delta': 'th":"a.txt"}',
          },
        });
        await gap();
        // OpenAI 分片写法：协议明确接受，与上面的紧凑写法等价
        notify('station/stream', <String, dynamic>{
          'request_id': requestId,
          'delta': <String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'delta': <String, dynamic>{'content': '流式尾'},
              },
            ],
          },
        });
        await gap();
        notify('station/stream', <String, dynamic>{
          'request_id': requestId,
          'done': true,
          'finish_reason': 'stop',
          'usage': <String, dynamic>{
            'prompt_tokens': 7,
            'completion_tokens': 3,
          },
        });
      case 'stream-hold':
        await gap();
        notify('station/stream', <String, dynamic>{
          'request_id': requestId,
          'delta': <String, dynamic>{'kind': 'text', 'text': 'OWN-1'},
        });
        // 等测试放行（归属校验用例：外来增量必须在这条流打开期间到达）
        await waitForFile(finishFile);
        notify('station/stream', <String, dynamic>{
          'request_id': requestId,
          'done': true,
          'finish_reason': 'stop',
        });
      case 'stream-error':
        await gap();
        notify('station/stream', <String, dynamic>{
          'request_id': requestId,
          'delta': <String, dynamic>{'kind': 'text', 'text': '半截'},
        });
        await gap();
        notify('station/stream', <String, dynamic>{
          'request_id': requestId,
          'error': <String, dynamic>{'message': '上游 500'},
        });
      case 'silent':
        // 声明接管后什么都不推：取消 / 心跳丢失两条收尾路径的对照
        break;
      case 'exit-after-stream':
        break;
    }
  }

  /// 冒名往**别的插件**的 request_id 推一条增量（归属校验用）。
  Future<void> foreignPush() async {
    if (foreignStreamFile.isEmpty) return;
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
    String requestId = '';
    while (DateTime.now().isBefore(deadline)) {
      try {
        final String text = File(foreignStreamFile).readAsStringSync().trim();
        if (text.isNotEmpty) {
          requestId = text.split('\n').first.trim();
          break;
        }
      } catch (_) {
        // 文件还没出现 / 正被写：继续等
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    if (requestId.isEmpty) {
      log('冒名推流失败：拿不到别人的 request_id');
      return;
    }
    // 等核心那条流稳定打开：否则这一推会落在"未知 request_id"分支上，
    // 用例就测不到归属校验那一段了。
    await Future<void>.delayed(Duration(milliseconds: foreignDelayMs));
    notify('station/stream', <String, dynamic>{
      'request_id': requestId,
      'delta': <String, dynamic>{'kind': 'text', 'text': 'FOREIGN'},
    });
    if (foreignMarkerFile.isNotEmpty) {
      try {
        File(foreignMarkerFile).writeAsStringSync(requestId, flush: true);
      } catch (error) {
        log('写标记文件失败：$error');
      }
    }
  }

  Future<void> subscribe() async {
    if (bogusStream) {
      // 未知 request_id：核心应丢弃并记日志，且不影响任何在途流
      notify('station/stream', <String, dynamic>{
        'request_id': 'relay-unknown-request-id',
        'delta': <String, dynamic>{'kind': 'text', 'text': 'GHOST'},
      });
    }
    if (subscribePoint.isEmpty) return;
    try {
      final Map<String, dynamic> response = await requestCore(
        'station/subscribe',
        <String, dynamic>{'station_id': subscribePoint, 'replace': true},
      );
      log(
        'subscribe $subscribePoint → ${jsonEncode(response['result'] ?? response)}',
      );
    } catch (error) {
      log('subscribe 失败：$error');
    }
  }

  /// `system.relay.llm.handle` 的一次性接管回包（null = 不接管）。
  Map<String, dynamic>? llmHandlePayload() {
    switch (llmMode) {
      case 'once':
        return <String, dynamic>{
          'content': '插件一次性接管',
          'reasoning_content': '先想想',
          'tool_calls': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'call_once',
              'type': 'function',
              'function': <String, dynamic>{
                'name': 'read',
                'arguments': '{"path":"a.txt"}',
              },
            },
          ],
          'usage': <String, dynamic>{
            'prompt_tokens': 11,
            'completion_tokens': 4,
          },
          'finish_reason': 'stop',
        };
      case 'once-openai':
        return <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': 'OpenAI 形状接管',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'call_openai',
                    'function': <String, dynamic>{
                      'name': 'write',
                      'arguments': '{"path":"b.txt"}',
                    },
                  },
                ],
              },
              'finish_reason': 'stop',
            },
          ],
          'usage': <String, dynamic>{
            'prompt_tokens': 3,
            'completion_tokens': 2,
          },
        };
      case 'stream':
      case 'stream-hold':
      case 'stream-error':
      case 'silent':
      case 'exit-after-stream':
        return <String, dynamic>{'stream': true};
      default:
        return null;
    }
  }

  if (subscribePoint.isNotEmpty || bogusStream) {
    // hello 握手后核心已能处理请求；用 microtask 让读循环先跑起来
    scheduleMicrotask(subscribe);
  }
  if (foreignStreamFile.isNotEmpty) {
    scheduleMicrotask(foreignPush);
  }

  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((
    String line,
  ) {
    if (line.trim().isEmpty) return;
    Map<String, dynamic> message;
    try {
      message = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final Object? id = message['id'];
    final String method = (message['method'] ?? '').toString();
    // 核心对我方主动请求的响应（JSON-RPC Response 形态：有 id、无 method）
    if (method.isEmpty) {
      final Completer<Map<String, dynamic>>? waiting = pending.remove(
        id?.toString(),
      );
      if (waiting != null && !waiting.isCompleted) waiting.complete(message);
      return;
    }
    final Map<String, dynamic> params =
        (message['params'] as Map<dynamic, dynamic>? ?? <dynamic, dynamic>{})
            .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    if (id == null) {
      // 通知：一律记录（取消用例据此查证），并处理需要反应的几条
      appendLine(
        recordFile,
        jsonEncode(<String, dynamic>{'method': method, 'params': params}),
      );
      if (method == 'station/cancel') {
        final String requestId = (params['request_id'] ?? '').toString();
        if (lateDeltaAfterCancel && requestId.isNotEmpty) {
          notify('station/stream', <String, dynamic>{
            'request_id': requestId,
            'delta': <String, dynamic>{'kind': 'text', 'text': 'LATE'},
          });
        }
      }
      if (method == 'shutdown') exit(0);
      return;
    }

    void reply(Map<String, dynamic> result) {
      send(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result});
    }

    switch (method) {
      case 'hello':
        reply(<String, dynamic>{
          'plugin_id': 'fake-llm',
          'name': '假 LLM 插件',
          'capabilities': <String>['tools'],
        });
      case 'tools/list':
        reply(<String, dynamic>{'tools': <Map<String, dynamic>>[]});
      case 'ping':
        if (ignorePing) return;
        reply(<String, dynamic>{'ok': true});
      case 'station/request':
        final String point = (params['station_id'] ?? '').toString();
        final String requestId = (params['request_id'] ?? '').toString();
        // 收集站（工具定义申报）：回空清单。**必须回**——不回会让核心那次
        // 收集一直等下去（工具表刷新点被卡住）。
        if (point == StationIds.collect) {
          reply(<String, dynamic>{
            'reply': <String, dynamic>{
              'payload': <String, dynamic>{'tools': <Map<String, dynamic>>[]},
            },
          });
          return;
        }
        if (point == StationIds.relayLlmHandle) {
          appendLine(requestLogFile, requestId);
          final Map<String, dynamic>? payload = llmHandlePayload();
          reply(<String, dynamic>{
            'reply': <String, dynamic>{'payload': payload},
          });
          if (llmMode == 'exit-after-stream') {
            // 回包必须先真正写进管道再退出，否则核心看不到 stream:true
            stdout.flush().then((_) => exit(0));
          } else {
            unawaited(pushStream(requestId));
          }
          return;
        }
        if (point == StationIds.relayLlmRequest) {
          if (llmRequestMode == 'rewrite') {
            reply(<String, dynamic>{
              'reply': <String, dynamic>{
                'payload': <String, dynamic>{
                  'model': 'plugin-model',
                  'messages': <Map<String, dynamic>>[
                    <String, dynamic>{'role': 'user', 'content': '插件改写后的输入'},
                  ],
                  'temperature': 0.25,
                  'response_format': <String, dynamic>{'type': 'json_object'},
                },
              },
            });
            return;
          }
          if (llmRequestMode == 'invalid') {
            // 非法：model 为空 ⇒ 核心必须放行原请求（fail-open）
            reply(<String, dynamic>{
              'reply': <String, dynamic>{
                'payload': <String, dynamic>{'model': ''},
              },
            });
            return;
          }
          if (llmRequestMode == 'invalid-messages') {
            // 非法：messages 不是数组 ⇒ 同样必须放行原请求
            reply(<String, dynamic>{
              'reply': <String, dynamic>{
                'payload': <String, dynamic>{
                  'model': 'plugin-model',
                  'messages': 'not-a-list',
                },
              },
            });
            return;
          }
          reply(<String, dynamic>{
            'reply': <String, dynamic>{'payload': null},
          });
          return;
        }
        if (point == StationIds.relayContextCompact) {
          appendLine(compactLogFile, jsonEncode(params));
          // 新契约（2026-10）：接管 = 回一份**整份新上下文** + 覆盖条数
          final Map<String, dynamic> context = <String, dynamic>{
            'messages': <Map<String, dynamic>>[
              <String, dynamic>{'role': 'system', 'content': '插件压缩后的系统提示词'},
              <String, dynamic>{'role': 'user', 'content': '插件压缩后的历史要点'},
              <String, dynamic>{'role': 'user', 'content': '最近一条原文'},
            ],
            'covered_message_count': 2,
          };
          // 按请求多少条原文决定覆盖数（契约用例据此断言水位线真的按回包落库）
          final Object? incoming = params['payload'];
          if (incoming is Map && incoming['messages'] is List) {
            final int total = (incoming['messages'] as List<dynamic>).length;
            context['covered_message_count'] = total <= 1 ? 0 : 2;
          }
          final Object? payload = switch (compactMode) {
            'list' => context,
            'bad-messages' => <String, dynamic>{
              'messages': <dynamic>['not-a-message'],
              'covered_message_count': 1,
            },
            'bad-count' => <String, dynamic>{
              'messages': context['messages'],
            },
            'bare-list' => context['messages'],
            _ => null,
          };
          reply(<String, dynamic>{
            'reply': <String, dynamic>{'payload': payload},
          });
          return;
        }
        if (point == StationIds.relayPromptSystem) {
          final Object? payload = switch (promptMode) {
            'text' => '插件改写后的提示词',
            'empty' => '',
            'map' => <String, dynamic>{'prompt': '插件改写后的提示词（map）'},
            _ => null,
          };
          reply(<String, dynamic>{
            'reply': <String, dynamic>{'payload': payload},
          });
          return;
        }
        // 其它点位：不改动
        reply(<String, dynamic>{
          'reply': <String, dynamic>{'payload': null},
        });
      default:
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, dynamic>{
            'code': -32601,
            'message': 'method not found: $method',
          },
        });
    }
  }, onDone: () => exit(0));
}

/// 夹具侧记住的几个点位 id（**刻意硬编码字面量**）。
///
/// 为什么不 import 核心的 `StationHubIds`：插件进程在生产里是**独立进程**，
/// 只能靠协议里的字符串；夹具照抄协议字面量，"核心改了 id 而夹具没跟着改"
/// 因此会以测试失败的形式暴露出来，而不是被一次 import 悄悄抹平。
abstract final class StationIds {
  static const String collect = 'plugin.tool.define';
  static const String relayLlmHandle = 'system.relay.llm.handle';
  static const String relayLlmRequest = 'system.relay.llm.request';
  static const String relayContextCompact = 'system.relay.context.compact';
  static const String relayPromptSystem = 'system.relay.prompt.system';
}
