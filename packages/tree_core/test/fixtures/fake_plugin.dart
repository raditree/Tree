import 'dart:convert';
import 'dart:io';

/// 测试用假插件（stdio JSON-RPC）：hello / tools.list / tools.call /
/// station.request / ping / event。
///
/// 参数：
/// - --events-file PATH：把收到的 event 通知逐行追加到该文件（验证总线分发）
/// - --ignore-ping：完全不回 ping（验证心跳丢失 ⇒ degraded，且进程不被杀）
/// - --ignore-ping-until PATH：该文件不存在时忽略 ping，文件出现后恢复回包
///   （验证心跳恢复 ⇒ degraded 自动清除）
/// - --exit-on-slow：tools/call 命中 slow 时直接退出进程
///   （验证「无静态超时」+「进程退出即在途调用显式失败」）
/// - --station-tools：实现收集站的 station/request，按站点 schema 申报工具定义
///   （含一条执行名与工具名不同的别名工具，用于验证按来源 plugin_id 路由）
void main(List<String> args) {
  String eventsFile = '';
  String pingGateFile = '';
  final bool ignorePing = args.contains('--ignore-ping');
  final bool exitOnSlow = args.contains('--exit-on-slow');
  final bool stationTools = args.contains('--station-tools');
  for (int i = 0; i < args.length - 1; i++) {
    if (args[i] == '--events-file') eventsFile = args[i + 1];
    if (args[i] == '--ignore-ping-until') pingGateFile = args[i + 1];
  }

  bool pingAllowed() {
    if (ignorePing) return false;
    if (pingGateFile.isEmpty) return true;
    return File(pingGateFile).existsSync();
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
              'description': '故意不回应（测进程退出时的显式失败）',
              'inputSchema': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          ],
        });
      case 'station/request':
        if (!stationTools) {
          stdout.writeln(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'error': <String, dynamic>{
                'code': -32601,
                'message': 'method not found: station/request',
              },
            }),
          );
          return;
        }
        reply(<String, dynamic>{
          'reply': <String, dynamic>{
            'payload': <String, dynamic>{
              'tools': <Map<String, dynamic>>[
                <String, dynamic>{
                  'tool_name': 'echo',
                  'description': '回显输入（经收集站申报）',
                  'parameters': <String, dynamic>{
                    'type': 'object',
                    'properties': <String, dynamic>{
                      'text': <String, dynamic>{'type': 'string'},
                    },
                    'required': <String>['text'],
                  },
                  'execution': <String, dynamic>{
                    'method': 'tools/call',
                    'name': 'echo',
                  },
                },
                <String, dynamic>{
                  'tool_name': 'alias',
                  'description': '别名工具（执行名与工具名不同）',
                  'parameters': <String, dynamic>{
                    'type': 'object',
                    'properties': <String, dynamic>{},
                  },
                  'execution': <String, dynamic>{
                    'method': 'tools/call',
                    'name': 'echo',
                  },
                },
              ],
            },
          },
        });
      case 'tools/call':
        final String name = (params['name'] ?? '').toString();
        final Map<String, dynamic> callArgs =
            (params['arguments'] as Map<dynamic, dynamic>? ??
                    <dynamic, dynamic>{})
                .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
        if (name == 'slow') {
          // 不回应；加了 --exit-on-slow 时直接退出进程，验证在途调用显式失败
          if (exitOnSlow) exit(0);
          return;
        }
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
        if (!pingAllowed()) return;
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
