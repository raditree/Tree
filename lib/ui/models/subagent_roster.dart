/// 一条**临时员工名册**记录（`GET /api/agents/{agentId}/subagents` 的一项）。
///
/// 为什么前端要单独认识这个形状（用户 2026-10-03「进入某个临时成员的选项经常会无端
/// 变化」）：入口以前只能从"当前已加载的消息窗口"里猜，窗口化只热视口附近
/// （`lib/README.md` 不变量 19），消息一被淘汰入口就凭空消失。名册本身**早就落盘**
/// （`data/<agentId>/<sessionId>/subagents.json`，`store/README.md` 不变量 11）——
/// 这份模型就是它的只读视图：**身份信息**（名字 / 层级 / 谁召来的）来自这里，
/// 过程消息仍然只从消息流里来。
///
/// **跨会话不保留**：名册是会话级的，切 agent / 换会话一律重新拉（见
/// `SubagentTranscript.clear`）。
class SubagentRosterEntry {
  const SubagentRosterEntry({
    required this.id,
    required this.name,
    required this.parentId,
    required this.level,
    this.ownerAgentId = '',
    this.scope = '',
    this.runCount = 0,
  });

  /// 临时员工 id（`sub_…`）。
  final String id;

  /// 显示名（缺省「临时员工」）。
  final String name;

  /// 召它的那个 agent：真实 agent id 或**上级临时员工** id。
  final String parentId;

  /// 会话内树层级（真实 agent 的直属临时员工 = 1）。
  final int level;

  /// 会话主人（真实 agent id）。
  final String ownerAgentId;

  /// 被召来时的职责/范围摘要（名册原样带出来的，界面暂未渲染）。
  final String scope;

  /// 被跑过多少轮（含复用）。
  final int runCount;

  /// 从核心的响应项解析（脏数据退默认值，**不抛**——一条坏记录不该让整个下拉空掉）。
  factory SubagentRosterEntry.fromJson(Map<String, dynamic> json) {
    return SubagentRosterEntry(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      parentId: json['parent_id'] as String? ?? '',
      level: (json['level'] as num?)?.toInt() ?? 1,
      ownerAgentId: json['owner_agent_id'] as String? ?? '',
      scope: json['scope'] as String? ?? '',
      runCount: (json['run_count'] as num?)?.toInt() ?? 0,
    );
  }
}
