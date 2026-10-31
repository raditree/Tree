import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 钉住：插件挂载优先于核心实现；卸载后必须回落核心实现。
///
/// 用的是仍然归核心执行的 `plugin.*` 点位（#43 之后领域命令不在表里了，
/// 「核心那侧的挂载位置」只剩平台面两族）。
void main() {
  test('插件挂载优先于核心；unmount 后回落核心实现', () async {
    final ExecuteStation station = ExecuteStation(
      id: StationHubIds.executePlugin,
      description: 'fallback 夹具',
      commands: <String>['plugin.list'],
    );
    station.mount(
      command: 'plugin.list',
      mountId: 'core.execute.plugin.list',
      handler: (StationCommandContext context) async =>
          StationCommandOutcome.ok(<String, dynamic>{'mount': 'core'}),
    );
    station.mount(
      command: 'plugin.list',
      mountId: 'plugin.local_executor',
      priority: 100,
      handler: (StationCommandContext context) async =>
          StationCommandOutcome.ok(<String, dynamic>{'mount': 'plugin'}),
    );
    StationCommandResult result = await station.execute(
      command: 'plugin.list',
      scope: const StationScope(modeKey: 'local'),
      arguments: const <String, dynamic>{},
    );
    expect((result.payload! as Map)['mount'], 'plugin');
    station.unmount('plugin.local_executor');
    result = await station.execute(
      command: 'plugin.list',
      scope: const StationScope(modeKey: 'local'),
      arguments: const <String, dynamic>{},
    );
    expect((result.payload! as Map)['mount'], 'core');
  });
}
