import '../store/tree_store.dart';
import '../team/team_service.dart';
import 'subagent_tool.dart';
import 'tool_run_registry.dart';
import 'tool_runs_tool.dart';

/// `tool_runs` 的**生产落点**：作用域来自**既有的关系**，关闭落到**同一个** closer。
///
/// 两条口径都是"复用"而不是"另造"：
/// 1. **谁是我的直属下级**：
///    - 团队成员：`TeamService.directMembers`——`parent_agent_id == 我`，与广播
///      （`message broadcast` 只发直属）、派发、级联停止是**同一份**判据；
///    - 临时员工：`SubagentChannel.directSubagentsOf`——名册里既有的 `parentId`
///      关系（与 `privateOwnerOf` / 复用解析同一份），它按会话分栏，所以只认**本会话**的；
///    - **只收直属**：隔代下级由它的直接上级去管（契约"自己 + 直属下级"）。
/// 2. **关闭**：[ToolRunRegistry.close]——右栏「正在执行的 tool」的关闭按钮走的 REST
///    (`POST /api/tools/running/{handle}/close`) 与执行站 `tool.close` 都是它；
///    本类只做"归属校验"，真正的终止 / 收敛 / 登记表移除全在那一份实现里。
///
/// 因此这里**没有**第二套关闭语义、也没有第二套"下级"定义。
class ToolRunsScope implements ToolRunsChannel {
  ToolRunsScope({required this.registry, this.teamService, this.subagents});

  /// **进程级唯一那一份**登记表（生产 = `WorkspaceToolRunner.toolRuns`）。
  final ToolRunRegistry registry;

  /// 团队关系（可为 null：没有团队服务时只看得见自己，不算未接线）。
  final TeamService? teamService;

  /// 临时员工名册（可为 null：没有它时只看团队那一路）。
  final SubagentChannel? subagents;

  @override
  Duration get threshold => registry.threshold;

  @override
  List<ToolRun> listVisible({
    required String agentId,
    required String sessionId,
  }) {
    final Set<String> scope = _scopeIds(agentId, sessionId);
    return registry
        .list()
        .where((ToolRun run) => scope.contains(run.agentId))
        .toList(growable: false);
  }

  @override
  Future<ToolCloseOutcome> closeVisible({
    required String agentId,
    required String sessionId,
    required String handle,
    String memberId = '',
  }) async {
    final String key = handle.trim();
    final ToolRun? run = _find(key);
    if (run == null) {
      // 句柄失效（不存在 / 核心重启过 / 这次运行早已结束）：交给**同一个** closer
      // 回它那句可读原因（"登记表是纯内存的……"），不在这里另写一份文案。
      return registry.close(key);
    }
    final Set<String> scope = _scopeIds(agentId, sessionId);
    if (!scope.contains(run.agentId)) {
      return ToolCloseOutcome.denied(
        '这条运行不属于你或你的直属下级，拒绝关闭：handle=$key 的 '
        'agent_id=${run.agentId}（session_id=${run.sessionId}，tool=${run.tool}）。'
        '你只能关自己（$agentId）与其直属下级的运行；别人的运行由它自己、它的上级'
        '或用户/插件显式关闭。',
      );
    }
    final String expected = memberId.trim();
    if (expected.isNotEmpty && expected != run.agentId) {
      return ToolCloseOutcome.denied(
        'member_id=$expected 与这条运行的 agent_id=${run.agentId} 不符：'
        '请核对 handle（可能抄到了别的下级的运行）。',
      );
    }
    return registry.close(key);
  }

  ToolRun? _find(String handle) {
    if (handle.isEmpty) return null;
    for (final ToolRun run in registry.list()) {
      if (run.handle == handle) return run;
    }
    return null;
  }

  /// 本 agent 自己 + 其**直属**下级（判据全部来自既有关系，见类文档）。
  Set<String> _scopeIds(String agentId, String sessionId) {
    final Set<String> ids = <String>{agentId};
    final TeamService? team = teamService;
    if (team != null) {
      for (final CoreAgent member in team.directMembers(agentId)) {
        ids.add(member.id);
      }
    }
    final SubagentChannel? subs = subagents;
    if (subs != null) {
      for (final SubagentTag tag in subs.directSubagentsOf(agentId, sessionId)) {
        ids.add(tag.id);
      }
    }
    return ids;
  }
}
