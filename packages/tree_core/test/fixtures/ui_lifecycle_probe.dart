import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 测试用 **UI 插件进程**（生命周期握手 / UI 热重启）。
///
/// 它做四件事，全部以「事件日志」为证据（测试按事件判，不按挂钟）：
/// 1. 连核心 WS，发 `ui.hello`（默认声明 `ui.lifecycle`，`--mode nocap` 不声明）；
/// 2. 收到 `plugin.suspend` ⇒ 写一条 `suspend` 事件，回 `plugin.suspendAck`
///    （payload 里带本进程 pid，测试据此证明「第二世取回的是第一世写的那份」），
///    然后自己 `exit(0)`（先写 `exit` 事件，用来断言「新进程在旧进程退出之后才起」）；
/// 3. 收到 `plugin.resume` ⇒ 写一条 `resume` 事件（含 `has_snapshot` / `payload`）；
/// 4. `--mode hang` 收挂起请求后既不应答也不退出（钉 ack 超时后 kill）；
///    `--mode oversize` 回一份超过单条上限（1 MiB）的切片（钉「超限 ⇒ 冷启动」）。
///
/// 参数：`--id <plugin_id> --events <jsonl 路径> [--mode lifecycle|nocap|hang|oversize]`。
void main(List<String> args) async {
  final String pluginId = _argOf(args, '--id') ?? '';
  final String eventsPath = _argOf(args, '--events') ?? '';
  final String mode = _argOf(args, '--mode') ?? 'lifecycle';
  final String windowId = Platform.environment['TREE_UI_WINDOW_ID'] ?? '';
  final String base = Platform.environment['TREE_CORE_URL'] ?? '';
  final String token = Platform.environment['TREE_CORE_TOKEN'] ?? '';

  void emit(Map<String, dynamic> event) {
    if (eventsPath.isEmpty) return;
    File(eventsPath).writeAsStringSync(
      '${jsonEncode(<String, dynamic>{...event, 'at': DateTime.now().microsecondsSinceEpoch})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  emit(<String, dynamic>{
    'kind': 'start',
    'pid': pid,
    'window': windowId,
    'mode': mode,
  });

  final WebSocket socket;
  try {
    socket = await WebSocket.connect('$base/ws?token=$token');
  } catch (error) {
    emit(<String, dynamic>{'kind': 'connect_error', 'error': '$error'});
    exit(4);
  }
  socket.add(
    jsonEncode(<String, dynamic>{
      'type': 'ui.hello',
      'data': <String, dynamic>{
        'plugin_id': pluginId,
        'version': 'test',
        'capabilities': mode == 'nocap'
            ? const <String>[]
            : const <String>['ui.lifecycle'],
        if (windowId.isNotEmpty) 'window_id': windowId,
      },
    }),
  );

  socket.listen((Object? raw) {
    Map<String, dynamic> frame;
    try {
      final Object? decoded = jsonDecode(raw.toString());
      if (decoded is! Map) return;
      frame = decoded.map((Object? k, Object? v) => MapEntry(k.toString(), v));
    } catch (_) {
      return;
    }
    switch (frame['type']) {
      case 'plugin.suspend':
        emit(<String, dynamic>{'kind': 'suspend', 'window': windowId});
        if (mode == 'hang') return;
        final Map<String, dynamic> payload = mode == 'oversize'
            ? <String, dynamic>{'blob': 'x' * (2 << 20)}
            : <String, dynamic>{'window': windowId, 'era_pid': pid};
        socket.add(
          jsonEncode(<String, dynamic>{
            'type': 'plugin.suspendAck',
            'data': <String, dynamic>{
              'ok': true,
              'dumped': true,
              'window_id': windowId,
              'plugin_id': pluginId,
              'bytes': jsonEncode(payload).length,
              'payload': payload,
            },
          }),
        );
        Timer(const Duration(milliseconds: 30), () {
          emit(<String, dynamic>{'kind': 'exit', 'pid': pid, 'window': windowId});
          exit(0);
        });
      case 'plugin.resume':
        final Object? data = frame['data'];
        emit(<String, dynamic>{
          'kind': 'resume',
          'window': windowId,
          'has_snapshot': data is Map ? data['has_snapshot'] : null,
          'payload': data is Map ? data['payload'] : null,
          'generation': data is Map ? data['generation'] : null,
          'reason': data is Map ? data['reason'] : null,
        });
    }
  }, onDone: () {
    emit(<String, dynamic>{'kind': 'socket_closed', 'window': windowId});
  });

  // 保持事件循环活着（UI 插件不读 stdin、不说 stdio 协议）。
  Timer.periodic(const Duration(seconds: 1), (_) {});
}

String? _argOf(List<String> args, String name) {
  final int index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}
