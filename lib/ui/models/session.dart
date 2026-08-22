/// 会话数据模型
///
/// 描述一次独立的多会话对话单元，包含标题、状态、创建/更新时间与
/// 选中的 Spec（P4-spec 使用）。
class ChatSession {
  /// 会话唯一标识
  final String sessionId;

  /// 会话标题（首条用户消息自动生成，可手动重命名）
  final String title;

  /// 会话状态："active"
  final String status;

  /// 创建时间（毫秒时间戳）
  final int createdAt;

  /// 最后活跃时间（毫秒时间戳）
  final int updatedAt;

  /// 选中的 Spec id 列表（P4-spec 使用）
  final List<String> selectedSpecIds;

  ChatSession({
    required this.sessionId,
    required this.title,
    this.status = 'active',
    this.createdAt = 0,
    this.updatedAt = 0,
    this.selectedSpecIds = const [],
  });

  /// 是否为默认会话
  bool get isDefault => sessionId == 'session_default';

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    final List<dynamic>? rawSpecs =
        json['selected_spec_ids'] as List<dynamic>?;
    return ChatSession(
      sessionId: json['session_id'] as String? ?? '',
      title: json['title'] as String? ?? '新会话',
      status: json['status'] as String? ?? 'active',
      createdAt: json['created_at'] as int? ?? 0,
      updatedAt: json['updated_at'] as int? ?? 0,
      selectedSpecIds: rawSpecs?.map((dynamic e) => e.toString()).toList() ??
          const <String>[],
    );
  }
}
