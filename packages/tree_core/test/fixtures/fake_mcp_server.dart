import 'dart:convert';
import 'dart:io';

/// 测试用假 MCP 服务（stdio JSON-RPC）：实现 initialize / tools/list / tools/call。
///
/// 参数：`--fail-init` 让 initialize 返回错误（验证握手失败的报错路径）。
void main(List<String> args) {
  final bool failInit = args.contains('--fail-init');
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
    if (id == null) return; // 通知（notifications/initialized）
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
      case 'initialize':
        if (failInit) {
          stdout.writeln(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'error': <String, dynamic>{'code': -32000, 'message': '拒绝初始化'},
            }),
          );
          return;
        }
        reply(<String, dynamic>{
          'protocolVersion': '2024-11-05',
          'capabilities': <String, dynamic>{},
          'serverInfo': <String, dynamic>{'name': 'fake-mcp', 'version': '0.1'},
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
        final Map<String, dynamic> params =
            (message['params'] as Map<dynamic, dynamic>).map(
              (dynamic k, dynamic v) => MapEntry(k.toString(), v),
            );
        final String name = (params['name'] ?? '').toString();
        final Map<String, dynamic> callArgs =
            (params['arguments'] as Map<dynamic, dynamic>? ??
                    <dynamic, dynamic>{})
                .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
        if (name == 'slow') return; // 永不回应
        if (name == 'echo') {
          reply(<String, dynamic>{
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'text',
                'text': 'echo: ${callArgs['text']}',
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
