import '../store/records.dart';

/// 成员相对**查询者**的关系（前端分组与提示用）。
abstract final class MemberRelation {
  static const String teamLeader = 'team_leader';
  static const String direct = 'direct';
  static const String peer = 'peer';
  static const String indirect = 'indirect';
}

/// 成员活动日志路径（工作空间相对路径；leader 用 read/grep 查看产出）。
String memberLogPath(String memberId) => '.self/activity.log';

/// 对外成员视图。
///
/// **白名单**：绝不包含 `system_prompt`（名单接口会把提示词泄漏给整棵树）；
/// 只有 `query_member` / `update_member` 才额外返回它。
Map<String, dynamic> memberView(
  CoreAgent member, {
  required String leaderName,
  required String relation,
  required String workStatus,
}) => <String, dynamic>{
  'id': member.id,
  'name': member.name,
  'role': member.role,
  'duty': member.duty,
  'model_id': member.modelId,
  'level': member.level,
  'can_lead_team': member.canLeadTeam,
  'parent_agent_id': member.parentAgentId,
  'leader_name': leaderName,
  'relation': relation,
  'work_status': workStatus,
  'review_status': member.reviewStatus,
  'log_path': memberLogPath(member.id),
  'created_at': member.createdAt,
  'workspace_id': member.workspaceId,
};

/// 成员级覆盖（只含真正设置过的键；前端按 key 缺省不修改）。
Map<String, Object?> memberOverrides(CoreAgent member) => <String, Object?>{
  if (member.reasoningEffort.trim().isNotEmpty)
    MemberOverrideKeys.reasoningEffort: member.reasoningEffort,
  if (member.maxSeqlenOverride > 0)
    MemberOverrideKeys.maxSeqlen: member.maxSeqlenOverride,
  if (member.maxOutputTokens > 0)
    MemberOverrideKeys.maxOutputTokens: member.maxOutputTokens,
  if (member.compressThreshold > 0)
    MemberOverrideKeys.compressThreshold: member.compressThreshold,
  if (member.thinkingOverride != null)
    MemberOverrideKeys.thinking: member.thinkingOverride,
};
