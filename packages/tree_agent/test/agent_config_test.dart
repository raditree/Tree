import 'package:test/test.dart';
import 'package:tree_agent/tree_agent.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

void main() {
  group('sha256Hex（缺省状态目录的多工作空间隔离键靠它）', () {
    test('对齐 FIPS 180-4 已知向量', () {
      expect(
        sha256Hex(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      // 两个分组（> 64 字节）：验证 padding 与多块循环
      expect(
        sha256Hex(
          'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('不同 root 得到不同 key，同一 root 稳定', () {
      expect(AgentConfig.stateKey('/a/ws'), AgentConfig.stateKey('/a/ws'));
      expect(AgentConfig.stateKey('/a/ws'), isNot(AgentConfig.stateKey('/a/ws2')));
      expect(AgentConfig.stateKey('/a/ws/../ws'), AgentConfig.stateKey('/a/ws'));
      expect(AgentConfig.stateKey('/a/ws').length, 16);
    });
  });

  group('AgentConfig.parse', () {
    test('缺 --root / --token 都报可读错', () {
      expect(
        () => AgentConfig.parse(<String>['--token', 't']),
        throwsA(isA<AgentConfigException>()),
      );
      expect(
        () => AgentConfig.parse(<String>['--root', '/ws']),
        throwsA(isA<AgentConfigException>()),
      );
    });

    test('无法识别的参数报错（带用法）', () {
      expect(
        () => AgentConfig.parse(<String>['--nope']),
        throwsA(
          isA<AgentConfigException>().having(
            (AgentConfigException e) => e.message,
            'message',
            contains('无法识别的参数'),
          ),
        ),
      );
    });

    test('--idle-timeout-ms 必须是**非负**整数（负数 / 非数字都拒）', () {
      expect(
        () => AgentConfig.parse(<String>[
          '--root',
          '/ws',
          '--token',
          't',
          '--idle-timeout-ms',
          '-1',
        ]),
        throwsA(isA<AgentConfigException>()),
      );
      expect(
        () => AgentConfig.parse(<String>[
          '--root',
          '/ws',
          '--token',
          't',
          '--idle-timeout-ms',
          'abc',
        ]),
        throwsA(isA<AgentConfigException>()),
      );
    });

    test('正常解析：root 归一化、idle 缺省 0 = 永不', () {
      final AgentConfig config = AgentConfig.parse(
        <String>['--root', '/a/b/../c/', '--token', 'sekret'],
        environment: <String, String>{'HOME': '/home/u'},
      );
      expect(config.root, '/a/c');
      expect(config.token, 'sekret');
      expect(config.idleTimeout, isNull);
      expect(config.home, '/home/u');
    });

    test('--idle-timeout-ms 0 也是"永不"；正数才武装定时器', () {
      expect(
        AgentConfig.parse(<String>[
          '--root',
          '/ws',
          '--token',
          't',
          '--idle-timeout-ms',
          '0',
        ]).idleTimeout,
        isNull,
      );
      expect(
        AgentConfig.parse(<String>[
          '--root',
          '/ws',
          '--token',
          't',
          '--idle-timeout-ms',
          '5000',
        ]).idleTimeout,
        const Duration(milliseconds: 5000),
      );
    });
  });

  group('缺省状态目录', () {
    test(r'$HOME/.tree/agent/state/<sha256(root) 前 16 hex>', () {
      final String dir = AgentConfig.defaultStateDir('/ws', '/home/u');
      expect(dir, '/home/u/$kAgentStateDir/${AgentConfig.stateKey('/ws')}');
      expect(dir, startsWith('/home/u/.tree/agent/state/'));
    });

    test(r'HOME 为空时退到相对当前目录（不硬编码绝对路径）', () {
      expect(
        AgentConfig.defaultStateDir('/ws', ''),
        '.tree/agent/state/${AgentConfig.stateKey('/ws')}',
      );
    });

    test('--state-dir 覆盖缺省值并归一化', () {
      final AgentConfig config = AgentConfig.parse(<String>[
        '--root',
        '/ws',
        '--token',
        't',
        '--state-dir',
        '/tmp/x/../state',
      ]);
      expect(config.stateDir, '/tmp/state');
    });

    test('多工作空间互不串扰（不同 root ⇒ 不同状态目录）', () {
      expect(
        AgentConfig.defaultStateDir('/ws/a', '/home/u'),
        isNot(AgentConfig.defaultStateDir('/ws/b', '/home/u')),
      );
    });
  });

  group('环境与平台探测', () {
    test('homeOf：HOME 优先，退 USERPROFILE', () {
      expect(AgentConfig.homeOf(<String, String>{'HOME': '/h'}), '/h');
      expect(
        AgentConfig.homeOf(<String, String>{'USERPROFILE': 'C:/Users/u'}),
        'C:/Users/u',
      );
      expect(AgentConfig.homeOf(<String, String>{}), '');
    });

    test('detectArch 从 Platform.version 形状里取架构', () {
      expect(
        AgentConfig.detectArch(
          '3.13.4 (stable) (Tue Sep 15 01:01:15 2026 -0700) on "linux_x64"',
        ),
        'x64',
      );
      expect(
        AgentConfig.detectArch(
          '3.13.4 (stable) (x) on "linux_arm64"',
        ),
        'arm64',
      );
      expect(AgentConfig.detectArch('拿去解析不了的串'), '');
    });
  });
}
