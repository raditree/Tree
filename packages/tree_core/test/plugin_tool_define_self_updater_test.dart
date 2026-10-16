// 阶段 3（第 4 天）：**框架自迭代插件**的内置注册与两条申报路（真子进程）。
//
// 为什么单独一份而不是并进 `plugin_tool_define_test.dart`：那份钉的是**机制**
// （收集站怎么采集、怎么按来源 plugin_id 路由），这一份钉的是**这条能力出厂时的形状**
// —— 内置清单的字段、播种语义，以及"同一个工具有两条申报路，schema 必须同一份"。
// 机制变了改那份，这条的合同变了改这一份。
//
// 钉住的六件事：
// 1. 内置清单：binary 型、team 粒度、默认开、**声明 `suspension: keep`**（少了这一项，
//    "重启我自己而不丢状态"就退化成冷启动，而它在界面上看不出任何区别）；
// 2. 播种严格：只在条目根本不存在时播种；解析失败只记日志不落盘；用户关过绝不再开；
// 3. 出厂的空 scope ⇒ 走 `tools/list` 那一路申报（不依赖任何调用点上下文）；
// 4. 给了 team 归属 ⇒ 走收集站 `plugin.tool.define` 那一路申报，命名空间是
//    `plugin__self_updater__plugin_hot_restart`，而 `self_updater` 这一段来自插件在
//    `hello` 里的**自报**（两边不同串就在此暴露）；
// 5. 两条路的**参数 schema 逐字一致**：漂移出的两个工具比"没工具"更难查；
// 6. `action` 只能填控制面四条 —— 快照两条是生命周期原语，不交给模型（D9）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 插件自报的工具名（源头在 `packages/tree_self_updater/lib/src/tool_surface.dart`）。
/// 这里**故意手抄**：本用例要的正是"两边不一致时闸门得红"，共用常量就等于没测。
const String kToolName = 'plugin_hot_restart';
const String kNamespaced = 'plugin__self_updater__$kToolName';

/// `action` ⇒ 执行站命令的期望映射（与 `PluginToolSurface.agentToolCommands` 同集）。
const Map<String, String> kActionToCommand = <String, String>{
  'list': 'plugin.list',
  'state': 'plugin.state',
  'restart': 'plugin.restart',
  'suspend': 'plugin.suspend',
};

