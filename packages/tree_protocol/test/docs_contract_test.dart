import 'dart:io';

import 'package:test/test.dart';

/// **文档契约门禁**（仓库级；放在协议包里因为它是"门禁"的家）。
///
/// 规则来自 [CONTRIBUTING §4](../../../CONTRIBUTING.md)：文档制度不能靠自觉——
/// 模块 README 必须在、必须写清**不变量（assertions）**，docs 索引必须列全所有文档。
/// 谁删了 README / 删掉不变量小节 / 加了文档没进索引，这里就红。
void main() {
  // `dart test` 的工作目录是包根（packages/tree_protocol）⇒ 上两级是仓库根。
  // 只做字符串拼接（Dart 的 IO 在 Windows 上同样接受 '/'），免得为一个门禁给本包加依赖。
  final String repo = Directory.current.parent.parent.path;

  test('入口与开发者文档齐全', () {
    const List<String> required = <String>[
      'README.md',
      'CONTRIBUTING.md',
      'CHANGELOG.md',
      'LICENSE',
      'docs/README.md',
      'docs/architecture.md',
      'docs/development.md',
      'docs/team.md',
      'docs/plugin-development.md',
      'docs/known-issues.md',
    ];
    for (final String rel in required) {
      expect(File('$repo/$rel').existsSync(), isTrue, reason: '缺文档：$rel');
    }
  });

  test('每个模块 README 都有「不变量（assertions）」与「测试」两节', () {
    const List<String> modules = <String>[
      'packages/tree_protocol/README.md',
      'packages/tree_local_exec/README.md',
      'packages/tree_core/README.md',
      'packages/tree_core_cli/README.md',
      'lib/README.md',
    ];
    for (final String rel in modules) {
      final File file = File('$repo/$rel');
      expect(file.existsSync(), isTrue, reason: '缺模块 README：$rel');
      final String text = file.readAsStringSync();
      expect(
        text,
        contains('不变量（assertions）'),
        reason: '$rel 必须写清这个模块的不变量（CONTRIBUTING §4）',
      );
      expect(
        text,
        contains('## 测试'),
        reason: '$rel 必须给出怎么跑该模块的测试',
      );
    }
  });

  /// 某个目录下的文件是否都被"索引文件"提到过（索引必须诚实）。
  void expectIndexed(String dirRelPath, String indexRelPath, {bool skipIndex = true}) {
    final Directory dir = Directory('$repo/$dirRelPath');
    expect(dir.existsSync(), isTrue, reason: '目录不存在：$dirRelPath');
    final String index = File('$repo/$indexRelPath').readAsStringSync();
    final List<String> files = dir
        .listSync()
        .whereType<File>()
        .map((File f) => f.uri.pathSegments.last)
        .where((String name) => !(skipIndex && name == 'README.md'))
        .toList(growable: false);
    expect(files, isNotEmpty, reason: '$dirRelPath 下应当有文档');
    for (final String name in files) {
      expect(
        index.contains(name),
        isTrue,
        reason: '$indexRelPath 没列出 $name（新增/移动文档要同步索引）',
      );
    }
  }

  test('docs 索引列全 docs/ 下的文档', () {
    expectIndexed('docs', 'docs/README.md');
  });

  test('归档索引列全 docs/archive/ 下的文档', () {
    expectIndexed('docs/archive', 'docs/archive/README.md');
  });

  test('tree_core 的每个业务模块都有自己的 README（不变量 + 测试 + 进模块地图）', () {
    const String srcRel = 'packages/tree_core/lib/src';
    final Directory src = Directory('$repo/$srcRel');
    expect(src.existsSync(), isTrue, reason: '缺目录：$srcRel');
    final String index = File('$repo/packages/tree_core/README.md').readAsStringSync();
    final List<String> modules = src
        .listSync()
        .whereType<Directory>()
        .map((Directory d) => d.path.replaceAll('\\', '/').split('/').last)
        .toList(growable: false)
      ..sort();
    expect(modules, isNotEmpty, reason: '$srcRel 下应当有业务模块目录');
    for (final String name in modules) {
      final String rel = '$srcRel/$name/README.md';
      final File file = File('$repo/$rel');
      expect(file.existsSync(), isTrue, reason: '缺模块 README：$rel');
      final String text = file.readAsStringSync();
      expect(
        text,
        contains('不变量（assertions）'),
        reason: '$rel 必须写清这个模块的不变量（CONTRIBUTING §4）',
      );
      expect(text, contains('## 测试'), reason: '$rel 必须给出怎么跑该模块的测试');
      expect(
        index.contains('lib/src/$name/'),
        isTrue,
        reason: 'packages/tree_core/README.md 的模块地图没列出 lib/src/$name/（新增模块要同步索引）',
      );
    }
  });

  test('提示词资产索引在，且点名真实符号（改提示词要能一眼定位）', () {
    const String rel = 'docs/architecture.md';
    final String text = File('$repo/$rel').readAsStringSync();
    const List<String> required = <String>[
      'defaultSystemPromptSeed',
      'systemPromptWithWorkspace',
      'kBuiltinSpecs',
      'builtin_spec_assets.dart',
      'status_text.dart',
      'llm_summarizer.dart',
    ];
    for (final String symbol in required) {
      expect(
        text,
        contains(symbol),
        reason: '$rel 的「提示词资产」表必须点名 $symbol——改提示词要能一眼定位到文件（CONTRIBUTING §3）',
      );
    }
  });

  test('文档集合里的相对链接都能解析到真实的文件或目录', () {
    final List<String> docs = docSet();
    expect(docs.length, greaterThan(10), reason: '文档集合不应当为空（检查扫描逻辑）');
    for (final String rel in docs) {
      final String base = rel.contains('/') ? rel.substring(0, rel.lastIndexOf('/')) : '';
      bool inFence = false;
      for (final String line in File('$repo/$rel').readAsLinesSync()) {
        // 代码块里的 `](…)` 是示例，不是链接。
        if (line.trimLeft().startsWith('```')) {
          inFence = !inFence;
          continue;
        }
        if (inFence) continue;
        for (final RegExpMatch match in mdLink.allMatches(line)) {
          String target = match.group(1)!;
          if (target.startsWith('<') ||
              target.startsWith('#') ||
              target.startsWith('mailto:') ||
              target.contains('://')) {
            continue;
          }
          final int hash = target.indexOf('#');
          if (hash >= 0) target = target.substring(0, hash);
          if (target.isEmpty) continue;
          String decoded = target;
          try {
            decoded = Uri.decodeComponent(target);
          } on FormatException {
            // 路径里有裸 % —— 原样拿去解析，失败自然会被下面报出来。
          }
          final String resolved = resolveRelative(base, decoded);
          expect(
            File('$repo/$resolved').existsSync() || Directory('$repo/$resolved').existsSync(),
            isTrue,
            reason: '$rel 里的链接指向不存在的路径：$target',
          );
        }
      }
    }
  });
}

