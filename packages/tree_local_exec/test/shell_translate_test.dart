import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// Windows 上命令是否走 PowerShell（见 [Shell.windowsShell] 的探测顺序）。
///
/// 非 Windows / 退回 cmd.exe 时跳过「真机执行」用例：cmd 本来就支持 && / ||，
/// 翻译器在这些平台上也不会被调用。
bool get _isPowerShellWindows =>
    Platform.isWindows && !Shell.windowsShell.toLowerCase().endsWith('cmd.exe');

/// 期望串里反复出现的 $? ：抽成常量，免得满屏转义。
const String _ok = r'$?';
const String _fail = r'-not $?';

void main() {
  group('translateLogicalOperators：顶层 && / ||', () {
    test('没有运算符时逐字节不变', () {
      const List<String> commands = <String>[
        'echo hello',
        'echo   hello   ',
        'git status --short',
        r'echo a#b',
        'echo 中文测试',
        'Get-ChildItem -Recurse | Out-Null',
        "echo 'it''s fine'",
        'echo one\r\necho two\r\n',
      ];
      for (final String command in commands) {
        expect(
          Shell.translateLogicalOperators(command),
          command,
          reason: '没有顶层运算符就不该动一个字节：$command',
        );
      }
    });

    test(r'a && b → a; if (`$?`) { b }', () {
      expect(
        Shell.translateLogicalOperators('echo a && echo b'),
        'echo a; if ($_ok) { echo b }',
      );
    });

    test(r'a || b → a; if (-not `$?`) { b }', () {
      expect(
        Shell.translateLogicalOperators('cmd /c exit 1 || echo fallback'),
        'cmd /c exit 1; if ($_fail) { echo fallback }',
      );
    });

    test('多段链按左折叠平铺展开', () {
      expect(
        Shell.translateLogicalOperators('echo 1 && echo 2 && echo 3'),
        'echo 1; if ($_ok) { echo 2 }; if ($_ok) { echo 3 }',
      );
      expect(
        Shell.translateLogicalOperators('echo 1 && echo 2 || echo 3'),
        'echo 1; if ($_ok) { echo 2 }; if ($_fail) { echo 3 }',
      );
    });

    test('顶层分号是语句边界：链不会吞掉后面的语句', () {
      expect(
        Shell.translateLogicalOperators('echo a && echo b; echo c'),
        'echo a; if ($_ok) { echo b }; echo c',
      );
    });

    test('多行命令：每条语句各自折叠，换行与 CRLF 原样保留', () {
      expect(
        Shell.translateLogicalOperators('cd app && npm ci\nnpm test\n'),
        'cd app; if ($_ok) { npm ci }\nnpm test\n',
      );
      expect(
        Shell.translateLogicalOperators('echo a && echo b\r\necho c\r\n'),
        'echo a; if ($_ok) { echo b }\r\necho c\r\n',
      );
    });

    test('语句末尾悬着运算符时换行是行继续，链可以跨行', () {
      expect(
        Shell.translateLogicalOperators('echo a &&\necho b'),
        'echo a; if ($_ok) { echo b }',
      );
    });

    test('运算符两侧多余空格被规整，命令内容不缺不多', () {
      expect(
        Shell.translateLogicalOperators('  echo a   &&   echo b  '),
        'echo a; if ($_ok) { echo b }',
      );
    });

    test('重定向与 2>&1 不被误伤', () {
      expect(
        Shell.translateLogicalOperators(r'git log > out.txt 2>&1 && echo ok'),
        'git log > out.txt 2>&1; if ($_ok) { echo ok }',
      );
    });
  });

  group('翻译器的引号处理', () {
    test('引号内的 && / || 原样保留', () {
      const List<String> commands = <String>[
        r'echo "x && y"',
        r"echo 'x || y'",
        r'echo "a || b && c"',
      ];
      for (final String command in commands) {
        expect(
          Shell.translateLogicalOperators(command),
          command,
          reason: '引号内不是运算符：$command',
        );
      }
    });

    test('引号内保留、引号外翻译', () {
      expect(
        Shell.translateLogicalOperators(r'echo "x && y" && echo done'),
        r'echo "x && y"; if ($?) { echo done }',
      );
      expect(
        Shell.translateLogicalOperators(r"echo 'x || y' || echo done"),
        r"echo 'x || y'; if (-not $?) { echo done }",
      );
    });

    test('双引号内的两个双引号、单引号内的两个单引号都是字面引号', () {
      expect(
        Shell.translateLogicalOperators(
          r'echo "say ""x && y"" now" && echo done',
        ),
        r'echo "say ""x && y"" now"; if ($?) { echo done }',
      );
      expect(
        Shell.translateLogicalOperators(r"echo 'it''s a && b' && echo done"),
        r"echo 'it''s a && b'; if ($?) { echo done }",
      );
    });

    test('双引号内的反引号转义不提前结束字符串', () {
      expect(
        Shell.translateLogicalOperators(r'echo "a `" && b" && echo done'),
        r'echo "a `" && b"; if ($?) { echo done }',
      );
    });

    test('顶层反引号转义不参与配对', () {
      // 反引号把第一个 & 转义成字面 &，剩下单个 & 凑不成运算符 → 原样返回
      expect(Shell.translateLogicalOperators(r'echo `&& b'), r'echo `&& b');
    });
  });

  group('保守回退：拿不准就原样返回', () {
    test('引号不闭合 / 链残缺 / 注释 / here-string', () {
      const List<String> commands = <String>[
        r'echo "unterminated && echo b',
        "echo 'unterminated || echo b",
        'echo a &&',
        '&& echo b',
        'echo a && && echo b',
        'echo a && echo b # 注释 && echo c',
        'echo a <# 块注释 #> && echo b',
        r'echo @"x && y"@ && echo b',
        "echo @'x && y'@ && echo b",
      ];
      for (final String command in commands) {
        expect(
          Shell.translateLogicalOperators(command),
          command,
          reason: '必须原样返回（宁可让 PowerShell 报错）：$command',
        );
      }
    });

    test('token 中间的 # 不是注释，照常翻译', () {
      expect(
        Shell.translateLogicalOperators('echo a#b && echo c'),
        'echo a#b; if ($_ok) { echo c }',
      );
    });
  });

  group('包装层接线', () {
    test('PowerShell 分支包出来的 -Command 里没有裸 && / ||', () {
      if (!_isPowerShellWindows) return;
      final List<String> args = Shell.argsFor('echo a && echo b');
      expect(args.first, '-NoProfile');
      expect(args, contains('-Command'));
      final String wrapped = args.last;
      expect(wrapped, contains(r'if ($?) { echo b }'));
      expect(wrapped.contains('&&'), isFalse, reason: '包装后的命令不该再含 &&');
      expect(wrapped.contains('||'), isFalse, reason: '包装后的命令不该再含 ||');
    });
  });

  group('真机执行：翻译后的命令在 PowerShell 上真的能跑', () {
    late Directory root;
    late LocalWorkspaceIO io;

    setUp(() {
      root = Directory.systemTemp.createTempSync('tree_shell_');
      io = LocalWorkspaceIO(root.path);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('echo a && echo b：两条都跑，退出码 0，没有 ParserError', () async {
      if (!_isPowerShellWindows) return;
      final ExecOutcome outcome = await io.exec('echo first && echo second');
      expect(outcome.exitCode, 0, reason: outcome.stderr);
      expect(outcome.stdout, contains('first'));
      expect(outcome.stdout, contains('second'));
      expect(outcome.stderr, isNot(contains('ParserError')));
      expect(
        outcome.stderr,
        isNot(contains('not a valid statement separator')),
      );
    });

    test('多段链 a && b && c：按顺序都跑', () async {
      if (!_isPowerShellWindows) return;
      final ExecOutcome outcome = await io.exec(
        'echo s1 && echo s2 && echo s3',
      );
      expect(outcome.exitCode, 0, reason: outcome.stderr);
      expect(
        outcome.stdout.indexOf('s1'),
        lessThan(outcome.stdout.indexOf('s2')),
      );
      expect(
        outcome.stdout.indexOf('s2'),
        lessThan(outcome.stdout.indexOf('s3')),
      );
    });

    test('&& 前面失败：后面不跑，退出码透传', () async {
      if (!_isPowerShellWindows) return;
      final ExecOutcome outcome = await io.exec('cmd /c exit 3 && echo never');
      expect(outcome.exitCode, 3, reason: 'cmd 的退出码要透传到工具层');
      expect(outcome.stdout, isNot(contains('never')));
    });

    test('|| 前面失败：补跑后面那条', () async {
      if (!_isPowerShellWindows) return;
      final ExecOutcome outcome = await io.exec(
        'cmd /c exit 1 || echo fallback',
      );
      expect(outcome.stdout, contains('fallback'));
    });

    test('混用链 a && b || c：a 失败时跳到 c', () async {
      if (!_isPowerShellWindows) return;
      final ExecOutcome outcome = await io.exec(
        'cmd /c exit 3 && echo no || echo yes',
      );
      expect(outcome.stdout, contains('yes'));
      expect(outcome.stdout, isNot(contains('no')));
    });

    test('引号内的 && 原样输出', () async {
      if (!_isPowerShellWindows) return;
      final ExecOutcome outcome = await io.exec('echo "x && y"');
      expect(outcome.exitCode, 0, reason: outcome.stderr);
      expect(outcome.stdout, contains('x && y'));
    });

    test('链后面的语句不被吞掉：a && b; echo c 里 c 一定跑', () async {
      if (!_isPowerShellWindows) return;
      final ExecOutcome outcome = await io.exec(
        'cmd /c exit 5 && echo no; echo always',
      );
      expect(outcome.stdout, contains('always'));
      expect(outcome.stdout, isNot(contains('no')));
    });
  });
  group('裸 echo 兼容翻译（cmd 语义：输出一个空行）', () {
    test('命令位置上的无参 echo 补成空串参数', () {
      expect(Shell.translateBareEcho('echo; echo done'), "echo ''; echo done");
      expect(
        Shell.translateBareEcho('git status; echo; git log'),
        "git status; echo ''; git log",
      );
      expect(Shell.translateBareEcho('echo'), "echo ''");
      expect(Shell.translateBareEcho('echo   '), "echo ''   ");
      expect(Shell.translateBareEcho('echo | Out-Null'), "echo '' | Out-Null");
      expect(
        Shell.translateBareEcho('Write-Output; echo x'),
        "Write-Output ''; echo x",
      );
      expect(Shell.translateBareEcho('a && echo'), "a && echo ''");
      // 换行也是语句边界
      expect(
        Shell.translateBareEcho('echo\necho done'),
        "echo ''\necho done",
      );
    });

    test('有参数 / 引号内 / 注释里 / 名字更长的一律不动', () {
      expect(Shell.translateBareEcho('echo hi'), 'echo hi');
      expect(Shell.translateBareEcho("echo ''"), "echo ''");
      expect(Shell.translateBareEcho(r'echo $x'), r'echo $x');
      expect(Shell.translateBareEcho('Write-Host "echo;"'), 'Write-Host "echo;"');
      expect(Shell.translateBareEcho('echo "a; echo"'), 'echo "a; echo"');
      expect(Shell.translateBareEcho('function echo { }'), 'function echo { }');
      expect(Shell.translateBareEcho('# echo;\necho done'), '# echo;\necho done');
      expect(Shell.translateBareEcho('echoes'), 'echoes');
      expect(Shell.translateBareEcho('echo-tree'), 'echo-tree');
    });

    test('拿不准就整体原样返回（引号不闭合 / here-string / 块注释）', () {
      expect(
        Shell.translateBareEcho('echo "unclosed; echo'),
        'echo "unclosed; echo',
      );
      expect(Shell.translateBareEcho("@'\necho;\n'@"), "@'\necho;\n'@");
      expect(Shell.translateBareEcho('<# echo; #>'), '<# echo; #>');
    });

    test('包装层接线：裸 echo 既补了空串、也不进交互模式', () {
      if (!_isPowerShellWindows) return;
      final List<String> args = Shell.argsFor('echo; echo done');
      expect(args.last, contains("echo ''"));
      expect(args, contains('-NonInteractive'));
    });
  });

}
