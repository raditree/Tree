// 插件仓（raditree/tree-plugins，装在桌面仓的 `plugins/` 下）的**源码侧合同**门禁。
//
// 为什么这份校验要在核心仓里跑：`plugins/README.md` 写的字段纪律有**两个读者**——
// 发布方（`tool/build_plugins.dart` 编译前）与装机端（`plugin_downloader.dart` 列清单时）。
// 只在其中一处校验，另一处就会漂；而漂了的现场表现是"面板列不出来"或"装上去起不来"，
// 两种都很难归因（用户看到的都是"没反应"）。这里补第三个读者：**源码自己**。
//
// 钉住四件事：
// 1. 每个插件目录的 `plugin.json` 过字段纪律（id=目录名、三段版本、值域、纯文件名、
//    `command` ∈ `files`）；
// 2. `runtime: binary` 的必须有 `<id>_plugin.dart` 入口（否则构建脚本编不出东西，
//    而它会以"跳过"的形式静默过去）；
// 3. `_kit` 与 `release` **不是插件**（没有 plugin.json ⇒ 合同里就该被跳过）；
// 4. 骨架里那张方法名表 [M] 的每个值都必须是 `PluginRpcMethods` 已登记的名字——
//    插件自带常量表是"零核心依赖"的代价，代价必须由这条用例兜住。
//    （旧 UI 表 `Ui` 随片 E 退役，不再有登记面约束。）
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

