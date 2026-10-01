import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 内置插件脚本查找的**开发态回退必须锚定仓根**。
///
/// 为什么单独锁这一条：桌面壳是以**自己所在目录**为工作目录拉起核心的，所以跑
/// Debug 构建时 cwd 是 `build/windows/x64/runner/Debug`——该目录下没有 plugins/，
/// Debug 产物也不复制 plugins/。旧实现把"开发态回退"写成相对 cwd 的两条路径，
/// 结果一个都命中不了，内置示例插件在面板上变成「找不到内置插件脚本」。
///
/// 正确行为：从可执行文件向上找到含 `packages/tree_core` 的目录（仓根），
/// 再查它的 `examples/plugins/`——与 cwd 无关。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_repo_root_');
  });

  tearDown(() {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        // Windows 上句柄可能还没释放，稍后重试
      }
    }
  });

  /// 造一个"像仓库"的目录树：`<root>/packages/tree_core` 是标记。
  String makeRepo(String root) {
    Directory(p.join(root, 'packages', 'tree_core')).createSync(recursive: true);
    Directory(p.join(root, 'examples', 'plugins')).createSync(recursive: true);
    return root;
  }

  test('repoRoot：从构建产物目录向上找到仓根（Debug 产物的真实布局）', () {
    final String root = makeRepo(p.join(temp.path, 'repo'));
    // 核心跑在 build/windows/x64/runner/Debug 下
    final String exeDir = p.join(
      root,
      'build',
      'windows',
      'x64',
      'runner',
      'Debug',
    );
    Directory(exeDir).createSync(recursive: true);

    expect(BuiltinPluginCatalog.repoRoot(exeDir), p.normalize(root));
  });

  test('repoRoot：找不到标记（发行包）返回 null，不瞎猜', () {
    final String outside = p.join(temp.path, 'installed', 'bin');
    Directory(outside).createSync(recursive: true);
    expect(BuiltinPluginCatalog.repoRoot(outside), isNull);
  });

  test('scriptRoots：默认回退含**仓根**的 examples/plugins（与 cwd 无关）', () {
    final String root = makeRepo(p.join(temp.path, 'repo'));
    final String exeDir = p.join(root, 'build', 'windows', 'x64', 'runner', 'Debug');
    Directory(exeDir).createSync(recursive: true);
    // 脚本真的放在仓根下（不是 exe 同级、也不是 cwd）
    final String scriptPath = p.join(
      root,
      'examples',
      'plugins',
      'sample_plugin.py',
    );
    File(scriptPath).writeAsStringSync('# demo\n');

    final BuiltinPluginCatalog catalog = BuiltinPluginCatalog(
      executableDir: exeDir,
      probe: (String command, List<String> args) async => true,
      isWindows: true,
    );

    // 目录清单里必须有"仓根 examples/plugins"这一条，且它排在 cwd 回退之前
    final List<String> roots = catalog.scriptRoots();
    final String expectedRoot = p.normalize(p.join(root, 'examples', 'plugins'));
    expect(roots, contains(expectedRoot));
    expect(
      roots.indexOf(expectedRoot) < roots.length - 2,
      isTrue,
      reason: '仓根回退应优先于 cwd 兜底：$roots',
    );

    // 端到端：真解析一次，脚本路径必须是仓根下那个（这就是面板上不再报
    // 「找不到内置插件脚本」的判据）
    final BuiltinPluginSpec spec = BuiltinPluginCatalog.specOf('sample')!;
    return catalog.resolve(spec).then((BuiltinResolution resolution) {
      expect(resolution.ok, isTrue, reason: resolution.error);
      expect(
        p.normalize(resolution.scriptPath),
        p.normalize(scriptPath),
        reason: '命中的必须是仓根下的脚本，而不是靠 cwd 撞上的',
      );
      expect(resolution.command, 'python');
    });
  });

  test('scriptRoots：exe 同级 plugins/ 仍然优先（发行包布局不被破坏）', () {
    final String root = makeRepo(p.join(temp.path, 'repo'));
    final String exeDir = p.join(root, 'build', 'windows', 'x64', 'runner', 'Release');
    // 发行包布局：可执行文件同级就有 plugins/
    Directory(p.join(exeDir, 'plugins')).createSync(recursive: true);
    File(
      p.join(exeDir, 'plugins', 'sample_plugin.py'),
    ).writeAsStringSync('# packaged\n');

    final BuiltinPluginCatalog catalog = BuiltinPluginCatalog(
      executableDir: exeDir,
      probe: (String command, List<String> args) async => true,
      isWindows: true,
    );

    expect(
      catalog.scriptRoots().first,
      p.normalize(p.join(exeDir, 'plugins')),
      reason: '发行包位置必须是第一优先',
    );
    return catalog
        .resolve(BuiltinPluginCatalog.specOf('sample')!)
        .then((BuiltinResolution resolution) {
          expect(
            p.normalize(resolution.scriptPath),
            p.normalize(p.join(exeDir, 'plugins', 'sample_plugin.py')),
            reason: '同级有就用同级的（发行包自带的版本优先于仓内开发版）',
          );
        });
  });
}
