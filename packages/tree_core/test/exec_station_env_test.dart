// 执行站·环境族（`env.get` / `env.refresh`，2026-11-13）。
//
// 这族解决的是「用户装了新工具 / 改了 PATH，而核心与插件进程还是启动时那份环境」：
// 核心启动后先主动重读一次；插件需要再刷新时下 `env.refresh`，只读当前环境用 `env.get`。
//
// 钉住的四件事：
// 1. `env.get` 默认回整份环境；带 `names` 时只回命中的（大小写不敏感，Windows 口径），
//    并显式列出 `missing`；
// 2. `env.refresh` 回**刷新前后差异**（changed / added / removed），默认不回整份环境，
//    `include_env: true` 才带；
// 3. 本族是**整机级**能力：不要求 team（与 plugin / station 两族刻意不同）；
// 4. 没接线时以「未接线」显式失败，不假装读过（口径与另两族一致）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  group('EnvironmentCommands', () {
    late Map<String, String> current;
    late Map<String, String>? snapshot;
    late int loads;
    late int reloads;

    setUp(() {
      current = <String, String>{
        'Path': r'C:\Windows\system32;C:\Users\me\bin',
        'TREE_HOME': r'E:\tree',
      };
      snapshot = null;
      loads = 0;
      reloads = 0;
    });

    EnvironmentCommands commands() => EnvironmentCommands(
      load: (void Function(String message)? log) async {
        loads++;
        return Map<String, String>.of(current);
      },
      reload: (void Function(String message)? log) async {
        reloads++;
        snapshot = Map<String, String>.of(current);
        current = <String, String>{
          'Path': r'C:\Windows\system32;C:\Users\me\bin;C:\Program Files\GitHub CLI',
          'NEW_TOOL_HOME': r'D:\tools',
        };
        return Map<String, String>.of(current);
      },
      snapshot: () => snapshot == null ? null : Map<String, String>.of(snapshot!),
    );

    test('env.get：不带 names ⇒ 整份环境', () async {
      final Map<String, dynamic> result = await commands().handle(
        command: 'env.get',
      );
      expect(result['ok'], isTrue);
      expect(result['count'], 2);
      expect(result['env'], current);
      expect(loads, 1);
    });

    test('env.get：names 大小写不敏感，找不到的进 missing（不静默）', () async {
      final Map<String, dynamic> result = await commands().handle(
        command: 'env.get',
        arguments: <String, dynamic>{
          'names': <String>['path', 'NOPE'],
        },
      );
      expect(result['ok'], isTrue);
      expect(result['count'], 1);
      expect(
        result['env'],
        <String, String>{'Path': current['Path']!},
        reason: '键名保持环境里的写法（插件拿去比对时才知道原样）',
      );
      expect(result['missing'], <String>['NOPE']);
    });

    test('env.get：names 形状非法 ⇒ 可读拒绝（不吞成"空结果"）', () async {
      final Map<String, dynamic> result = await commands().handle(
        command: 'env.get',
        arguments: <String, dynamic>{'names': 'Path'},
      );
      expect(result['ok'], isFalse);
      expect(result['error'], contains('names'));
    });

    test('env.refresh：回刷新前后差异，默认不带整份环境', () async {
      // 先让有一条"缓存基线"（get 一次不会设置快照，这里直接给 snapshot）
      snapshot = <String, String>{'Path': r'C:\old', 'GONE': '1'};
      final Map<String, dynamic> result = await commands().handle(
        command: 'env.refresh',
      );
      expect(result['ok'], isTrue);
      expect(reloads, 1);
      expect(result['baseline'], 'cache');
      expect(result['changed'], <String>['Path']);
      expect(result['added'], <String>['NEW_TOOL_HOME']);
      expect(result['removed'], <String>['GONE']);
      expect(result.containsKey('env'), isFalse);
      expect(result['refreshed_at'], isA<String>());
    });

    test('env.refresh：include_env=true 才带整份环境', () async {
      snapshot = <String, String>{'Path': r'C:\old'};
      final Map<String, dynamic> result = await commands().handle(
        command: 'env.refresh',
        arguments: <String, dynamic>{'include_env': true},
      );
      expect(result['ok'], isTrue);
      expect(result['env'], current);
    });

    test('env.refresh：没有缓存基线时拿进程环境当基线（不把整份环境报成 added）', () async {
      snapshot = null;
      final Map<String, dynamic> result = await commands().handle(
        command: 'env.refresh',
      );
      expect(result['ok'], isTrue);
      expect(result['baseline'], 'process');
    });

    test('未知 env 命令 ⇒ 可读拒绝并列出允许的命令', () async {
      final Map<String, dynamic> result = await commands().handle(
        command: 'env.rewrite',
      );
      expect(result['ok'], isFalse);
      expect(result['error'], contains('env.get'));
      expect(result['error'], contains('env.refresh'));
    });
  });

  group('挂载位置与环境站', () {
    late Directory temp;
    late PluginBus bus;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tree_env_station_');
      bus = PluginBus(
        configFile: p.join(temp.path, 'config', 'plugins.yaml'),
        coreVersion: 'test',
        heartbeatInterval: const Duration(seconds: 30),
      );
    });

    tearDown(() async {
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

    /// 走**执行站**下命令（绕过站点就等于没测到白名单）。
    Future<StationCommandResult> run(
      String command, {
      StationScope scope = const StationScope(),
      String sourcePluginId = 'local_executor',
    }) async {
      final ExecuteStation? station = bus.stations.executeForCommand(command);
      expect(station, isNotNull, reason: '$command 没有所属点位');
      return station!.execute(
        command: command,
        scope: scope,
        arguments: const <String, dynamic>{},
        sourcePluginId: sourcePluginId,
      );
    }

    test('env.get：不要求 team（整机级能力），插件身份照常透传', () async {
      final EnvironmentCommands env = EnvironmentCommands(
        load: (void Function(String message)? log) async =>
            <String, String>{'Path': r'C:\Windows'},
      );
      expect(
        bus.mountExecuteStations(ExecuteStationMounts(environmentQuery: env.handle)),
        isNull,
      );
      final StationCommandResult result = await run('env.get');
      expect(result.ok, isTrue, reason: result.error);
      expect(
        (result.payload as Map<String, dynamic>)['env'],
        <String, String>{'Path': r'C:\Windows'},
      );
    });

    test('未接线：核心没注入环境读口时以「未接线」失败，不假装读过', () async {
      expect(bus.mountExecuteStations(ExecuteStationMounts()), isNull);
      final StationCommandResult result = await run('env.get');
      expect(result.ok, isFalse);
      expect(result.error, contains('未接线'));
    });

    test('点位白名单：env 族只有 get / refresh，别的名字进不来', () async {
      expect(EnvironmentCommands.commands, <String>['env.get', 'env.refresh']);
      expect(StationPoints.ownerOfCommand('env.rewrite'), isNull);
      expect(
        StationPoints.ownerOfCommand('env.refresh')!.id,
        StationHubIds.executeEnv,
      );
      expect(
        StationPoints.resolveAlias(kindWire: 'execute', point: 'env'),
        isEmpty,
        reason: '执行站不可订阅：别名只用于白名单外的可读文案，不参与订阅解析',
      );
    });
  });
}