void main() {
  final Directory repoRoot = Directory('../..');
  final Directory pluginRepo = Directory('${repoRoot.path}/plugins');

  /// 插件仓是**独立 git 仓**：没检出时整组合同门禁**可见地跳过**（不再把整包
  /// 测试打成红）；`TREE_REQUIRE_PLUGIN_REPO=1` 时缺目录仍然失败（CI 已设）。
  final String? pluginRepoSkip = _pluginRepoSkipReason(pluginRepo);
  void crossRepoTest(String description, void Function() body) =>
      test(description, body, skip: pluginRepoSkip);

  List<Directory> pluginDirs() {
    expect(
      pluginRepo.existsSync(),
      isTrue,
      reason: '插件仓不存在：plugins/ —— 目录被移动时门禁必须显式失败，不能静默通过',
    );
    final List<Directory> dirs = pluginRepo
        .listSync()
        .whereType<Directory>()
        .where(
          (Directory d) =>
              !d.path.endsWith('.git') && !_base(d.path).startsWith('.'),
        )
        .toList()
      ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
    return dirs;
  }

  List<Map<String, dynamic>> manifests = <Map<String, dynamic>>[];

  setUp(() {
    manifests = <Map<String, dynamic>>[];
    for (final Directory dir in pluginDirs()) {
      final File manifest = File('${dir.path}/plugin.json');
      if (!manifest.existsSync()) continue;
      // `__dir` 是用例自己填的**目录名**（独立于 id）：否则"id 必须等于目录名"
      // 这条断言会拿被测数据自证，永远红不了。
      manifests.add(<String, dynamic>{
        ..._json(manifest.readAsStringSync()),
        '__dir': _base(dir.path),
      });
    }
  });

  crossRepoTest('插件仓至少有一个插件，且 _kit / release 都不是插件', () {
    expect(
      manifests,
      isNotEmpty,
      reason: '一个 plugin.json 都没有：要么搬家没搬完，要么这条用例的读法漂了',
    );
    for (final String notPlugin in <String>['_kit', 'release']) {
      final Directory dir = Directory('${pluginRepo.path}/$notPlugin');
      if (!dir.existsSync()) continue;
      expect(
        File('${dir.path}/plugin.json').existsSync(),
        isFalse,
        reason: '$notPlugin 被当成插件会被装机端列进清单（它其实不是）',
      );
    }
    // `_kit` 必须有骨架文件：它是五个插件共用的那一份读循环。
    expect(
      File('${pluginRepo.path}/_kit/plugin_kit.dart').existsSync(),
      isTrue,
      reason: '公共骨架缺失 ⇒ 各插件会退回各自抄一份管道（那正是这次要消掉的漂移）',
    );
  });

  crossRepoTest('tree.agent 依赖 local_executor（执行器是 agent 的必需依赖）', () {
    final Map<String, dynamic>? manifest = manifests.cast<Map<String, dynamic>?>().firstWhere(
      (Map<String, dynamic>? m) => m?['id'] == 'tree.agent',
      orElse: () => null,
    );
    expect(manifest, isNotNull, reason: '找不到 tree.agent');
    final Object? requires = manifest!['requires'];
    expect(requires, isA<Map<String, dynamic>>());
    final Object? plugins = (requires as Map<String, dynamic>)['plugins'];
    expect(plugins, isA<List<dynamic>>());
    final List<dynamic> list = plugins as List<dynamic>;
    final Map<String, dynamic>? dep = list
        .whereType<Map<String, dynamic>>()
        .cast<Map<String, dynamic>?>()
        .firstWhere((Map<String, dynamic>? d) => d?['id'] == 'local_executor', orElse: () => null);
    expect(dep, isNotNull, reason: 'tree.agent 必须声明 local_executor 依赖');
    expect(dep!['optional'], isNot(true), reason: '执行器依赖不能是 optional');
  });

  crossRepoTest('每个 plugin.json 都过字段纪律（与 plugins/README.md 的表逐条对齐）', () {
    final Set<String> seenIds = <String>{};
    final Set<String> seenCommands = <String>{};
    for (final Map<String, dynamic> manifest in manifests) {
      final String id = _str(manifest['id']);
      final String dirName = _str(manifest['__dir']);
      expect(dirName, isNotEmpty, reason: '有 plugin.json 的目录却没拿到目录名');
      expect(id, dirName, reason: 'id（$id）必须等于目录名（$dirName）');
      expect(
        RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(id) && id != '.' && id != '..',
        isTrue,
        reason: 'id「$id」字符集非法（与核心 PluginConfigStore 同一条，防路径穿越）',
      );
      expect(_str(manifest['name']), isNotEmpty, reason: '$id 缺 name');
      expect(
        RegExp(r'^\d+\.\d+\.\d+$').hasMatch(_str(manifest['version'])),
        isTrue,
        reason: '$id 的 version（${_str(manifest['version'])}）必须是三段数字',
      );
      final String runtime = _str(manifest['runtime'], fallback: 'binary');
      // 片 D：唯一分类维度是「有无界面」，与语言 / 执行形态无关。
      // binary / python 是历史清单值（核心归一化为 headless + 「清单待升级」）。
      expect(
        <String>['headless', 'ui', 'binary', 'python'],
        contains(runtime),
        reason: '$id 的 runtime（$runtime）只能是 headless / ui（历史值 binary / python 仍接受）',
      );
      final List<dynamic> files = manifest['files'] is List
          ? manifest['files'] as List<dynamic>
          : <dynamic>[];
      expect(files, isNotEmpty, reason: '$id 的 files 至少要有一个');
      // UI 插件是整包 zip（含 data/ 与 dll），源清单用 `["**"]` 表达"整个目录"。
      // 装机端走 `archive` 形态，不按 files[] 逐项列表，所以这里放行这一种写法。
      final bool wholeArchive = files.length == 1 && _str(files.first) == '**';
      if (wholeArchive) {
        expect(
          runtime,
          'ui',
          reason: '$id 用了 files:["**"]，但 runtime 不是 ui（只有 UI 走整包 archive）',
        );
      } else {
        for (final Object? entry in files) {
          final String name = _str(entry);
          expect(
            name.contains('/') || name.contains(r'\') || name.contains('..'),
            isFalse,
            reason: '$id 的 files 里「$name」必须是纯文件名（防路径穿越）',
          );
        }
      }
      final String command = _str(manifest['command']);
      expect(command, isNotEmpty, reason: '$id 缺 command（装完不知道拉哪个）');
      if (!wholeArchive) {
        expect(
          files.map((Object? e) => _str(e)),
          contains(command),
          reason: '$id 的 command（$command）必须出现在 files 里',
        );
      }
      final String suspension = _str(manifest['suspension']);
      expect(
        suspension.isEmpty || suspension == 'keep',
        isTrue,
        reason: '$id 的 suspension（$suspension）值域只有空与 keep',
      );
      expect(
        <String>['team', 'agent', 'session'],
        contains(_str(manifest['granularity'], fallback: 'team')),
        reason: '$id 的 granularity 非法',
      );
      expect(
        seenIds.add(id),
        isTrue,
        reason: '插件 id 重复：$id（装机端会按 id 定位目录，重复就是互相覆盖）',
      );
      expect(
        seenCommands.add(command),
        isTrue,
        reason: 'command 文件名重复：$command（同一个 plugins/ 目录里撞名）',
      );
    }
  });

  crossRepoTest('Dart 形态的插件都有入口（构建脚本按约定找它）', () {
    final List<String> missing = <String>[];
    for (final Map<String, dynamic> manifest in manifests) {
      final String id = _str(manifest['id']);
      final String runtime = _str(manifest['runtime'], fallback: 'binary');
      // UI 插件是 Flutter 工程：没有 `<id>_plugin.dart`，由 package_ui_plugin 构建
      // （`dart compile exe` 编不了 Flutter），`build_plugins.dart` 显式跳过它。
      if (runtime == 'ui') continue;
      // headless / 历史 binary 都要编成可执行体；python 是脚本，不在此列。
      if (runtime == 'python') continue;
      final File entry = File('${pluginRepo.path}/$id/${id}_plugin.dart');
      if (!entry.existsSync()) missing.add('$id → ${entry.path}');
    }
    expect(
      missing,
      isEmpty,
      reason: '这些插件缺入口源，编译会被静默跳过：\n${missing.join('\n')}',
    );
  });

  crossRepoTest('声明了 app_version_define 的插件，那个键名必须真出现在它的源码里', () {
    // 钉的是“注到了东西”而不是“注对了”：键名写错（多一个字母、拿成另一个插件的键）
    // 会静默地注不上，而插件拿着 `defaultValue` 自报一个假版本——目标机驻留目录按
    // 版本命名 ⇒ 每次装都当新版重推，面板上那一行版本号也是假的。
    // “注对了”由**产物自检**核（`ssh_executor --selftest` 第 7 条：版本不等于兜底值），
    // 因为那个兜底值住在 `tree_tunnel_protocol` 里，本用例隔着一个仓去推它不诚实。
    final List<String> dangling = <String>[];
    for (final Map<String, dynamic> manifest in manifests) {
      final String id = _str(manifest['id']);
      final String define = _str(manifest['app_version_define']);
      if (define.isEmpty) continue;
      final Directory dir = Directory('${pluginRepo.path}/$id');
      final List<String> hits = <String>[];
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // `.dart_tool/` 是 pub 生成的缓存（含依赖自己的源码），不算这条插件的源码。
        if (entity.path.contains(r'.dart_tool')) continue;
        if (entity.readAsStringSync().contains(define)) hits.add(entity.path);
      }
      if (hits.isEmpty) dangling.add('$id → 键名 $define 在这条插件的源码里找不到');
    }
    expect(
      dangling,
      isEmpty,
      reason: '这些 app_version_define 注不到任何东西：\n${dangling.join('\n')}',
    );
  });

  crossRepoTest('骨架那张方法名表逐个已登记（插件自带常量表不能漂）', () {
    final File kit = File('${pluginRepo.path}/_kit/plugin_kit.dart');
    expect(kit.existsSync(), isTrue);
    final String src = kit.readAsStringSync();
    // 只取 M 这一段（Cmd 里的 `plugin.stateDump` / `plugin.stateFetch` 是**执行站命令名**，
    // 不是 method，归 station/command 那条白名单管）。
    final int start = src.indexOf('abstract final class M {');
    final int end = src.indexOf('abstract final class Cmd');
    expect(start, greaterThan(-1), reason: '骨架里找不到方法名表 M');
    expect(end, greaterThan(start), reason: '找不到 Cmd 表的边界（M 段取不完）');
    final Iterable<RegExpMatch> matches = RegExp(
      r"static const String \w+ = '([^']+)';",
    ).allMatches(src.substring(start, end));
    expect(matches, isNotEmpty, reason: '方法名表是空的：读法漂了');
    final List<String> uncovered = matches
        .map((RegExpMatch m) => m.group(1)!)
        .where(
          (String name) => !PluginRpcMethods.all.contains(name),
        )
        .toList();
    expect(
      uncovered,
      isEmpty,
      reason:
          '骨架里这些方法名既不在 PluginRpcMethods：$uncovered —— '
          '插件侧要用的名字必须先在家里登记，否则门禁的方向断言就会失真',
    );
    // 反向也要成立：核心登记的每个方法名都得是协议名（不是路径 / 命令）。
    expect(
      PluginRpcMethods.all,
      containsAll(<String>['hello', 'ping', 'tools/list', 'station/command']),
    );
  });

  crossRepoTest('插件源码不得 import 核心包（插件仓可独立编译）', () {
    // 为什么钉死：插件仓可能被第三方单独 clone；一旦出现
    // `package:tree_core/` / `package:tree_protocol/`，那边直接编不出来。
    // 复用核心能力只能走「平台内置站（日志/存储/租约）」或「其它插件的自建执行站」。
    // 只认 import 语句：注释里提到这两个包名是允许的（迁移说明需要写它们）。
    final RegExp forbidden = RegExp(
      r'''import\s+['"]package:(tree_core|tree_protocol)/''',
    );
    final List<String> offenders = <String>[];
    for (final Directory dir in pluginDirs()) {
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.contains('${Platform.pathSeparator}.dart_tool'
            '${Platform.pathSeparator}')) {
          continue;
        }
        if (!forbidden.hasMatch(entity.readAsStringSync())) continue;
        offenders.add(
          entity.path.substring(pluginRepo.parent.path.length + 1).replaceAll(
            r'\',
            '/',
          ),
        );
      }
    }
    expect(
      offenders..sort(),
      isEmpty,
      reason:
          '这些插件源码 import 了核心包，单独 clone 插件仓会编不出来：\n'
          '${offenders.join('\n')}',
    );
  });
}

