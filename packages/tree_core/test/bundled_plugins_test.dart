import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 随包插件自动登记（全量版安装包）的口径：
/// 只有「索引在 + 成品齐 + 字节数对 + 用户没写过这一条」才落盘，其余一律跳过。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_bundled_');
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  PluginConfigStore store() =>
      PluginConfigStore(p.join(temp.path, 'config', 'plugins.yaml'));

  String pluginsDir() {
    final String dir = p.join(temp.path, 'plugins');
    Directory(dir).createSync(recursive: true);
    return dir;
  }

  void writeArtifact(String dir, String target, {int bytes = 3}) {
    File(p.join(dir, target)).writeAsStringSync('x' * bytes);
  }

  void writeIndex(String dir, List<Map<String, dynamic>> plugins) {
    File(p.join(dir, kBundledPluginIndexName)).writeAsStringSync(
      jsonEncode(<String, dynamic>{'schema': 1, 'plugins': plugins}),
    );
  }

  Map<String, dynamic> entry({
    String id = 'demo',
    String target = 'demo.exe',
    int bytes = 3,
    String runtime = 'headless',
    String command = '',
    String version = '1.2.3',
    String name = '',
  }) => <String, dynamic>{
    'id': id,
    'name': name.isEmpty ? '示例 $id' : name,
    'version': version,
    'runtime': runtime,
    'command': command.isEmpty ? target : command,
    'args': <String>[],
    'files': <Map<String, dynamic>>[
      <String, dynamic>{'asset': target, 'target': target, 'bytes': bytes},
    ],
    'granularity': 'team',
    'scope': <String, dynamic>{},
  };

  test('成品齐、字节数对 ⇒ 登记为绝对路径并启用', () {
    final String dir = pluginsDir();
    writeArtifact(dir, 'demo.exe');
    writeIndex(dir, <Map<String, dynamic>>[entry()]);

    final PluginConfigStore s = store();
    final List<String> seeded = seedBundledPlugins(
      store: s,
      executableDir: temp.path,
    );

    expect(seeded, <String>['demo']);
    final Map<String, dynamic>? saved = s.readEntry('demo');
    expect(saved, isNotNull);
    expect(saved!['command'], p.join(dir, 'demo.exe'));
    expect(saved['enabled'], isTrue);
    expect(saved['source'], kBundledPluginSourceValue);
    expect(saved['repo_version'], '1.2.3');
  });

  test('幂等：第二次不重复写，也不动用户已有关闭状态', () {
    final String dir = pluginsDir();
    writeArtifact(dir, 'demo.exe');
    writeIndex(dir, <Map<String, dynamic>>[entry()]);
    final PluginConfigStore s = store();
    seedBundledPlugins(store: s, executableDir: temp.path);
    expect(s.setEnabled('demo', false).ok, isTrue);

    expect(
      seedBundledPlugins(store: s, executableDir: temp.path),
      isEmpty,
    );
    expect(s.readEntry('demo')!['enabled'], isFalse);
  });

  test('比版本号变了 ⇒ 原地升级，保留用户的停用状态', () {
    final String dir = pluginsDir();
    writeArtifact(dir, 'demo.exe');
    writeIndex(dir, <Map<String, dynamic>>[entry()]);
    final PluginConfigStore s = store();
    seedBundledPlugins(store: s, executableDir: temp.path);
    expect(s.setEnabled('demo', false).ok, isTrue);

    writeIndex(dir, <Map<String, dynamic>>[entry(version: '2.0.0')]);
    expect(
      seedBundledPlugins(store: s, executableDir: temp.path),
      <String>['demo'],
    );
    final Map<String, dynamic> saved = s.readEntry('demo')!;
    expect(saved['repo_version'], '2.0.0');
    expect(saved['enabled'], isFalse, reason: '开关是用户状态，升级不覆盖');
  });

  test('版本号没变但成品字节变了 ⇒ 按指纹原地升级', () {
    final String dir = pluginsDir();
    writeArtifact(dir, 'demo.exe', bytes: 3);
    writeIndex(dir, <Map<String, dynamic>>[entry(bytes: 3)]);
    final PluginConfigStore s = store();
    seedBundledPlugins(store: s, executableDir: temp.path);

    // 同样 3 字节、内容不同：只看长度会漏，指纹要能认出来。
    File(p.join(dir, 'demo.exe')).writeAsStringSync('yyy');
    writeIndex(
      dir,
      <Map<String, dynamic>>[entry(bytes: 3, name: '重建版')],
    );
    expect(
      seedBundledPlugins(store: s, executableDir: temp.path),
      <String>['demo'],
    );
    expect(s.readEntry('demo')!['name'], '重建版');
  });

  test('用户手改过（command / args / env / scope）⇒ 不升级', () {
    final String dir = pluginsDir();
    writeArtifact(dir, 'demo.exe');
    writeIndex(dir, <Map<String, dynamic>>[entry()]);
    final PluginConfigStore s = store();
    seedBundledPlugins(store: s, executableDir: temp.path);

    final String custom = p.join(temp.path, 'my-build.exe');
    expect(s.update('demo', <String, dynamic>{'command': custom}).ok, isTrue);
    writeIndex(dir, <Map<String, dynamic>>[entry(version: '9.9.9')]);
    expect(
      seedBundledPlugins(store: s, executableDir: temp.path),
      isEmpty,
    );
    final Map<String, dynamic> saved = s.readEntry('demo')!;
    expect(saved['command'], custom);
    expect(saved['repo_version'], '1.2.3');
  });

  test('存量条目先记基线，下次启动才参与升级', () {
    final String dir = pluginsDir();
    writeArtifact(dir, 'demo.exe');
    writeIndex(dir, <Map<String, dynamic>>[entry()]);
    final PluginConfigStore s = store();
    // 模拟本特性上线前登记的条目：有 source: bundled，但没有指纹/签名。
    expect(
      s.create(<String, dynamic>{
        'id': 'demo',
        'name': '旧名字',
        'command': p.join(dir, 'demo.exe'),
        'source': kBundledPluginSourceValue,
        'repo_version': '1.2.3',
      }).ok,
      isTrue,
    );

    expect(
      seedBundledPlugins(store: s, executableDir: temp.path),
      isEmpty,
      reason: '第一次只记录基线，不覆盖存量条目',
    );
    expect(s.readEntry('demo')![kBundledDigestKey], isNotNull);
    expect(s.readEntry('demo')![kBundledSnapshotKey], isNotNull);

    File(p.join(dir, 'demo.exe')).writeAsStringSync('yyyy');
    writeIndex(
      dir,
      <Map<String, dynamic>>[entry(bytes: 4, name: '新名字')],
    );
    expect(
      seedBundledPlugins(store: s, executableDir: temp.path),
      <String>['demo'],
    );
    expect(s.readEntry('demo')!['name'], '新名字');
  });

  test('local / release 来源的条目不动（不是随包安装的）', () {
    final String dir = pluginsDir();
    writeArtifact(dir, 'demo.exe');
    writeIndex(dir, <Map<String, dynamic>>[entry(version: '9.9.9')]);
    final PluginConfigStore s = store();
    final String mine = p.join(temp.path, 'mine.exe');
    expect(
      s.create(<String, dynamic>{
        'id': 'demo',
        'command': mine,
        'source': 'local',
      }).ok,
      isTrue,
    );

    expect(
      seedBundledPlugins(store: s, executableDir: temp.path),
      isEmpty,
    );
    expect(s.readEntry('demo')!['command'], mine);
  });

  test('成品缺失 / 字节数不符 ⇒ 跳过并给出原因', () {
    final String dir = pluginsDir();
    writeArtifact(dir, 'a.exe', bytes: 3);
    writeIndex(dir, <Map<String, dynamic>>[
      entry(id: 'missing', target: 'missing.exe'),
      entry(id: 'short', target: 'a.exe', bytes: 99),
    ]);
    final List<String> logged = <String>[];

    final List<String> seeded = seedBundledPlugins(
      store: store(),
      executableDir: temp.path,
      log: logged.add,
    );

    expect(seeded, isEmpty);
    expect(logged.any((String m) => m.contains('missing')), isTrue);
    expect(logged.any((String m) => m.contains('字节数不符')), isTrue);
  });

  test('runtime=ui 不在这里登记（界面走 seedDesktopUiPlugin）', () {
    final String dir = pluginsDir();
    writeArtifact(dir, 'tree_ui.exe');
    writeIndex(dir, <Map<String, dynamic>>[
      entry(id: 'tree.ui.default', target: 'tree_ui.exe', runtime: 'ui'),
    ]);

    expect(
      seedBundledPlugins(store: store(), executableDir: temp.path),
      isEmpty,
    );
  });

  test('没有随包索引 ⇒ 空操作（普通发行版走发布仓库）', () {
    final String dir = pluginsDir();
    writeArtifact(dir, 'demo.exe');
    expect(
      seedBundledPlugins(store: store(), executableDir: temp.path),
      isEmpty,
    );
    expect(File(p.join(dir, kBundledPluginIndexName)).existsSync(), isFalse);
  });
}
