import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// **临时员工只在它被召来的那个会话里存在**（用户 2026-10-04 的硬断言，落盘实现版）。
///
/// 一句话：临时员工**随会话持久化**（核心重启后打开同一会话它还在、还能复用），
/// 但**不是全局 agent**——不写 `agents/<id>.yaml`、不进 `agents()/teams()/members()`、
/// 不可被 `message` 寻址、不计 `team_member_count`；跨会话一律查不到、不可复用。
///
/// 这里跑的是**真 FileTreeStore + 真磁盘目录**（不是内存替身），逐条钉住：
/// 1. 同会话可见 / 跨会话不可见；
/// 2. 跨会话复用 = 可读错误（不静默新建、不错命中同名条目）；
/// 3. 重启后同一会话仍在、仍可复用；
/// 4. 删会话即随之消失；
/// 5. 不落成全局 agent（`agents/` 里没有 `sub_*`）+ 名册/寻址口径；
/// 6. 存储位置只在该会话的数据范围内。
void main() {
  late Directory temp;
  late TreePaths paths;
  late CoreSettings settings;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_subagent_iso_');
    paths = TreePaths(temp.path);
    paths.ensureLayoutSync();
    settings = CoreSettings();
    settings.putModel(CoreModelConfig(modelId: 'demo', name: 'demo'));
  });

  tearDown(() {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        // Windows 上落盘句柄可能晚一拍释放
      }
    }
  });

  /// 一套"核心装配"：真落盘 store + 会话级名册 + 装饰器 + 工具落点（假的跑一轮）。
  ({
    FileTreeStore fileStore,
    SubagentRegistry registry,
    SubagentStore store,
    SubagentService service,
  })
  harness({String report = '做完了'}) {
    final FileTreeStore fileStore = FileTreeStore(paths);
    final SubagentRegistry registry = SubagentRegistry(
      persistence: fileStore,
    );
    final SubagentStore store = SubagentStore(
      inner: fileStore,
      registry: registry,
    );
    final SubagentService service = SubagentService(
      store: store,
      registry: registry,
      settings: settings,
    );
    // 不真调 LLM：假 runner 只回一段报告（名字/任务回显，便于断言没串号）
    service.runner = (SubagentTurnRequest request) async {
      expect(store.agent(request.tag.id), isNotNull, reason: '运行时必须能查到它');
      return SubagentTurnResult(report: '$report（${request.tag.name}）');
    };
    return (fileStore: fileStore, registry: registry, store: store, service: service);
  }

  ToolInvocation invocation(
    String agentId,
    String sessionId, {
    required String task,
    String? reuse,
    bool background = false,
  }) => ToolInvocation(
    id: 'tc-1',
    name: 'subagent',
    arguments: <String, dynamic>{
      'task': task,
      'subagent_id': ?reuse,
      if (background) 'background': true,
    },
    agentId: agentId,
    sessionId: sessionId,
  );

  Future<ToolOutcome> call(
    SubagentService service,
    String agentId,
    String sessionId, {
    required String task,
    String? reuse,
    bool background = false,
  }) => SubagentTool.run(
    invocation(agentId, sessionId, task: task, reuse: reuse, background: background),
    service,
  );

  test('1/6. 同会话可见；跨会话不可见；记录只在该会话的数据范围内', () async {
    final h = harness();
    final CoreAgent owner = h.store.createAgent(name: 'leader', modelId: 'demo');
    final CoreSession s1 = h.store.createSession(owner.id, title: '一')!;
    final CoreSession s2 = h.store.createSession(owner.id, title: '二')!;

    final ToolOutcome outcome = await call(
      h.service,
      owner.id,
      s1.sessionId,
      task: '把 a.txt 改成 b',
    );
    expect(outcome.isError, isFalse, reason: outcome.content);
    final String id = h.registry.records(owner.id, s1.sessionId).single.id;
    expect(outcome.content, contains(id), reason: '结果里必须回传 id 供复用');

    // 同会话可见（换一套装配也可见：记录在盘上）
    await h.fileStore.flush();
    final h2 = harness();
    expect(h2.store.agent(id)?.name, isNotEmpty);
    expect(h2.store.subAgentsInSession(owner.id, s1.sessionId), hasLength(1));
    expect(
      h2.store.subAgentsInSession(owner.id, s2.sessionId),
      isEmpty,
      reason: '同一个 agent 的另一个会话必须是空名册',
    );
    expect(h2.registry.handle(id)?.sessionId, s1.sessionId);

    // 6. 存储位置：只在该会话目录下（同一 agent 的另一个会话里没有）
    final File roster = File(paths.subagentsFile(owner.id, s1.sessionId));
    expect(roster.existsSync(), isTrue, reason: '名册落在 data/<agent>/<session>/subagents.json');
    expect(
      File(paths.subagentsFile(owner.id, s2.sessionId)).existsSync(),
      isFalse,
      reason: '另一个会话不该有它的名册',
    );
    expect(Directory(paths.agentDataDir(id)).existsSync(), isFalse,
        reason: '临时员工没有自己的会话数据目录');
    final Map<String, dynamic> json =
        jsonDecode(roster.readAsStringSync()) as Map<String, dynamic>;
    expect(json['session_id'], s1.sessionId);
    expect(json['agent_id'], owner.id);
    expect((json['subagents'] as List<dynamic>), hasLength(1));
  });

  test('2. 跨会话复用 = 可读错误（不静默新建、不错命中同名条目）', () async {
    final h = harness();
    final CoreAgent owner = h.store.createAgent(name: 'leader', modelId: 'demo');
    final CoreSession s1 = h.store.createSession(owner.id, title: '一')!;
    final CoreSession s2 = h.store.createSession(owner.id, title: '二')!;
    await call(h.service, owner.id, s1.sessionId, task: '整理 docs');
    final CoreSubagent created = h.registry.records(owner.id, s1.sessionId).single;

    // 拿 s1 的 id 到 s2 复用：必须可读错误
    final ToolOutcome byId = await call(
      h.service,
      owner.id,
      s2.sessionId,
      task: '接着整理',
      reuse: created.id,
    );
    expect(byId.isError, isTrue);
    expect(byId.content, contains('另一个会话'));
    expect(byId.content, contains(s1.sessionId), reason: '要说清它在哪个会话里');
    expect(h.registry.records(owner.id, s2.sessionId), isEmpty,
        reason: '不许静默新建');

    // 拿名字跨会话复用：同样必须报错，不能错命中/新建
    final ToolOutcome byName = await call(
      h.service,
      owner.id,
      s2.sessionId,
      task: '接着整理',
      reuse: created.name,
    );
    expect(byName.isError, isTrue);
    expect(byName.content, contains('另一个会话'));
    expect(h.registry.records(owner.id, s2.sessionId), isEmpty);

    // 同会话内复用同名是可以的（唯一时）
    final ToolOutcome sameSession = await call(
      h.service,
      owner.id,
      s1.sessionId,
      task: '继续整理 docs 的剩余文件',
      reuse: created.name,
    );
    expect(sameSession.isError, isFalse, reason: sameSession.content);
    expect(h.registry.records(owner.id, s1.sessionId), hasLength(1),
        reason: '复用不许新建实体');
    expect(h.registry.handle(created.id)?.runCount, 2);
  });

  test('3. 重启后同一会话仍在、仍可复用（换个进程装配读同一份落盘）', () async {
    final h = harness();
    final CoreAgent owner = h.store.createAgent(name: 'leader', modelId: 'demo');
    final CoreSession s1 = h.store.createSession(owner.id, title: '一')!;
    await call(h.service, owner.id, s1.sessionId, task: '第一件事');
    final String id = h.registry.records(owner.id, s1.sessionId).single.id;
    await h.fileStore.flush();

    // "重启"：全新 FileTreeStore + 全新 registry（内存全空），只共享磁盘
    final h2 = harness(report: '第二轮的产出');
    expect(h2.registry.count, 0, reason: '新进程内存里还没有任何临时员工');
    expect(h2.store.agent(id)?.name, isNotEmpty, reason: '打开同一会话就能查到它');
    final ToolOutcome again = await call(
      h2.service,
      owner.id,
      s1.sessionId,
      task: '接着做第二件事',
      reuse: id,
    );
    expect(again.isError, isFalse, reason: again.content);
    expect(again.content, contains(id));
    expect(again.content, contains('第二轮的产出'));
    expect(h2.registry.records(owner.id, s1.sessionId), hasLength(1));
  });

  test('4. 删会话即随之消失（记录与名册都不残留）', () async {
    final h = harness();
    final CoreAgent owner = h.store.createAgent(name: 'leader', modelId: 'demo');
    final CoreSession s1 = h.store.createSession(owner.id, title: '一')!;
    await call(h.service, owner.id, s1.sessionId, task: '干活');
    final String id = h.registry.records(owner.id, s1.sessionId).single.id;
    final String roster = paths.subagentsFile(owner.id, s1.sessionId);
    await h.fileStore.flush(); // write-behind：落盘断言前先等队列排空
    expect(File(roster).existsSync(), isTrue);

    expect(h.store.deleteSession(owner.id, s1.sessionId), isTrue);
    await h.fileStore.flush();
    expect(h.store.subAgentsInSession(owner.id, s1.sessionId), isEmpty);
    expect(h.store.agent(id), isNull);
    expect(h.registry.handle(id), isNull);
    expect(File(roster).existsSync(), isFalse, reason: '名册随会话目录一起删');
  });

  test('5. 不落成全局 agent：agents/ 无 sub_*、名册/寻址/计数都不含它', () async {
    final h = harness();
    final CoreAgent owner = h.store.createAgent(name: 'leader', modelId: 'demo');
    final CoreSession s1 = h.store.createSession(owner.id)!;
    final int before = h.store.agent(owner.id)!.teamMemberCount;
    await call(h.service, owner.id, s1.sessionId, task: '干活');
    final String id = h.registry.records(owner.id, s1.sessionId).single.id;
    await h.fileStore.flush();

    // agents/ 目录里没有任何 sub_*
    final List<String> agentFiles = Directory(paths.agentsDir)
        .listSync()
        .map((FileSystemEntity e) => e.uri.pathSegments.last)
        .toList(growable: false);
    expect(
      agentFiles.where((String n) => n.startsWith(SubagentLimits.idPrefix)),
      isEmpty,
      reason: '临时员工绝不写 agents/<id>.yaml',
    );
    expect(
      Directory(paths.sessionsDataDir)
          .listSync()
          .map((FileSystemEntity e) => e.uri.pathSegments.last)
          .where((String n) => n.startsWith(SubagentLimits.idPrefix)),
      isEmpty,
      reason: '它也没有自己的 data/<id>/ 目录',
    );

    // 名册口径
    expect(h.store.agents().map((CoreAgent a) => a.id), isNot(contains(id)));
    expect(h.store.teams().map((CoreAgent a) => a.id), isNot(contains(id)));
    expect(h.store.members(owner.id), isEmpty);
    expect(h.store.agent(owner.id)!.teamMemberCount, before,
        reason: 'team_member_count 不含临时员工');

    // message 寻址不到它（团队内寻址的目标只能是成员/直属 leader/其它 TOP）
    final TeamService teams = TeamService(store: h.store, settings: settings);
    expect(teams.resolveMessageTarget(owner.id, id), isNull);
    expect(teams.lastTargetReason, 'not_found');
    expect(teams.resolveMessageTarget(owner.id, h.registry.handle(id)!.name), isNull);
  });
}
