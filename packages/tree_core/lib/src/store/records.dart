import '../settings/ssh_config.dart';
import '../util/ids.dart';
import '../util/json_time.dart';

/// 存储层的三个记录类型：agent / 会话 / 消息。
///
/// 每个记录都有两种形态，并由各自的序列化方法承载：
/// - **持久化形态**（`toJson` / `fromJson`）：键名与值类型即磁盘上的样子。
///   agent 与 session 写 YAML、消息写 JSONL，但两者共用同一套键，因此同一份
///   `toJson` 既能 `jsonEncode`（消息）也能交给 `YamlCodec.encode`（配置）。
/// - **前端形态**（`toApiJson`）：与既有后端 REST 响应字段完全一致，
///   `lib/ui` 因此零改动。时间在前端形态用毫秒整数（`ChatSession.fromJson`
///   要求 int），在持久化形态用 ISO 字符串（便于人读与手改）。

/// agent 记录（现状 server `agents` 表的桌面替身）。
class CoreAgent {
  CoreAgent({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.systemPrompt = '',
    this.modelId = '',
    this.workspaceId = '',
    this.workspaceDir = '',
    this.sshConfig,
    this.teamMemberCount = 0,
    this.maxLevel = 3,
    this.maxMembersPerLevel = 7,
    this.teamId = '',
    this.parentAgentId = '',
    this.level = 0,
    this.role = '',
    this.duty = '',
    this.canLeadTeam = true,
    this.reviewStatus = '',
    this.comment = '',
    Map<String, double>? scores,
    this.reasoningEffort = '',
    this.maxSeqlenOverride = 0,
    this.maxOutputTokens = 0,
    this.compressThreshold = 0,
  }) : scores = scores ?? <String, double>{};

  final String id;
  String name;
  String systemPrompt;
  String modelId;
  String workspaceId;

  /// agent 的工作空间目录（绝对路径）。
  ///
  /// 空串 = 未指定，由工具层落到默认位置 `<数据根>/workspaces/<agent_id>`。
  /// 用户可以直接手改 `agents/<id>.yaml` 的 `workspace_dir` 指向自己的项目目录
  /// —— 这是"绕开 UI 直接改配置"的关键入口。
  String workspaceDir;

  /// SSH 执行配置（非空 = 该 agent 的工具跑在远端主机上）。
  ///
  /// 用户可以直接手写 `agents/<id>.yaml` 的 `ssh:` 段接入远端，无需任何 UI。
  SshConfig? sshConfig;
  int teamMemberCount;

  /// 每层最大层级（创建 TOP 时设定；0/负数按 [TeamLimits.defaultMaxLevel]）。
  int maxLevel;

  /// 每层最大直属成员数（0/负数按 [TeamLimits.defaultMaxMembersPerLevel]）。
  int maxMembersPerLevel;

  // ── 团队（M5b）：成员就是 agent，团队字段直接写进 `agents/<id>.yaml` ────

  /// 所属团队（= TOP agent 的 id）。TOP 自身为空串。
  String teamId;

  /// 直属上级（TOP 的直属成员为 TOP 的 id）。TOP 自身为空串。
  String parentAgentId;

  /// 层级：TOP = 0，成员 = 上级 + 1。
  int level;

  /// 角色 / 职责（leader 分工用）。
  String role;
  String duty;

  /// 是否允许再建子团队。
  bool canLeadTeam;

  /// 审核状态（[ReviewStatus]）；TOP 为空串（不适用）。
  String reviewStatus;

  /// leader 评价。
  String comment;

  /// 评分（quality / efficiency / collaboration / accuracy，0~10）。
  Map<String, double> scores;

  // ── 成员级模型参数覆盖（M5b）：0 / 空串 = 未覆盖，回退 TOP 的模型配置 ──

  String reasoningEffort;
  int maxSeqlenOverride;
  int maxOutputTokens;
  double compressThreshold;

  final int createdAt;
  int updatedAt;

  /// 是否为团队成员（TOP 不在成员名单里）。
  bool get isMember => teamId.isNotEmpty;

  /// 是否已通过用户审核、可以接收并执行消息。
  bool get isApproved => reviewStatus == ReviewStatus.approved;

