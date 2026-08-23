import 'package:flutter/material.dart';

import '../models/session.dart';

/// 会话选择器（中栏标题栏）
///
/// 展示当前 agent 的会话列表，支持：
/// - 单击标题栏展开自定义下拉列表切换会话
/// - 下拉列表内「新建会话」
/// - 标题栏右键（secondary tap）/长按当前会话弹出「重命名 / 删除」菜单
/// - 下拉列表项右键/长按弹出该会话的「重命名 / 删除」菜单（默认会话除外）
///
/// 通过回调与外部（MessagePanel）交互，自身不持有会话数据。
///
/// 实现说明：下拉采用 Overlay 自绘列表面板（配合 [CompositedTransformTarget]/
/// [CompositedTransformFollower] 定位），而非 [MenuAnchor]/[PopupMenuButton]——
/// 因为需要支持「列表项内再弹二级右键菜单」与选中态/空态自定义排版，
/// 原生 PopupMenu 无法在菜单项内嵌右键手势。
class SessionPicker extends StatefulWidget {
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

  @override
  State<SessionPicker> createState() => _SessionPickerState();
}

class _SessionPickerState extends State<SessionPicker> {
  /// 下拉 Overlay 是否打开
  bool _dropdownOpen = false;

  /// 当前打开的 Overlay 条目
  OverlayEntry? _overlayEntry;

  /// 定位锚点（按钮 -> 下拉面板）
  final LayerLink _layerLink = LayerLink();

  /// 最近一次右键/长按位置（用于 showMenu 定位）
  Offset? _lastTapPos;

  ChatSession? get _current {
    for (final ChatSession s in widget.sessions) {
      if (s.sessionId == widget.currentSessionId) return s;
    }
    return widget.sessions.isNotEmpty ? widget.sessions.first : null;
  }

  @override
  void dispose() {
    _closeDropdown();
    super.dispose();
  }

  /// 切换下拉开关
  void _toggleDropdown() {
    if (_dropdownOpen) {
      _closeDropdown();
    } else {
      _openDropdown();
    }
  }

  /// 打开自定义下拉列表（Overlay 插入列表面板）
  void _openDropdown() {
    if (_dropdownOpen) return;
    final OverlayState overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(
      builder: (BuildContext ctx) => _buildDropdownOverlay(ctx),
    );
    overlay.insert(_overlayEntry!);
    _dropdownOpen = true;
  }

  /// 关闭下拉列表
  void _closeDropdown() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _dropdownOpen = false;
  }

  /// 标题栏右键/长按当前会话标题栏，弹出重命名/删除菜单。
  /// 列表项内不再放内嵌按钮，避免会话名过长时按钮被挤出。
  void _handleSecondary(BuildContext context, Offset globalPosition) {
    final ChatSession? current = _current;
    if (current == null || current.isDefault) return; // 默认会话不可重命名/删除

    final box = context.findRenderObject() as RenderBox?;
    showMenu<_SecondaryAction>(
      context: context,
      // 将菜单定位到触发点（光标/长按点）附近
      position: RelativeRect.fromRect(
        globalPosition & (box?.size ?? Size.zero),
        Offset.zero & (box?.size ?? Size.zero),
      ),
      items: <PopupMenuEntry<_SecondaryAction>>[
        PopupMenuItem<_SecondaryAction>(
          value: const _SecondaryAction(type: 'rename'),
          child: Row(
            children: <Widget>[
              Icon(Icons.edit_outlined,
                  size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              const Text('重命名会话'),
            ],
          ),
        ),
        PopupMenuItem<_SecondaryAction>(
          value: const _SecondaryAction(type: 'delete'),
          child: Row(
            children: <Widget>[
              Icon(Icons.delete_outline,
                  size: 18, color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 8),
              Text('删除会话',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ],
    ).then((action) {
      if (action == null) return;
      if (action.type == 'rename') {
        widget.onRename(current);
      } else if (action.type == 'delete') {
        widget.onDelete(current);
      }
    });
  }

  /// 下拉列表项右键/长按：弹出该会话的重命名/删除菜单（默认会话除外）
  Future<void> _showItemMenu(ChatSession session) async {
    if (session.isDefault) return; // 默认会话不可重命名/删除
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final Offset tapPos = _lastTapPos ??
        Offset(overlay.size.width - 200, overlay.size.height / 2);
    _lastTapPos = null;

    final RelativeRect position = RelativeRect.fromLTRB(
      tapPos.dx,
      tapPos.dy,
      overlay.size.width - tapPos.dx,
      overlay.size.height - tapPos.dy,
    );

    final String? action = await showMenu<String>(
      context: context,
      position: position,
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'rename',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.edit_outlined,
                  size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              const Text('重命名会话'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.delete_outline,
                  size: 18, color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 8),
              Text('删除会话',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ],
    );

    if (action == 'rename') {
      widget.onRename(session);
    } else if (action == 'delete') {
      widget.onDelete(session);
    }
  }

  /// 构建下拉 Overlay：全屏点击屏障 + 跟随按钮的列表面板
  Widget _buildDropdownOverlay(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: <Widget>[
        // 点击屏障：点击下拉外任意位置关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _closeDropdown,
            onSecondaryTapDown: (_) {
              _closeDropdown();
            },
          ),
        ),
        // 会话列表面板（定位到按钮下方）
        CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 6),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            color: cs.surface,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 280,
                maxHeight: 340,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 新建会话
                  InkWell(
                    onTap: () {
                      _closeDropdown();
                      widget.onCreate();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(Icons.add_circle_outline,
                              size: 18, color: cs.primary),
                          const SizedBox(width: 8),
                          Text(
                            '新建会话',
                            style: TextStyle(fontSize: 13, color: cs.primary),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (widget.sessions.isNotEmpty)
                    Divider(height: 1, thickness: 1, color: cs.outlineVariant),
                  // 会话列表
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: widget.sessions.length,
                      itemBuilder: (BuildContext ctx, int index) {
                        return _buildSessionItem(
                          ctx,
                          widget.sessions[index],
                          cs,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 构建单个会话列表项：单击选择，右键/长按弹该项操作菜单
  Widget _buildSessionItem(BuildContext ctx, ChatSession session, ColorScheme cs) {
    final bool selected = session.sessionId == widget.currentSessionId;
    return GestureDetector(
      onTap: () {
        widget.onSelect(session);
        _closeDropdown();
      },
      onSecondaryTapDown: (TapDownDetails details) {
        _lastTapPos = details.globalPosition;
      },
      onSecondaryTap: () => _showItemMenu(session),
      onLongPressStart: (LongPressStartDetails details) {
        _lastTapPos = details.globalPosition;
      },
      onLongPress: () => _showItemMenu(session),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        color: selected
            ? cs.primaryContainer.withOpacity(0.5)
            : Colors.transparent,
        child: Row(
          children: <Widget>[
            Icon(
              session.isDefault
                  ? Icons.lock_outline
                  : Icons.chat_bubble_outline,
              size: 16,
              color: selected ? cs.primary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: selected ? cs.primary : cs.onSurface,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check, size: 16, color: cs.primary),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ChatSession? current = _current;

    final Widget anchor = GestureDetector(
      onTap: _toggleDropdown,
      onSecondaryTapDown: (details) =>
          _handleSecondary(context, details.globalPosition),
      onLongPressStart: (details) =>
          _handleSecondary(context, details.globalPosition),
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

    return CompositedTransformTarget(
      link: _layerLink,
      child: anchor,
    );
  }
}

/// 菜单动作：type ∈ {rename, delete}
class _SecondaryAction {
  final String type;

  const _SecondaryAction({required this.type});
}
