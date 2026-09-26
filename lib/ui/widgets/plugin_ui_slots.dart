import 'package:flutter/material.dart';
import 'package:tree_protocol/tree_protocol.dart';

import '../services/plugin_ui_registry.dart';
import 'activity_bar_item.dart';
import 'plugin_ui_view.dart';

/// 插件声明式图标名 → Flutter 图标（受控白名单；未知名回退扩展图标）。
///
/// 插件不能传任意图标代码（那等于让插件决定前端资源），只能传约定名；
/// 白名单外一律回退 [Icons.extension_outlined]，不崩、不空。
const Map<String, IconData> _kPluginIcons = <String, IconData>{
  'extension': Icons.extension_outlined,
  'plugin': Icons.extension_outlined,
  'list': Icons.list_alt_outlined,
  'table': Icons.table_chart_outlined,
  'form': Icons.edit_note_outlined,
  'text': Icons.notes_outlined,
  'card': Icons.article_outlined,
  'progress': Icons.timelapse_outlined,
  'sync': Icons.sync_outlined,
  'status': Icons.info_outline,
  'info': Icons.info_outline,
  'chart': Icons.insert_chart_outlined,
  'terminal': Icons.terminal_outlined,
  'folder': Icons.folder_outlined,
  'download': Icons.download_outlined,
  'settings': Icons.settings_outlined,
  'bug': Icons.bug_report_outlined,
  'star': Icons.star_outline,
  'bell': Icons.notifications_outlined,
  'clock': Icons.schedule_outlined,
  'database': Icons.storage_outlined,
  'cloud': Icons.cloud_outlined,
  'link': Icons.link_outlined,
  'search': Icons.search_outlined,
  'play': Icons.play_circle_outline,
};

/// 图标名 → [IconData]（未知名回退扩展图标）。
IconData pluginUiIcon(String name) =>
    _kPluginIcons[name] ?? Icons.extension_outlined;

/// 槽位展示标签：title 优先，回退「插件 plugin_id」，再回退 slot_key。
String pluginSlotLabel(PluginUiSlot slot) {
  if (slot.title.isNotEmpty) {
    return slot.title;
  }
  if (slot.pluginId.isNotEmpty) {
    return '插件 ${slot.pluginId}';
  }
  return slot.slotKey;
}

// ══════════════════════════════════════════════════════════════════════════
// 接入点 1：左侧活动栏项（追加在主活动栏项之后，观感与既有项完全一致）
// ══════════════════════════════════════════════════════════════════════════

/// 活动栏里的插件项集合（按 [PluginUiRegistry.slotsOfKind] 顺序）。
///
/// 自身监听注册表：manifest / update / 注销都会即时反映；主页面只需在
/// "活动栏项列表变化"时重建左栏面板（见 MainPage 的槽位键监听）。
class PluginActivityBarItems extends StatelessWidget {
  /// 构造。
  const PluginActivityBarItems({
    super.key,
    this.registry,
    this.selectedSlotKey,
    required this.onSelect,
  });

  /// 槽位注册表（默认全局单例；测试注入独立实例）。
  final PluginUiRegistry? registry;

  /// 当前选中的插件活动栏槽位键（null = 选中的是内置面板）。
  final String? selectedSlotKey;

