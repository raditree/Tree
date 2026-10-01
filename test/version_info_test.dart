// 版本信息与插件开发入口（设置页）的测试。
//
// 两件容易被"看起来对"骗过去的事，这里都钉住：
// 1. `kAppVersion` 是**手写常量**（运行时读不到 pubspec），所以必须有一条测试直接
//    读 pubspec.yaml 比对——漂移要让测试红，而不是让用户看到一个假版本号；
// 2. 插件文档路径是**多候选探测**（发行版 plugins/ 与仓库 examples/plugins/ 两种
//    布局），顺序与回退都要可验证，否则用户点了"打开说明"只会看到没反应。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/app_version.dart';
import 'package:tree/ui/pages/settings_page.dart';

/// 造一个假的可执行文件路径（不需要真有文件，只用来定位"应用目录"）。
String fakeExeIn(Directory dir) => p.join(dir.path, 'Tree.exe');

void main() {
  group('版本常量与 pubspec 不漂移', () {
    test('kAppVersion / kAppBuildNumber 与 pubspec.yaml 的 version 一致', () {
      final File pubspec = File(p.join(Directory.current.path, 'pubspec.yaml'));
      expect(pubspec.existsSync(), isTrue, reason: '测试要在仓库根运行');
      final String? line = pubspec
          .readAsLinesSync()
          .cast<String?>()
          .firstWhere(
            (String? l) => l != null && l.trimLeft().startsWith('version:'),
            orElse: () => null,
          );
      expect(line, isNotNull, reason: 'pubspec.yaml 必须有 version: 行');
      final String raw = line!.split(':')[1].trim();
      final List<String> parts = raw.split('+');
      expect(
        parts.first,
        kAppVersion,
        reason: 'pubspec 的 version 变了就要同步 lib/app_version.dart 的常量',
      );
      expect(
        parts.length > 1 ? parts[1] : '0',
        kAppBuildNumber,
        reason: '构建号同样要同步',
      );
    });
  });

  group('PluginDocs：插件开发说明的定位', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tree_docs_');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    String writeReadme(String dir) {
      final Directory d = Directory(dir)..createSync(recursive: true);
      final File f = File(p.join(d.path, PluginDocs.readmeName));
      f.writeAsStringSync('# 插件开发\n');
      return f.path;
    }

    test('发行版布局：应用目录下的 plugins/README.md 被找到', () {
      final String expected = writeReadme(
        p.join(temp.path, PluginDocs.bundledDirName),
      );
      expect(
        PluginDocs.resolvePath(executablePath: fakeExeIn(temp)),
        expected,
      );
    });

    test('源码布局：从产物目录向上找到 examples/plugins/README.md', () {
      // 模拟 build/windows/x64/runner/Debug/Tree.exe 这种深层产物目录
      final Directory deep = Directory(
        p.join(temp.path, 'build', 'windows', 'x64', 'runner', 'Debug'),
      )..createSync(recursive: true);
      final String expected = writeReadme(
        p.join(temp.path, p.joinAll(PluginDocs.repoDirName.split('/'))),
      );
      expect(
        PluginDocs.resolvePath(executablePath: fakeExeIn(deep)),
        expected,
      );
    });

    test('两种布局都在时**优先发行目录**（离可执行文件最近的那份）', () {
      final String bundled = writeReadme(
        p.join(temp.path, PluginDocs.bundledDirName),
      );
      writeReadme(
        p.join(temp.path, p.joinAll(PluginDocs.repoDirName.split('/'))),
      );
      expect(
        PluginDocs.resolvePath(executablePath: fakeExeIn(temp)),
        bundled,
        reason: '发行包与仓库同时在时，用户要看的是随包发出去的那份文档',
      );
    });

    test('overrideDir 优先级最高（给将来的"自定义文档路径"留口）', () {
      writeReadme(p.join(temp.path, PluginDocs.bundledDirName));
      final String override = writeReadme(p.join(temp.path, 'my_docs'));
      expect(
        PluginDocs.resolvePath(
          overrideDir: p.join(temp.path, 'my_docs'),
          executablePath: fakeExeIn(temp),
        ),
        override,
      );
    });

    test('都找不到 ⇒ resolvePath 返回 null（调用方给可读提示，不静默）', () {
      expect(
        PluginDocs.resolvePath(executablePath: fakeExeIn(temp)),
        isNull,
      );
    });

    test('candidatePaths 覆盖指南与简版两个文件名且不重复', () {
      final List<String> candidates = PluginDocs.candidatePaths(
        executablePath: fakeExeIn(temp),
      );
      expect(candidates, isNotEmpty);
      expect(candidates.toSet().length, candidates.length, reason: '候选不得重复');
      for (final String c in candidates) {
        expect(PluginDocs.docNames, contains(p.basename(c)));
      }
      expect(
        candidates.any((String c) => p.basename(c) == PluginDocs.guideName),
        isTrue,
        reason: '系统性指南必须在候选里（首选）',
      );
    });

    test('同一目录里指南与 README 都在 ⇒ 选系统性指南', () {
      final Directory bundled = Directory(
        p.join(temp.path, PluginDocs.bundledDirName),
      )..createSync(recursive: true);
      File(p.join(bundled.path, PluginDocs.readmeName))
        .writeAsStringSync('# 示例索引\n');
      final File guide = File(p.join(bundled.path, PluginDocs.guideName))
        ..writeAsStringSync('# 插件开发指南\n');
      expect(
        PluginDocs.resolvePath(executablePath: fakeExeIn(temp)),
        guide.path,
        reason: '入口要送人去**系统性指南**；简版 README 只是兜底',
      );
    });

    test('源码布局：仓库 docs/ 下的指南也被找到', () {
      final Directory deep = Directory(
        p.join(temp.path, 'build', 'windows', 'x64', 'runner', 'Debug'),
      )..createSync(recursive: true);
      final Directory docs = Directory(
        p.join(temp.path, PluginDocs.repoDocDirName),
      )..createSync(recursive: true);
      final File guide = File(p.join(docs.path, PluginDocs.guideName))
        ..writeAsStringSync('# 插件开发指南\n');
      expect(
        PluginDocs.resolvePath(executablePath: fakeExeIn(deep)),
        guide.path,
      );
    });

    test('祖先目录里的 docs/README.md 不算插件文档（泛化文件名会认错文档）', () {
      // 实测来源：`flutter test` 的 flutter_tester.exe 在 Flutter SDK 里，
      // 逐级向上会命中 SDK 自带的 `flutter/docs/README.md`——若认它，用户点
      // 「打开插件开发说明」会被送到一份与插件无关的文档上。
      final Directory deep = Directory(
        p.join(temp.path, 'build', 'windows', 'x64', 'runner', 'Debug'),
      )..createSync(recursive: true);
      final Directory docs = Directory(
        p.join(temp.path, PluginDocs.repoDocDirName),
      )..createSync(recursive: true);
      File(p.join(docs.path, PluginDocs.readmeName))
          .writeAsStringSync('# 这是别的项目的文档\n');
      expect(
        PluginDocs.resolvePath(executablePath: fakeExeIn(deep)),
        isNull,
        reason: 'docs/ 下只认 plugin-development.md 这个专有文件名',
      );
    });

    test('openReadme：找不到文档时给可读原因（含查找位置）', () async {
      final String? error = await PluginDocs.openReadme(
        executablePath: fakeExeIn(temp),
      );
      expect(error, isNotNull);
      expect(error, contains('未找到'));
      expect(error, contains(PluginDocs.bundledDirName));
      expect(error, contains(PluginDocs.repoDirName));
    });

    test('openPath：路径不存在时给可读原因', () async {
      final String? error = await PluginDocs.openPath(
        p.join(temp.path, 'nope.md'),
      );
      expect(error, contains('不存在'));
    });
  });

  group('设置页：插件开发入口与版本信息', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    Future<void> pumpSettings(WidgetTester tester, VersionInfo info) async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(versionInfo: info)),
      );
      await tester.pump();
    }

    /// 版本卡在列表末尾，必须先滚下去（否则 find 找不到、测试假红）。
    Future<void> scrollTo(WidgetTester tester, Finder target) async {
      await tester.scrollUntilVisible(
        target,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
    }

    const VersionInfo full = VersionInfo(
      coreVersion: '0.1.0',
      corePid: 4242,
      corePort: 63970,
      attached: false,
      coreExecutablePath: r'E:\app\tree_core.exe',
      buildWarning: null,
    );

    testWidgets('版本卡显示应用 / 核心 / 进程 / 契约与产物路径', (WidgetTester tester) async {
      await pumpSettings(tester, full);
      final Finder card = find.byKey(const Key('version-copy'));
      await scrollTo(tester, card);

      expect(find.text('版本信息'), findsOneWidget, reason: '分区标题');
      expect(find.text('$kAppVersion+$kAppBuildNumber'), findsOneWidget);
      expect(find.text('0.1.0'), findsOneWidget);
      expect(find.text('pid 4242 · 端口 63970 · 本应用拉起'), findsOneWidget);
      expect(find.text('v$kClientContractVersion'), findsOneWidget);
      expect(find.text(r'E:\app\tree_core.exe'), findsOneWidget);
      expect(find.byKey(const Key('version-build-warning')), findsNothing);
    });

    testWidgets('附着模式与未握手都给可读文案（不留空、不显示假 pid）', (WidgetTester tester) async {
      await pumpSettings(
        tester,
        const VersionInfo(
          coreVersion: '',
          corePid: 0,
          corePort: 0,
          attached: true,
          coreExecutablePath: '',
          buildWarning: null,
        ),
      );
      await scrollTo(tester, find.byKey(const Key('version-copy')));

      expect(find.text('未知（未完成握手）'), findsNWidgets(2), reason: '版本与进程各一处');
      // 附着模式没有"本应用拉起的核心产物路径"⇒ 该行整行不显示
      expect(find.text('核心产物'), findsNothing);
    });

    testWidgets('核心产物比界面旧 ⇒ 告警显示在版本卡上', (WidgetTester tester) async {
      await pumpSettings(
        tester,
        const VersionInfo(
          coreVersion: '0.1.0',
          corePid: 1,
          corePort: 2,
          attached: false,
          coreExecutablePath: '',
          buildWarning: '核心进程产物比界面旧：请重建核心后重启应用',
        ),
      );
      await scrollTo(tester, find.byKey(const Key('version-copy')));

      expect(find.byKey(const Key('version-build-warning')), findsOneWidget);
      expect(find.textContaining('核心进程产物比界面旧'), findsOneWidget);
    });

    testWidgets('插件开发卡：文档入口 + 找不到时的可读提示', (WidgetTester tester) async {
      await pumpSettings(tester, full);
      await scrollTo(tester, find.byKey(const Key('plugin-docs-open')));

      expect(find.text('插件开发'), findsOneWidget, reason: '分区标题');
      expect(find.text('打开插件开发说明'), findsOneWidget);
      expect(
        find.textContaining('stdio JSON-RPC'),
        findsOneWidget,
        reason: '入口要一句话说清插件是什么，不能只有一个按钮',
      );
      // 测试环境里没有 plugins/README.md ⇒ 显示可读提示而不是空
      expect(find.textContaining('未找到'), findsOneWidget);
      // 找不到时"打开所在目录"应当不可点（点了也没意义的按钮不如禁用）
      final OutlinedButton reveal = tester.widget<OutlinedButton>(
        find.byKey(const Key('plugin-docs-reveal')),
      );
      expect(reveal.onPressed, isNull);
    });

    testWidgets('复制版本信息：写进剪贴板并给提示', (WidgetTester tester) async {
      final List<MethodCall> calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') calls.add(call);
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

      await pumpSettings(tester, full);
      await scrollTo(tester, find.byKey(const Key('version-copy')));
      await tester.tap(find.byKey(const Key('version-copy')));
      await tester.pump();

      expect(calls, hasLength(1));
      final String text =
          (calls.single.arguments as Map<Object?, Object?>)['text'] as String;
      expect(text, contains('Tree 桌面端 $kAppVersion+$kAppBuildNumber'));
      expect(text, contains('核心版本：0.1.0'));
      expect(text, contains('接口契约：v$kClientContractVersion'));
      expect(find.text('版本信息已复制'), findsOneWidget);
    });
  });
}
