import 'package:flutter/material.dart';

/// 左栏 Agent 列表用的一组**纯格式化函数**。
///
/// 抽出来独立成文件的理由：
/// - 它们只做"数据 → 展示文本/颜色"的转换，跟 widget 结构无关；
/// - 独立后可以**单独测**（无需 pump widget，速度快、覆盖到位）；
/// - 消息面板 / 成员列表将来若要用同一个"预览剥离 markdown"，直接 import 即可。

/// team 调色板。**顺序固定**——插入新色只能往后加，不能改中间顺序
/// （否则已存在的 team 颜色会整体错位，跨会话看起来像"团队换了身份"）。
const List<Color> kTeamPalette = <Color>[
  Color(0xFF4C8DFF), // 蓝
  Color(0xFF5EBD8F), // 绿
  Color(0xFFE0A93B), // 琥珀
  Color(0xFFB47BE0), // 紫
  Color(0xFFE06C75), // 红
  Color(0xFF38B7B0), // 青
  Color(0xFFD08A57), // 棕
  Color(0xFF7C9CD8), // 淡蓝
];

/// 稳定的 team → 颜色映射（同一 teamId 永远同色）。
///
/// 用 `teamId` 而不是 name：name 可改可重名，id 不会。`teamId` 为空
/// （顶层 agent 自身就是团队）也走同一套 hash——它同样需要一个稳定色。
Color teamColorFor(String teamId) {
  if (teamId.isEmpty) return const Color(0xFF8A8A8A); // 中性灰兜底
  int h = 0;
  for (final int c in teamId.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return kTeamPalette[h % kTeamPalette.length];
}

/// 相对时间：
/// - null：空串
/// - 未来 / < 1 分钟：刚刚
/// - < 1 小时：N 分钟前
/// - 同一天：HH:MM
/// - 昨天：昨天
/// - 一周内：周一…周日
/// - 今年内：M/D
/// - 更早：YYYY/M/D
///
/// [now] 是**测试注入点**（默认真实时钟）。生产代码不传，行为与以前一致；
/// 测试传一个固定时刻，断言才稳定（否则跨分钟 / 跨天时用例会随机翻红）。
String relativeTime(DateTime? time, {DateTime? now}) {
  if (time == null) return '';
  final DateTime reference = now ?? DateTime.now();
  final Duration diff = reference.difference(time);
  if (diff.isNegative) return '刚刚';
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  final bool sameDay = reference.year == time.year &&
      reference.month == time.month &&
      reference.day == time.day;
  if (sameDay) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }
  final DateTime yesterday = reference.subtract(const Duration(days: 1));
  if (yesterday.year == time.year &&
      yesterday.month == time.month &&
      yesterday.day == time.day) {
    return '昨天';
  }
  if (diff.inDays < 7) {
    const List<String> week = <String>[
      '周一', '周二', '周三', '周四', '周五', '周六', '周日',
    ];
    return week[time.weekday - 1];
  }
  if (reference.year == time.year) {
    return '${time.month}/${time.day}';
  }
  return '${time.year}/${time.month}/${time.day}';
}

/// 把最后一条消息剥成可读的一行预览。
///
/// `agent.lastMessage` 可能带 markdown 标记（`## 轮次汇报`、`- [ ] 项` 之类），
/// 直接把原文塞进列表会读成"半截正文"。这里**只清标记、不改词**：去掉代码块围栏、
/// 标题 / 列表 / 引用的行首标记、行内强调与链接语法，最后折叠空白。空结果回落到
/// "暂无消息"。
String previewOf(String raw) {
  if (raw.trim().isEmpty) return '暂无消息';
  String s = raw;
  s = s.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
  s = s.replaceAll(RegExp(r'^\s*#{1,6}\s*', multiLine: true), '');
  s = s.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
  s = s.replaceAll(RegExp(r'^\s*\d+\.\s+', multiLine: true), '');
  s = s.replaceAll(RegExp(r'^\s*>\s*', multiLine: true), '');
  // ⚠ `String.replaceAll(Pattern, String)` **不做** `$1` 反向引用展开——
  // 替换串里的 `$1` 会原样输出（Dart 与 JS / Python 在这点上不同）。
  // 要回填捕获组必须走 `replaceAllMapped` + `m.group(1)!`。
  s = s.replaceAllMapped(RegExp(r'`([^`]*)`'), (Match m) => m.group(1)!);
  s = s.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (Match m) => m.group(1)!);
  s = s.replaceAllMapped(RegExp(r'\*([^*]+)\*'), (Match m) => m.group(1)!);
  s = s.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\([^)]*\)'), (Match m) => m.group(1)!);
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.isEmpty ? '暂无消息' : s;
}