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
  'GET /api/agents',
  'GET /api/agents/{agentId}',
  'GET /api/agents/{agentId}/teammates',
  'GET /api/conversations/{agentId}',
  'GET /api/agents/{agentId}/sessions',
  'GET /api/agents/{agentId}/sessions/{sessionId}',
  'GET /api/agents/{agentId}/todos',
  'GET /api/agents/{agentId}/subagents',
  'GET /api/models',
  'GET /api/agents/{agentId}/models-info',
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
  final String? declarationFailure = await _verifyDeclarations(exe);
  if (declarationFailure != null) {
    stderr.writeln('[verify] 申报表不一致：$declarationFailure');
    exitCode = 1;
    return;
  }
  stdout.writeln(
    '[OK] 申报表与等价用例表一致（${kImplementedRoutes.length} 条）',
  );
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

/// 校验插件的「收集站申报」与本工具的路由表**逐条一致**。
///
/// 为什么要这一条：申报了却没实现（或实现了却没申报、没进等价表）时，路由会
/// 在交接后悄悄 501/404。这里把三张表钉在一起：插件 kDeclaredRoutes ≡
/// [kImplementedRoutes]（等价用例表）。
Future<String?> _verifyDeclarations(String exe) async {
  final Process process = await Process.start(exe, const <String>[]);
  final StreamIterator<String> iterator = StreamIterator<String>(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  try {
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
      'method': 'station/request',
      'params': <String, dynamic>{
        'station_id': 'system.collect.api.routes',
        'payload': <String, dynamic>{},
      },
    });
    final Map<String, dynamic> reply = await waitForId(2);
    final Object? rawRoutes =
        reply['result']?['reply']?['payload']?['routes'];
    if (rawRoutes is! List) {
      return '收集站回包缺少 routes 列表：${reply['result']}';
    }
    final Set<String> declared = <String>{};
    for (final Object? item in rawRoutes) {
      if (item is! Map) return '路由申报项不是对象：$item';
      declared.add('${item['method']} ${item['pattern']}');
    }
    final Set<String> expected = kImplementedRoutes.toSet();
    final Set<String> missing = expected.difference(declared);
    final Set<String> extra = declared.difference(expected);
    if (missing.isNotEmpty) return '申报缺这些已实现路由：${missing.toList()}';
    if (extra.isNotEmpty) return '申报多出没有等价用例的路由：${extra.toList()}';
    return null;
  } finally {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
    await iterator.cancel();
  }
}

