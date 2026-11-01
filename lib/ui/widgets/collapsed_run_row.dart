import 'package:flutter/material.dart';

/// 折叠组的一行控制条（规格 §3.2.2）。
///
/// 文案：「折叠 n 次工具调用（读取×3 · 编辑×2 · …）· 含 m 段思考，点击展开 ›」；
/// 纯思考组（无工具）：「折叠 m 段思考，点击展开 ›」；展开态把「折叠 …」前缀去掉、
/// 动词换成「点击收起」。样式对齐 [ToolCallCard] 的一行式（单行、超长省略号）。
///
/// **简述零后端成本**：计数由渲染层对 run 内显示行现算（`tool_name` 本来就在显示
/// 数据里），详细数据不碰。
class CollapsedRunRow extends StatelessWidget {
  const CollapsedRunRow({
    super.key,
    required this.toolCount,
    required this.thinkingCount,
    required this.toolCountsByLabel,
    required this.expanded,
    required this.onTap,
  });

  /// 组内已完成工具条数
  final int toolCount;

  /// 组内思考段条数（只计数、不分型）
  final int thinkingCount;

  /// 按 `toolLabel` 分类的工具计数（渲染层现算）
  final Map<String, int> toolCountsByLabel;

  /// 当前组是否处于展开态（决定「点击展开」还是「点击收起」）
  final bool expanded;

  final VoidCallback onTap;

  /// 类型简述：按条数降序保留前 4 类，其余并入「等×k」（规格 §3.2.2）。
  String get _typeSummary {
    if (toolCountsByLabel.isEmpty) return '';
    final List<MapEntry<String, int>> entries =
        toolCountsByLabel.entries.toList()
          ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
            final int byCount = b.value.compareTo(a.value);
            return byCount != 0 ? byCount : a.key.compareTo(b.key);
          });
    const int keep = 4;
    final List<String> parts = <String>[
      for (final MapEntry<String, int> e in entries.take(keep))
        '${e.key}×${e.value}',
    ];
    if (entries.length > keep) {
      final int rest = entries
          .skip(keep)
          .fold<int>(0, (int s, MapEntry<String, int> e) => s + e.value);
      parts.add('等×$rest');
    }
    return parts.join(' · ');
  }

  String get _text {
    final String verb = expanded ? '点击收起' : '点击展开';
    if (toolCount == 0) {
      return '${expanded ? '' : '折叠 '}$thinkingCount 段思考，$verb ›';
    }
    final String think = thinkingCount > 0 ? '· 含 $thinkingCount 段思考' : '';
    return '${expanded ? '' : '折叠 '}$toolCount 次工具调用（$_typeSummary）'
        '$think，$verb ›';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        hoverColor: cs.primary.withValues(alpha: 0.07),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: <Widget>[
              Icon(
                expanded ? Icons.expand_less : Icons.unfold_more,
                size: 15,
                color: cs.primary.withValues(alpha: 0.75),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
