// 插件清单读写层（plugin_config_store.dart）的用例。
//
// 锁住的四件事（M9 §4.2）：
// 1. **往返**：写进去的条目能原样读回来（含 args / env / scope 的规范化）；
// 2. **保留**：顶层未知键、其它条目、条目里的未知键（如 builtin 标记、用户备注）、
//    甚至 plugins 列表里的坏条目，都不能被"改一个开关"顺手吃掉；
// 3. **校验**：id 非空唯一、command 非空、granularity 三选一、scope 键白名单、
//    args / env / enabled 类型——全部给可读中文原因，且**不落盘**；
// 4. **原子写**：写完没有残留的 .tmp（AtomicFile 的语义），文件始终可解析。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/plugin_config_store.dart';
import 'package:tree_core/src/store/yaml_codec.dart';

void main() {
  late Directory temp;
  late String path;
  late PluginConfigStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_store_');
    path = p.join(temp.path, 'config', 'plugins.yaml');
    store = PluginConfigStore(path);
  });

  tearDown(() {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        sleep(const Duration(milliseconds: 50));
      }
    }
  });

  void write(String text) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  Map<String, dynamic> readDocument() =>
      YamlCodec.decode(File(path).readAsStringSync());

  test('文件不存在时读出空清单；create 写入后可往返，且没有 .tmp 残留', () {
    expect(store.readEntries(), isEmpty);
    expect(store.totalEnabled(), isTrue, reason: '缺省 = 启用');

    final PluginStoreResult result = store.create(<String, dynamic>{
      'id': 'demo',
      'name': '演示',
      'command': 'python',
      'args': <String>['x.py', '--flag'],
      'env': <String, String>{'A': '1'},
      'granularity': 'agent',
      'scope': <String, dynamic>{'team_id': 't1', 'agent_id': 'a1'},
    });
    expect(result.ok, isTrue, reason: result.error);
    expect(result.entry!['enabled'], isTrue, reason: '缺省启用');
    expect(result.entry!['args'], <String>['x.py', '--flag']);
    expect(result.entry!['scope'], <String, dynamic>{
      'team_id': 't1',
      'agent_id': 'a1',
    });

    final List<Map<String, dynamic>> entries = store.readEntries();
    expect(entries, hasLength(1));
    expect(entries.single['id'], 'demo');
    expect(entries.single['granularity'], 'agent');
    expect(File('$path.tmp').existsSync(), isFalse, reason: '原子写的临时文件必须已被改名');
  });

  test('保留未知键：顶层、其它条目、条目内未知键与坏条目都不丢', () {
    write('''
version: 7
future_key: 未来字段
plugins:
  - id: keep
    command: python
    note: 用户手写的备注
  - 这是个坏条目
  - id: other
    command: python
''');
    final PluginStoreResult result = store.setEnabled('other', false);
    expect(result.ok, isTrue, reason: result.error);

    final Map<String, dynamic> doc = readDocument();
    expect(doc['version'], 7);
    expect(doc['future_key'], '未来字段');
    final List<dynamic> plugins = doc['plugins'] as List<dynamic>;
    expect(plugins, hasLength(3), reason: '坏条目不能被顺手删掉');
    expect(plugins[1], '这是个坏条目');
    final Map<String, dynamic> keep = plugins[0] as Map<String, dynamic>;
    expect(keep['note'], '用户手写的备注');
    final Map<String, dynamic> other = plugins[2] as Map<String, dynamic>;
    expect(other['enabled'], isFalse);
    // 总开关（顶层 enabled）也保留：原文件没写 = 缺省启用，写回时补成 true
    expect(doc['enabled'], isTrue);
  });

  test('id 唯一：重复 create 被拒且不改写文件', () {
    write('enabled: true\nplugins:\n  - id: demo\n    command: python\n');
    final PluginStoreResult dup = store.create(<String, dynamic>{
      'id': 'demo',
      'command': 'python3',
    });
    expect(dup.ok, isFalse);
    expect(dup.error, contains('已存在'));
    expect(store.readEntries().single['command'], 'python');
  });

  test('校验：id / command / granularity / scope / args / env / enabled', () {
    final List<({Map<String, dynamic> entry, String expect})> cases =
        <({Map<String, dynamic> entry, String expect})>[
          (entry: <String, dynamic>{'command': 'python'}, expect: 'id 不能为空'),
          (
            entry: <String, dynamic>{'id': '../evil', 'command': 'python'},
            expect: 'id 只允许',
          ),
          (entry: <String, dynamic>{'id': 'x'}, expect: 'command 不能为空'),
          (
            entry: <String, dynamic>{
              'id': 'x',
              'command': 'python',
              'granularity': 'global',
            },
            expect: 'granularity',
          ),
          (
            entry: <String, dynamic>{
              'id': 'x',
              'command': 'python',
              'scope': <String, dynamic>{'team': 't1'},
            },
            expect: '未知键',
          ),
          (
            entry: <String, dynamic>{
              'id': 'x',
              'command': 'python',
              'scope': <String, dynamic>{'mode_key': 'cloud'},
            },
            expect: 'mode_key',
          ),
          (
            entry: <String, dynamic>{
              'id': 'x',
              'command': 'python',
              'args': 'a b',
            },
            expect: 'args 必须是字符串数组',
          ),
          (
            entry: <String, dynamic>{
              'id': 'x',
              'command': 'python',
              'env': <String, dynamic>{'A': 1},
            },
            expect: 'env 必须是字符串到字符串',
          ),
          (
            entry: <String, dynamic>{
              'id': 'x',
              'command': 'python',
              'enabled': 'yes',
            },
            expect: 'enabled 必须是布尔值',
          ),
        ];
    for (final ({Map<String, dynamic> entry, String expect}) c in cases) {
      final PluginStoreResult result = store.create(c.entry);
      expect(result.ok, isFalse, reason: '应当被拒');
      expect(result.error, contains(c.expect));
    }
    expect(store.readEntries(), isEmpty, reason: '校验失败不落盘');
  });

  test('update：不存在报错；不能改 id；setEnabled 保留条目', () {
    write('enabled: true\nplugins:\n  - id: demo\n    command: python\n');
    expect(
      store.update('nope', <String, dynamic>{'enabled': false}).error,
      contains('不存在'),
    );
    expect(
      store.update('demo', <String, dynamic>{'id': 'renamed'}).error,
      contains('不能修改插件 id'),
    );

    final PluginStoreResult off = store.setEnabled('demo', false);
    expect(off.ok, isTrue, reason: off.error);
    expect(store.readEntries(), hasLength(1), reason: '停用 = 条目保留（面板显示已停用）');
    expect(store.readEntry('demo')!['enabled'], isFalse);
    expect(store.readEntry('demo')!['command'], 'python', reason: '开关不动其它字段');
  });

  test('内置标记：upsert 写 builtin，之后编辑开关不丢该标记', () {
    final PluginStoreResult first = store.upsert(<String, dynamic>{
      'id': 'sample',
      'name': '示例插件',
      'command': 'python',
      'args': <String>['sample_plugin.py'],
      'builtin': true,
    });
    expect(first.ok, isTrue, reason: first.error);
    expect(store.readEntry('sample')!['builtin'], isTrue);

    // 再 upsert 一次（重新解析运行时）：builtin 仍在
    expect(
      store.upsert(<String, dynamic>{
        'id': 'sample',
        'command': 'py',
        'args': <String>['-3', 'sample_plugin.py'],
        'builtin': true,
      }).ok,
      isTrue,
    );
    expect(store.readEntry('sample')!['builtin'], isTrue);
    expect(store.readEntry('sample')!['command'], 'py');

    // 停用（PATCH 语义）：builtin 与 args 都保留
    expect(store.setEnabled('sample', false).ok, isTrue);
    final Map<String, dynamic> entry = store.readEntry('sample')!;
    expect(entry['builtin'], isTrue);
    expect(entry['args'], <String>['-3', 'sample_plugin.py']);
    expect(entry['enabled'], isFalse);
  });

  test('remove：删掉目标条目，其它条目与未知键保留', () {
    write(
      'enabled: false\nplugins:\n  - id: a\n    command: python\n'
      '  - id: b\n    command: python\n',
    );
    final PluginStoreResult result = store.remove('a');
    expect(result.ok, isTrue, reason: result.error);
    expect(store.readEntries(), hasLength(1));
    expect(store.readEntries().single['id'], 'b');
    expect(store.totalEnabled(), isFalse, reason: '总开关保留');
    expect(store.remove('a').error, contains('不存在'));
  });

  test('文件被手工改坏：读成空清单但解析失败可见（回调）', () {
    final List<String> logs = <String>[];
    final PluginConfigStore noisy = PluginConfigStore(path, log: logs.add);
    write('plugins: [ {id: demo, command: python\n');
    expect(noisy.readEntries(), isEmpty);
    expect(logs.single, contains('解析失败'));
  });
}