void main() {
  late Directory temp;
  late String repo;
  late String selfUpdaterBin;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_self_updater_');
    final String? found = BuiltinPluginCatalog.repoRoot(Directory.current.path);
    expect(found, isNotNull, reason: '用例锚不到仓根 ⇒ 插件源码路径无从拼');
    repo = found!;
    selfUpdaterBin = p.join(
      repo,
      'packages',
      'tree_self_updater',
      'bin',
      'tree_self_updater.dart',
    );
    expect(File(selfUpdaterBin).existsSync(), isTrue, reason: selfUpdaterBin);
  });

  tearDown(() async {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  // ── 夹具 ───────────────────────────────────────────────────────────────

  /// 起一条只装 self_updater 的总线（[scopeLine] 决定它走**哪条申报路**）。
  ///
  /// 用**源码**起而不是用 `build/plugins` 里的产物：产物是 gitignore 的构建输出，
  /// 拿它当唯一依赖会让这台机器之外的 `dart test` 全都跳过。产物的解析与自检另有
  /// 一条门控用例（见最后那条 test）。
  Future<PluginBus> startBus({
    required String scopeLine,
    required List<String> logs,
  }) async {
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(
      <String>[
        'enabled: true',
        'plugins:',
        '  - id: $kSelfUpdaterPluginId',
        '    name: 框架自迭代插件',
        '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"',
        '    args: ["${selfUpdaterBin.replaceAll('\\', '/')}"]',
        '    enabled: true',
        '    granularity: team',
        '    suspension: keep',
        '    scope: $scopeLine',
        '',
      ].join('\n'),
    );
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      // 心跳节拍拉长：本文件只关心申报，不要探活定时器插进来
      heartbeatInterval: const Duration(seconds: 30),
      log: (String message) => logs.add(message),
    );
    await bus.start();
    return bus;
  }

  /// 从工具 schema 里取出 `action` 的可选值（= 模型真能填的那几个）。
  List<String> actionsOf(Map<String, dynamic> parameters) {
    final Object? properties = parameters['properties'];
    if (properties is! Map) return const <String>[];
    final Object? action = (properties['action'] as Map?)?['enum'];
    return action is List
        ? <String>[for (final Object? e in action) '$e']
        : const <String>[];
  }

  /// 工具表里那一条的完整合同检查（两条申报路共用 ⇒ 少写一遍就会漏一遍）。
  void expectToolContract(PluginToolDefinition definition) {
    expect(definition.pluginId, kSelfUpdaterPluginId);
    expect(definition.toolName, kToolName);
    expect(definition.resolvedExecutionName, kToolName);
    expect(
      definition.executionMethod,
      PluginToolDefinition.executionMethodToolCall,
    );
    expect(definition.description, contains('热重启'));
    final List<String> actions = actionsOf(definition.parameters);
    expect(actions, unorderedEquals(kActionToCommand.keys));
    // action ⇒ 命令 的映射必须**正好落在可申报的四条**上：多一条就是把原语交给模型
    expect(
      actions.map((String a) => kActionToCommand[a]).toSet(),
      PluginToolSurface.agentToolCommands,
    );
    for (final String raw in <String>[
      'stateDump',
      'stateFetch',
      'plugin.stateDump',
      'plugin.stateFetch',
    ]) {
      expect(actions, isNot(contains(raw)), reason: '$raw 是生命周期原语（D9）');
    }
  }

  // ── 1：内置清单的形状 ──────────────────────────────────────────────────

  test('内置清单：binary 型、默认开，并且**声明了可挂起**', () {
    final BuiltinPluginSpec? spec = BuiltinPluginCatalog.specOf(
      kSelfUpdaterPluginId,
    );
    expect(spec, isNotNull, reason: '清单里没有它 ⇒ 面板永远不会出现这一项');
    expect(spec!.kind, BuiltinPluginSpec.kindBinary);
    expect(spec.runtime, 'binary');
    expect(spec.script, kSelfUpdaterBinaryName);
    expect(spec.granularity, 'team');
    expect(spec.scope, isEmpty, reason: '出厂不限定归属 ⇒ 工具对所有 team 可见');
    expect(spec.defaultEnabled, isTrue);
    expect(
      spec.suspension,
      PluginSuspension.keep,
      reason: '没有它，"重启我自己"就是冷启动：差别只在这一个字段上',
    );
    expect(spec.toJson()['suspension'], 'keep');
    expect(
      BuiltinPluginCatalog.specOf(kSelfUpdaterPluginId)!.description,
      contains('tree_self_updater --selftest'),
      reason: '面板要告诉用户怎么自检（装机后端到验证读退出码）',
    );

    // 随包文件名的口径（Windows 补 .exe，其他平台不带扩展名）
    expect(
      BuiltinPluginCatalog.binaryFileName(spec, isWindows: true),
      '$kSelfUpdaterBinaryName.exe',
    );
    expect(
      BuiltinPluginCatalog.binaryFileName(spec, isWindows: false),
      kSelfUpdaterBinaryName,
    );

    // 落盘条目：binary 型**不许**塞空串参数；suspension 必须真的写进去
    final Map<String, dynamic> entry = BuiltinPluginCatalog.entryFor(
      spec,
      BuiltinResolution.ok(
        command: 'C:/tree/plugins/$kSelfUpdaterBinaryName.exe',
        prefixArgs: const <String>[],
        scriptPath: '',
        searchedScriptRoots: const <String>[],
      ),
    );
    expect(entry['args'], isEmpty, reason: 'args: [""] 会让插件拿到一个空参数');
    expect(entry['suspension'], 'keep');
    expect(entry['builtin'], isTrue);
    expect(entry['enabled'], isTrue);

    // 反面对照：没声明的内置项**不该**多出一个无意义的键（用户看到的键只含真影响行为的）
    final Map<String, dynamic> sampleEntry = BuiltinPluginCatalog.entryFor(
      BuiltinPluginCatalog.specOf('sample')!,
      BuiltinResolution.ok(
        command: 'python',
        prefixArgs: const <String>[],
        scriptPath: 'plugins/sample_plugin.py',
        searchedScriptRoots: const <String>[],
      ),
    );
    expect(sampleEntry.containsKey('suspension'), isFalse);
  });

  // ── 2：播种语义 ────────────────────────────────────────────────────────

  test('播种严格：条目根本没有才种；解析失败不落盘；用户关过绝不再开', () async {
    final String configFile = p.join(temp.path, 'config', 'plugins.yaml');
    File(configFile).createSync(recursive: true);
    final PluginConfigStore store = PluginConfigStore(configFile);
    final Directory bin = Directory(p.join(temp.path, 'bin'))..createSync();

    // ① 产物还没做 ⇒ **不播种**，但原因要说出来（静默的结果是面板上一句"未启用"，
    //    而用户以为是自己没打开开关）
    final List<String> quiet = <String>[];
    final BuiltinPluginCatalog missing = BuiltinPluginCatalog(
      scriptRoots: <String>[p.join(temp.path, 'nowhere')],
      isWindows: false,
    );
    expect(
      await seedDefaultEnabledBuiltins(
        catalog: missing,
        store: store,
        log: quiet.add,
      ),
      isEmpty,
    );
    expect(store.readEntry(kSelfUpdaterPluginId), isNull);
    expect(
      quiet.any(
        (String m) => m.contains(kSelfUpdaterPluginId) && m.contains('解析失败'),
      ),
      isTrue,
      reason: '$quiet',
    );

    // ② 产物就位 ⇒ 播种一条 enabled + suspension: keep（键丢了就等于白声明）
    File(p.join(bin.path, kSelfUpdaterBinaryName))
        .writeAsStringSync('placeholder');
    final BuiltinPluginCatalog present = BuiltinPluginCatalog(
      scriptRoots: <String>[bin.path],
      isWindows: false,
    );
    expect(
      await seedDefaultEnabledBuiltins(catalog: present, store: store),
      contains(kSelfUpdaterPluginId),
    );
    final Map<String, dynamic>? seeded = store.readEntry(kSelfUpdaterPluginId);
    expect(seeded, isNotNull);
    expect(seeded!['enabled'], isTrue);
    expect(seeded['suspension'], 'keep');

    // ③ 幂等：再来一次必须什么都不做（否则每次启动都在改用户的文件）
    expect(
      await seedDefaultEnabledBuiltins(catalog: present, store: store),
      isEmpty,
    );

    // ④ 用户显式关过 ⇒ 绝不再自动打开（那是"替用户改回他自己关掉的东西"）
    expect(store.setEnabled(kSelfUpdaterPluginId, false).ok, isTrue);
    await seedDefaultEnabledBuiltins(catalog: present, store: store);
    expect(store.readEntry(kSelfUpdaterPluginId)!['enabled'], isFalse);
  });

  // ── 3/4：真子进程的两条申报路 ──────────────────────────────────────────

  test('空 scope（出厂默认）⇒ 走 tools/list 申报，命名空间与插件自报 id 同串', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(scopeLine: '{}', logs: logs);
    addTearDown(bus.close);

    expect(bus.instances(), hasLength(1), reason: '$logs');
    // 自报身份与核心清单**同串**：命名空间里那一段来自 hello，不是配置抄来的
    final PluginHost host = bus.instances().single.host;
    expect(
      host.pluginId,
      kSelfUpdaterPluginId,
      reason: '插件自报 id 与内置清单不同串 ⇒ "模型看到的工具名"与"插件认识的 id"对不上',
    );
    expect(host.name, BuiltinPluginCatalog.specOf(kSelfUpdaterPluginId)!.name);

    expect(
      bus.toolsOf(kSelfUpdaterPluginId).map((PluginToolInfo t) => t.name),
      <String>[kToolName],
      reason: '这个插件只提供唯一一个 tool（四个动作是一个动作的四种问法）',
    );
    final PluginToolDefinition? definition = bus.definitionOf(kNamespaced);
    expect(definition, isNotNull, reason: '命名空间必须是 plugin__<id>__<tool>');
    expectToolContract(definition!);
    // 通配订阅没有可证明的 team ⇒ 这一趟**不**走站点采集（但原因必须说得出，不静默）
    final ToolDefinitionRefresh refresh =
        await PluginTool.refreshToolDefinitions(bus);
    expect(refresh.registered, isEmpty, reason: '证不了归属 ⇒ 本不该采集');
    expect(
      refresh.skipped.any(
        (String s) => s.contains('通配订阅') && s.contains('tools/list'),
      ),
      isTrue,
      reason: '${refresh.skipped}',
    );
    expect(
      bus.toolsOf(kSelfUpdaterPluginId),
      isNotEmpty,
      reason: '退回 tools/list 那一路也不能把工具弄丢',
    );
  });

  test('给了 team 归属 ⇒ 走收集站 plugin.tool.define 申报（订阅是核心自己下的）', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(
      scopeLine: '{team_id: team-1, mode_key: local}',
      logs: logs,
    );
    addTearDown(bus.close);

    // 1) 收集站的订阅者就是它自己，且**插件一行代码都没写**（核心代下）
    final Map<String, dynamic> collectStation =
        (bus.snapshot()['stations'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .firstWhere((Map<String, dynamic> s) => s['kind'] == 'collect');
    expect(collectStation['station_id'], StationHubIds.collect);
    expect(
      (collectStation['subscriptions'] as List<dynamic>).map(
        (dynamic s) => (s as Map<String, dynamic>)['plugin_id'],
      ),
      <String>[kSelfUpdaterPluginId],
    );

    // 2) 采集回来的定义进了工具表
    final ToolDefinitionRefresh refresh =
        await PluginTool.refreshToolDefinitions(bus);
    expect(refresh.complete, isTrue, reason: refresh.describe());
    expect(refresh.unresponsive, isEmpty, reason: '真插件必须真的回包');
    expect(refresh.registered, contains(kNamespaced));
    expectToolContract(bus.definitionOf(kNamespaced)!);
    expect(
      bus.definitionOf(kNamespaced)!.scope.teamId,
      'team-1',
      reason: '申报时的 scope 是工具表可见性过滤的依据',
    );

    // 3) 点位形状：申报走的是内置收集站，不是自建点位
    expect(StationHubIds.all, contains(StationHubIds.collect));
  });

  test('两条申报路共用同一份 schema（漂移出的两个工具比"没工具"更难查）', () async {
    final List<String> legacyLogs = <String>[];
    final PluginBus legacy = await startBus(scopeLine: '{}', logs: legacyLogs);
    addTearDown(legacy.close);
    final List<String> collectLogs = <String>[];
    final PluginBus collected = await startBus(
      scopeLine: '{team_id: team-2, mode_key: local}',
      logs: collectLogs,
    );
    addTearDown(collected.close);

    final PluginToolDefinition a = legacy.definitionOf(kNamespaced)!;
    final PluginToolDefinition b = collected.definitionOf(kNamespaced)!;
    // 深比较：字段名可以不同（name/inputSchema ↔ tool_name/parameters），
    // 但落到工具表里的**参数表与说明书必须逐字一致**
    expect(b.parameters, a.parameters);
    expect(b.description, a.description);
    expect(actionsOf(b.parameters), actionsOf(a.parameters));
  });

  // ── 5：随包产物（门控：没构建就 skip）──────────────────────────────────

  test('开发态产物解析：build/plugins 里的二进制能被内置目录找到，且自检退出码 0', () async {
    final BuiltinPluginCatalog catalog = BuiltinPluginCatalog(
      executableDir: p.join(repo, 'build'),
    );
    final BuiltinResolution resolution = await catalog.resolve(
      BuiltinPluginCatalog.specOf(kSelfUpdaterPluginId)!,
    );
    if (!resolution.ok) {
      markTestSkipped(
        '没跑 `dart run tool/build_self_updater.dart`（${resolution.error}）：'
        '本机没有产物时这是预期行为（真机构建门控）',
      );
      return;
    }
    expect(resolution.scriptPath, isEmpty, reason: 'binary 型没有脚本参数');
    expect(p.basename(resolution.command), startsWith(kSelfUpdaterBinaryName));
    expect(
      p.split(resolution.command).reversed,
      contains('plugins'),
      reason: '产物必须落在 build/plugins/（打包脚本也从那里拷）',
    );

    // **随包自检**：装机后端到验证读的是退出码，而不是"有没有报错"
    final ProcessResult selftest = await Process.run(
      resolution.command,
      <String>['--selftest'],
    );
    expect(selftest.exitCode, 0, reason: '${selftest.stderr}');
    expect('${selftest.stderr}', contains('PASS'));
    expect('${selftest.stderr}', isNot(contains('FAIL')));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
