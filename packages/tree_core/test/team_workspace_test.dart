import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 团队工作目录口径（2026-10-02 用户定夺）：**成员与团队 TOP 共享同一个工作目录**。
///
/// 这里钉住三件事，任何一条被改都会让"成员的活与 leader 不在同一目录"回归
/// （用户实测：成员文件写进了 `workspaces/<member_id>`，teammates 窗口与文件面板都看不到）：
/// 1. 成员一路向上解析到 TOP（中间层成员也一样）；
/// 2. 成员自己 yaml 里的 `workspace_dir` **不生效**（共享口径优先，不能被旧配置悄悄覆盖）；
/// 3. 异常配置（上级不存在 / 成环）不会死循环，退化成"以自己为准"。
void main() {
  CoreAgent agent(
    String id, {
    String parent = '',
    String team = '',
    String dir = '',
  }) => CoreAgent(
    id: id,
    name: id,
    createdAt: 0,
    updatedAt: 0,
    parentAgentId: parent,
    teamId: team,
    workspaceDir: dir,
  );

  CoreAgent? Function(String id) lookupOf(List<CoreAgent> agents) {
    final Map<String, CoreAgent> table = <String, CoreAgent>{
      for (final CoreAgent a in agents) a.id: a,
    };
    return (String id) => table[id];
  }

  group('teamWorkspaceFor：成员跟随团队 TOP', () {
    test('TOP 自己解析到自己（口径与共享之前完全一致）', () {
      final CoreAgent top = agent('top', dir: r'E:\programs\tmp');
      final TeamWorkspace shared = teamWorkspaceFor(top, lookupOf(<CoreAgent>[top]));
      expect(shared.owner.id, 'top');
      expect(shared.configuredDir, r'E:\programs\tmp');
    });

    test('成员解析到 TOP，且自己 yaml 里的 workspace_dir 不生效', () {
      final CoreAgent top = agent('top', dir: r'E:\programs\tmp');
      final CoreAgent member = agent(
        'member',
        parent: 'top',
        team: 'top',
        dir: r'C:\elsewhere\独立目录',
      );
      final TeamWorkspace shared = teamWorkspaceFor(
        member,
        lookupOf(<CoreAgent>[top, member]),
      );
      expect(shared.owner.id, 'top');
      expect(shared.configuredDir, r'E:\programs\tmp');
    });

    test('多级成员（成员的下级）同样落到 TOP', () {
      final CoreAgent top = agent('top', dir: '/mnt/proj');
      final CoreAgent mid = agent('mid', parent: 'top', team: 'top', dir: '/mid');
      final CoreAgent leaf = agent('leaf', parent: 'mid', team: 'top', dir: '/leaf');
      final TeamWorkspace shared = teamWorkspaceFor(
        leaf,
        lookupOf(<CoreAgent>[top, mid, leaf]),
      );
      expect(shared.owner.id, 'top');
      expect(shared.configuredDir, '/mnt/proj');
    });

    test('TOP 未配置目录：configuredDir 为空，由调用方用 owner 的默认目录', () {
      final CoreAgent top = agent('top');
      final CoreAgent member = agent('member', parent: 'top', team: 'top');
      final TeamWorkspace shared = teamWorkspaceFor(
        member,
        lookupOf(<CoreAgent>[top, member]),
      );
      expect(shared.owner.id, 'top');
      expect(shared.configuredDir, isEmpty);
    });

    test('上级不存在（被删/跨库）：以自己为准，不抛错', () {
      final CoreAgent member = agent('member', parent: 'ghost', team: 'ghost');
      final TeamWorkspace shared = teamWorkspaceFor(member, lookupOf(<CoreAgent>[]));
      expect(shared.owner.id, 'member');
    });

    test('配置成环也不会死循环（a → b → a）', () {
      final CoreAgent a = agent('a', parent: 'b', dir: '/a');
      final CoreAgent b = agent('b', parent: 'a', dir: '/b');
      final TeamWorkspace shared = teamWorkspaceFor(a, lookupOf(<CoreAgent>[a, b]));
      expect(<String>['a', 'b'], contains(shared.owner.id));
      expect(shared.configuredDir, isNotEmpty);
    });
  });

  group('接线点：FileService / 系统提示词都按共享目录走', () {
    (MemoryStore, CoreAgent, CoreAgent) fixtures() {
      final MemoryStore store = MemoryStore();
      final CoreAgent top = store.createAgent(name: '队长', modelId: 'demo')
        ..workspaceDir = r'E:\programs\tmp';
      store.putAgent(top);
      final CoreAgent member = store.createAgent(name: '成员', modelId: 'demo')
        ..parentAgentId = top.id
        ..teamId = top.id;
      store.putAgent(member);
      return (store, top, member);
    }

    test('FileService.rootFor：成员用 TOP 的目录；TOP 未配置时用 TOP 的默认目录', () {
      final (MemoryStore store, CoreAgent top, CoreAgent member) = fixtures();
      final FileService files = FileService(
        store: store,
        defaultWorkspaceDir: (String id) => '/data/workspaces/$id',
      );
      expect(files.rootFor(member), r'E:\programs\tmp');
      expect(files.rootFor(top), r'E:\programs\tmp');

      // TOP 未配置：成员跟随 TOP 的**默认**目录（不是成员自己的默认目录）
      top.workspaceDir = '';
      store.putAgent(top);
      expect(files.rootFor(member), '/data/workspaces/${top.id}');
    });

    test('系统提示词：接线后成员说的是 TOP 的目录；未接线保持旧口径', () {
      final (MemoryStore store, CoreAgent top, CoreAgent member) = fixtures();

      // 旧口径（provider 未接线）：成员说的是它自己的默认目录
      expect(workspacePromptSuffix(member), contains('workspaces/${member.id}'));

      addTearDown(() => teamWorkspaceProvider = null);
      teamWorkspaceProvider = (CoreAgent a) => teamWorkspaceFor(a, store.agent);
      expect(workspacePromptSuffix(member), contains(r'E:\programs\tmp'));
      expect(
        workspacePromptSuffix(member),
        isNot(contains('workspaces/${member.id}')),
      );
      // TOP 自己的提示词不受接线影响（字节不变 ⇒ 前缀缓存不受影响）
      expect(workspacePromptSuffix(top), contains(r'E:\programs\tmp'));
    });
  });

  group('teamSshConfigFor：成员跟随 TOP 的 SSH', () {
    const SshConfig topSsh = SshConfig(
      host: '192.168.0.208',
      username: 'open',
      root: '/mnt/space',
    );

    test('成员没有自己的 ssh ⇒ 用 TOP 那份（同一台远端主机、同一个根）', () {
      final CoreAgent top = agent('top')..sshConfig = topSsh;
      final CoreAgent member = agent('member', parent: 'top', team: 'top');
      expect(
        teamSshConfigFor(member, lookupOf(<CoreAgent>[top, member]))?.host,
        '192.168.0.208',
      );
      expect(
        teamSshConfigFor(member, lookupOf(<CoreAgent>[top, member]))?.root,
        '/mnt/space',
      );
    });

    test('成员自己配了 ssh ⇒ 以自己那份为准（手工配置优先）', () {
      final CoreAgent top = agent('top')..sshConfig = topSsh;
      final CoreAgent member = agent('member', parent: 'top', team: 'top')
        ..sshConfig = const SshConfig(host: '10.0.0.9');
      expect(
        teamSshConfigFor(member, lookupOf(<CoreAgent>[top, member]))?.host,
        '10.0.0.9',
      );
    });

    test('TOP 自己：返回它原有的配置（没配置仍是 null）', () {
      final CoreAgent top = agent('top')..sshConfig = topSsh;
      expect(
        teamSshConfigFor(top, lookupOf(<CoreAgent>[top]))?.host,
        '192.168.0.208',
      );
      final CoreAgent plain = agent('plain');
      expect(teamSshConfigFor(plain, lookupOf(<CoreAgent>[plain])), isNull);
    });

    test('系统提示词：SSH 团队的成员说的是 TOP 的远端根 + 自己的私有目录', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent top = store.createAgent(name: '队长', modelId: 'demo')
        ..sshConfig = topSsh;
      store.putAgent(top);
      final CoreAgent member = store.createAgent(name: '成员', modelId: 'demo')
        ..parentAgentId = top.id
        ..teamId = top.id;
      store.putAgent(member);
      addTearDown(() => teamWorkspaceProvider = null);
      teamWorkspaceProvider = (CoreAgent a) => teamWorkspaceFor(a, store.agent);
      final String prompt = workspacePromptSuffix(member);
      expect(prompt, contains('/mnt/space'));
      expect(prompt, contains(privateSelfDir(member.id)));
    });
  });
}