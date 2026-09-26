import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:tree_protocol/tree_protocol.dart';

import '../services/plugin_ui_registry.dart';

/// 插件视图的**受限渲染器**（Q12 / M9 计划 4.1 契约）。
///
/// 输入 = 协议包的 [PluginUiView]（单节点或节点数组），输出 = Flutter 控件：
/// - 控件集只有 `text` / `list` / `table` / `form` / `progress` / `actions`，
///   外加两个布局容器 `row` / `column`（4.1 之外的前端扩展，见协议包 dartdoc）；
/// - **不允许 webview / iframe**：文本只有纯文本与 markdown 两条路径，markdown 由
///   Flutter 控件渲染（`MarkdownBody`），图片一律渲染成占位文本（**不发起任何
///   网络请求**），链接不注册点击回调（点了没反应，不打开系统浏览器）；
/// - **未知控件类型**渲染成「不支持的控件（类型名）」占位，绝不抛异常；
/// - 按钮点击 / 表单提交 → [PluginUiRegistry.dispatchAction] →
///   `plugin_ui_action` 帧（`slot_key` + `action_id` + `payload`）；
///   表单提交的 payload = `submit.payload` 与各字段当前值合并（**字段值覆盖同名键**）。
///
/// 所有解析都是"宽容"的：[PluginUiNode.str] / [PluginUiNode.listOrEmpty] 等读取器
/// 对缺失字段给默认值，因此插件发来半成品视图也不会崩。
class PluginUiViewRenderer extends StatelessWidget {
  /// 构造。
  const PluginUiViewRenderer({
    super.key,
    required this.slot,
    required this.view,
    this.registry,
    this.agentId = '',
    this.sessionId = '',
  });

  /// 视图所属槽位（动作帧需要 `slot_key` / `plugin_id` / `team_id`）。
  final PluginUiSlot slot;

  /// 待渲染视图。
  final PluginUiView view;

  /// 槽位注册表（默认全局单例；测试注入独立实例）。
  final PluginUiRegistry? registry;

  /// 当前 agent（隔离四元组的其余成员，动作帧原样带上）。
  final String agentId;

  /// 当前会话 id。
  final String sessionId;

  PluginUiRegistry get _registry => registry ?? PluginUiRegistry.instance;

