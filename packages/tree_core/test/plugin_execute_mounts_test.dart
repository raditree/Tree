import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/execute_mounts.dart';
import 'package:tree_core/src/plugin/station_ids.dart';
import 'package:tree_core/src/plugin/station_instance.dart';
import 'package:tree_core/src/plugin/station_points.dart';
import 'package:tree_core/src/plugin/station_runtime.dart';
import 'package:tree_core/src/plugin/station_scope.dart';
import 'package:tree_core/src/plugin/stations.dart';
import 'package:tree_core/src/tool/terminal_hooks.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 执行站首命令集的**挂载位置**（M9 Wave 3-I；点位化见 `station_points.dart`）。
///
/// 验证两件事：
/// 1. 九条可落地命令都真的有落点（不再返回「暂无挂载位置」），且落到**既有实现**上
///    （fs.* → WorkspaceIO；terminal.exec → terminal 工具；agent.* → 注入的会话路径），
///    并且**每个执行站点位只挂自己那族的命令**（点位化：一个命令族一个实例）；
/// 2. 每条命令都按**四元组 scope** 解析目标：跨 team / 跨模式 / agent 不一致一律
///    拒绝并给可读原因（fail-closed），且**不动**工作空间。
void main() {
  late Directory temp;
  late String workspace;
  late StationHub hub;
  late List<Map<String, dynamic>> sent;
  late List<Map<String, dynamic>> stopped;
  late List<Map<String, dynamic>> compacted;
  late List<ExecuteStationMounts> opened;

  const String agent = 'agt_1';
  const String team = 'team-1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_exec_mount_');
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
    hub = StationHub(
      storePath: p.join(temp.path, 'config', 'stations.yaml'),
      heartbeatInterval: const Duration(milliseconds: 50),
      missThreshold: 3,
      livenessProbeInterval: const Duration(milliseconds: 10),
    );
    sent = <Map<String, dynamic>>[];
    stopped = <Map<String, dynamic>>[];
    compacted = <Map<String, dynamic>>[];
    opened = <ExecuteStationMounts>[];
  });

  tearDown(() async {
    for (final ExecuteStationMounts mounts in opened) {
      await mounts.close();
    }
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  /// 挂载位置：agent 的工作空间固定在临时目录；归属 / 模式可注入（验证隔离）。
  ExecuteStationMounts mounts({
    String agentTeam = team,
    String agentMode = StationModeKey.local,
    bool wired = true,
  }) {
    final ExecuteStationMounts built = ExecuteStationMounts(
      ioFor: (String agentId) async => LocalWorkspaceIO(workspace),
      agentTeamOf: (String agentId) => agentId == agent ? agentTeam : '',
      agentModeOf: (String agentId) => agentId == agent ? agentMode : '',
      messageSender: !wired
          ? null
          : ({
              required String agentId,
              required String sessionId,
              required String content,
              String sourcePluginId = '',
            }) async {
              sent.add(<String, dynamic>{
                'agent_id': agentId,
                'session_id': sessionId,
                'content': content,
                'plugin': sourcePluginId,
              });
              return <String, dynamic>{
                'success': true,
                'detail': <String, dynamic>{'target': agentId},
              };
            },
      agentStopper: !wired
          ? null
          : (String agentId, {required bool cascade}) async {
              stopped.add(<String, dynamic>{
                'agent_id': agentId,
                'cascade': cascade,
              });
              return <String, dynamic>{
                'cascade': cascade,
                'cascade_ids': <String>[agentId, 'child'],
                'cancelled': <String>[agentId],
                'idle': <String>['child'],
                'any_running': true,
              };
            },
      compactor: !wired
          ? null
          : (String agentId, String sessionId) async {
              compacted.add(<String, dynamic>{
                'agent_id': agentId,
                'session_id': sessionId,
              });
              return <String, dynamic>{'compressed': true, 'context_size': 42};
            },
    );
    opened.add(built);
    return built;
  }

  /// 把一份挂载位置接到**它自己那族的点位**上（点位化：执行站按命令族拆成 7 个
  /// 实例，`mountInto` 只挂 `station.commands`），返回「命令 → 所属点位」的解析器。
  _Wiring wiring(ExecuteStationMounts mounts) {
    for (final StationPointSpec spec in StationPoints.executes) {
      final ExecuteStation station = hub.executePointFor(spec.id)!;
      expect(
        mounts.mountInto(station),
        isNull,
        reason: '点位 ${spec.id} 的命令（${spec.commands.join('、')}）都应挂载成功',
      );
    }
    return _Wiring(hub);
  }

  StationScope scope({
    String teamId = team,
    String modeKey = StationModeKey.local,
  }) => StationScope(teamId: teamId, modeKey: modeKey);

  /// 跑一条执行站命令：命令自动落到**它所属的点位**，并默认带上 `agent_id`
  /// （点位不绑定 agent，目标由命令参数指定——与插件下命令的真实形状一致）。
  Future<StationCommandResult> run(
    _Wiring wiring,
    String command, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
    StationScope? scoped,
    String pluginId = 'sample',
  }) => wiring.point(command).execute(
    command: command,
    scope: scoped ?? scope(),
    arguments: <String, dynamic>{'agent_id': agent, ...arguments},
    sourcePluginId: pluginId,
  );

  test('九条命令各自挂到自己的点位（ui.push 由站点中枢挂载）', () {
    final _Wiring wired = wiring(mounts());
    // 每个点位只挂自己那族的命令：命令族之间互不干扰（点位化的直接收益）
    for (final StationPointSpec spec in StationPoints.executes) {
      expect(
        wired
            .point(spec.commands.first)
            .mounts()
            .map((StationCommandMount m) => m.command)
            .toSet(),
        spec.commands.toSet(),
        reason: '点位 ${spec.id} 只挂 ${spec.commands.join('、')}',
      );
    }
    expect(
      wired.point('fs.read').mounts(command: 'fs.read').single.mountId,
      'core.execute.fs.read',
    );
    expect(
      wired.point('ui.push').mounts(command: 'ui.push').single.mountId,
      'core.frontend.card',
    );
  });

  test('未挂载 / 白名单外都显式报错（不静默）', () async {
    final ExecuteStation bare = hub.executePointFor(StationHubIds.executeFs)!;
    final StationCommandResult noMount = await bare.execute(
      command: 'fs.read',
      scope: scope(),
      arguments: <String, dynamic>{'agent_id': agent},
    );
    expect(noMount.ok, isFalse);
    expect(noMount.error, contains('暂无挂载位置'));

    final _Wiring wired = wiring(mounts());
    // 白名单外的命令落在哪个点位都拒：这里用已接线的文件点位直接下命令
    final StationCommandResult denied = await wired
        .point('fs.read')
        .execute(
          command: 'shell.rm',
          scope: scope(),
          arguments: <String, dynamic>{'agent_id': agent},
          sourcePluginId: 'sample',
        );
    expect(denied.ok, isFalse);
    expect(denied.error, contains('不属于点位'));
    // 别的点位的命令也进不来（命令族隔离）
    final StationCommandResult crossFamily = await wired
        .point('fs.read')
        .execute(
          command: 'terminal.exec',
          scope: scope(),
          arguments: <String, dynamic>{'agent_id': agent},
          sourcePluginId: 'sample',
        );
    expect(crossFamily.ok, isFalse);
    expect(crossFamily.error, contains(StationHubIds.executeFs));
  });

  test(
    'fs.write → fs.read → fs.list → fs.grep：落到工作空间 IO（local/ssh 同抽象）',
    () async {
      final _Wiring wired = wiring(mounts());

      final StationCommandResult write = await run(
        wired,
        'fs.write',
        arguments: <String, dynamic>{
          'path': 'docs/a.txt',
          'content': '你好 tree\n第二行',
        },
      );
      expect(write.ok, isTrue, reason: write.error);
      final Map<String, dynamic> writePayload =
          write.payload! as Map<String, dynamic>;
      expect(writePayload['bytes_written'], greaterThan(0));
      expect(File(p.join(workspace, 'docs', 'a.txt')).existsSync(), isTrue);

      final StationCommandResult read = await run(
        wired,
        'fs.read',
        arguments: <String, dynamic>{'path': 'docs/a.txt'},
      );
      expect(read.ok, isTrue, reason: read.error);
      final Map<String, dynamic> readPayload =
          read.payload! as Map<String, dynamic>;
      expect(readPayload['content'], contains('你好 tree'));
      expect(readPayload['total_lines'], 2);
      expect(readPayload['mode_key'], StationModeKey.local);
      expect(readPayload['agent_id'], agent);

      final StationCommandResult list = await run(
        wired,
        'fs.list',
        arguments: <String, dynamic>{'path': 'docs'},
      );
      expect(list.ok, isTrue, reason: list.error);
      expect((list.payload! as Map<String, dynamic>)['entries'], isNotEmpty);

      final StationCommandResult grep = await run(
        wired,
        'fs.grep',
        arguments: <String, dynamic>{'pattern': 'tree'},
      );
      expect(grep.ok, isTrue, reason: grep.error);
      final Map<String, dynamic> grepPayload =
          grep.payload! as Map<String, dynamic>;
      expect(grepPayload['count'], greaterThanOrEqualTo(1));
      expect(
        (grepPayload['matches'] as List<dynamic>).first,
        containsPair('path', 'docs/a.txt'),
      );

      // 隐藏路径默认不搜（与内置 grep 同一默认口径）：include_hidden 才放行
      final StationCommandResult hiddenWrite = await run(
        wired,
        'fs.write',
        arguments: <String, dynamic>{
          'path': '.hidden/secret.txt',
          'content': 'tree hidden',
        },
      );
      expect(hiddenWrite.ok, isTrue, reason: hiddenWrite.error);
      final StationCommandResult defaultGrep = await run(
        wired,
        'fs.grep',
        arguments: <String, dynamic>{'pattern': 'tree'},
      );
      expect(
        (defaultGrep.payload! as Map<String, dynamic>)['count'],
        grepPayload['count'],
        reason: '隐藏目录里的命中不该出现在默认结果里',
      );
      final StationCommandResult hiddenGrep = await run(
        wired,
        'fs.grep',
        arguments: <String, dynamic>{'pattern': 'tree', 'include_hidden': true},
      );
      expect(
        ((hiddenGrep.payload! as Map<String, dynamic>)['matches']
                as List<dynamic>)
            .map((dynamic m) => (m as Map<String, dynamic>)['path']),
        contains('.hidden/secret.txt'),
      );
    },
  );

  test('terminal.exec 复用既有 terminal 工具路径（含 hook 模式语义）', () async {
    final _Wiring wired = wiring(mounts());

    final StationCommandResult echo = await run(
      wired,
      'terminal.exec',
      arguments: <String, dynamic>{'command': 'echo station-hello'},
    );
    expect(echo.ok, isTrue, reason: echo.error);
    final Map<String, dynamic> payload = echo.payload! as Map<String, dynamic>;
    expect(payload['text'], contains('退出码 0'));
    expect(payload['text'], contains('station-hello'));
    expect(payload['is_error'], isFalse);

    // hook=true：后台执行 + 返回 task_id + 可查询（与 terminal 工具同一实现）
    final StationCommandResult hook = await run(
      wired,
      'terminal.exec',
      arguments: <String, dynamic>{'command': 'echo hook-hello', 'hook': true},
    );
    expect(hook.ok, isTrue, reason: hook.error);
    final String text =
        (hook.payload! as Map<String, dynamic>)['text'] as String;
    expect(text, contains('[terminal hook]'));
    final RegExp taskId = RegExp(r'task_id: (\S+)');
    expect(taskId.firstMatch(text), isNotNull);
    final StationCommandResult status = await run(
      wired,
      'terminal.exec',
      arguments: <String, dynamic>{
        'hook_action': 'status',
        'task_id': taskId.firstMatch(text)!.group(1),
      },
    );
    expect(status.ok, isTrue, reason: status.error);
  });

  test('terminal.exec 用注入的 hooks（任务落在注入实例里）；close 不关注入实例', () async {
    // CLI 的接线形状：注入工具层那一份 hooks ⇒ 插件命令与 agent 工具调用同一张任务表
    final TerminalHooks shared = TerminalHooks();
    addTearDown(shared.close);
    final ExecuteStationMounts withSharedHooks = ExecuteStationMounts(
      ioFor: (String agentId) async => LocalWorkspaceIO(workspace),
      agentTeamOf: (String agentId) => agentId == agent ? team : '',
      agentModeOf: (String agentId) =>
          agentId == agent ? StationModeKey.local : '',
      hooks: shared,
    );
    opened.add(withSharedHooks);
    final _Wiring wired = wiring(withSharedHooks);

    final StationCommandResult hook = await run(
      wired,
      'terminal.exec',
      arguments: <String, dynamic>{'command': 'echo shared-hook', 'hook': true},
    );
    expect(hook.ok, isTrue, reason: hook.error);
    expect(shared.tasks, hasLength(1), reason: '任务必须落在注入实例里（与工具层同一张表）');
    final HookTask task = shared.tasks.single;
    expect(task.agentId, agent);
    expect(task.command, contains('shared-hook'));

    // 注入实例归注入方所有：挂载位置 close 不得清空它的任务表（也不得关它）
    await withSharedHooks.close();
    expect(shared.task(task.id), isNotNull, reason: 'close 不得清空外部注入的实例');
    expect(shared.tasks, hasLength(1));
  });

  test('隔离：跨 team / 跨模式 / agent 不一致一律拒绝，且不动工作空间', () async {
    // 点位化后 mode 只在**命令 scope** 上：同一个文件操作点位服务 local / ssh
    // （挂载位置自己按 scope 判跨模式，见下 ③）。
    final _Wiring wired = wiring(mounts());

    // ① scope 里带了某个 agent，而命令点名了另一个 agent（跨 scope）
    final StationScope boundScope = StationScope(
      teamId: team,
      agentId: 'agt_2',
      modeKey: StationModeKey.local,
    );
    final StationCommandResult crossAgent = await run(
      wired,
      'fs.write',
      arguments: <String, dynamic>{
        'agent_id': agent,
        'path': 'x.txt',
        'content': 'x',
      },
      scoped: boundScope,
    );
    expect(crossAgent.ok, isFalse);
    expect(crossAgent.error, contains('跨 scope'));

    // ② scope 的 agent 与目标 agent 声明的团队不一致（跨 team）
    final StationCommandResult crossTeam = await run(
      wired,
      'fs.write',
      arguments: <String, dynamic>{'path': 'y.txt', 'content': 'y'},
      scoped: scope(teamId: 'team-2'),
    );
    expect(crossTeam.ok, isFalse);
    expect(crossTeam.error, contains('跨 team'));

    // ③ 模式不一致：SSH scope 的命令不许打到本地工作空间（plan §1.2 红线）
    final StationCommandResult crossMode = await run(
      wired,
      'fs.write',
      arguments: <String, dynamic>{'path': 'z.txt', 'content': 'z'},
      scoped: scope(modeKey: StationModeKey.ssh),
    );
    expect(crossMode.ok, isFalse);
    expect(crossMode.error, contains('跨模式'));
    expect(crossMode.error, contains('本地工作空间'));

    // ④ 归属证明不了（agent 不存在）⇒ 也拒绝
    final StationCommandResult unknown = await run(
      wired,
      'fs.read',
      arguments: <String, dynamic>{'path': 'a.txt', 'agent_id': 'ghost'},
    );
    expect(unknown.ok, isFalse);
    expect(unknown.error, contains('拒绝执行'));

    expect(File(p.join(workspace, 'x.txt')).existsSync(), isFalse);
    expect(File(p.join(workspace, 'z.txt')).existsSync(), isFalse);
  });

  test('路径越界与缺参数都是可读错误（不静默、不写盘）', () async {
    final _Wiring wired = wiring(mounts());
    final StationCommandResult escape = await run(
      wired,
      'fs.read',
      arguments: <String, dynamic>{'path': '../escape.txt'},
    );
    expect(escape.ok, isFalse);
    expect(escape.error, contains('路径非法'));

    for (final (String command, Map<String, dynamic> args)
        in <(String, Map<String, dynamic>)>[
          ('fs.read', <String, dynamic>{}),
          ('fs.write', <String, dynamic>{'path': 'a.txt'}),
          ('fs.grep', <String, dynamic>{}),
          ('terminal.exec', <String, dynamic>{}),
          ('agent.message', <String, dynamic>{}),
        ]) {
      final StationCommandResult result = await run(
        wired,
        command,
        arguments: args,
      );
      expect(result.ok, isFalse, reason: '$command 缺参数必须显式失败');
      expect(result.error, isNotEmpty, reason: '$command 必须给可读原因');
    }
  });

  test('agent.message / agent.stop / agent.compact 落到既有会话路径', () async {
    final _Wiring wired = wiring(mounts());

    final StationCommandResult message = await run(
      wired,
      'agent.message',
      arguments: <String, dynamic>{
        'message': '插件派活：做 A',
        'session_id': 'ses_9',
      },
    );
    expect(message.ok, isTrue, reason: message.error);
    expect(sent.single['agent_id'], agent);
    expect(sent.single['session_id'], 'ses_9');
    expect(sent.single['content'], '插件派活：做 A');
    expect(sent.single['plugin'], 'sample');

    // cascade 缺省 = true（与核心既有 stop 语义一致）
    final StationCommandResult stop = await run(wired, 'agent.stop');
    expect(stop.ok, isTrue, reason: stop.error);
    expect(stopped.single['cascade'], isTrue);
    expect((stop.payload! as Map<String, dynamic>)['any_running'], isTrue);

    final StationCommandResult stopOne = await run(
      wired,
      'agent.stop',
      arguments: <String, dynamic>{'cascade': false},
    );
    expect(stopOne.ok, isTrue);
    expect(stopped.last['cascade'], isFalse);

    final StationCommandResult compact = await run(wired, 'agent.compact');
    expect(compact.ok, isTrue, reason: compact.error);
    expect(compacted.single['agent_id'], agent);
    expect(compacted.single['session_id'], isNotEmpty);
    expect((compact.payload! as Map<String, dynamic>)['compressed'], isTrue);
  });

  test('会话侧依赖未接线时显式报「未接线」（不静默成功）', () async {
    final _Wiring wired = wiring(mounts(wired: false));
    final StationCommandResult message = await run(
      wired,
      'agent.message',
      arguments: <String, dynamic>{'message': 'x'},
    );
    expect(message.ok, isFalse);
    expect(message.error, contains('未接线'));
    final StationCommandResult stop = await run(wired, 'agent.stop');
    expect(stop.ok, isFalse);
    expect(stop.error, contains('未接线'));
    final StationCommandResult compact = await run(wired, 'agent.compact');
    expect(compact.ok, isFalse);
    expect(compact.error, contains('未接线'));
  });

  test('会话接口报错时原样回到调用方（不吞错）', () async {
    final ExecuteStationMounts failing = ExecuteStationMounts(
      ioFor: (String agentId) async => LocalWorkspaceIO(workspace),
      agentTeamOf: (String agentId) => agentId == agent ? team : '',
      agentModeOf: (String agentId) =>
          agentId == agent ? StationModeKey.local : '',
      messageSender: ({
        required String agentId,
        required String sessionId,
        required String content,
        String sourcePluginId = '',
      }) async => <String, dynamic>{'error': '成员未就绪：尚未分配模型'},
      agentStopper: (String agentId, {required bool cascade}) async =>
          <String, dynamic>{'error': 'agent 不存在'},
      compactor: (String agentId, String sessionId) async => <String, dynamic>{
        'error': 'agent 正在生成：压缩会改写上下文',
      },
    );
    opened.add(failing);
    final _Wiring wired = wiring(failing);
    final StationCommandResult message = await run(
      wired,
      'agent.message',
      arguments: <String, dynamic>{'message': 'x'},
    );
    expect(message.ok, isFalse);
    expect(message.error, contains('尚未分配模型'));
    final StationCommandResult stop = await run(wired, 'agent.stop');
    expect(stop.ok, isFalse);
    expect(stop.error, contains('agent 不存在'));
    final StationCommandResult compact = await run(wired, 'agent.compact');
    expect(compact.ok, isFalse);
    expect(compact.error, contains('正在生成'));
  });

  test('没有在途任务时 agent.stop 也显式回话（不静默）', () async {
    final _Wiring wired = wiring(
      ExecuteStationMounts(
        ioFor: (String agentId) async => LocalWorkspaceIO(workspace),
        agentTeamOf: (String agentId) => agentId == agent ? team : '',
        agentModeOf: (String agentId) =>
            agentId == agent ? StationModeKey.local : '',
        agentStopper: (String agentId, {required bool cascade}) async =>
            <String, dynamic>{
              'cascade': cascade,
              'cascade_ids': <String>[agentId],
              'cancelled': <String>[],
              'idle': <String>[agentId],
              'any_running': false,
            },
      ),
    );
    final StationCommandResult stop = await run(wired, 'agent.stop');
    expect(stop.ok, isTrue);
    final Map<String, dynamic> payload = stop.payload! as Map<String, dynamic>;
    expect(payload['any_running'], isFalse);
    expect(payload['reason'], contains('没有进行中的任务'));
  });
}

/// 一次接线的结果：**命令 → 所属执行站点位**。
///
/// 点位化后执行站按命令族拆成 7 个独立实例，一条命令只属于一个点位；这里用
/// [StationHub.executeForCommand]（= 核心 `station/command` 的分发依据）解析，
/// 用例因此不必知道"这条命令该挂在哪个点位"（点位表挪动时用例不用改）。
class _Wiring {
  _Wiring(this._hub);

  final StationHub _hub;

  ExecuteStation point(String command) => _hub.executeForCommand(command)!;
}