  /// 持久化形态（`agents/<id>.yaml`）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'system_prompt': systemPrompt,
    'model_id': modelId,
    'workspace_id': workspaceId,
    'workspace_dir': workspaceDir,
    if (sshConfig != null) 'ssh': sshConfig!.toJson(),
    'team_member_count': teamMemberCount,
    'max_level': maxLevel,
    'max_members_per_level': maxMembersPerLevel,
    'team_id': teamId,
    'parent_agent_id': parentAgentId,
    'level': level,
    'role': role,
    'duty': duty,
    'can_lead_team': canLeadTeam,
    'review_status': reviewStatus,
    'comment': comment,
    'scores': scores,
    'reasoning_effort': reasoningEffort,
    'max_seqlen_override': maxSeqlenOverride,
    'max_output_tokens': maxOutputTokens,
    'compress_threshold': compressThreshold,
    'created_at': JsonTime.encode(createdAt),
    'updated_at': JsonTime.encode(updatedAt),
  };

  /// 从持久化形态或前端形态还原（字段名一致，仅时间表示不同）。
  static CoreAgent fromJson(Map<String, dynamic> json) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return CoreAgent(
      id: json['id'] as String? ?? CoreIds.agent(),
      name: json['name'] as String? ?? '',
      systemPrompt: json['system_prompt'] as String? ?? '',
      modelId: json['model_id'] as String? ?? '',
      workspaceId: json['workspace_id'] as String? ?? '',
      workspaceDir: json['workspace_dir'] as String? ?? '',
      sshConfig: SshConfig.parse(json['ssh']),
      teamMemberCount: (json['team_member_count'] as num?)?.toInt() ?? 0,
      maxLevel:
          (json['max_level'] as num?)?.toInt() ?? TeamLimits.defaultMaxLevel,
      maxMembersPerLevel:
          (json['max_members_per_level'] as num?)?.toInt() ??
          TeamLimits.defaultMaxMembersPerLevel,
      teamId: json['team_id'] as String? ?? '',
      parentAgentId: json['parent_agent_id'] as String? ?? '',
      level: (json['level'] as num?)?.toInt() ?? 0,
      role: json['role'] as String? ?? '',
      duty: json['duty'] as String? ?? '',
      canLeadTeam: json['can_lead_team'] as bool? ?? true,
      reviewStatus: json['review_status'] as String? ?? '',
      comment: json['comment'] as String? ?? '',
      scores: _scoreMap(json['scores']),
      reasoningEffort: json['reasoning_effort'] as String? ?? '',
      maxSeqlenOverride: (json['max_seqlen_override'] as num?)?.toInt() ?? 0,
      maxOutputTokens: (json['max_output_tokens'] as num?)?.toInt() ?? 0,
      compressThreshold: (json['compress_threshold'] as num?)?.toDouble() ?? 0,
      createdAt: JsonTime.decode(json['created_at']) ?? now,
      updatedAt: JsonTime.decode(json['updated_at']) ?? now,
    );
  }

  /// 前端形态（`GET /api/agents` 列表项与创建响应）。
  Map<String, dynamic> toApiJson({
    String lastMessage = '',
    int? lastMessageTime,
    int unreadCount = 0,
    int pendingMemberCount = 0,
  }) => <String, dynamic>{
    'id': id,
    'name': name,
    'type': 'normal',
    'system_prompt': systemPrompt,
    'model_id': modelId,
    'workspace_id': workspaceId,
    'workspace_dir': workspaceDir,
    // 只暴露"是否配了 SSH"，凭据绝不出现在 API 响应里
    'has_ssh': sshConfig != null,
    'last_message': lastMessage,
    'last_message_time': lastMessageTime,
    'unread_count': unreadCount,
    'avatar_url': null,
    'pending_member_count': pendingMemberCount,
    'team_id': teamId,
    'parent_agent_id': parentAgentId,
    'level': level,
    'role': role,
    'duty': duty,
    'can_lead_team': canLeadTeam,
    'review_status': reviewStatus,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}

Map<String, double> _scoreMap(Object? raw) {
  if (raw is! Map) return <String, double>{};
  final Map<String, double> out = <String, double>{};
  raw.forEach((dynamic key, dynamic value) {
    final double? parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (parsed != null) out[key.toString()] = parsed;
  });
  return out;
}

/// 会话记录（现状 server `sessions` 表的桌面替身）。
class CoreSession {
  CoreSession({
    required this.sessionId,
    required this.agentId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.status = 'active',
    this.compactedSummary = '',
    this.compactedMessageCount = 0,
    List<String>? selectedSpecIds,
  }) : selectedSpecIds = selectedSpecIds ?? <String>[];

  /// 兜底默认会话 id（与前端 `_currentSessionId` 的缺省值一致）。
  static const String defaultSessionId = 'session_default';

  final String sessionId;
  final String agentId;
  String title;
  String status;
  final int createdAt;
  int updatedAt;
  List<String> selectedSpecIds;

  /// 上下文压缩后的摘要（M7d-4）：空串 = 从未压缩。
  ///
  /// 压缩**不删除任何消息**（用户仍能在界面回看全文），只是告诉引擎
  /// "前 [compactedMessageCount] 条已经总结过，请带摘要替代它们"。
  String compactedSummary;

  /// 已被摘要覆盖的历史消息条数（按写入顺序的前缀长度）。
  int compactedMessageCount;

