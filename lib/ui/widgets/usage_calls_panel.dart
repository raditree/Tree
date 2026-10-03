import 'package:flutter/material.dart';

/// 一次 LLM 调用的用量读数（**纯数据**：把两种来源形态归一到同一个模型上）。
///
/// 为什么要有它：核心每次调用 LLM 都会产出一条用量，但这块数据有**两种形态**，
/// 而看的人只关心"这一轮到底花了多少"：
/// 1. **实时帧**：WS `msg_usage` / `msg_end` 里的 `usage` map——键为 `prompt_tokens` /
///    `completion_tokens` / `total_tokens` / `max_tokens`，外加可选的 `cached_tokens`
///    （>0 才带）、`estimated`（true = 数值是本地估算）、`trimmed_messages`。
///    这种帧**没有** `source` / `model` / `at` / `duration_ms`，所以它们缺省为
///    `turn` / `''` / null / null。
/// 2. **落库历史**：`<会话目录>/usage.jsonl` 的一行——`at`(ISO-8601) / `source` /
///    `model` / `prompt_tokens` / `cached_tokens` / `completion_tokens` / `estimated` /
///    `duration_ms`。
///
/// **null ≠ 0**：`cached_tokens == null` 表示"端点根本没报这个字段"，与"命中了 0 个
/// token"是两件事，所以字段本身可空、UI 显示 `—` 而不是 `0`。`duration_ms` 同理。
///
/// 这个类是**自包含**的：不 import 任何 io / service，数据一律由接线方传入
/// （实时帧与 usage.jsonl 谁先到都能直接 `fromUsage` 吃下来）。
class UsageCallView {
  const UsageCallView({
    this.source = 'turn',
    this.model = '',
    this.promptTokens = 0,
    this.cachedTokens,
    this.completionTokens = 0,
    this.estimated = false,
    this.durationMs,
    this.at,
  });

  /// 调用来源：`turn`（对话）/ `compact`（内置压缩）/ `llm.call`（插件发起）/
  /// `plugin`（插件接管）；实时帧没有这个字段 ⇒ 默认 `turn`。
  final String source;

  /// 模型名（实时帧 / 老落库行可能没有 ⇒ 空串）。
  final String model;

  /// 输入（prompt）token 数。
  final int promptTokens;

  /// 缓存命中 token 数；**null = 端点没报这个字段**（≠ 0）。
  final int? cachedTokens;

  /// 输出（completion）token 数。
  final int completionTokens;

  /// 数值是否为本地估算（端点没给真实用量时由核心估算）。
  final bool estimated;

  /// 本次调用耗时（毫秒）；读数没带 ⇒ null。
  final int? durationMs;

  /// 这条读数的时间（实时帧没有 ⇒ null）。
  final DateTime? at;

  /// 从**任意一种**形态的 map 解析（实时帧的 `usage` map 或 `usage.jsonl` 的一行）。
  ///
  /// 全程**不抛异常**：类型不对 / 解析不出 / 键缺失，一律退回默认值；只有真正
  /// "没有这个信息"（`cached_tokens` / `duration_ms` / `at` 缺失或 null）才留 null。
  factory UsageCallView.fromUsage(Map<String, dynamic> json) {
    return UsageCallView(
      source: _asString(json['source']) ?? 'turn',
      model: _asString(json['model']) ?? '',
      promptTokens: _asInt(json['prompt_tokens']) ?? 0,
      cachedTokens: _asInt(json['cached_tokens']),
      completionTokens: _asInt(json['completion_tokens']) ?? 0,
      estimated: _asBool(json['estimated']) ?? false,
      durationMs: _asInt(json['duration_ms']),
      at: _asTime(json['at']),
    );
  }

  /// 逐项解析（实时帧列表 / usage.jsonl 每行 JSON 解码后的列表都能直接喂）；
  /// 非 Map 项（null、字符串、数字……）**跳过**，不抛异常。
  static List<UsageCallView> fromUsages(Iterable<Object?> raw) {
    final List<UsageCallView> out = <UsageCallView>[];
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final Map<String, dynamic> map = <String, dynamic>{};
      item.forEach((Object? key, Object? value) {
        if (key != null) map[key.toString()] = value;
      });
      out.add(UsageCallView.fromUsage(map));
    }
    return out;
  }
}

/// 折叠区「本轮调用列表」：头部一行写清有多少次，展开后每行一次调用（来源 / 输入 /
/// 缓存命中 / 输出 / 耗时）。
///
/// 默认**折叠**：用量是"需要才查"的信息，不该默认把中栏占满；`maxRows > 0` 时
/// 只展示**最后** N 条（长会话下"最近几次"才是用户要看的），截断在标题里写明。
class UsageCallsPanel extends StatefulWidget {
  const UsageCallsPanel({
    super.key,
    required this.calls,
    this.initiallyExpanded = false,
    this.maxRows = 0,
  });

  /// 逐调用用量（按时间从旧到新）。空列表也算正常状态（还没调用过）。
  final List<UsageCallView> calls;

  /// 首帧是否展开（缺省折叠）。
  final bool initiallyExpanded;

  /// `> 0` 时只显示**最后** maxRows 条；`<= 0` 表示全显示。
  final int maxRows;

