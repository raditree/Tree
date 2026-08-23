/// 消息数据模型
///
/// 描述一条聊天消息，包含角色（用户/agent）、内容、时间戳与可选附件。
/// [content] 与 [isStreaming] 为可变字段，便于在流式接收过程中原地更新，
/// 避免 UI 上反复新增/替换消息对象。
class ChatMessage {
  /// 消息唯一标识
  final String id;

  /// 角色："user" 或 "agent"
  final String role;

  /// 消息内容（流式接收时会持续追加）
  String content;

  /// 时间戳
  final DateTime timestamp;

  /// 附件列表（可为空）
  final List<Attachment>? attachments;

  /// 是否正在流式接收
  bool isStreaming;

  /// token 用量统计（normal LLM 流式结束时返回）
  ///
  /// 结构：`{ prompt_tokens, completion_tokens, total_tokens, max_tokens }`，
  /// 无限上下文 LLM 或未统计时为 null。
  Map<String, dynamic>? usage;

  /// 消息种类："text"（普通文本）或 "tool"（工具调用卡片）
  final String kind;

  /// 工具名称（kind == "tool" 时有效）
  final String? toolName;

  /// 工具调用参数（kind == "tool" 时有效）
  final Map<String, dynamic>? toolArguments;

  /// 工具执行结果文本（kind == "tool" 时有效）
  String toolResult;

  /// 工具是否仍在执行中（kind == "tool" 时有效）
  bool toolRunning;

  /// 提问选项（kind == "ask_user_question" 时有效）
  final List<String> options;

  /// 是否已作答（内联提问卡片被选择后置位，用于禁用其余选项）
  bool answered;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.attachments,
    this.isStreaming = false,
    this.usage,
    this.kind = 'text',
    this.toolName,
    this.toolArguments,
    this.toolResult = '',
    this.toolRunning = false,
    this.options = const <String>[],
    this.answered = false,
  });

  /// 是否为用户消息
  bool get isUser => role == 'user';

  /// 从 JSON 构造 ChatMessage 实例
  ///
  /// 兼容后端字段命名：
  /// - `is_streaming` / `isStreaming`
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final List<dynamic>? raw = json['attachments'] as List<dynamic>?;
    final Map<String, dynamic>? usage =
        (json['usage'] as Map<dynamic, dynamic>?)?.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    );
    final Map<String, dynamic>? toolArgs =
        (json['tool_arguments'] as Map<dynamic, dynamic>?)?.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    );
    return ChatMessage(
      id: json['id'] as String? ?? '',
      role: json['role'] as String? ?? 'agent',
      content: json['content'] as String? ?? '',
      timestamp: _parseTime(json['timestamp']) ?? DateTime.now(),
      attachments: raw
          ?.map((dynamic e) => Attachment.fromJson(e as Map<String, dynamic>))
          .toList(),
      isStreaming:
          json['is_streaming'] as bool? ?? json['isStreaming'] as bool? ?? false,
      usage: usage,
      kind: json['kind'] as String? ?? 'text',
      toolName: json['tool_name'] as String?,
      toolArguments: toolArgs,
      toolResult: json['tool_result'] as String? ?? '',
      options:
          (json['options'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
              <String>[],
      answered: json['answered'] as bool? ?? false,
    );
  }

  /// 解析时间字段，支持 ISO 字符串与毫秒数
  static DateTime? _parseTime(dynamic value) {
    if (value == null) return null;
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }
}

/// 附件数据模型
///
/// 描述消息中携带的文件附件，包含文件名、大小与类型。
class Attachment {
  /// 文件名
  final String name;

  /// 文件大小（字节）
  final int size;

  /// 文件类型（MIME 类型或扩展名）
  final String type;

  Attachment({
    required this.name,
    required this.size,
    required this.type,
  });

  factory Attachment.fromJson(Map<String, dynamic> json) {
    return Attachment(
      name: json['name'] as String? ?? '',
      size: _parseInt(json['size']),
      type: json['type'] as String? ?? '',
    );
  }

  /// 解析整数字段，兼容字符串形式
  static int _parseInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}
