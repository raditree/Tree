import '../store/records.dart';

/// 团队规模上限（与参考实现一致：默认 3 层 / 每层 7 人，硬上限 5 / 100）。
///
/// 为什么夹紧而不是报错：规模来自用户手改的 `agents/<id>.yaml`，手写值非法时
/// 应落到默认值继续可用，而不是让整个团队功能瘫痪。
abstract final class TeamLimits {
  static const int defaultMaxLevel = 3;
  static const int defaultMaxMembersPerLevel = 7;
  static const int hardMaxLevel = 5;
  static const int hardMaxMembers = 100;

  /// 归一化层级上限（非法/<=0 → 默认；> 硬上限 → 硬上限）。
  static int level(Object? raw) {
    final int value = raw is num
        ? raw.toInt()
        : int.tryParse('${raw ?? ''}') ?? 0;
    if (value <= 0) return defaultMaxLevel;
    return value > hardMaxLevel ? hardMaxLevel : value;
  }

  /// 归一化每层成员上限。
  static int members(Object? raw) {
    final int value = raw is num
        ? raw.toInt()
        : int.tryParse('${raw ?? ''}') ?? 0;
    if (value <= 0) return defaultMaxMembersPerLevel;
    return value > hardMaxMembers ? hardMaxMembers : value;
  }
}

/// 成员审核状态（权威 4 态）。
///
/// `pending_model` / `pending_review` 都需要**用户**在「团队成员 → 模型配置」页
/// 处理；leader agent 无权代替（见 team 工具的 model_id 禁令）。
abstract final class ReviewStatus {
  /// 已创建但还没分配模型。
  static const String pendingModel = 'pending_model';

  /// 已分配模型但用户还没审核。
  static const String pendingReview = 'pending_review';

  /// 已通过审核：可以接收并执行消息。
  static const String approved = 'approved';

  /// 已被用户驳回：不接收任何消息。
  static const String rejected = 'rejected';

  static const List<String> all = <String>[
    pendingModel,
    pendingReview,
    approved,
    rejected,
  ];

  /// 是否需要用户处理（前端红点口径）。
  static bool needsUser(String status) =>
      status == pendingModel || status == pendingReview;

  static bool isValid(String status) => all.contains(status);

  /// 由"是否已分配模型"推导：新建成员恒无模型 → [pendingModel]。
  static String fromModelId(String modelId) =>
      modelId.trim().isEmpty ? pendingModel : approved;
}

/// 成员级模型参数覆盖的键名（与前端 model_info_panel / teammates_window 一致）。
abstract final class MemberOverrideKeys {
  static const String reasoningEffort = 'reasoning_effort';
  static const String maxSeqlen = 'max_seqlen';
  static const String maxOutputTokens = 'max_output_tokens';
  static const String compressThreshold = 'compress_threshold';

  static const List<String> all = <String>[
    reasoningEffort,
    maxSeqlen,
    maxOutputTokens,
    compressThreshold,
  ];
}

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
};
