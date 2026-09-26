import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 测试用假 MCP 服务（stdio JSON-RPC）：实现 initialize / ping / tools/list /
/// tools/call。工具：echo（回显）、slow（**永不回应**，用来验证"心跳丢失判死"）、
/// slow-alive（延迟一段时间再回应，**期间照常回 ping**，用来验证"心跳正常的长请求
/// 不被总时长打断"）。
///
/// 参数：
/// - `--fail-init`：initialize 返回错误（验证握手失败的报错路径）；
/// - `--silent`：进程活着但**一声不吭**（连 ping 都不回），模拟链路彻底失活；
/// - `--deaf-for=<ms>`：initialize 回完之后**先沉默这么多毫秒**再恢复正常，
///   模拟"心跳丢了一阵又恢复"（M9 1.1 的自动清除路径）；
/// - `--no-ping`：不实现 ping（回 method-not-found，像老服务端那样）——错误回包
///   同样算"回包"，客户端不该因此判失活。
void main(List<String> args) {
  final bool failInit = args.contains('--fail-init');
  final bool silent = args.contains('--silent');
  final bool noPing = args.contains('--no-ping');
  final int deafForMs = _intArg(args, '--deaf-for=');

  /// 手握手之后才开始计时的沉默窗口（握手本身不受影响）。
  DateTime? deafUntil;
  bool deaf() =>
      silent || (deafUntil != null && DateTime.now().isBefore(deafUntil!));

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
    // 沉默窗口内**什么都不回**：连 ping 也不回，于是客户端会记满连续丢失。
    if (deaf()) return;
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
        if (deafForMs > 0) {
          deafUntil = DateTime.now().add(Duration(milliseconds: deafForMs));
        }
      // MCP 的 ping：空 result 就是"我还在"
      case 'ping':
        if (noPing) {
          // 老/非常规服务端：method not found。**错误回包也是回包**，
          // 客户端应把它算作一次心跳（与 SSH keepalive 回 FAILURE 同理）。
          stdout.writeln(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'error': <String, dynamic>{
                'code': -32601,
                'message': 'method not found: ping',
              },
            }),
          );
          return;
        }
        reply(<String, dynamic>{});
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
              'description': '故意不回应（测心跳丢失判死）',
              'inputSchema': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
            <String, dynamic>{
              'name': 'slow-alive',
              'description': '跑很久但期间照常回 ping（测长请求不被总时长打断）',
              'inputSchema': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'ms': <String, dynamic>{'type': 'integer'},
                },
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
        if (name == 'slow-alive') {
          // 延迟回包：await 在事件循环里，**监听器照常处理 ping**，所以这段时间
          // 链路一直是活的——客户端不该以"总时长"为由打断它。
          final int ms = int.tryParse('${callArgs['ms'] ?? 0}') ?? 0;
          Future<void>.delayed(Duration(milliseconds: ms), () {
            reply(<String, dynamic>{
              'content': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'text': '慢慢做完：$ms ms'},
              ],
              'isError': false,
            });
          });
          return;
        }
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

int _intArg(List<String> args, String prefix) {
  for (final String arg in args) {
    if (arg.startsWith(prefix)) {
      return int.tryParse(arg.substring(prefix.length)) ?? 0;
    }
  }
  return 0;
}
