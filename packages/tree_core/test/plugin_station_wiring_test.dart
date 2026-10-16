import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// CoreServer 的站点接线（M9 Wave 3-I）：
/// 核心一启动就把执行站首命令集的**挂载位置**接上，并把运行期四元组的两个解析器
/// （team ← agent 归属、mode_key ← agent 工作空间模式）注入插件总线。
///
/// 这里跑的是**真实核心 + 真实工作空间 IO**（不注入假挂载），因此「暂无挂载位置」
/// 与「SSH 命令打到本地工作空间」这两类问题都能在这里被挡住。
void main() {
  late Directory temp;
  late String workspace;
  late MemoryStore store;
  late CoreAgent agent;
  late PluginBus bus;
  late CoreServer server;

  // 起一个核心（可注入执行站要用的后台任务管理器）：多次调用会**替换**同一批
  // mountId 的挂载位置（ExecuteStation.mount 幂等），因此用例可以拿第二个核心
  // 验证「注入 hooks」的分支。
  Future<CoreServer> boot({TerminalHooks? stationHooks, UsageLog? usageLog}) =>
      CoreServer.start(
        store: store,
        pluginBus: bus,
        usageLog: usageLog,
        specIoFor: (String agentId) async =>
            agentId == agent.id ? LocalWorkspaceIO(workspace) : null,
        enableHeartbeat: false,
        streamChunkDelay: Duration.zero,
        engine: ScriptedAgent(chunkDelay: Duration.zero),
        stationHooks: stationHooks,
      );

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_station_wire_');
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
    store = MemoryStore();
    agent = store.createAgent(name: '甲', modelId: 'demo');
    agent.teamId = 'team-1';
    agent.workspaceDir = workspace;
    store.putAgent(agent);

    final File file = File('${temp.path}/config/plugins.yaml');
    file.createSync(recursive: true);
    file.writeAsStringSync('enabled: true\nplugins: []\n');
    bus = PluginBus(
      configFile: file.path,
      heartbeatInterval: const Duration(seconds: 30),
    );
    server = await boot();
  });

  tearDown(() async {
    await server.close();
    await bus.close();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  /// **命令 → 所属执行站点位**（点位化：执行站按命令族拆成 11 个实例，命令只落在
  /// 自己那一族；`executeForCommand` 就是核心 `station/command` 的分发依据）。
  ///
  /// 站点与 mode 无关：local / ssh 是**命令 scope** 的取值，不是站点身份。
  ExecuteStation station(String command) =>
      bus.stations.station(StationPoints.ownerOfCommand(command)!.id)!
          as ExecuteStation;

  test('核心启动即把二十六条命令挂到各自的点位（不再返回「暂无挂载位置」）', () {
    for (final StationPointSpec spec in StationPoints.executes) {
      expect(
        bus.stations
            .executePointFor(spec.id)!
            .mounts()
            .map((StationCommandMount m) => m.command)
            .toSet(),
        spec.commands.toSet(),
        reason: '点位 ${spec.id} 只挂自己那族的命令（命令族之间互不干扰）',
      );
    }
    // 全命令并集 = 二十六条（fs 4 + terminal 4 + agent 3 + ui 1 + llm 1 + tool 2 +
    // session 1 + ssh 1 + plugin 6 + station 2 + usage 1）；`llm.call` / `tool.call` / `tool.close` /
    // `session.rename` / `ssh.reconnect` 也被各自点位接管，只是落到「尚无挂载实现」的显式失败
    // （不是「暂无挂载位置」）。
    expect(ExecuteStation.builtinCommands, hasLength(26));
  });

  test('运行期四元组：team 取 agent 归属、mode_key 取工作空间模式', () {
    final StationScope local = bus.runtimeScopeFor(
      agentId: agent.id,
      sessionId: 'ses_1',
    );
    expect(local.teamId, 'team-1', reason: 'team 从 agent 归属解析');
    expect(local.modeKey, StationModeKey.local);
    expect(local.agentId, agent.id);

    // 同一个 agent 配上 SSH 后：mode_key 变成 ssh（插件命令因此不会打到本地工作空间）
    agent.sshConfig = SshConfig(host: 'example.com', username: 'open');
    store.putAgent(agent);
    expect(
      bus.runtimeScopeFor(agentId: agent.id, sessionId: 'ses_1').modeKey,
      StationModeKey.ssh,
    );
  });

  test('端到端：fs.write / fs.read / fs.list 落在 agent 的工作空间里', () async {
    final ExecuteStation execute = station('fs.write');
    final StationScope scope = bus.runtimeScopeFor(
      agentId: agent.id,
      sessionId: 'ses_1',
    );

    final StationCommandResult write = await execute.execute(
      command: 'fs.write',
      scope: scope,
      arguments: <String, dynamic>{
        'agent_id': agent.id,
        'path': 'notes/a.txt',
        'content': '接线完成',
      },
    );
    expect(write.ok, isTrue, reason: write.error);
    expect(
      File(p.join(workspace, 'notes', 'a.txt')).readAsStringSync(),
      '接线完成',
    );

    final StationCommandResult read = await execute.execute(
      command: 'fs.read',
      scope: scope,
      arguments: <String, dynamic>{'agent_id': agent.id, 'path': 'notes/a.txt'},
    );
    expect(read.ok, isTrue, reason: read.error);
    expect((read.payload! as Map<String, dynamic>)['content'], '接线完成');

    final StationCommandResult list = await execute.execute(
      command: 'fs.list',
      scope: scope,
      arguments: <String, dynamic>{'agent_id': agent.id, 'path': 'notes'},
    );
    expect(list.ok, isTrue, reason: list.error);
    expect(
      ((list.payload! as Map<String, dynamic>)['entries'] as List<dynamic>),
      isNotEmpty,
    );
  });

  test('端到端：SSH 模式的命令不许打到本地工作空间（跨模式拒绝）', () async {
    // 同一点位（fs.read 所属的文件操作点位）：mode 只在**命令 scope** 上，
    // 所以这里拿到的是同一个实例，跨模式判定由挂载位置自己做（见 execute_mounts）。
    final ExecuteStation ssh = station('fs.read');
    final StationCommandResult denied = await ssh.execute(
      command: 'fs.read',
      scope: StationScope(
        teamId: 'team-1',
        agentId: agent.id,
        sessionId: 'ses_1',
        modeKey: StationModeKey.ssh,
      ),
      arguments: <String, dynamic>{'agent_id': agent.id, 'path': 'notes/a.txt'},
    );
    expect(denied.ok, isFalse);
    expect(denied.error, contains('跨模式'));
  });

  test('端到端：agent.stop 走既有级联停止路径；未接线的服务显式报错', () async {
    final ExecuteStation execute = station('agent.stop');
    final StationScope scope = bus.runtimeScopeFor(
      agentId: agent.id,
      sessionId: 'ses_1',
    );

    final StationCommandResult stop = await execute.execute(
      command: 'agent.stop',
      scope: scope,
      arguments: <String, dynamic>{'agent_id': agent.id},
    );
    expect(stop.ok, isTrue, reason: stop.error);
    final Map<String, dynamic> payload = stop.payload! as Map<String, dynamic>;
    expect(payload['cascade_ids'], <String>[agent.id]);
    expect(payload['any_running'], isFalse);
    expect(payload['reason'], contains('没有进行中的任务'));

    // compaction 没接：agent.compact 必须显式报错（不静默成功）
    final StationCommandResult compact = await execute.execute(
      command: 'agent.compact',
      scope: scope,
      arguments: <String, dynamic>{'agent_id': agent.id},
    );
    expect(compact.ok, isFalse);
    expect(compact.error, contains('压缩'));
  });

  // ── 内置点位「启动即存在」（懒创建 ⇒ 用户实机看到「站点（0）」） ──

  test('核心启动即建齐 33 个内置点位（**每个接入点一个实例，与 team / mode 无关**）', () {
    final List<String> expected =
        StationPoints.all
            .where((StationPointSpec spec) => spec.kind != StationKind.collect)
            .map((StationPointSpec spec) => spec.id)
            .toList()
          ..sort();
    expect(
      bus.stations.stationList().map((StationInstance s) => s.id).toList(),
      expected,
      reason: '广播 10 + 执行 11 + 中转 12 = 33：每个点位一个独立实例，id 不含 team / mode',
    );
    expect(bus.stations.stationList(), hasLength(33));
    expect(
      bus.stations.stationList().whereType<CollectStation>(),
      isEmpty,
      reason: '收集站的 schema 属于接入点，预建空 schema 的收集站没有意义',
    );

    // 面板快照口径：前端卡片直接渲染 kind / kind_label / builtin / subscriber_count
    final Map<String, dynamic> described = bus.stations.snapshot().first;
    expect(described['station_id'], StationHubIds.broadcast);
    expect(described['kind'], 'broadcast');
    expect(described['kind_label'], '广播站');
    expect(described['builtin'], isTrue);
    expect(described['subscriber_count'], 0);
    expect(
      described['subscribers_by_team'],
      isEmpty,
      reason: '还没有订阅者 ⇒ 面板没有团队分组可显示',
    );
  });

  test('站点数不随工作空间模式 / 重启变化（team×mode 不再产生新实例）', () async {
    expect(bus.stations.stationList(), hasLength(33));

    // 同一团队里出现 SSH 工作面的 agent：**不再**多出站点（点位化的核心）。
    // mode 仍是有意义的隔离维度，但它属于消息 scope，不属于站点身份。
    agent.sshConfig = SshConfig(host: 'example.com', username: 'open');
    store.putAgent(agent);
    final CoreServer second = await boot();
    addTearDown(second.close);
    expect(
      bus.stations.stationList(),
      hasLength(33),
      reason: 'local / ssh 是同一个点位的两种工作面，不各自建站',
    );

    // 「重启」：换一条总线 + 再起一个核心，读同一个 stations.yaml
    // （只看内置点位：收集站由接入点按需现建，不参与预建口径）
    final List<String> builtinIds = bus.stations
        .stationList()
        .where((StationInstance s) => s.kind != StationKind.collect)
        .map((StationInstance s) => s.id)
        .toList();
    final PluginBus restarted = PluginBus(
      configFile: bus.configFile,
      heartbeatInterval: const Duration(seconds: 30),
    );
    addTearDown(restarted.close);
    final CoreServer third = await CoreServer.start(
      store: store,
      pluginBus: restarted,
      specIoFor: (String agentId) async =>
          agentId == agent.id ? LocalWorkspaceIO(workspace) : null,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    addTearDown(third.close);
    expect(
      restarted.stations
          .stationList()
          .where((StationInstance s) => s.kind != StationKind.collect)
          .map((StationInstance s) => s.id)
          .toList(),
      builtinIds,
      reason: '第二次启动从盘恢复：数量与 id 都不变（33 个内置点位不重复建）',
    );
  });

  // ── Wave 3-I 第 2 条：执行站 terminal.exec 与工具层**共用同一张任务表** ──

  test('未注入 hooks：核心自建一份，terminal.exec 的 hook 模式照常可用', () async {
    final ExecuteStation execute = station('terminal.exec');
    final StationScope stationScope = bus.runtimeScopeFor(
      agentId: agent.id,
      sessionId: 'ses_1',
    );

    final StationCommandResult hook = await execute.execute(
      command: 'terminal.exec',
      scope: stationScope,
      arguments: <String, dynamic>{
        'agent_id': agent.id,
        'command': 'echo self-hook',
        'hook': true,
      },
    );
    expect(hook.ok, isTrue, reason: hook.error);
    final String text =
        (hook.payload! as Map<String, dynamic>)['text'] as String;
    expect(text, contains('[terminal hook]'));
    final RegExpMatch? taskId = RegExp(r'task_id: (\S+)').firstMatch(text);
    expect(taskId, isNotNull, reason: '自建路径必须照旧返回 task_id');

    // 自建实例自己查得到（与注入路径行为一致）；它随核心 close() 一起释放（tearDown）
    final StationCommandResult status = await execute.execute(
      command: 'terminal.exec',
      scope: stationScope,
      arguments: <String, dynamic>{
        'agent_id': agent.id,
        'hook_action': 'status',
        'task_id': taskId!.group(1),
      },
    );
    expect(status.ok, isTrue, reason: status.error);
    expect(
      ((status.payload! as Map<String, dynamic>)['text'] as String),
      contains(taskId.group(1)!),
    );
  });

  test('注入 hooks：terminal.exec 落到工具层同一张任务表；核心 close 不关注入实例', () async {
    // 模拟 CLI 的 tools.hooks：实例归工具层所有，核心只是借用
    final TerminalHooks shared = TerminalHooks();
    addTearDown(shared.close);
    final CoreServer second = await boot(stationHooks: shared);
    addTearDown(second.close);

    final ExecuteStation execute = station('terminal.exec');
    final StationScope stationScope = bus.runtimeScopeFor(
      agentId: agent.id,
      sessionId: 'ses_1',
    );
    final StationCommandResult hook = await execute.execute(
      command: 'terminal.exec',
      scope: stationScope,
      arguments: <String, dynamic>{
        'agent_id': agent.id,
        'command': 'echo shared-hook',
        'hook': true,
      },
    );
    expect(hook.ok, isTrue, reason: hook.error);
    expect(shared.tasks, hasLength(1), reason: '任务必须落在注入的那一份（工具层同一张表）');
    final HookTask task = shared.tasks.single;
    expect(task.agentId, agent.id);
    expect(task.command, contains('shared-hook'));

    // 等 echo 收尾，再用同一实例按 task_id 查到它（插件与 agent 互相可见）
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
    while (task.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(task.running, isFalse, reason: 'echo 很快结束');
    final StationCommandResult status = await execute.execute(
      command: 'terminal.exec',
      scope: stationScope,
      arguments: <String, dynamic>{
        'agent_id': agent.id,
        'hook_action': 'status',
        'task_id': task.id,
      },
    );
    expect(status.ok, isTrue, reason: status.error);
    expect(
      ((status.payload! as Map<String, dynamic>)['text'] as String),
      contains('shared-hook'),
    );

    // 核心 close 只关自建的那一份：注入实例归注入方（工具层）所有，任务表仍在
    await second.close();
    expect(shared.task(task.id), isNotNull, reason: 'close 不得清空外部注入的实例');
    expect(shared.tasks, hasLength(1));
  });

  test('生产接线：usage.query 经执行站读到真实账本（聚合一处只算一份）', () async {
    final TreePaths paths = TreePaths(p.join(temp.path, 'data-root'));
    final UsageLog ledger = UsageLog(paths);
    final CoreServer second = await boot(usageLog: ledger);
    addTearDown(second.close);

    // 走**生产同一条落盘路径**记三笔：会话 ses_1 两笔（其中一笔端点没给缓存读数）
    // + 会话 ses_2 一笔（它不该出现在 ses_1 的回包里）
    ledger.record(
      agent.id,
      'ses_1',
      UsageCall(
        at: DateTime(2026, 10, 16, 10),
        source: UsageSource.turn,
        model: 'demo',
        promptTokens: 1000,
        cachedTokens: 400,
        completionTokens: 50,
      ),
    );
    ledger.record(
      agent.id,
      'ses_1',
      UsageCall(
        at: DateTime(2026, 10, 16, 11),
        source: UsageSource.compact,
        model: 'demo',
        promptTokens: 300,
        completionTokens: 30,
      ),
    );
    ledger.record(
      agent.id,
      'ses_2',
      UsageCall(
        at: DateTime(2026, 10, 16, 12),
        source: UsageSource.llmCall,
        model: 'demo',
        promptTokens: 200,
        completionTokens: 20,
        estimated: true,
      ),
    );
    await ledger.flush();

    final StationCommandResult result = await station('usage.query').execute(
      command: 'usage.query',
      scope: bus.runtimeScopeFor(agentId: agent.id, sessionId: 'ses_1'),
      arguments: <String, dynamic>{'agent_id': agent.id},
    );
    expect(result.ok, isTrue, reason: result.error);
    final Map<String, dynamic> body = result.payload! as Map<String, dynamic>;
    expect(body['session_id'], 'ses_1', reason: 'scope 的会话就是生效会话（回包 echo）');
    expect(body['usage_file'], paths.usageFile(agent.id, 'ses_1'));
    expect(body['count'], 2, reason: '账本按会话分文件：别的会话那一笔不许混进来');
    expect(
      body['tail_bytes'],
      UsageLog.defaultTailBytes,
      reason: '没给就用默认上限，并把生效值回出去',
    );
    final List<dynamic> calls = body['calls'] as List<dynamic>;
    // 行形状与 UsageCall.toJson() **逐字一致**（字段表只有一处出处）
    expect((calls.first as Map<String, dynamic>).keys.toList(), <String>[
      'at',
      'source',
      'model',
      'prompt_tokens',
      'cached_tokens',
      'completion_tokens',
      'estimated',
      'duration_ms',
    ]);
    final Map<String, dynamic> summary =
        body['summary'] as Map<String, dynamic>;
    expect(summary['prompt_tokens'], 1300);
    expect(summary['completion_tokens'], 80);
    expect(
      summary['cached_tokens'],
      400,
      reason: '只有一笔给了缓存读数：另一笔不许被编成 0（与账本那一列同口径）',
    );
    expect((summary['by_source'] as Map).keys.toSet(), <String>{
      UsageSource.turn,
      UsageSource.compact,
    });
  });
}
