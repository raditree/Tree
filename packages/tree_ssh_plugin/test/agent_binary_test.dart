import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tree_ssh_plugin_binary_');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  List<int> bytes([int size = 128]) =>
      List<int>.generate(size, (int i) => (i * 3) % 256);

  File writeAgent(String relative, List<int> content) {
    final File file = File('${tmp.path}${Platform.pathSeparator}$relative');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(content);
    return file;
  }

  AgentBinaryResolver resolverFor(List<String> dirs) =>
      AgentBinaryResolver(searchDirsOverride: dirs);

  group('定位随包 agent', () {
    test('在候选目录里按 arch 名字找到（名字带 {arch} 占位也能展开）', () async {
      final List<int> content = bytes();
      writeAgent('agents/tree_agent-linux-amd64', content);
      final AgentBinary binary = await resolverFor(<String>[
        '${tmp.path}${Platform.pathSeparator}agents',
      ]).call(const AgentRequest(version: '1.0.0'), 'amd64');
      expect(binary.bytes, content);
      expect(binary.name, 'tree_agent-linux-amd64');
      expect(binary.sha256, sha256Hex(content));
    });

    test('binary_name 里的 {arch} 会展开', () async {
      writeAgent('agents/tree_agent-arm64', bytes());
      final AgentBinary binary = await resolverFor(<String>[
        '${tmp.path}${Platform.pathSeparator}agents',
      ]).call(
        const AgentRequest(version: '1.0.0', binaryName: 'tree_agent-{arch}'),
        'arm64',
      );
      expect(binary.name, 'tree_agent-arm64');
    });

    test('binary_path 优先于候选目录', () async {
      final File explicit = writeAgent('other/我的agent', bytes(64));
      writeAgent('agents/tree_agent-linux-amd64', bytes(128));
      final AgentBinary binary = await resolverFor(<String>[
        '${tmp.path}${Platform.pathSeparator}agents',
      ]).call(
        AgentRequest(version: '1.0.0', binaryPath: explicit.path),
        'amd64',
      );
      expect(binary.path, explicit.path);
      expect(binary.size, 64);
    });

    test('候选目录按顺序取第一个命中（不猜、不乱挑）', () async {
      writeAgent('first/tree_agent-linux-amd64', bytes(16));
      writeAgent('second/tree_agent-linux-amd64', bytes(32));
      final String sep = Platform.pathSeparator;
      final AgentBinary binary = await resolverFor(<String>[
        '${tmp.path}${sep}second',
        '${tmp.path}${sep}first',
      ]).call(const AgentRequest(version: '1.0.0'), 'amd64');
      expect(binary.size, 32);
    });
  });

  group('完整性校验（失败一律 push_failed）', () {
    test('找不到 ⇒ push_failed，且消息里列出找过哪些路径', () async {
      await expectLater(
        resolverFor(<String>['${tmp.path}${Platform.pathSeparator}agents'])
            .call(const AgentRequest(version: '1.0.0'), 'amd64'),
        throwsA(
          isA<AgentBinaryException>()
              .having(
                (AgentBinaryException e) => e.kind,
                'kind',
                TunnelErrorKinds.pushFailed,
              )
              .having(
                (AgentBinaryException e) => e.message,
                'message',
                contains('tree_agent-linux-amd64'),
              ),
        ),
      );
    });

    test('空文件不算"找到了"', () async {
      writeAgent('agents/tree_agent-linux-amd64', <int>[]);
      await expectLater(
        resolverFor(<String>['${tmp.path}${Platform.pathSeparator}agents'])
            .call(const AgentRequest(version: '1.0.0'), 'amd64'),
        throwsA(isA<AgentBinaryException>()),
      );
    });

    test('与核心声明的 bytes_sha256 不一致 ⇒ push_failed（打包坏了，别推上去）', () async {
      writeAgent('agents/tree_agent-linux-amd64', bytes());
      await expectLater(
        resolverFor(<String>['${tmp.path}${Platform.pathSeparator}agents']).call(
          const AgentRequest(version: '1.0.0', bytesSha256: 'deadbeef'),
          'amd64',
        ),
        throwsA(
          isA<AgentBinaryException>()
              .having(
                (AgentBinaryException e) => e.message,
                'message',
                contains('sha256'),
              ),
        ),
      );
    });

    test('声明与本地一致 ⇒ 通过（核心声明是可信输入，仍要核对）', () async {
      final List<int> content = bytes();
      writeAgent('agents/tree_agent-linux-amd64', content);
      final AgentBinary binary = await resolverFor(<String>[
        '${tmp.path}${Platform.pathSeparator}agents',
      ]).call(
        AgentRequest(version: '1.0.0', bytesSha256: sha256Hex(content)),
        'amd64',
      );
      expect(binary.sha256, sha256Hex(content));
    });
  });

  group('默认候选目录（与核心侧的打包约定对齐）', () {
    test('包含「插件可执行文件同级 plugins/ 的上一级 + agents/」', () {
      final String sep = Platform.pathSeparator;
      final String exeDir = File(Platform.resolvedExecutable).parent.path;
      final String parent = File(exeDir).parent.path;
      final List<String> dirs = AgentBinaryResolver().searchDirs();
      // 发行包：<应用目录>/plugins/tree_ssh_executor.exe + <应用目录>/agents/...
      // 开发态：<仓根>/build/plugins/... + <仓根>/build/agents/...
      expect(dirs, contains('$parent${sep}agents'));
      // 同级与 cwd 兜底也在
      expect(dirs, contains('$exeDir${sep}agents'));
      expect(dirs.length, greaterThanOrEqualTo(4));
    });

    test('注入 override 时不做任何猜测', () {
      final List<String> dirs = <String>['/x/agents'];
      expect(
        AgentBinaryResolver(searchDirsOverride: dirs).searchDirs(),
        same(dirs),
      );
    });
  });
}
