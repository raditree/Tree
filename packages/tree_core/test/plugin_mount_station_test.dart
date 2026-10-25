import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 钉住：`plugin.mount` 只能把执行站命令挂到**发起者自己**，核心不接受
/// 调用方指定别的插件 id；挂载目标点位必须是内置执行站。
void main() {
  test('plugin.mount：pluginId 恒为 sourcePluginId，不读 arguments.plugin_id', () async {
    String? seenPluginId;
    String? seenCommand;
    Map<String, dynamic>? seenArguments;
    final ExecuteStationMounts mounts = ExecuteStationMounts(
      ioFor: (String agentId) async => null,
      agentTeamOf: (String agentId) => '',
      agentModeOf: (String agentId) => '',
      pluginManager:
          ({
            required String command,
            required String pluginId,
            required String sourcePluginId,
            Map<String, dynamic>? arguments,
          }) async {
            seenCommand = command;
            seenPluginId = pluginId;
            seenArguments = arguments;
            return <String, dynamic>{'ok': true, 'mounted': <String>['fs.read']};
          },
    );
    final ExecuteStation station = ExecuteStation(
      id: StationHubIds.executePlugin,
      description: 'plugin.mount 夹具',
      commands: <String>['plugin.mount'],
    );
    expect(mounts.mountInto(station), isNull);
    final StationCommandResult result = await station.execute(
      command: 'plugin.mount',
      scope: const StationScope(modeKey: 'local'),
      arguments: <String, dynamic>{
        'station_id': 'system.execute.fs',
        'commands': <String>['fs.read'],
        'plugin_id': 'someone.else',
      },
      sourcePluginId: 'local_executor',
    );
    expect(result.ok, isTrue, reason: result.error);
    expect(seenCommand, 'plugin.mount');
    expect(seenPluginId, 'local_executor');
    expect(seenArguments!['plugin_id'], 'someone.else');
  });

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