/// 跨仓合同门禁前置：插件仓不在时给出**可见 skip 原因**，而不是把整包测试打红
/// （远端/本地单仓环境本来就可能没有插件仓）；`TREE_REQUIRE_PLUGIN_REPO=1` 时
/// 缺目录仍然失败，保证"有仓就必须真扫"。
String? _pluginRepoSkipReason(Directory pluginRepo) {
  if (pluginRepo.existsSync()) return null;
  if (Platform.environment['TREE_REQUIRE_PLUGIN_REPO'] == '1') {
    fail('插件仓不存在：plugins/ —— TREE_REQUIRE_PLUGIN_REPO=1 要求必须扫描插件仓');
  }
  return '未检出插件仓（plugins/，独立仓 raditree/tree-plugins）：跨仓合同门禁跳过；'
      '设 TREE_REQUIRE_PLUGIN_REPO=1 可强制要求';
}

String _base(String path) {
  final String normalized = path.replaceAll(r'\', '/');
  final int slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

Map<String, dynamic> _json(String text) => (json.decode(text) as Map).map(
  (Object? key, Object? value) => MapEntry<String, dynamic>(key.toString(), value),
);

String _str(Object? value, {String fallback = ''}) {
  final String text = (value ?? '').toString().trim();
  return text.isEmpty ? fallback : text;
}
