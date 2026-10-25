import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 钉住：`plugin.toolCall` 是**不透明转发**——核心只认 plugin_id / tool，
/// 领域身份（agent/team/mode/session）必须原样躺在 arguments.scope 里，
/// 核心不读取、不注入、不校验。
void main() {
  test('plugin.toolCall：arguments.scope 原样透传，核心不解析领域字段', () async {
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
            seenArguments = arguments;
            return <String, dynamic>{
              'ok': true,
              'payload': <String, dynamic>{
                'tool': 'query',
                'result': '来自贡献插件',
                'is_error': false,
              },
            };
          },
    );
    final ExecuteStation station = ExecuteStation(
      id: StationHubIds.executePlugin,
      description: 'plugin.toolCall 夹具',
      commands: <String>['plugin.toolCall'],
    );
    expect(mounts.mountInto(station), isNull);
    const Map<String, dynamic> domainScope = <String, dynamic>{
      'agent_id': 'agt',
      'team_id': 'top',
      'mode_key': 'ssh',
      'session_id': 'ses_1',
    };
    final StationCommandResult result = await station.execute(
      command: 'plugin.toolCall',
      scope: const StationScope(modeKey: 'local'),
      arguments: <String, dynamic>{
        'plugin_id': 'tree.sample',
        'tool': 'query',
        'arguments': <String, dynamic>{'id': 1},
        'scope': domainScope,
      },
      sourcePluginId: 'tree.agent',
    );
    expect(result.error, isEmpty);
    expect(result.ok, isTrue);
    final Map<String, dynamic> outer =
        (result.payload as Map).cast<String, dynamic>();
    final Map<String, dynamic> payload =
        (outer['payload'] as Map).cast<String, dynamic>();
    expect(payload['tool'], 'query');
    expect(payload['result'], '来自贡献插件');
    expect(seenArguments, isNotNull);
    expect(seenArguments!['scope'], domainScope);
    expect(seenArguments!.containsKey('agent_id'), isFalse);
    expect(seenArguments!.containsKey('team_id'), isFalse);
    expect(seenArguments!.containsKey('mode_key'), isFalse);
  });
}