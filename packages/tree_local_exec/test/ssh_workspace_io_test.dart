import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

import 'fake_ssh_transport.dart';

void main() {
  late FakeSshTransport t;
  late SshWorkspaceIO io;

  setUp(() {
    t = FakeSshTransport();
    io = SshWorkspaceIO('/ws', t);
  });

  group('resolve', () {
    test('拼接相对路径并做 POSIX 归一化', () {
      expect(io.resolve('a/b.txt'), '/ws/a/b.txt');
      expect(io.resolve('  a.txt  '), '/ws/a.txt');
      expect(io.resolve('.'), '/ws');
      expect(io.resolve('a/./b'), '/ws/a/b');
    });

    test('拒绝空路径与绝对路径', () {
      expect(() => io.resolve(''), throwsA(isA<WorkspacePathException>()));
      expect(() => io.resolve('   '), throwsA(isA<WorkspacePathException>()));
      expect(
        () => io.resolve('/etc/passwd'),
        throwsA(isA<WorkspacePathException>()),
      );
      expect(() => io.resolve('~/x'), throwsA(isA<WorkspacePathException>()));
      expect(() => io.resolve('C:/x'), throwsA(isA<WorkspacePathException>()));
    });

    test('拒绝 .. 逃出根目录', () {
      expect(
        () => io.resolve('../out'),
        throwsA(isA<WorkspacePathException>()),
      );
      expect(
        () => io.resolve('a/../../out'),
        throwsA(isA<WorkspacePathException>()),
      );
    });

    test('relativize 反向给出工作空间相对路径', () {
      expect(io.relativize('/ws/a/b.txt'), 'a/b.txt');
      expect(io.relativize('/ws'), '.');
    });
  });

  group('readFile', () {
    test('整文件读取带行数与语言标识', () async {
      t.seed('/ws/a.txt', 'l1\nl2\nl3\nl4');
      final FileContent c = await io.readFile('a.txt');
      expect(c.text, 'l1\nl2\nl3\nl4');
      expect(c.totalLines, 4);
      expect(c.startLine, 1);
      expect(c.truncated, isFalse);
      expect(c.language, 'txt');
      expect(c.base64, isNull);
    });

    test('结尾换行保真（远端同口径）', () async {
      t.seed('/ws/nl.txt', 'a\nb\n');
      final FileContent c = await io.readFile('nl.txt');
      expect(c.text, 'a\nb\n', reason: '结尾换行不能被吃掉');
      expect(c.totalLines, 2);
      expect(
        (await io.readFile('nl.txt', startLine: 1, lineCount: 1)).text,
        'a',
        reason: '只取中段 ⇒ 不补结尾换行',
      );
    });

    test('行范围读取标记 truncated', () async {
      t.seed('/ws/a.txt', 'l1\nl2\nl3\nl4');
      final FileContent c = await io.readFile(
        'a.txt',
        startLine: 2,
        lineCount: 2,
      );
      expect(c.text, 'l2\nl3');
      expect(c.startLine, 2);
      expect(c.totalLines, 4);
      expect(c.truncated, isTrue);
    });

    test('start_line 越界报错，缺文件翻成可读错误', () async {
      t.seed('/ws/a.txt', 'l1\nl2');
      expect(
        () => io.readFile('a.txt', startLine: 9),
        throwsA(isA<WorkspaceIoException>()),
      );
      expect(
        () => io.readFile('missing.txt'),
        throwsA(isA<WorkspaceIoException>()),
      );
    });

    test('二进制文件拒绝当文本读', () async {
      t.seedBytes('/ws/bin.dat', <int>[1, 0, 2]);
      expect(
        () => io.readFile('bin.dat'),
        throwsA(
          isA<WorkspaceIoException>().having(
            (WorkspaceIoException e) => e.toString(),
            'message',
            contains('二进制'),
          ),
        ),
      );
    });

    test('图像扩展名走 base64 分支', () async {
      t.seedBytes('/ws/pic.png', <int>[137, 80, 78, 71, 1, 2, 3]);
      final FileContent c = await io.readFile('pic.png');
      expect(c.text, '');
      expect(c.base64, isNotNull);
      expect(base64Decode(c.base64!), <int>[137, 80, 78, 71, 1, 2, 3]);
      expect(c.language, 'png');
    });
  });

  group('writeFile / editFile', () {
    test('写入按 UTF-8 编码投递', () async {
      final int n = await io.writeFile('sub/x.txt', 'héllo');
      expect(n, utf8.encode('héllo').length);
      expect(utf8.decode(t.files['/ws/sub/x.txt']!), 'héllo');
    });

    test('唯一匹配编辑', () async {
      t.seed('/ws/e.txt', 'alpha\nbeta\nalpha\n');
      final EditOutcome out = await io.editFile(
        'e.txt',
        oldText: 'beta',
        newText: 'BETA',
      );
      expect(out.replacements, 1);
      expect(out.path, 'e.txt');
      expect(utf8.decode(t.files['/ws/e.txt']!), 'alpha\nBETA\nalpha\n');
    });

    test('多命中且未开启 replace_all 直接报错', () async {
      t.seed('/ws/e.txt', 'alpha\nalpha\n');
      expect(
        () => io.editFile('e.txt', oldText: 'alpha', newText: 'x'),
        throwsA(isA<WorkspaceIoException>()),
      );
      final EditOutcome all = await io.editFile(
        'e.txt',
        oldText: 'alpha',
        newText: 'A',
        replaceAll: true,
      );
      expect(all.replacements, 2);
      expect(utf8.decode(t.files['/ws/e.txt']!), 'A\nA\n');
    });

    test('CRLF 文件保留 CRLF，且 old_text 可用 LF 匹配', () async {
      t.seedBytes('/ws/crlf.txt', utf8.encode('one\r\ntwo\r\n'));
      await io.editFile('crlf.txt', oldText: 'one\ntwo', newText: '1\n2');
      expect(utf8.decode(t.files['/ws/crlf.txt']!), '1\r\n2\r\n');
    });

    test('old_text 为空拒绝', () async {
      t.seed('/ws/e.txt', 'x');
      expect(
        () => io.editFile('e.txt', oldText: '', newText: 'y'),
        throwsA(isA<WorkspaceIoException>()),
      );
    });
  });

  group('grep', () {
    test('字面量匹配 + 路径相对化 + 行号', () async {
      t.seed('/ws/src/a.dart', 'final x = 1;\nfinal y = 2;');
      t.seed('/ws/src/b.txt', 'nothing here');
      final GrepOutcome out = await io.grep(
        const GrepQuery(pattern: 'final', relativePath: 'src'),
      );
      expect(out.matches.length, 2);
      expect(out.matches.first.path, 'src/a.dart');
      expect(out.matches.first.lineNumber, 1);
      expect(out.matches.last.lineNumber, 2);
      expect(out.scannedFiles, 2);
      expect(out.truncated, isFalse);
    });

    test('regex / ignoreCase / exclude glob / maxResults', () async {
      t.seed('/ws/src/a.dart', 'final x = 1;');
      t.seed('/ws/src/gen.g.dart', 'final z = 3;');
      final GrepOutcome re = await io.grep(
        const GrepQuery(
          pattern: r'FINAL \w+',
          regex: true,
          ignoreCase: true,
          relativePath: 'src',
        ),
      );
      expect(re.matches.length, 2);

      final GrepOutcome filtered = await io.grep(
        const GrepQuery(
          pattern: 'final',
          relativePath: 'src',
          exclude: <String>['*.g.dart'],
        ),
      );
      expect(filtered.matches.length, 1);

      final GrepOutcome capped = await io.grep(
        const GrepQuery(pattern: 'final', relativePath: 'src', maxResults: 1),
      );
      expect(capped.matches.length, 1);
      expect(capped.truncated, isTrue);
    });

    test('非法正则翻成可读错误', () async {
      expect(
        () => io.grep(
          const GrepQuery(pattern: '(', regex: true, relativePath: 'src'),
        ),
        throwsA(isA<WorkspaceIoException>()),
      );
    });

    test('根目录搜索时路径不带 ./ 前缀', () async {
      t.seed('/ws/root.txt', 'needle');
      final GrepOutcome out = await io.grep(const GrepQuery(pattern: 'needle'));
      expect(out.matches.single.path, 'root.txt');
    });

    test('默认排除目录与二进制文件被跳过', () async {
      t.seed('/ws/src/keep.txt', 'needle');
      t.seed('/ws/src/build', 'needle');
      t.seedBytes('/ws/src/blob.bin', <int>[110, 101, 0, 101]);
      final GrepOutcome out = await io.grep(
        const GrepQuery(pattern: 'needle', relativePath: 'src'),
      );
      expect(out.matches.map((GrepMatch m) => m.path).toList(), <String>[
        'src/keep.txt',
      ]);
    });

    test('隐藏路径（.[!.]*）默认不搜；include_hidden=true 才放行', () async {
      t.seed('/ws/src/a.txt', 'needle');
      t.seed('/ws/.env', 'needle');
      t.seed('/ws/.self/spec/note.md', 'needle');
      t.seed('/ws/.git/config', 'needle');

      final GrepOutcome hidden = await io.grep(
        const GrepQuery(pattern: 'needle'),
      );
      expect(hidden.matches.map((GrepMatch m) => m.path).toList(), <String>[
        'src/a.txt',
      ]);
      expect(hidden.excludedDirs, contains('.self'));

      final GrepOutcome all = await io.grep(
        const GrepQuery(pattern: 'needle', includeHidden: true),
      );
      expect(all.matches.map((GrepMatch m) => m.path).toSet(), <String>{
        'src/a.txt',
        '.env',
        '.self/spec/note.md',
      }, reason: '.git 是硬黑名单，开关管不着');
    });

    test('无匹配时给出扫描清单与生效的排除目录（Q10）', () async {
      t.seed('/ws/src/a.txt', 'nothing');
      t.seed('/ws/src/b.txt', 'nothing');
      // 排除目录里的文件：本地 walk 会剪枝，远端也要一致（只按文件 basename
      // 是拦不住它们的），否则排除清单就是假的
      t.seed('/ws/node_modules/pkg/c.txt', 'nothing');
      t.seed('/ws/build/d.txt', 'nothing');
      final GrepOutcome out = await io.grep(const GrepQuery(pattern: '查无此词'));
      expect(out.matches, isEmpty);
      expect(out.scannedFileCount, 2);
      expect(out.scannedFilePaths, <String>['src/a.txt', 'src/b.txt']);
      expect(out.excludedDirs, containsAll(<String>['node_modules', 'build']));
    });

    test('有匹配时既有字段不变，清单同样可用（Q10）', () async {
      t.seed('/ws/src/a.txt', 'needle');
      t.seed('/ws/src/b.txt', 'other');
      final GrepOutcome out = await io.grep(const GrepQuery(pattern: 'needle'));
      expect(out.matches.single.path, 'src/a.txt');
      expect(out.scannedFileCount, 2);
      expect(out.scannedFiles, 2, reason: '旧的 int 字段语义不变');
      expect(out.scannedFilePaths, hasLength(2));
      expect(out.excludedDirs, isEmpty);
    });

    test('扫描清单最多 200 条，总数不封顶（Q10）', () async {
      for (int i = 0; i < 230; i++) {
        t.seed('/ws/many/f$i.txt', 'zzz');
      }
      final GrepOutcome out = await io.grep(const GrepQuery(pattern: '查无此词'));
      expect(out.scannedFileCount, 230);
      expect(out.scannedFilePaths, hasLength(GrepOutcome.maxScannedFilePaths));
    });

    test('exclude glob 命中的目录进排除清单（Q10）', () async {
      t.seed('/ws/src/a.dart', 'x');
      t.seed('/ws/src/gen.skip/b.dart', 'x');
      final GrepOutcome out = await io.grep(
        const GrepQuery(pattern: '查无此词', exclude: <String>['*.skip']),
      );
      expect(out.scannedFileCount, 1);
      expect(out.scannedFilePaths, <String>['src/a.dart']);
      expect(out.excludedDirs, <String>['src/gen.skip']);
    });
  });

  group('listFiles', () {
    test('按 maxEntries 截断并过滤排除目录名', () async {
      t.seed('/ws/list/a.txt', 'a');
      t.seed('/ws/list/b.txt', 'b');
      t.seed('/ws/list/build', 'x');
      final List<String> files = await io.listFiles(
        relativePath: 'list',
        maxDepth: 3,
      );
      expect(files, <String>['a.txt', 'b.txt']);
      final List<String> capped = await io.listFiles(
        relativePath: 'list',
        maxDepth: 3,
        maxEntries: 1,
      );
      expect(capped.length, 1);
    });
  });

  group('exec', () {
    test('命令前置 cd 到工作空间根并引用', () async {
      t.onRun = (String _) =>
          const SshExecResult(exitCode: 3, stdout: 'out', stderr: 'err');
      final ExecOutcome r = await io.exec('ls -la');
      expect(t.commands.single, "cd '/ws' && ls -la");
      expect(r.exitCode, 3);
      expect(r.stdout, 'out');
      expect(r.stderr, 'err');
      expect(r.shell, 'ssh');
      expect(r.timedOut, isFalse);
    });

    test('根目录含单引号时安全转义', () async {
      final SshWorkspaceIO quoted = SshWorkspaceIO("/ws/it's", t);
      await quoted.exec('pwd');
      expect(t.commands.single, 'cd \'/ws/it\'\\\'\'s\' && pwd');
    });

    test('timeout 透传给传输层（本层不据此终止命令；软超时见 ssh_exec_soft_timeout_test）', () async {
      t.onRun = (String _) =>
          const SshExecResult(exitCode: 0, stdout: 'done', stderr: '');
      final ExecOutcome r = await io.exec(
        'sleep 300',
        timeout: const Duration(seconds: 5),
      );
      expect(t.timeouts.single, const Duration(seconds: 5), reason: '签名保留');
      expect(r.exitCode, 0);
      expect(r.timedOut, isFalse, reason: '执行器不再产生超时终止');
    });

    test('超长输出截断并带标记', () async {
      t.onRun = (String _) =>
          SshExecResult(exitCode: 0, stdout: 'x' * 100, stderr: 'y' * 100);
      final ExecOutcome r = await io.exec('cmd', maxOutputBytes: 50);
      expect(r.truncated, isTrue);
      expect(r.stdout.length < 100, isTrue);
      expect(r.stdout, contains('输出过长已截断'));
      expect(r.stderr, contains('输出过长已截断'));
    });

    test('空命令拒绝', () async {
      expect(() => io.exec('   '), throwsA(isA<WorkspaceIoException>()));
    });
  });

  group('resolveRemoteRoot', () {
    test('绝对路径只做 POSIX 归一化，不打扰远端', () async {
      expect(await resolveRemoteRoot(t, '/home/u/proj/'), '/home/u/proj');
      expect(await resolveRemoteRoot(t, '  /srv/app  '), '/srv/app');
      expect(t.commands, isEmpty, reason: '已是绝对路径就不该再问 HOME');
    });

    test('~ / ~/sub / 相对路径都基于远端 HOME 展开', () async {
      t.onRun = (String _) =>
          const SshExecResult(exitCode: 0, stdout: '/home/u\n', stderr: '');
      expect(await resolveRemoteRoot(t, '~'), '/home/u');
      expect(await resolveRemoteRoot(t, '~/proj/'), '/home/u/proj');
      expect(await resolveRemoteRoot(t, 'proj'), '/home/u/proj');
      expect(t.commands.first, r'printf __TREE_HOME__%s "$HOME"');
      expect(
        t.commands.first,
        isNot(contains('~')),
        reason: '不能依赖远端 shell 展开 ~（引号内不展开）',
      );
    });

    test('空配置回落到远端 HOME，且解析结果可用于工作空间', () async {
      t.onRun = (String _) =>
          const SshExecResult(exitCode: 0, stdout: '/home/u', stderr: '');
      final String root = await resolveRemoteRoot(t, '');
      expect(root, '/home/u');
      expect(SshWorkspaceIO(root, t).resolve('a.txt'), '/home/u/a.txt');
    });

    test('拿不到远端 HOME 时给可读错误', () async {
      t.onRun = (String _) =>
          const SshExecResult(exitCode: 1, stdout: '', stderr: 'boom');
      expect(
        () => resolveRemoteRoot(t, '~'),
        throwsA(
          isA<WorkspaceIoException>().having(
            (WorkspaceIoException e) => e.toString(),
            'message',
            contains('HOME'),
          ),
        ),
      );
    });
  });

  group('链路活性（M9 1.1：心跳丢了才判超时）', () {
    test('在途命令遇连续 N 次心跳丢失 → 显式失败，不永久挂起', () async {
      t.pendingRun = Completer<SshExecResult>(); // 远端永远不回
      final Future<ExecOutcome> pending = io.exec('sleep 9999');
      await Future<void>.delayed(Duration.zero);
      expect(t.commands, hasLength(1), reason: '命令已经发出去了');

      // 连续 3 次"心跳窗口内没有回包"（默认 N=3）
      for (int i = 0; i < 3; i++) {
        t.liveness.recordMiss();
      }
      await expectLater(
        pending,
        throwsA(
          isA<SshLinkStaleException>().having(
            (SshLinkStaleException e) => e.message,
            'message',
            contains('心跳丢失'),
          ),
        ),
      );
      expect(t.liveness.isStale, isTrue);
    });

    test('已失活：新操作立刻显式失败，且不再往链路上发东西', () async {
      for (int i = 0; i < 3; i++) {
        t.liveness.recordMiss();
      }
      await expectLater(
        io.exec('echo hi'),
        throwsA(isA<SshLinkStaleException>()),
      );
      await expectLater(
        io.readFile('a.txt'),
        throwsA(isA<SshLinkStaleException>()),
      );
      expect(t.commands, isEmpty, reason: '判死的链路不该再收到命令');
      expect(t.liveness.lastBeatAt, isNull);
    });

    test('心跳正常：行为不变，成功响应记一次心跳并清零丢失计数', () async {
      t.seed('/ws/a.txt', 'hello');
      t.liveness.recordMiss();
      t.liveness.recordMiss();
      expect(t.liveness.isStale, isFalse, reason: '还没到阈值');

      final ExecOutcome exec = await io.exec('echo hi');
      expect(exec.exitCode, 0);
      expect(t.liveness.missedCount, 0, reason: '成功的读/写响应也是心跳');
      expect(t.liveness.lastBeatAt, isNotNull);
      expect((await io.readFile('a.txt')).text, 'hello');
      expect(t.liveness.isAlive, isTrue);
    });

    test('心跳恢复 → 失活标记清除，操作恢复可用（不主动关连接）', () async {
      for (int i = 0; i < 3; i++) {
        t.liveness.recordMiss();
      }
      await expectLater(
        io.exec('echo a'),
        throwsA(isA<SshLinkStaleException>()),
      );

      t.liveness.recordBeat(); // 下一拍回来了（等价于重连成功后的 reset）
      final ExecOutcome ok = await io.exec('echo b');
      expect(ok.exitCode, 0);
      expect(t.liveness.isStale, isFalse);
      expect(t.closed, isFalse, reason: '心跳丢失期间不关连接');
    });

    test('流式读：远端不给数据时以心跳丢失错误结束，不永久挂起', () async {
      t.seed('/ws/big.bin', 'x');
      t.stallReadStream = true;
      final Future<List<List<int>>> collected = io.openRead('big.bin').toList();
      await Future<void>.delayed(Duration.zero); // 让守卫先注册在途信号
      for (int i = 0; i < 3; i++) {
        t.liveness.recordMiss();
      }
      // 守卫必须把显式错误交给调用方：源流卡住时连 cancel 都不会完成，
      // 所以这里等的是"流报错"，不是"流结束"
      await expectLater(collected, throwsA(isA<SshLinkStaleException>()));
    });

    test('grep：单文件读不到照旧跳过，但心跳丢失要如实抛出', () async {
      t.seed('/ws/a.txt', 'needle');
      t.seed('/ws/b.txt', 'needle');
      final Completer<void> reading = Completer<void>();
      t.beforeRead = (String path) async {
        if (!path.endsWith('/a.txt')) return;
        reading.complete();
        await Completer<void>().future; // 这一读卡住了
      };
      final Future<GrepOutcome> pending = io.grep(
        const GrepQuery(pattern: 'needle'),
      );
      await reading.future;
      for (int i = 0; i < 3; i++) {
        t.liveness.recordMiss();
      }
      await expectLater(pending, throwsA(isA<SshLinkStaleException>()));
    });
  });

  group('git（M9 Q4：exec 通道）', () {
    test('gitLog：命令形状与旧实现一致，按 tab 解析且 message 可含 tab', () async {
      t.onRun = (String _) => const SshExecResult(
        exitCode: 0,
        stdout:
            'abc123\t张三\t2026-01-02 03:04:05 +0800\t修复：\t多标签\n'
            'def456\t李四\t2026-01-01 00:00:00 +0800\t初次提交\n',
        stderr: '',
      );
      final GitLogOutcome out = await io.gitLog(limit: 10);
      expect(
        t.commands.single,
        "cd '/ws' && git log --pretty=format:%H%x09%an%x09%ad%x09%s "
        '--date=iso -n 10',
      );
      expect(out.exitCode, 0);
      expect(out.commits, hasLength(2));
      expect(out.commits.first.hash, 'abc123');
      expect(out.commits.first.author, '张三');
      expect(out.commits.first.date, '2026-01-02 03:04:05 +0800');
      expect(out.commits.first.message, '修复：\t多标签', reason: '标题里的 tab 要保留');
      expect(out.commits.last.message, '初次提交');
    });

    test('gitLog 默认 limit=50，且夹在 1..1000', () async {
      await io.gitLog();
      expect(t.commands.last, endsWith('-n 50'));
      await io.gitLog(limit: 0);
      expect(t.commands.last, endsWith('-n 1'));
      await io.gitLog(limit: 99999);
      expect(t.commands.last, endsWith('-n 1000'));
    });

    test('gitBranches：* 标出当前分支，远端分支照收', () async {
      t.onRun = (String _) => const SshExecResult(
        exitCode: 0,
        stdout: '* main\n  dev\n  remotes/origin/main\n',
        stderr: '',
      );
      final GitBranchesOutcome out = await io.gitBranches();
      expect(t.commands.single, "cd '/ws' && git branch -a");
      expect(out.current, 'main');
      expect(out.branches, <String>['main', 'dev', 'remotes/origin/main']);
      expect(out.exitCode, 0);
    });

    test('非仓库 / 远端没有 git：空列表 + 退出码，不抛异常', () async {
      t.onRun = (String _) => const SshExecResult(
        exitCode: 128,
        stdout: '',
        stderr:
            'fatal: not a git repository (or any of the parent directories)',
      );
      final GitLogOutcome log = await io.gitLog();
      expect(log.commits, isEmpty);
      expect(log.exitCode, 128);

      final GitBranchesOutcome branches = await io.gitBranches();
      expect(branches.branches, isEmpty);
      expect(branches.current, '');
      expect(branches.exitCode, 128);
    });

    test('退出码非 0 时不解析 stdout（报错文本不该变成提交）', () async {
      t.onRun = (String _) => const SshExecResult(
        exitCode: 129,
        stdout: 'usage: git log ...\n',
        stderr: '',
      );
      final GitLogOutcome out = await io.gitLog();
      expect(out.commits, isEmpty);
      expect(out.exitCode, 129);
    });

    test('toJson 形状与旧后端一致（下划线 exit_code）', () async {
      t.onRun = (String _) =>
          const SshExecResult(exitCode: 0, stdout: '', stderr: '');
      final GitLogOutcome log = await io.gitLog();
      expect(log.toJson(), <String, dynamic>{
        'commits': <Map<String, dynamic>>[],
        'exit_code': 0,
      });
      final GitBranchesOutcome branches = await io.gitBranches();
      expect(branches.toJson(), <String, dynamic>{
        'branches': <String>[],
        'current': '',
        'exit_code': 0,
      });
    });

    test('gitStatus：-z 输出解析成面板口径，命令带 --porcelain=v1 -z', () async {
      t.onRun = (String _) => const SshExecResult(
        exitCode: 0,
        stdout:
            ' M a.txt\u0000A  b.txt\u0000?? 未 跟踪.txt\u0000 D c.txt\u0000',
        stderr: '',
      );
      final GitStatusOutcome out = await io.gitStatus();
      expect(t.commands.single, "cd '/ws' && git status --porcelain=v1 -z");
      expect(out.isRepo, isTrue);
      expect(out.exitCode, 0);
      expect(out.truncated, isFalse);
      expect(
        out.entries
            .map((GitStatusEntry e) => '${e.status}:${e.path}')
            .toList(),
        <String>['M:a.txt', 'A:b.txt', 'U:未 跟踪.txt', 'D:c.txt'],
      );
    });

    test('gitStatus：ignored=true 才带 --ignored，!! → I', () async {
      t.onRun = (String _) => const SshExecResult(
        exitCode: 0,
        stdout: '!! build/\u0000',
        stderr: '',
      );
      final GitStatusOutcome out = await io.gitStatus(ignored: true);
      expect(
        t.commands.single,
        "cd '/ws' && git status --porcelain=v1 -z --ignored",
      );
      expect(out.entries.single.status, 'I');
      expect(out.entries.single.path, 'build');
    });

    test('gitStatus：非仓库 → isRepo=false + 空列表，不抛异常', () async {
      t.onRun = (String _) => const SshExecResult(
        exitCode: 128,
        stdout: '',
        stderr: 'fatal: not a git repository',
      );
      final GitStatusOutcome out = await io.gitStatus();
      expect(out.isRepo, isFalse);
      expect(out.entries, isEmpty);
      expect(out.truncated, isFalse);
      expect(out.exitCode, 128);
    });

    test('gitStatus：条目上限触发 truncated', () async {
      t.onRun = (String _) => const SshExecResult(
        exitCode: 0,
        stdout: ' M a\u0000 M b\u0000 M c\u0000',
        stderr: '',
      );
      final GitStatusOutcome out = await io.gitStatus(maxEntries: 2);
      expect(out.entries, hasLength(2));
      expect(out.truncated, isTrue);
    });

    test('gitStatus：toJson 形状 = {is_repo, entries, truncated}', () async {
      t.onRun = (String _) => const SshExecResult(
        exitCode: 0,
        stdout: ' M a.txt\u0000',
        stderr: '',
      );
      final GitStatusOutcome out = await io.gitStatus();
      expect(out.toJson(), <String, dynamic>{
        'is_repo': true,
        'entries': <Map<String, dynamic>>[
          <String, dynamic>{'path': 'a.txt', 'status': 'M'},
        ],
        'truncated': false,
      });
    });
  });

  group('文件面板接口（M7g）', () {
    test('listEntries：一层目录、目录在前、相对路径以工作空间根为基准', () async {
      t.seed('/ws/sub/a.txt', 'hello');
      t.seed('/ws/sub/deep/b.txt', 'x');
      t.dirs.add('/ws/sub/empty');
      final List<WorkspaceEntry> entries = await io.listEntries('sub');
      final List<String> names = entries
          .map((WorkspaceEntry e) => e.name)
          .toList();
      expect(
        names.first,
        'deep',
        reason: '目录在前（字母序里 deep < empty < a? 不，目录整体在前）',
      );
      expect(names, containsAll(<String>['a.txt', 'deep', 'empty']));
      final WorkspaceEntry file = entries.firstWhere(
        (WorkspaceEntry e) => e.name == 'a.txt',
      );
      expect(file.isDirectory, isFalse);
      expect(file.size, 5);
      expect(file.relativePath, 'sub/a.txt');
      expect(file.modified, isNotNull);
      final WorkspaceEntry dir = entries.firstWhere(
        (WorkspaceEntry e) => e.name == 'deep',
      );
      expect(dir.isDirectory, isTrue);
      expect(dir.size, 0);
      expect(dir.relativePath, 'sub/deep');
    });

    test('listEntries：根目录可用，越界路径拒绝', () async {
      t.seed('/ws/a.txt', 'a');
      final List<WorkspaceEntry> root = await io.listEntries('');
      expect(root.single.relativePath, 'a.txt');
      expect(
        () => io.listEntries('../escape'),
        throwsA(isA<WorkspacePathException>()),
      );
      expect(
        () => io.listEntries('/abs'),
        throwsA(isA<WorkspacePathException>()),
      );
    });

    test('readBytes / writeBytes：原始字节往返，写入自动建父目录', () async {
      t.seedBytes('/ws/binary.bin', <int>[0, 1, 2, 255]);
      expect(await io.readBytes('binary.bin'), <int>[0, 1, 2, 255]);
      await io.writeBytes('out/deep/new.bin', <int>[9, 8, 7]);
      expect(t.files['/ws/out/deep/new.bin'], <int>[9, 8, 7]);
      expect(
        () => io.writeBytes('../escape.bin', <int>[1]),
        throwsA(isA<WorkspacePathException>()),
      );
      expect(
        () => io.readBytes('missing.bin'),
        throwsA(isA<WorkspaceIoException>()),
      );
    });

    test('sizeOf / openRead / writeStream：流式读写与限长读（M8c）', () async {
      t.seedBytes('/ws/big.bin', List<int>.generate(1000, (int i) => i % 256));
      expect(await io.sizeOf('big.bin'), 1000);
      expect(
        await io
            .openRead('big.bin', offset: 0, length: 4)
            .expand((c) => c)
            .toList(),
        <int>[0, 1, 2, 3],
      );
      expect(
        await io.openRead('big.bin', offset: 998).expand((c) => c).toList(),
        <int>[998 % 256, 999 % 256],
      );
      await io.writeStream(
        'out/deep/stream.bin',
        Stream<List<int>>.value(<int>[7, 8, 9]),
      );
      expect(t.files['/ws/out/deep/stream.bin'], <int>[7, 8, 9]);
      expect(() => io.sizeOf('../x'), throwsA(isA<WorkspacePathException>()));
    });
  });

  group('文件面板结构改动（M11：SFTP）', () {
    test('makeDirectory：父目录存在才建；已存在 / 父目录缺失给结果码', () async {
      t.seed('/ws/a.txt', 'a');
      final WorkspaceMutationResult ok = await io.makeDirectory('newdir');
      expect(ok.ok, isTrue);
      expect(t.dirs, contains('/ws/newdir'));

      final WorkspaceMutationResult again = await io.makeDirectory('newdir');
      expect(again.status, WorkspaceMutationStatus.alreadyExists);
      expect(again.message, contains('已存在'));

      final WorkspaceMutationResult missing = await io.makeDirectory(
        'nope/deep',
      );
      expect(missing.status, WorkspaceMutationStatus.parentMissing);
      expect(missing.message, contains('父目录不存在'));

      expect(
        () => io.makeDirectory('../escape'),
        throwsA(isA<WorkspacePathException>()),
      );
    });

    test('rename：源缺失 / 目标已存在 / 父目录缺失各自的码，成功后真的搬了', () async {
      t.seed('/ws/a.txt', 'A');
      t.seed('/ws/other.txt', 'B');
      t.dirs.add('/ws/sub');

      final WorkspaceMutationResult missing = await io.rename(
        'nope.txt',
        'x.txt',
      );
      expect(missing.status, WorkspaceMutationStatus.notFound);

      final WorkspaceMutationResult exists = await io.rename(
        'a.txt',
        'other.txt',
      );
      expect(exists.status, WorkspaceMutationStatus.alreadyExists);
      expect(exists.message, contains('不覆盖'));
      expect(t.files['/ws/other.txt'], utf8.encode('B'), reason: '绝不覆盖');
      expect(t.files.containsKey('/ws/a.txt'), isTrue, reason: '失败不动源');

      final WorkspaceMutationResult parent = await io.rename(
        'a.txt',
        'no/dir/a.txt',
      );
      expect(parent.status, WorkspaceMutationStatus.parentMissing);

      final WorkspaceMutationResult ok = await io.rename('a.txt', 'sub/a.txt');
      expect(ok.ok, isTrue);
      expect(t.files.containsKey('/ws/a.txt'), isFalse);
      expect(t.files['/ws/sub/a.txt'], utf8.encode('A'));
    });

    test('remove：非空目录默认拒绝，recursive 才删整棵；空目录 / 文件 / 缺失', () async {
      t.seed('/ws/dir/a.txt', 'a');
      t.seed('/ws/dir/deep/b.txt', 'b');
      t.seed('/ws/file.txt', 'f');
      t.dirs.add('/ws/empty');

      final WorkspaceMutationResult notEmpty = await io.remove('dir');
      expect(notEmpty.status, WorkspaceMutationStatus.notEmpty);
      expect(notEmpty.message, contains('recursive=1'));
      expect(
        t.files.containsKey('/ws/dir/a.txt'),
        isTrue,
        reason: '拒绝时一个字节都不删',
      );

      final WorkspaceMutationResult ok = await io.remove(
        'dir',
        recursive: true,
      );
      expect(ok.ok, isTrue);
      expect(
        t.files.keys.where((String k) => k.startsWith('/ws/dir/')),
        isEmpty,
      );

      final WorkspaceMutationResult empty = await io.remove('empty');
      expect(empty.ok, isTrue);
      expect(t.dirs, isNot(contains('/ws/empty')));

      final WorkspaceMutationResult file = await io.remove('file.txt');
      expect(file.ok, isTrue);
      expect(t.files.containsKey('/ws/file.txt'), isFalse);

      final WorkspaceMutationResult missing = await io.remove('nope');
      expect(missing.status, WorkspaceMutationStatus.notFound);

      expect(
        () => io.remove('../escape'),
        throwsA(isA<WorkspacePathException>()),
      );
    });

    test('结果码载体：ok() 的 message 为空，失败码带可读原因', () {
      expect(const WorkspaceMutationResult.ok().ok, isTrue);
      expect(const WorkspaceMutationResult.ok().message, isEmpty);
      const WorkspaceMutationResult bad = WorkspaceMutationResult(
        WorkspaceMutationStatus.notFound,
        '路径不存在：x',
      );
      expect(bad.ok, isFalse);
      expect(bad.message, '路径不存在：x');
    });
  });

  test('close 透传到传输层', () async {
    await io.close();
    expect(t.closed, isTrue);
  });
}
