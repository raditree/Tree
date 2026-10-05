import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// **内置压缩插件（真 Python 进程）的端到端契约**。
///
/// 为什么必须真进程：压缩插件不是"回一段文本"，它要经 `station/command` 调
/// `llm.call` / `fs.read` / `tool.call` 三个执行站命令，再把结果拼成一份**整份新上下文**
/// 回填。这条链路跨了 插件进程 → 插件总线 → 执行站 → 四项假依赖 → 回填 → 落库，
/// 任何一环的报文形状错了都只表现为"压缩没发生"（静默），所以这里全程真进程 + 真总线。
///
/// 覆盖：
/// 1. 接管成功：**原料 = 引擎口径的 `request.messages`**（不是落库全量）⇒ 总结调用
///    的前缀与对话逐字一致（缓存可命中）、`tools` 原样透传；回包 = 摘要侧 + **原样抄回
///    的尾部**，`covered_message_count` = 原文总条数；
/// 2. `llm.call` 失败 ⇒ 插件回 null ⇒ 核心回退内置 compact（内容不丢）。
void main() {
  late Directory temp;
  late String workspace;
  late List<PluginBus> buses;
  late List<Map<String, dynamic>> llmCalls;
  int busSeq = 0;

  const String team = 'team-1';

  /// 真插件脚本（测试 cwd = packages/tree_core ⇒ 上两级是仓根）。
  String compactScript() => p.normalize(
    p.join(
      Directory.current.path,
      '..',
      '..',
      'examples',
      'plugins',
      'compact_plugin.py',
    ),
  );

  String pythonCommand() => Platform.isWindows ? 'python' : 'python3';

  bool pythonAvailable() {
    try {
      return Process.runSync(pythonCommand(), <String>['--version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  final String? noPython = pythonAvailable()
      ? null
      : '本机没有 ${pythonCommand()}，跳过内置压缩插件的真进程用例';

  /// 引擎口径的线形前缀（真核心里由 `LlmAgentEngine.wireRequestFor` 产出）：
  /// 系统提示词 + 交替的 user/assistant；**最后一条 user 之后是尾部**。
  const List<Map<String, dynamic>> wireMessages = <Map<String, dynamic>>[
    <String, dynamic>{'role': 'system', 'content': '你是一个助手'},
    <String, dynamic>{'role': 'user', 'content': '第一轮要求'},
    <String, dynamic>{'role': 'assistant', 'content': '第一轮回答'},
    <String, dynamic>{'role': 'user', 'content': '第二轮要求'},
    <String, dynamic>{'role': 'assistant', 'content': '第二轮回答'},
    <String, dynamic>{'role': 'user', 'content': '第三轮要求'},
    <String, dynamic>{'role': 'assistant', 'content': '第三轮回答'},
  ];
  const int wireCut = 5; // 切点：'第三轮要求' 的下标

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_compact_plugin_');
    workspace = p.join(temp.path, 'ws');
    Directory(p.join(workspace, 'lib')).createSync(recursive: true);
    Directory(p.join(workspace, 'docs')).createSync(recursive: true);
    File(p.join(workspace, 'lib', 'auth.dart')).writeAsStringSync(
      'class Auth {\n  // session 实现\n}\n',
    );
    File(p.join(workspace, 'docs', 'plan.md')).writeAsStringSync('# 计划\n1. 改 JWT\n');
    buses = <PluginBus>[];
    llmCalls = <Map<String, dynamic>>[];
    busSeq = 0;
  });

  tearDown(() async {
    for (final PluginBus bus in buses) {
      await bus.close();
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

  String slash(String path) => path.replaceAll(Platform.pathSeparator, '/');

  String pluginEntry() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: compact\n'
      '    name: 上下文压缩\n'
      '    command: "${pythonCommand()}"\n'
      '    args: ["${slash(compactScript())}"]\n'
      '    granularity: team\n'
      '    scope: {}\n';

  /// 起一条真总线，并把执行站四项依赖接成假实现。
  ///
  /// [llmBadJson] 非空 = 总结调用**失败但带原文**（`LlmJsonCaller` 解析失败分支的
  /// 真实形状）：插件应当据此做本地修复 / 发一次修复调用，而不是当场弃权。
  /// [llmRepairOk] = 第二段自愈（"判断完整性 + 修 json"调用）是否成功。
  Future<PluginBus> startBus({
    required String agentId,
    required bool llmOk,
    List<String> logs = const <String>[],
    String? llmBadJson,
    bool llmRepairOk = true,
  }) async {
    final String dir = p.join(temp.path, 'bus-${++busSeq}');
    final File file = File(p.join(dir, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(pluginEntry());
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      missThreshold: 3,
      log: logs.add,
    );
    buses.add(bus);
    bus.callSiteContext = (String id, String sessionId) => StationScopeContext(
      teamId: id == agentId ? team : '',
      agentId: id,
      sessionId: sessionId,
    );
    bus.agentModeKeyResolver = (String id) =>
        id == agentId ? StationModeKey.local : '';
    bus.mountExecuteStations(
      ExecuteStationMounts(
        ioFor: (String id) async => LocalWorkspaceIO(workspace),
        agentTeamOf: (String id) => id == agentId ? team : '',
        agentModeOf: (String id) => id == agentId ? StationModeKey.local : '',
        llmCaller:
            ({
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
              // 修复调用（自愈第二段）的判别：单条 user、**不带** response_format
              // / tools —— 与插件 [repair_json] 的入参口径一一对应。
              final bool isRepair =
                  responseFormat == null &&
                  messages != null &&
                  messages.length == 1;
              llmCalls.add(<String, dynamic>{
                'agent_id': agentId,
                'messages': messages,
                'system': system,
                'tools': tools,
                'response_format': responseFormat,
                'max_tokens': maxTokens,
                'is_repair': isRepair,
              });
              if (isRepair) {
                if (!llmRepairOk) {
                  return <String, dynamic>{'error': '修复调用失败（假端点）'};
                }
                return <String, dynamic>{
                  'ok': true,
                  'json': <String, dynamic>{
                    'complete': false,
                    'reason': '正文在 required_files 中途断掉',
                    'summary': demoSummary(),
                  },
                  'text': '{"complete":false}',
                  'model': 'demo-model',
                  'usage': <String, dynamic>{'prompt_tokens': 300},
                };
              }
              if (!llmOk) {
                if (llmBadJson != null) {
                  // 与生产实现（LlmJsonCaller 解析失败分支）同一口径：**失败但带原文**。
                  return <String, dynamic>{
                    'error':
                        '模型正文不是合法 JSON（本次按 text 形态发送：'
                        '未发 response_format…）',
                    'error_kind': 'json_parse',
                    'text': llmBadJson,
                    'text_length': llmBadJson.length,
                    'truncated_suspect': !llmBadJson.trimRight().endsWith('}'),
                    'model': 'agent-model',
                  };
                }
                return <String, dynamic>{'error': '端点不支持 json_object'};
              }
              return <String, dynamic>{
                'ok': true,
                'json': demoSummary(),
                'text': '{"ok":true}',
                'model': 'demo-model',
                'usage': <String, dynamic>{'prompt_tokens': 1200},
              };
            },
        toolCaller:
            ({
              required String agentId,
              required String sessionId,
              required String tool,
              required Map<String, dynamic> arguments,
              required String sourcePluginId,
              required bool relay,
            }) async {
              if (tool == 'set_todo_list' && arguments['action'] == 'get') {
                return const ToolOutcome(
                  '- [~] t1 | status=in_progress progress=50 | 改 JWT\n'
                  '- [ ] t2 | status=pending progress=0 | 补测试',
                );
              }
              return const ToolOutcome('未知工具', isError: true);
            },
      ),
    );
    await bus.start();
    return bus;
  }

  Future<void> waitForSubscription(
    PluginBus bus,
    List<String> logs, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final RelayStation? station = bus.stations.relayPointFor(
      StationHubIds.relayContextCompact,
    );
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (station != null && station.subscribers.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      station?.subscribers,
      isNotEmpty,
      reason:
          '压缩插件必须订上点位；日志：${logs.join(' | ')}；'
          '插件 stderr：'
          '${bus.instances().map((({String pluginId, PluginHost host}) i) => '${i.pluginId}: ${i.host.stderrTail}').join(' /// ')}',
    );
  }

  /// 结构合法性（端点 400 的机器化防线）：`tool` 必须有前置配对，`tool_calls` 必须配平。
  List<String> structureProblems(List<Map<String, dynamic>> messages) {
    final List<String> problems = <String>[];
    List<String> pending = <String>[];
    for (int i = 0; i < messages.length; i++) {
      final Map<String, dynamic> message = messages[i];
      final String role = (message['role'] ?? '').toString();
      if (role == 'assistant') {
        if (pending.isNotEmpty) {
          problems.add('第 $i 条 assistant 打断了未配对的 tool_calls：$pending');
          pending = <String>[];
        }
        final Object? calls = message['tool_calls'];
        if (calls is List && calls.isNotEmpty) {
          pending = <String>[
            for (final Object? call in calls)
              ((call as Map)['id'] ?? '').toString(),
          ];
        }
        continue;
      }
      if (role == 'tool') {
        final String id = (message['tool_call_id'] ?? '').toString();
        if (!pending.remove(id)) {
          problems.add('第 $i 条 tool 没有配对的前置 tool_calls：$id');
        }
        continue;
      }
      if (pending.isNotEmpty) {
        problems.add('第 $i 条 $role 打断了未配对的 tool_calls：$pending');
        pending = <String>[];
      }
    }
    if (pending.isNotEmpty) {
      problems.add('结尾仍有未配对的 tool_calls：$pending');
    }
    return problems;
  }

  List<Map<String, dynamic>> asMaps(List<Object?> messages) => messages
      .map((Object? m) => (m! as Map).cast<String, dynamic>())
      .toList(growable: false);

  int toolRounds(List<Map<String, dynamic>> messages) => messages
      .where((Map<String, dynamic> m) {
        final Object? calls = m['tool_calls'];
        return calls is List && calls.isNotEmpty;
      })
      .length;

  /// 造一个"引擎口径前缀"提供者（真核心里由 `LlmAgentEngine.wireRequestFor` 产出）。
  WireRequestProvider wireProvider([
    List<Map<String, dynamic>>? messages,
  ]) =>
      (CoreAgent agent, CoreSession session) async => <String, dynamic>{
        'model': 'demo-model',
        'messages': messages ?? wireMessages,
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'function',
            'function': <String, dynamic>{
              'name': 'read',
              'description': '读文件',
              'parameters': <String, dynamic>{'type': 'object'},
            },
          },
        ],
        'stream': false,
      };

  /// 六条原文（三轮一问一答）：与线形前缀的最后三条 user 对应。
  MemoryStore storeWithThreeTurns() {
    final MemoryStore store = MemoryStore();
    final CoreAgent agent = store.createAgent(name: '压缩用例', modelId: 'demo');
    agent.systemPrompt = '你是一个助手';
    store.putAgent(agent);
    final CoreSession session = store.session(
      agent.id,
      TreeStore.defaultSessionId,
    )!;
    int clock = 0;
    for (final String content in <String>[
      '第一轮要求',
      '第一轮回答',
      '第二轮要求',
      '第二轮回答',
      '第三轮要求',
      '第三轮回答',
    ]) {
      store.appendMessage(
        CoreMessage(
          id: CoreIds.next('m'),
          agentId: agent.id,
          sessionId: session.sessionId,
          role: content.endsWith('要求') ? 'user' : 'agent',
          content: content,
          timestamp: ++clock,
        ),
      );
    }
    return store;
  }

  test('真插件接管：前缀逐字复用（缓存）+ 尾部原样抄回 + 水位线 = 原文总数', () async {
    final MemoryStore store = storeWithThreeTurns();
    final CoreAgent agent = store.agents().single;
    final CoreSession session = store.session(
      agent.id,
      TreeStore.defaultSessionId,
    )!;
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(agentId: agent.id, llmOk: true, logs: logs);
    await waitForSubscription(bus, logs);

    final CompactionService service = CompactionService(
      store: store,
      settings: CoreSettings(),
    )..relayHook = bus.relayCompaction;
    service.wireRequestProvider = wireProvider();
    final CompactionResult result = await service.compact(
      agent.id,
      session.sessionId,
    );
    expect(result.compressed, isTrue);
    expect(result.source, compactionSourceRelay);
    expect(result.summarizedMessages, 6, reason: '尾部抄回 ⇒ 覆盖全部 6 条原文');
    expect(
      result.contextSize,
      9,
      reason: '2 system + assistant + 4 tool + 尾部 2 条',
    );

    // ① 总结调用：前缀 = request.messages[:cut]（与对话逐字一致）+ 一条 user 指令；
    //    tools 原样透传；**不用** system 参数（否则前缀整体错位）
    expect(llmCalls, hasLength(1));
    final Map<String, dynamic> call = llmCalls.single;
    final List<Object?> sent = call['messages']! as List<Object?>;
    expect(
      sent.sublist(0, sent.length - 1),
      wireMessages.sublist(0, wireCut),
      reason: '前缀必须与对话那一轮逐字一致（缓存单元才命中）',
    );
    final Map<String, dynamic> instruction =
        sent.last as Map<String, dynamic>;
    expect(instruction['role'], 'user');
    expect(instruction['content'], contains('json'));
    expect(
      (call['system'] as String?) ?? '',
      isEmpty,
      reason: '不能再用 system 参数插在前面（会让前缀整体错位）',
    );
    expect(
      jsonEncode(call['tools']),
      contains('read'),
      reason: 'tools 是前缀对齐的另一半',
    );
    expect(
      call['response_format'],
      'text',
      reason: '总结调用必须走 text 形态：`json_object` 会让端点改写提示词（恒定 +22 token，'
          '落在 messages 之前）⇒ 上面这条"逐字一致"的前缀整段丢缓存（known-issues #27）',
    );
    expect(
      jsonEncode(sent),
      isNot(contains('第三轮回答')),
      reason: 'keep 段不该进总结输入',
    );

    // ② 落库：摘要侧 + 原样抄回的尾部；配对严格
    final CoreSession after = store.session(agent.id, session.sessionId)!;
    final List<Map<String, dynamic>> context = after.compactedContext;
    expect(context, hasLength(9));
    expect(context[0]['role'], 'system');
    expect(context[0]['content'], contains('你是一个助手'));
    expect(context[1]['role'], 'system');
    final String summary = context[1]['content'] as String;
    expect(summary, contains('## 背景'));
    expect(summary, contains('## 轨迹'));
    expect(summary, contains('## 改动与产出文件'));
    expect(summary, contains('lib/auth.dart'));

    final Map<String, dynamic> assistant = context[2];
    expect(
      assistant['reasoning_content'],
      '上下文压缩后，我先 read 相关文件，获取 todo 列表',
    );
    final List<Map<String, dynamic>> calls = (assistant['tool_calls'] as List)
        .cast<Map<String, dynamic>>();
    expect(calls, hasLength(4), reason: '3 个必读 + 1 个 todo');
    expect(
      calls.map((Map<String, dynamic> c) => (c['function'] as Map)['name']),
      <String>['read', 'read', 'read', 'set_todo_list'],
    );
    final List<Map<String, dynamic>> results = context
        .sublist(3, 7)
        .cast<Map<String, dynamic>>();
    expect(
      results.map((Map<String, dynamic> m) => m['tool_call_id']).toList(),
      calls.map((Map<String, dynamic> c) => c['id']).toList(),
      reason: 'tool_calls 与 tool 结果必须一一配对（悬空即 400）',
    );
    expect(results[0]['content'], contains('class Auth'));
    expect(results[1]['content'], contains('改 JWT'));
    expect(results[2]['content'], contains('读取失败'));
    expect(results[3]['content'], contains('待办'));
    expect(
      context.sublist(7),
      wireMessages.sublist(wireCut),
      reason: '尾部原文原样抄回（插件不改写助手工作与工具卡）',
    );

    // ③ 水位线 = 原文总数、摘要清空（两条路径互斥）
    expect(after.compactedMessageCount, 6);
    expect(after.compactedSummary, isEmpty);
    expect(after.compacted, isTrue);
    // ④ 结构合法性：落库上下文与"喂给总结模型的那次请求"都必须无孤儿 tool / 无悬空 tool_calls
    expect(
      structureProblems(context),
      isEmpty,
      reason: '落库上下文是端点真正会收到的东西：结构不合法就是 400',
    );
    expect(
      structureProblems(asMaps(sent)),
      isEmpty,
      reason: '总结输入本身就是一次真实请求，同样必须结构合法',
    );
  }, timeout: const Timeout(Duration(seconds: 180)), skip: noPython);

  test('单轮超长工具轨迹：只留最后 8 个工具轮，其余进总结输入', () async {
    // 一条 user 后面跟 12 个工具轮 —— "keep 死保整轮"会压不动的那种会话
    final List<Map<String, dynamic>> wire = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': '你是一个助手'},
      <String, dynamic>{'role': 'user', 'content': '把整个仓库扫一遍'},
    ];
    for (int i = 0; i < 12; i++) {
      wire.add(<String, dynamic>{
        'role': 'assistant',
        'content': '',
        'reasoning_content': '继续扫',
        'tool_calls': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'call_s$i',
            'type': 'function',
            'function': <String, dynamic>{
              'name': 'grep',
              'arguments': '{"q":"TODO"}',
            },
          },
        ],
      });
      wire.add(<String, dynamic>{
        'role': 'tool',
        'tool_call_id': 'call_s$i',
        'content': '第 ${i + 1} 轮工具结果',
      });
    }
    wire.add(<String, dynamic>{'role': 'assistant', 'content': '扫完了'});

    final MemoryStore store = MemoryStore();
    final CoreAgent agent = store.createAgent(name: '单轮用例', modelId: 'demo');
    agent.systemPrompt = '你是一个助手';
    store.putAgent(agent);
    final CoreSession session = store.session(
      agent.id,
      TreeStore.defaultSessionId,
    )!;
    store.appendMessage(
      CoreMessage(
        id: CoreIds.next('m'),
        agentId: agent.id,
        sessionId: session.sessionId,
        role: 'user',
        content: '把整个仓库扫一遍',
        timestamp: 1,
      ),
    );
    store.appendMessage(
      CoreMessage(
        id: CoreIds.next('m'),
        agentId: agent.id,
        sessionId: session.sessionId,
        role: 'agent',
        content: '扫完了',
        timestamp: 2,
      ),
    );

    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(agentId: agent.id, llmOk: true, logs: logs);
    await waitForSubscription(bus, logs);
    final CompactionService service = CompactionService(
      store: store,
      settings: CoreSettings(),
    )..relayHook = bus.relayCompaction;
    service.wireRequestProvider = wireProvider(wire);
    final CompactionResult result = await service.compact(
      agent.id,
      session.sessionId,
    );
    expect(result.source, compactionSourceRelay);
    expect(result.summarizedMessages, 2, reason: '尾部抄回 ⇒ 覆盖全部原文');

    final CoreSession after = store.session(agent.id, session.sessionId)!;
    final List<Map<String, dynamic>> context = after.compactedContext;
    // 尾部 = 最后 8 个工具轮 + 收尾 assistant（共 17 条），且与原 wire 逐字一致
    final List<Map<String, dynamic>> tail = wire.sublist(10);
    expect(toolRounds(tail), 8);
    expect(
      context.sublist(context.length - tail.length),
      tail,
      reason: '尾部原样抄回：最后 8 个工具轮一个不多一个不少',
    );
    expect(
      toolRounds(context),
      9,
      reason: '回包里的工具轮 = 伪造的 read/todo 那条 1 + 尾部 8',
    );
    expect(structureProblems(context), isEmpty);

    // 被挤出去的早期工具轮必须进总结输入，被保留的不许进
    final List<Map<String, dynamic>> sent = asMaps(
      llmCalls.single['messages']! as List<Object?>,
    );
    final String asked = jsonEncode(sent);
    expect(asked, contains('第 1 轮工具结果'));
    expect(asked, contains('第 4 轮工具结果'));
    expect(
      asked,
      isNot(contains('第 5 轮工具结果')),
      reason: '第 5 轮起在尾部原样保留，不该再喂给总结模型',
    );
    expect(
      sent.sublist(0, sent.length - 1),
      wire.sublist(0, 10),
      reason: '总结前缀仍是"引擎真会发的那份"的前缀（缓存可命中）',
    );
    expect(structureProblems(sent), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 180)), skip: noPython);

  test('插件不接管（llm.call 失败）⇒ 核心回退内置 compact，内容不丢', () async {
    final MemoryStore store = storeWithThreeTurns();
    final CoreAgent agent = store.agents().single;
    final CoreSession session = store.session(
      agent.id,
      TreeStore.defaultSessionId,
    )!;
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(agentId: agent.id, llmOk: false, logs: logs);
    await waitForSubscription(bus, logs);

    final CompactionService service = CompactionService(
      store: store,
      settings: CoreSettings(),
      summarizer: _FakeSummarizer(),
    )..relayHook = bus.relayCompaction;
    service.wireRequestProvider = wireProvider();
    final CompactionResult result = await service.compact(
      agent.id,
      session.sessionId,
    );
    expect(result.compressed, isTrue);
    expect(
      result.source,
      compactionSourceBuiltin,
      reason: '插件没接管（llm.call 失败）⇒ 回退内置 compact',
    );
    final CoreSession after = store.session(agent.id, session.sessionId)!;
    expect(after.compactedSummary, contains('内置摘要'));
    expect(
      after.compactedContext,
      isEmpty,
      reason: '互斥的另一半：内置摘要接管时清掉中转站的列表',
    );
  }, timeout: const Timeout(Duration(seconds: 180)), skip: noPython);

  test('总结正文非法 JSON（可本地修复）⇒ 插件零额外调用仍接管（钱别白花）', () async {
    // 真机现场（2026-10-05 18:29）：`llm.call` **成功了**（448k prompt、≈100% 命中
    // 缓存）但正文不是合法 JSON，插件却报"原文 0 字"当场弃权 ⇒ 核心回退内置压缩，
    // 那笔几十万 token 的钱白花。原因是 `failedWith` 的载荷在
    // `StationInstance.execute` 的失败分支被丢掉（见 docs/known-issues.md #31
    // 「真机复现」）。这条用例把"原文必须经执行站回到插件"钉在真进程 + 真总线上。
    final String encoded = jsonEncode(demoSummary());
    final String trailingComma = '${encoded.substring(0, encoded.length - 1)},}';
    final MemoryStore store = storeWithThreeTurns();
    final CoreAgent agent = store.agents().single;
    final CoreSession session = store.session(
      agent.id,
      TreeStore.defaultSessionId,
    )!;
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(
      agentId: agent.id,
      llmOk: false,
      llmBadJson: trailingComma,
      logs: logs,
    );
    await waitForSubscription(bus, logs);

    final CompactionService service = CompactionService(
      store: store,
      settings: CoreSettings(),
      summarizer: _FakeSummarizer(),
    )..relayHook = bus.relayCompaction;
    service.wireRequestProvider = wireProvider();
    final CompactionResult result = await service.compact(
      agent.id,
      session.sessionId,
    );

    expect(
      result.source,
      compactionSourceRelay,
      reason: '本地结构修复救回了摘要 ⇒ 插件接管；日志：${logs.join(' | ')}',
    );
    expect(result.summarizedMessages, 6);
    expect(
      llmCalls,
      hasLength(1),
      reason: '本地结构修复是免费的：不该多花一次调用',
    );
    final CoreSession after = store.session(agent.id, session.sessionId)!;
    final String summary = after.compactedContext[1]['content'] as String;
    expect(
      summary,
      contains('由本地结构修复得到'),
      reason: '抢救回来的摘要必须显式标注（可能不完整）',
    );
    expect(summary, contains('## 背景'));
    expect(summary, contains('lib/auth.dart'));
  }, timeout: const Timeout(Duration(seconds: 180)), skip: noPython);

  test('正文被截断 ⇒ 恰好一次修复调用（不带 tools / response_format / max_tokens）后接管', () async {
    // 本地修不了（真截断）时的第二段自愈：一次小的"判断完整性 + 修 json"调用。
    // 三条硬口径都要钉住：不带 tools、不发 response_format、**不设 max_tokens**
    // （设小了就是下一次截断、钱又白花）。
    const String truncated =
        '{"background": "把登录改成 JWT", "trajectory": "已定位 auth 模块';
    final MemoryStore store = storeWithThreeTurns();
    final CoreAgent agent = store.agents().single;
    final CoreSession session = store.session(
      agent.id,
      TreeStore.defaultSessionId,
    )!;
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(
      agentId: agent.id,
      llmOk: false,
      llmBadJson: truncated,
      logs: logs,
    );
    await waitForSubscription(bus, logs);

    final CompactionService service = CompactionService(
      store: store,
      settings: CoreSettings(),
      summarizer: _FakeSummarizer(),
    )..relayHook = bus.relayCompaction;
    service.wireRequestProvider = wireProvider();
    final CompactionResult result = await service.compact(
      agent.id,
      session.sessionId,
    );

    expect(
      result.source,
      compactionSourceRelay,
      reason: '修复调用补全了摘要 ⇒ 插件接管；日志：${logs.join(' | ')}',
    );
    expect(result.summarizedMessages, 6);
    expect(llmCalls, hasLength(2), reason: '本地修不了 ⇒ 恰好一次修复调用（硬上限）');
    final Map<String, dynamic> repair = llmCalls[1];
    expect(repair['is_repair'], isTrue, reason: '第二条必须是那次修复调用');
    expect(
      repair['response_format'],
      isNull,
      reason: '修复调用不发 response_format（站点缺省即 json_object）',
    );
    expect(repair['tools'], isNull, reason: '修复调用不带 tools');
    expect(
      repair['max_tokens'],
      isNull,
      reason: '不设小 max_tokens：设小了 = 下一次截断 = 钱又白花',
    );
    final CoreSession after = store.session(agent.id, session.sessionId)!;
    final String summary = after.compactedContext[1]['content'] as String;
    expect(summary, contains('由一次 JSON 修复调用补全'));
    expect(summary, contains('模型判定原文被截断'));
  }, timeout: const Timeout(Duration(seconds: 180)), skip: noPython);

  test('本地修不了 + 修复调用也失败 ⇒ 不接管，且原因可读（不再是"原文 0 字"）', () async {
    const String truncated =
        '{"background": "把登录改成 JWT", "trajectory": "已定位 auth 模块';
    final MemoryStore store = storeWithThreeTurns();
    final CoreAgent agent = store.agents().single;
    final CoreSession session = store.session(
      agent.id,
      TreeStore.defaultSessionId,
    )!;
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(
      agentId: agent.id,
      llmOk: false,
      llmBadJson: truncated,
      llmRepairOk: false,
      logs: logs,
    );
    await waitForSubscription(bus, logs);

    final CompactionService service = CompactionService(
      store: store,
      settings: CoreSettings(),
      summarizer: _FakeSummarizer(),
    )..relayHook = bus.relayCompaction;
    service.wireRequestProvider = wireProvider();
    final CompactionResult result = await service.compact(
      agent.id,
      session.sessionId,
    );

    expect(result.source, compactionSourceBuiltin, reason: '三段都失败 ⇒ 回退内置');
    expect(llmCalls, hasLength(2), reason: '硬上限：放弃前只多花一次调用');
    final String why = logs
        .where((String l) => l.contains('未接管'))
        .map((String l) => l)
        .join(' | ');
    expect(why, contains('repair_failed'), reason: '原因要给到机读 code，别只说"回 null"');
    expect(
      why,
      contains('原文'),
      reason: '真正的原因必须能看懂（真机那次只留下"原文 0 字"）',
    );
    expect(
      why,
      isNot(contains('原文 0 字')),
      reason: '插件拿到原文了，就不该再报 0 字',
    );
  }, timeout: const Timeout(Duration(seconds: 180)), skip: noPython);
}

/// 假总结器的"合法摘要"（与真插件约定的四键 schema 一致）。
Map<String, dynamic> demoSummary() => <String, dynamic>{
  'background': '用户要把登录改成 JWT。',
  'trajectory': '已定位 auth 模块是 session 实现。',
  'files_changed': <Map<String, dynamic>>[
    <String, dynamic>{'path': 'lib/auth.dart', 'change': '修改：改成 JWT 校验'},
  ],
  'required_files': <Map<String, dynamic>>[
    <String, dynamic>{
      'path': 'lib/auth.dart',
      'start_line': 1,
      'line_count': 20,
      'why': '正在改的模块',
    },
    <String, dynamic>{'path': 'docs/plan.md', 'why': '计划文档'},
    <String, dynamic>{
      'path': 'docs/missing.md',
      'why': '故意不存在：必须留下失败结果',
    },
  ],
};

/// 假总结器（回退路径专用）。
class _FakeSummarizer implements ContextSummarizer {
  @override
  Future<String> summarize(
    CoreAgent agent,
    String prompt, {
    void Function(String notice)? onNotice,
    UsageSink? usageSink,
  }) async => '内置摘要';

  @override
  Future<void> close() async {}
}
