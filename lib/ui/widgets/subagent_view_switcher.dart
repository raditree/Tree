import 'package:flutter/material.dart';

import '../models/message.dart';
import '../services/conversation_view.dart';
import '../services/subagent_transcript.dart';

/// 中栏的**视角切换器**（输入框右下、发送键左侧）——"主会话 ⇄ 某个临时员工"。
///
/// 用户 2026-10-04：「做成类似切换会话的样式，把切换的 UI 组件放输入框右下部分
/// （发送按钮左侧）」。它只表达"现在在看谁"并回调切换，不持有状态、不新开窗口。
///
/// 样式与 [SessionPicker]（会话切换器）同族：圆角胶囊 + 图标 + 当前项 + 下拉箭头。
class SubagentViewSwitcher extends StatelessWidget {
  const SubagentViewSwitcher({
    super.key,
    required this.ownerAgentId,
    required this.ownerName,
    required this.currentSubagentId,
    required this.onSelect,
  });

  /// 会话主人（判断"谁召来的"用）。
  final String ownerAgentId;
  final String ownerName;

  /// 当前正在看的临时员工 id（空 = 主会话）。
  final String currentSubagentId;

  /// 切换视角（空串 = 回主会话）。
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: SubagentTranscript.instance,
      builder: (BuildContext context, Widget? child) {
        final List<String> ids = SubagentTranscript.instance.ids;
        // 没有临时员工、也不在临时员工视角里 ⇒ 没什么可切的，不占位置
        if (ids.isEmpty && currentSubagentId.isEmpty) {
          return const SizedBox.shrink();
        }
        final bool inSubagent = currentSubagentId.isNotEmpty;
        final String label = inSubagent
            ? '临时员工「${subagentName(SubagentTranscript.instance.of(currentSubagentId), fallback: '…')}」'
            : '主会话';
        return PopupMenuButton<String>(
          tooltip: inSubagent
              ? '现在在看临时员工的过程 · 点这里切回主会话或换一个'
              : '进入某个临时员工的视角（不新开窗口：借这个窗口看它的过程）',
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: '',
              height: 38,
              child: _item(
                context,
                icon: Icons.chat_bubble_outline,
                label: '主会话 · ${ownerName.isEmpty ? '当前 agent' : ownerName}',
                selected: !inSubagent,
              ),
            ),
            if (ids.isNotEmpty) const PopupMenuDivider(),
            for (final String id in ids)
              PopupMenuItem<String>(
                value: id,
                height: 38,
                child: _item(
                  context,
                  icon: Icons.badge_outlined,
                  label: _labelOf(id),
                  selected: id == currentSubagentId,
                ),
              ),
          ],
          onSelected: onSelect,
          // 用 child（不用 icon）：颜色由我们自己给，不受 PopupMenuButton 内部
          // IconButton 取色的影响（发布版的图标字形曾因字体子集缺失整片画不出来）
          child: Container(
            margin: const EdgeInsets.only(right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: inSubagent
                  ? cs.primary.withValues(alpha: 0.14)
                  : cs.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: inSubagent
                    ? cs.primary.withValues(alpha: 0.45)
                    : cs.outline.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  inSubagent ? Icons.badge : Icons.badge_outlined,
                  size: 14,
                  color: inSubagent ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: inSubagent ? cs.primary : cs.onSurfaceVariant,
                    ),
                  ),
                ),
                Icon(
                  Icons.arrow_drop_down,
                  size: 16,
                  color: inSubagent ? cs.primary : cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _item(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool selected,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Icon(
          selected ? Icons.check : icon,
          size: 15,
          color: selected ? cs.primary : cs.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              color: selected ? cs.primary : cs.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  /// 一行：名字 + **谁召来的** + 层数 + 已有多少条过程（措辞与 teammates 分开）。
  String _labelOf(String id) {
    final List<ChatMessage> transcript = SubagentTranscript.instance.of(id);
    final String caller = SubagentTranscript.instance.callerNameOf(
      id,
      ownerAgentId: ownerAgentId,
      ownerName: ownerName,
    );
    return '临时员工「${subagentName(transcript)}」 · '
        '${viewSubtitle(callerName: caller, transcript: transcript)} · '
        '${transcript.length} 条过程';
  }
}
