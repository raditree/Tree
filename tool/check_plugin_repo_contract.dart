// 插件仓独立 CI 门禁（L-21）：插件源码不得 import 核心包。
//
// 背景：tree-plugins 可能被第三方单独 clone（没有桌面仓、没有 tree_core /
// tree_protocol 的 package 解析），一旦插件源码出现
// `package:tree_core/...` 或 `package:tree_protocol/...`，那边直接编不出来。
// 桌面仓的 `packages/tree_protocol/test/plugin_repo_contract_test.dart` 已经钉了
// 同一条规则，但它本身依赖 tree_protocol，没法在插件仓独立跑；这里补一条
// **零三方依赖、单文件**的等价门禁。
//
// 用法（两种仓都能跑）：
//   # 桌面仓根
//   dart run tool/check_plugin_repo_contract.dart
//   # 插件仓根（tree-plugins checkout；脚本可复制进 CI 镜像或用绝对路径调）
//   cd plugins && dart run <path-to>/tool/check_plugin_repo_contract.dart --plugin-root .
//
// 退出码：0 = 全绿；1 = 发现违规；2 = 参数 / 环境错误。
//
// 只扫 Dart 的 import/export 指令与 pubspec.yaml 的依赖键：
// 注释里提到这两个包名是允许的（迁移说明需要写它们），不误报。

import 'dart:io';

/// 规则：Dart import / export 不得指向核心包。
final RegExp _forbiddenImport = RegExp(
  r'''(?:^|\s)(?:import|export)\s+['"]package:(?:tree_core|tree_protocol)/''',
);

/// 规则：pubspec 的依赖键不得直接叫 tree_core / tree_protocol。
final RegExp _forbiddenDependency = RegExp(
  r'^\s*(?:tree_core|tree_protocol)\s*:',
);

/// 生成物目录不扫：里面是 pub 缓存的依赖源码，不是本仓插件源码。
const Set<String> _skipDirNames = <String>{
  '.git',
  '.dart_tool',
  'build',
};

final List<String> _scannedDart = <String>[];
final List<String> _scannedPubspec = <String>[];

void main(List<String> args) {
  String? pluginRoot;
  bool selftest = false;
  for (int i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (arg == '--selftest') {
      selftest = true;
    } else if (arg == '--plugin-root') {
      if (i + 1 >= args.length) {
        stderr.writeln('[FAIL] --plugin-root 缺少路径参数');
        exit(2);
      }
      pluginRoot = args[++i];
    } else if (arg == '--help' || arg == '-h') {
      stdout.writeln('用法：dart run tool/check_plugin_repo_contract.dart '
          '[--plugin-root <插件仓根>] [--selftest]');
      return;
    } else {
      stderr.writeln('[FAIL] 未知参数：$arg');
      exit(2);
    }
  }

  if (selftest) {
    exit(_selfTest());
  }

  final Directory root;
  if (pluginRoot != null) {
    root = Directory(pluginRoot);
    if (!root.existsSync()) {
      stderr.writeln('[FAIL] 插件仓根不存在：${root.path}');
      exit(2);
    }
  } else {
    root = _defaultRoot();
  }

  stdout.writeln('[check-plugin-contract] 插件仓根：${root.absolute.path}');
  final int pluginCount = _pluginCount(root);
  if (pluginCount == 0) {
    stderr.writeln('[FAIL] 没找到任何 plugin.json —— 目录不对时门禁必须显式失败，'
        '不能静默通过');
    exit(1);
  }

  final List<String> offenders = _scan(root);
  stdout.writeln('[check-plugin-contract] 插件 $pluginCount 个；'
      '扫描 Dart 文件 ${_scannedDart.length} 个、pubspec.yaml '
      '${_scannedPubspec.length} 个');
  if (offenders.isEmpty) {
    stdout.writeln('[OK] 未发现核心包 import / 依赖：插件仓可独立编译');
    return;
  }
  for (final String offender in offenders) {
    stdout.writeln('[FAIL] $offender');
  }
  stdout.writeln('[FAIL] 共 ${offenders.length} 处违规：插件必须能脱离桌面仓单独编译 '
      '（L-21 / 不变量 13）');
  exit(1);
}

/// 默认根：桌面仓根的 `plugins/`；否则当前目录（插件仓根）。
Directory _defaultRoot() {
  final Directory cwd = Directory.current;
  final Directory nested =
      Directory('${cwd.path}${Platform.pathSeparator}plugins');
  if (nested.existsSync() && _pluginCount(nested) > 0) return nested;
  return cwd;
}

