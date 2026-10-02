import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 插件开发指南的**解析与播种**（`plugin_guide.dart` / `builtin_spec_assets.dart`）。
///
/// 背景（为什么需要这组用例）：agent 的工作空间类工具只认工作空间相对路径
/// （`WorkspaceIO.resolve` 拒绝对路径与 `..`），而指南原件住在**核心所在机器**上
/// （发行布局的应用目录 `plugins/`、开发态的仓库 `docs/`）——不播种的话，规范正文里
/// 那句"读指南"在工作空间不是仓库时根本执行不了。这里把"找原件 → 搬进工作空间"
/// 的每条分支钉住，尤其是**失败必须如实回报**（不许静默、不许假装成功）。
void main() {
  late Directory temp;
  late Directory srcDir;
  late Directory appDir;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_guide_');
    srcDir = Directory.systemTemp.createTempSync('tree_guide_src_');
    appDir = Directory.systemTemp.createTempSync('tree_guide_app_');
  });

  tearDown(() {
    for (final Directory dir in <Directory>[temp, srcDir, appDir]) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上偶发的句柄占用：留给临时目录清理，不因此判失败。
      }
    }
  });

  /// `overrideDir` 形态：指南直接放在该目录里。
  String writeGuide(Directory dir, String content) {
    final File file = File(p.join(dir.path, kPluginGuideFileName));
    file.writeAsStringSync(content);
    return file.path;
  }

  /// 发行布局形态：`<dir>/plugins/plugin-development.md`（与 `Tree.exe` 同级）。
  String writeAppCopy(Directory dir, String content) {
    final File file = File(p.join(dir.path, 'plugins', kPluginGuideFileName));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file.path;
  }

  group('解析原件（核心所在机器上）', () {
    test('可执行文件同级的 plugins/ 优先（发行布局）', () {
      final String expected = writeAppCopy(appDir, '# 发行版指南\n');
      final String? found = resolvePluginGuideSource(
        executableDir: appDir.path,
        currentDir: temp.path, // 把 cwd 兜底换成空目录，避免它抢答
      );
      expect(found, expected);
    });

    test('开发态：可执行文件在构建产物目录里 → 向上找到仓根的 docs/', () {
      // 真实布局：Debug 产物目录离仓根有好几层，仓根判定与内置插件脚本同一套
      // （BuiltinPluginCatalog.repoRoot）。
      final String? found = resolvePluginGuideSource(
        executableDir: p.join(
          Directory.current.path,
          'build',
          'windows',
          'x64',
          'runner',
          'Debug',
        ),
        currentDir: temp.path,
      );
      expect(found, isNotNull, reason: '仓库工作空间里必须能找到 docs/plugin-development.md');
      expect(found, endsWith(p.join('docs', kPluginGuideFileName)));
      expect(File(found!).existsSync(), isTrue);
    });

    test('overrideDir 优先级最高（显式指定压过其它候选）', () {
      writeAppCopy(appDir, '# 发行版指南\n');
      final String override = writeGuide(srcDir, '# 指定的指南\n');
      final String? found = resolvePluginGuideSource(
        executableDir: appDir.path,
        overrideDir: srcDir.path,
        currentDir: temp.path,
      );
      expect(found, override);
    });

    test('到处都没有 → null（不当场编一份假指南）', () {
      final String? found = resolvePluginGuideSource(
        executableDir: appDir.path,
        currentDir: temp.path,
      );
      expect(found, isNull);
    });
  });

  group('播种进工作空间', () {
    test('created：内容与原件逐字一致（CRLF 归一成 LF），路径在 .self/docs/', () async {
      writeGuide(srcDir, '# 指南\n\n- 一行\r\n- 两行\r\n');
      final RecordingIo io = RecordingIo(temp.path);

      final PluginGuideSeed seed = await seedPluginGuide(
        io,
        overrideDir: srcDir.path,
        currentDir: temp.path,
      );

      expect(seed.action, 'created');
      expect(seed.ok, isTrue);
      expect(seed.workspacePath, kPluginGuideWorkspacePath);
      expect(seed.workspacePath, '.self/docs/plugin-development.md');
      expect(seed.bytes, greaterThan(0));
      expect(seed.sourcePath, endsWith(kPluginGuideFileName));
      // 写入走的是**传进来的 io**（工作空间那一侧），且用的是工作空间相对路径：
      // 远端（SSH）工作空间就会落到远端主机——播在本机等于没播。
      expect(io.writes, <String>[kPluginGuideWorkspacePath]);
      final String seeded = File(
        p.join(temp.path, '.self', 'docs', kPluginGuideFileName),
      ).readAsStringSync();
      expect(seeded, '# 指南\n\n- 一行\n- 两行\n');
    });

    test('unchanged：内容一致就不再写（不刷 mtime）；原件变了才 updated', () async {
      final String source = writeGuide(srcDir, '# 指南 v1\n');
      final RecordingIo io = RecordingIo(temp.path);

      final PluginGuideSeed first = await seedPluginGuide(
        io,
        overrideDir: srcDir.path,
        currentDir: temp.path,
      );
      expect(first.action, 'created');

      final PluginGuideSeed second = await seedPluginGuide(
        io,
        overrideDir: srcDir.path,
        currentDir: temp.path,
      );
      expect(second.action, 'unchanged');
      expect(io.writes, hasLength(1), reason: '内容没变就不该再写一遍');

      // 手改副本：核心维护这份副本，所以下次播种要覆盖回去（规范正文已写明别手改）
      final File copy = File(
        p.join(temp.path, '.self', 'docs', kPluginGuideFileName),
      );
      copy.writeAsStringSync('# 被手改过\n');

      final PluginGuideSeed third = await seedPluginGuide(
        io,
        overrideDir: srcDir.path,
        currentDir: temp.path,
      );
      expect(third.action, 'updated');
      expect(copy.readAsStringSync(), '# 指南 v1\n');

      // 原件更新 → 副本跟着更新（另一台机器升级核心后不会拿着旧口径干活）
      File(source).writeAsStringSync('# 指南 v2\n');
      final PluginGuideSeed fourth = await seedPluginGuide(
        io,
        overrideDir: srcDir.path,
        currentDir: temp.path,
      );
      expect(fourth.action, 'updated');
      expect(copy.readAsStringSync(), '# 指南 v2\n');
    });

    test('missing：核心那台机器上没原件 → 如实回报 + 列出找过的目录 + 不产生文件', () async {
      final List<String> logs = <String>[];
      final RecordingIo io = RecordingIo(temp.path);

      final PluginGuideSeed seed = await seedPluginGuide(
        io,
        executableDir: appDir.path,
        overrideDir: srcDir.path,
        currentDir: temp.path,
        log: logs.add,
      );

      expect(seed.action, 'missing');
      expect(seed.ok, isFalse);
      expect(seed.error, contains(kPluginGuideFileName));
      expect(seed.searched, isNotEmpty, reason: '失败要能说清"我都找过哪儿"');
      expect(seed.searched.first, p.normalize(srcDir.path));
      expect(io.writes, isEmpty, reason: '拿不到原件就不要往工作空间写东西');
      expect(
        Directory(p.join(temp.path, '.self')).existsSync(),
        isFalse,
        reason: '不该因为一次失败的播种留下空目录',
      );
      expect(logs.single, contains('未播种'));
    });

    test('failed：读到了原件但写不进去 → 如实回报 failed（不抛）', () async {
      writeGuide(srcDir, '# 指南\n');
      final PluginGuideSeed seed = await seedPluginGuide(
        _FailingWriteIo(temp.path),
        overrideDir: srcDir.path,
        currentDir: temp.path,
      );
      expect(seed.action, 'failed');
      expect(seed.ok, isFalse);
      expect(seed.error, contains('写工作空间失败'));
    });
  });

  group('随附文档接线（select 时按规范 id 播种）', () {
    test('只有 plugin-creator 有随附文档；其余内置规范不播种', () async {
      writeGuide(srcDir, '# 指南\n');
      final LocalWorkspaceIO io = LocalWorkspaceIO(temp.path);

      final List<Map<String, dynamic>> none = await seedBuiltinSpecAssets(
        io,
        <String>['general-task', 'hard-task', 'team-meeting'],
        overrideDir: srcDir.path,
        currentDir: temp.path,
      );
      expect(none, isEmpty);
      expect(
        Directory(p.join(temp.path, '.self')).existsSync(),
        isFalse,
        reason: '没有随附文档的规范不该动工作空间',
      );

      final List<Map<String, dynamic>> seeded = await seedBuiltinSpecAssets(
        io,
        <String>['general-task', kPluginCreatorSpecId],
        overrideDir: srcDir.path,
        currentDir: temp.path,
      );
      expect(seeded, hasLength(1));
      expect(seeded.single['spec_id'], 'plugin-creator');
      expect(seeded.single['action'], 'created');
      expect(seeded.single['ok'], isTrue);
      expect(seeded.single['path'], kPluginGuideWorkspacePath);
      expect(
        File(p.join(temp.path, '.self', 'docs', kPluginGuideFileName)).existsSync(),
        isTrue,
      );
    });
  });
}

/// 记账 IO：只关心"往哪写了什么"，证明播种走的是工作空间 IO（远端时就是远端主机）。
class RecordingIo extends LocalWorkspaceIO {
  RecordingIo(super.root);

  final List<String> writes = <String>[];

  @override
  Future<int> writeFile(String relativePath, String content) {
    writes.add(relativePath);
    return super.writeFile(relativePath, content);
  }
}

/// 写入必失败的 IO：验证"读到了原件但写不进去"也如实回报 `failed`。
class _FailingWriteIo extends LocalWorkspaceIO {
  _FailingWriteIo(super.root);

  @override
  Future<int> writeFile(String relativePath, String content) async {
    throw WorkspaceIoException('磁盘满了（测试构造）');
  }
}
