import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

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

    test('压缩估算与实际上下文同口径（阈值不失真）', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(name: 'a', modelId: 'demo')
        ..systemPrompt = '你是助手';
      final CoreSession session =
          store.session(agent.id, TreeStore.defaultSessionId)!;
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
}
