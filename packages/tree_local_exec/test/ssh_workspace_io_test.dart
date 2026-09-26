import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 内存假传输：把 [SshWorkspaceIO] 的全部语义测试从"真 SSH"里解耦出来。
///
/// 真 dartssh2 那一层只负责搬运字节（[dartssh_transport.dart]），语义全部落在
/// [SshWorkspaceIO]；因此这里用假实现覆盖路径约束、行范围、唯一匹配编辑、
/// grep 排除规则、结果截断等真正容易出错的部分。
class FakeSshTransport implements SshTransport {
  final Map<String, List<int>> files = <String, List<int>>{};
  final List<String> commands = <String>[];
  final List<Duration> timeouts = <Duration>[];
  SshExecResult Function(String command)? onRun;
  bool closed = false;

  void seed(String path, String content) => files[path] = utf8.encode(content);

  void seedBytes(String path, List<int> bytes) => files[path] = bytes;

  @override
  Future<List<int>> read(String absolutePath) async {
    final List<int>? bytes = files[absolutePath];
    if (bytes == null) throw StateError('no such file: $absolutePath');
    return bytes;
  }

  @override
  Future<void> write(String absolutePath, List<int> bytes) async {
    files[absolutePath] = List<int>.of(bytes);
  }

  @override
  Future<List<String>> listFiles(
    String absolutePath, {
    int maxDepth = 2,
  }) async {
    final String prefix = absolutePath.endsWith('/')
        ? absolutePath
        : '$absolutePath/';
    final List<String> out = <String>[];
    for (final String path in files.keys) {
      if (!path.startsWith(prefix)) continue;
      final String rel = path.substring(prefix.length);
      if (maxDepth > 0 && rel.split('/').length > maxDepth) continue;
      out.add(rel);
    }
    out.sort();
    return out;
  }

  /// 显式声明的空目录（[files] 只描述文件，空目录推不出来）。
  final Set<String> dirs = <String>{};

  @override
  Future<List<SshFileEntry>> listEntries(
    String absolutePath, {
    int maxEntries = 2000,
  }) async {
    final String prefix = absolutePath.endsWith('/')
        ? absolutePath
        : '$absolutePath/';
    final Map<String, SshFileEntry> byName = <String, SshFileEntry>{};
    final DateTime stamp = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    for (final String dir in dirs) {
      if (!dir.startsWith(prefix)) continue;
      final String rest = dir.substring(prefix.length);
      if (rest.isEmpty || rest.contains('/')) continue;
      byName[rest] = SshFileEntry(
        name: rest,
        isDirectory: true,
        modified: stamp,
      );
    }
    for (final MapEntry<String, List<int>> entry in files.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final String rest = entry.key.substring(prefix.length);
      if (rest.isEmpty) continue;
      final int slash = rest.indexOf('/');
      final String name = slash < 0 ? rest : rest.substring(0, slash);
      byName[name] = SshFileEntry(
        name: name,
        isDirectory: slash >= 0,
        size: slash >= 0 ? 0 : entry.value.length,
        modified: stamp,
      );
    }
    final List<SshFileEntry> out = byName.values.toList();
    return out.length > maxEntries ? out.sublist(0, maxEntries) : out;
  }

  @override
  Future<bool> exists(String absolutePath) async =>
      files.containsKey(absolutePath) ||
      files.keys.any((String k) => k.startsWith('$absolutePath/'));

  @override
  Future<SshExecResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    commands.add(command);
    timeouts.add(timeout);
    return onRun?.call(command) ??
        const SshExecResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<void> close() async => closed = true;
}

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

    test('透传超时并标记 timedOut', () async {
      t.onRun = (String _) => const SshExecResult(
        exitCode: 124,
        stdout: '',
        stderr: '',
        timedOut: true,
      );
      final ExecOutcome r = await io.exec(
        'sleep 300',
        timeout: const Duration(seconds: 5),
      );
      expect(t.timeouts.single, const Duration(seconds: 5));
      expect(r.timedOut, isTrue);
      expect(r.exitCode, 124);
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
      expect(t.commands.first, r'printf %s "$HOME"');
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

  group('文件面板接口（M7g）', () {
    test('listEntries：一层目录、目录在前、相对路径以工作空间根为基准', () async {
      t.seed('/ws/sub/a.txt', 'hello');
      t.seed('/ws/sub/deep/b.txt', 'x');
      t.dirs.add('/ws/sub/empty');
      final List<WorkspaceEntry> entries = await io.listEntries('sub');
      final List<String> names = entries
          .map((WorkspaceEntry e) => e.name)
          .toList();
      expect(names.first, 'deep', reason: '目录在前（字母序里 deep < empty < a? 不，目录整体在前）');
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
  });

  test('close 透传到传输层', () async {
    await io.close();
    expect(t.closed, isTrue);
  });
}
