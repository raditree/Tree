/// G-1 **双跑等价对照**工具：同一数据根下比较「核心 HTTP」与「插件 `api/delegate`」。
///
/// 为什么需要它：G-1 要求 36 条端点的回包"与迁移前一致"，但双跑期核心 router
/// 永远优先（委派不得抢占已实现路由），HTTP 请求打不到插件。于是等价验证走两条
/// 独立链路，再逐字节比较：
///
///   核心 HTTP（参考实现）  ──相同数据根──  插件的 api/delegate（被委派方）
///
/// 一条路由算通过 = **状态码 + Content-Type + body 字节**三者一致。任何一项不同
/// 都打印差异并以非 0 退出（可进 CI；不静默跳过）。
///
/// 用法（在 `packages/tree_core` 下）：
///   dart run tool/verify_agent_equivalence.dart
///   dart run tool/verify_agent_equivalence.dart --exe ../../build/plugins/tree_agent.exe
///
/// 加一条路由：在 [_runCase] 里加一个分支（种子数据 + 具体请求），其余流程复用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_core/tree_core.dart';

/// 当前已搬进插件、可做等价对照的路由（与 `agent_api_contract.md` 的编号对应）。
const List<String> kImplementedRoutes = <String>[
  'GET /api/agents/{agentId}/todos',
];

Future<void> main(List<String> args) async {
  final String? exe = _resolveExe(_arg(args, '--exe'));
  if (exe == null) {
    stderr.writeln(
      '[verify] 找不到插件产物。先构建：dart run tool/build_plugins.dart --only tree.agent',
    );
    exitCode = 2;
    return;
  }
  stdout.writeln('[verify] 插件产物：$exe');
  final List<String> failures = <String>[];
  for (final String route in kImplementedRoutes) {
    final String? failure = await _runCase(route, exe);
    if (failure == null) {
      stdout.writeln('[OK] $route：状态码 / Content-Type / body 逐字节一致');
    } else {
      failures.add('$route：$failure');
      stdout.writeln('[FAIL] $route：$failure');
    }
  }
  if (failures.isEmpty) {
    stdout.writeln('[verify] 全部通过（${kImplementedRoutes.length} 条）');
    return;
  }
  stderr.writeln('[verify] ${failures.length} 条不一致');
  exitCode = 1;
}

/// 跑一条路由；返回 null = 一致，否则是可读差异。
Future<String?> _runCase(String route, String exe) async {
  final Directory temp = Directory.systemTemp.createTempSync(
    'tree_agent_equiv_',
  );
  final TreePaths paths = TreePaths(temp.path);
  final FileTreeStore store = FileTreeStore(paths);
  final _RouteCall call;
  switch (route) {
    case 'GET /api/agents/{agentId}/todos':
      store.putAgent(
        CoreAgent(
          id: 'agt',
          name: '等价夹具',
          createdAt: 1,
          updatedAt: 1,
          workspaceDir: p.join(temp.path, 'workspace'),
        ),
      );
      await store.flush();
      FileTodoStore(paths).write('agt', 'session_default', <TodoItem>[
        const TodoItem(
          id: 't1',
          content: '写读路径',
          status: 'in_progress',
          progress: 40,
        ),
        const TodoItem(id: 't2', content: '第二条', progress: 100),
      ]);
      call = const _RouteCall(
        concretePath: '/api/agents/agt/todos',
        query: <String, String>{'session_id': 'session_default'},
        pathParams: <String, String>{'agentId': 'agt'},
        agentId: 'agt',
      );
    default:
      return '没有为这条路由配置等价种子（加一个 case 再跑）';
  }

  final CoreServer server = await CoreServer.start(
    dataDir: temp.path,
    enableHeartbeat: false,
    streamChunkDelay: Duration.zero,
    store: store,
    todoStore: FileTodoStore(paths),
  );
  Process? process;
  StreamIterator<String>? iterator;
  final HttpClient client = HttpClient();
  try {
    final _HttpReply coreReply = await _coreHttp(server, client, call);
    final _PluginReply pluginReply = await _pluginDelegate(
      exe,
      temp.path,
      call,
      onStarted: (Process started) => process = started,
      onIterator: (StreamIterator<String> it) => iterator = it,
    );
    if (coreReply.status != pluginReply.status) {
      return '状态码不同：核心 ${coreReply.status} / 插件 ${pluginReply.status}';
    }
    if (coreReply.contentType != pluginReply.contentType) {
      return 'Content-Type 不同：核心 ${coreReply.contentType} / 插件 ${pluginReply.contentType}';
    }
    if (coreReply.body != pluginReply.body) {
      return 'body 不同：\n  核心：${coreReply.body}\n  插件：${pluginReply.body}';
    }
    return null;
  } finally {
    client.close(force: true);
    if (process != null) {
      process!.kill();
      await process!.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
    }
    await iterator?.cancel();
    await server.close();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶发文件占用：临时目录留给系统清理，不影响结论。
    }
  }
}