/// 跑一条路由；返回 null = 一致，否则是可读差异。
Future<String?> _runCase(String route, String exe) async {
  final Directory temp = Directory.systemTemp.createTempSync(
    'tree_agent_equiv_',
  );
  final TreePaths paths = TreePaths(temp.path);
  final FileTreeStore store = FileTreeStore(paths);
  final CoreSettings settings = CoreSettings();
  FileQuestionStore? questionStore;
  QuestionBroker? questionBroker;
  final _RouteCall call;
  switch (route) {
    case 'GET /api/agents':
      final int m0 = DateTime.parse(
        '2026-10-25T10:00:00.000',
      ).millisecondsSinceEpoch;
      final int m1 = DateTime.parse(
        '2026-10-25T10:00:01.000',
      ).millisecondsSinceEpoch;
      final int m2 = DateTime.parse(
        '2026-10-25T10:00:02.000',
      ).millisecondsSinceEpoch;
      final int m3 = DateTime.parse(
        '2026-10-25T10:00:03.000',
      ).millisecondsSinceEpoch;
      store.putAgent(
        CoreAgent(
          id: 'agt',
          name: '夹具',
          createdAt: m3,
          updatedAt: m3,
          modelId: 'm1',
          systemPrompt: '你是夹具',
        ),
      );
      store.putAgent(
        CoreAgent(
          id: 'agt_top',
          name: '指挥',
          createdAt: m1,
          updatedAt: m2,
          modelId: 'm1',
          systemPrompt: '你是指挥',
        ),
      );
      store.putAgent(
        CoreAgent(
          id: 'agt_m',
          name: '成员',
          createdAt: m0,
          updatedAt: m1,
          teamId: 'agt_top',
          parentAgentId: 'agt_top',
          level: 1,
          reviewStatus: 'pending_review',
          sshConfig: const SshConfig(host: '10.0.0.5'),
        ),
      );
      await store.flush();
      // 会话预览：只让默认会话有消息；最后一条合格消息是 agent 文本。
      int msgTime(String iso) =>
          DateTime.parse(iso).millisecondsSinceEpoch;
      store.appendMessage(
        CoreMessage(
          id: 'm1',
          agentId: 'agt',
          sessionId: 'session_default',
          role: 'user',
          content: '你好',
          kind: 'text',
          timestamp: msgTime('2026-10-25T10:00:06.000'),
        ),
      );
      store.appendMessage(
        CoreMessage(
          id: 'm2',
          agentId: 'agt',
          sessionId: 'session_default',
          role: 'agent',
          content: '这是预览',
          kind: 'text',
          timestamp: msgTime('2026-10-25T10:00:09.000'),
        ),
      );
      store.appendMessage(
        CoreMessage(
          id: 'm3',
          agentId: 'agt',
          sessionId: 'session_default',
          role: 'agent',
          content: '子回复',
          kind: 'text',
          subagentId: 'sub_1',
          timestamp: msgTime('2026-10-25T10:00:09.500'),
        ),
      );
      store.appendMessage(
        CoreMessage(
          id: 'm4',
          agentId: 'agt',
          sessionId: 'session_default',
          role: 'agent',
          content: '工具卡片',
          kind: 'tool',
          timestamp: msgTime('2026-10-25T10:00:09.900'),
        ),
      );
      await store.flush();
      call = const _RouteCall(
        concretePath: '/api/agents',
        query: <String, String>{},
        pathParams: <String, String>{},
        agentId: '',
      );
    case 'GET /api/agents/{agentId}':
      store.putAgent(
        CoreAgent(
          id: 'agt_m',
          name: '成员',
          createdAt: DateTime.parse(
            '2026-10-25T10:00:00.000',
          ).millisecondsSinceEpoch,
          updatedAt: DateTime.parse(
            '2026-10-25T10:00:01.000',
          ).millisecondsSinceEpoch,
          teamId: 'agt_top',
          parentAgentId: 'agt_top',
          level: 1,
          reviewStatus: 'pending_review',
          sshConfig: const SshConfig(host: '10.0.0.5'),
        ),
      );
      await store.flush();
      call = const _RouteCall(
        concretePath: '/api/agents/agt_m',
        query: <String, String>{},
        pathParams: <String, String>{'agentId': 'agt_m'},
        agentId: 'agt_m',
      );
    case 'GET /api/agents/{agentId}/sessions':
      await _seedSessions(store);
      call = const _RouteCall(
        concretePath: '/api/agents/agt/sessions',
        query: <String, String>{},
        pathParams: <String, String>{'agentId': 'agt'},
        agentId: 'agt',
      );
    case 'GET /api/agents/{agentId}/sessions/{sessionId}':
      await _seedSessions(store);
      call = const _RouteCall(
        concretePath: '/api/agents/agt/sessions/session_default',
        query: <String, String>{},
        pathParams: <String, String>{
          'agentId': 'agt',
          'sessionId': 'session_default',
        },
        agentId: 'agt',
      );
    case 'GET /api/agents/{agentId}/teammates':
      _writeModelFixtures(paths);
      FileSettingsSink(paths).load(settings);
      store.putAgent(
        CoreAgent(
          id: 'agt_top',
          name: '指挥',
          createdAt: DateTime.parse(
            '2026-10-25T10:00:01.000',
          ).millisecondsSinceEpoch,
          updatedAt: DateTime.parse(
            '2026-10-25T10:00:02.000',
          ).millisecondsSinceEpoch,
          modelId: 'm1',
          systemPrompt: '你是指挥',
        ),
      );
      store.putAgent(
        CoreAgent(
          id: 'agt_m',
          name: '成员',
          createdAt: DateTime.parse(
            '2026-10-25T10:00:00.000',
          ).millisecondsSinceEpoch,
          updatedAt: DateTime.parse(
            '2026-10-25T10:00:01.000',
          ).millisecondsSinceEpoch,
          teamId: 'agt_top',
          parentAgentId: 'agt_top',
          level: 1,
          reviewStatus: 'pending_review',
          reasoningEffort: 'low',
          maxSeqlenOverride: 16000,
          thinkingOverride: false,
        ),
      );
      store.putAgent(
        CoreAgent(
          id: 'agt_m2',
          name: '执行',
          createdAt: DateTime.parse(
            '2026-10-25T10:00:04.000',
          ).millisecondsSinceEpoch,
          updatedAt: DateTime.parse(
            '2026-10-25T10:00:04.000',
          ).millisecondsSinceEpoch,
          teamId: 'agt_top',
          parentAgentId: 'agt_m',
          level: 2,
          role: '执行',
          duty: '跑测试',
          modelId: 'm2',
          reviewStatus: 'approved',
          workspaceId: 'ws_m2',
        ),
      );
      await store.flush();
      call = const _RouteCall(
        concretePath: '/api/agents/agt_top/teammates',
        query: <String, String>{},
        pathParams: <String, String>{'agentId': 'agt_top'},
        agentId: 'agt_top',
      );
    case 'GET /api/conversations/{agentId}':
      await _seedSessions(store);
      questionStore = FileQuestionStore(paths);
      questionStore.add(
        QuestionRecord(
          qid: 'q1',
          agentId: 'agt',
          sessionId: 'session_default',
          question: '选哪个',
          options: <String>['A', 'B'],
          answers: <String>['B'],
          answer: 'B',
          status: 'answered',
          createdAt: DateTime.parse(
            '2026-10-25T10:00:07.000',
          ).millisecondsSinceEpoch,
        ),
      );
      await questionStore.flush();
      questionBroker = QuestionBroker(
        questions: questionStore,
        transcript: store,
        broadcast: (Map<String, dynamic> _) {},
      );
      call = const _RouteCall(
        concretePath: '/api/conversations/agt',
        query: <String, String>{'session_id': 'session_default'},
        pathParams: <String, String>{'agentId': 'agt'},
        agentId: 'agt',
      );
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
    case 'GET /api/agents/{agentId}/subagents':
      final CoreAgent owner = CoreAgent(
        id: 'agt',
        name: '等价夹具',
        createdAt: 1,
        updatedAt: 1,
        workspaceDir: p.join(temp.path, 'workspace'),
      );
      store.putAgent(owner);
      await store.flush();
      store.putSubagent(
        CoreSubagent(
          id: 'sub_1',
          name: '临时员工',
          ownerAgentId: 'agt',
          sessionId: 'session_default',
          parentId: 'agt',
          level: 1,
          scope: '整理日志',
          runCount: 2,
          createdAt: 1761360000000,
          updatedAt: 1761360005000,
          agent: CoreAgent(
            id: 'sub_1',
            name: '临时员工',
            createdAt: 1761360000000,
            updatedAt: 1761360005000,
            parentAgentId: 'agt',
          ),
        ),
      );
      store.putSubagent(
        CoreSubagent(
          id: 'sub_2',
          name: '下级',
          ownerAgentId: 'agt',
          sessionId: 'session_default',
          parentId: 'sub_1',
          level: 2,
          createdAt: 1761360100000,
          updatedAt: 1761360100000,
          agent: CoreAgent(
            id: 'sub_2',
            name: '下级',
            createdAt: 1761360100000,
            updatedAt: 1761360100000,
            parentAgentId: 'sub_1',
            level: 2,
          ),
        ),
      );
      await store.flush();
      call = const _RouteCall(
        concretePath: '/api/agents/agt/subagents',
        query: <String, String>{'session_id': 'session_default'},
        pathParams: <String, String>{'agentId': 'agt'},
        agentId: 'agt',
      );
    case 'GET /api/models':
      _writeModelFixtures(paths);
      FileSettingsSink(paths).load(settings);
      call = const _RouteCall(
        concretePath: '/api/models',
        query: <String, String>{},
        pathParams: <String, String>{},
        agentId: '',
      );
    case 'GET /api/agents/{agentId}/models-info':
      _writeModelFixtures(paths);
      FileSettingsSink(paths).load(settings);
      store.putAgent(
        CoreAgent(
          id: 'agt',
          name: '等价夹具',
          createdAt: 1,
          updatedAt: 1,
          modelId: 'm1',
          systemPrompt: '你是夹具',
          workspaceDir: p.join(temp.path, 'workspace'),
          reasoningEffort: 'high',
          maxSeqlenOverride: 32000,
          maxOutputTokens: 8192,
          compressThreshold: 0.8,
          thinkingOverride: true,
        ),
      );
      await store.flush();
      call = const _RouteCall(
        concretePath: '/api/agents/agt/models-info',
        query: <String, String>{},
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
    settings: settings,
    teamService: TeamService(store: store, settings: settings),
    questions: questionBroker,
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

/// 会话夹具：默认会话四条消息（user / agent 文本 / 临时员工 / 工具）+ 第二个会话。
Future<void> _seedSessions(FileTreeStore store) async {
  store.putAgent(
    CoreAgent(
      id: 'agt',
      name: '夹具',
      createdAt: 1,
      updatedAt: 1,
      modelId: 'm1',
    ),
  );
  await store.flush();
  int t(String iso) => DateTime.parse(iso).millisecondsSinceEpoch;
  store.appendMessage(
    CoreMessage(
      id: 'm1',
      agentId: 'agt',
      sessionId: 'session_default',
      role: 'user',
      content: '你好',
      kind: 'text',
      timestamp: t('2026-10-25T10:00:06.000'),
    ),
  );
  store.appendMessage(
    CoreMessage(
      id: 'q1',
      agentId: 'agt',
      sessionId: 'session_default',
      role: 'agent',
      content: '选哪个',
      kind: 'ask_user_question',
      timestamp: t('2026-10-25T10:00:07.000'),
    ),
  );
  store.appendMessage(
    CoreMessage(
      id: 'm2',
      agentId: 'agt',
      sessionId: 'session_default',
      role: 'agent',
      content: '这是预览',
      kind: 'text',
      timestamp: t('2026-10-25T10:00:09.000'),
    ),
  );
  store.appendMessage(
    CoreMessage(
      id: 'm3',
      agentId: 'agt',
      sessionId: 'session_default',
      role: 'agent',
      content: '子回复',
      kind: 'text',
      subagentId: 'sub_1',
      timestamp: t('2026-10-25T10:00:09.500'),
    ),
  );
  store.appendMessage(
    CoreMessage(
      id: 'm4',
      agentId: 'agt',
      sessionId: 'session_default',
      role: 'agent',
      content: '工具卡片',
      kind: 'tool',
      timestamp: t('2026-10-25T10:00:09.900'),
    ),
  );
  store.createSession('agt', title: '旧会话', sessionId: 'ses_old');
  store.appendMessage(
    CoreMessage(
      id: 'm0',
      agentId: 'agt',
      sessionId: 'ses_old',
      role: 'agent',
      content: '旧的预览',
      kind: 'text',
      timestamp: t('2026-10-25T10:00:04.000'),
    ),
  );
  await store.flush();
}

/// 模型池夹具：与 selftest 同一份内容（脱敏 / 默认档位 / token_scale / 排序）。
void _writeModelFixtures(TreePaths paths) {
  final Directory dir = Directory(paths.modelsDir)..createSync(recursive: true);
  File(p.join(dir.path, 'm1.yaml')).writeAsStringSync(
    'model_id: m1\n'
    'name: 模型一\n'
    'base_url: https://api.example.com/v1\n'
    'api_key: sk-secret\n'
    'thinking: true\n'
    'if_vision: false\n'
    'reasoning_effort: high\n'
    'reasoning_effort_options: [low, high]\n'
    'max_seqlen: 64000\n'
    'max_output_tokens: 8192\n'
    'token_scale: 2.5\n'
    'longest_session_tokens: 12000\n',
  );
  File(p.join(dir.path, 'm2.yaml')).writeAsStringSync(
    'model_id: m2\n'
    'base_url: http://127.0.0.1:8080/\n',
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