  /// 点击回调（参数为槽位键）。
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final PluginUiRegistry reg = registry ?? PluginUiRegistry.instance;
    return ListenableBuilder(
      listenable: reg,
      builder: (BuildContext context, Widget? child) {
        final List<PluginUiSlot> slots =
            reg.slotsOfKind(PluginUiSlotKind.activity);
        if (slots.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final PluginUiSlot slot in slots) ...<Widget>[
              // 与内置项之间的 4px 间隔保持一致
              const SizedBox(height: 4),
              ActivityBarItem(
                icon: pluginUiIcon(slot.icon),
                selectedIcon: pluginUiIcon(slot.icon),
                tooltip: pluginSlotLabel(slot),
                selected: slot.slotKey == selectedSlotKey,
                onTap: () => onSelect(slot.slotKey),
              ),
            ],
          ],
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// 接入点 2：右栏插件 Tab 内容
// ══════════════════════════════════════════════════════════════════════════

/// 右栏某个插件 Tab 的内容：渲染该槽位当前视图（更新即时生效）。
class PluginPanelSlotView extends StatelessWidget {
  /// 构造。
  const PluginPanelSlotView({
    super.key,
    required this.slot,
    this.registry,
    this.agentId = '',
    this.sessionId = '',
  });

  /// 槽位（Tab 由 [slot] 的 slotKey / title 决定）。
  final PluginUiSlot slot;

  /// 槽位注册表（默认全局单例）。
  final PluginUiRegistry? registry;

  /// 当前 agent（动作帧的上下文）。
  final String agentId;

  /// 当前会话 id。
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final PluginUiRegistry reg = registry ?? PluginUiRegistry.instance;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: reg,
      builder: (BuildContext context, Widget? child) {
        // 从注册表取最新槽位（plugin_ui_update 是整块替换，槽位键不变）
        final PluginUiSlot current = reg.slotRaw(slot.slotKey) ?? slot;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (current.pluginId.isNotEmpty) ...<Widget>[
                Text(
                  '来自插件 ${current.pluginId}',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
              ],
              PluginUiViewRenderer(
                slot: current,
                view: current.view,
                registry: reg,
                agentId: agentId,
                sessionId: sessionId,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// 接入点 3：底部细状态栏（仅在有插件状态项时出现）
// ══════════════════════════════════════════════════════════════════════════

/// 主界面底部状态栏：逐条渲染当前 team 的 status 槽位。
///
/// **没有状态项时整条不出现**（返回零尺寸），因此不会给既有界面增加常驻高度。
/// 每条状态项按单行裁切（状态栏只有 24px 高）：内容用 OverflowBox 按自然尺寸
/// 布局后裁掉超出部分，既不会 RenderFlex 溢出报错，也不会为了塞进一行而丢控件。
class PluginStatusBar extends StatelessWidget {
  /// 构造。
  const PluginStatusBar({
    super.key,
    this.registry,
    this.agentId = '',
    this.sessionId = '',
    this.height = 24,
  });

  /// 槽位注册表（默认全局单例）。
  final PluginUiRegistry? registry;

  /// 当前 agent（动作帧的上下文）。
  final String agentId;

  /// 当前会话 id。
  final String sessionId;

  /// 状态栏高度（细条）。
  final double height;

  @override
  Widget build(BuildContext context) {
    final PluginUiRegistry reg = registry ?? PluginUiRegistry.instance;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: reg,
      builder: (BuildContext context, Widget? child) {
        final List<PluginUiSlot> slots =
            reg.slotsOfKind(PluginUiSlotKind.status);
        if (slots.isEmpty) {
          return const SizedBox.shrink();
        }
        return Container(
          height: height,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.25),
            border: Border(
              top: BorderSide(
                color: Theme.of(context).dividerColor,
                width: 0.5,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          // 有界 Row + Flexible：状态项再多也不会把内容挤出屏幕（超长内容按项裁切）
          child: Row(
            children: <Widget>[
              for (int i = 0; i < slots.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 16),
                Flexible(
                  child: _PluginStatusItem(
                    slot: slots[i],
                    registry: reg,
                    agentId: agentId,
                    sessionId: sessionId,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 单条状态项：槽位标题 + 视图（单行裁切）。
class _PluginStatusItem extends StatelessWidget {
  const _PluginStatusItem({
    required this.slot,
    required this.registry,
    required this.agentId,
    required this.sessionId,
  });

  final PluginUiSlot slot;
  final PluginUiRegistry registry;
  final String agentId;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: pluginSlotLabel(slot),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(pluginUiIcon(slot.icon), size: 13, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          if (slot.title.isNotEmpty) ...<Widget>[
            Text(
              slot.title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(width: 6),
          ],
          // 单行视口：内容按自然高度布局后被裁切（OverflowBox 的宽度必须来自
          // 有界约束，否则会拿到无穷宽度而断言失败——见 ConstrainedBox）
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: SizedBox(
                height: 20,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: 0,
                    maxHeight: double.infinity,
                    child: PluginUiViewRenderer(
                      slot: slot,
                      view: slot.view,
                      registry: registry,
                      agentId: agentId,
                      sessionId: sessionId,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// 接入点 4：消息流内联卡片（按到达顺序，由消息列表追加在末尾）
// ══════════════════════════════════════════════════════════════════════════

/// 消息流插件卡片集合（按到达顺序；无卡片时零尺寸）。
class PluginInlineCards extends StatelessWidget {
  /// 构造。
  const PluginInlineCards({
    super.key,
    this.registry,
    this.agentId = '',
    this.sessionId = '',
  });

  /// 槽位注册表（默认全局单例）。
  final PluginUiRegistry? registry;

  /// 当前 agent（动作帧的上下文）。
  final String agentId;

  /// 当前会话 id。
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final PluginUiRegistry reg = registry ?? PluginUiRegistry.instance;
    return ListenableBuilder(
      listenable: reg,
      builder: (BuildContext context, Widget? child) {
        final List<PluginUiSlot> slots =
            reg.slotsOfKind(PluginUiSlotKind.card);
        if (slots.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final PluginUiSlot slot in slots)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PluginCardHost(
                  slot: slot,
                  registry: reg,
                  agentId: agentId,
                  sessionId: sessionId,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 单张插件卡片（消息流内联卡片，也是执行站 ui.push 的落地形态）。
class PluginCardHost extends StatelessWidget {
  /// 构造。
  const PluginCardHost({
    super.key,
    required this.slot,
    this.registry,
    this.agentId = '',
    this.sessionId = '',
  });

  /// 槽位。
  final PluginUiSlot slot;

  /// 槽位注册表（默认全局单例）。
  final PluginUiRegistry? registry;

  /// 当前 agent（动作帧的上下文）。
  final String agentId;

  /// 当前会话 id。
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                pluginUiIcon(slot.icon),
                size: 14,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  pluginSlotLabel(slot),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (slot.pluginId.isNotEmpty)
                Text(
                  slot.pluginId,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: 8),
          PluginUiViewRenderer(
            slot: slot,
            view: slot.view,
            registry: registry ?? PluginUiRegistry.instance,
            agentId: agentId,
            sessionId: sessionId,
          ),
        ],
      ),
    );
  }
}
