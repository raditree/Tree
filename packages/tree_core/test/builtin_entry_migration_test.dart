// 内置插件的**换代迁移**（Python 脚本 → 随包二进制）：钉住"老用户开机不炸"这一件事。
//
// 背景：内置清单里 `compact`（2026-10-17）与 `sample`（同批）都从
// `python + …/xxx_plugin.py` 换成了随包二进制 `tree_<id>[.exe]`。而 `plugins.yaml` 存的是
// **解析后的** command/args（只有面板开关才会重写它），于是老用户磁盘上那些条仍指向
// 已经不在包里的 `.py`：表现是"上下文压缩 / 示例插件突然起不来"，配置看上去完全正常，
// 归因要穿过落盘配置 / 打包清单 / 发布索引三处——这是最难查的一类，所以迁移与这几条用例一起进仓。
//
// 钉住的五件事：
// 1. 清单真换了代（kind=binary + 两种平台拼写的二进制名都对，旧脚本名不再出现在任何一项上）；
// 2. 老条目被重写成新命令，而用户的 `enabled` 与 `env` **一个都不动**；
// 3. 幂等：命令已是这一代就什么都不做（每次开机都跑，不能每次都改用户的文件）；
// 4. 三种"不该动"：不是 builtin / 条目根本不存在 / 解析失败（最后一种必须留一行）；
// 5. **python 型条目绝不在启动期重写**——那会白白跑一遍解释器探测（开机多起两个进程），
//    而那条路本来就有面板开关在服务。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late Directory binDir;
  late String configFile;
  late PluginConfigStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_builtin_migration_');
    binDir = Directory(p.join(temp.path, 'plugins'))
      ..createSync(recursive: true);
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    configFile = file.path;
    store = PluginConfigStore(configFile);
  });

  tearDown(() {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        // Windows 上刚落盘的句柄可能还没释放。
        sleep(const Duration(milliseconds: 50));
      }
    }
  });

  /// 假目录：产物有 `tree_compact` 与 `tree_sample`（[withBinary] = false 模拟"还没构建产物"）。
  ///
  /// `isWindows: false` 让名字不带 `.exe`，用例在哪个平台跑都同一个字符串。
  BuiltinPluginCatalog catalog({bool withBinary = true}) {
    if (withBinary) {
      File(p.join(binDir.path, kCompactBinaryName))
          .writeAsStringSync('placeholder');
      File(p.join(binDir.path, kSampleBinaryName))
          .writeAsStringSync('placeholder');
    }
    return BuiltinPluginCatalog(
      scriptRoots: <String>[
        p.join(temp.path, withBinary ? 'plugins' : 'nowhere'),
      ],
      isWindows: false,
    );
  }

  /// 落一条"老一代"的内置条目：解释器 + 脚本绝对路径（就是换代前 `entryFor` 的产物）。
  void seedLegacy({
    String id = kCompactPluginId,
    String name = '上下文压缩',
    String command = 'python',
    List<String> args = const <String>[],
    bool builtin = true,
    bool enabled = true,
    Map<String, String> env = const <String, String>{},
  }) {
    final Map<String, dynamic> entry = <String, dynamic>{
      'id': id,
      'name': name,
      'command': command,
      'args': <String>[
        if (args.isEmpty)
          p.join(temp.path, 'old_scripts', '${id}_plugin.py'),
        ...args,
      ],
      'env': <String, String>{...env},
      'enabled': enabled,
      'granularity': 'team',
      'scope': <String, dynamic>{},
      if (builtin) 'builtin': true,
    };
    expect(store.upsert(entry).ok, isTrue, reason: '夹具写不进去就是用例自己的问题');
  }

  // ── 1 清单本身 ──────────────────────────────────────────────────────────

  /// 一条换代项的共同断言：kind=binary + 二进制名的两种平台拼写。
  ///
  /// 写成函数而不是两条复制：这一批有两个 id，而“旧名不得再在任何清单项上”这类断言
  /// 很容易只给新加的那条写。
  ///
  /// 2026-10-18：这里以前钉的是 `protectedFileNames()` 含这个二进制名，而那份“受保护名”
  /// 已从**由清单推**改成**看本机事实**（`PluginDownloader.protectedFileNames`）——插件成品
  /// 不再随包之后，按清单推会把本机根本没有的文件当保护名，那些内置 id 就永远装不上。
  /// 保护那件事的钉子搬到了 `plugin_config_api_test.dart`（它拿**真文件**当夹具）；
  /// 本文件只钉清单本身换代了没有。
  void expectSwappedToBinary(
    String id,
    String binaryName,
    String legacyScript,
  ) {
    final BuiltinPluginSpec? spec = BuiltinPluginCatalog.specOf(id);
    expect(spec, isNotNull);
    expect(spec!.kind, BuiltinPluginSpec.kindBinary, reason: id);
    expect(spec.runtime, 'binary', reason: id);
    expect(spec.script, binaryName, reason: id);
    // 平台拼写：Windows 补 `.exe`，其余平台不带——装机端与打包链都拿这个名字找文件，
    // 写错一个点就是“面板上能看见、装上去起不来”。
    expect(
      BuiltinPluginCatalog.binaryFileName(spec, isWindows: true),
      '$binaryName.exe',
      reason: id,
    );
    expect(
      BuiltinPluginCatalog.binaryFileName(spec, isWindows: false),
      binaryName,
      reason: id,
    );
    // 旧脚本名不得还出现在**任何一项**上（包括别的 id）。
    expect(
      BuiltinPluginCatalog.specs.map((BuiltinPluginSpec s) => s.script),
      isNot(contains(legacyScript)),
      reason: '$id：清单换了代，旧脚本名也跟着消失——留着就是假装那个脚本还在包里',
    );
  }

  test('内置清单：compact 已是随包二进制（不再要求用户额外装 Python）', () {
    expectSwappedToBinary(
      kCompactPluginId,
      kCompactBinaryName,
      'compact_plugin.py',
    );
  });

  test('内置清单：sample 也是随包二进制（示例插件不该要求用户装 Python）', () {
    expectSwappedToBinary(
      kSamplePluginId,
      kSampleBinaryName,
      'sample_plugin.py',
    );
    // 它仍是“默认关”的那一份：演示插件不该在用户没要求时拉起进程。
    expect(
      BuiltinPluginCatalog.specOf(kSamplePluginId)!.defaultEnabled,
      isFalse,
    );
  });

  // ── 2 迁移本体 ──────────────────────────────────────────────────────────

  test('老配置（python + …_plugin.py）在启动期换成随包二进制（compact 与 sample 同批）', () async {
    seedLegacy(enabled: false, env: const <String, String>{'TREE_DEBUG': '1'});
    seedLegacy(id: kSamplePluginId, name: '示例插件');
    final List<String> lines = <String>[];
    final List<String> moved = await migrateBuiltinEntries(
      catalog: catalog(),
      store: store,
      log: lines.add,
      isWindows: false,
    );
    expect(
      moved,
      containsAll(<String>[kCompactPluginId, kSamplePluginId]),
      reason: '同批换代的两个 id 都得被重写到：漏一个就是一句“示例插件突然起不来”',
    );
    for (final (String id, String binary) in <(String, String)>[
      (kCompactPluginId, kCompactBinaryName),
      (kSamplePluginId, kSampleBinaryName),
    ]) {
      final Map<String, dynamic> entry = store.readEntry(id)!;
      expect(entry['command'], endsWith(binary), reason: id);
      expect(
        entry['args'],
        isEmpty,
        reason: '$id：binary 型没有脚本参数；留着那条 .py 路径就是指向不存在的文件',
      );
      expect(
        entry['builtin'],
        true,
        reason: '$id：仍标 builtin，UI 才能继续把它放在「内置」分组里（删除 = 停用 + 隐藏，可恢复）',
      );
    }
    final Map<String, dynamic> compact = store.readEntry(kCompactPluginId)!;
    expect(compact['enabled'], false, reason: '迁移的是命令，不是开关：用户关过就不该被这次重写打开');
    expect(
      (compact['env'] as Map)['TREE_DEBUG'],
      '1',
      reason: '用户手加的环境变量不能被 entryFor 的空 env 抹掉',
    );
    expect(lines.join('\n'), contains(kCompactBinaryName));
    expect(lines.join('\n'), contains(kSampleBinaryName));
  });

  // ── 3 幂等 ──────────────────────────────────────────────────────────────

  test('幂等：命令已是这一代 ⇒ 什么都不做，连产物都不必再解析', () async {
    seedLegacy();
    expect(
      await migrateBuiltinEntries(
        catalog: catalog(),
        store: store,
        isWindows: false,
      ),
      contains(kCompactPluginId),
    );
    // 第二次故意换成"没有产物"的目录：如果它还要去解析，就会失败并留日志。
    final List<String> lines = <String>[];
    expect(
      await migrateBuiltinEntries(
        catalog: catalog(withBinary: false),
        store: store,
        log: lines.add,
        isWindows: false,
      ),
      isEmpty,
      reason: '每次开机都跑这一段，第二次必须原地不动（不能每次改用户的文件）',
    );
    expect(lines, isEmpty, reason: '跳过发生在解析之前：不该产出一句日志');
    expect(
      store.readEntry(kCompactPluginId)!['command'],
      endsWith(kCompactBinaryName),
    );
  });

  // ── 4 三种"不该动" ──────────────────────────────────────────────────────

  test('不是 builtin 的同 id 条目不动（那是用户自己写的东西）', () async {
    seedLegacy(builtin: false);
    final List<String> lines = <String>[];
    expect(
      await migrateBuiltinEntries(
        catalog: catalog(),
        store: store,
        log: lines.add,
        isWindows: false,
      ),
      isEmpty,
    );
    expect(store.readEntry(kCompactPluginId)!['command'], 'python');
    expect(lines, isEmpty);
  });

  test('条目根本不存在 ⇒ 什么都不做（没有的东西交给播种，不是迁移）', () async {
    final List<String> lines = <String>[];
    expect(
      await migrateBuiltinEntries(
        catalog: catalog(),
        store: store,
        log: lines.add,
        isWindows: false,
      ),
      isEmpty,
    );
    expect(store.readEntry(kCompactPluginId), isNull);
    expect(lines, isEmpty);
  });

  test('解析不到产物 ⇒ 保持现状 + 留一行（改坏比不改更糟）', () async {
    seedLegacy();
    final List<String> lines = <String>[];
    expect(
      await migrateBuiltinEntries(
        catalog: catalog(withBinary: false),
        store: store,
        log: lines.add,
        isWindows: false,
      ),
      isEmpty,
    );
    final Map<String, dynamic> entry = store.readEntry(kCompactPluginId)!;
    expect(
      entry['command'],
      'python',
      reason: '解析失败就维持原样：把一个能起的东西改成起不来的路径是最坏的结果',
    );
    expect(
      lines.join('\n'),
      contains('保持现状'),
      reason: '静默跳过在界面上就是"点了开关没反应"，必须给一行',
    );
  });

  // ── 5 python 型不进这条路 ───────────────────────────────────────────────

  test('python 型条目绝不在启动期重写（那会白白探测解释器，开机多起两个进程）', () async {
    // 2026-10-17 之后真清单里已经**没有** python 型的内置项（sample 是最后一个），
    // 所以这里注入一条合成的：这条口径是给下一代内置项防用的，不能因为
    // “现在没人走到”就把它删掉。
    seedLegacy(id: 'legacy_py', name: '合成 python 内置项');
    final List<String> lines = <String>[];
    expect(
      await migrateBuiltinEntries(
        catalog: catalog(),
        store: store,
        log: lines.add,
        isWindows: false,
        specs: <BuiltinPluginSpec>[
          const BuiltinPluginSpec(
            id: 'legacy_py',
            name: '合成 python 内置项',
            description: '只为钉住"python 型不被动"这条口径而存在',
            script: 'legacy_py_plugin.py',
            runtime: 'python',
          ),
          // 同批里再放一条真 binary：证明“跳过”是按 kind 判的，不是整批没跑。
          BuiltinPluginCatalog.specOf(kCompactPluginId)!,
        ],
      ),
      isEmpty,
      reason: 'binary 那条磁盘上没落条目（没有的东西交给播种，不是迁移）',
    );
    expect(store.readEntry('legacy_py')!['command'], 'python');
    expect(
      lines,
      isEmpty,
      reason: 'python 型连解析都不该跑：探测要真起进程（Windows 上 python / py -3 两次）',
    );
  });
}
