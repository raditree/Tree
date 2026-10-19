import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/detail_selection.dart';

/// 右栏「窗口」的描述：一种可被打开的窗口（文件 / 详情 / 设置 / 插件面板槽位 …）。
///
/// 宿主 [RightPanelHost] 不认识任何具体窗口——它只认识 id / 标题 / 图标 / 内容构造器，
/// 因此插件声明的 `panel` 槽位、设置页、文件页可以用同一套「窗口」机制打开，
/// 也便于单独给宿主写防回归用例（传几个假窗口即可）。
class RightPanelEntry {
  const RightPanelEntry({
    required this.id,
    required this.label,
    required this.icon,
    required this.bodyBuilder,
    this.openByDefault = false,
    this.autoOpenOnSelection = false,
  });

  /// 窗口唯一键（内置用固定名，插件槽位用 `panel:<slotKey>`）。
  final String id;

  /// 窗口标题（chip 上与「+」路由页上显示）。
  final String label;

  /// 窗口图标（chip 上与「+」路由页上显示）。
  final IconData icon;

  /// 窗口内容构造器（每次宿主重建时调用；内容自身负责保持状态）。
  final WidgetBuilder bodyBuilder;

  /// 初次进入时默认打开（例如「文件」）。
  final bool openByDefault;

  /// 中栏选中 / 注入详情时**自动打开并聚焦**这一窗（「详情」用）。
  ///
  /// 插件卡片点进详情（[DetailSelection.inject]）会写进这里，从而在**没有选中 agent**
  /// 时也能把详情窗叫出来——这正是用户反馈的痛点。
  final bool autoOpenOnSelection;
}

/// 右栏「窗口宿主」：把设置 / 文件 / 详情 / 模型信息 / 插件面板等**统一成窗口**，
/// 按需打开、随时关闭（用户 2026-10-18 定稿：右侧不再是一根固定分栏）。
///
/// - 顶栏是一排窗口 chip + 一个「+」创建按钮 + 折叠按钮；
/// - 没有打开任何窗口时仍**长期存在**（显示一个「打开窗口」的空态），因此即使没选中
///   agent、右侧也一直在（用户痛点：刚进应用右侧就没了，插件详情无处显示）；
/// - 「+」打开的是**页内路由页**（不是全屏 Navigator 路由）：所有可用窗口按
///   5 列 × 4 行网格排列，超过 20 个分页；
/// - 窗口身体用 [IndexedStack] 常挂：切换窗口不重建，文件树的展开态 / 查看器缓冲都不丢。
class RightPanelHost extends StatefulWidget {
  const RightPanelHost({
    super.key,
    required this.entries,
    this.onCollapse,
    this.openRequestId,
    this.openRequestRevision = 0,
  });

  /// 可用窗口集合（顺序即 chip 顺序 / 路由页顺序；由父级按当前 agent 与插件槽位算）。
  final List<RightPanelEntry> entries;

  /// 折叠右栏（顶栏最右那颗 chevron）。
  final VoidCallback? onCollapse;

  /// 外部要求打开某窗口的 id（新手引导「带我过去」用）。
  final String? openRequestId;

  /// [openRequestId] 的请求序号：只在**值变化**时生效，避免用户自己关掉后被拽回。
  final int openRequestRevision;

  @override
  State<RightPanelHost> createState() => _RightPanelHostState();
}

class _RightPanelHostState extends State<RightPanelHost> {
  /// 每家路由页的窗口格子数：5 列 × 4 行。
  static const int _columns = 5;
  static const int _rows = 4;
  static const int _perPage = _columns * _rows;

  /// 已打开的窗口 id（顺序即 chip 顺序）
  List<String> _open = <String>[];

  /// 当前聚焦的窗口 id（null = 没有打开任何窗口 / 正在路由页）
  String? _active;

  /// 是否正显示「+」路由页（页内，非全屏路由）
  bool _picking = false;

