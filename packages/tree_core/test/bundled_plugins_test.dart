import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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

  /// 写一个目录形态的插件包（UI 插件：exe + dll + data/）。
  List<int> writeArchive(
    String dir,
    String name,
    Map<String, String> files,
  ) {
    final Archive archive = Archive();
    for (final MapEntry<String, String> item in files.entries) {
      final List<int> bytes = utf8.encode(item.value);
      archive.addFile(ArchiveFile(item.key, bytes.length, bytes));
    }
    final List<int> encoded = ZipEncoder().encode(archive);
    File(p.join(dir, name)).writeAsBytesSync(encoded);
    return encoded;
  }

  Map<String, dynamic> archiveEntry({int? bytes, String version = '0.1.0'}) =>
      <String, dynamic>{
        'id': 'tree.ui.feishu',
        'name': '飞书远程控制',
        'version': version,
        'runtime': 'ui',
        'command': 'app.exe',
        'args': <String>[],
        'granularity': 'team',
        'scope': <String, dynamic>{},
        'archive': 'tree-ui-feishu-0.1.0.zip',
        'archive_bytes': bytes ?? 0,
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

  test('命令指向的文件消失（目录形态被扁平成品覆盖）⇒ 按同版本随包成品重指，其余不动', () {
    final String dir = pluginsDir();
    writeArtifact(dir, 'demo.exe');
    writeIndex(dir, <Map<String, dynamic>>[entry()]);
    final PluginConfigStore s = store();
    // 现场：先按目录形态装过（plugins/demo/demo.exe），后来全量包换成扁平成品，
    // 旧目录被清掉，plugins.yaml 仍指旧路。
    expect(
      s.create(<String, dynamic>{
        'id': 'demo',
        'command': p.join(dir, 'demo', 'demo.exe'),
        'args': <String>[],
        'enabled': false,
        'granularity': 'team',
        'scope': <String, dynamic>{},
        'source': 'local',
        'repo_version': '1.2.3',
      }).ok,
      isTrue,
    );
    final List<String> logged = <String>[];

    final List<String> seeded = seedBundledPlugins(
      store: s,
      executableDir: temp.path,
      log: logged.add,
    );

    expect(seeded, <String>['demo']);
    final Map<String, dynamic> saved = s.readEntry('demo')!;
    expect(saved['command'], p.join(dir, 'demo.exe'));
    expect(saved['enabled'], isFalse, reason: '开关是用户状态，修路径不覆盖');
    expect(saved['source'], 'local', reason: '只修指向，不改来源');
    expect(
      logged.any((String m) => m.contains('已重指到随包成品')),
      isTrue,
    );
  });

  test('命令失效但随包版本不同 ⇒ 不擅自换二进制（只留日志）', () {
    final String dir = pluginsDir();
    writeArtifact(dir, 'demo.exe');
    writeIndex(dir, <Map<String, dynamic>>[entry(version: '2.0.0')]);
    final PluginConfigStore s = store();
    final String stale = p.join(dir, 'demo', 'demo.exe');
    expect(
      s.create(<String, dynamic>{
        'id': 'demo',
        'command': stale,
        'source': 'local',
        'repo_version': '1.2.3',
      }).ok,
      isTrue,
    );
    final List<String> logged = <String>[];

    expect(
      seedBundledPlugins(store: s, executableDir: temp.path, log: logged.add),
      isEmpty,
    );
    expect(s.readEntry('demo')!['command'], stale);
    expect(logged.any((String m) => m.contains('版本无法确认')), isTrue);
  });

  test('命令失效且随包成品缺失 ⇒ 不改配置（不写注定起不来的条目）', () {
    final String dir = pluginsDir();
    writeIndex(dir, <Map<String, dynamic>>[entry()]); // 索引有、成品没落盘
    final PluginConfigStore s = store();
    final String stale = p.join(dir, 'demo', 'demo.exe');
    expect(
      s.create(<String, dynamic>{
        'id': 'demo',
        'command': stale,
        'source': 'local',
        'repo_version': '1.2.3',
      }).ok,
      isTrue,
    );

    expect(
      seedBundledPlugins(store: s, executableDir: temp.path),
      isEmpty,
    );
    expect(s.readEntry('demo')!['command'], stale);
  });

  test('目录形态（archive）⇒ 解到 plugins/<id>/ 后登记，UI 默认停用', () {
    final String dir = pluginsDir();
    final List<int> zip = writeArchive(
      dir,
      'tree-ui-feishu-0.1.0.zip',
      <String, String>{
        './app.exe': 'exe',
        './data/flutter_assets/hint.txt': 'data',
      },
    );
    writeIndex(dir, <Map<String, dynamic>>[archiveEntry(bytes: zip.length)]);
    final PluginConfigStore s = store();

    expect(
      seedBundledPlugins(store: s, executableDir: temp.path),
      <String>['tree.ui.feishu'],
    );
    final Map<String, dynamic> saved = s.readEntry('tree.ui.feishu')!;
    expect(saved['command'], p.join(dir, 'tree.ui.feishu', 'app.exe'));
    expect(saved['runtime'], 'ui');
    expect(saved['enabled'], isFalse, reason: '替代界面不该自己弹窗');
    expect(
      File(p.join(dir, 'tree.ui.feishu', 'data', 'flutter_assets', 'hint.txt'))
          .existsSync(),
      isTrue,
    );
    // 幂等：解过一次就不再动（也不会把用户后来打开的开关关回去）。
    expect(
      seedBundledPlugins(store: s, executableDir: temp.path),
      isEmpty,
    );
  });

  test('目录形态：命令失效 + 同版本 ⇒ 重新解包并重指，开关与来源保留', () {
    final String dir = pluginsDir();
    final List<int> zip = writeArchive(
      dir,
      'tree-ui-feishu-0.1.0.zip',
      <String, String>{'./app.exe': 'exe'},
    );
    writeIndex(dir, <Map<String, dynamic>>[archiveEntry(bytes: zip.length)]);
    final PluginConfigStore s = store();
    final String command = p.join(dir, 'tree.ui.feishu', 'app.exe');
    expect(
      s.create(<String, dynamic>{
        'id': 'tree.ui.feishu',
        'command': command,
        'runtime': 'ui',
        'source': 'local',
        'repo_version': '0.1.0',
        'enabled': false,
      }).ok,
      isTrue,
    );

    expect(
      seedBundledPlugins(store: s, executableDir: temp.path),
      <String>['tree.ui.feishu'],
    );
    final Map<String, dynamic> saved = s.readEntry('tree.ui.feishu')!;
    expect(saved['command'], command);
    expect(saved['source'], 'local');
    expect(saved['enabled'], isFalse);
    expect(File(command).existsSync(), isTrue);
  });

  test('目录形态：插件包字节数不符 ⇒ 不解包也不登记', () {
    final String dir = pluginsDir();
    final List<int> zip = writeArchive(
      dir,
      'tree-ui-feishu-0.1.0.zip',
      <String, String>{'./app.exe': 'exe'},
    );
    writeIndex(
      dir,
      <Map<String, dynamic>>[archiveEntry(bytes: zip.length + 1)],
    );
    final PluginConfigStore s = store();

    expect(
      seedBundledPlugins(store: s, executableDir: temp.path),
      isEmpty,
    );
    expect(s.readEntry('tree.ui.feishu'), isNull);
    expect(Directory(p.join(dir, 'tree.ui.feishu')).existsSync(), isFalse);
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
