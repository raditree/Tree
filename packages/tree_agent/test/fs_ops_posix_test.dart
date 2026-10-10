import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent/tree_agent.dart';

import 'support.dart';

/// **POSIX 专属**：符号链接语义（Windows 建链接要特权，开发机上跑不了）。
///
/// 断言的是协议 §4 / 不变量 12 的口径：**按链接本身操作、不跟着符号链接删穿**。
/// 这些用例在 Windows 上以可读理由 skip —— **不是**把断言删掉，M7 会用交叉编译出的
/// Linux 二进制在 WSL/Docker 里真跑它们。
/// 非 POSIX 平台（Windows 开发机）显式 skip —— **带可读理由**，且**一条断言都不删**；
/// M7 会用交叉编译出的 Linux 二进制在 WSL/Docker 里真跑它们。
final String? posixSkipReason = Platform.isWindows
    ? 'POSIX 专属（符号链接语义）：Windows 开发机跳过，M7 用交叉编译的 Linux 二进制真跑'
    : null;

void main() {
  late Directory root;
  late String rootPath;
  late FsOps fs;

  setUp(() {
    root = createTempRoot('fs_posix');
    rootPath = toPosix(root.path);
    fs = FsOps(PathGuard(rootPath));
  });

  tearDown(() => removeTempRoot(root));

  Future<FileSystemEntityType> typeOf(String path) =>
      FileSystemEntity.type(path, followLinks: false);

  group('符号链接', () {
    test('fs.remove(recursive) 删链接目录，**不删穿**到它的目标', () async {
      writeFile('$rootPath/real/file.txt', <int>[1, 2, 3]);
      await Link('$rootPath/link').create('$rootPath/real');

      await fs.remove(<String, dynamic>{
        'path': '$rootPath/link',
        'recursive': true,
      });

      expect(await typeOf('$rootPath/link'), FileSystemEntityType.notFound);
      expect(
        await File('$rootPath/real/file.txt').exists(),
        true,
        reason: '链接被删，目标必须原样还在',
      );
    });

    test('fs.list 不跟着链接目录穿；链接文件算文件', () async {
      writeFile('$rootPath/real/file.txt', <int>[1]);
      writeFile('$rootPath/other/target.txt', <int>[2]);
      await Link('$rootPath/linkdir').create('$rootPath/real');
      await Link('$rootPath/linkfile').create('$rootPath/other/target.txt');

      final Map<String, dynamic> r = await fs.list(<String, dynamic>{
        'path': rootPath,
      });
      final Set<String> files = (r['files'] as List<dynamic>)
          .cast<String>()
          .toSet();
      expect(files, <String>{
        'real/file.txt',
        'other/target.txt',
        'linkfile',
      });
      expect(
        files.any((String f) => f.startsWith('linkdir/')),
        false,
        reason: '链接目录不能被穿进去（防环，也防"删到外面"）',
      );
    });

    test('fs.listEntries 把链接报成 link（不跟随）', () async {
      writeFile('$rootPath/other/target.txt', <int>[2]);
      await Link('$rootPath/linkfile').create('$rootPath/other/target.txt');

      final Map<String, dynamic> r = await fs.listEntries(<String, dynamic>{
        'path': rootPath,
      });
      final Iterable<Map<String, dynamic>> entries = (r['entries'] as List<dynamic>)
          .map((dynamic e) => (e as Map<dynamic, dynamic>).cast<String, dynamic>());
      final Map<String, dynamic> linkEntry = entries.firstWhere(
        (Map<String, dynamic> e) => e['name'] == 'linkfile',
      );
      expect(linkEntry['type'], 'link');
    });

    test('链接文件可以按链接本身删掉（目标不受影响）', () async {
      writeFile('$rootPath/other/target.txt', <int>[2]);
      await Link('$rootPath/linkfile').create('$rootPath/other/target.txt');

      await fs.remove(<String, dynamic>{'path': '$rootPath/linkfile'});
      expect(await typeOf('$rootPath/linkfile'), FileSystemEntityType.notFound);
      expect(await File('$rootPath/other/target.txt').exists(), true);
    });
  }, skip: posixSkipReason);
}
