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
    this.maxLevel = 1,
    this.maxMembersPerLevel = 0,
  });

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
  int maxLevel;
  int maxMembersPerLevel;
  final int createdAt;
  int updatedAt;

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
      maxLevel: (json['max_level'] as num?)?.toInt() ?? 1,
      maxMembersPerLevel: (json['max_members_per_level'] as num?)?.toInt() ?? 0,
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
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
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

  /// 是否为兜底默认会话。
  bool get isDefault => sessionId == defaultSessionId;

  /// 持久化形态（`data/<agent>/<session>/session.json`）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'session_id': sessionId,
    'agent_id': agentId,
    'title': title,
    'status': status,
    'selected_spec_ids': selectedSpecIds,
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
