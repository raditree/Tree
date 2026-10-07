import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/execute_mounts.dart';
import 'package:tree_core/src/plugin/station_ids.dart';
import 'package:tree_core/src/plugin/station_instance.dart';
import 'package:tree_core/src/plugin/station_points.dart';
import 'package:tree_core/src/plugin/station_runtime.dart';
import 'package:tree_core/src/plugin/station_scope.dart';
import 'package:tree_core/src/plugin/stations.dart';
import 'package:tree_core/src/tool/tool_runner.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// **执行站点位化新增的三条命令**（2026-10-01）：
/// `llm.call` / `tool.call` / `session.rename`。
///
/// 与既有 `plugin_execute_mounts_test.dart` 的分工：那里锁的是首命令集（fs /
/// terminal / agent / ui）与四元组隔离；这里只覆盖**新命令**的接线点语义——
/// 参数怎么透传、payload 什么形状、`relay` 开关与 `response_format` 标记、
/// 空标题为什么被拒、**未接线时是否可读地失败**，以及四元组 fail-closed 是否
/// 同样管住这三条（挂载位置不因为命令是"新的"而放松归属校验）。
///
/// 三条命令的依赖（`llmCaller` / `toolCaller` / `sessionRenamer`）全部是可注入
/// 字段，因此这里注入**假实现**：命令层的语义与真实 LLM / 工具 / 存储无关。
void main() {
  late Directory temp;
  late String workspace;
  late StationHub hub;
  late List<ExecuteStationMounts> opened;

  late List<Map<String, dynamic>> llmCalls;
  late List<Map<String, dynamic>> toolCalls;
  late List<Map<String, dynamic>> renameCalls;
  late List<String> sshReconnectCalls;
  late Map<String, dynamic> sshReconnectResult;

  const String agent = 'agt_1';
  const String team = 'team-1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_exec_new_cmd_');
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
    hub = StationHub(
      storePath: p.join(temp.path, 'config', 'stations.yaml'),
      heartbeatInterval: const Duration(milliseconds: 50),
      missThreshold: 3,
      livenessProbeInterval: const Duration(milliseconds: 10),
    );
    opened = <ExecuteStationMounts>[];
    llmCalls = <Map<String, dynamic>>[];
    toolCalls = <Map<String, dynamic>>[];
    renameCalls = <Map<String, dynamic>>[];
    sshReconnectCalls = <String>[];
    sshReconnectResult = <String, dynamic>{'ok': true, 'stale': false};
  });

  tearDown(() async {
    for (final ExecuteStationMounts mounts in opened) {
      await mounts.close();
    }
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  /// 挂载位置：工作空间固定在临时目录；归属 / 模式可注入；三条新命令的入口可注入。
  ExecuteStationMounts mounts({bool wired = true}) {
    final ExecuteStationMounts built = ExecuteStationMounts(
      ioFor: (String agentId) async => LocalWorkspaceIO(workspace),
      agentTeamOf: (String agentId) => agentId == agent ? team : '',
      agentModeOf: (String agentId) =>
          agentId == agent ? StationModeKey.local : '',
      llmCaller: !wired
          ? null
          : ({
              required String agentId,
              required String sessionId,
              List<Object?>? messages,
              String? prompt,
              String? system,
              String? model,
              double? temperature,
              int? maxTokens,
              List<Object?>? tools,
              String? responseFormat,
            }) async {
              llmCalls.add(<String, dynamic>{
                'agent_id': agentId,
                'messages': messages,
                'prompt': prompt,
                'system': system,
                'model': model,
                'temperature': temperature,
                'max_tokens': maxTokens,
                'tools': tools,
                'response_format': responseFormat,
              });
              if (prompt == '端点会拒绝') {
                return <String, dynamic>{'error': '端点不支持 json_object'};
              }
              if (prompt == '正文不是 JSON') {
                // 与生产实现（LlmJsonCaller 解析失败分支）同一口径：**失败但带原文**。
                return <String, dynamic>{
                  'error': '模型正文不是合法 JSON（本次按 text 形态发送：未发 response_format…）',
                  'error_kind': 'json_parse',
                  'text': '{"background": "半截正文',
                  'text_length': 19,
                  'truncated_suspect': true,
                  'model': 'agent-model',
                };
              }
              // 与生产实现（LlmJsonCaller）同一口径：model 为空 = 复用目标 agent 的模型
              final String requested = (model ?? '').trim();
              return <String, dynamic>{
                'ok': true,
                'json': <String, dynamic>{'answer': 42},
                'text': '{"answer": 42}',
                'model': requested.isEmpty ? 'agent-model' : requested,
                'usage': <String, dynamic>{'prompt_tokens': 3},
              };
            },
      toolCaller: !wired
          ? null
          : ({
              required String agentId,
              required String sessionId,
              required String tool,
              required Map<String, dynamic> arguments,
              required String sourcePluginId,
              required bool relay,
            }) async {
              toolCalls.add(<String, dynamic>{
                'agent_id': agentId,
                'session_id': sessionId,
                'tool': tool,
                'arguments': arguments,
                'source_plugin_id': sourcePluginId,
                'relay': relay,
              });
              return ToolOutcome('工具结果：$tool', isError: tool == 'boom');
            },
      sessionRenamer: !wired
          ? null
          : ({
              required String agentId,
              required String sessionId,
              required String title,
            }) async {
              renameCalls.add(<String, dynamic>{
                'agent_id': agentId,
                'session_id': sessionId,
                'title': title,
              });
              if (title == '会失败') {
                return <String, dynamic>{'error': '会话不存在'};
              }
              return <String, dynamic>{
                'renamed': true,
                'title': title,
                'session_id': sessionId,
              };
            },
      // `ssh.reconnect`：重建远端链路的入口（生产 = WorkspaceToolRunner.reconnectSshLink）。
      // 三种结局（成功 / 该 agent 不是 SSH / 重建失败）都由这个假实现如实产出。
      sshReconnector: !wired
          ? null
          : (String agentId) async {
              sshReconnectCalls.add(agentId);
              return sshReconnectResult;
            },
    );
    opened.add(built);
    return built;
  }

  /// 把挂载位置接到**它自己那族的点位**上，并返回「命令 → 所属点位」的解析器。
  ExecuteStation point(String command) {
    final StationPointSpec spec = StationPoints.ownerOfCommand(command)!;
    final ExecuteStation station = hub.executePointFor(spec.id)!;
    expect(
      hub.executeForCommand(command),
      isNotNull,
      reason: '命令 $command 必须属于某个执行站点位',
    );
    return station;
  }

  void wire(ExecuteStationMounts mounts) {
    for (final StationPointSpec spec in StationPoints.executes) {
      final ExecuteStation station = hub.executePointFor(spec.id)!;
      expect(
        mounts.mountInto(station),
        isNull,
        reason: '点位 ${spec.id}（${spec.commands.join('、')}）都应挂载成功',
      );
    }
  }

  StationScope scope({
    String teamId = team,
    String agentId = '',
    String modeKey = StationModeKey.local,
  }) => StationScope(teamId: teamId, agentId: agentId, modeKey: modeKey);

  /// 跑一条命令（命令自动落到它所属的点位；默认带上目标 agent）。
  Future<StationCommandResult> run(
    String command, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
    StationScope? scoped,
    String pluginId = 'sample',
  }) => point(command).execute(
    command: command,
    scope: scoped ?? scope(),
    arguments: <String, dynamic>{'agent_id': agent, ...arguments},
    sourcePluginId: pluginId,
  );

  // ── llm.call ─────────────────────────────────────────────────────────

  test('llm.call：参数透传到注入的调用器，payload 带 response_format=json_object', () async {
    wire(mounts());

    final StationCommandResult result = await run(
      'llm.call',
      arguments: <String, dynamic>{
        'messages': <Object?>[
          <String, dynamic>{'role': 'user', 'content': '你好'},
        ],
        'system': '你是助手',
        'model': 'm1',
        'temperature': 0.3,
        'max_tokens': 128,
      },
    );
    expect(result.ok, isTrue, reason: result.error);
    expect(result.mountId, 'core.execute.llm.call');

    final Map<String, dynamic> call = llmCalls.single;
    expect(call['agent_id'], agent, reason: '必须复用目标 agent（模型解析在核心侧）');
    expect(call['messages'], <Object?>[
      <String, dynamic>{'role': 'user', 'content': '你好'},
    ]);
    expect(call['prompt'], isNull, reason: '给了 messages 就不该再传 prompt');
    expect(call['system'], '你是助手');
    expect(call['model'], 'm1');
    expect(call['temperature'], 0.3);
    expect(call['max_tokens'], 128);
    expect(
      call['response_format'],
      isNull,
      reason: '没给 response_format ⇒ 走站点缺省（调用器收到 null，不替插件擅自改成别的值）',
    );

    final Map<String, dynamic> payload =
        result.payload! as Map<String, dynamic>;
    expect(payload['ok'], isTrue);
    expect(payload['json'], <String, dynamic>{'answer': 42});
    expect(payload['text'], '{"answer": 42}');
    expect(payload['model'], 'm1');
    expect(payload['usage'], <String, dynamic>{'prompt_tokens': 3});
    expect(
      payload['response_format'],
      'json_object',
      reason: '站点处**硬设** JSON 返回形式：插件不能在命令层把它改掉',
    );
    expect(payload['agent_id'], agent);

    // prompt 形态（二选一）：没有 messages 时传 prompt
    final StationCommandResult byPrompt = await run(
      'llm.call',
      arguments: <String, dynamic>{'prompt': '给我 JSON'},
    );
    expect(byPrompt.ok, isTrue, reason: byPrompt.error);
    expect(llmCalls.last['prompt'], '给我 JSON');
    expect(llmCalls.last['messages'], isNull);
    expect((byPrompt.payload! as Map<String, dynamic>)['model'], 'agent-model');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('llm.call：入参非法 / 调用器报错都是可读失败（不静默）', () async {
    wire(mounts());

    final StationCommandResult noInput = await run('llm.call');
    expect(noInput.ok, isFalse);
    expect(noInput.error, contains('messages'));
    expect(noInput.error, contains('prompt'));

    final StationCommandResult badMessages = await run(
      'llm.call',
      arguments: <String, dynamic>{'messages': 'not-a-list'},
    );
    expect(badMessages.ok, isFalse);
    expect(badMessages.error, contains('必须是数组'));

    // 端点不支持 JSON 形式：如实失败，不静默去掉 response_format 重试
    final StationCommandResult upstream = await run(
      'llm.call',
      arguments: <String, dynamic>{'prompt': '端点会拒绝'},
    );
    expect(upstream.ok, isFalse);
    expect(upstream.error, contains('端点不支持 json_object'));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('llm.call：解析失败也必须把原文（text）经执行站回给插件', () async {
    // 这一跳是**真机踩空过的地方**：`failedWith(error, payload)` 的载荷曾经在
    // `StationInstance.execute` 的失败分支被丢掉 ⇒ 插件拿到 `payload=null`、
    // 报"原文 0 字"、连本地修复的机会都没有 ⇒ 那笔已付费的总结调用整包白扔
    // （docs/known-issues.md #31「真机复现」）。
    wire(mounts());

    final StationCommandResult result = await run(
      'llm.call',
      arguments: <String, dynamic>{
        'prompt': '正文不是 JSON',
        'response_format': 'text',
      },
    );
    expect(result.ok, isFalse, reason: '调用确实是失败的');
    expect(result.error, contains('不是合法 JSON'));

    final Map<String, dynamic> payload =
        result.payload! as Map<String, dynamic>;
    expect(
      payload['text'],
      '{"background": "半截正文',
      reason: '模型正文原文必须原样带出去：插件靠它本地修复 / 交给修复调用',
    );
    expect(payload['error_kind'], 'json_parse');
    expect(payload['text_length'], 19);
    expect(payload['truncated_suspect'], isTrue);
    expect(
      llmCalls.single['response_format'],
      'text',
      reason: '失败回包不影响入参透传（插件的 text 形态仍原样传给调用器）',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('llm.call：response_format 可显式选 text（复用对话前缀的正路），非法值可读失败', () async {
    wire(mounts());
    final List<Object?> oneUser = <Object?>[
      <String, dynamic>{'role': 'user', 'content': '你好'},
    ];

    // ① 显式 text：透传给调用器，并在回包里 echo **生效值**
    final StationCommandResult text = await run(
      'llm.call',
      arguments: <String, dynamic>{
        'messages': oneUser,
        'response_format': 'text',
      },
    );
    expect(text.ok, isTrue, reason: text.error);
    expect(llmCalls.single['response_format'], 'text', reason: '原样透传给调用器');
    expect(
      (text.payload! as Map<String, dynamic>)['response_format'],
      'text',
      reason: '回包 echo 的是生效值（不再是写死的 json_object）',
    );

    // ② OpenAI 形状的对象写法等价
    final StationCommandResult asObject = await run(
      'llm.call',
      arguments: <String, dynamic>{
        'messages': oneUser,
        'response_format': <String, dynamic>{'type': 'json_object'},
      },
    );
    expect(asObject.ok, isTrue, reason: asObject.error);
    expect(llmCalls.last['response_format'], 'json_object');

    // ③ 不认识的值：**进调用器之前**就如实失败（写了错值却以为生效是最难查的一类问题）
    final StationCommandResult bad = await run(
      'llm.call',
      arguments: <String, dynamic>{
        'messages': oneUser,
        'response_format': 'xml',
      },
    );
    expect(bad.ok, isFalse);
    expect(bad.error, contains('response_format'));
    expect(bad.error, contains('text'));
    expect(llmCalls, hasLength(2), reason: '非法值不得落到调用器');
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── tool.call ────────────────────────────────────────────────────────

  test('tool.call：参数 / relay 开关 / is_error 透传，payload 形状稳定', () async {
    wire(mounts());

    final StationCommandResult result = await run(
      'tool.call',
      arguments: <String, dynamic>{
        'tool': 'read',
        'arguments': <String, dynamic>{'path': 'notes/a.txt'},
        'session_id': 'ses_9',
      },
    );
    expect(result.ok, isTrue, reason: result.error);
    expect(result.mountId, 'core.execute.tool.call');

    final Map<String, dynamic> call = toolCalls.single;
    expect(call['agent_id'], agent);
    expect(call['session_id'], 'ses_9', reason: 'session_id 由命令参数指定');
    expect(call['tool'], 'read');
    expect(call['arguments'], <String, dynamic>{'path': 'notes/a.txt'});
    expect(call['source_plugin_id'], 'sample', reason: '工具层要知道是谁发起的');
    expect(call['relay'], isFalse, reason: '默认绕开中转 / 广播（防插件自锁）');

    final Map<String, dynamic> payload =
        result.payload! as Map<String, dynamic>;
    expect(payload['tool'], 'read');
    expect(payload['result'], '工具结果：read');
    expect(payload['is_error'], isFalse);
    expect(payload['relayed'], isFalse);
    expect(payload['agent_id'], agent);
    expect(payload['session_id'], 'ses_9');

    // relay: true ⇒ 这次调用也走工具中转与广播（audit 自己）
    final StationCommandResult relayed = await run(
      'tool.call',
      arguments: <String, dynamic>{
        'tool': 'write',
        'arguments': <String, dynamic>{'path': 'b.txt', 'content': 'x'},
        'relay': true,
      },
    );
    expect(relayed.ok, isTrue, reason: relayed.error);
    expect(toolCalls.last['relay'], isTrue);
    expect(
      (relayed.payload! as Map<String, dynamic>)['relayed'],
      isTrue,
      reason: 'relayed 必须如实回报，插件才知道这次有没有走站点',
    );

    // 工具自身失败 ⇒ **命令仍成功**（ok:true），失败体现在 is_error + result 文本
    final StationCommandResult failed = await run(
      'tool.call',
      arguments: <String, dynamic>{'tool': 'boom'},
    );
    expect(failed.ok, isTrue, reason: '命令跑起来了：工具失败不该伪装成"命令没跑起来"');
    final Map<String, dynamic> failedPayload =
        failed.payload! as Map<String, dynamic>;
    expect(failedPayload['is_error'], isTrue);
    expect(failedPayload['result'], '工具结果：boom');

    // 入参非法
    final StationCommandResult noTool = await run('tool.call');
    expect(noTool.ok, isFalse);
    expect(noTool.error, contains('tool'));
    final StationCommandResult badArgs = await run(
      'tool.call',
      arguments: <String, dynamic>{
        'tool': 'read',
        'arguments': 'not-an-object',
      },
    );
    expect(badArgs.ok, isFalse);
    expect(badArgs.error, contains('必须是对象'));

    // name / args 是文档里的等价写法（别名）
    final StationCommandResult aliased = await run(
      'tool.call',
      arguments: <String, dynamic>{
        'name': 'read',
        'args': <String, dynamic>{'path': 'c.txt'},
      },
    );
    expect(aliased.ok, isTrue, reason: aliased.error);
    expect(toolCalls.last['tool'], 'read');
    expect(toolCalls.last['arguments'], <String, dynamic>{'path': 'c.txt'});
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── session.rename ───────────────────────────────────────────────────

  test('session.rename：title 透传并即时回报；空标题被拒（不静默成功）', () async {
    wire(mounts());

    final StationCommandResult result = await run(
      'session.rename',
      arguments: <String, dynamic>{'title': '新标题', 'session_id': 'ses_7'},
    );
    expect(result.ok, isTrue, reason: result.error);
    expect(result.mountId, 'core.execute.session.rename');
    expect(renameCalls.single, <String, dynamic>{
      'agent_id': agent,
      'session_id': 'ses_7',
      'title': '新标题',
    });
    final Map<String, dynamic> payload =
        result.payload! as Map<String, dynamic>;
    expect(payload['renamed'], isTrue);
    expect(payload['title'], '新标题');
    expect(payload['session_id'], 'ses_7');
    expect(payload['agent_id'], agent);

    // 空标题：store 层语义是"空标题 = 不改名"，命令层绝不能静默返回成功
    for (final Object? empty in <Object?>['', '   ', null]) {
      final StationCommandResult denied = await run(
        'session.rename',
        arguments: <String, dynamic>{'title': empty},
      );
      expect(denied.ok, isFalse, reason: '空标题必须显式失败（收到 ${empty.runtimeType}）');
      expect(denied.error, contains('title'));
    }
    expect(renameCalls, hasLength(1), reason: '被拒的命令不得落到实现');

    // name 是文档里的等价写法
    final StationCommandResult aliased = await run(
      'session.rename',
      arguments: <String, dynamic>{'name': '别名标题'},
    );
    expect(aliased.ok, isTrue, reason: aliased.error);
    expect(renameCalls.last['title'], '别名标题');
    expect(
      renameCalls.last['session_id'],
      'session_default',
      reason: '没给 session_id 时落到默认会话（与既有投递口径一致）',
    );

    // 实现报错原样回到调用方
    final StationCommandResult failed = await run(
      'session.rename',
      arguments: <String, dynamic>{'title': '会失败'},
    );
    expect(failed.ok, isFalse);
    expect(failed.error, contains('会话不存在'));
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── ssh.reconnect ────────────────────────────────────────────────────

  test('ssh.reconnect：目标 agent 透传并即时回报；失败原样回到调用方（不假装成功）', () async {
    wire(mounts());

    final StationCommandResult result = await run('ssh.reconnect');
    expect(result.ok, isTrue, reason: result.error);
    expect(result.mountId, 'core.execute.ssh.reconnect');
    expect(sshReconnectCalls, <String>[agent]);
    final Map<String, dynamic> payload =
        result.payload! as Map<String, dynamic>;
    expect(payload['ok'], isTrue);
    expect(payload['agent_id'], agent);
    expect(payload['stale'], isFalse);

    // 重建失败（注入方如实报 error）⇒ 命令失败，原因原样带回
    sshReconnectResult = <String, dynamic>{
      'ok': false,
      'error': 'SSH 重连失败：主机不可达',
    };
    final StationCommandResult failed = await run('ssh.reconnect');
    expect(failed.ok, isFalse);
    expect(failed.error, contains('主机不可达'));
    expect(sshReconnectCalls, hasLength(2), reason: '失败也要真的落到实现上');

    // 「该 agent 不是 SSH 工作空间」也是**失败**（绝不能把它说成成功）
    sshReconnectResult = <String, dynamic>{
      'ok': false,
      'not_ssh': true,
      'error': '该 agent 未使用 SSH（本地工作空间），没有可重连的远端链路',
    };
    final StationCommandResult notSsh = await run('ssh.reconnect');
    expect(notSsh.ok, isFalse);
    expect(notSsh.error, contains('没有可重连的远端链路'));
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── 未接线 ───────────────────────────────────────────────────────────

  test('未接线：四条命令各自显式失败（ok:false，error 含「未接线」）', () async {
    wire(mounts(wired: false));

    final Map<String, Map<String, dynamic>> args =
        <String, Map<String, dynamic>>{
          'llm.call': <String, dynamic>{'prompt': '你好'},
          'tool.call': <String, dynamic>{'tool': 'read'},
          'session.rename': <String, dynamic>{'title': '标题'},
          'ssh.reconnect': <String, dynamic>{},
        };
    for (final MapEntry<String, Map<String, dynamic>> entry in args.entries) {
      final StationCommandResult result = await run(
        entry.key,
        arguments: entry.value,
      );
      expect(result.ok, isFalse, reason: '${entry.key} 未接线时必须失败');
      expect(
        result.error,
        contains('未接线'),
        reason: '${entry.key} 的失败原因要 readable：${result.error}',
      );
      expect(
        result.mountId,
        contains('core.execute'),
        reason: '失败发生在挂载位置内部（命令确实被路由到了）',
      );
    }
    expect(llmCalls, isEmpty);
    expect(toolCalls, isEmpty);
    expect(renameCalls, isEmpty);
    expect(sshReconnectCalls, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── 四元组 fail-closed ───────────────────────────────────────────────

  test('四元组 fail-closed：跨 team / 跨模式 / 缺 team / agent 不一致都拒绝这四条命令', () async {
    wire(mounts());

    final Map<String, StationScope> badScopes = <String, StationScope>{
      '跨 team': scope(teamId: 'team-2'),
      '跨模式': scope(modeKey: StationModeKey.ssh),
      '缺 team': scope(teamId: ''),
      'agent 不一致': scope(agentId: 'agt_2'),
    };
    final List<String> commands = <String>[
      'llm.call',
      'tool.call',
      'session.rename',
      'ssh.reconnect',
    ];
    final Map<String, Map<String, dynamic>> args =
        <String, Map<String, dynamic>>{
          'llm.call': <String, dynamic>{'prompt': '你好'},
          'tool.call': <String, dynamic>{'tool': 'read'},
          'session.rename': <String, dynamic>{'title': '标题'},
          'ssh.reconnect': <String, dynamic>{},
        };

    for (final MapEntry<String, StationScope> entry in badScopes.entries) {
      for (final String command in commands) {
        final StationCommandResult result = await run(
          command,
          arguments: args[command]!,
          scoped: entry.value,
        );
        expect(
          result.ok,
          isFalse,
          reason: '$command 在「${entry.key}」的 scope 下必须被拒（fail-closed）',
        );
        expect(result.error, isNotEmpty, reason: '$command 必须给可读原因');
        // 三种拒绝原因分别对应三种不可证明：跨 team / 跨模式 / 缺 team / 跨 scope
        expect(
          result.error,
          anyOf(
            contains('跨 team'),
            contains('跨模式'),
            contains('缺少 team_id'),
            contains('跨 scope'),
          ),
          reason: '$command 的拒绝原因要说明是哪一维不成立：${result.error}',
        );
      }
    }

    // 归属根本证明不了（agent 不存在）⇒ 同样拒绝
    for (final String command in commands) {
      final StationCommandResult ghost = await run(
        command,
        arguments: <String, dynamic>{'agent_id': 'ghost', ...args[command]!},
      );
      expect(ghost.ok, isFalse, reason: '$command 对不存在的 agent 必须拒绝');
      expect(ghost.error, contains('拒绝执行'));
    }

    // fail-closed 的关键推论：一次都没落到实现上
    expect(llmCalls, isEmpty, reason: '被隔离拒绝的命令绝不能调用 LLM');
    expect(toolCalls, isEmpty, reason: '被隔离拒绝的命令绝不能执行工具');
    expect(renameCalls, isEmpty, reason: '被隔离拒绝的命令绝不能改会话名');
    expect(sshReconnectCalls, isEmpty, reason: '被隔离拒绝的命令绝不能重建链路');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('新命令与首命令集一样按命令族分点位（llm / tool / session / ssh 四个点位）', () {
    wire(mounts());
    expect(point('llm.call').id, StationHubIds.executeLlm);
    expect(point('tool.call').id, StationHubIds.executeTool);
    expect(point('session.rename').id, StationHubIds.executeSession);
    expect(point('ssh.reconnect').id, StationHubIds.executeSsh);
    expect(
      point('llm.call').mounts().map((StationCommandMount m) => m.command),
      <String>['llm.call'],
      reason: '每个执行站点位只挂自己那族的命令',
    );
  });
}
