import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// **插件声明左侧活动栏面板**（Q12 的生产端，端到端）：
///
/// 真插件进程 → stdio 通知 `ui/manifest` → 核心桥接 → WS 广播 `plugin_ui_manifest`
/// → 前端注册表登记槽位（`activity` 槽位正是左侧活动栏项）。
///
/// 这里断言"帧真的发出来了、内容可用、归属不可自述、非法声明不降级"；
/// 前端渲染另有 `test/plugin_ui_slots_test.dart`（活动栏接入点）。
void main() {
  late Directory temp;
  late String script;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_ui_bridge_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    expect(File(script).existsSync(), isTrue, reason: '假插件脚本必须存在');
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

  String slash(String path) => path.replaceAll(Platform.pathSeparator, '/');

  String pluginYaml(List<String> extraArgs) =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: demo\n'
      '    name: 布局插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}"'
      '${extraArgs.map((String a) => ', "$a"').join()}]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1}\n';

  /// 起总线并收集广播帧，等 `plugin_ui_manifest` 到达。
  Future<({PluginBus bus, List<Map<String, dynamic>> frames})> startWithFrames(
    String yaml,
  ) async {
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(yaml);
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      broadcast: frames.add,
    );
    addTearDown(bus.close);
    await bus.start();
    return (bus: bus, frames: frames);
  }

  Future<Map<String, dynamic>?> waitForFrame(
    List<Map<String, dynamic>> frames,
    String type,
  ) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      for (final Map<String, dynamic> frame in frames) {
        if (frame['type'] == type) return frame;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  test('插件发 ui/manifest ⇒ 核心广播 plugin_ui_manifest（含 activity 槽位）', () async {
    final ({PluginBus bus, List<Map<String, dynamic>> frames}) started =
        await startWithFrames(pluginYaml(<String>['--ui-manifest']));
    final Map<String, dynamic>? frame = await waitForFrame(
      started.frames,
      PluginUiFrameType.manifest,
    );
    expect(frame, isNotNull, reason: '核心必须把插件声明的槽位推给前端');

    final PluginUiManifest manifest = PluginUiManifest.fromFrame(frame!)!;
    expect(manifest.pluginId, 'demo', reason: '归属取实例 id');
    expect(manifest.teamId, 'team-1', reason: 'team 取 plugins.yaml 的声明');
    final PluginUiSlot activity = manifest.slots.firstWhere(
      (PluginUiSlot s) => s.kind == PluginUiSlotKind.activity,
    );
    expect(activity.slotKey, 'fake.activity.1');
    expect(activity.title, '假插件面板');
    expect(activity.view.nodes.single.type, 'column');
    expect(
      manifest.slots.map((PluginUiSlot s) => s.kind),
      contains(PluginUiSlotKind.panel),
      reason: '右栏 Tab 槽位同样支持',
    );

    // 非 UI 通知仍走 plugin_event（既有行为不变）：插件在 hello 之后会发 log。
    expect(
      await waitForFrame(started.frames, 'plugin_event'),
      isNotNull,
      reason: '插件上线后的 log 通知照旧转 plugin_event',
    );

    // **当前态缓存**（前端刷新 / 重连 / 启动竞态错过的重放来源）：真插件的真声明
    // 必须在广播的同时进缓存，且重放的就是同一份槽位。
    expect(
      started.bus.uiCache.pluginIds(),
      contains('demo'),
      reason: '广播出去的真声明必须同时入缓存，否则前端后连就永远拿不到面板',
    );
    final PluginUiManifest replayed = PluginUiManifest.fromFrame(
      started.bus.uiCache.frames().firstWhere(
            (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.manifest,
          ),
    )!;
    expect(replayed.slots.map((PluginUiSlot s) => s.slotKey),
        manifest.slots.map((PluginUiSlot s) => s.slotKey));

    // 插件下线 ⇒ 缓存作废（新连接不该再收到已下线插件的槽位）
    await started.bus.close();
    expect(started.bus.uiCache.frames(), isEmpty);
  });

  test('插件冒用别的 plugin_id 声明槽位 ⇒ 该条被跳过（归属不可自述）', () async {
    final ({PluginBus bus, List<Map<String, dynamic>> frames}) started =
        await startWithFrames(
          pluginYaml(<String>['--ui-manifest-foreign']),
        );
    final Map<String, dynamic>? frame = await waitForFrame(
      started.frames,
      PluginUiFrameType.manifest,
    );
    expect(
      frame,
      isNotNull,
      reason: '越权的那条被跳过，但同帧里合法的 panel 槽位仍应发出',
    );
    final PluginUiManifest manifest = PluginUiManifest.fromFrame(frame!)!;
    expect(
      manifest.slots.map((PluginUiSlot s) => s.slotKey),
      isNot(contains('fake.activity.1')),
      reason: '冒用 plugin_id 的槽位必须被拒',
    );
    expect(manifest.slots.map((PluginUiSlot s) => s.slotKey),
        contains('fake.panel.1'));
  });

  test('通知自带的 team 与声明冲突 ⇒ 以声明为准（不采信自述）', () async {
    final ({PluginBus bus, List<Map<String, dynamic>> frames}) started =
        await startWithFrames(
          pluginYaml(<String>['--ui-manifest', '--ui-team', 'team-9']),
        );
    final Map<String, dynamic>? frame = await waitForFrame(
      started.frames,
      PluginUiFrameType.manifest,
    );
    expect(frame, isNotNull);
    expect(
      PluginUiManifest.fromFrame(frame!)!.teamId,
      'team-1',
      reason: '声明是作用域上限：插件不能把面板刷到别的 team',
    );
  });
}
