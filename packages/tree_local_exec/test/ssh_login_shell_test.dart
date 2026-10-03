import 'package:test/test.dart';
import 'package:tree_local_exec/src/ssh_login_shell.dart';

/// 远端命令的登录外壳包装（用户 2026-10-03：「SSH 下也有类似情况：我有 nvcc，另一个 agent 没有」）。
/// 判据：默认走登录外壳；bash 不在退 sh；都不在**原样发**；自定义模板可用；关得掉；
/// 模板写坏不会让命令失败。探测用注入的假实现，不碰真 SSH。
void main() {
  test(r'POSIX 单引号转义：单引号、$、反引号、换行都当字面量', () {
    expect(posixSingleQuote('ls -la'), "'ls -la'");
    // 单引号走 POSIX 的经典穿壳写法：' → '\''
    expect(posixSingleQuote("it's"), r"'it'\''s'");
    expect(posixSingleQuote(r'echo $HOME `id`'), r"'echo $HOME `id`'");
    expect(posixSingleQuote('a\nb'), "'a\nb'");
  });

  test('渲染：模板带 {cmd} 时替换成转义后的命令；缺占位符要报错（不静默发半条）', () {
    expect(
      renderLoginShellCommand(template: 'bash -lc {cmd}', command: 'which nvcc'),
      "bash -lc 'which nvcc'",
    );
    expect(
      () => renderLoginShellCommand(template: 'bash -lc', command: 'x'),
      throwsArgumentError,
    );
  });

  test('默认：bash 可用就用 bash', () async {
    final List<String> probed = <String>[];
    final SshLoginShell shell = SshLoginShell(
      prober: (String command) async {
        probed.add(command);
        return true;
      },
    );
    expect(await shell.resolve(), 'bash -lc {cmd}');
    expect(probed, <String>["bash -lc 'true'"], reason: '探测一次就够，别每条命令都探');
    expect(await shell.wrap('which nvcc'), "bash -lc 'which nvcc'");
    expect(probed, hasLength(1), reason: '结论要缓存');
  });

  test('bash 不可用 ⇒ 退到 sh', () async {
    final SshLoginShell shell = SshLoginShell(
      prober: (String command) async => command.startsWith('sh '),
    );
    expect(await shell.resolve(), 'sh -lc {cmd}');
    expect(await shell.wrap('which nvcc'), "sh -lc 'which nvcc'");
  });

  test('两个都不可用 ⇒ 原样发（与今天行为一致）并留日志', () async {
    final List<String> logs = <String>[];
    final SshLoginShell shell = SshLoginShell(
      prober: (String command) async => false,
      log: logs.add,
    );
    expect(await shell.resolve(), isNull);
    expect(await shell.wrap('which nvcc'), 'which nvcc');
    expect(logs, isNotEmpty, reason: '回退要留痕');
  });

  test('自定义模板优先；它探测失败就退回内置候选', () async {
    final SshLoginShell custom = SshLoginShell(
      template: 'zsh -lc {cmd}',
      prober: (String command) async => command.startsWith('zsh '),
    );
    expect(await custom.resolve(), 'zsh -lc {cmd}');

    final SshLoginShell fallback = SshLoginShell(
      template: 'zsh -lc {cmd}',
      prober: (String command) async => command.startsWith('bash '),
      log: (_) {},
    );
    expect(await fallback.resolve(), 'bash -lc {cmd}');
  });

  test('空模板 = 显式关掉：不探测、不包装', () async {
    bool probed = false;
    final SshLoginShell off = SshLoginShell(
      template: '',
      prober: (String command) async {
        probed = true;
        return true;
      },
    );
    expect(await off.resolve(), isNull);
    expect(await off.wrap('which nvcc'), 'which nvcc');
    expect(probed, isFalse);
  });

  test('模板写坏（缺 {cmd}）只跳过那一档，不影响后面的兜底', () async {
    final List<String> logs = <String>[];
    final SshLoginShell broken = SshLoginShell(
      template: 'bash -lc',
      prober: (String command) async => true,
      log: logs.add,
    );
    expect(await broken.resolve(), 'bash -lc {cmd}');
    expect(logs.any((String m) => m.contains('跳过不可用的登录外壳模板')), isTrue);
  });

  test('reset 之后重新探测（换连接 / 排障用）', () async {
    int calls = 0;
    final SshLoginShell shell = SshLoginShell(
      prober: (String command) async {
        calls++;
        return true;
      },
    );
    await shell.resolve();
    await shell.resolve();
    expect(calls, 1);
    shell.reset();
    await shell.resolve();
    expect(calls, 2);
  });
}
