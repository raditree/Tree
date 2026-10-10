import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent/tree_agent.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'support.dart';

/// 造一个小的目录树：
/// ```
/// root/a.txt
/// root/sub/b.txt
/// root/sub/deep/c.txt
/// root/.hidden/h.txt
/// ```
void buildTree(String rootPath) {
  writeFile('$rootPath/a.txt', utf8.encode('aaa'));
  writeFile('$rootPath/sub/b.txt', utf8.encode('bbb'));
  writeFile('$rootPath/sub/deep/c.txt', utf8.encode('ccc'));
  writeFile('$rootPath/.hidden/h.txt', utf8.encode('hhh'));
}

void main() {
  late Directory root;
  late String rootPath;
  late FsOps fs;

  setUp(() {
    root = createTempRoot('fs');
    rootPath = toPosix(root.path);
    fs = FsOps(PathGuard(rootPath));
  });

  tearDown(() => removeTempRoot(root));

  group('fs.read', () {
    test('分块 ≤ kReadChunkBytes；offset/eof 正确；拼接后逐字节等于原文', () async {
      final List<int> original = List<int>.generate(
        kReadChunkBytes + 137,
        (int i) => (i * 31 + 7) % 256,
      );
      writeFile('$rootPath/big.bin', original);

      final Map<String, dynamic> first = await fs.read(<String, dynamic>{
        'path': '$rootPath/big.bin',
      });
      expect(first['size'], original.length);
      expect(first['offset'], 0);
      expect(first['eof'], false);
      final List<int> chunk1 = base64Decode(first['data'] as String);
      expect(chunk1.length, kReadChunkBytes, reason: '单次最多 kReadChunkBytes 原文');

      final Map<String, dynamic> second = await fs.read(<String, dynamic>{
        'path': '$rootPath/big.bin',
        'offset': kReadChunkBytes,
      });
      final List<int> chunk2 = base64Decode(second['data'] as String);
      expect(chunk2.length, 137);
      expect(second['offset'], kReadChunkBytes);
      expect(second['eof'], true);

      expect(<int>[...chunk1, ...chunk2], original, reason: '字节无损（不变量 17 的前提）');
    });

    test('length 只给想要的量；给 0 不报错', () async {
      writeFile('$rootPath/x.txt', utf8.encode('hello world'));
      final Map<String, dynamic> r = await fs.read(<String, dynamic>{
        'path': '$rootPath/x.txt',
        'offset': 6,
        'length': 5,
      });
      expect(utf8.decode(base64Decode(r['data'] as String)), 'world');
      expect(r['eof'], true, reason: '读到了文件末尾');

      final Map<String, dynamic> head = await fs.read(<String, dynamic>{
        'path': '$rootPath/x.txt',
        'offset': 0,
        'length': 5,
      });
      expect(utf8.decode(base64Decode(head['data'] as String)), 'hello');
      expect(head['eof'], false, reason: '后面还有');

      final Map<String, dynamic> empty = await fs.read(<String, dynamic>{
        'path': '$rootPath/x.txt',
        'length': 0,
      });
      expect(base64Decode(empty['data'] as String), isEmpty);
    });

    test('offset 超过文件长度 ⇒ 空块 + eof', () async {
      writeFile('$rootPath/x.txt', utf8.encode('abc'));
      final Map<String, dynamic> r = await fs.read(<String, dynamic>{
        'path': '$rootPath/x.txt',
        'offset': 999,
      });
      expect(base64Decode(r['data'] as String), isEmpty);
      expect(r['offset'], 3);
      expect(r['eof'], true);
    });

    test('空文件：eof=true、data 为空', () async {
      writeFile('$rootPath/empty.txt', const <int>[]);
      final Map<String, dynamic> r = await fs.read(<String, dynamic>{
        'path': '$rootPath/empty.txt',
      });
      expect(r['size'], 0);
      expect(base64Decode(r['data'] as String), isEmpty);
      expect(r['eof'], true);
    });

    test('不存在 / 是目录 ⇒ not_found', () async {
      expect(
        () => fs.read(<String, dynamic>{'path': '$rootPath/nope.txt'}),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.notFound,
          ),
        ),
      );
      await Directory('$rootPath/adir').create();
      expect(
        () => fs.read(<String, dynamic>{'path': '$rootPath/adir'}),
        throwsA(isA<RpcException>()),
      );
    });
  });

  group('fs.write', () {
    test('write 覆盖、append 追加，且自动建父目录', () async {
      await fs.write(<String, dynamic>{
        'path': '$rootPath/deep/nested/f.txt',
        'data': base64Encode(utf8.encode('one')),
      });
      expect(await File('$rootPath/deep/nested/f.txt').readAsString(), 'one');

      await fs.write(<String, dynamic>{
        'path': '$rootPath/deep/nested/f.txt',
        'data': base64Encode(utf8.encode('two')),
      });
      expect(await File('$rootPath/deep/nested/f.txt').readAsString(), 'two');

      await fs.write(<String, dynamic>{
        'path': '$rootPath/deep/nested/f.txt',
        'data': base64Encode(utf8.encode('-three')),
        'mode': 'append',
      });
      expect(
        await File('$rootPath/deep/nested/f.txt').readAsString(),
        'two-three',
      );
    });

    test('二进制（非 UTF-8）字节无损往返', () async {
      final List<int> bytes = <int>[0x00, 0xff, 0xfe, 0x80, 0x0a, 0x0d, 0xc3];
      await fs.write(<String, dynamic>{
        'path': '$rootPath/bin.dat',
        'data': base64Encode(bytes),
      });
      final Map<String, dynamic> r = await fs.read(<String, dynamic>{
        'path': '$rootPath/bin.dat',
      });
      expect(base64Decode(r['data'] as String), bytes);
    });

    test('非法 base64 / 非法 mode ⇒ invalidParams', () async {
      expect(
        () => fs.write(<String, dynamic>{
          'path': '$rootPath/a',
          'data': '!!!!',
        }),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            RpcCodes.invalidParams,
          ),
        ),
      );
      expect(
        () => fs.write(<String, dynamic>{
          'path': '$rootPath/a',
          'data': base64Encode(const <int>[]),
          'mode': 'truncate',
        }),
        throwsA(isA<RpcException>()),
      );
    });
  });

  group('fs.stat / fs.exists / fs.isDir', () {
    test('stat：file / dir / missing（missing 不抛）', () async {
      writeFile('$rootPath/a.txt', utf8.encode('abc'));
      await Directory('$rootPath/d').create();

      final Map<String, dynamic> file = await fs.stat(<String, dynamic>{
        'path': '$rootPath/a.txt',
      });
      expect(file['type'], 'file');
      expect(file['size'], 3);
      expect(file['mtime_ms'], isA<int>());

      final Map<String, dynamic> dir = await fs.stat(<String, dynamic>{
        'path': '$rootPath/d',
      });
      expect(dir['type'], 'dir');

      final Map<String, dynamic> missing = await fs.stat(<String, dynamic>{
        'path': '$rootPath/nope',
      });
      expect(missing['type'], 'missing');
      expect(missing['size'], 0);
    });

    test('exists / isDir', () async {
      writeFile('$rootPath/a.txt', utf8.encode('abc'));
      await Directory('$rootPath/d').create();

      expect(await fs.exists(<String, dynamic>{'path': '$rootPath/a.txt'}), <String, dynamic>{
        'exists': true,
        'is_dir': false,
      });
      expect(await fs.exists(<String, dynamic>{'path': '$rootPath/d'}), <String, dynamic>{
        'exists': true,
        'is_dir': true,
      });
      expect(await fs.exists(<String, dynamic>{'path': '$rootPath/nope'}), <String, dynamic>{
        'exists': false,
        'is_dir': false,
      });
      expect(await fs.isDir(<String, dynamic>{'path': '$rootPath/d'}), <String, dynamic>{
        'is_dir': true,
      });
      expect(await fs.isDir(<String, dynamic>{'path': '$rootPath/a.txt'}), <String, dynamic>{
        'is_dir': false,
      });
    });
  });

  group('fs.list（递归、只列文件、相对 path）', () {
    test('默认递归到 8 层；相对路径用正斜杠；不含目录本身', () async {
      buildTree(rootPath);
      final Map<String, dynamic> r = await fs.list(<String, dynamic>{
        'path': rootPath,
      });
      expect(
        (r['files'] as List<dynamic>).cast<String>().toSet(),
        <String>{
          'a.txt',
          'sub/b.txt',
          'sub/deep/c.txt',
          '.hidden/h.txt',
        },
      );
      expect(r['truncated'], false);
      expect(r['scanned'], isA<int>());
    });

    test('max_depth 真限制深度', () async {
      buildTree(rootPath);
      expect(
        ((await fs.list(<String, dynamic>{
          'path': rootPath,
          'max_depth': 1,
        }))['files'] as List<dynamic>).cast<String>(),
        <String>['a.txt'],
      );
      expect(
        ((await fs.list(<String, dynamic>{
          'path': rootPath,
          'max_depth': 2,
        }))['files'] as List<dynamic>).cast<String>().toSet(),
        <String>{'a.txt', 'sub/b.txt', '.hidden/h.txt'},
      );
    });

    test('max_entries 到顶 ⇒ truncated=true', () async {
      buildTree(rootPath);
      final Map<String, dynamic> r = await fs.list(<String, dynamic>{
        'path': rootPath,
        'max_entries': 2,
      });
      expect((r['files'] as List<dynamic>).length, 2);
      expect(r['truncated'], true);
    });

    test('子目录也能单独列（相对该目录）', () async {
      buildTree(rootPath);
      expect(
        ((await fs.list(<String, dynamic>{
          'path': '$rootPath/sub',
        }))['files'] as List<dynamic>).cast<String>().toSet(),
        <String>{'b.txt', 'deep/c.txt'},
      );
    });

    test('不存在 / 是文件 ⇒ not_found', () async {
      writeFile('$rootPath/a.txt', utf8.encode('x'));
      expect(
        () => fs.list(<String, dynamic>{'path': '$rootPath/zzz'}),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.notFound,
          ),
        ),
      );
      expect(
        () => fs.list(<String, dynamic>{'path': '$rootPath/a.txt'}),
        throwsA(isA<RpcException>()),
      );
    });
  });

  group('fs.listEntries（一层，带元信息）', () {
    test('name / type / size 正确；目录 size 记 0', () async {
      buildTree(rootPath);
      final Map<String, dynamic> r = await fs.listEntries(<String, dynamic>{
        'path': rootPath,
      });
      final Map<String, Map<String, dynamic>> byName =
          <String, Map<String, dynamic>>{
            for (final dynamic e in r['entries'] as List<dynamic>)
              ((e as Map<String, dynamic>)['name'] as String):
                  e.cast<String, dynamic>(),
          };
      expect(byName.keys.toSet(), <String>{'a.txt', 'sub', '.hidden'});
      expect(byName['a.txt']!['type'], 'file');
      expect(byName['a.txt']!['size'], 3);
      expect(byName['sub']!['type'], 'dir');
      expect(byName['sub']!['size'], 0);
    });

    test('max_entries 生效；不存在 ⇒ not_found', () async {
      buildTree(rootPath);
      final Map<String, dynamic> r = await fs.listEntries(<String, dynamic>{
        'path': rootPath,
        'max_entries': 1,
      });
      expect((r['entries'] as List<dynamic>).length, 1);
      expect(
        () => fs.listEntries(<String, dynamic>{'path': '$rootPath/zzz'}),
        throwsA(isA<RpcException>()),
      );
    });
  });

  group('fs.mkdir', () {
    test('父目录不存在 ⇒ -32005 parent_missing', () async {
      expect(
        () => fs.mkdir(<String, dynamic>{'path': '$rootPath/no/where'}),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.parentMissing,
          ),
        ),
      );
    });

    test('已存在 ⇒ -32003 already_exists（文件 / 目录都算）', () async {
      await fs.mkdir(<String, dynamic>{'path': '$rootPath/d'});
      expect(
        () => fs.mkdir(<String, dynamic>{'path': '$rootPath/d'}),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.alreadyExists,
          ),
        ),
      );
      writeFile('$rootPath/f', utf8.encode('x'));
      expect(
        () => fs.mkdir(<String, dynamic>{'path': '$rootPath/f'}),
        throwsA(isA<RpcException>()),
      );
    });

    test('recursive=true 时自动建父目录（缺省是 false）', () async {
      await fs.mkdir(<String, dynamic>{
        'path': '$rootPath/a/b/c',
        'recursive': true,
      });
      expect(await Directory('$rootPath/a/b/c').exists(), true);
    });
  });

  group('fs.rename', () {
    test('成功移动（文件与目录都行）', () async {
      writeFile('$rootPath/a.txt', utf8.encode('x'));
      await fs.rename(<String, dynamic>{
        'from': '$rootPath/a.txt',
        'to': '$rootPath/b.txt',
      });
      expect(await File('$rootPath/b.txt').exists(), true);
      expect(await File('$rootPath/a.txt').exists(), false);

      await Directory('$rootPath/d1').create();
      await fs.rename(<String, dynamic>{
        'from': '$rootPath/d1',
        'to': '$rootPath/d2',
      });
      expect(await Directory('$rootPath/d2').exists(), true);
    });

    test('源不存在 ⇒ -32002；目标已存在 ⇒ -32003（绝不覆盖）', () async {
      writeFile('$rootPath/a.txt', utf8.encode('x'));
      writeFile('$rootPath/b.txt', utf8.encode('y'));
      expect(
        () => fs.rename(<String, dynamic>{
          'from': '$rootPath/zzz',
          'to': '$rootPath/c.txt',
        }),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.notFound,
          ),
        ),
      );
      expect(
        () => fs.rename(<String, dynamic>{
          'from': '$rootPath/a.txt',
          'to': '$rootPath/b.txt',
        }),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.alreadyExists,
          ),
        ),
      );
      expect(await File('$rootPath/b.txt').readAsString(), 'y', reason: '没被覆盖');
    });

    test('from 与 to **两个**都做越界检查', () async {
      expect(
        () => fs.rename(<String, dynamic>{
          'from': '/etc/passwd',
          'to': '$rootPath/x',
        }),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.pathOutOfRoot,
          ),
        ),
      );
      writeFile('$rootPath/a.txt', utf8.encode('x'));
      expect(
        () => fs.rename(<String, dynamic>{
          'from': '$rootPath/a.txt',
          'to': '/tmp/escape',
        }),
        throwsA(isA<RpcException>()),
      );
    });
  });

  group('fs.remove', () {
    test('目录非空且 recursive=false ⇒ -32004 not_empty', () async {
      buildTree(rootPath);
      expect(
        () => fs.remove(<String, dynamic>{'path': '$rootPath/sub'}),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.notEmpty,
          ),
        ),
      );
      expect(await Directory('$rootPath/sub').exists(), true, reason: '拒绝后目录还在');
    });

    test('空目录可直接删；recursive=true 删整棵', () async {
      await Directory('$rootPath/empty').create();
      await fs.remove(<String, dynamic>{'path': '$rootPath/empty'});
      expect(await Directory('$rootPath/empty').exists(), false);

      buildTree(rootPath);
      await fs.remove(<String, dynamic>{
        'path': '$rootPath/sub',
        'recursive': true,
      });
      expect(await Directory('$rootPath/sub').exists(), false);
    });

    test('文件按链接本身删；不存在的路径 ⇒ not_found', () async {
      writeFile('$rootPath/a.txt', utf8.encode('x'));
      await fs.remove(<String, dynamic>{'path': '$rootPath/a.txt'});
      expect(await File('$rootPath/a.txt').exists(), false);
      expect(
        () => fs.remove(<String, dynamic>{'path': '$rootPath/zzz'}),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.notFound,
          ),
        ),
      );
    });
  });

  group('fs.delete', () {
    test('删文件；**不存在不报错**', () async {
      writeFile('$rootPath/a.txt', utf8.encode('x'));
      await fs.delete(<String, dynamic>{'path': '$rootPath/a.txt'});
      expect(await File('$rootPath/a.txt').exists(), false);
      // 第二次（已不存在）仍然成功
      await fs.delete(<String, dynamic>{'path': '$rootPath/a.txt'});
    });
  });

  group('越界防护（每个方法都过 PathGuard）', () {
    test('全部 fs.* 对 root 之外的路径回 -32001', () async {
      final Map<String, Map<String, dynamic>> calls = <String, Map<String, dynamic>>{
        'read': <String, dynamic>{'path': '/etc/passwd'},
        'write': <String, dynamic>{'path': '/tmp/x', 'data': ''},
        'stat': <String, dynamic>{'path': '/etc'},
        'exists': <String, dynamic>{'path': '/etc'},
        'list': <String, dynamic>{'path': '/etc'},
        'listEntries': <String, dynamic>{'path': '/etc'},
        'mkdir': <String, dynamic>{'path': '/tmp/new'},
        'remove': <String, dynamic>{'path': '/tmp'},
        'delete': <String, dynamic>{'path': '/tmp/x'},
        'isDir': <String, dynamic>{'path': '/etc'},
      };
      for (final MapEntry<String, Map<String, dynamic>> entry in calls.entries) {
        Future<Map<String, dynamic>> Function(Map<String, dynamic>) method;
        switch (entry.key) {
          case 'read':
            method = fs.read;
          case 'write':
            method = fs.write;
          case 'stat':
            method = fs.stat;
          case 'exists':
            method = fs.exists;
          case 'list':
            method = fs.list;
          case 'listEntries':
            method = fs.listEntries;
          case 'mkdir':
            method = fs.mkdir;
          case 'remove':
            method = fs.remove;
          case 'delete':
            method = fs.delete;
          default:
            method = fs.isDir;
        }
        await expectLater(
          method(entry.value),
          throwsA(
            isA<RpcException>().having(
              (RpcException e) => e.code,
              'code',
              TunnelErrorCodes.pathOutOfRoot,
            ),
          ),
          reason: '${entry.key} 必须挡越界',
        );
      }
    });

    test('破坏性操作拒绝工作空间根自身', () async {
      expect(
        () => fs.remove(<String, dynamic>{
          'path': rootPath,
          'recursive': true,
        }),
        throwsA(isA<RpcException>()),
      );
      expect(
        () => fs.delete(<String, dynamic>{'path': rootPath}),
        throwsA(isA<RpcException>()),
      );
      expect(await Directory(rootPath).exists(), true);
    });
  });
}
