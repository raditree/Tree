import 'package:flutter/material.dart';

import '../models/agent.dart';

/// Agent 列表项组件
///
/// 渲染单个 Agent 信息行，包含头像、名称、最后消息预览、时间与未读数。
/// 头像为主色（随主题）背景。选中时整行高亮 primaryContainer 背景。
class AgentListItem extends StatelessWidget {
  /// 对应的 Agent 数据
  final Agent agent;

  /// 是否处于选中状态
  final bool selected;

  /// 点击回调
  final VoidCallback? onTap;

  /// 未读数红色徽章背景色
  static const Color _unreadBadgeColor = Color(0xFFEF4444);

  const AgentListItem({
    super.key,
    required this.agent,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? cs.primaryContainer : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // 左侧头像
              _buildAvatar(context),
              const SizedBox(width: 10),
              // 中间名称与消息预览
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 上行：名称 + 时间
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            agent.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                            ),
                          ),
                        ),
                        if (agent.lastMessageTime != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              _formatTime(agent.lastMessageTime!),
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.outline,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // 下行：最后消息预览（灰色单行省略）
                    Text(
                      agent.lastMessage.isEmpty ? '暂无消息' : agent.lastMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 右侧：未读数徽章（0 时不显示）
              if (agent.unreadCount > 0) _buildUnreadBadge(),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建头像（圆形 40x40）
  Widget _buildAvatar(BuildContext context) {
    final String initial = _getInitial(agent.name);
    // 头像背景跟随主题主色（浅色 #00904A / 深色 #00FF8C），文字用 onPrimary
    final cs = Theme.of(context).colorScheme;

    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 圆形头像
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: cs.primary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              initial,
              style: TextStyle(
                color: cs.onPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建未读数徽章（红色圆形 + 白色数字）
  Widget _buildUnreadBadge() {
    // 超过 99 显示 "99+"
    final String text =
        agent.unreadCount > 99 ? '99+' : agent.unreadCount.toString();
    // 文字长度决定徽章宽度（数字位数）
    final double width = text.length > 1 ? 20.0 : 16.0;

    return Container(
      constraints: BoxConstraints(minWidth: width),
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: _unreadBadgeColor,
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 取名称首字符作为头像占位字母
  ///
  /// 取首个 UTF-16 编码单元。对于 BMP 内字符（含中文、英文字母）
  /// 均可正确返回首个字形；agent 名称不涉及 emoji 等代理对字符。
  String _getInitial(String name) {
    if (name.isEmpty) return '?';
    return name[0].toUpperCase();
  }

  /// 格式化最后消息时间
  ///
  /// - 今天：显示 HH:mm
  /// - 昨天：显示 "昨天"
  /// - 本周内：显示星期几
  /// - 更早：显示 MM/DD
  String _formatTime(DateTime time) {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime target = DateTime(time.year, time.month, time.day);
    final int diffDays = today.difference(target).inDays;

    // 24 小时内按"今天"处理（显示具体时间）
    if (diffDays <= 0 &&
        now.difference(time).inHours < 24 &&
        now.isAfter(time)) {
      final String hour = time.hour.toString().padLeft(2, '0');
      final String minute = time.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    }
    if (diffDays == 1) {
      return '昨天';
    }
    if (diffDays > 1 && diffDays < 7) {
      const List<String> weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      // DateTime.weekday 范围 1-7（周一至周日）
      return weekdays[time.weekday - 1];
    }
    return '${time.month.toString().padLeft(2, '0')}/${time.day.toString().padLeft(2, '0')}';
  }
}
