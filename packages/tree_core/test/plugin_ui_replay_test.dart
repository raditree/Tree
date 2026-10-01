import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'ws_harness.dart';

/// **前端后连 / 重连时的插件面板补发**（端到端）。
///
/// 插件的槽位声明是"启动时发一次"的：核心的广播只发给"当下在听"的连接，而前端的
/// 槽位注册表是内存态。于是**先起插件、后连前端**这一常见时序会让面板永远不出现
/// （真机表现：刷新一下 GUI，插件面板就此消失，要重启插件才回来）。
///
/// 这里验证真插件 → 真核心 → 真 WS 的补发链路：后连的客户端必须收到
/// `plugin_ui_manifest`，且补发只发给新连接（不扰动已经在听的连接）。
void main() {
  late Directory temp;
  late PluginBus bus;
  late CoreServer server;
  late TestWs first;
  late List<Map<String, dynamic>> frames;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_ui_replay_');
    final String script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    final File config = File(p.join(temp.path, 'config', 'plugins.yaml'));
    config.createSync(recursive: true);
    config.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: demo\n'
      '    name: 布局插件\n'
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
      '    args: ["${script.replaceAll('\\', '/')}", "--ui-manifest"]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1}\n',
    );
    frames = <Map<String, dynamic>>[];
    void Function(Map<String, dynamic> frame)? sink;
    bus = PluginBus(
      configFile: config.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      broadcast: (Map<String, dynamic> frame) {
        frames.add(frame);
        sink?.call(frame);
      },
    );
    server = await CoreServer.start(
      pluginBus: bus,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    sink = server.hub.broadcast;
    // **第一个连接先不接**：本测试要的正是"没人听的时候插件就声明完了"这个时序
    first = await TestWs.connect(server);
    first.record();
  });

  tearDown(() async {
    await first.close();
    await server.close();
    await bus.close();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('插件先声明、前端后连 ⇒ 新连接收到补发的 plugin_ui_manifest', () async {
    // 先让**先连的那条**把插件启动时的那一次真实广播收下（作为对照组）
    await bus.start();
    await first.until(
      (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.manifest,
      reason: '插件启动时的原始广播',
    );
    final int firstBefore = first.frames
        .where((Map<String, dynamic> f) =>
            f['type'] == PluginUiFrameType.manifest)
        .length;
    expect(bus.uiCache.pluginIds(), contains('demo'),
        reason: '插件启动时核心就该把声明缓存下来');

    // 现在才连上来的客户端（模拟前端刷新 / 启动晚于插件）
    final TestWs late_ = await TestWs.connect(server);
    late_.record();
    addTearDown(late_.close);

    await late_.until(
      (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.manifest,
      reason: '补发的 plugin_ui_manifest',
    );
    final PluginUiManifest replayed = PluginUiManifest.fromFrame(
      late_.frames.firstWhere(
        (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.manifest,
      ),
    )!;
    expect(replayed.pluginId, 'demo');
    expect(replayed.teamId, 'team-1');
    expect(
      replayed.slots.map((PluginUiSlot s) => s.slotKey),
      contains('fake.activity.1'),
      reason: '补发的必须是插件真正声明过的槽位（activity = 左侧活动栏项）',
    );

    // 补发**只给新连接**：先连的那条一帧都不该多收（否则每次有人重连都会让所有
    // 连接重刷一遍面板）
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      first.frames
          .where((Map<String, dynamic> f) =>
              f['type'] == PluginUiFrameType.manifest)
          .length,
      firstBefore,
      reason: '重放不得广播给既有连接',
    );
  });

  test('插件下线 ⇒ 缓存作废：之后连上的客户端不再收到该插件的槽位', () async {
    // 先用"第一条连接收到过原始广播"证明插件确实声明过（否则本测试是空转）
    await bus.start();
    await first.until(
      (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.manifest,
      reason: '插件启动时的原始广播',
    );
    expect(bus.uiCache.frames(), isNotEmpty);

    await bus.close(); // 插件下线（相当于核心关停插件 / 插件被停用）
    expect(bus.uiCache.frames(), isEmpty);

    final TestWs late_ = await TestWs.connect(server);
    late_.record();
    addTearDown(late_.close);
    // 给补发留出到达时间，再断言"没有多余的面板帧"
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      late_.frames.where(
        (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.manifest,
      ),
      isEmpty,
      reason: '已下线插件的槽位不得被重放（那会留下点不动的僵尸面板）',
    );
  });
}
