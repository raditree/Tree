// 随安装包发布的**默认界面插件**（`tree.ui.default`）首启登记：钉住"双击能出界面"。
//
// 背景（2026-11-01 用户报的致命问题）：安装器把 `Tree.exe` 交给了引导壳，界面本身是
// `runtime: ui` 插件（同目录 `tree_ui.exe` + `plugin.json`）。核心只按 `plugins.yaml`
// 拉起插件 —— 新装机的清单里**没有这一条**，所以核心永远不拉界面，普通用户双击后
// 什么都看不到。`seedDesktopUiPlugin` 就是补这一条，口径只有四条：
// 1. 文件在才写（没有 `tree_ui` 就不留一条注定起不来的配置）；
// 2. 条目在就尊重现状（用户停用了就绝不自动打开）；
// 3. 换安装目录 / 升级后旧 command 指空了，只修路径（enabled / env 原样保留）；
// 4. 不是 `builtin: true` 的同 id 条目（用户手写的）一点都不动。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late String executableDir;
  late PluginConfigStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_ui_seed_');
    executableDir = temp.path;
    final File config = File(p.join(temp.path, 'config', 'plugins.yaml'));
    config.createSync(recursive: true);
    store = PluginConfigStore(config.path);
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

  String uiCommand() => p.join(executableDir, kDesktopUiBinaryName);

  void placeUi() =>
      File(uiCommand()).writeAsStringSync('placeholder');

  test('界面文件不在 ⇒ 什么都不写（不留一条注定起不来的配置）', () async {
    final List<String> lines = <String>[];
    expect(
      await seedDesktopUiPlugin(
        store: store,
        executableDir: executableDir,
        isWindows: false,
        log: lines.add,
      ),
      isEmpty,
    );
    expect(store.readEntry(kDesktopUiPluginId), isNull);
    expect(lines, isEmpty);
  });

  test('首启：登记一条 runtime=ui、enabled=true 的条目', () async {
    placeUi();
    final List<String> seeded = await seedDesktopUiPlugin(
      store: store,
      executableDir: executableDir,
      isWindows: false,
    );
    expect(seeded, <String>[kDesktopUiPluginId]);
    final Map<String, dynamic> entry = store.readEntry(kDesktopUiPluginId)!;
    expect(entry['command'], uiCommand(), reason: '必须是绝对路径：安装目录不固定');
    expect(entry['runtime'], 'ui', reason: '核心据此走 UiHost，而不是 stdio 的 headless 分支');
    expect(entry['enabled'], isTrue);
    expect(entry['builtin'], isTrue, reason: '只有标了 builtin 的这条才允许本函数修路径');
    expect(
      (entry['requires'] as Map)['api'],
      '>=1.0 <2.0',
      reason: 'UI 与核心的 API 合同：缺了会被依赖闸门拦下',
    );
  });

  test('幂等：已登记且路径一致 ⇒ 不重复写、不产日志', () async {
    placeUi();
    await seedDesktopUiPlugin(
      store: store,
      executableDir: executableDir,
      isWindows: false,
    );
    final List<String> lines = <String>[];
    expect(
      await seedDesktopUiPlugin(
        store: store,
        executableDir: executableDir,
        isWindows: false,
        log: lines.add,
      ),
      isEmpty,
    );
    expect(lines, isEmpty);
  });

  test('用户手动停用 ⇒ 尊重现状，绝不自动打开', () async {
    placeUi();
    await seedDesktopUiPlugin(
      store: store,
      executableDir: executableDir,
      isWindows: false,
    );
    expect(
      store.setEnabled(kDesktopUiPluginId, false).ok,
      isTrue,
      reason: '夹具：模拟用户在面板/手改里关掉界面插件',
    );
    expect(
      await seedDesktopUiPlugin(
        store: store,
        executableDir: executableDir,
        isWindows: false,
      ),
      isEmpty,
      reason: '条目在、路径也对：这条路径不该被重写',
    );
    expect(store.readEntry(kDesktopUiPluginId)!['enabled'], isFalse);
  });

  test('换安装目录 / 升级 ⇒ 只修 command，enabled 与 env 原样保留', () async {
    // 旧目录里那条（文件已经不在那儿了：模拟移动安装目录）。
    final String oldDir = p.join(temp.path, 'old_install');
    final Map<String, dynamic> legacy = <String, dynamic>{
      'id': kDesktopUiPluginId,
      'name': 'Tree 默认界面',
      'command': p.join(oldDir, kDesktopUiBinaryName),
      'args': <String>[],
      'env': <String, String>{'TREE_UI_DEBUG': '1'},
      'enabled': false,
      'granularity': 'team',
      'scope': <String, dynamic>{},
      'runtime': 'ui',
      'builtin': true,
    };
    expect(store.upsert(legacy).ok, isTrue);
    placeUi();
    final List<String> lines = <String>[];
    expect(
      await seedDesktopUiPlugin(
        store: store,
        executableDir: executableDir,
        isWindows: false,
        log: lines.add,
      ),
      <String>[kDesktopUiPluginId],
    );
    final Map<String, dynamic> entry = store.readEntry(kDesktopUiPluginId)!;
    expect(entry['command'], uiCommand());
    expect(entry['enabled'], isFalse, reason: '修路径不是替用户开开关');
    expect(
      (entry['env'] as Map)['TREE_UI_DEBUG'],
      '1',
      reason: '用户手加的环境变量不能被这次修正抹掉',
    );
    expect(lines.join('\n'), contains('重指'));
  });

  test('旧命令指向的界面仍在（热装到 plugins/）⇒ 不抢回随包路径', () async {
    // 现场：UI 插件经 /api/plugin/install/local 装到 plugins/tree.ui.default/，
    // 下一次核心启动若把 command 改回同目录的随包 tree_ui.exe，界面就被静默降级。
    final String installed = p.join(
      temp.path,
      'plugins',
      kDesktopUiPluginId,
      kDesktopUiBinaryName,
    );
    File(installed).parent.createSync(recursive: true);
    File(installed).writeAsStringSync('placeholder');
    final Map<String, dynamic> entry = <String, dynamic>{
      'id': kDesktopUiPluginId,
      'name': 'Tree 默认界面',
      'command': installed,
      'args': <String>[],
      'env': <String, String>{},
      'enabled': true,
      'granularity': 'team',
      'scope': <String, dynamic>{},
      'runtime': 'ui',
      'builtin': true,
    };
    expect(store.upsert(entry).ok, isTrue);
    placeUi(); // 随包那份也在，但它不是用户正在用的
    final List<String> lines = <String>[];
    expect(
      await seedDesktopUiPlugin(
        store: store,
        executableDir: executableDir,
        isWindows: false,
        log: lines.add,
      ),
      isEmpty,
      reason: '文件还在 ⇒ 不是"路径指空"，不能替用户换回随包界面',
    );
    expect(store.readEntry(kDesktopUiPluginId)!['command'], installed);
    expect(lines, isEmpty);
  });

  test('不是 builtin 的同 id 条目（用户自己写的）⇒ 一点都不动', () async {
    final Map<String, dynamic> custom = <String, dynamic>{
      'id': kDesktopUiPluginId,
      'name': '我的自定义界面',
      'command': p.join(temp.path, 'my_ui'),
      'enabled': true,
      'granularity': 'team',
      'scope': <String, dynamic>{},
      'runtime': 'ui',
    };
    expect(store.upsert(custom).ok, isTrue);
    placeUi();
    expect(
      await seedDesktopUiPlugin(
        store: store,
        executableDir: executableDir,
        isWindows: false,
      ),
      isEmpty,
    );
    expect(store.readEntry(kDesktopUiPluginId)!['command'], custom['command']);
  });
}
