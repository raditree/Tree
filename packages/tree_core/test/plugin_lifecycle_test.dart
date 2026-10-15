// 插件生命周期枚举（plugin_lifecycle.dart）与挂起声明（PluginSuspension）的用例。
//
// 这一份文件钉的是 D11 / D3 的**契约边界**，不是行为：
// 1. 线上形态的字面值（前端与插件都按这些词判断，改名就是破坏兼容）；
// 2. 宽容解析：老核心没有 `lifecycle` 字段、未来可能出现新值 ⇒ 一律 null，绝不抛；
// 3. 路由判据的划分：哪些态算"暂时不可用可暂存"、哪些态"绝不投递"；
// 4. **本枚举不许吃掉 `status` / `health`**：活性看 health、启停看 status、
//    阶段看 lifecycle —— 三件事的取值集合必须互不相交（否则迟早有人拿 lifecycle
//    去当 health 用，产出"health=ok 但 lifecycle=restarting 到底谁说了算"的悬案）。
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/plugin_host.dart'
    show PluginConfig, PluginSuspension;
import 'package:tree_core/src/plugin/plugin_lifecycle.dart';

void main() {
  test('线上形态的字面值逐个钉住', () {
    expect(PluginLifecycleState.values.map((PluginLifecycleState s) => s.wire),
        <String>[
          'stopped',
          'booting',
          'ready',
          'restarting',
          'suspended',
          'failed',
        ]);
    expect(PluginLifecycleState.tryParse('restarting'),
        PluginLifecycleState.restarting);
  });

  test('宽容解析：空串、未知值、大小写不符都返回 null 而不是抛', () {
    expect(PluginLifecycleState.tryParse(''), isNull);
    expect(PluginLifecycleState.tryParse('   '), isNull);
    // 认不出 ⇒ null（调用方按"不知道生命周期"处理），这比崩掉或"猜一个态"都好。
    expect(PluginLifecycleState.tryParse('ReStarting'), isNull);
    expect(PluginLifecycleState.tryParse('degraded'), isNull);
  });

  test('路由判据：重启中/挂起中/启动中 = 暂时不可用；停用/失败 = 绝不投递', () {
    expect(PluginLifecycleState.restarting.isTemporarilyUnavailable, isTrue);
    expect(PluginLifecycleState.suspended.isTemporarilyUnavailable, isTrue);
    expect(PluginLifecycleState.booting.isTemporarilyUnavailable, isTrue);
    expect(PluginLifecycleState.ready.isTemporarilyUnavailable, isFalse);
    expect(PluginLifecycleState.failed.isTemporarilyUnavailable, isFalse,
        reason: '失败不是"暂时不可用"：暂存它等于把请求存进一个不会回来的地方');

    expect(PluginLifecycleState.stopped.rejectsWork, isTrue);
    expect(PluginLifecycleState.failed.rejectsWork, isTrue);
    expect(PluginLifecycleState.restarting.rejectsWork, isFalse);
    expect(PluginLifecycleState.suspended.rejectsWork, isFalse);
    // 两个判据不得同时为真：一个态要么"等它回来"，要么"别投"，不能又要暂存又要拒绝。
    for (final PluginLifecycleState state in PluginLifecycleState.values) {
      expect(
        state.isTemporarilyUnavailable && state.rejectsWork,
        isFalse,
        reason: '${state.wire} 的同时可暂存与拒绝投递 = 判据自相矛盾',
      );
    }
  });

  test('lifecycle 的字面值不得与 status / health 的词表重叠（三件事各自的家）', () {
    const Set<String> statusValues = <String>{'registered', 'disabled'};
    const Set<String> healthValues = <String>{'ok', 'degraded', 'unavailable'};
    final Set<String> lifecycle = PluginLifecycleState.values
        .map((PluginLifecycleState s) => s.wire)
        .toSet();
    expect(
      lifecycle.intersection(statusValues),
      isEmpty,
      reason: '重叠会让面板与日志里同一个词有两种解释',
    );
    expect(lifecycle.intersection(healthValues), isEmpty);
  });

  group('挂起声明（D3：默认不可挂起）', () {
    test('值域只有"留空"与 keep，且默认是留空', () {
      expect(PluginSuspension.values, <String>{'', 'keep'});
      expect(PluginSuspension.none, '');
      expect(PluginSuspension.keep, 'keep');
      expect(PluginSuspension.describeValues, contains('keep'));
    });

    test('配置没写 suspension ⇒ 解析为空且 canSuspend = false（老插件行为不变）', () {
      final PluginConfig none = PluginConfig.fromJson(<String, dynamic>{
        'id': 'legacy',
        'command': 'python',
      });
      expect(none.suspension, '');
      expect(none.canSuspend, isFalse);
    });

    test('写了 keep ⇒ canSuspend 为真；非字符串取值当没写（不让整份配置读不出来）', () {
      expect(
        PluginConfig.fromJson(<String, dynamic>{
          'id': 'demo',
          'command': 'python',
          'suspension': 'keep',
        }).canSuspend,
        isTrue,
      );
      // fromJson 取宽容读法：非字符串 ⇒ 空串。拼错的大写值由
      // `plugin_config_store.dart` 的校验层当场拒（那边有专门用例）。
      final PluginConfig bad = PluginConfig.fromJson(<String, dynamic>{
        'id': 'demo',
        'command': 'python',
        'suspension': true,
      });
      expect(bad.suspension, '');
      expect(bad.canSuspend, isFalse);
    });

    test('往返：只有声明了才写回这一条（没声明的文档逐字不变）', () {
      expect(
        PluginConfig.fromJson(<String, dynamic>{
          'id': 'demo',
          'command': 'python',
        }).toJson().containsKey('suspension'),
        isFalse,
        reason: '不写 = 不产出空键，保持与改动前逐字一致',
      );
      final PluginConfig keep = PluginConfig.fromJson(<String, dynamic>{
        'id': 'demo',
        'command': 'python',
        'suspension': 'keep',
      });
      expect(keep.toJson()['suspension'], 'keep');
      // 前端形态也要带上它：面板得能在插件**没启动**时就讲得出它能不能挂起。
      expect(keep.toApiJson()['suspension'], 'keep');
    });

    test('给 API 的形态多了 suspension 键，但既有键一个不少（向后兼容）', () {
      final Map<String, dynamic> json = PluginConfig(
        id: 'demo',
        command: 'python',
      ).toApiJson();
      for (final String key in <String>[
        'plugin_id',
        'name',
        'description',
        'command',
        'args',
        'enabled',
        'granularity',
      ]) {
        expect(json.containsKey(key), isTrue, reason: '$key 被改掉了 = 前端读不到');
      }
    });
  });
}
