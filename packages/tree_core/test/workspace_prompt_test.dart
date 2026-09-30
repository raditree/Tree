import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// M8a：工作空间**软约束**。
///
/// 锁两件事：
/// 1. **根不收窄**——本地 agent 的根是 \`workspace_dir\`，SSH agent 的根就是
///    \`ssh.root\`（留空 = 远端登录用户的 \`HOME\`）。数据文件与项目文件常分处
///    根下不同子目录，所以提示词只做"按用户指示定位"的软引导，不逼用户改根。
/// 2. 提示词与压缩估算**共用同一个函数**：估算若只看 \`agent.systemPrompt\`，
///    加了这段之后压缩阈值就会失真，因此这里直接对比两者。
void main() {
  CoreAgent makeAgent() {
    final MemoryStore store = MemoryStore();
    return store.createAgent(name: '工作空间用例', modelId: 'demo');
  }

  group('工作空间软约束（M8a）', () {
    test('本机 agent：根取 workspace_dir；未配置时说明默认目录', () {
      final CoreAgent agent = makeAgent();
      final String byDefault = workspacePromptSuffix(agent);
      expect(byDefault, contains('workspaces/${agent.id}'));
      expect(byDefault, contains('本机'));

      agent.workspaceDir = 'E:/proj/tree';
      final String configured = workspacePromptSuffix(agent);
      expect(configured, contains('E:/proj/tree'));
      expect(configured, isNot(contains('workspaces/${agent.id}')));
    });

    test('SSH agent：根就是 ssh.root；留空 = 远端登录用户 HOME（不收窄）', () {
      final CoreAgent agent = makeAgent();
      agent.sshConfig = const SshConfig(
        host: '192.168.0.208',
        username: 'open',
        keyPath: '/home/me/.ssh/id_ed25519',
      );
      final String byHome = workspacePromptSuffix(agent);
      expect(byHome, contains('open'));
      expect(byHome, contains('HOME'));

      agent.sshConfig = const SshConfig(
        host: '192.168.0.208',
        username: 'open',
        keyPath: '/home/me/.ssh/id_ed25519',
        root: '/mnt/space',
      );
      final String rooted = workspacePromptSuffix(agent);
      expect(rooted, contains('/mnt/space'));
      expect(rooted, isNot(contains('远端登录用户')));
    });

    test('是软约束：说明数据/项目文件可能分处不同子目录、不得自行收窄', () {
      final String text = workspacePromptSuffix(makeAgent());
      expect(text, contains('软约束'));
      expect(text, contains('数据文件与项目文件'));
      expect(text, contains('不要自行收窄'));
    });

    test('追加不覆盖用户自己的提示词；空/空白提示词只留约束段', () {
      final CoreAgent agent = makeAgent()..systemPrompt = '你是助手。';
      final String appended = systemPromptWithWorkspace(agent);
      expect(appended, startsWith('你是助手。'));
      expect(appended, contains('## 工作空间'));

      agent.systemPrompt = '   ';
      final String onlyConstraint = systemPromptWithWorkspace(agent);
      expect(onlyConstraint, startsWith('## 工作空间'));
      expect(onlyConstraint, isNot(contains('   \n')));
    });

    test('Q9：Spec 索引随提示词注入（provider / 显式参数），默认不注入', () {
      final CoreAgent agent = makeAgent();
      // 默认（核心没接线 Spec 服务）：与 M8a 完全一致
      expect(systemPromptWithWorkspace(agent), isNot(contains('Spec 索引')));

      // 可设置的 provider：会话生成与压缩估算两处自动同口径
      addTearDown(() => specIndexProvider = null);
      specIndexProvider = (CoreAgent _) => '- `general-task` [easy] 简单任务（内置）';
      final String wired = systemPromptWithWorkspace(agent);
      expect(wired, contains('## Spec 索引（任务型规范）'));
      expect(wired, contains('`general-task`'));
      expect(wired, startsWith('## 工作空间'), reason: '索引追加在软约束之后');

      // 显式参数优先于 provider（调用方已经算好索引时用）
      final String explicit = systemPromptWithWorkspace(
        agent,
        specIndex: '- `custom-x` [custom] 自定义',
      );
      expect(explicit, contains('`custom-x`'));
      expect(explicit, isNot(contains('`general-task`')));

      // provider 返回空白 = 不注入（不要多出一个空章节）
      specIndexProvider = (CoreAgent _) => '   ';
      expect(systemPromptWithWorkspace(agent), isNot(contains('Spec 索引')));
    });

    test('Q9 ⑧：已选 Spec 全文按会话注入（provider / 显式参数 / 空则不注入）', () {
      final CoreAgent agent = makeAgent();
      expect(
        systemPromptWithWorkspace(agent, sessionId: 'ses_1'),
        isNot(contains('已选 Spec 全文')),
      );

      final List<String> asked = <String>[];
      addTearDown(() => selectedSpecsProvider = null);
      selectedSpecsProvider = (CoreAgent _, String sessionId) {
        asked.add(sessionId);
        return '### Spec: general-task\n先侦察再规划';
      };
      final String wired = systemPromptWithWorkspace(agent, sessionId: 'ses_1');
      expect(wired, contains('## 已选 Spec 全文（本会话挂的 hook）'));
      expect(wired, contains('### Spec: general-task'));
      expect(wired, contains('先侦察再规划'), reason: '注入的是全文，不是只有 id');
      expect(asked, <String>['ses_1'], reason: 'hook 是会话级的，必须把 sessionId 传下去');
      expect(
        wired.indexOf('## Spec 索引'),
        lessThan(wired.indexOf('## 已选 Spec 全文')),
        reason: '顺序照参考实现：先索引，再已选全文',
      );

      final String explicit = systemPromptWithWorkspace(
        agent,
        sessionId: 'ses_1',
        selectedSpecs: '### Spec: custom-x\n自定义正文',
      );
      expect(explicit, contains('custom-x'));
      expect(explicit, isNot(contains('general-task')));

      selectedSpecsProvider = (CoreAgent _, String _) => '   ';
      expect(
        systemPromptWithWorkspace(agent, sessionId: 'ses_1'),
        isNot(contains('已选 Spec 全文')),
        reason: 'provider 返回空白时不多出一个空章节',
      );
    });

    test('Q9：索引不缓存——create 之后下一轮提示词里就有它', () async {
      final Directory temp = Directory.systemTemp.createTempSync(
        'tree_prompt_',
      );
      // 索引快照会在后台补一次（含 .self/spec 播种），与删除可能有毫秒级竞争：
      // Windows 上删正在读写的目录会抛 PathAccessException，故重试几次。
      addTearDown(() async {
        for (int i = 0; i < 5; i++) {
          try {
            if (temp.existsSync()) temp.deleteSync(recursive: true);
            return;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      });
      final LocalWorkspaceIO io = LocalWorkspaceIO(temp.path);
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(name: '索引用例', modelId: 'demo');
      final SpecService specs = SpecService(store: store);
      specs.ioFor = (String _) async => io;
      addTearDown(() => specIndexProvider = null);
      specIndexProvider = (CoreAgent a) => specs.indexSnapshot(a.id);

      final String before = systemPromptWithWorkspace(agent);
      expect(before, contains('general-task'), reason: '内置 3 条随时在');
      expect(before, isNot(contains('prompt-refresh')));

      await specs.run(
        ToolInvocation(
          id: 'tool_1',
          name: 'spec',
          arguments: <String, dynamic>{
            'action': 'create',
            'title': 'Prompt Refresh',
            'workflow': 'w',
          },
          agentId: agent.id,
          sessionId: TreeStore.defaultSessionId,
        ),
        io,
      );

      expect(
        systemPromptWithWorkspace(agent),
        contains('`prompt-refresh`'),
        reason: '没有「刷新索引」动作：下一轮拼提示词时索引就是新的',
      );
    });

    test('压缩估算与实际上下文同口径（阈值不失真）', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(name: 'a', modelId: 'demo')
        ..systemPrompt = '你是助手';
      final CoreSession session = store.session(
        agent.id,
        TreeStore.defaultSessionId,
      )!;
      final CompactionService service = CompactionService(
        store: store,
        settings: CoreSettings(),
      );
      expect(
        service.estimateContextTokens(agent, session),
        estimateTokens(systemPromptWithWorkspace(agent)) +
            estimateTokens(session.compactedSummary),
      );
      expect(
        service.estimateContextTokens(agent, session),
        greaterThan(estimateTokens(agent.systemPrompt)),
        reason: '只估算 agent.systemPrompt 会漏掉软约束这段',
      );
    });
  });

  group('工作空间基础段（Q6）', () {
    test('基础段来自 provider（按 agent），个人段与软约束仍在其后', () {
      final CoreAgent agent = makeAgent()..systemPrompt = '个人指令';
      addTearDown(() => systemPromptFileProvider = null);
      expect(systemPromptWithWorkspace(agent), isNot(contains('全局约定')));

      systemPromptFileProvider = (CoreAgent _) => '全局约定';
      final String text = systemPromptWithWorkspace(agent);
      expect(text, startsWith('全局约定'));
      expect(text, contains('个人指令'));
      expect(
        text.indexOf('全局约定'),
        lessThan(text.indexOf('个人指令')),
        reason: '工作空间基础段在前，agent 个人指令在后',
      );
      expect(text, contains('## 工作空间'));

      // 只有基础段时也成立
      agent.systemPrompt = '';
      expect(systemPromptWithWorkspace(agent), startsWith('全局约定'));

      // provider 空白 = 不注入（不产生空章节）
      systemPromptFileProvider = (CoreAgent _) => '   ';
      expect(systemPromptWithWorkspace(agent), startsWith('## 工作空间'));
    });
  });

  group('系统提示词文件（Q6，工作空间 .self/system_prompt.md）', () {
    test('播种、改文件即生效、HTML 注释剥离、重置会备份 .bak.<n>', () async {
      final Directory temp = Directory.systemTemp.createTempSync(
        'tree_sysprompt_',
      );
      // 快照会在后台补一次刷新（读/写 .self/system_prompt.md），与删除有毫秒级竞争：
      // Windows 上删正在读写的目录会抛 PathAccessException，故重试几次。
      addTearDown(() async {
        for (int i = 0; i < 5; i++) {
          try {
            if (temp.existsSync()) temp.deleteSync(recursive: true);
            return;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      });
      final LocalWorkspaceIO io = LocalWorkspaceIO(temp.path);
      const String agentId = 'agt_x';

      // 未接 IO 的 store：快照为空且**不发起后台刷新**（避免与目录删除竞争）
      expect(SystemPromptStore().snapshot(agentId), isEmpty);

      final SystemPromptStore store = SystemPromptStore(
        ioFor: (String _) async => io,
      );
      // 未播种：refresh 顺手播种
      final String seeded = await store.refresh(agentId);
      expect(seeded, contains('你是当前任务的专业执行者'));
      final File file = File('${temp.path}/.self/system_prompt.md');
      expect(file.existsSync(), isTrue);

      // 用户改文件 → refresh 读到新内容，且 HTML 注释被剥离
      file.writeAsStringSync('<!-- 自说明 -->\n用户版本');
      expect(await store.refresh(agentId), '用户版本', reason: 'HTML 注释不进模型上下文');

      // 重置：备份 .bak.1 后写回默认
      final PromptResetResult reset = await store.reset(agentId, io);
      expect(reset.backup, '.self/system_prompt.md.bak.1');
      expect(reset.restored, isTrue);
      expect(
        File('${temp.path}/.self/system_prompt.md.bak.1').readAsStringSync(),
        contains('用户版本'),
      );
      expect(store.snapshot(agentId), contains('你是当前任务的专业执行者'));

      // 再重置一次：备份序号顺延，不覆盖旧备份
      final PromptResetResult again = await store.reset(agentId, io);
      expect(again.backup, '.self/system_prompt.md.bak.2');
    });
  });
}
