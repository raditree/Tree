import 'package:flutter/material.dart';

import '../models/agent.dart';
import 'agent_list_format.dart';



/// Agent 列表项（**无头像**；左侧色条承担 team 归属与视觉锚点）
///
/// 行布局：
///
/// ```
/// ▌ 契门                                    刚刚
///   轮次汇报：本轮的 3 个任务…              🔴 2
/// ```
///
/// - 左侧 4px 色条 = 该 agent 所属 team 的颜色（[teamColorFor]）；
/// - 第 1 行：名称（未读时加粗）+ 右侧相对时间；
/// - 第 2 行：预览（markdown 已剥离）+ 右侧徽标（待处理成员 / 未读）。
class AgentListItem extends StatelessWidget {
  final Agent agent;
  final bool selected;
  final VoidCallback onTap;

  const AgentListItem({
    super.key,
    required this.agent,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color barColor = teamColorFor(agent.teamId);
    final bool unread = agent.unreadCount > 0;
    final String time = relativeTime(agent.lastMessageTime);
    final String preview = previewOf(agent.lastMessage);

    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          // 色条**固定 4px**：不随选中变宽——一变宽会把文字往右推 2px，
          // 选中瞬间整行抖一下。选中态改用背景高亮表达。
          border: Border(left: BorderSide(color: barColor, width: 4)),
          color: selected ? cs.primaryContainer.withValues(alpha: 0.40) : null,
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 第 1 行：名称 + 相对时间
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    agent.name.isEmpty ? '(未命名)' : agent.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                if (time.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 6),
                  Text(
                    time,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 3),
            // 第 2 行：预览 + 徽标（待处理成员 / 未读）
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
                if (agent.pendingMemberCount > 0) ...<Widget>[
                  const SizedBox(width: 6),
                  _badge(
                    text: '${agent.pendingMemberCount}',
                    background: const Color(0xFFE06C75),
                  ),
                ],
                if (agent.unreadCount > 0) ...<Widget>[
                  const SizedBox(width: 6),
                  _badge(
                    text: '${agent.unreadCount}',
                    background: cs.primary,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Widget _badge({required String text, required Color background}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          height: 1.2,
        ),
      ),
    );
  }
}



