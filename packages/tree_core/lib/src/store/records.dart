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
    this.thinkingOverride,
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

  /// 是否把历史思考（`reasoning_content`）回传端点的**本 Agent 覆盖**。
  ///
  /// null = 不覆盖（跟随模型的 `thinking`）；true/false = 覆盖。
  /// 用三态而不是 bool，是因为"不设置"与"显式关掉模型默认开启"必须能区分——
  /// 与 [maxSeqlenOverride] 等覆盖项同一语义（0/空串 = 未覆盖）。
  bool? thinkingOverride;

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
    'thinking_override': thinkingOverride,
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
      thinkingOverride: json['thinking_override'] as bool?,
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
    List<Map<String, dynamic>>? compactedContext,
    List<String>? selectedSpecIds,
  }) : selectedSpecIds = selectedSpecIds ?? <String>[],
       compactedContext = compactedContext ?? <Map<String, dynamic>>[];

  /// 兜底默认会话 id（与前端 `_currentSessionId` 的缺省值一致）。
  static const String defaultSessionId = 'session_default';

  final String sessionId;
  final String agentId;
  String title;
  String status;
  final int createdAt;
  int updatedAt;
  List<String> selectedSpecIds;

  /// 上下文压缩后的摘要（M7d-4）：空串 = 从未压缩（或权威在中转站产出的列表上）。
  ///
  /// 压缩**不删除任何消息**（用户仍能在界面回看全文），只是告诉引擎
  /// "前 [compactedMessageCount] 条已经总结过，请带摘要替代它们"。
  ///
  /// 与 [compactedContext] 互斥：写这份摘要时会把列表清空（内置路径接管）。
  String compactedSummary;

  /// 已被摘要覆盖的历史消息条数（按写入顺序的前缀长度）。
  int compactedMessageCount;

  /// **中转站产出的整份上下文**（点位化 `system.relay.context.compact`）：
  /// OpenAI 线形态的消息数组（`LlmMessage.toWire()` 的形状）。
  ///
  /// 非空时它是权威：引擎**原样使用**这份列表，再从原文第
  /// [compactedMessageCount] 条之后继续追加——不再自己拼 system / 摘要。
  ///
  /// 与 [compactedSummary] **互斥**（两条压缩路径只能有一个权威，否则"列表覆盖 12 条
  /// + 摘要覆盖 6 条"会同时存在，引擎无从选择）：写列表时清空摘要，写摘要时清空列表。
  List<Map<String, dynamic>> compactedContext;

  /// 是否已经压缩过上下文（内置摘要路径或中转站路径任一留下过产物）。
  bool get compacted =>
      compactedMessageCount > 0 &&
      (compactedSummary.trim().isNotEmpty || compactedContext.isNotEmpty);

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
    // 空列表不落盘：session.json 是给人看的，没走中转站就不该多一个空键
    if (compactedContext.isNotEmpty)
      'compacted_context': compactedContext,
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
      // 宽容解析：手改坏的行直接丢掉，不让整个会话读不出来
      compactedContext: <Map<String, dynamic>>[
        for (final Object? item
            in json['compacted_context'] as List<dynamic>? ?? const <dynamic>[])
          if (item is Map)
            item.map(
              (dynamic k, dynamic v) => MapEntry<String, dynamic>(
                k.toString(),
                v,
              ),
            ),
      ],
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
    this.toolArgumentsRaw = '',
    this.toolResultForModel = '',
    this.usage,
    this.attachments,
    this.options,
    this.answered = false,
    this.llmHidden = false,
    this.subagentId = '',
    this.subagentName = '',
    this.subagentParentId = '',
    this.subagentLevel = 0,
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
      toolArgumentsRaw: json['tool_arguments_raw'] as String? ?? '',
      toolResultForModel: json['tool_result_for_model'] as String? ?? '',
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
      llmHidden: json['llm_hidden'] as bool? ?? false,
      subagentId: json['subagent_id'] as String? ?? '',
      subagentName: json['subagent_name'] as String? ?? '',
      subagentParentId: json['subagent_parent_id'] as String? ?? '',
      subagentLevel: (json['subagent_level'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final String agentId;
  final String sessionId;
  final String role;
  final String content;

  /// 消息时间戳（毫秒）。
  ///
  /// 不是 final：存储层在追加时把它抬成**同一会话内严格递增**（见
  /// [TreeStore.appendMessage] 的"单调序号"），这样按时间戳排序的历史接口也不会
  /// 重排同一轮的多条消息。
  int timestamp;
  final String kind;
  final String? toolName;
  final Map<String, dynamic>? toolArguments;
  final String toolResult;

  /// 端点给的 tool_call id（回灌 `role: tool` 消息时需要原样带回）。
  /// 前端 `ChatMessage.fromJson` 不认识该字段，会安全忽略。
  final String? toolCallId;

  /// **模型原始的工具参数串**（流式增量拼出来的那一份，逐字保留）。
  ///
  /// 为什么要存：历史回灌时 `tool_calls[].function.arguments` 必须是**当初发出去
  /// 的同一串字节**。[toolArguments] 是解析后的 Map，重新 `jsonEncode` 得到的是
  /// 规范形态（无空格、统一转义），与模型原文常常不同——一旦不同，下一轮重建出来
  /// 的消息就与上一轮实发的逐字不一致，端点前缀缓存从这条消息起全部落空
  /// （真机表现：373k 上下文只命中 ~12k，正好是 system+摘要）。
  /// 空串 = 老数据（修复前落库的），回退到 `jsonEncode(toolArguments)`。
  final String toolArgumentsRaw;

  /// **送模型那一份工具结果**（门控 + 会话状态前缀之后的内容，逐字保留）。
  ///
  /// 与 [toolResult] 的分工：那个是"给人看 / 前端卡片 / 全文"的口径，这个是
  /// "模型当初收到的字节"。重建历史时原样取用，前缀才可能命中缓存；空串 = 老数据
  /// （回退到当场过一遍门控）。
  final String toolResultForModel;
  final Map<String, dynamic>? usage;
  final List<Map<String, dynamic>>? attachments;
  final List<String>? options;
  final bool answered;

  /// 是否为工具调用卡片（不计入"有效消息数"）。
  bool get isTool => kind == 'tool';

  /// 是否为思考（推理）卡片：默认**不进**上下文（引擎不回灌），
  /// 只有模型开了"回传思考"（`thinking`）时才作为 `reasoning_content` 回传。
  bool get isThinking => kind == 'thinking';

  /// 是否为"新的输入"（引擎按 **user** 翻译的三类消息）。
  ///
  /// 这类消息**落库为 agent 角色**（UI 照旧渲染成 agent 气泡），但引擎翻译历史时
  /// 按 **user** 消息处理：它既不是模型说的、也不是用户说的，而是"新的输入"。
  /// 详见 `ConversationService.wake` 与 `.self/plan/20261001-thinking-400-and-interrupt/`。
  ///
  /// 三类（与 `agent_engine.dart` 的 `CoreMessageRef.isNotice` 必须同口径）：
  /// - [MessageKinds.notice]：hook 提示 / 系统发言（wake）；
  /// - [MessageKinds.subagentTask]：交给临时员工的任务（**它自己**的输入）；
  /// - [MessageKinds.subagentReport]：临时员工后台完成报告（**发起者**的输入，
  ///   因此它虽然带 subagent 标记，却是唯一会进发起者模型上下文的带标记消息）。
  bool get isNotice =>
      kind == MessageKinds.notice ||
      kind == MessageKinds.subagentTask ||
      kind == MessageKinds.subagentReport;

  /// 是否为**临时员工给发起者的完成报告**（后台 `subagent` 的 wake 注入）。
  ///
  /// 它与其它带标记的消息相反：**要进发起者的模型上下文**（发起者得知道活干完了），
  /// 但**不进临时员工自己的历史**（那是它自己说过的话，重复一遍只会自相矛盾）。
  bool get isSubagentReport => kind == MessageKinds.subagentReport;

  /// **不插进模型提示词**（`llm_hidden: true`）：消息照常落库、照常下发（前端当普通
  /// 气泡渲染），但引擎重建请求时**整条跳过**。
  ///
  /// 用它的两类东西：
  /// - **系统发言**——失败提示、"已停止本轮生成。"（模型读到那句错误只会把它当成
  ///   新的排查任务；用户实测反馈）；
  /// - **过程提示**——重试进度（"第 2/5 次重试"），给用户看的，不是对话内容。
  ///
  /// 与 [isNotice] 的分工一眼可辨：`notice`（hook 唤醒）是**新的输入**，要按 user 进
  /// 上下文；本标记则相反。字段是通用的：任何消息都能打这个标签（插件/未来注入同理）。
  final bool llmHidden;

  // ── 临时员工（subagent，会话级）标记 ─────────────────────────────────
  //
  // 临时员工**没有自己的会话与消息文件**：它的全部活动都写进"召它的那个 agent 的
  // 会话"消息流里，靠这四个字段打标记。由此得到两条硬性质（见 store/README.md）：
  // - 用户能在会话历史里看到"这个临时员工干了什么"（`sessionMessages` 不过滤）；
  // - 父 agent 的模型上下文里**不会**混进临时员工的话（`messages()` 过滤掉带标记的
  //   消息）——否则工具批会被切开（assistant(tool_calls) 与它的 tool 结果之间插进
  //   别的消息），带 tools 的思考模式端点会 400。

  /// 产出这条消息的临时员工 id（`sub_…`）；空串 = 不是临时员工的消息。
  final String subagentId;

  /// 临时员工的显示名（界面分组用）。
  final String subagentName;

  /// 召它的那个 agent（真实 agent id，或上级临时员工 id）——会话内名册是一棵树。
  final String subagentParentId;

  /// 它在会话内树里的层级（真实 agent 的直属临时员工 = 1）。
  final int subagentLevel;

  /// 是否为临时员工产出的消息。
  bool get isSubagentMessage => subagentId.isNotEmpty;

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
    // 只在真的记了"送模型那一份"时才写：老会话文件不该多出一堆空键
    if (toolArgumentsRaw.isNotEmpty) 'tool_arguments_raw': toolArgumentsRaw,
    if (toolResultForModel.isNotEmpty)
      'tool_result_for_model': toolResultForModel,
    'usage': usage,
    'attachments': attachments,
    'options': options ?? const <String>[],
    'answered': answered,
    // 只在该隐藏时才落这个键：普通消息的 jsonl 一行不该多个 false
    if (llmHidden) 'llm_hidden': true,
    // 临时员工标记：只有带标记的消息才落这些键，普通消息的 jsonl 一行保持不变
    if (subagentId.isNotEmpty) ...<String, dynamic>{
      'subagent_id': subagentId,
      'subagent_name': subagentName,
      'subagent_parent_id': subagentParentId,
      'subagent_level': subagentLevel,
    },
    'is_streaming': false,
  };
}