/// Markdown 行内链接 `](target)` 的目标部分。
final RegExp mdLink = RegExp(r'\]\(([^)\s]+)\)');

/// **文档集合**：仓库根入口文档 + `docs/` 全部 + `lib` / `packages` / `examples` 下的 README。
///
/// 刻意不扫 `.trae/`、`.self/`、`spec/`：那些是历史工具产物与 agent 的私有工作区，
/// 不参与仓库文档契约（它们的链接指向早已删除的服务端代码）。
List<String> docSet() {
  final String repo = Directory.current.parent.parent.path;
  final List<String> out = <String>['README.md', 'CONTRIBUTING.md', 'CHANGELOG.md'];
  for (final String root in <String>['docs', 'lib', 'packages', 'examples']) {
    final Directory dir = Directory('$repo/$root');
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final String path = entity.path.replaceAll('\\', '/');
      final int at = path.indexOf('/$root/');
      if (at < 0) continue;
      final String rel = path.substring(at + 1);
      final bool isReadme = rel.endsWith('/README.md') || rel == 'README.md';
      if (root == 'docs' || isReadme) out.add(rel);
    }
  }
  return out;
}

/// 把 [target] 按 [base]（仓库相对目录，可为空）解析成仓库相对路径（纯字符串，不依赖 path 包）。
String resolveRelative(String base, String target) {
  final List<String> parts = <String>[
    if (base.isNotEmpty) ...base.split('/'),
    ...target.split('/'),
  ];
  final List<String> out = <String>[];
  for (final String part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(part);
  }
  return out.join('/');
}
