import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/message.dart';
import '../services/detail_selection.dart';

/// 一次推理的**一行**：图标 + 「思考」 + 首行摘要。
///
/// 与工具行同一套排版：默认只占一行，完整推理内容去右栏「详情」页看（点这一行）。
/// 理由同工具行——一轮任务里思考与工具交替出现几十次，卡片会把消息流撑散；
/// 一行之后"想了什么、做了什么"排在一起，像一条时间线。
class ThinkingCard extends StatefulWidget {
  final ChatMessage message;

  const ThinkingCard({super.key, required this.message});

  @override
  State<ThinkingCard> createState() => _ThinkingCardState();
}

class _ThinkingCardState extends State<ThinkingCard> {
  /// 鼠标是否停在这一行上（图标与箭头提亮；底色由 InkWell 画）
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ChatMessage m = widget.message;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool running = m.isStreaming;
    final String text = m.content.trim();
    final String summary = text.isEmpty ? '正在分析问题…' : thinkingSummary(text);

    return ListenableBuilder(
      listenable: DetailSelection.instance,
      builder: (BuildContext context, Widget? child) {
        final bool isSelected = DetailSelection.instance.selectedId == m.id;
        return MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Material(
            color: isSelected
                ? cs.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              hoverColor: cs.primary.withValues(alpha: 0.07),
              // 与工具行同一口径：点一下选中、再点一下取消
      onTap: () => DetailSelection.instance.toggle(m),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  children: <Widget>[
                    Icon(
                      running ? Icons.psychology : Icons.psychology_outlined,
                      size: 15,
                      color: _hover || isSelected
                          ? cs.tertiary
                          : cs.tertiary.withValues(alpha: 0.75),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      running ? '思考中' : '思考',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (running)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.tertiary,
                        ),
                      )
                    else
                      Icon(
                        Icons.chevron_right,
                        size: 14,
                        color: _hover || isSelected ? cs.primary : cs.outline,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 折叠成一行时的摘要：取第一段非空内容，去掉 markdown 标记与多余空白，截断 80 字。
///
/// **只扫头部窗口**（巨型 thinking 实测单段 10 万+ 字）：这一行只在 80 字内截断，
/// 而 ThinkingCard 每个增量帧都会重建——旧实现对全文 split + 两遍正则，等于把
/// O(全文) 的扫描钉死在每帧上（摘要永远看不到的那一段也扫）。窗口外的内容
/// 不可能影响这 80 字：除非前 512 字全是空行（极端形态，窗口内取到什么都差不多）。
String thinkingSummary(String text) {
  const int window = 512;
  final String head = text.length > window ? text.substring(0, window) : text;
  final String line = head
      .split('\n')
      .firstWhere(
        (String l) => l.trim().isNotEmpty,
        orElse: () => head,
      )
      .trim();
  // 去掉 markdown 标记后**还要再 trim 一次**：『## 标题』去掉 # 会留下前导空格
  final String cleaned = line
      .replaceAll(RegExp(r'[#*`>|-]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.length > 80 ? '${cleaned.substring(0, 80)}…' : cleaned;
}

/// 完整推理内容（右栏「详情」页用）：markdown 渲染 + 可选中。
///
/// **分块增量渲染**：thinking 单段实测可到 10 万+ 字，而流式期间每个增量帧
/// 父面板都会 setState——旧结构里 MarkdownBody 拿全量文本，等于每帧一次
/// 全文重解析 + 全文重排版（“生成慢时界面卡死”最大头）。现在把文本按
/// ~6000 字定居成块：**写完的块保持同一个 widget 实例**，Flutter 对同实例
/// 在 updateChild 直接短路，不再碰解析/排版；只有正在写的尾块每帧重画。
/// 全量历史都在场、可回滚阅读，每帧成本封顶在常数（尾部块大小）。
class ThinkingDetail extends StatefulWidget {
  const ThinkingDetail({super.key, required this.message});

  final ChatMessage message;

  /// 定居块的目标字数：超过这个长度的尾部文本会被切成块固定下来。
  static const int blockChars = 6000;

  /// 尾块硬顶：长时间找不到换行 / 围栏不闭合时，到这个字数强制切块
  /// （防“单行 10 万字的 thinking”把尾块养回巨型）。
  static const int tailCharsCap = 4 * blockChars;

  @override
  State<ThinkingDetail> createState() => _ThinkingDetailState();
}

class _ThinkingDetailState extends State<ThinkingDetail> {
  /// 定居块的 MarkdownBody 实例：实例同一就是缓存键（见类注释）。
  final List<Widget> _settled = <Widget>[];

  /// 已定居的字符数：只扫描 [已定居, 新尾部) 这一段，扫描成本 O(新到达)/帧。
  int _settledChars = 0;

  /// 定居边界处的围栏态：true = 上一块结尾还卡在未闭合 ``` 里，
  /// 下一块要合成一个开围栏再接正文（否则每块单独解析会把代码掉回正文）。
  bool _insideFence = false;

  /// 建缓存时的主题：换肤时定居块里藏着旧 styleSheet，整段重建一次。
  ColorScheme? _cachedScheme;

  void _reset() {
    _settled.clear();
    _settledChars = 0;
    _insideFence = false;
  }

  @override
  void didUpdateWidget(ThinkingDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切到另一条消息：缓存整体作废（content 不同源，不能接着定居）
    if (oldWidget.message.id != widget.message.id) _reset();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (_cachedScheme != null && !identical(_cachedScheme, cs)) _reset();
    _cachedScheme = cs;

    final ChatMessage m = widget.message;
    final String text = m.content;
    if (text.trim().isEmpty) {
      return Row(
        children: <Widget>[
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            '思考中…',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      );
    }
    if (text.length < _settledChars) _reset();
    _advance(text, m.isStreaming, cs);
    final int tailLen = text.length - _settledChars;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (m.isStreaming)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '思考中…（内容还在追加）',
              style: TextStyle(fontSize: 11, color: cs.tertiary),
            ),
          ),
        ..._settled,
        // 尾块：正在写的一块，每帧重解析——尺寸被定居逻辑封顶在常数。
        // 封口后 _advance 会把余量全部定居，这一项自然消失（重建零成本）。
        if (tailLen > 0) _markdown(_insideFence ? '```\n${text.substring(_settledChars)}' : text.substring(_settledChars), cs),
      ],
    );
  }

  Widget _markdown(String data, ColorScheme cs) => MarkdownBody(
    data: data,
    selectable: true,
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: TextStyle(fontSize: 13, height: 1.6, color: cs.onSurfaceVariant),
    ),
  );

  /// 把新到达的尾部增量逐步定居成块：只碰 [_settledChars, text.length)，
  /// 所以每帧扫描成本 = O(本帧新到达)，与全文长度无关。
  void _advance(String text, bool streaming, ColorScheme cs) {
    // 封口后把余量（哪怕不足一块）也定居掉：重建时零重解析
    while (text.length - _settledChars > (streaming ? ThinkingDetail.blockChars : 0)) {
      final int remaining = text.length - _settledChars;
      final int cut = _cutPoint(text);
      final String piece = text.substring(_settledChars, cut);
      final bool endsOpen = _insideFence || _countFences(piece).isOdd;
      if (streaming && endsOpen && remaining <= ThinkingDetail.tailCharsCap) {
        // 围栏没闭合：整段先留在尾块里，不拿半截代码去定居
        // （每块单独解析，开围栏的块会把后面正文错排成代码）
        break;
      }
      final String data =
          '${_insideFence ? '```\n' : ''}$piece${endsOpen ? '\n```' : ''}';
      _settled.add(_markdown(data, cs));
      _insideFence = endsOpen;
      _settledChars = cut;
    }
  }

  /// 切点：优先取「距已定居处 ≥ blockChars 的第一个换行后」；找不到
  /// （thinking 常见：单行几万字）就在 blockChars 处硬切；硬切点落在
  /// 代理对中间时往后让一格，不切出半个表情。
  int _cutPoint(String text) {
    int cut;
    final int from = _settledChars + ThinkingDetail.blockChars;
    // indexOf 的 start 超出字符串长度会直接抛 RangeError，先夹紧
    final int nl =
        from >= text.length ? -1 : text.indexOf('\n', from);
    if (nl < 0 || nl - _settledChars > ThinkingDetail.tailCharsCap) {
      cut = _settledChars + ThinkingDetail.blockChars;
      if (cut < text.length &&
          text.codeUnitAt(cut) >= 0xDC00 &&
          text.codeUnitAt(cut) <= 0xDFFF) {
        cut += 1;
      }
    } else {
      cut = nl + 1;
    }
    if (cut > text.length) cut = text.length;
    return cut;
  }

  static int _countFences(String s) {
    int n = 0;
    int i = s.indexOf('```');
    while (i >= 0) {
      n++;
      i = s.indexOf('```', i + 3);
    }
    return n;
  }
}