/// **临时员工**（subagent）记录：一个"召之即来、干完还在"的会话级成员。
///
/// 与 [CoreAgent] 的本质区别（用户 2026-10-04 定稿的口径）：
/// - **只活在它被召来的那个会话里**：记录落 `data/<agentId>/<sessionId>/subagents.json`，
///   不写 `agents/<id>.yaml`、不进 [TreeStore.agents] / `teams()` / `members()`、
///   不可被 `message` 寻址、不计 `team_member_count`；换会话查不到，删会话一起消失；
/// - **可复用**：同一会话内给 id 或名称就能在**同一个**临时员工上继续（历史延续、
///   配置不变），所以它有一条自己的消息史（带 [CoreMessage.subagentId] 标记）；
/// - **可再派发**：它自己也能召临时员工，于是会话内名册是一棵**树**（[parentId] +
///   [level]），层级上限见 `SubagentLimits`。
///
/// [agent] 是它的运行配置快照：工作空间/模型/覆盖项在创建时从**召它的那个 agent**
/// 继承（`parentAgentId` 指向召唤者，工作空间因此仍与发起者**同一份**）。
class CoreSubagent {
  CoreSubagent({
    required this.id,
    required this.name,
    required this.ownerAgentId,
    required this.sessionId,
    required this.parentId,
    required this.level,
    required this.agent,
    this.scope = '',
    this.runCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 临时员工 id（`sub_…`，全局唯一：`store.agent(id)` 没有会话维度，
  /// 两个会话各自叫 `sub_1` 会让工作空间解析串号）。
  final String id;

  /// 显示名（默认「临时员工」；同会话内不要求唯一，名称复用有歧义时报可读错误）。
  String name;

  /// **会话主人**：这个临时员工所在会话归属的真实 agent（树根）。
  ///
  /// 它的消息、工作空间私有分栏、`team_id`/`mode_key` 口径都按这个 id 归集。
  final String ownerAgentId;

  /// 它只在这个会话里存在（跨会话一律查不到、不可复用）。
  final String sessionId;

  /// 召它的那个 agent：真实 agent id 或**上级临时员工** id（会话内是一棵树）。
  final String parentId;

  /// 会话内树层级：真实 agent 的直属临时员工 = 1，其下级 = 2……
  final int level;

  /// 运行配置快照（继承发起者的工作空间/模型/成员级覆盖）。
  CoreAgent agent;

  /// **被召来时的职责/范围**（首个 task 的摘要）：复用判据的书面依据——
  /// "只有当新任务与它被召来时的职责/范围一致时才复用同一个临时员工"。
  String scope;

  /// 被跑过多少轮（含复用；自检与界面用）。
  int runCount;

  final int createdAt;
  int updatedAt;

  /// 持久化形态（`data/<agentId>/<sessionId>/subagents.json` 里的一条）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'owner_agent_id': ownerAgentId,
    'session_id': sessionId,
    'parent_id': parentId,
    'level': level,
    'scope': scope,
    'run_count': runCount,
    'agent': agent.toJson(),
    'created_at': JsonTime.encode(createdAt),
    'updated_at': JsonTime.encode(updatedAt),
  };

  static CoreSubagent fromJson(Map<String, dynamic> json) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Object? rawAgent = json['agent'];
    final Map<String, dynamic> agentJson = rawAgent is Map
        ? rawAgent.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    return CoreSubagent(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      ownerAgentId: json['owner_agent_id'] as String? ?? '',
      sessionId: json['session_id'] as String? ?? '',
      parentId: json['parent_id'] as String? ?? '',
      level: (json['level'] as num?)?.toInt() ?? 1,
      scope: json['scope'] as String? ?? '',
      runCount: (json['run_count'] as num?)?.toInt() ?? 0,
      agent: CoreAgent.fromJson(agentJson),
      createdAt: JsonTime.decode(json['created_at']) ?? now,
      updatedAt: JsonTime.decode(json['updated_at']) ?? now,
    );
  }
}

