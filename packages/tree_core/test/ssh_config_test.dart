import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// M4b-1：SSH 配置解析、密钥不外泄、以及"配置了 SSH 就走远端后端"的选择逻辑。
///
/// 真正的 SFTP/exec 传输（dartssh2）在 M4b-2 交付；这里用注入的假后端验证选择
/// 逻辑与失败方式（绝不静默回落本地）。
void main() {
  group('SshConfig.parse 宽容读取', () {
    test('完整口令配置与密钥配置都能解析', () {
      final SshConfig? byPassword = SshConfig.parse(<String, dynamic>{
        'host': '10.0.0.5',
        'port': 2222,
        'username': 'deploy',
        'password': 'secret',
      });
      expect(byPassword?.host, '10.0.0.5');
      expect(byPassword?.port, 2222);
      expect(byPassword?.username, 'deploy');
      expect(byPassword?.isComplete, isTrue);

      final SshConfig? byKey = SshConfig.parse(<String, dynamic>{
        'host': ' example.com ',
        'user': 'me',
        'key_path': '~/.ssh/id_ed25519',
      });
      expect(byKey?.host, 'example.com');
      expect(byKey?.port, 22, reason: '缺省端口 22');
      expect(byKey?.username, 'me', reason: 'user 是 username 的别名');
      expect(byKey?.isComplete, isTrue, reason: '有密钥即可');
    });

    test('端口可写字符串；缺 host 或非映射时返回 null', () {
      expect(
        SshConfig.parse(<String, dynamic>{'host': 'h', 'port': '2200'})?.port,
        2200,
      );
      expect(SshConfig.parse(<String, dynamic>{'port': 22}), isNull);
      expect(SshConfig.parse(<String, dynamic>{'host': '   '}), isNull);
      expect(SshConfig.parse('just a string'), isNull);
      expect(SshConfig.parse(null), isNull);
    });

    test('root / remote_root 解析进 root 并持久化；未配置不落盘', () {
      final SshConfig? parsed = SshConfig.parse(<String, dynamic>{
        'host': 'h',
        'username': 'u',
        'password': 'p',
        'remote_root': ' ~/proj ',
      });
      expect(parsed?.root, '~/proj');
      expect(parsed?.toJson()['root'], '~/proj');
      expect(parsed?.isComplete, isTrue, reason: 'root 不影响最小连接信息');

      final SshConfig plain = SshConfig.parse(<String, dynamic>{
        'host': 'h',
        'username': 'u',
        'password': 'p',
      })!;
      expect(plain.root, isEmpty);
      expect(plain.toJson().containsKey('root'), isFalse);
      expect(plain.redacted().containsKey('root'), isFalse);
    });

    test('isComplete / missingFields 指出缺什么', () {
      final SshConfig? bare = SshConfig.parse(<String, dynamic>{'host': 'h'});
      expect(bare?.isComplete, isFalse);
      expect(bare?.missingFields, containsAll(<String>['username']));
      expect(
        bare?.missingFields
            .where((String f) => f.contains('password'))
            .toList(),
        hasLength(1),
      );
    });
  });

  group('凭据不外泄', () {
    test('redacted/toString 只有 host/port/username 与认证方式', () {
      const SshConfig config = SshConfig(
        host: 'h',
        username: 'u',
        password: 'top-secret',
        keyPath: '/k',
        keyPassphrase: 'passphrase',
      );
      expect(config.redacted(), <String, dynamic>{
        'host': 'h',
        'port': 22,
        'username': 'u',
        'auth': 'password',
      });
      expect('${config.redacted()}', isNot(contains('top-secret')));
      expect('$config', isNot(contains('top-secret')));
      expect('$config', isNot(contains('passphrase')));
      expect(
        const SshConfig(
          host: 'h',
          username: 'u',
          keyPath: '/k',
        ).redacted()['auth'],
        'key',
      );
      expect(const SshConfig(host: 'h').redacted()['auth'], 'none');
    });

    test('持久化形态保留凭据（写用户自己的 agent 文件）；API 形态只给 has_ssh', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(
        name: 'ssh agent',
        modelId: 'm',
      );
      agent.sshConfig = const SshConfig(
        host: 'h',
        username: 'u',
        password: 'top-secret',
      );
      final Map<String, dynamic> persisted = agent.toJson();
      expect(
        (persisted['ssh'] as Map<String, dynamic>)['password'],
        'top-secret',
      );
      expect(CoreAgent.fromJson(persisted).sshConfig?.host, 'h');

      final Map<String, dynamic> api = agent.toApiJson();
      expect(api['has_ssh'], isTrue);
      expect('$api', isNot(contains('top-secret')));
      expect(api.containsKey('ssh'), isFalse);
    });

    test('key_path 的 ~ 会展开为用户目录', () {
      const SshConfig config = SshConfig(
        host: 'h',
        keyPath: '~/.ssh/id_ed25519',
      );
      final String resolved = config.resolvedKeyPath();
      expect(resolved.startsWith('~'), isFalse);
      expect(resolved.endsWith(p.join('.ssh', 'id_ed25519')), isTrue);
      expect(
        const SshConfig(host: 'h', keyPath: '/abs/key').resolvedKeyPath(),
        '/abs/key',
      );
    });
  });

  group('WorkspaceToolRunner 后端选择', () {
    late Directory localRoot;
    late Directory remoteRoot;

    setUp(() {
      localRoot = Directory.systemTemp.createTempSync('tree_ssh_local_');
      remoteRoot = Directory.systemTemp.createTempSync('tree_ssh_remote_');
    });

    tearDown(() {
      for (final Directory dir in <Directory>[localRoot, remoteRoot]) {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      }
    });

    ToolInvocation call(String name, Map<String, dynamic> args) =>
        ToolInvocation(
          id: 'tool_1',
          name: name,
          arguments: args,
          rawArguments: '',
          agentId: 'agt_1',
          sessionId: 'ses_1',
        );

    test('配了 SSH 且有后端工厂 → 工具落在远端后端上', () async {
      final List<SshConfig> used = <SshConfig>[];
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String id) => localRoot.path,
        resolveSshConfig: (String id) => const SshConfig(
          host: 'remote.example.com',
          username: 'u',
          password: 'pw',
        ),
        sshIoFactory: (SshConfig config) async {
          used.add(config);
          return LocalWorkspaceIO(remoteRoot.path);
        },
      );
      final ToolOutcome outcome = await runner.run(
        call('write', <String, dynamic>{
          'file_path': 'a.txt',
          'content': '远端内容',
        }),
      );
      expect(outcome.isError, isFalse);
      expect(used.single.host, 'remote.example.com');
      expect(File(p.join(remoteRoot.path, 'a.txt')).readAsStringSync(), '远端内容');
      expect(
        File(p.join(localRoot.path, 'a.txt')).existsSync(),
        isFalse,
        reason: '绝不能把远端该做的活干在本机',
      );
      await runner.close();
    });

    test('配了 SSH 但后端未接入 → 明确报错且不回落本地；日志不含口令', () async {
      final List<String> logs = <String>[];
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String id) => localRoot.path,
        resolveSshConfig: (String id) => const SshConfig(
          host: 'remote.example.com',
          username: 'u',
          password: 'top-secret',
        ),
        log: logs.add,
      );
      final ToolOutcome outcome = await runner.run(
        call('write', <String, dynamic>{'file_path': 'a.txt', 'content': 'x'}),
      );
      expect(outcome.isError, isTrue);
      expect(outcome.content, contains('SSH'));
      expect(File(p.join(localRoot.path, 'a.txt')).existsSync(), isFalse);
      expect(logs.join('\n'), contains('尚未接入'));
      expect(logs.join('\n'), isNot(contains('top-secret')));
      await runner.close();
    });

    test('SSH 配置缺 username/凭据 → 报可读原因且不回落本地', () async {
      final List<String> logs = <String>[];
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String id) => localRoot.path,
        resolveSshConfig: (String id) =>
            SshConfig.parse(<String, dynamic>{'host': 'h'}),
        sshIoFactory: (SshConfig config) async =>
            LocalWorkspaceIO(remoteRoot.path),
        log: logs.add,
      );
      final ToolOutcome outcome = await runner.run(
        call('write', <String, dynamic>{'file_path': 'a.txt', 'content': 'x'}),
      );
      expect(outcome.isError, isTrue);
      expect(logs.join('\n'), contains('SSH 配置缺少'));
      expect(logs.join('\n'), contains('username'));
      await runner.close();
    });

    test('没配 SSH 时仍走本地（不回归）', () async {
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String id) => localRoot.path,
        resolveSshConfig: (String id) => null,
      );
      final ToolOutcome outcome = await runner.run(
        call('write', <String, dynamic>{
          'file_path': 'local.txt',
          'content': 'local',
        }),
      );
      expect(outcome.isError, isFalse);
      expect(File(p.join(localRoot.path, 'local.txt')).existsSync(), isTrue);
      await runner.close();
    });
  });
}
