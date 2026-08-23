import 'package:flutter/material.dart';

import '../../io/api_service.dart';

/// 单条 Todo 项
class TodoItem {
  final String id;
  final String content;
  final String status;
  final int progress;
  final int updatedAt;

  const TodoItem({
    required this.id,
    required this.content,
    required this.status,
    required this.progress,
    this.updatedAt = 0,
  });

  factory TodoItem.fromJson(Map<String, dynamic> json) {
    return TodoItem(
      id: (json['id'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      status: (json['status'] ?? 'pending').toString(),
      progress: int.tryParse(json['progress']?.toString() ?? '0') ?? 0,
      updatedAt: int.tryParse(json['updated_at']?.toString() ?? '0') ?? 0,
    );
  }
}

/// Todo 面板（右栏导航页）
///
/// 通过后端 API 按 user_id + agent_id + session_id 拉取该 agent 当前会话的
/// 任务清单（会话隔离，由 SetTodoList 工具维护），渲染成 id + 内容 + 状态/
/// 进度的列表。进入面板时拉取一次，会话变化时自动重新拉取。
class TodoPanel extends StatefulWidget {
  /// 工作空间 ID
  final String workspaceId;

  /// 所属顶层 agent ID（查询 todos 用）
  final String? topAgentId;

  /// 当前会话 ID（todos 按会话隔离）
  final String sessionId;

  /// 刷新触发器（外部可递增触发重新拉取）
  final int refreshTrigger;

  const TodoPanel({
    super.key,
    required this.workspaceId,
    this.topAgentId,
    this.sessionId = 'session_default',
    this.refreshTrigger = 0,
  });

  @override
  State<TodoPanel> createState() => _TodoPanelState();
}

class _TodoPanelState extends State<TodoPanel> {
  List<TodoItem> _todos = <TodoItem>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TodoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspaceId != widget.workspaceId ||
        oldWidget.sessionId != widget.sessionId ||
        oldWidget.refreshTrigger != widget.refreshTrigger) {
      _load();
    }
  }

  /// 拉取并解析当前会话 todos
  Future<void> _load() async {
    setState(() {
      // 软更新：有旧数据时不闪加载态
      _loading = _todos.isEmpty;
      _error = null;
    });
    try {
      final agentId = widget.topAgentId ?? '';
      final List<Map<String, dynamic>> todoMaps =
          await ApiService.getAgentTodos(agentId, sessionId: widget.sessionId);
      final List<TodoItem> items =
          todoMaps.map(TodoItem.fromJson).toList(growable: false);
      if (!mounted) return;
      setState(() {
        _todos = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取任务清单失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_outlined, size: 48, color: cs.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_todos.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.checklist_outlined, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(
              '暂无任务清单',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _todos.length,
        itemBuilder: (BuildContext context, int index) {
          return _buildTodoRow(cs, _todos[index]);
        },
      ),
    );
  }

  /// 渲染单条 todo：状态图标 + 内容 + 状态/进度
  Widget _buildTodoRow(ColorScheme cs, TodoItem todo) {
    final IconData icon;
    final Color color;
    switch (todo.status) {
      case 'completed':
        icon = Icons.check_circle;
        color = Colors.green;
        break;
      case 'in_progress':
        icon = Icons.play_circle;
        color = cs.primary;
        break;
      case 'blocked':
        icon = Icons.block;
        color = Colors.orange;
        break;
      default:
        icon = Icons.radio_button_unchecked;
        color = cs.onSurfaceVariant;
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      color: cs.surfaceVariant.withOpacity(0.5),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    todo.content,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      decoration:
                          todo.status == 'completed'
                              ? TextDecoration.lineThrough
                              : null,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    todo.id,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (todo.status == 'in_progress' || todo.progress > 0)
                  Text(
                    '${todo.status} · ${todo.progress}%',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  )
                else
                  Text(
                    todo.status,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}