/// 从 [list] 里取出 [rootId] 及其**全部下级**的 id（会话内名册是一棵树）。
///
/// 两个存储实现（内存 / 落盘）共用同一份"按树收"的判据：删一个临时员工时，
/// 它召出来的下级必须一起走——否则会留下悬空的 `parent_id`（与团队关系自愈
/// 要解决的悬空 `parent_agent_id` 是同一类问题）。
Set<String> subagentTreeIds(List<CoreSubagent> list, String rootId) {
  final Set<String> doomed = <String>{rootId};
  bool grew = true;
  while (grew) {
    grew = false;
    for (final CoreSubagent s in list) {
      if (doomed.contains(s.id)) continue;
      if (doomed.contains(s.parentId)) {
        doomed.add(s.id);
        grew = true;
      }
    }
  }
  return doomed;
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

/// 消息 kind 的字面量（跨层口径）。
///
/// 引擎侧的 `CoreMessageRef.isNotice` 只认字面量（agent 层刻意不依赖存储层），
/// 两处必须同步：任何一类"按 user 翻译"的 kind 都要同时出现在这两个地方。
abstract final class MessageKinds {
  /// 普通文本 / 思考段 / 工具卡片。
  static const String text = 'text';
  static const String thinking = 'thinking';
  static const String tool = 'tool';

  /// hook 提示 / 系统发言：引擎按 user 翻译，且**不喂模型**（llm_hidden）。
  static const String notice = 'notice';

  /// 交给临时员工的任务（它自己那一轮的输入；发起者的上下文里**没有**它）。
  static const String subagentTask = 'subagent_task';

  /// 临时员工后台完成报告（发起者的输入；带 subagent 标记，前端按它分组）。
  static const String subagentReport = 'subagent_report';
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

  /// 是否回传历史思考（`reasoning_content`）：DeepSeek 带 `tools` 的请求要求回传。
  static const String thinking = 'thinking';

  static const List<String> all = <String>[
    reasoningEffort,
    maxSeqlen,
    maxOutputTokens,
    compressThreshold,
    thinking,
  ];
}