  @override
  State<UsageCallsPanel> createState() => _UsageCallsPanelState();
}

class _UsageCallsPanelState extends State<UsageCallsPanel> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  /// 真正要渲染的那几条（maxRows 截断只取**尾部**，截断信息不进 [UsageCallView]）。
  List<UsageCallView> get _visible {
    final List<UsageCallView> all = widget.calls;
    final int max = widget.maxRows;
    if (max <= 0 || all.length <= max) return all;
    return all.sublist(all.length - max);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final List<UsageCallView> visible = _visible;
    final int total = widget.calls.length;
    final bool truncated = visible.length < total;

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 头部整体可点：折叠状态下"点标题"就能展开（测试与用户都走这条路）。
          InkWell(
            key: const Key('usage-calls-header'),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: <Widget>[
                  Icon(Icons.insights_outlined, size: 16, color: cs.primary),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      truncated
                          ? '本轮调用列表（最近 ${visible.length} 次）'
                          : '本轮调用列表（${visible.length} 次）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (truncated) ...<Widget>[
                    const SizedBox(width: 6),
                    Text(
                      '共 $total 次',
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    _expanded ? '收起' : '展开',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          // 折叠时**不建**子树（而不是 Offstage/透明度）：既省渲染，也让"折叠 =
          // 找不到行内容"成为一条可靠的断言。
          if (_expanded) ...<Widget>[
            Divider(height: 1, thickness: 1, color: cs.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: visible.isEmpty
                  ? Text(
                      '暂无调用记录',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (final UsageCallView call in visible)
                          _UsageCallRow(call: call),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一次调用的一行：来源 / 输入 / 缓存命中 / 输出 / 耗时（估算行额外挂标记）。
class _UsageCallRow extends StatelessWidget {
  const _UsageCallRow({required this.call});

  final UsageCallView call;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.6),
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            flex: 3,
            child: _MetricCell(
              label: '来源',
              value: usageSourceLabel(call.source),
              note: call.model.isEmpty ? null : call.model,
            ),
          ),
          Expanded(
            flex: 2,
            child: _MetricCell(
              label: '输入',
              value: formatTokenCount(call.promptTokens),
            ),
          ),
          Expanded(
            flex: 2,
            child: _MetricCell(
              label: '缓存命中',
              // null = 端点没报（≠ 0），这里必须是 `—`。
              value: call.cachedTokens == null
                  ? '—'
                  : formatTokenCount(call.cachedTokens!),
            ),
          ),
          Expanded(
            flex: 2,
            child: _MetricCell(
              label: '输出',
              value: formatTokenCount(call.completionTokens),
            ),
          ),
          Expanded(
            flex: 2,
            child: _MetricCell(
              label: '耗时',
              value: call.durationMs == null
                  ? '—'
                  : formatDurationMs(call.durationMs!),
            ),
          ),
          if (call.estimated)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 1),
              child: Tooltip(
                message: '本地估算：端点没有返回真实用量',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: cs.tertiaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '估算',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: cs.onTertiaryContainer,
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

/// 一格：小标签在上、值在下（可选第三行放模型名等附注）。
class _MetricCell extends StatelessWidget {
  const _MetricCell({
    required this.label,
    required this.value,
    this.note,
  });

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String? noteText = note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10, height: 1.2, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 1),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, height: 1.25, color: cs.onSurface),
        ),
        if (noteText != null)
          Text(
            noteText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9, height: 1.2, color: cs.onSurfaceVariant),
          ),
      ],
    );
  }
}

/// 来源文案映射（`turn` 是实时帧的默认值，所以它也必须是"对话"）。
String usageSourceLabel(String source) {
  switch (source) {
    case 'turn':
      return '对话';
    case 'compact':
      return '内置压缩';
    case 'llm.call':
      return '插件 llm.call';
    case 'plugin':
      return '插件接管';
    default:
      return source;
  }
}

/// 千分位（`1234` → `1,234`；负数保留符号）：不引第三方，手写即可。
String formatTokenCount(int value) {
  final bool negative = value < 0;
  final String digits = value.abs().toString();
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return negative ? '-$buffer' : buffer.toString();
}

/// 耗时文案：`>= 1000ms` 折成秒（一位小数，`1800` → `1.8s`），否则毫秒（`832ms`）。
String formatDurationMs(int ms) {
  if (ms >= 1000) return '${(ms / 1000).toStringAsFixed(1)}s';
  return '${ms}ms';
}

// ---- 解析容错：类型不对 / 解析不出返回 null（由调用方决定默认值），永不抛异常 ----

String? _asString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is double) {
    if (value.isNaN || value.isInfinite) return null;
    return value.toInt();
  }
  if (value is String) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final int? asInt = int.tryParse(trimmed);
    if (asInt != null) return asInt;
    final double? asDouble = double.tryParse(trimmed);
    if (asDouble == null || asDouble.isNaN || asDouble.isInfinite) return null;
    return asDouble.toInt();
  }
  return null;
}

bool? _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
      case '':
        return false;
    }
  }
  return null;
}

DateTime? _asTime(Object? value) {
  if (value is DateTime) return value;
  if (value is String) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : DateTime.tryParse(trimmed);
  }
  // 容错：少数调用方直接给 epoch 毫秒。
  if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  return null;
}
