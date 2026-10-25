import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 钉住：插件挂载优先于核心实现；卸载后必须回落核心实现。
void main() {
  test('插件挂载优先于核心；unmount 后回落核心实现', () async {
    final ExecuteStation station = ExecuteStation(
      id: StationHubIds.executeFs,
      description: 'fallback 夹具',
      commands: <String>['fs.read'],
    );
    station.mount(
      command: 'fs.read',
      mountId: 'core.execute.fs.read',
      handler: (StationCommandContext context) async =>
          StationCommandOutcome.ok(<String, dynamic>{'mount': 'core'}),
    );
    station.mount(
      command: 'fs.read',
      mountId: 'plugin.local_executor',
      priority: 100,
      handler: (StationCommandContext context) async =>
          StationCommandOutcome.ok(<String, dynamic>{'mount': 'plugin'}),
    );
    StationCommandResult result = await station.execute(
      command: 'fs.read',
      scope: const StationScope(modeKey: 'local'),
      arguments: const <String, dynamic>{},
    );
    expect((result.payload! as Map)['mount'], 'plugin');
    station.unmount('plugin.local_executor');
    result = await station.execute(
      command: 'fs.read',
      scope: const StationScope(modeKey: 'local'),
      arguments: const <String, dynamic>{},
    );
    expect((result.payload! as Map)['mount'], 'core');
  });
}