  /// 路由页当前页码（0 基）
  int _page = 0;

  /// 窗口 chip 行的滚动控制器：标签太多时靠它出滑动条 / 吞鼠标滚轮。
  final ScrollController _chipScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _open = <String>[
      for (final RightPanelEntry e in widget.entries)
        if (e.openByDefault) e.id,
    ];
    if (_open.isEmpty && widget.entries.isNotEmpty) {
      _open = <String>[widget.entries.first.id];
    }
    _active = _open.isEmpty ? null : _open.first;
    // 中栏点工具行 / 思考行、插件卡片注入详情 → 自动打开并聚焦「详情」窗
    DetailSelection.instance.addListener(_onDetailSelected);
  }

  @override
  void dispose() {
    DetailSelection.instance.removeListener(_onDetailSelected);
    _chipScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RightPanelHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Set<String> ids = <String>{for (final RightPanelEntry e in widget.entries) e.id};
    final bool entriesChanged =
        !_sameIds(oldWidget.entries, widget.entries);
    if (entriesChanged) {
      // 已被注销的窗口（插件卸载）从打开列表里摘掉；新出现的默认窗口补进末尾
      final List<String> next = <String>[
        for (final String id in _open)
          if (ids.contains(id)) id,
      ];
      for (final RightPanelEntry e in widget.entries) {
        if (e.openByDefault && !next.contains(e.id)) next.add(e.id);
      }
      _open = next;
      if (_active != null && !_open.contains(_active)) {
        _active = _open.isEmpty ? null : _open.first;
      }
      if (_open.isEmpty && _picking == false) _active = null;
    }
    // 外部打开请求：仅在请求序号变化时生效
    if (widget.openRequestId != null &&
        widget.openRequestRevision != oldWidget.openRequestRevision) {
      _openWindow(widget.openRequestId!);
    }
  }

  /// 两个 entries 列表的 id 序列是否一致（顺序敏感）。
  bool _sameIds(List<RightPanelEntry> a, List<RightPanelEntry> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  RightPanelEntry? _entryById(String id) {
    for (final RightPanelEntry e in widget.entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 打开某窗口并聚焦（已打开则只聚焦）。多个同 id 窗口只保留一个。
  void _openWindow(String id) {
    if (_entryById(id) == null) return;
    setState(() {
      if (!_open.contains(id)) _open.add(id);
      _active = id;
      _picking = false;
    });
  }

  /// 聚焦某个已打开的窗口。
  void _focusWindow(String id) {
    if (_active == id && !_picking) return;
    setState(() {
      _active = id;
      _picking = false;
    });
  }

  /// 关掉某个窗口；关的是当前聚焦窗时落到相邻窗。
  void _closeWindow(String id) {
    final int index = _open.indexOf(id);
    if (index < 0) return;
    setState(() {
      _open.removeAt(index);
      if (_active == id) {
        _active = _open.isEmpty
            ? null
            : _open[index.clamp(0, _open.length - 1)];
      }
    });
  }

  /// 「+」：开关页内路由页。
  void _togglePicker() {
    setState(() {
      _picking = !_picking;
      _page = 0;
    });
  }

  /// 中栏选中 / 注入详情：把「详情」窗叫出来（清空时不动，避免强拽）。
  void _onDetailSelected() {
    if (!mounted) return;
    if (DetailSelection.instance.message == null &&
        DetailSelection.instance.injected == null) {
      return;
    }
    RightPanelEntry? target;
    for (final RightPanelEntry e in widget.entries) {
      if (e.autoOpenOnSelection) {
        target = e;
        break;
      }
    }
    if (target == null) return;
    if (_open.contains(target.id) && _active == target.id && !_picking) return;
    _openWindow(target.id);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: <Widget>[
          _buildTopBar(cs),
          Divider(height: 1, thickness: 1, color: Theme.of(context).dividerColor),
          Expanded(child: _picking ? _buildPicker(cs) : _buildBody(cs)),
        ],
      ),
    );
  }

  /// 顶栏：窗口 chip（横向可滚 + 常显滑动条）+「+」创建 + 折叠。
  ///
  /// chip 行**常显滑动条**（用户 2026-10-19）：窗口开得多时标签会顶到右端被遮住，
  /// 以前只能横向拖，鼠标用户根本看不出来还有没有更多——现在底下有一条细滑动条
  /// 常驻，并且把鼠标滚轮的**竖直**增量也转成横向滚动（见 [_onChipPointerSignal]）。
  Widget _buildTopBar(ColorScheme cs) {
    return Container(
      height: 44,
      color: cs.surface,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Listener(
              // 桌面端鼠标滚轮是竖直的（scrollDelta.dy），而这条 chip 行是水平滚动视图
              // ——Scrollable 对水平轴只认 scrollDelta.dx，所以滚轮默认纹丝不动。
              // 这里把 dy 补成横向滚动，用户能直接滚轮翻标签。
              onPointerSignal: _onChipPointerSignal,
              child: Scrollbar(
                key: const ValueKey<String>('right-panel-chip-scrollbar'),
                controller: _chipScroll,
                thumbVisibility: true,
                scrollbarOrientation: ScrollbarOrientation.bottom,
                thickness: 4,
                radius: const Radius.circular(2),
                child: SingleChildScrollView(
                  controller: _chipScroll,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      const SizedBox(width: 6),
                      for (final String id in _open)
                        if (_entryById(id) != null)
                          _buildWindowChip(cs, _entryById(id)!),
                      const SizedBox(width: 6),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey<String>('right-panel-new-window'),
            tooltip: _picking ? '关闭创建页' : '新建窗口',
            visualDensity: VisualDensity.compact,
            icon: Icon(_picking ? Icons.close : Icons.add),
            onPressed: _togglePicker,
          ),
          if (widget.onCollapse != null)
            IconButton(
              key: const ValueKey<String>('right-panel-collapse'),
              tooltip: '折叠右侧栏',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_right),
              onPressed: widget.onCollapse,
            ),
        ],
      ),
    );
  }

  /// 鼠标滚轮 / 触控板滚到 chip 行上时：把竖直增量转成横向滚动。
  void _onChipPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_chipScroll.hasClients) return;
    final double delta =
        event.scrollDelta.dy != 0 ? event.scrollDelta.dy : event.scrollDelta.dx;
    if (delta == 0) return;
    final double next = (_chipScroll.offset + delta)
        .clamp(0.0, _chipScroll.position.maxScrollExtent);
    if (next == _chipScroll.offset) return;
    _chipScroll.jumpTo(next);
  }

  /// 在 [base] 的字重上抬 [delta] 档（夹在 w100…w900）。
  ///
  /// 窗口 chip 的"活动态更粗"要用**相对强调**（在界面字重之上抬一档），
  /// 而不是写死 w400 / w600——写死会让「界面字重」设置在这排标签上完全失效
  /// （用户 2026-10-19：窗口文字粗细不受设置影响）。
  static FontWeight _bumpWeight(FontWeight base, int delta) {
    final int slot = FontWeight.values.indexOf(base);
    final int next = (slot + delta).clamp(0, FontWeight.values.length - 1);
    return FontWeight.values[next];
  }

  /// 一个窗口 chip（图标 + 标题 + 关闭）。
  Widget _buildWindowChip(ColorScheme cs, RightPanelEntry entry) {
    final bool active = entry.id == _active && !_picking;
    // chip 文字跟随**界面字重设置**：默认样式来自 [Material] 写的
    // textTheme.bodyMedium（已被 FontService 抬过档），活动态在它之上再抬一档。
    final FontWeight baseWeight =
        DefaultTextStyle.of(context).style.fontWeight ?? FontWeight.w400;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: Material(
        color: active
            ? cs.primary.withValues(alpha: 0.14)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: ValueKey<String>('right-panel-chip-${entry.id}'),
          borderRadius: BorderRadius.circular(6),
          onTap: () => _focusWindow(entry.id),
          child: Padding(
            padding: const EdgeInsets.only(left: 8, right: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  entry.icon,
                  size: 15,
                  color: active ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        active ? _bumpWeight(baseWeight, 1) : baseWeight,
                    color: active ? cs.primary : cs.onSurface,
                  ),
                ),
                const SizedBox(width: 2),
                InkWell(
                  key: ValueKey<String>('right-panel-chip-close-${entry.id}'),
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => _closeWindow(entry.id),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      Icons.close,
                      size: 13,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 窗口身体：所有已打开窗口用 [IndexedStack] 常挂（切窗不重建）。
  Widget _buildBody(ColorScheme cs) {
    final List<RightPanelEntry> openEntries = <RightPanelEntry>[
      for (final String id in _open)
        if (_entryById(id) != null) _entryById(id)!,
    ];
    if (openEntries.isEmpty) return _buildEmpty(cs);
    int index = 0;
    for (int i = 0; i < openEntries.length; i++) {
      if (openEntries[i].id == _active) {
        index = i;
        break;
      }
    }
    return IndexedStack(
      index: index,
      children: <Widget>[
        for (final RightPanelEntry e in openEntries) e.bodyBuilder(context),
      ],
    );
  }

  /// 没有打开任何窗口：仍长期存在的空态（一颗大按钮叫出路由页）。
  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.dashboard_customize_outlined, size: 48, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: const ValueKey<String>('right-panel-empty-new'),
            onPressed: _togglePicker,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('打开窗口'),
          ),
        ],
      ),
    );
  }

  /// 「+」路由页：可用窗口按 5 列 × 4 行排列，超过 20 个分页。
  Widget _buildPicker(ColorScheme cs) {
    final List<RightPanelEntry> items = widget.entries;
    final int pages = math.max(1, (items.length + _perPage - 1) ~/ _perPage);
    final int page = _page.clamp(0, pages - 1);
    final int start = page * _perPage;
    final List<RightPanelEntry> slice = items.sublist(
      start,
      math.min(start + _perPage, items.length),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Text(
            '打开窗口（点一项打开或聚焦）',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: GridView.count(
            key: const ValueKey<String>('right-panel-picker-grid'),
            crossAxisCount: _columns,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 0.86,
            children: <Widget>[
              for (final RightPanelEntry e in slice) _buildPickerCell(cs, e),
            ],
          ),
        ),
        if (pages > 1) _buildPager(cs, page, pages),
      ],
    );
  }

  /// 路由页一个窗口格子。
  Widget _buildPickerCell(ColorScheme cs, RightPanelEntry entry) {
    final bool opened = _open.contains(entry.id);
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: ValueKey<String>('right-panel-pick-${entry.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openWindow(entry.id),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(entry.icon, size: 24, color: cs.primary),
              const SizedBox(height: 6),
              Text(
                entry.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.onSurface),
              ),
              if (opened) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  '已打开',
                  style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 分页控件（超过一页才出现）。
  Widget _buildPager(ColorScheme cs, int page, int pages) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('right-panel-page-prev'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_left, size: 18),
            onPressed: page > 0 ? () => setState(() => _page = page - 1) : null,
          ),
          Text(
            '第 ${page + 1} / $pages 页',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          IconButton(
            key: const ValueKey<String>('right-panel-page-next'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_right, size: 18),
            onPressed: page < pages - 1
                ? () => setState(() => _page = page + 1)
                : null,
          ),
        ],
      ),
    );
  }
}

/// 折叠窄条上的竖排文字：右栏现在是一堆窗口的宿主，「工作区」仍是最贴切的概括。
const String kRightPanelRailHint = '工作区';