/// 有 plugin.json 的直属子目录数（`_kit` / `release` 命中 0，因为它们没有清单）。
int _pluginCount(Directory root) {
  int count = 0;
  for (final FileSystemEntity entity in root.listSync(followLinks: false)) {
    if (entity is! Directory) continue;
    final String name = _baseName(entity.path);
    if (name.startsWith('.') || name == 'release') continue;
    if (File('${entity.path}${Platform.pathSeparator}plugin.json')
        .existsSync()) {
      count++;
    }
  }
  return count;
}

/// 扫全仓插件源码；返回可读违规清单（空 = 全绿）。
List<String> _scan(Directory root) {
  _scannedDart.clear();
  _scannedPubspec.clear();
  final List<String> offenders = <String>[];
  for (final FileSystemEntity entity in root.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    final String path = entity.path;
    if (_hasSkippedDir(path)) continue;
    if (path.endsWith('.dart')) {
      _scannedDart.add(path);
      final List<String> lines = entity.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (_forbiddenImport.hasMatch(lines[i])) {
          offenders.add('${_relative(root, path)}:${i + 1}: '
              '${lines[i].trim()}');
        }
      }
    } else if (_baseName(path) == 'pubspec.yaml') {
      _scannedPubspec.add(path);
      final List<String> lines = entity.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (_forbiddenDependency.hasMatch(lines[i])) {
          offenders.add('${_relative(root, path)}:${i + 1}: '
              '${lines[i].trim()}（依赖核心包）');
        }
      }
    }
  }
  offenders.sort();
  return offenders;
}

bool _hasSkippedDir(String path) {
  final String normalized = path.replaceAll(r'\', '/');
  for (final String dir in _skipDirNames) {
    if (normalized.contains('/$dir/')) return true;
  }
  return false;
}

String _baseName(String path) {
  final String normalized = path.replaceAll(r'\', '/');
  final int slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

String _relative(Directory root, String path) {
  final String normalizedRoot = root.absolute.path.replaceAll(r'\', '/');
  final String normalizedPath = path.replaceAll(r'\', '/');
  if (normalizedPath.startsWith('$normalizedRoot/')) {
    return normalizedPath.substring(normalizedRoot.length + 1);
  }
  return normalizedPath;
}

/// 门禁自己的小自检：证明"有违规会红、没有会绿"，避免脚本坏掉后静默放行。
int _selfTest() {
  final Directory temp = Directory.systemTemp.createTempSync(
    'plugin_contract_selftest_',
  );
  int failures = 0;
  void check(bool ok, String what) {
    stdout.writeln('${ok ? '[OK]' : '[FAIL]'} $what');
    if (!ok) failures++;
  }

  try {
    final Directory clean = Directory('${temp.path}${Platform.pathSeparator}clean')
      ..createSync();
    File('${clean.path}${Platform.pathSeparator}plugin.json')
        .writeAsStringSync('{"id":"clean","version":"1.0.0"}');
    Directory('${clean.path}${Platform.pathSeparator}lib').createSync();
    File('${clean.path}${Platform.pathSeparator}lib${Platform.pathSeparator}'
            'clean_plugin.dart')
        .writeAsStringSync("import 'package:yaml/yaml.dart';\n");
    check(_scan(temp).isEmpty, '干净插件：不误报');

    final Directory bad = Directory('${temp.path}${Platform.pathSeparator}bad')
      ..createSync();
    File('${bad.path}${Platform.pathSeparator}plugin.json')
        .writeAsStringSync('{"id":"bad","version":"1.0.0"}');
    Directory('${bad.path}${Platform.pathSeparator}lib').createSync();
    final File badFile = File(
      '${bad.path}${Platform.pathSeparator}lib${Platform.pathSeparator}'
      'bad_plugin.dart',
    )..writeAsStringSync(
        "// 注释里写 package:tree_core 不算违规\n"
        "import 'package:tree_core/tree_core.dart';\n",
      );
    final List<String> hit = _scan(temp);
    check(hit.length == 1 && hit.single.contains('package:tree_core'),
        '注入 package:tree_core 会变红');
    check(hit.isNotEmpty && hit.single.contains('bad_plugin.dart:2'),
        '违规位置指出文件:行号');

    badFile.writeAsStringSync("import 'package:tree_protocol/x.dart';\n");
    final List<String> hit2 = _scan(temp);
    check(hit2.length == 1 && hit2.single.contains('package:tree_protocol'),
        '注入 package:tree_protocol 也会变红');

    badFile.deleteSync();
    check(_scan(temp).isEmpty, '删掉违规后恢复全绿');
  } finally {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  }

  stdout.writeln('[check-plugin-contract] --selftest：'
      '${failures == 0 ? '全部通过' : '有 $failures 项失败'}');
  return failures == 0 ? 0 : 1;
}