  /// 是否已经压缩过上下文。
  bool get compacted =>
      compactedMessageCount > 0 && compactedSummary.trim().isNotEmpty;

  /// 是否为兜底默认会话。
  bool get isDefault => sessionId == defaultSessionId;

  /// 持久化形态（`data/<agent>/<session>/session.json`）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'session_id': sessionId,
    'agent_id': agentId,
    'title': title,
    'status': status,
    'selected_spec_ids': selectedSpecIds,
    'compacted_summary': compactedSummary,
    'compacted_message_count': compactedMessageCount,
    'created_at': JsonTime.encode(createdAt),
    'updated_at': JsonTime.encode(updatedAt),
  };

  static CoreSession fromJson(Map<String, dynamic> json) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return CoreSession(
      sessionId: json['session_id'] as String? ?? defaultSessionId,
      agentId: json['agent_id'] as String? ?? '',
      title: json['title'] as String? ?? '新会话',
      status: json['status'] as String? ?? 'active',
      compactedSummary: json['compacted_summary'] as String? ?? '',
      compactedMessageCount:
          (json['compacted_message_count'] as num?)?.toInt() ?? 0,
      selectedSpecIds:
          (json['selected_spec_ids'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toList() ??
          <String>[],
      createdAt: JsonTime.decode(json['created_at']) ?? now,
      updatedAt: JsonTime.decode(json['updated_at']) ?? now,
    );
  }

  /// 前端形态（`GET /api/agents/{id}/sessions`）。
  Map<String, dynamic> toApiJson({int messageCount = 0}) => <String, dynamic>{
    'session_id': sessionId,
    'agent_id': agentId,
    'title': title,
    'status': status,
    'selected_spec_ids': selectedSpecIds,
    'message_count': messageCount,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}

/// 消息记录（现状 server `messages` 表的桌面替身）。
///
/// 形态即前端 `ChatMessage.fromJson` 的输入（`GET /api/conversations/...` 与
/// WS `message` 帧共用），因此 [toJson] 同时是持久化形态（jsonl 一行）与 API 形态。
class CoreMessage {
  CoreMessage({
    required this.id,
    required this.agentId,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.timestamp,
    this.kind = 'text',
    this.toolName,
    this.toolArguments,
    this.toolResult = '',
    this.toolCallId,
    this.usage,
    this.attachments,
    this.options,
    this.answered = false,
  });

  factory CoreMessage.fromJson(Map<String, dynamic> json) {
    return CoreMessage(
      id: json['id'] as String? ?? CoreIds.message(),
      agentId: json['agent_id'] as String? ?? '',
      sessionId: json['session_id'] as String? ?? CoreSession.defaultSessionId,
      role: json['role'] as String? ?? 'agent',
      content: json['content'] as String? ?? '',
      timestamp:
          JsonTime.decode(json['timestamp']) ??
          DateTime.now().millisecondsSinceEpoch,
      kind: json['kind'] as String? ?? 'text',
      toolName: json['tool_name'] as String?,
      toolArguments: (json['tool_arguments'] as Map<dynamic, dynamic>?)?.map(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v),
      ),
      toolResult: json['tool_result'] as String? ?? '',
      toolCallId: json['tool_call_id'] as String?,
      usage: (json['usage'] as Map<dynamic, dynamic>?)?.map(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v),
      ),
      attachments: (json['attachments'] as List<dynamic>?)
          ?.map(
            (dynamic e) =>
                Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
          )
          .toList(),
      options: (json['options'] as List<dynamic>?)
          ?.map((dynamic e) => e.toString())
          .toList(),
      answered: json['answered'] as bool? ?? false,
    );
  }

  final String id;
  final String agentId;
  final String sessionId;
  final String role;
  final String content;
  final int timestamp;
  final String kind;
  final String? toolName;
  final Map<String, dynamic>? toolArguments;
  final String toolResult;

  /// 端点给的 tool_call id（回灌 `role: tool` 消息时需要原样带回）。
  /// 前端 `ChatMessage.fromJson` 不认识该字段，会安全忽略。
  final String? toolCallId;
  final Map<String, dynamic>? usage;
  final List<Map<String, dynamic>>? attachments;
  final List<String>? options;
  final bool answered;

  /// 是否为工具调用卡片（不计入"有效消息数"）。
  bool get isTool => kind == 'tool';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'agent_id': agentId,
    'session_id': sessionId,
    'role': role,
    'content': content,
    'timestamp': JsonTime.encode(timestamp),
    'kind': kind,
    'tool_name': toolName,
    'tool_arguments': toolArguments,
    'tool_result': toolResult,
    'tool_call_id': toolCallId,
    'usage': usage,
    'attachments': attachments,
    'options': options ?? const <String>[],
    'answered': answered,
    'is_streaming': false,
  };
}

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
