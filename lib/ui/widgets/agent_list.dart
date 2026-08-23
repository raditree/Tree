import 'package:flutter/material.dart';

import '../models/agent.dart';
import 'agent_list_item.dart';

/// Agent 列表组件
///
/// 渲染左栏 Agent 列表，维护当前选中的 agent 状态。
/// 点击某项时更新选中态并通过 [onAgentSelected] 回调通知父组件，
/// 以便切换中栏会话内容。列表为空时展示居中"暂无 Agent"提示。
///
/// 支持右键弹出菜单（移动端长按），含"清空对话"选项。
class AgentList extends StatefulWidget {
  /// 待渲染的 Agent 列表
  final List<Agent> agents;

  /// 选中 Agent 时的回调，参数为对应的 Agent
  final ValueChanged<Agent>? onAgentSelected;

  /// 清空 agent 对话历史后的回调（父组件可刷新消息列表）
  final ValueChanged<Agent>? onClearHistory;

  /// 删除 agent 后的回调（父组件同步后端并刷新列表）
  final ValueChanged<Agent>? onDelete;

  /// 左栏折叠回调（列表底部空位区域点击触发，Agent 较少时便于快速折叠）
  final VoidCallback? onCollapse;

  const AgentList({
    super.key,
    required this.agents,
    this.onAgentSelected,
    this.onClearHistory,
    this.onDelete,
    this.onCollapse,
  });

  @override
  State<AgentList> createState() => _AgentListState();
}

class _AgentListState extends State<AgentList> {
  /// 当前选中的 Agent id
  String? _selectedAgentId;

  /// 处理列表项点击
  ///
  /// 更新选中态并触发回调。重复点击同一项也会触发回调，
  /// 由父组件决定是否需要去重处理。
  void _handleTap(Agent agent) {
    setState(() {
      _selectedAgentId = agent.id;
    });
    widget.onAgentSelected?.call(agent);
  }

  /// 处理右键/长按：弹出操作菜单（含清空对话）
  Future<void> _handleSecondaryAction(
    BuildContext context,
    Agent agent,
  ) async {
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    // 计算点击位置（鼠标右键时为鼠标位置，长按为长按点）
    final Offset tapPos = _lastTapPos ??
        Offset(
          overlay.size.width - 200,
          overlay.size.height / 2,
        );
    _lastTapPos = null;

    final RelativeRect position = RelativeRect.fromLTRB(
      tapPos.dx,
      tapPos.dy,
      overlay.size.width - tapPos.dx,
      overlay.size.height - tapPos.dy,
    );

    final String? choice = await showMenu<String>(
      context: context,
      position: position,
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'clear',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const <Widget>[
              Icon(Icons.delete_sweep_outlined, size: 18, color: Colors.orange),
              SizedBox(width: 8),
              Text(
                '清空对话',
                style: TextStyle(color: Colors.orange),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const <Widget>[
              Icon(Icons.delete_outline, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text(
                '删除 Agent',
                style: TextStyle(color: Colors.red),
              ),
            ],
          ),
        ),
      ],
    );

    if (choice == 'clear') {
      if (!mounted) return;
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('清空对话'),
          content: Text('确定要清空与"${agent.name}"的所有对话记录吗？此操作不可恢复。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空', style: TextStyle(color: Colors.orange)),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        widget.onClearHistory?.call(agent);
      }
    } else if (choice == 'delete') {
      if (!mounted) return;
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('删除 Agent'),
          content: Text('确定要删除"${agent.name}"吗？其对话历史将一并删除，此操作不可恢复。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        widget.onDelete?.call(agent);
      }
    }
  }

  /// 记录最后一次点击位置（用于右键菜单定位）
  Offset? _lastTapPos;

  @override
  Widget build(BuildContext context) {
    // 列表末尾追加一项"空位折叠区"：Agent 较少时列表下方空白可点击折叠左栏
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: widget.agents.length + 1,
      // 列表项之间 1px 分隔线
      separatorBuilder: (BuildContext context, int index) {
        if (index >= widget.agents.length) {
          return const SizedBox.shrink();
        }
        return Divider(
          height: 1,
          thickness: 1,
          color: Theme.of(context).dividerColor,
          indent: 12,
          endIndent: 12,
        );
      },
      itemBuilder: (BuildContext context, int index) {
        // 最后一项：空位折叠区
        if (index == widget.agents.length) {
          return _buildCollapsePlaceholder();
        }
        final Agent agent = widget.agents[index];
        return GestureDetector(
          // 桌面端右键
          onSecondaryTapDown: (TapDownDetails details) {
            _lastTapPos = details.globalPosition;
          },
          onSecondaryTap: () => _handleSecondaryAction(context, agent),
          // 移动端长按
          onLongPressStart: (LongPressStartDetails details) {
            _lastTapPos = details.globalPosition;
          },
          onLongPress: () => _handleSecondaryAction(context, agent),
          child: AgentListItem(
            agent: agent,
            selected: agent.id == _selectedAgentId,
            onTap: () => _handleTap(agent),
          ),
        );
      },
    );
  }

  /// 列表底部空位折叠区：Agent 较少时显示"点击空白处折叠左栏"
  Widget _buildCollapsePlaceholder() {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onCollapse,
      onDoubleTap: widget.onCollapse,
      child: SizedBox(
        height: 220,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.agents.isEmpty) ...<Widget>[
                Text(
                  '暂无 Agent',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Icon(Icons.chevron_left, size: 20, color: cs.outline),
              const SizedBox(height: 4),
              Text(
                '点击空白处折叠左栏',
                style: TextStyle(fontSize: 11, color: cs.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
