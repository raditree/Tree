import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

void main() {
  late Directory root;
  late LocalWorkspaceIO io;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tree_ws_');
    io = LocalWorkspaceIO(root.path);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String writeFile(String rel, String content) {
    final File file = File(p.join(root.path, rel));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file.path;
  }

  group('路径安全', () {
    test('相对路径解析到根内', () {
      final String resolved = io.resolve('lib/src/a.dart');
      expect(resolved.startsWith(root.path), isTrue);
      expect(resolved.endsWith(p.join('lib', 'src', 'a.dart')), isTrue);
      expect(io.resolve('./a.txt'), p.join(root.path, 'a.txt'));
    });

    test('绝对路径/盘符/UNC/~/越界一律拒绝', () {
      final List<String> bad = <String>[
        '/etc/passwd',
        r'\\server\share\x',
        '~/secret',
        '../outside.txt',
        'a/../../outside.txt',
        '',
        '   ',
        if (Platform.isWindows) 'E:\\evil.txt',
        if (Platform.isWindows) 'E:/evil.txt',
      ];
      for (final String path in bad) {
        expect(
          () => io.resolve(path),
          throwsA(isA<WorkspacePathException>()),
          reason: '应拒绝：$path',
        );
      }
    });

    test('以 .. 开头但仍在根内的路径是合法的', () {
      expect(io.resolve('a/../b.txt'), p.join(root.path, 'b.txt'));
    });
  });

  group('readFile', () {
    test('返回全文并给出行数', () async {
      writeFile('a.txt', 'line1\nline2\nline3');
      final FileContent content = await io.readFile('a.txt');
      expect(content.text, 'line1\nline2\nline3');
      expect(content.totalLines, 3);
      expect(content.startLine, 1);
      expect(content.truncated, isFalse);
    });

    test('行范围：start_line + line_count，并标记 truncated', () async {
      writeFile('a.txt', '1\n2\n3\n4\n5');
      final FileContent content = await io.readFile(
        'a.txt',
        startLine: 2,
        lineCount: 2,
      );
      expect(content.text, '2\n3');
      expect(content.startLine, 2);
      expect(content.totalLines, 5);
      expect(content.truncated, isTrue);
    });

    test('start_line 越界/文件不存在/目录 → 可读错误', () async {
      writeFile('a.txt', 'x');
      await expectLater(
        io.readFile('a.txt', startLine: 99),
        throwsA(isA<WorkspaceIoException>()),
      );
      await expectLater(
        io.readFile('missing.txt'),
        throwsA(isA<WorkspaceIoException>()),
      );
      Directory(p.join(root.path, 'dir')).createSync();
      await expectLater(
        io.readFile('dir'),
        throwsA(isA<WorkspaceIoException>()),
      );
    });

    test('图像返回 base64 而不是文本', () async {
      final List<int> png = <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ];
      File(p.join(root.path, 'p.png')).writeAsBytesSync(png);
      final FileContent content = await io.readFile('p.png');
      expect(content.base64, base64Encode(png));
      expect(content.text, isEmpty);
    });

    test('二进制（含 NUL）拒绝作为文本读取', () async {
      File(p.join(root.path, 'b.bin')).writeAsBytesSync(<int>[1, 2, 0, 3]);
      await expectLater(
        io.readFile('b.bin'),
        throwsA(isA<WorkspaceIoException>()),
      );
    });

    test('超大文本按 maxBytes 截断并标记', () async {
      final String big = 'x' * 5000;
      writeFile('big.txt', big);
      final FileContent content = await io.readFile('big.txt', maxBytes: 100);
      expect(content.truncated, isTrue);
      expect(content.text.length, lessThan(5000));
    });

    test('非法 UTF-8 回退 latin1（不抛异常、不丢字节）', () async {
      File(p.join(root.path, 'gbk.txt'))
          .writeAsBytesSync(<int>[0xC4, 0xE3, 0xBA, 0xC3]);
      final FileContent content = await io.readFile('gbk.txt');
      expect(content.text.runes.length, 4);
    });
  });

  group('writeFile / editFile', () {
    test('写入自动建父目录并覆盖既有内容', () async {
      final int bytes = await io.writeFile('a/b/c.txt', '你好');
      expect(bytes, utf8.encode('你好').length);
      expect(File(p.join(root.path, 'a/b/c.txt')).readAsStringSync(), '你好');
      await io.writeFile('a/b/c.txt', 'x');
      expect(File(p.join(root.path, 'a/b/c.txt')).readAsStringSync(), 'x');
    });

    test('edit：唯一匹配才允许替换', () async {
      writeFile('a.txt', 'hello world');
      final EditOutcome outcome = await io.editFile(
        'a.txt',
        oldText: 'world',
        newText: 'tree',
      );
      expect(outcome.replacements, 1);
      expect(File(p.join(root.path, 'a.txt')).readAsStringSync(), 'hello tree');
    });

    test('edit：多处匹配报错，replace_all=true 时全替换', () async {
      writeFile('a.txt', 'x x x');
      await expectLater(
        io.editFile('a.txt', oldText: 'x', newText: 'y'),
        throwsA(isA<WorkspaceIoException>()),
      );
      final EditOutcome outcome = await io.editFile(
        'a.txt',
        oldText: 'x',
        newText: 'y',
        replaceAll: true,
      );
      expect(outcome.replacements, 3);
      expect(File(p.join(root.path, 'a.txt')).readAsStringSync(), 'y y y');
    });

    test('edit：找不到内容 / 文件不存在 / old_text 为空 → 可读错误', () async {
      writeFile('a.txt', 'abc');
      await expectLater(
        io.editFile('a.txt', oldText: 'zzz', newText: 'y'),
        throwsA(isA<WorkspaceIoException>()),
      );
      await expectLater(
        io.editFile('missing.txt', oldText: 'a', newText: 'b'),
        throwsA(isA<WorkspaceIoException>()),
      );
      await expectLater(
        io.editFile('a.txt', oldText: '', newText: 'b'),
        throwsA(isA<WorkspaceIoException>()),
      );
    });

    test('edit：CRLF 文件用 LF 片段也能匹配，且替换后仍是 CRLF', () async {
      writeFile('crlf.txt', 'line1\r\nline2\r\nline3\r\n');
      await io.editFile('crlf.txt', oldText: 'line2\n', newText: 'LINE2\n');
      final String after = File(p.join(root.path, 'crlf.txt'))
          .readAsStringSync();
      expect(after, 'line1\r\nLINE2\r\nline3\r\n');
    });
  });

  group('grep / listFiles', () {
    test('字面量与正则、大小写、行号', () async {
      writeFile('lib/a.dart', 'void main() {}\n// TODO: fix\n');
      writeFile('lib/b.dart', '// todo: other\n');
      final GrepOutcome literal = await io.grep(
        const GrepQuery(pattern: 'TODO'),
      );
      expect(literal.matches, hasLength(1));
      expect(literal.matches.single.path, 'lib/a.dart');
      expect(literal.matches.single.lineNumber, 2);

      final GrepOutcome insensitive = await io.grep(
        const GrepQuery(pattern: 'todo', ignoreCase: true),
      );
      expect(insensitive.matches, hasLength(2));

      final GrepOutcome regex = await io.grep(
        const GrepQuery(pattern: r'void\s+main', regex: true),
      );
      expect(regex.matches, hasLength(1));
    });

    test('默认排除依赖/构建目录；path 指过去则不再排除', () async {
      writeFile('src/a.txt', 'needle');
      writeFile('build/b.txt', 'needle');
      writeFile('node_modules/c.txt', 'needle');
      writeFile('.git/d.txt', 'needle');
      final GrepOutcome excluded = await io.grep(
        const GrepQuery(pattern: 'needle'),
      );
      expect(excluded.matches.map((GrepMatch m) => m.path).toList(), <String>[
        'src/a.txt',
      ]);

      final GrepOutcome explicit = await io.grep(
        const GrepQuery(pattern: 'needle', relativePath: 'build'),
      );
      expect(explicit.matches.map((GrepMatch m) => m.path).toList(), <String>[
        'build/b.txt',
      ]);
    });

    test('exclude glob 按 basename 追加排除；max_results 截断', () async {
      writeFile('src/a.dart', 'x1\nx2\nx3');
      writeFile('src/a.g.dart', 'x4');
      final GrepOutcome without = await io.grep(
        GrepQuery(pattern: 'x', exclude: const <String>['*.g.dart']),
      );
      expect(without.matches, hasLength(3));
      final GrepOutcome limited = await io.grep(
        const GrepQuery(pattern: 'x', maxResults: 2),
      );
      expect(limited.matches, hasLength(2));
      expect(limited.truncated, isTrue);
      expect(limited.scannedFiles, greaterThan(0));
    });

    test('无匹配时给出扫描清单与生效的排除目录（Q10）', () async {
      writeFile('src/a.txt', 'nothing');
      writeFile('src/b.txt', 'nothing');
      writeFile('node_modules/pkg/c.txt', 'nothing');
      writeFile('build/d.txt', 'nothing');
      final GrepOutcome out = await io.grep(const GrepQuery(pattern: '查无此词'));
      expect(out.matches, isEmpty);
      expect(out.scannedFileCount, 2);
      expect(out.scannedFilePaths, hasLength(2));
      expect(
        out.scannedFilePaths,
        containsAll(<String>['src/a.txt', 'src/b.txt']),
      );
      expect(
        out.excludedDirs,
        containsAll(<String>['node_modules', 'build']),
        reason: '排除清单只列真的存在、真的被跳过的目录',
      );
      expect(out.scannedFiles, 2, reason: '旧的 int 字段语义不变');
    });

    test('有匹配时既有字段不变，清单同样可用（Q10）', () async {
      writeFile('lib/a.dart', 'needle');
      writeFile('lib/b.dart', 'other');
      final GrepOutcome out = await io.grep(const GrepQuery(pattern: 'needle'));
      expect(out.matches.single.path, 'lib/a.dart');
      expect(out.scannedFileCount, 2);
      expect(out.scannedFilePaths, hasLength(2));
      expect(out.excludedDirs, isEmpty);
    });

    test('扫描清单最多 200 条，总数不封顶（Q10）', () async {
      for (int i = 0; i < 230; i++) {
        writeFile('many/f$i.txt', 'zzz');
      }
      final GrepOutcome out = await io.grep(const GrepQuery(pattern: '查无此词'));
      expect(out.scannedFileCount, 230);
      expect(out.scannedFilePaths, hasLength(GrepOutcome.maxScannedFilePaths));
    });

    test('exclude glob 命中的目录进排除清单，且不重复计（Q10）', () async {
      writeFile('src/a.dart', 'x');
      writeFile('src/gen.skip/b.dart', 'x');
      writeFile('src/gen.skip/deep/c.dart', 'x');
      final GrepOutcome out = await io.grep(
        GrepQuery(pattern: '查无此词', exclude: const <String>['*.skip']),
      );
      expect(out.scannedFileCount, 1);
      expect(out.scannedFilePaths, <String>['src/a.dart']);
      expect(out.excludedDirs, <String>['src/gen.skip']);
    });

    test('max_depth 限制递归层数', () async {
      writeFile('a.txt', 'hit');
      writeFile('sub/b.txt', 'hit');
      final GrepOutcome shallow = await io.grep(
        const GrepQuery(pattern: 'hit', maxDepth: 1),
      );
      expect(shallow.matches.map((GrepMatch m) => m.path).toList(), <String>[
        'a.txt',
      ]);
    });

    test('listFiles 标记目录并受 max_depth/maxEntries 约束', () async {
      writeFile('a.txt', 'x');
      writeFile('sub/b.txt', 'x');
      final List<String> entries = await io.listFiles(maxDepth: 2);
      expect(entries, contains('a.txt'));
      expect(entries, contains('sub/'));
      expect(entries, contains('sub/b.txt'));
      final List<String> limited = await io.listFiles(maxEntries: 1);
      expect(limited, hasLength(1));
      await expectLater(
        io.listFiles(relativePath: 'a.txt'),
        throwsA(isA<WorkspaceIoException>()),
      );
    });
  });

  group('exec', () {
    test('退出码/stdout/stderr，cwd 为工作空间根', () async {
      final ExecOutcome ok = await io.exec('echo tree-ok');
      expect(ok.exitCode, 0);
      expect(ok.stdout, contains('tree-ok'));

      final ExecOutcome fail = await io.exec('exit 3');
      expect(fail.exitCode, 3);
      expect(fail.ok, isFalse);

      final ExecOutcome err = await io.exec('echo oops 1>&2');
      expect(err.stderr, contains('oops'));

      final ExecOutcome cwd = await io.exec(Platform.isWindows ? 'cd' : 'pwd');
      expect(
        cwd.stdout.trim().replaceAll('\\', '/'),
        root.path.replaceAll('\\', '/'),
      );
    });

    test('非 UTF-8 输出（Windows cmd 内建命令）保字节并标记 nonUtf8Output', () async {
      // 实测：Windows 上 cmd 内建命令经管道输出用的是系统 ANSI 代码页（zh-CN=GBK），
      // chcp 65001 管不住管道。此处的契约是"字节不丢 + 明确标记"，好让工具层提示
      // 使用者；按系统代码页正确解码是后续增强项（需要 FFI MultiByteToWideChar）。
      final ExecOutcome outcome = await io.exec('echo 中文测试');
      if (Platform.isWindows) {
        expect(outcome.stdout.trim(), isNotEmpty);
        expect(
          latin1.encode(outcome.stdout.trim()).length,
          greaterThanOrEqualTo(8),
          reason: 'latin1 兜底应保住原始字节数',
        );
        expect(outcome.nonUtf8Output, isTrue);
      } else {
        expect(outcome.stdout, contains('中文测试'));
        expect(outcome.nonUtf8Output, isFalse);
      }
    });

    test('纯 ASCII 输出不标记 nonUtf8Output', () async {
      final ExecOutcome outcome = await io.exec('echo plain-ascii');
      expect(outcome.nonUtf8Output, isFalse);
      expect(outcome.stdout, contains('plain-ascii'));
    });

    test('timeout 不再终止命令：慢命令跑完，输出照常可读（M9 1.1）', () async {
      final ExecOutcome outcome = await io.exec(
        Platform.isWindows
            ? 'ping -n 3 127.0.0.1 >nul & echo done'
            : 'sleep 2; echo done',
        timeout: const Duration(milliseconds: 200),
      );
      expect(outcome.timedOut, isFalse, reason: '执行器取消硬超时：不再杀进程，也不标记超时');
      expect(outcome.exitCode, 0);
      expect(outcome.stdout, contains('done'), reason: '进程跑完后输出仍可读取');
    });

    test('空命令被拒绝', () async {
      await expectLater(io.exec('   '), throwsA(isA<WorkspaceIoException>()));
    });
  });

  group('git（M9 Q4：本机 git）', () {
    Future<void> git(List<String> args) async {
      final ProcessResult result = await Process.run(
        'git',
        args,
        workingDirectory: root.path,
      );
      expect(
        result.exitCode,
        0,
        reason: 'git ${args.join(' ')}: ${result.stderr}',
      );
    }

    test('非仓库：空列表 + 非零退出码，不抛异常', () async {
      final GitLogOutcome log = await io.gitLog();
      expect(log.commits, isEmpty);
      expect(log.exitCode, isNot(0));
      final GitBranchesOutcome branches = await io.gitBranches();
      expect(branches.branches, isEmpty);
      expect(branches.current, '');
      expect(branches.exitCode, isNot(0));
    });

    test('真仓库：提交历史与分支（含当前分支）', () async {
      final ProcessResult probe = await Process.run('git', <String>[
        '--version',
      ]);
      if (probe.exitCode != 0) {
        markTestSkipped('本机没有 git，跳过');
        return;
      }
      writeFile('a.txt', 'hello');
      await git(<String>['init', '-q']);
      await git(<String>['config', 'user.email', 'test@example.com']);
      await git(<String>['config', 'user.name', 'Tree Test']);
      await git(<String>['add', 'a.txt']);
      await git(<String>['commit', '-q', '-m', '初次提交']);
      await git(<String>['branch', 'feature']);

      final GitLogOutcome log = await io.gitLog(limit: 1);
      expect(log.exitCode, 0);
      expect(log.commits, hasLength(1), reason: 'limit=1 只回一条');
      expect(log.commits.single.message, '初次提交');
      expect(log.commits.single.author, 'Tree Test');
      expect(log.commits.single.hash, isNotEmpty);
      expect(log.commits.single.date, isNotEmpty);

      final GitBranchesOutcome branches = await io.gitBranches();
      expect(branches.exitCode, 0);
      expect(branches.current, isNotEmpty);
      expect(branches.branches, contains('feature'));
      expect(branches.branches, contains(branches.current));
    });
  });

  group('工作空间文件流（M8c）', () {
    Future<List<int>> collect(Stream<List<int>> stream) async {
      final List<int> out = <int>[];
      await for (final List<int> chunk in stream) {
        out.addAll(chunk);
      }
      return out;
    }

    test('sizeOf / openRead / writeStream：可限长读、写流建父目录', () async {
      final Directory streamRoot = Directory.systemTemp.createTempSync(
        'tree_stream_',
      );
      addTearDown(() {
        if (streamRoot.existsSync()) {
          streamRoot.deleteSync(recursive: true);
        }
      });
      final LocalWorkspaceIO streamIo = LocalWorkspaceIO(streamRoot.path);
      final List<int> payload = List<int>.generate(1000, (int i) => i % 256);

      await streamIo.writeStream(
        'deep/out.bin',
        Stream<List<int>>.value(payload),
      );
      expect(
        File(p.join(streamRoot.path, 'deep', 'out.bin')).readAsBytesSync(),
        payload,
        reason: '流式写要自动建父目录且逐字节落盘',
      );

      expect(await streamIo.sizeOf('deep/out.bin'), payload.length);
      expect(
        await collect(streamIo.openRead('deep/out.bin', offset: 0, length: 10)),
        payload.sublist(0, 10),
      );
      expect(
        await collect(streamIo.openRead('deep/out.bin', offset: 990)),
        payload.sublist(990),
        reason: '只给 offset = 从该处读到结尾',
      );
      expect(
        () => streamIo.sizeOf('missing.bin'),
        throwsA(isA<WorkspaceIoException>()),
      );
      expect(
        () => streamIo.openRead('../escape.bin'),
        throwsA(isA<WorkspacePathException>()),
      );
    });
  });
}
