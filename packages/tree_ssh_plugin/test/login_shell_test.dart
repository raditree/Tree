import 'package:test/test.dart';
import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';

/// 记录探活请求的假探测器。
class _Probe {
  _Probe({this.available = const <String>{'bash', 'sh'}});

  final Set<String> available;
  final List<String> commands = <String>[];

  Future<int> call(String command) async {
    commands.add(command);
    if (command == 'command -v bash') {
      return available.contains('bash') ? 0 : 1;
    }
    if (command == 'command -v sh') {
      return available.contains('sh') ? 0 : 1;
    }
    // 自定义模板的探活：渲染后的 `true`，第一个词是外壳名。
    final String shell = command.split(' ').first;
    return available.contains(shell) ? 0 : 1;
  }
}

void main() {
  group('POSIX 单引号转义（与 tree_local_exec 逐字一致）', () {
    test('普通命令', () {
      expect(posixSingleQuote('ls -la'), "'ls -la'");
    });

    test('命令里带单引号 ⇒ \'\\\'\'', () {
      expect(posixSingleQuote("echo 'hi'"), "'echo '\\''hi'\\'''");
    });

    test(r'$ 与反引号都当字面量（不展开）', () {
      expect(posixSingleQuote(r'echo $HOME `pwd`'), r"'echo $HOME `pwd`'");
    });
  });

  group('renderLoginShellCommand', () {
    test('按模板渲染，命令被单引号包裹', () {
      expect(
        renderLoginShellCommand(template: 'bash -lc {cmd}', command: 'echo hi'),
        "bash -lc 'echo hi'",
      );
    });

    test('模板缺 {cmd} ⇒ ArgumentError（调用方跳过这一档）', () {
      expect(
        () => renderLoginShellCommand(template: 'bash -lc', command: 'x'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('LoginShell 三态模板', () {
    test('缺省（null）= 用内置候选，先探 bash 就用 bash -lc', () async {
      final _Probe probe = _Probe();
      final LoginShell shell = LoginShell(prober: probe.call);
      expect(await shell.resolve(), 'bash -lc {cmd}');
      expect(probe.commands, <String>['command -v bash']);
      expect(await shell.wrap('nvcc --version'), "bash -lc 'nvcc --version'");
    });

    test('没有 bash ⇒ 退到 sh -lc', () async {
      final _Probe probe = _Probe(available: <String>{'sh'});
      final LoginShell shell = LoginShell(prober: probe.call);
      expect(await shell.resolve(), 'sh -lc {cmd}');
      expect(probe.commands, <String>['command -v bash', 'command -v sh']);
    });

    test('两个都没有 ⇒ 不包装（命令原样发，与旧行为一致）', () async {
      final _Probe probe = _Probe(available: <String>{});
      final LoginShell shell = LoginShell(prober: probe.call);
      expect(await shell.resolve(), isNull);
      expect(await shell.wrap('echo hi'), 'echo hi');
    });

    test("空串 = 显式关掉（连探测都不做）", () async {
      final _Probe probe = _Probe();
      final LoginShell shell = LoginShell(template: '', prober: probe.call);
      expect(await shell.resolve(), isNull);
      expect(probe.commands, isEmpty);
      expect(await shell.wrap('echo hi'), 'echo hi');
    });

    test('自定义模板优先，并用"渲染后的 true"验活', () async {
      final _Probe probe = _Probe(available: <String>{'zsh'});
      final LoginShell shell = LoginShell(
        template: 'zsh -lc {cmd}',
        prober: probe.call,
      );
      expect(await shell.resolve(), 'zsh -lc {cmd}');
      expect(probe.commands, <String>["zsh -lc 'true'"]);
      expect(await shell.wrap('a b'), "zsh -lc 'a b'");
    });

    test('自定义模板非法（缺 {cmd}）⇒ 跳过这一档，退到内置候选', () async {
      final _Probe probe = _Probe();
      final LoginShell shell = LoginShell(
        template: 'zsh -lc',
        prober: probe.call,
      );
      expect(await shell.resolve(), 'bash -lc {cmd}');
      expect(probe.commands, <String>['command -v bash']);
    });
  });

  group('LoginShell 缓存与降级', () {
    test('一条隧道只探一次（第二次 resolve 不再打远端）', () async {
      final _Probe probe = _Probe();
      final LoginShell shell = LoginShell(prober: probe.call);
      await shell.resolve();
      await shell.resolve();
      await shell.wrap('x');
      expect(probe.commands.length, 1);
    });

    test('reset 之后重新探', () async {
      final _Probe probe = _Probe();
      final LoginShell shell = LoginShell(prober: probe.call);
      await shell.resolve();
      shell.reset();
      await shell.resolve();
      expect(probe.commands.length, 2);
    });

    test('探测器抛异常 ⇒ 这一档被跳过，继续下一档（不让命令失败）', () async {
      final List<String> seen = <String>[];
      final LoginShell shell = LoginShell(
        prober: (String command) async {
          seen.add(command);
          if (command == 'command -v bash') throw StateError('远端抽风');
          return 0;
        },
      );
      expect(await shell.resolve(), 'sh -lc {cmd}');
      expect(seen, <String>['command -v bash', 'command -v sh']);
    });

    test('探测过的档位留痕（诊断可读）', () async {
      final LoginShell shell = LoginShell(
        prober: (String command) async => command == 'command -v bash' ? 1 : 0,
      );
      await shell.resolve();
      expect(shell.probed.first, contains('bash'));
      expect(shell.probed.last, contains('✓'));
    });
  });
}
