import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 中文 Windows（系统 ANSI 代码页 = GBK/936）：本仓库的主要目标环境，也是
/// "cmd 内建命令的管道输出是 GBK 字节、严格 UTF-8 解不开"这个 bug 的现场。
///
/// 其它 ANSI 代码页（含把系统区域设成 UTF-8 的 65001）下，cmd 会把它表示不了的汉字
/// 换成 '?'（字节退化成纯 ASCII），下面几个依赖 GBK 字节前提的用例会自行跳过。
bool get _isGbkWindows =>
    Platform.isWindows && AnsiCodePage.systemCodePage == 936;

/// Windows 上命令是否走 PowerShell（见 [Shell.windowsShell] 的探测顺序）。
bool get _isPowerShellWindows =>
    Platform.isWindows && !Shell.windowsShell.toLowerCase().endsWith('cmd.exe');

/// GBK/CP936 的「中文测试」字节：不是合法 UTF-8，做"非 UTF-8 输出"的确定性样本。
const List<int> _gbkZhongWenBytes = <int>[
  0xD6,
  0xD0,
  0xCE,
  0xC4,
  0xB2,
  0xE2,
  0xCA,
  0xD4,
];

/// 把 [bytes] 原样写进 stdout 的 PowerShell 命令（绕过 PowerShell 的编码层）。
///
/// 这样"非 UTF-8 输出"有了**不依赖 cmd 内建命令行为**的确定性来源：换 shell、换控制台
/// 代码页都不影响它是 GBK 字节这件事。
String _rawStdoutCommand(List<int> bytes) {
  final String literals = bytes
      .map((int b) => '0x${b.toRadixString(16)}')
      .join(',');
  return '[Console]::OpenStandardOutput().Write([byte[]]($literals), 0, ${bytes.length})';
}

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

    test('非 UTF-8 文件走统一解码链：按系统代码页解码，解不开才 latin1 兜底', () async {
      // GBK/CP936 的「你好」（C4 E3 BA C3）：不是合法 UTF-8，正是 Windows 上
      // 非 UTF-8 文本文件的常见形态。
      const List<int> gbk = <int>[0xC4, 0xE3, 0xBA, 0xC3];
      File(p.join(root.path, 'gbk.txt')).writeAsBytesSync(gbk);
      final FileContent content = await io.readFile('gbk.txt');
      final DecodedText decoded = PlatformTextDecoder.decode(gbk);
      expect(content.text, decoded.text, reason: '文件读取必须与统一解码链完全一致');
      if (decoded.isGarbled) {
        expect(latin1.encode(content.text), gbk, reason: '兜底路径逐字节保底，不丢字节');
      }
      if (Platform.isWindows && AnsiCodePage.systemCodePage == 936) {
        expect(content.text, '你好', reason: '中文机器上按 CP936 解出正确中文');
      }
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

    test('非 UTF-8 文件：edit 保编码往返，不静默转成 UTF-8', () async {
      if (!_isGbkWindows) return; // 需要"系统代码页能表示这些中文"的机器
      // GBK 的「你好世界」：未改动的部分必须**字节不变**地写回去
      const List<int> gbk = <int>[
        0xC4,
        0xE3,
        0xBA,
        0xC3,
        0xCA,
        0xC0,
        0xBD,
        0xE7,
      ];
      final File file = File(p.join(root.path, 'gbk.txt'))
        ..writeAsBytesSync(gbk);
      final EditOutcome outcome = await io.editFile(
        'gbk.txt',
        oldText: '世界',
        newText: '世界!',
      );
      expect(outcome.replacements, 1);
      final List<int> after = file.readAsBytesSync();
      expect(
        after.sublist(0, 6),
        gbk.sublist(0, 6),
        reason: '未触碰的「你好」必须还是原 GBK 字节',
      );
      expect(after.length, gbk.length + 1);
      expect(
        (await io.readFile('gbk.txt')).text,
        '你好世界!',
        reason: '写回后仍然是原编码，读出来还是正确中文',
      );
    });

    test('非 UTF-8 文件：替换进原编码表示不了的字符 → 显式拒绝且文件不动', () async {
      if (!_isGbkWindows) return;
      const List<int> gbk = <int>[0xC4, 0xE3, 0xBA, 0xC3]; // GBK「你好」
      final File file = File(p.join(root.path, 'gbk2.txt'))
        ..writeAsBytesSync(gbk);
      await expectLater(
        // 😀 不在 CP936 里：写回只能靠 '?' 顶替，必须拒绝而不是写坏
        io.editFile('gbk2.txt', oldText: '你好', newText: '你好😀'),
        throwsA(isA<WorkspaceIoException>()),
      );
      expect(file.readAsBytesSync(), gbk, reason: '拒绝时文件必须原封不动');
    });

    test('非 UTF-8 文件：write 覆盖写沿用原编码（不静默转 UTF-8）', () async {
      if (!_isGbkWindows) return;
      final File file = File(p.join(root.path, 'gbk3.txt'))
        ..writeAsBytesSync(<int>[0xC4, 0xE3, 0xBA, 0xC3]); // GBK「你好」
      await io.writeFile('gbk3.txt', '中文');
      expect(file.readAsBytesSync(), <int>[
        0xD6,
        0xD0,
        0xCE,
        0xC4,
      ], reason: 'GBK 文件被覆盖写后仍应是 GBK 字节，而不是 UTF-8');
      expect((await io.readFile('gbk3.txt')).text, '中文');
    });

    test('代码页不可用（非 Windows / FFI 失败）：edit 走 latin1 逐字节回写', () async {
      // 非 UTF-8 且不是合法代码页序列：解码链落到 latin1 兜底
      const List<int> raw = <int>[
        0xC4,
        0xE3,
        0x41,
        0x42,
      ]; // 两个非 UTF-8 字节 + "AB"
      final File file = File(p.join(root.path, 'raw.txt'))
        ..writeAsBytesSync(raw);
      AnsiCodePage.debugDecoderOverride = (List<int> bytes) => null;
      try {
        final EditOutcome outcome = await io.editFile(
          'raw.txt',
          oldText: 'AB',
          newText: 'CD',
        );
        expect(outcome.replacements, 1);
      } finally {
        // 注入点是全局静态：这里是 writeFile/editFile 组，没有 exec 组的 tearDown
        AnsiCodePage.debugDecoderOverride = null;
      }
      expect(file.readAsBytesSync(), <int>[
        0xC4,
        0xE3,
        0x43,
        0x44,
      ], reason: 'latin1 逐字节回写：未触碰的字节原样，改动按 latin1 编码');
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

    test('隐藏路径（.[!.]*）默认不搜；include_hidden=true 才放行', () async {
      writeFile('src/a.txt', 'needle');
      writeFile('.env', 'needle');
      writeFile('.self/spec/note.md', 'needle');
      writeFile('.github/workflows/ci.yml', 'needle');
      writeFile('.git/config', 'needle');

      final GrepOutcome hidden = await io.grep(
        const GrepQuery(pattern: 'needle'),
      );
      expect(hidden.matches.map((GrepMatch m) => m.path).toList(), <String>[
        'src/a.txt',
      ], reason: '隐藏文件与隐藏目录下的文件都不该进结果');
      expect(hidden.scannedFileCount, 1);
      expect(
        hidden.excludedDirs,
        containsAll(<String>['.self', '.github']),
        reason: '被跳过的隐藏目录要进排除清单，模型才能区分"真没有"',
      );

      final GrepOutcome all = await io.grep(
        const GrepQuery(pattern: 'needle', includeHidden: true),
      );
      expect(all.matches.map((GrepMatch m) => m.path).toSet(), <String>{
        'src/a.txt',
        '.env',
        '.self/spec/note.md',
        '.github/workflows/ci.yml',
      }, reason: '.git 是硬黑名单，开关管不着');
    });

    test('显式把 path 指到隐藏目录：指向哪里搜哪里', () async {
      writeFile('.self/spec/note.md', 'needle');
      writeFile('src/a.txt', 'needle');
      final GrepOutcome out = await io.grep(
        const GrepQuery(pattern: 'needle', relativePath: '.self/spec'),
      );
      expect(out.matches.single.path, '.self/spec/note.md');
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
    tearDown(() {
      // 下面有用例注入"代码页解码不可用"，它是全局静态，用完必须复原
      AnsiCodePage.debugDecoderOverride = null;
    });

    test('退出码/stdout/stderr，cwd 为工作空间根', () async {
      final ExecOutcome ok = await io.exec('echo tree-ok');
      expect(ok.exitCode, 0);
      expect(ok.stdout, contains('tree-ok'));

      final ExecOutcome fail = await io.exec('exit 3');
      expect(fail.exitCode, 3);
      expect(fail.ok, isFalse);

      // Windows 走 PowerShell：1>&2 在 Windows PowerShell 5.1 上是解析错误（只有 PS 7
      // 支持），所以用 PS 5.1/7 通吃的 [Console]::Error.WriteLine 写 stderr。
      final ExecOutcome err = await io.exec(
        Platform.isWindows
            ? r"[Console]::Error.WriteLine('oops')"
            : 'echo oops 1>&2',
      );
      expect(err.stderr, contains('oops'));

      // PowerShell 的 cd（Set-Location）不打印当前目录，取路径要显式写 $PWD.Path
      final ExecOutcome cwd = await io.exec(
        Platform.isWindows ? r'$PWD.Path' : 'pwd',
      );
      expect(
        cwd.stdout.trim().replaceAll('\\', '/'),
        root.path.replaceAll('\\', '/'),
      );
    });

    test('中文输出可读：PowerShell 下是 UTF-8，cmd 下是系统代码页', () async {
      // Windows 换 PowerShell 后，OutputEncoding 固定 UTF-8，所以中文走 UTF-8 分支；
      // 退回 cmd 时是系统代码页字节，由解码链按 CP_ACP 解开。两条路都不该出现乱码。
      final ExecOutcome outcome = await io.exec('echo 中文测试');
      expect(outcome.stdout.trim(), '中文测试', reason: '中文必须可读，不能是乱码');
      expect(outcome.garbledOutput, isFalse, reason: '不该落到 latin1 兜底');
    });

    test('非 UTF-8 原始字节（GBK）：按系统代码页解码，标 nonUtf8Output 不标 garbled', () async {
      if (!_isPowerShellWindows) return; // 该命令是 PowerShell 写法
      final ExecOutcome outcome = await io.exec(
        _rawStdoutCommand(_gbkZhongWenBytes),
      );
      expect(outcome.nonUtf8Output, isTrue, reason: '这 8 个字节不是合法 UTF-8');
      if (_isGbkWindows) {
        expect(outcome.stdout, '中文测试', reason: 'CP936 下必须解成中文');
        expect(outcome.garbledOutput, isFalse, reason: '代码页解开了就不是真乱码');
      }
    });

    test('代码页不可用（非 Windows / FFI 失败）时降级 latin1 并标 garbled', () async {
      if (!_isPowerShellWindows) return;
      // 注入"代码页解码不可用"：与"非 Windows / FFI 加载失败"走同一条降级分支
      AnsiCodePage.debugDecoderOverride = (List<int> bytes) => null;
      final ExecOutcome outcome = await io.exec(
        _rawStdoutCommand(_gbkZhongWenBytes),
      );
      expect(outcome.nonUtf8Output, isTrue);
      expect(outcome.garbledOutput, isTrue, reason: '连代码页都不可用 → 如实标记真乱码');
      expect(
        latin1.encode(outcome.stdout),
        _gbkZhongWenBytes,
        reason: 'latin1 兜底逐字节保底，不丢字节',
      );
    });

    test('真机 dir：自建中文目录名可读', () async {
      if (!Platform.isWindows) return;
      const String name = '中文目录验证';
      Directory(p.join(root.path, name)).createSync();
      final ExecOutcome outcome = await io.exec('dir');
      expect(outcome.stdout, contains(name), reason: '中文目录名必须可读');
      expect(outcome.garbledOutput, isFalse, reason: '不该落到 latin1 兜底');
    });

    test('纯 ASCII 输出不标记 nonUtf8Output', () async {
      final ExecOutcome outcome = await io.exec('echo plain-ascii');
      expect(outcome.nonUtf8Output, isFalse);
      expect(outcome.stdout, contains('plain-ascii'));
    });

    test('没有硬超时：不设软超时（Duration.zero）时慢命令跑完，输出照常可读（M9 1.1）', () async {
      // 2026-10-02 起 timeout > 0 是**软**超时（不杀进程，把活着的句柄交出去，见
      // exec_soft_timeout_test.dart）；「没有硬超时」这条口径由 Duration.zero 表达。
      final ExecOutcome outcome = await io.exec(
        Platform.isWindows
            ? r'ping -n 3 127.0.0.1 | Out-Null; echo done'
            : 'sleep 2; echo done',
        timeout: Duration.zero,
      );
      expect(outcome.timedOut, isFalse, reason: '执行器取消硬超时：不再杀进程，也不标记超时');
      expect(outcome.exitCode, 0);
      expect(outcome.stdout, contains('done'), reason: '进程跑完后输出仍可读取');
    });

    test('空命令被拒绝', () async {
      await expectLater(io.exec('   '), throwsA(isA<WorkspaceIoException>()));
    });

    test('进程已退出、后台子进程还攥着管道：收尾不永久挂住（1.1）', () async {
      // 命令行自己立刻退出，但它 fork/start 出来的后台进程继承着管道写端并**持续**
      // 输出：这时"等流关闭"要等到后台进程结束（60s），"等输出静默"也永远等不到。
      // 进程已死即命令结束，收尾只该把残余缓冲收干净——所以这里要求它明显早于
      // 60s 返回，且已经拿到的输出完整。
      // Windows 上后台进程会把 cwd（= 工作空间）锁住，所以把它挪到 %TEMP%，
      // 否则 tearDown 删临时目录会失败（PowerShell 用 -WorkingDirectory）。
      final DateTime started = DateTime.now();
      final ExecOutcome outcome = await io.exec(
        Platform.isWindows
            ? r'$p = Start-Process -FilePath ping -ArgumentList "-n","60","127.0.0.1"'
                  r' -NoNewWindow -WorkingDirectory $env:TEMP -PassThru; echo done'
            : 'sleep 60 & echo done',
      );
      final int elapsedMs = DateTime.now().difference(started).inMilliseconds;
      expect(outcome.stdout, contains('done'));
      expect(elapsedMs, lessThan(20000), reason: '不能等到后台子进程自己结束（那是 60s）');
    }, timeout: const Timeout(Duration(seconds: 45)));
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
