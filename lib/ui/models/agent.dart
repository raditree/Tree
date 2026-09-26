/// Agent 数据模型
///
/// 描述一次会话对应的 Agent 信息，包含名称、类型、最后消息预览、
/// 未读消息数等字段。
class Agent {
  /// 唯一标识
  final String id;

  /// 名称
  final String name;

  /// 类型（当前恒为 "normal"）
  final String type;

  /// 最后消息预览
  final String lastMessage;

  /// 最后消息时间（可能为空，例如新会话尚未产生消息）
  final DateTime? lastMessageTime;

  /// 未读消息数
  final int unreadCount;

  /// 头像 URL（可选，目前 UI 使用首字母占位）
  final String? avatarUrl;

  /// 该 agent 的独立 Docker 工作空间 ID（后端容器名为 workspace_{workspace_id}）
  final String workspaceId;

  /// 是否已配置 SSH（> false = 该 agent 的工具在远端主机执行）
  final bool hasSsh;

  /// 工作空间目录（空 = 核心默认 `<数据根>/workspaces/<agent_id>`）
  final String workspaceDir;

  /// 团队归属（空 = 顶层 agent，即团队根）。
  ///
  /// 为什么前端需要它：`/api/agents` 返回的是**全部** agent（含团队成员，核心的
  /// `toApiJson` 带 `team_id`），而插件槽位/站点等作用域都以**团队**为单位。
  /// 顶层 agent 自身就是团队（用自身 id），成员则要回指它的团队——否则选中成员时
  /// 插件面板按成员 id 过滤，会把该团队的站点与槽位全滤掉（表现为"站点（0）"）。
  final String teamId;

  /// 等待用户处理的团队成员数（未分配模型 / 待审核）
  ///
  /// 后端 `/api/agents` 按 TOP 的整棵成员树统计。> 0 时在 Agent 列表与
  /// teammates 入口显示红点徽章，提示用户去「模型配置」为成员赋模型并审核。
  final int pendingMemberCount;

  Agent({
    required this.id,
    required this.name,
    required this.type,
    required this.lastMessage,
    this.lastMessageTime,
    this.unreadCount = 0,
    this.avatarUrl,
    this.workspaceId = '',
    this.hasSsh = false,
    this.workspaceDir = '',
    this.pendingMemberCount = 0,
    this.teamId = '',
  });

  /// 插件作用域用的团队 id：成员回指团队，顶层 agent 用自身 id。
  String get teamScopeId => teamId.isNotEmpty ? teamId : id;

  /// 从 JSON 构造 Agent 实例
  ///
  /// 兼容后端返回的字段命名：
  /// - `last_message` / `lastMessage`
  /// - `last_message_time` / `lastMessageTime`
  /// - `unread_count` / `unreadCount`
  /// - `avatar_url` / `avatarUrl`
  factory Agent.fromJson(Map<String, dynamic> json) {
    return Agent(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? 'normal',
      lastMessage: json['last_message'] as String? ??
          json['lastMessage'] as String? ??
          '',
      lastMessageTime: _parseTime(
        json['last_message_time'] ?? json['lastMessageTime'],
      ),
      unreadCount: _parseInt(
        json['unread_count'] ?? json['unreadCount'],
      ),
      avatarUrl: json['avatar_url'] as String? ?? json['avatarUrl'] as String?,
      workspaceId: json['workspace_id'] as String? ?? json['workspaceId'] as String? ?? '',
      hasSsh: json['has_ssh'] == true || json['hasSsh'] == true,
      workspaceDir: json['workspace_dir'] as String? ??
          json['workspaceDir'] as String? ??
          '',
      pendingMemberCount: _parseInt(
        json['pending_member_count'] ?? json['pendingMemberCount'],
      ),
      teamId: json['team_id'] as String? ?? json['teamId'] as String? ?? '',
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

  /// 解析整数字段，兼容字符串形式
  static int _parseInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}
