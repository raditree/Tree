import 'package:flutter/material.dart';

import '../models/session.dart';

/// 会话选择器（中栏标题栏）
///
/// 展示当前 agent 的会话列表，支持：
/// - 单击/下拉切换会话
/// - 新建会话
/// - 右键（secondary tap）当前会话标题栏弹出「重命名 / 删除」菜单
///
/// 通过回调与外部（MessagePanel）交互，自身不持有会话数据。
class SessionPicker extends StatelessWidget {
  /// 全部会话列表
  final List<ChatSession> sessions;

  /// 当前选中的会话 id
  final String currentSessionId;

  /// 选择会话
  final ValueChanged<ChatSession> onSelect;

  /// 新建会话
  final VoidCallback onCreate;

  /// 重命名会话
  final ValueChanged<ChatSession> onRename;

  /// 删除会话
  final ValueChanged<ChatSession> onDelete;

  const SessionPicker({
    super.key,
    required this.sessions,
    required this.currentSessionId,
    required this.onSelect,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
  });

  ChatSession? get _current {
    for (final ChatSession s in sessions) {
      if (s.sessionId == currentSessionId) return s;
    }
    return sessions.isNotEmpty ? sessions.first : null;
  }

  /// 右键（Windows 桌面 secondary tap）/长按当前会话标题栏，弹出重命名/删除菜单。
  /// 列表项内不再放内嵌按钮，避免会话名过长时按钮被挤出。
  void _handleSecondary(BuildContext context, Offset globalPosition) {
    final ChatSession? current = _current;
    final cs = Theme.of(context).colorScheme;
    if (current == null || current.isDefault) return; // 默认会话不可重命名/删除

    final box = context.findRenderObject() as RenderBox?;
    final size = box?.size ?? Size.zero;

    showMenu<_SecondaryAction>(
      context: context,
      // 将菜单定位到触发点（光标/长按点）附近
      position: RelativeRect.fromRect(
        globalPosition & size,
        Offset.zero & (box?.size ?? Size.zero),
      ),
      items: <PopupMenuEntry<_SecondaryAction>>[
        PopupMenuItem<_SecondaryAction>(
          value: const _SecondaryAction(type: 'rename'),
          child: Row(
            children: <Widget>[
              Icon(Icons.edit_outlined, size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              const Text('重命名会话'),
            ],
          ),
        ),
        PopupMenuItem<_SecondaryAction>(
          value: const _SecondaryAction(type: 'delete'),
          child: Row(
            children: <Widget>[
              Icon(Icons.delete_outline, size: 18, color: cs.error),
              const SizedBox(width: 8),
              Text('删除会话', style: TextStyle(color: cs.error)),
            ],
          ),
        ),
      ],
    ).then((action) {
      if (action == null) return;
      if (action.type == 'rename') {
        onRename(current);
      } else if (action.type == 'delete') {
        onDelete(current);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ChatSession? current = _current;

    final PopupMenuButton<_SessionAction> menu =
        PopupMenuButton<_SessionAction>(
      tooltip: '会话管理',
      onSelected: (action) {
        switch (action.type) {
          case 'create':
            onCreate();
            break;
          case 'select':
            onSelect(action.session!);
            break;
          case 'rename':
            onRename(action.session!);
            break;
          case 'delete':
            onDelete(action.session!);
            break;
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<_SessionAction>>[
        PopupMenuItem<_SessionAction>(
          value: const _SessionAction(type: 'create'),
          child: Row(
            children: const <Widget>[
              Icon(Icons.add_circle_outline, size: 18),
              SizedBox(width: 8),
              Text('新建会话'),
            ],
          ),
        ),
        if (sessions.isNotEmpty) const PopupMenuDivider(),
        for (final ChatSession s in sessions)
          PopupMenuItem<_SessionAction>(
            value: _SessionAction(type: 'select', session: s),
            child: Row(
              children: <Widget>[
                Icon(
                  s.isDefault ? Icons.lock_outline : Icons.chat_bubble_outline,
                  size: 16,
                  color: s.sessionId == currentSessionId
                      ? cs.primary
                      : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: s.sessionId == currentSessionId
                          ? cs.primary
                          : cs.onSurface,
                      fontWeight: s.sessionId == currentSessionId
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: cs.surfaceVariant.withOpacity(0.4),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: cs.outlineVariant, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.forum_outlined, size: 14, color: cs.primary),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                current?.title ?? '默认会话',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: cs.onSurface),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 16, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );

    // 右键/长按标题栏弹当前会话的重命名/删除菜单（默认会话除外）
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _handleSecondary(context, details.globalPosition),
      onLongPressStart: (details) =>
          _handleSecondary(context, details.globalPosition),
      child: menu,
    );
  }
}

/// 菜单动作：type ∈ {create, select, rename, delete}，select/rename/delete 携带会话
class _SessionAction {
  final String type;
  final ChatSession? session;

  const _SessionAction({required this.type, this.session});
}

/// 右键菜单动作：type ∈ {rename, delete}
class _SecondaryAction {
  final String type;

  const _SecondaryAction({required this.type});
}