Future<_HttpReply> _coreHttp(
  CoreServer server,
  HttpClient client,
  _RouteCall call,
) async {
  final Uri uri = Uri.parse(
    'http://127.0.0.1:${server.port}${call.concretePath}',
  ).replace(queryParameters: call.query);
  final HttpClientRequest request = await client.getUrl(uri);
  request.headers.set('authorization', 'Bearer ${server.token}');
  final HttpClientResponse response = await request.close();
  final String body = await response.transform(utf8.decoder).join();
  return _HttpReply(
    status: response.statusCode,
    contentType: response.headers.contentType?.toString() ?? '',
    body: body,
  );
}

Future<_PluginReply> _pluginDelegate(
  String exe,
  String dataDir,
  _RouteCall call, {
  required void Function(Process process) onStarted,
  required void Function(StreamIterator<String> iterator) onIterator,
}) async {
  final Process process = await Process.start(exe, const <String>[]);
  onStarted(process);
  final StreamIterator<String> iterator = StreamIterator<String>(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  onIterator(iterator);

  Future<Map<String, dynamic>> waitForId(int id) async {
    while (await iterator.moveNext()) {
      final Map<String, dynamic> message =
          jsonDecode(iterator.current) as Map<String, dynamic>;
      if (message['id'] == id) return message;
    }
    throw StateError('插件 stdout 提前关闭（期待 id=$id）');
  }

  void send(Map<String, dynamic> frame) {
    process.stdin.writeln(jsonEncode(frame));
    unawaited(process.stdin.flush());
  }

  send(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'hello',
    'params': <String, dynamic>{'plugin_id': 'tree.agent'},
  });
  await waitForId(1);

  send(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': 2,
    'method': 'api/delegate',
    'params': <String, dynamic>{
      'method': 'GET',
      'path': call.concretePath,
      'params': <String, dynamic>{
        for (final MapEntry<String, String> entry in call.pathParams.entries)
          entry.key: entry.value,
      },
      'query': <String, dynamic>{
        for (final MapEntry<String, String> entry in call.query.entries)
          entry.key: entry.value,
      },
      'headers': <String, dynamic>{},
      'scope': <String, dynamic>{'agent_id': call.agentId},
      'workspace_dir': '',
      'data_dir': dataDir,
      'agent_id': call.agentId,
      'team_id': call.agentId,
      'request_id': 'equiv-1',
    },
  });
  final Map<String, dynamic> delegated = await waitForId(2);
  final Map<String, dynamic> result =
      (delegated['result'] as Map).cast<String, dynamic>();
  return _PluginReply(
    status: (result['status'] as num?)?.toInt() ?? -1,
    contentType: '${(result['headers'] as Map?)?['content-type'] ?? ''}',
    body: '${result['body'] ?? ''}',
  );
}

String? _resolveExe(String? explicit) {
  if (explicit != null && explicit.trim().isNotEmpty) {
    final String path = p.normalize(p.absolute(explicit.trim()));
    return File(path).existsSync() ? path : null;
  }
  for (final String candidate in <String>[
    p.join(Directory.current.path, '..', '..', 'build', 'plugins', 'tree_agent.exe'),
    p.join(Directory.current.path, 'build', 'plugins', 'tree_agent.exe'),
  ]) {
    final String path = p.normalize(candidate);
    if (File(path).existsSync()) return path;
  }
  return null;
}

String? _arg(List<String> args, String name) {
  for (int i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}

class _RouteCall {
  const _RouteCall({
    required this.concretePath,
    required this.query,
    required this.pathParams,
    required this.agentId,
  });

  final String concretePath;
  final Map<String, String> query;
  final Map<String, String> pathParams;
  final String agentId;
}

class _HttpReply {
  const _HttpReply({
    required this.status,
    required this.contentType,
    required this.body,
  });

  final int status;
  final String contentType;
  final String body;
}

class _PluginReply {
  const _PluginReply({
    required this.status,
    required this.contentType,
    required this.body,
  });

  final int status;
  final String contentType;
  final String body;
}
