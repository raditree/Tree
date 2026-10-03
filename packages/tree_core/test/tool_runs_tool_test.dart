import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
// 刻意只 import 用到的 src 文件（本仓库测试的既有做法）：不走 `package:tree_core/tree_core.dart`
// 聚合入口，避免把并行同事的中间态编译错误算到本测试头上。
import 'package:tree_core/src/agent/subagent_service.dart';
import 'package:tree_core/src/settings/core_settings.dart';
import 'package:tree_core/src/store/memory_store.dart';
import 'package:tree_core/src/store/records.dart';
import 'package:tree_core/src/store/subagent_registry.dart';
import 'package:tree_core/src/store/subagent_store.dart';
import 'package:tree_core/src/team/team_service.dart';
import 'package:tree_core/src/tool/builtin_tools.dart';
import 'package:tree_core/src/tool/subagent_tool.dart';
import 'package:tree_core/src/tool/tool_run_registry.dart';
import 'package:tree_core/src/tool/tool_runner.dart';
import 'package:tree_core/src/tool/tool_runs_scope.dart';
import 'package:tree_core/src/tool/tool_runs_tool.dart';
import 'package:tree_core/src/tool/workspace_tool_runner.dart';

/// **内置工具 `tool_runs`**（plan `20261003-running-tools` §11.3 冻结契约）。
///
/// 病根（见 `.self/recon-arch-stability.md` §2.7/§2.8）：工具执行没有静态上限 ⇒ 一条
/// 不返回的命令让整批工具永不结束 ⇒ 引擎把批中途到来的用户消息无限延期 ⇒ teammate
/// 永久失联（"批卡死、消息只能进不能出"）。§11.1 定案"不支持转 hook 的工具一直等，
/// 直到被用户 / 插件 / **上级 agent** 显式取消" ⇒ 上级 agent 手上必须有**同一个**
/// 关闭入口，因此有了这个内置工具：
///
/// - `action=list`：本 agent **自己 + 其直属下级**的在途运行（字段与 REST 快照同源）；
/// - `action=close`：按 handle 调**同一个** closer（`ToolRunRegistry.close`——右栏
///   "关闭"按钮的 REST 与执行站 `tool.close` 走的就是它）；
/// - fail-closed：句柄失效 / 不属于自己或自己的直属下级 / 未接线 ⇒ **可读原因**。
///
/// 时钟口径（避免 flaky）：登记表注入假时钟 `now: () => _fakeNow`，用推进假时钟制造
/// "已超阈值"，不依赖真实等待。
void main() {
  const String session = 'ses-top';

  /// terminal 的"跑很久"命令（本地路径，让在途调用真能挂住）。
  String longCommand(int seconds) =>
      Platform.isWindows ? 'Start-Sleep -Seconds $seconds' : 'sleep $seconds';

  group('工具声明', () {
    test('只在显式要求时声明——裸 specs() 里没有它（行为不变）', () {
      expect(
        BuiltinTools.specs().map((ToolSpec s) => s.name),
        isNot(contains(ToolRunsTool.name)),
        reason: '既有断言「M4 只声明 5 个工作空间工具」不能被悄悄改掉',
      );
      expect(
        BuiltinTools.specs(withToolRuns: true).map((ToolSpec s) => s.name),
        contains(ToolRunsTool.name),
      );
      expect(
        BuiltinTools.needsWorkspace(ToolRunsTool.name),
        isFalse,
        reason: '工作空间不可用时（SSH 配置不全等）它也必须能用——它不读文件',
      );
    });

    test('schema：action 必填且只有 list / close；handle 与 member_id 的语义写清', () {
      final ToolSpec spec = ToolRunsTool.spec();
      expect(spec.name, 'tool_runs');
      final Map<String, dynamic> parameters = spec.parameters;
      expect(parameters['required'], <String>['action']);
      final Map<String, dynamic> properties =
          parameters['properties'] as Map<String, dynamic>;
      expect(
        (properties['action'] as Map<String, dynamic>)['enum'],
        <String>['list', 'close'],
      );
      expect(properties.containsKey('handle'), isTrue);
      expect(properties.containsKey('member_id'), isTrue);
      expect(
        ((properties['handle'] as Map<String, dynamic>)['description'] as String),
        contains('toolrun_'),
      );
      expect(
        ((properties['handle'] as Map<String, dynamic>)['description'] as String),
        contains('stuck_tools'),
        reason: 'handle 从哪来必须写在 schema 里（list 或 query_status.stuck_tools）',
      );
    });

    test('描述写清三件事：什么时候用 / handle 从哪来 / close 是显式终止不是自动杀', () {
      final String text = ToolRunsTool.spec().description;
      expect(text, contains('长时间不返回'), reason: '什么时候用');
      expect(text, contains('tool_runs action=list'), reason: 'handle 从哪来');
      expect(text, contains('纯内存'), reason: '句柄不跨核心重启存活');
      expect(text, contains('显式'), reason: 'close 的语义');
      expect(text, contains('自动'), reason: 'close 是显式终止，不是自动杀');
      expect(text, contains('直属下级'), reason: '作用域');
    });
  });

  group('action=list：本 agent 自己 + 直属下级', () {
    late Directory temp;
    late MemoryStore store;
    late TeamService team;
    late ToolRunRegistry registry;
    late WorkspaceToolRunner runner;
    late List<String> logs;
    late String ws;
    late CoreAgent top;
    late String member;
    late String grandMember;
    late CoreAgent otherTop;
    int fakeNow = 0;

    setUp(() {
      fakeNow = 1000;
      logs = <String>[];
      temp = Directory.systemTemp.createTempSync('tree_tool_runs_tool_');
      ws = p.join(temp.path, 'ws');
      Directory(ws).createSync(recursive: true);
      store = MemoryStore();
      team = TeamService(store: store, settings: CoreSettings());
      registry = ToolRunRegistry(
        threshold: const Duration(seconds: 300),
        now: () => fakeNow,
      );
      addTearDown(registry.shutdown);
      top = store.createAgent(name: '队长', maxLevel: 3, maxMembersPerLevel: 7);
      member =
          team.createMember(top.id, <String, dynamic>{
                'action': 'create_member',
                'member_name': '成员甲',
              })['member_id']
              as String;
      // 隔代成员（成员甲的直属下级）：**不该**出现在 TOP 的清单里（契约 = 直属下级）
      grandMember =
          team.createMember(member, <String, dynamic>{
                'action': 'create_member',
                'member_name': '成员乙',
              })['member_id']
              as String;
      otherTop = store.createAgent(name: '别的队');
      runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String _) => ws,
        toolRuns: registry,
        teamService: team,
        log: logs.add,
      );
      addTearDown(runner.close);
    });

    tearDown(() async {
      for (int i = 0; i < 5; i++) {
        try {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    Future<ToolOutcome> listAs(String agentId, String sessionId) => runner.run(
      ToolInvocation(
        id: 'call-list',
        name: ToolRunsTool.name,
        arguments: <String, dynamic>{'action': 'list'},
        agentId: agentId,
        sessionId: sessionId,
      ),
    );

    test('字段与 REST 快照同源（handle/agent_id/session_id/tool/command_preview/'
        'started_at/elapsed_ms/over_threshold + hint）；隔代与外人不可见', () async {
      final ToolRun selfRun = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{
          'command': 'find /mnt/space -name "M4_REPORT.md"',
        },
        agentId: top.id,
        sessionId: session,
      );
      final ToolRun memberRun = registry.start(
        tool: 'grep',
        arguments: <String, dynamic>{'pattern': '分层', 'regex': true},
        agentId: member,
        sessionId: 'ses-member',
      );
      final ToolRun grandRun = registry.start(
        tool: 'read',
        arguments: <String, dynamic>{'file_path': 'a.md'},
        agentId: grandMember,
        sessionId: 'ses-grand',
      );
      final ToolRun alienRun = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': 'sleep 9'},
        agentId: otherTop.id,
        sessionId: 'ses-alien',
      );
      fakeNow += 400000; // 越过 300 s 阈值

      final ToolOutcome outcome = await listAs(top.id, session);
      expect(outcome.isError, isFalse, reason: outcome.content);
      final String text = outcome.content;

      expect(text, contains('正在执行的工具运行'));
      expect(text, contains('作用域：本 agent 自己 + 其直属下级'));
      expect(text, contains('超阈值 300s'));

      // 自己 + 直属下级：可见
      expect(text, contains(selfRun.handle));
      expect(text, contains(memberRun.handle));
      // 隔代下级 / 不相干的另一个 TOP：不可见
      expect(text, isNot(contains(grandRun.handle)), reason: '契约是**直属**下级');
      expect(text, isNot(contains(alienRun.handle)), reason: '别人的运行不许出现');

      // 冻结字段（名字与 REST 快照逐字一致）
      expect(text, contains('handle=${selfRun.handle}'));
      expect(text, contains('agent_id=${top.id}'));
      expect(text, contains('agent_id=$member'));
      expect(text, contains('session_id=ses-member'));
      expect(text, contains('tool=grep'));
      expect(text, contains('started_at=1000'));
      expect(text, contains('elapsed_ms=400000'));
      expect(text, contains('over_threshold=true'));
      expect(text, contains('command_preview:'));
      expect(text, contains('"pattern":"分层"'), reason: 'command_preview 是参数摘要');

      // 防呆 hint：口径复用 query_status.stuck_tools 那一份（stuckToolHint）
      expect(text, contains('hint:'));
      expect(text, contains('find'));
      expect(text, contains('-maxdepth'));
      expect(text, contains('tool.close'));

      // 收手指引：模型该用 tool_runs action=close（而不是插件命令）
      expect(text, contains('tool_runs action=close'));

      registry.finish(selfRun);
      registry.finish(memberRun);
      registry.finish(grandRun);
      registry.finish(alienRun);
    });

    test('未超阈值的项 over_threshold=false 且**不带 hint**（hint 只给卡住的）', () async {
      registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': 'echo hi'},
        agentId: member,
        sessionId: 'ses-member',
      );
      final ToolOutcome outcome = await listAs(top.id, session);
      expect(outcome.content, contains('over_threshold=false'));
      expect(
        outcome.content,
        isNot(contains('hint:')),
        reason: '没到阈值就不该报"疑似卡住"',
      );
    });

    test('空表：登记表里一条在途运行都没有时可读空态（没瞎报）', () async {
      final ToolRunRegistry empty = ToolRunRegistry(
        threshold: const Duration(seconds: 300),
        now: () => fakeNow,
      );
      addTearDown(empty.shutdown);
      final ToolOutcome outcome = await ToolRunsTool.run(
        ToolInvocation(
          id: 'call-list',
          name: ToolRunsTool.name,
          arguments: <String, dynamic>{'action': 'list'},
          agentId: top.id,
          sessionId: session,
        ),
        ToolRunsScope(registry: empty, teamService: team),
      );
      expect(outcome.isError, isFalse);
      expect(outcome.content, contains('当前没有正在执行的工具'));
      expect(outcome.content, contains('本 agent 自己 + 其直属下级'));
    });

    test('未知 action ⇒ 可读错误（列出可用动作）', () async {
      final ToolOutcome outcome = await runner.run(
        ToolInvocation(
          id: 'call-x',
          name: ToolRunsTool.name,
          arguments: <String, dynamic>{'action': 'nope'},
          agentId: top.id,
          sessionId: session,
        ),
      );
      expect(outcome.isError, isTrue);
      expect(outcome.content, contains('未知 action'));
      expect(outcome.content, contains('list'));
      expect(outcome.content, contains('close'));
    });
  });

  group('action=close：与右栏 / 执行站同一个 closer', () {
    late Directory temp;
    late MemoryStore store;
    late TeamService team;
    late ToolRunRegistry registry;
    late WorkspaceToolRunner runner;
    late List<String> logs;
    late String ws;
    late CoreAgent top;
    late String member;
    late String grandMember;
    int fakeNow = 0;

    setUp(() {
      fakeNow = 1000;
      logs = <String>[];
      temp = Directory.systemTemp.createTempSync('tree_tool_runs_close_');
      ws = p.join(temp.path, 'ws');
      Directory(ws).createSync(recursive: true);
      store = MemoryStore();
      team = TeamService(store: store, settings: CoreSettings());
      registry = ToolRunRegistry(
        threshold: const Duration(seconds: 120),
        now: () => fakeNow,
      );
      addTearDown(registry.shutdown);
      top = store.createAgent(name: '队长', maxLevel: 3, maxMembersPerLevel: 7);
      member =
          team.createMember(top.id, <String, dynamic>{
                'action': 'create_member',
                'member_name': '成员甲',
              })['member_id']
              as String;
      grandMember =
          team.createMember(member, <String, dynamic>{
                'action': 'create_member',
                'member_name': '成员乙',
              })['member_id']
              as String;
      runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String _) => ws,
        toolRuns: registry,
        teamService: team,
        log: logs.add,
      );
      addTearDown(runner.close);
      registry.terminate = runner.terminateToolRun;
    });

    tearDown(() async {
      for (int i = 0; i < 5; i++) {
        try {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    Future<ToolOutcome> closeAs(
      String agentId,
      String handle, {
      String memberId = '',
    }) => runner.run(
      ToolInvocation(
        id: 'call-close',
        name: ToolRunsTool.name,
        arguments: <String, dynamic>{
          'action': 'close',
          'handle': handle,
          if (memberId.isNotEmpty) 'member_id': memberId,
        },
        agentId: agentId,
        sessionId: 'ses-top',
      ),
    );

    test('关下级的在途调用 ⇒ 它**立刻收敛**（批能收尾）+ 登记表清空', () async {
      final Stopwatch watch = Stopwatch()..start();
      final Future<ToolOutcome> pending = runner.run(
        ToolInvocation(
          id: 'call-long',
          name: 'terminal',
          arguments: <String, dynamic>{'command': longCommand(3)},
          agentId: member, // 直属下级的活
          sessionId: 'ses-member',
        ),
      );

      // 等它真的在跑（登记表里出现这次运行）
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while (registry.length == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final ToolRun run = registry.list().single;
      expect(run.tool, 'terminal');
      expect(run.agentId, member);

      final ToolOutcome closed = await closeAs(top.id, run.handle);
      expect(closed.isError, isFalse, reason: closed.content);
      expect(closed.content, contains('已关闭一次工具运行'));
      expect(closed.content, contains(run.handle));
      expect(closed.content, contains('收敛'));
      expect(closed.content, contains('不要直接重跑'));
      expect(
        registry.list().where((ToolRun r) => r.tool == 'terminal'),
        isEmpty,
        reason: '登记表里不能再留这条 terminal 运行',
      );

      final ToolOutcome outcome = await pending.timeout(
        const Duration(seconds: 2),
      );
      watch.stop();
      expect(outcome.isError, isTrue, reason: '被关闭的调用如实标记为错误结果');
      expect(outcome.content, contains('【已按显式关闭请求终止】'));
      expect(outcome.content, contains(run.handle));
      expect(
        watch.elapsed.inSeconds,
        lessThan(3),
        reason: '关闭必须让在途调用立刻收敛，而不是等命令跑完',
      );
    });

    test('参数 member_id：与运行归属一致通过；不一致 ⇒ 拒绝并提示抄错 handle', () async {
      final ToolRun run = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': 'sleep 300'},
        agentId: member,
        sessionId: 'ses-member',
      );
      registry.terminate = (ToolRun r) async => '测试：没有本机进程句柄';

      final ToolOutcome mismatched = await closeAs(
        top.id,
        run.handle,
        memberId: grandMember,
      );
      expect(mismatched.isError, isTrue);
      expect(mismatched.content, contains('不符'));
      expect(registry.length, 1, reason: '拒绝时**不许**动登记表');

      final ToolOutcome ok = await closeAs(
        top.id,
        run.handle,
        memberId: member,
      );
      expect(ok.isError, isFalse, reason: ok.content);
      expect(registry.length, 0);
    });

    test('句柄失效 ⇒ 可读原因（fail-closed，不假装成功）', () async {
      final ToolOutcome outcome = await closeAs(top.id, 'toolrun_1_abcd_1');
      expect(outcome.isError, isTrue);
      expect(outcome.content, contains('已失效'));
      expect(outcome.content, contains('toolrun_1_abcd_1'));
      expect(outcome.content, contains('内存'), reason: '要说明句柄是纯内存、重启即清空');
    });

    test('拒绝非自己或非直属下级：外人 / 隔代 / 缺 handle', () async {
      final ToolRun alien = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': 'sleep 300'},
        agentId: 'agt_stranger',
        sessionId: 'ses-x',
      );
      final ToolOutcome denied = await closeAs(top.id, alien.handle);
      expect(denied.isError, isTrue);
      expect(denied.content, contains('不属于你或你的直属下级'));
      expect(denied.content, contains(alien.handle));
      expect(denied.content, contains('agt_stranger'), reason: '要说清它归谁');
      expect(registry.length, 1, reason: '拒绝 = 一个字都不动');

      // 隔代（成员甲的下级）也不算"我的直属下级"
      final ToolRun grand = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': 'sleep 300'},
        agentId: grandMember,
        sessionId: 'ses-grand',
      );
      final ToolOutcome deniedGrand = await closeAs(top.id, grand.handle);
      expect(deniedGrand.isError, isTrue);
      expect(deniedGrand.content, contains('不属于你或你的直属下级'));
      expect(registry.length, 2);

      // 但它的直接上级（成员甲）可以关
      final ToolOutcome byParent = await closeAs(member, grand.handle);
      expect(byParent.isError, isFalse, reason: byParent.content);
      expect(registry.length, 1);

      final ToolOutcome noHandle = await closeAs(top.id, '');
      expect(noHandle.isError, isTrue);
      expect(noHandle.content, contains('需要 handle'));
      expect(noHandle.content, contains('toolrun_'));
      registry.finish(alien);
    });

    test('未接线：没有登记表 / 没有进程终止器 ⇒ 都可读原因，不静默', () async {
      final ToolOutcome unbound = await BuiltinTools.run(
        ToolInvocation(
          id: 'call-close',
          name: ToolRunsTool.name,
          arguments: <String, dynamic>{
            'action': 'close',
            'handle': 'toolrun_1_abcd_1',
          },
          agentId: top.id,
          sessionId: 'ses-top',
        ),
        null,
      );
      expect(unbound.isError, isTrue);
      expect(unbound.content, contains('未接线'));
      expect(unbound.content, contains('登记表'));

      // 登记表在、但没人接线"终止进程树"：关闭仍生效（在途调用收敛），
      // note 如实说明没杀到进程（不假装杀成功）
      final ToolRunRegistry bare = ToolRunRegistry(
        threshold: const Duration(seconds: 300),
        now: () => fakeNow,
      );
      addTearDown(bare.shutdown);
      final ToolRun run = bare.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': 'sleep 300'},
        agentId: member,
        sessionId: 'ses-member',
      );
      final ToolOutcome outcome = await ToolRunsTool.run(
        ToolInvocation(
          id: 'call-close',
          name: ToolRunsTool.name,
          arguments: <String, dynamic>{
            'action': 'close',
            'handle': run.handle,
          },
          agentId: top.id,
          sessionId: 'ses-top',
        ),
        ToolRunsScope(registry: bare, teamService: team),
      );
      expect(outcome.isError, isFalse, reason: outcome.content);
      expect(outcome.content, contains('未接线'));
      expect(bare.length, 0);
      expect(run.isCloseRequested, isTrue);
    });
  });

  group('作用域：临时员工（直属临时员工算下级，隔代不算）', () {
    late MemoryStore inner;
    late SubagentRegistry subRegistry;
    late SubagentStore subStore;
    late SubagentService subService;
    late ToolRunRegistry registry;
    late CoreAgent owner;
    int fakeNow = 0;

    setUp(() {
      fakeNow = 1000;
      inner = MemoryStore();
      subRegistry = SubagentRegistry(persistence: inner);
      subStore = SubagentStore(inner: inner, registry: subRegistry);
      subService = SubagentService(
        store: subStore,
        registry: subRegistry,
        settings: CoreSettings(),
      );
      registry = ToolRunRegistry(
        threshold: const Duration(seconds: 300),
        now: () => fakeNow,
      );
      addTearDown(registry.shutdown);
      owner = inner.createAgent(name: '发起者');
      _putSub(subRegistry, owner, 'sub_1', '临时员工甲', owner.id, 1);
      _putSub(subRegistry, owner, 'sub_2', '临时员工乙', 'sub_1', 2);
    });

    test('directSubagentsOf 只认本会话的**直属**（复用名册既有的 parentId 关系）', () {
      expect(
        subService
            .directSubagentsOf(owner.id, 'ses-1')
            .map((SubagentTag t) => t.id)
            .toList(),
        <String>['sub_1'],
        reason: 'sub_2 是 sub_1 的下级（隔代），不算 owner 的直属',
      );
      expect(
        subService
            .directSubagentsOf('sub_1', 'ses-1')
            .map((SubagentTag t) => t.id)
            .toList(),
        <String>['sub_2'],
        reason: '临时员工也能看自己召的下级',
      );
      expect(
        subService.directSubagentsOf(owner.id, 'ses-other'),
        isEmpty,
        reason: '名册按会话分栏，跨会话不保留（硬不变量）',
      );
      expect(subService.directSubagentsOf(owner.id, ''), isEmpty);
    });

    test('listVisible / closeVisible：直属临时员工的活可见可关，隔代的不可见', () async {
      final ToolRunsScope scope = ToolRunsScope(
        registry: registry,
        subagents: subService,
      );
      final ToolRun mine = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': 'find / -name x'},
        agentId: owner.id,
        sessionId: 'ses-1',
      );
      final ToolRun child = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': 'sleep 300'},
        agentId: 'sub_1',
        sessionId: 'ses-1',
      );
      final ToolRun grand = registry.start(
        tool: 'terminal',
        arguments: <String, dynamic>{'command': 'sleep 300'},
        agentId: 'sub_2',
        sessionId: 'ses-1',
      );
      fakeNow += 400000;

      final List<String> visible = scope
          .listVisible(agentId: owner.id, sessionId: 'ses-1')
          .map((ToolRun r) => r.handle)
          .toList();
      expect(visible, contains(mine.handle));
      expect(visible, contains(child.handle));
      expect(visible, isNot(contains(grand.handle)), reason: '隔代不是"直属下级"');

      // sub_1 看自己的下级
      expect(
        scope
            .listVisible(agentId: 'sub_1', sessionId: 'ses-1')
            .map((ToolRun r) => r.handle),
        contains(grand.handle),
      );

      final ToolCloseOutcome denied = await scope.closeVisible(
        agentId: owner.id,
        sessionId: 'ses-1',
        handle: grand.handle,
      );
      expect(denied.closed, isFalse);
      expect(denied.note, contains('不属于你或你的直属下级'));
      expect(registry.length, 3, reason: '拒绝不动登记表');

      final ToolCloseOutcome ok = await scope.closeVisible(
        agentId: owner.id,
        sessionId: 'ses-1',
        handle: child.handle,
      );
      expect(ok.closed, isTrue);
      expect(registry.length, 2);
      expect(ok.note, contains('未接线'), reason: '没接终止器 ⇒ 如实说没杀到进程');
      scope.registry.finish(mine);
      scope.registry.finish(grand);
    });
  });
}

/// 往名册里放一条临时员工记录（只带 `tool_runs` 作用域解析需要的字段）。
void _putSub(
  SubagentRegistry registry,
  CoreAgent owner,
  String id,
  String name,
  String parentId,
  int level,
) {
  registry.put(
    CoreSubagent(
      id: id,
      name: name,
      ownerAgentId: owner.id,
      sessionId: 'ses-1',
      parentId: parentId,
      level: level,
      agent: CoreAgent(id: id, name: name, createdAt: 0, updatedAt: 0),
      createdAt: 0,
      updatedAt: 0,
    ),
  );
}
