import 'dart:convert';
import 'dart:io';

/// 热应用测试用的假插件（stdio JSON-RPC）：与 fake_plugin.dart 同一套协议，
/// 但多了三件测试"配置对账"必需的东西：
///
/// - `--start-log PATH`：**每次进程启动**往该文件追加一行（含 pid / marker / 完整
///   参数）。测试靠它**数启动次数**，从而证明"配置没变 ⇒ 不重启"；
/// - `--marker VALUE`：把启动参数带进工具返回值与工具描述（证明"改了启动参数 ⇒
///   真的用新参数重启了"，而不是拿旧进程糊弄）；
/// - 始终实现收集站的 `station/request`（按 schema 申报一个工具定义）：
///   于是"插件上线 ⇒ 收集站收集 ⇒ 工具表出现该工具 ⇒ 下线后消失"这条链路
///   能在测试里被断言。
///
/// 参数：
/// - --id ID：hello 里回带的 plugin_id（缺省 hot-plugin）
/// - --start-log PATH：启动记录文件（缺省不记）
/// - --marker VALUE：本次启动的标记（缺省空串）
void main(List<String> args) {
  final String startLog = _valueOf(args, '--start-log');
  final String marker = _valueOf(args, '--marker');
  final String pluginId = _valueOf(args, '--id', fallback: 'hot-plugin');

  if (startLog.isNotEmpty) {
    // 追加一行就够：测试只数行数 + 读 marker 序列
    File(startLog).writeAsStringSync(
      '${jsonEncode(<String, dynamic>{'pid': pid, 'marker': marker})}\n',
      mode: FileMode.append,
    );
  }

  void reply(Object? id, Map<String, dynamic> result) {
    stdout.writeln(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      }),
    );
  }

  /// 工具定义（收集站与 tools/list 两条申报路径共用同一份口径）。
  Map<String, dynamic> toolDefinition() => <String, dynamic>{
    'tool_name': 'marker',
    'description': '热应用假插件的标记工具（本次启动的 marker=$marker）',
    'parameters': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'echo': <String, dynamic>{'type': 'string'},
      },
    },
    'execution': <String, dynamic>{'method': 'tools/call', 'name': 'marker'},
  };

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
    // 通知（没有 id）：event 忽略，shutdown 直接退出
    if (id == null) {
      if (method == 'shutdown') exit(0);
      return;
    }
    switch (method) {
      case 'hello':
        reply(id, <String, dynamic>{
          'plugin_id': pluginId,
          'name': '热应用假插件',
          'capabilities': <String>['tools'],
        });
      case 'tools/list':
        reply(id, <String, dynamic>{
          'tools': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'marker',
              'description': '标记工具（marker=$marker）',
              'inputSchema': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          ],
        });
      case 'station/request':
        // 收集站：按 schema 申报工具定义（payload.tools）
        reply(id, <String, dynamic>{
          'reply': <String, dynamic>{
            'payload': <String, dynamic>{
              'tools': <Map<String, dynamic>>[toolDefinition()],
            },
          },
        });
      case 'tools/call':
        final Map<String, dynamic> params =
            (message['params'] as Map<dynamic, dynamic>? ??
                    <dynamic, dynamic>{})
                .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
        final String name = (params['name'] ?? '').toString();
        if (name == 'marker') {
          reply(id, <String, dynamic>{
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': 'marker=$marker'},
            ],
            'isError': false,
          });
          return;
        }
        reply(id, <String, dynamic>{
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': '未知工具 $name'},
          ],
          'isError': true,
        });
      case 'ping':
        reply(id, <String, dynamic>{'ok': true});
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

/// 取 `--key value` 形式的参数值（缺省返回 [fallback]）。
String _valueOf(List<String> args, String key, {String fallback = ''}) {
  for (int i = 0; i < args.length - 1; i++) {
    if (args[i] == key) return args[i + 1];
  }
  return fallback;
}