  @override
  Widget build(BuildContext context) {
    if (view.nodes.isEmpty) {
      return _hint(context, '（空视图）');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < view.nodes.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 8),
          buildNode(context, view.nodes[i]),
        ],
      ],
    );
  }

  /// 渲染单个视图节点（列表项 / 容器子项递归调用同一入口）。
  Widget buildNode(BuildContext context, PluginUiNode node) {
    switch (node.type) {
      case PluginUiViewType.text:
        return _text(context, node);
      case PluginUiViewType.list:
        return _list(context, node);
      case PluginUiViewType.table:
        return _table(context, node);
      case PluginUiViewType.form:
        return _PluginFormNode(
          // 整块替换语义：视图 JSON 变了就重建表单（未提交的输入不跨视图保留）
          key: ValueKey<String>('${slot.slotKey}::${jsonEncode(node.raw)}'),
          slot: slot,
          node: node,
          registry: _registry,
          agentId: agentId,
          sessionId: sessionId,
        );
      case PluginUiViewType.progress:
        return _progress(context, node);
      case PluginUiViewType.actions:
        return _actions(context, node);
      case PluginUiViewType.row:
        return _row(context, node);
      case PluginUiViewType.column:
        return _column(context, node);
      default:
        return unsupportedPlaceholder(context, node.type);
    }
  }

  /// 未知控件占位（公开静态方法，便于其它槽位渲染路径复用与测试断言）。
  static Widget unsupportedPlaceholder(BuildContext context, String type) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.help_outline, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '不支持的控件（$type）',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  // ── text ────────────────────────────────────────────────────────────────

  Widget _text(BuildContext context, PluginUiNode node) {
    final String text = node.str('text');
    if (text.isEmpty) {
      return _hint(context, '');
    }
    if (node.str('format') == 'markdown') {
      return _markdown(context, node, text);
    }
    return Text(text, style: _textStyle(context, node));
  }

  /// markdown 渲染：只用 Flutter 控件，图片禁用（防网络请求 / 跟踪），链接不可点。
  Widget _markdown(BuildContext context, PluginUiNode node, String text) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextStyle base =
        _textStyle(context, node) ?? TextStyle(fontSize: 13, color: cs.onSurface);
    return MarkdownBody(
      data: text,
      selectable: false,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: base,
        code: TextStyle(fontFamily: 'monospace', fontSize: base.fontSize),
        blockquoteDecoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      // 图片占位：不加载任何远端资源（插件视图不允许联网取图）
      imageBuilder: (Uri uri, String? title, String? alt) => Text(
        '[图片已禁用：${uri.toString()}]',
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      ),
    );
  }

  TextStyle? _textStyle(BuildContext context, PluginUiNode node) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    switch (node.str('style')) {
      case 'title':
        return const TextStyle(fontSize: 15, fontWeight: FontWeight.w600);
      case 'caption':
        return TextStyle(fontSize: 11, color: cs.onSurfaceVariant);
      case 'mono':
        return const TextStyle(fontSize: 12, fontFamily: 'monospace');
      default:
        return TextStyle(fontSize: 13, color: cs.onSurface);
    }
  }

  // ── list ────────────────────────────────────────────────────────────────

  Widget _list(BuildContext context, PluginUiNode node) {
    final List<Object?> items = node.listOrEmpty('items');
    if (items.isEmpty) {
      return _hint(context, node.str('empty', fallback: '暂无数据'));
    }
    final bool ordered = node.boolOr('ordered');
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  ordered ? '${i + 1}. ' : '· ',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
                Expanded(child: _itemContent(context, items[i])),
              ],
            ),
          ),
      ],
    );
  }

  /// 列表项内容：对象按节点递归渲染，标量按文本渲染。
  Widget _itemContent(BuildContext context, Object? item) {
    final PluginUiNode? node = PluginUiNode.tryParse(item);
    if (node != null) {
      return buildNode(context, node);
    }
    return Text(
      _cellText(item),
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  // ── table ───────────────────────────────────────────────────────────────

  Widget _table(BuildContext context, PluginUiNode node) {
    final List<String> columns = <String>[
      for (final Object? c in node.listOrEmpty('columns')) _cellText(c),
    ];
    final List<List<String>> rows = <List<String>>[];
    for (final Object? raw in node.listOrEmpty('rows')) {
      if (raw is List) {
        rows.add(<String>[for (final Object? c in raw) _cellText(c)]);
      }
    }
    final String caption = node.str('caption');
    if (columns.isEmpty && rows.isEmpty) {
      return _hint(context, caption.isEmpty ? '暂无数据' : caption);
    }
    // 列数取「表头列数」与「最宽行」的较大者：行比表头长也不丢单元格
    int columnCount = columns.length;
    for (final List<String> row in rows) {
      if (row.length > columnCount) {
        columnCount = row.length;
      }
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (caption.isNotEmpty) ...<Widget>[
          Text(
            caption,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
        ],
        Table(
          border: TableBorder.all(
            color: Theme.of(context).dividerColor,
            width: 0.5,
          ),
          defaultColumnWidth: const FlexColumnWidth(),
          children: <TableRow>[
            if (columns.isNotEmpty)
              TableRow(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                ),
                children: <Widget>[
                  for (int c = 0; c < columnCount; c++)
                    _cell(
                      context,
                      c < columns.length ? columns[c] : '',
                      header: true,
                    ),
                ],
              ),
            for (final List<String> row in rows)
              TableRow(
                children: <Widget>[
                  for (int c = 0; c < columnCount; c++)
                    _cell(context, c < row.length ? row[c] : '', header: false),
                ],
              ),
          ],
        ),
      ],
    );
  }

  Widget _cell(BuildContext context, String text, {required bool header}) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: header ? FontWeight.w600 : FontWeight.normal,
          color: header ? cs.onSurface : cs.onSurfaceVariant,
        ),
      ),
    );
  }

  // ── progress ────────────────────────────────────────────────────────────

  Widget _progress(BuildContext context, PluginUiNode node) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double? raw = node.numOrNull('value');
    final bool indeterminate = node.boolOr('indeterminate') || raw == null;
    final String label = node.str('label');
    final String detail = node.str('detail');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (label.isNotEmpty || detail.isNotEmpty) ...<Widget>[
          Row(
            children: <Widget>[
              if (label.isNotEmpty)
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 12, color: cs.onSurface),
                  ),
                )
              else
                const Spacer(),
              if (detail.isNotEmpty)
                Text(
                  detail,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: 4),
        ],
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: indeterminate ? null : raw.clamp(0.0, 1.0),
            minHeight: 4,
            backgroundColor: cs.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }

  // ── actions ─────────────────────────────────────────────────────────────

  Widget _actions(BuildContext context, PluginUiNode node) {
    final List<PluginUiButton> buttons = <PluginUiButton>[];
    for (final Object? raw in node.listOrEmpty('buttons')) {
      final PluginUiButton? button = PluginUiButton.tryParse(raw);
      if (button != null) {
        buttons.add(button);
      }
    }
    if (buttons.isEmpty) {
      return _hint(context, '（无可用操作）');
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment:
          node.str('align') == 'end' ? WrapAlignment.end : WrapAlignment.start,
      children: <Widget>[
        for (final PluginUiButton button in buttons) _button(context, button),
      ],
    );
  }

  Widget _button(BuildContext context, PluginUiButton button) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final VoidCallback? onPressed = button.enabled
        ? () => dispatch(context, button.actionId, button.payload)
        : null;
    switch (button.style) {
      case PluginUiButtonStyle.primary:
        return FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            minimumSize: Size.zero,
            textStyle: const TextStyle(fontSize: 12),
          ),
          child: Text(button.label),
        );
      case PluginUiButtonStyle.danger:
        return FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: cs.error,
            foregroundColor: cs.onError,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            minimumSize: Size.zero,
            textStyle: const TextStyle(fontSize: 12),
          ),
          child: Text(button.label),
        );
      default:
        return OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            minimumSize: Size.zero,
            textStyle: const TextStyle(fontSize: 12),
          ),
          child: Text(button.label),
        );
    }
  }

  // ── 容器 ────────────────────────────────────────────────────────────────

  Widget _column(BuildContext context, PluginUiNode node) {
    final List<PluginUiNode> children = node.children;
    final double gap = node.numOrNull('gap') ?? 8;
    if (children.isEmpty) {
      return _hint(context, '');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: gap),
          buildNode(context, children[i]),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, PluginUiNode node) {
    final List<PluginUiNode> children = node.children;
    final double gap = node.numOrNull('gap') ?? 8;
    if (children.isEmpty) {
      return _hint(context, '');
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0) SizedBox(width: gap),
          Expanded(child: buildNode(context, children[i])),
        ],
      ],
    );
  }

  // ── 动作派发 ────────────────────────────────────────────────────────────

  /// 派发一次交互（按钮点击）。
  ///
  /// 发送失败（未连接核心 / 未接发送通道）时给一条 SnackBar 提示——不能"点了
  /// 毫无反应"，但也绝不抛异常。没有 ScaffoldMessenger 的宿主（如单测）静默跳过。
  void dispatch(
    BuildContext context,
    String actionId,
    Map<String, dynamic> payload,
  ) {
    final bool sent = _registry.dispatchAction(
      slotKey: slot.slotKey,
      actionId: actionId,
      payload: payload,
      agentId: agentId,
      sessionId: sessionId,
    );
    if (sent) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('插件未连接，动作未发送'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  // ── 工具 ────────────────────────────────────────────────────────────────

  Widget _hint(BuildContext context, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// 单元格 / 列表项文本：标量直接 $toString()，非标量用紧凑 JSON 兜底。
  static String _cellText(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is String) {
      return value;
    }
    if (value is num || value is bool) {
      return value.toString();
    }
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }
}

/// 表单节点（有状态：字段值来自用户输入，提交时组装 payload）。
///
/// 提交口径（与协议包 [PluginUiAction.payload] 的 dartdoc 一致）：
/// `payload = {...submit.payload, ...各字段当前值}`——**字段值覆盖同名键**；
/// 字段值类型：`number` → `num`（非法输入回退原字符串）、`checkbox` → `bool`、
/// 其余 → `String`；`submit.action_id` 缺省时回退 `'submit'`，标签回退「提交」。
/// `required` 只做界面提示，不拦截提交（拦截交由插件判定）。
class _PluginFormNode extends StatefulWidget {
  const _PluginFormNode({
    super.key,
    required this.slot,
    required this.node,
    required this.registry,
    required this.agentId,
    required this.sessionId,
  });

  final PluginUiSlot slot;
  final PluginUiNode node;
  final PluginUiRegistry registry;
  final String agentId;
  final String sessionId;

  @override
  State<_PluginFormNode> createState() => _PluginFormNodeState();
}

class _PluginFormNodeState extends State<_PluginFormNode> {
  /// 字段定义（坏字段已在解析时跳过）。
  List<PluginUiField> _fields = <PluginUiField>[];

  /// 文本类字段控制器（key -> controller）。
  final Map<String, TextEditingController> _texts =
      <String, TextEditingController>{};

  /// 勾选框状态（key -> 是否勾选）。
  final Map<String, bool> _checks = <String, bool>{};

  /// 下拉选择状态（key -> 当前值）。
  final Map<String, String> _selects = <String, String>{};

  @override
  void initState() {
    super.initState();
    _resetFields();
  }

  @override
  void dispose() {
    for (final TextEditingController controller in _texts.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 按节点 JSON 重建字段状态（整块替换语义：新视图 ⇒ 新表单）。
  void _resetFields() {
    for (final TextEditingController controller in _texts.values) {
      controller.dispose();
    }
    _texts.clear();
    _checks.clear();
    _selects.clear();
    _fields = <PluginUiField>[];
    for (final Object? raw in widget.node.listOrEmpty('fields')) {
      final PluginUiField? field = PluginUiField.tryParse(raw);
      if (field == null) {
        continue;
      }
      _fields.add(field);
      final String initial = field.value?.toString() ?? '';
      switch (field.kind) {
        case PluginUiFieldKind.checkbox:
          _checks[field.key] = field.value == true;
          break;
        case PluginUiFieldKind.select:
          final List<String> options = field.options;
          _selects[field.key] = options.contains(initial)
              ? initial
              : (options.isEmpty ? '' : options.first);
          break;
        default:
          _texts[field.key] = TextEditingController(text: initial);
      }
    }
  }

  /// 各字段当前值。
  Map<String, dynamic> _values() {
    final Map<String, dynamic> values = <String, dynamic>{};
    for (final PluginUiField field in _fields) {
      switch (field.kind) {
        case PluginUiFieldKind.checkbox:
          values[field.key] = _checks[field.key] ?? false;
          break;
        case PluginUiFieldKind.select:
          values[field.key] = _selects[field.key] ?? '';
          break;
        case PluginUiFieldKind.number:
          final String text = _texts[field.key]?.text.trim() ?? '';
          values[field.key] = num.tryParse(text) ?? text;
          break;
        default:
          values[field.key] = _texts[field.key]?.text ?? '';
      }
    }
    return values;
  }

  /// 提交按钮的配置（`submit` 块；缺省时用兜底 action_id 与标签）。
  Map<String, dynamic> get _submit {
    final Object? raw = widget.node.raw['submit'];
    return raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
  }

  /// 提交：组装 payload 并派发 `plugin_ui_action`。
  void _handleSubmit() {
    final Map<String, dynamic> submit = _submit;
    final Object? submitPayload = submit['payload'];
    final Map<String, dynamic> payload = <String, dynamic>{
      ...(submitPayload is Map
          ? Map<String, dynamic>.from(submitPayload)
          : const <String, dynamic>{}),
      ..._values(),
    };
    final String actionId = (submit['action_id'] ?? '').toString();
    final bool sent = widget.registry.dispatchAction(
      slotKey: widget.slot.slotKey,
      actionId: actionId.isEmpty ? 'submit' : actionId,
      payload: payload,
      agentId: widget.agentId,
      sessionId: widget.sessionId,
    );
    if (sent) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('插件未连接，动作未发送'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String note = widget.node.str('note');
    final String submitLabel = (_submit['label'] ?? '').toString();
    if (_fields.isEmpty) {
      return Text(
        '（无字段）',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final PluginUiField field in _fields) _field(context, field),
        if (note.isNotEmpty) ...<Widget>[
          Text(
            note,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: _handleSubmit,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              minimumSize: Size.zero,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: Text(submitLabel.isEmpty ? '提交' : submitLabel),
          ),
        ),
      ],
    );
  }

  /// 单个字段（按类型渲染，`required` 只加星号提示）。
  Widget _field(BuildContext context, PluginUiField field) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextStyle labelStyle = TextStyle(
      fontSize: 12,
      color: cs.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(field.required ? '${field.label} *' : field.label, style: labelStyle),
          const SizedBox(height: 3),
          switch (field.kind) {
            PluginUiFieldKind.checkbox => Row(
              children: <Widget>[
                Checkbox(
                  value: _checks[field.key] ?? false,
                  visualDensity: VisualDensity.compact,
                  onChanged: (bool? value) =>
                      setState(() => _checks[field.key] = value ?? false),
                ),
                if (field.help.isNotEmpty)
                  Expanded(
                    child: Text(
                      field.help,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            PluginUiFieldKind.select => DropdownButtonFormField<String>(
              initialValue: _selects[field.key],
              isDense: true,
              decoration: _decoration(field),
              items: <DropdownMenuItem<String>>[
                for (final String option in field.options)
                  DropdownMenuItem<String>(
                    value: option,
                    child: Text(option, style: const TextStyle(fontSize: 12)),
                  ),
              ],
              onChanged: (String? value) =>
                  setState(() => _selects[field.key] = value ?? ''),
            ),
            PluginUiFieldKind.textarea => TextField(
              controller: _texts[field.key],
              maxLines: 4,
              minLines: 2,
              style: const TextStyle(fontSize: 12),
              decoration: _decoration(field),
            ),
            PluginUiFieldKind.number => TextField(
              controller: _texts[field.key],
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 12),
              decoration: _decoration(field),
            ),
            _ => TextField(
              controller: _texts[field.key],
              style: const TextStyle(fontSize: 12),
              decoration: _decoration(field),
            ),
          },
          if (field.kind != PluginUiFieldKind.checkbox && field.help.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                field.help,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  InputDecoration _decoration(PluginUiField field) {
    return InputDecoration(
      isDense: true,
      hintText: field.placeholder.isEmpty ? null : field.placeholder,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      border: const OutlineInputBorder(),
    );
  }
}
