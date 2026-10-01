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

  // ══════════════════════════════════════════════════════════════════════
  // 当前态缓存（前端刷新 / 重连 / 启动竞态错过声明时的重放来源）
  // ══════════════════════════════════════════════════════════════════════
  group('PluginUiCache：重放的是"当前态"', () {
    /// 造一条"桥已放行"的 manifest 帧（走真桥，不手搓帧形状）。
    Map<String, dynamic> manifestFrame(
      PluginUiBridge bridge,
      String pluginId, {
      String teamId = 'team-1',
    }) =>
        bridge.frameFor(
          pluginId: pluginId,
          declaredTeamId: teamId,
          method: 'ui/manifest',
          params: paramsFor(<Map<String, dynamic>>[slotJson()]),
        )!;

    /// 造一条"桥已放行"的 update 帧。
    Map<String, dynamic> updateFrame(
      PluginUiBridge bridge,
      String pluginId, {
      String teamId = 'team-1',
      String slotKey = 'demo.panel.1',
      Object? view = const <String, dynamic>{'type': 'text', 'text': 'v2'},
    }) =>
        bridge.frameFor(
          pluginId: pluginId,
          declaredTeamId: teamId,
          method: 'ui/update',
          params: <String, dynamic>{
            'slot_key': slotKey,
            'view': view,
            'team_id': teamId,
          },
        )!;

    test('无缓存 ⇒ 无重放', () {
      expect(PluginUiCache().frames(), isEmpty);
    });

    test('重放顺序：manifest 先于 update（前端要求槽位先存在）', () {
      final PluginUiBridge bridge = PluginUiBridge();
      final PluginUiCache cache = PluginUiCache();
      // 故意先记 update 再记 manifest：重放顺序必须由**帧类型**决定，不是到达顺序
      cache.record(updateFrame(bridge, 'demo'));
      cache.record(manifestFrame(bridge, 'demo'));

      final List<Map<String, dynamic>> frames = cache.frames();
      expect(
        frames.map((Map<String, dynamic> f) => f['type']),
        <String>[PluginUiFrameType.manifest, PluginUiFrameType.update],
      );
    });

    test('同类型只留最后一个（重放的是当前态，不是历史）', () {
      final PluginUiBridge bridge = PluginUiBridge();
      final PluginUiCache cache = PluginUiCache();
      cache.record(manifestFrame(bridge, 'demo'));
      cache.record(updateFrame(bridge, 'demo', view: const <String, dynamic>{
        'type': 'text',
        'text': '第一次',
      }));
      cache.record(updateFrame(bridge, 'demo', view: const <String, dynamic>{
        'type': 'text',
        'text': '第二次',
      }));

      final List<Map<String, dynamic>> frames = cache.frames();
      expect(frames, hasLength(2), reason: '一个 manifest + 一个 update，不堆历史');
      final PluginUiUpdate update =
          PluginUiUpdate.fromFrame(frames[1])!;
      expect((update.view!.toJson() as Map<String, dynamic>)['text'], '第二次');
    });

    test('多插件按 plugin_id 字典序（顺序确定，不随登记顺序抖动）', () {
      final PluginUiBridge bridge = PluginUiBridge();
      final PluginUiCache cache = PluginUiCache();
      cache.record(manifestFrame(bridge, 'zeta'));
      cache.record(manifestFrame(bridge, 'alpha'));
      expect(
        cache.frames().map((Map<String, dynamic> f) =>
            PluginUiManifest.fromFrame(f)!.pluginId),
        <String>['alpha', 'zeta'],
      );
      expect(cache.pluginIds(), <String>['alpha', 'zeta']);
    });

    test('归属 team 变了 ⇒ 旧帧作废（不重放上一次声明的陈旧归属）', () {
      final PluginUiBridge bridge = PluginUiBridge();
      final PluginUiCache cache = PluginUiCache();
      cache.record(manifestFrame(bridge, 'demo', teamId: 'team-1'));
      cache.record(updateFrame(bridge, 'demo', teamId: 'team-1'));
      // 插件改配到 team-2 后重新声明
      cache.record(manifestFrame(bridge, 'demo', teamId: 'team-2'));

      final List<Map<String, dynamic>> frames = cache.frames();
      expect(frames, hasLength(1), reason: '旧 team 的 update 必须一起作废');
      expect(PluginUiManifest.fromFrame(frames.single)!.teamId, 'team-2');
    });

    test('remove：插件下线后不再重放（前端可能正断线，收不到 destroyed）', () {
      final PluginUiBridge bridge = PluginUiBridge();
      final PluginUiCache cache = PluginUiCache();
      cache.record(manifestFrame(bridge, 'demo'));
      cache.record(manifestFrame(bridge, 'other'));
      cache.remove('demo');
      expect(cache.pluginIds(), <String>['other']);
      cache.clear();
      expect(cache.frames(), isEmpty);
    });

    test('非 UI 帧 / 畸形帧一律不进缓存（不成为绕过桥校验的旁路）', () {
      final PluginUiCache cache = PluginUiCache();
      cache.record(<String, dynamic>{
        'type': 'plugin_event',
        'data': <String, dynamic>{'plugin_id': 'demo'},
      });
      cache.record(<String, dynamic>{'type': PluginUiFrameType.manifest});
      cache.record(<String, dynamic>{
        'type': PluginUiFrameType.manifest,
        'data': <String, dynamic>{'team_id': 'team-1'}, // 缺 plugin_id
      });
      cache.record(<String, dynamic>{'data': <String, dynamic>{'plugin_id': 'x'}});
      expect(cache.frames(), isEmpty);
      expect(cache.pluginIds(), isEmpty);
    });

    // 真机踩过的坑：`plugin_status` / `plugin_event` 不带 team_id，若让它们参与
    // "归属是否变了"的判定，就会被当成"归属变成空"而把刚存下的声明整条作废
    // ——缓存永远是空的，重放永远没内容。
    test('非 UI 帧不得清掉已缓存的声明（plugin_status 不带 team_id）', () {
      final PluginUiBridge bridge = PluginUiBridge();
      final PluginUiCache cache = PluginUiCache();
      cache.record(manifestFrame(bridge, 'demo', teamId: 'team-1'));
      cache.record(<String, dynamic>{
        'type': 'plugin_status',
        'data': <String, dynamic>{'plugin_id': 'demo', 'status': 'registered'},
      });
      cache.record(<String, dynamic>{
        'type': 'plugin_event',
        'data': <String, dynamic>{'plugin_id': 'demo', 'method': 'log'},
      });
      expect(
        cache.frames(),
        hasLength(1),
        reason: '非 UI 帧必须被帧类型挡在归属判定之外',
      );
      expect(
        PluginUiManifest.fromFrame(cache.frames().single)!.teamId,
        'team-1',
      );
    });
  });
}
