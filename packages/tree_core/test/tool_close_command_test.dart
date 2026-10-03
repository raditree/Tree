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
import 'package:tree_local_exec/tree_local_exec.dart';

/// **执行站命令 `tool.close`**（2026-10-03，plan `20261003-running-tools` §4 步骤 8 / §10 D5）。
///
/// 病根：工具执行没有静态上限，一条不返回的命令让整个工具批永不结束 ⇒ teammate 永久失联
/// （`.self/recon-arch-stability.md` §2.7）。关闭是**唯一**的显式终止路径（停止键的语义
/// 一个字都没改），因此这里的语义必须**可读地失败**、绝不静默降级：
/// - 核心没注入关闭器 ⇒ 显式报「未接线」；
/// - 句柄缺失 / 失效 ⇒ 显式失败（fail-closed）+ 可读原因，不假装成功。
///
/// 关闭器（[StationToolCloser]）是可注入字段，所以这里注入**假关闭器**：
/// 命令层的语义与真实 `ToolRunRegistry.close` / 进程树终止无关（那两处各自有测试）。
void main() {
  late Directory temp;
  late String workspace;
  late StationHub hub;
  late List<ExecuteStationMounts> opened;
  late List<String> closeCalls;

  const String agent = 'agt_1';
  const String team = 'team-1';
  const String handle = 'toolrun_1234_abcd_1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_tool_close_cmd_');
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
    hub = StationHub(
      storePath: p.join(temp.path, 'config', 'stations.yaml'),
      heartbeatInterval: const Duration(milliseconds: 50),
      missThreshold: 3,
      livenessProbeInterval: const Duration(milliseconds: 10),
    );
    opened = <ExecuteStationMounts>[];
    closeCalls = <String>[];
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

  /// 挂载位置：工作空间固定在临时目录；归属 / 模式可注入；`tool.close` 的关闭器可注入。
  ///
  /// 假关闭器的返回形状与生产实现（`ToolRunRegistry.close` 的 `ToolCloseOutcome.toJson`）
  /// 逐键一致：`closed` / `tool` / `elapsed_ms` / `note`；句柄失效 ⇒ `{error: 可读原因}`。
  ExecuteStationMounts mounts({bool wired = true}) {
    final ExecuteStationMounts built = ExecuteStationMounts(
      ioFor: (String agentId) async => LocalWorkspaceIO(workspace),
      agentTeamOf: (String agentId) => agentId == agent ? team : '',
      agentModeOf: (String agentId) =>
          agentId == agent ? StationModeKey.local : '',
      toolCloser: !wired
          ? null
          : (String toolHandle) async {
              closeCalls.add(toolHandle);
              if (toolHandle == 'toolrun_missing_zzzz_9') {
                // 与 `ToolCloseOutcome.missing` 同口径：句柄失效是可读原因，不是异常
                return <String, dynamic>{
                  'error':
                      '该句柄已失效（toolrun_missing_zzzz_9）：'
                      '登记表是**纯内存**的——核心重启会清空它，这次运行结束（工具返回）后句柄同样失效。',
                };
              }
              return <String, dynamic>{
                'closed': true,
                'tool': 'terminal',
                'elapsed_ms': 1234,
                'note': '已终止本机进程树（task_id=hook_x）',
              };
            },
    );
    opened.add(built);
    return built;
  }

  /// 把挂载位置接到**它自己那族的点位**上，并返回「命令 → 所属点位」的解析器。
  ExecuteStation point(String command) {
    final StationPointSpec spec = StationPoints.ownerOfCommand(command)!;
    final ExecuteStation station = hub.executePointFor(spec.id)!;
    expect(
      hub.executeForCommand(command),
      isNotNull,
      reason: '命令 $command 必须属于某个执行站点位',
    );
    return station;
  }

  void wire(ExecuteStationMounts mounts) {
    for (final StationPointSpec spec in StationPoints.executes) {
      final ExecuteStation station = hub.executePointFor(spec.id)!;
      expect(
        mounts.mountInto(station),
        isNull,
        reason: '点位 ${spec.id}（${spec.commands.join('、')}）都应挂载成功',
      );
    }
  }

  StationScope scope({
    String teamId = team,
    String agentId = '',
    String modeKey = StationModeKey.local,
  }) => StationScope(teamId: teamId, agentId: agentId, modeKey: modeKey);

  /// 跑一条命令（命令自动落到它所属的点位；默认带上目标 agent）。
  Future<StationCommandResult> run(
    String command, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
    StationScope? scoped,
    String pluginId = 'sample',
  }) => point(command).execute(
    command: command,
    scope: scoped ?? scope(),
    arguments: <String, dynamic>{'agent_id': agent, ...arguments},
    sourcePluginId: pluginId,
  );

  // ── 白名单已登记 ─────────────────────────────────────────────────────

  test('tool.close 已在执行站命令白名单里（否则 _handle 复核会直接拒绝）', () {
    expect(
      StationPoints.ownerOfCommand('tool.close')?.id,
      StationHubIds.executeTool,
      reason: 'tool.close 必须挂在 tool.call 同一点位上（白名单复核依据）',
    );
  });

  // ── 未接线 / 入参 ────────────────────────────────────────────────────

  test('未接线：toolCloser == null 时显式失败（error 含「未接线」，不静默降级）', () async {
    wire(mounts(wired: false));

    final StationCommandResult result = await run(
      'tool.close',
      arguments: <String, dynamic>{'handle': handle},
    );
    expect(result.ok, isFalse, reason: '未接线必须显式失败，而不是假装关掉了');
    expect(result.error, contains('未接线'), reason: result.error);
    expect(
      result.mountId,
      contains('core.execute'),
      reason: '失败发生在挂载位置内部（命令确实被路由到了）',
    );
    expect(closeCalls, isEmpty, reason: '没接线就不该有任何关闭调用');
  });

  test('缺 / 空 handle：显式失败且原因含 handle（不落到关闭器）', () async {
    wire(mounts());

    for (final Object? empty in <Object?>[null, '', '   ']) {
      final Map<String, dynamic> arguments = empty == null
          ? const <String, dynamic>{}
          : <String, dynamic>{'handle': empty};
      final StationCommandResult result = await run(
        'tool.close',
        arguments: arguments,
      );
      expect(
        result.ok,
        isFalse,
        reason: '空 handle 必须显式失败（收到 ${empty.runtimeType}）',
      );
      expect(result.error, contains('handle'), reason: result.error);
    }
    expect(closeCalls, isEmpty, reason: '被拒的命令不得落到关闭器');
  });

  // ── 成功路径 ─────────────────────────────────────────────────────────

  test('成功路径：关闭器载荷原样透传 + 补 agent_id 归属字段', () async {
    wire(mounts());

    final StationCommandResult result = await run(
      'tool.close',
      arguments: <String, dynamic>{'handle': handle},
    );
    expect(result.ok, isTrue, reason: result.error);
    expect(result.mountId, 'core.execute.tool.close');
    expect(closeCalls, <String>[handle], reason: 'handle 原样交给关闭器（由它判有效性）');

    final Map<String, dynamic> payload =
        result.payload! as Map<String, dynamic>;
    // 冻结键（plan §10 D5）：closed / tool / elapsed_ms / note
    expect(payload['closed'], isTrue);
    expect(payload['tool'], 'terminal');
    expect(payload['elapsed_ms'], 1234);
    expect(payload['note'], isNotEmpty);
    expect(payload['note'], contains('task_id=hook_x'));
    // 与同文件其它命令一致：补一个归属字段
    expect(payload['agent_id'], agent);
    expect(result.error, isEmpty);
  });

  // ── fail-closed ──────────────────────────────────────────────────────

  test('句柄失效：关闭器给 error ⇒ 命令失败且原因就是那句话（fail-closed）', () async {
    wire(mounts());

    const String reason = '该句柄已失效（toolrun_missing_zzzz_9）：登记表是**纯内存**的';
    final StationCommandResult result = await run(
      'tool.close',
      arguments: <String, dynamic>{'handle': 'toolrun_missing_zzzz_9'},
    );
    expect(result.ok, isFalse, reason: '句柄失效绝不能伪装成"关掉了"');
    expect(result.error, startsWith(reason));
    expect(result.payload, isNull);
    expect(closeCalls, <String>['toolrun_missing_zzzz_9']);
  });

  // ── 与 tool.call 同点位（命令族归属） ────────────────────────────────

  test('tool.close 与 tool.call 属同一点位，且点位只挂这两条命令', () {
    wire(mounts());
    expect(point('tool.close').id, StationHubIds.executeTool);
    expect(
      point('tool.close').mounts().map((StationCommandMount m) => m.command),
      <String>['tool.call', 'tool.close'],
      reason: '执行站 tool 点位挂自己那族的命令',
    );
  });
}
