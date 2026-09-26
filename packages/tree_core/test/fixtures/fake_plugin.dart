import 'dart:convert';
import 'dart:io';

/// 测试用假插件（stdio JSON-RPC）：hello / tools.list / tools.call / ping / event。
///
/// 参数：
/// - `--events-file <path>`：把收到的 `event` 通知逐行追加到该文件（验证总线分发）
/// - `--ignore-ping`：不回 ping（验证看门狗能把实例标记为不可用）
void main(List<String> args) {
  String eventsFile = '';
  final bool ignorePing = args.contains('--ignore-ping');
  for (int i = 0; i < args.length - 1; i++) {
    if (args[i] == '--events-file') eventsFile = args[i + 1];
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
    final Map<String, dynamic> params =
        (message['params'] as Map<dynamic, dynamic>? ?? <dynamic, dynamic>{})
            .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    if (id == null) {
      if (method == 'event') {
        if (eventsFile.isNotEmpty) {
          File(
            eventsFile,
          ).writeAsStringSync('${jsonEncode(params)}\n', mode: FileMode.append);
        }
        // 插件主动通知（无 id）：核心应转成 plugin_event 推给前端
        stdout.writeln(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'log',
            'params': <String, dynamic>{
              'level': 'info',
              'message': '收到事件 ${params['type']}',
            },
          }),
        );
      }
      if (method == 'shutdown') exit(0);
      return;
    }
    void reply(Map<String, dynamic> result) {
      stdout.writeln(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': result,
        }),
      );
    }

    switch (method) {
      case 'hello':
        reply(<String, dynamic>{
          'plugin_id': 'fake-plugin',
          'name': '假插件',
          'capabilities': <String>['tools'],
        });
      case 'tools/list':
        reply(<String, dynamic>{
          'tools': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'echo',
              'description': '回显输入',
              'inputSchema': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'text': <String, dynamic>{'type': 'string'},
                },
                'required': <String>['text'],
              },
            },
            <String, dynamic>{
              'name': 'slow',
              'description': '故意不回应（测超时）',
              'inputSchema': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          ],
        });
      case 'tools/call':
        final String name = (params['name'] ?? '').toString();
        final Map<String, dynamic> callArgs =
            (params['arguments'] as Map<dynamic, dynamic>? ??
                    <dynamic, dynamic>{})
                .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
        if (name == 'slow') return;
        if (name == 'echo') {
          reply(<String, dynamic>{
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'text',
                'text': 'plugin-echo: ${callArgs['text']}',
              },
            ],
            'isError': false,
          });
          return;
        }
        reply(<String, dynamic>{
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': '未知工具 $name'},
          ],
          'isError': true,
        });
      case 'ping':
        if (ignorePing) return;
        reply(<String, dynamic>{'ok': true});
      default:
        stdout.writeln(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'error': <String, dynamic>{
              'code': -32601,
              'message': 'method not found: $method',
            },
          }),
        );
    }
  }, onDone: () => exit(0));
}
