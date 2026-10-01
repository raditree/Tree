import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// **插件通知 → 前端 UI 帧的桥**（Q12 的生产端补齐）。
///
/// 覆盖三件事：
/// 1. `ui/manifest` / `ui/update` 真的被转成 `plugin_ui_manifest` /
///    `plugin_ui_update` 帧（前端注册表认的就是这两类帧，此前核心侧无人发送）；
/// 2. **归属不可自述**：通知里带别的 plugin_id / team_id 一律以实例声明为准或拒绝；
/// 3. 非法输入（缺 slots / 槽位类型未知 / 超上限）**显式拒绝并给可读原因**，
///    不发半成品帧；非 UI 通知原样走 `plugin_event`（既有行为不变）。
void main() {
  Map<String, dynamic> paramsFor(List<Map<String, dynamic>> slots) =>
      <String, dynamic>{
        'slots': slots,
        'team_id': 'team-1',
      };

  Map<String, dynamic> slotJson({
    String key = 'demo.panel.1',
    String kind = PluginUiSlotKind.activity,
    Map<String, dynamic>? view,
  }) => <String, dynamic>{
    'slot_key': key,
    'slot': kind,
    'title': '示例面板',
    'icon': 'extension',
    'order': 10,
    'view':
        view ??
        <String, dynamic>{
          'type': 'text',
          'text': 'hello',
          'format': 'plain',
        },
  };

  test('ui/manifest → plugin_ui_manifest：activity 槽位声明成立', () {
    final PluginUiBridge bridge = PluginUiBridge();
    final List<String> rejected = <String>[];
    final Map<String, dynamic>? frame = bridge.frameFor(
      pluginId: 'demo',
      declaredTeamId: 'team-1',
      method: 'ui/manifest',
      params: paramsFor(<Map<String, dynamic>>[slotJson()]),
      onRejected: rejected.add,
    );
    expect(rejected, isEmpty);
    expect(frame, isNotNull);
    expect(frame!['type'], PluginUiFrameType.manifest);
    final PluginUiManifest manifest = PluginUiManifest.fromFrame(frame)!;
    expect(manifest.pluginId, 'demo');
    expect(manifest.teamId, 'team-1');
    expect(manifest.slots.single.slotKey, 'demo.panel.1');
    expect(manifest.slots.single.kind, PluginUiSlotKind.activity);
    expect(manifest.slots.single.pluginId, 'demo');
  });

  test('ui/update → plugin_ui_update：整块替换视图；view 缺省 = 注销该槽位', () {
    final PluginUiBridge bridge = PluginUiBridge();
    final Map<String, dynamic>? frame = bridge.frameFor(
      pluginId: 'demo',
      declaredTeamId: 'team-1',
      method: 'ui/update',
      params: <String, dynamic>{
        'slot_key': 'demo.panel.1',
        'view': <String, dynamic>{'type': 'text', 'text': '更新后'},
      },
    );
    expect(frame!['type'], PluginUiFrameType.update);
    final PluginUiUpdate update = PluginUiUpdate.fromFrame(frame)!;
    expect(update.slotKey, 'demo.panel.1');
    expect(update.view, isNotNull);

    final Map<String, dynamic>? unregister = bridge.frameFor(
      pluginId: 'demo',
      declaredTeamId: 'team-1',
      method: 'ui/update',
      params: <String, dynamic>{'slot_key': 'demo.panel.1'},
    );
    expect(PluginUiUpdate.fromFrame(unregister!)!.view, isNull);
  });

  test('归属不可自述：槽位声称属于别的插件 ⇒ 跳过并给可读原因', () {
    final PluginUiBridge bridge = PluginUiBridge();
    final List<String> rejected = <String>[];
    final Map<String, dynamic> frame = bridge.frameFor(
      pluginId: 'demo',
      declaredTeamId: 'team-1',
      method: 'ui/manifest',
      params: paramsFor(<Map<String, dynamic>>[
        <String, dynamic>{...slotJson(), 'plugin_id': 'other'},
        slotJson(key: 'demo.panel.ok'),
      ]),
      onRejected: rejected.add,
    )!;
    final PluginUiManifest manifest = PluginUiManifest.fromFrame(frame)!;
    expect(manifest.slots.map((PluginUiSlot s) => s.slotKey), <String>[
      'demo.panel.ok',
    ], reason: '越权的那条必须被跳过');
    expect(rejected.single, contains('越权'));
  });

  test('team 以声明为准：通知自带的 team 与声明冲突时不采信自述', () {
    final PluginUiBridge bridge = PluginUiBridge();
    final List<String> rejected = <String>[];
    final Map<String, dynamic> frame = bridge.frameFor(
      pluginId: 'demo',
      declaredTeamId: 'team-1',
      method: 'ui/manifest',
      params: <String, dynamic>{
        'slots': <Map<String, dynamic>>[slotJson()],
        'team_id': 'team-2',
      },
      onRejected: rejected.add,
    )!;
    expect(
      PluginUiManifest.fromFrame(frame)!.teamId,
      'team-1',
      reason: '声明是作用域上限，插件不能把槽位刷到别的 team',
    );
    expect(rejected.single, contains('以声明为准'));

    // 槽位条目自己带的 team 与解析结果不符 ⇒ 该条被跳过（跨 team 拒绝）
    final List<String> rejected2 = <String>[];
    final Map<String, dynamic> frame2 = bridge.frameFor(
      pluginId: 'demo',
      declaredTeamId: 'team-1',
      method: 'ui/manifest',
      params: paramsFor(<Map<String, dynamic>>[
        <String, dynamic>{...slotJson(), 'team_id': 'team-9'},
        slotJson(key: 'demo.panel.ok'),
      ]),
      onRejected: rejected2.add,
    )!;
    expect(PluginUiManifest.fromFrame(frame2)!.slots.single.slotKey,
        'demo.panel.ok');
    expect(rejected2.single, contains('跨 team'));
  });

  test('非法输入显式拒绝：缺 slots / 槽位类型未知 / 超槽位上限', () {
    final PluginUiBridge bridge = PluginUiBridge(maxSlots: 1);

    final List<String> a = <String>[];
    expect(
      bridge.frameFor(
        pluginId: 'demo',
        declaredTeamId: 'team-1',
        method: 'ui/manifest',
        params: <String, dynamic>{'slots': 'not-a-list'},
        onRejected: a.add,
      ),
      isNull,
    );
    expect(a.single, contains('必须是数组'));

    final List<String> b = <String>[];
    expect(
      bridge.frameFor(
        pluginId: 'demo',
        declaredTeamId: 'team-1',
        method: 'ui/manifest',
        params: paramsFor(<Map<String, dynamic>>[
          <String, dynamic>{...slotJson(), 'slot': 'unknown-kind'},
        ]),
        onRejected: b.add,
      ),
      isNull,
      reason: '唯一一条非法 ⇒ 没有合法槽位 ⇒ 整帧不发（也不降级成 plugin_event）',
    );
    expect(b.first, contains('非法'));

    final List<String> c = <String>[];
    expect(
      bridge.frameFor(
        pluginId: 'demo',
        declaredTeamId: 'team-1',
        method: 'ui/manifest',
        params: paramsFor(<Map<String, dynamic>>[
          slotJson(key: 'a'),
          slotJson(key: 'b'),
        ]),
        onRejected: c.add,
      ),
      isNull,
    );
    expect(c.single, contains('超过上限'));

    final List<String> d = <String>[];
    expect(
      bridge.frameFor(
        pluginId: 'demo',
        declaredTeamId: 'team-1',
        method: 'ui/update',
        params: <String, dynamic>{'view': <String, dynamic>{'type': 'text'}},
        onRejected: d.add,
      ),
      isNull,
    );
    expect(d.single, contains('slot_key'));
  });

  test('handles：只接管 ui/manifest 与 ui/update，其余通知维持 plugin_event', () {
    final PluginUiBridge bridge = PluginUiBridge();
    expect(bridge.handles('ui/manifest'), isTrue);
    expect(bridge.handles('ui/update'), isTrue);
    expect(bridge.handles('log'), isFalse);
    expect(bridge.handles('event'), isFalse);
    expect(
      bridge.frameFor(
        pluginId: 'demo',
        declaredTeamId: '',
        method: 'log',
        params: <String, dynamic>{'message': 'hi'},
      ),
      isNull,
    );
  });

  test('未声明 team 的插件可以自带 team（前端按当前 team 过滤）', () {
    final PluginUiBridge bridge = PluginUiBridge();
    final Map<String, dynamic> frame = bridge.frameFor(
      pluginId: 'demo',
      declaredTeamId: '',
      method: 'ui/manifest',
      params: paramsFor(<Map<String, dynamic>>[slotJson()]),
    )!;
    expect(PluginUiManifest.fromFrame(frame)!.teamId, 'team-1');
  });
}
