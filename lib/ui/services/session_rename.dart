import '../models/session.dart';

/// 会话改名帧（`session_renamed`）的**纯逻辑**：决定会话列表该怎么变。
///
/// 为什么单独成文件：面板里的处理函数需要 `mounted` / `setState` / 当前选中 agent
/// 这些 widget 上下文，而"该不该改、改成什么"本身是**纯数据变换**——抽出来就能直接
/// 单元测试，不必把 `MessagePanel` 整棵组件树搭起来（与 `message_replay_guard.dart`
/// 同一个做法）。
///
/// 背景（点位化，2026-10-01）：执行站命令 `session.rename` 让**插件**也能改会话标题。
/// REST 改名路径是前端自己 `setState`，插件改名没有这条路径，核心因此下发
/// `session_renamed` 帧；前端收到后要即时把标题换过来，否则用户得切走再切回才看得到。
abstract final class SessionRename {
  /// 把 [sessions] 里匹配 `(agentId, sessionId)` 的那一条标题改成 [title]。
  ///
  /// 返回：
  /// - `null` = **不需要改动**——帧不是当前 agent 的 / 会话不在列表里 / 标题本来就一样 /
  ///   参数为空（畸形帧）。调用方据此跳过 `setState`（避免整棵树白重建一次）；
  /// - 新列表 = 已替换（**顺序与其余字段原样保留**，只有那一条的 `title` 变了）。
  ///
  /// 为什么要按 (agent, session) 双键匹配：`sessionId` 只在自己的 agent 内唯一，
  /// 跨 agent 直接按 id 改会把别人的会话标题改掉。
  static List<ChatSession>? apply(
    List<ChatSession> sessions, {
    required String currentAgentId,
    required String agentId,
    required String sessionId,
    required String title,
  }) {
    if (agentId.isEmpty || sessionId.isEmpty || title.isEmpty) return null;
    if (currentAgentId.isEmpty || agentId != currentAgentId) return null;
    final int index = sessions.indexWhere(
      (ChatSession s) => s.sessionId == sessionId,
    );
    if (index < 0) return null;
    if (sessions[index].title == title) return null;
    return <ChatSession>[
      ...sessions.sublist(0, index),
      sessions[index].copyWith(title: title),
      ...sessions.sublist(index + 1),
    ];
  }

  /// 从帧里取改名载荷（兼容 `{data: {...}}` 与扁平两种形状）。
  ///
  /// 返回 `(agentId, sessionId, title)`；三者缺一即为畸形帧（调用方按"不改动"处理）。
  static ({String agentId, String sessionId, String title}) parse(
    Map<String, dynamic> frame,
  ) {
    final Map<String, dynamic> data =
        (frame['data'] as Map<String, dynamic>?) ?? frame;
    return (
      agentId: (data['agent_id'] as String?) ?? '',
      sessionId: (data['session_id'] as String?) ?? '',
      title: (data['title'] as String?) ?? '',
    );
  }
}
