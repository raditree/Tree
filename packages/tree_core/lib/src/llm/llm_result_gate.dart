import 'dart:math' as math;

import '../util/tokens.dart';

/// 超长工具结果的重定向写入器：把**完整原文**写到工作空间相对路径。
///
/// [agentId] 由调用方（引擎）绑定，这里保留该参数是为了让同一个写入器实例也能
/// 服务不同 agent——本地与 SSH 两条工作空间通道靠它区分。
typedef ResultRedirectWriter = Future<void> Function(
  String agentId,
  String relativePath,
  String content,
);

/// 工具结果大小门控（Q1-②，照旧后端 `llm.py:_maybe_redirect_result` 的口径）。
///
/// 门控只作用于**送给模型的那一份**：超过 [thresholdTokens] 估算 token 时
/// 1. 完整结果写入工作空间 `.self/results/<yyyyMMdd_HHmmss>_<3位序号>.<工具名>.result`；
/// 2. 上下文里换成一条提示（工具名 / 字符数 / 阈值 / 相对路径 / 查看建议 / 前
///    [previewChars] 字符预览）；
/// 3. 没有写入器或写入失败 → 退化为**按阈值截断**：上下文必须有界，宁可让模型
///    看到半截结果，也不能把几百 KB 的工具输出塞进下一次请求。
///
/// 与旧实现的一处**有意差异**：落库与前端卡片仍然保留完整结果（见 LlmSession 里
/// 的 AgentToolEnd），只有送模型的那一份被替换。桌面端的历史同时就是界面历史，
/// 替换掉用户就再也看不到原文了；旧后端三处统一替换是因为它另有归档表。
///
/// 阈值按 token 而不是字符（M9 口径）：字符级阈值在中文/代码/日志之间的实际
/// 体量差好几倍，只有按 token 才能和上下文预算说同一句话。
class ToolResultGate {
  ToolResultGate({
    required this.agentId,
    this.thresholdTokens = defaultThresholdTokens,
    this.tokenScale = defaultTokenScale,
    this.previewChars = defaultPreviewChars,
    this.writer,
    this.log,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 默认门控阈值（token）：≈16k 字符 @ token_scale 2.00。
  static const int defaultThresholdTokens = 8000;

  /// 重定向提示里附带的结果预览长度（字符）。
  static const int defaultPreviewChars = 300;

  /// 重定向落点（工作空间相对路径，相对工作空间根）。
  static const String resultsDir = '.self/results';

  /// 该门控服务的 agent。
  final String agentId;

  /// 门控阈值（token）。
  final int thresholdTokens;

  /// 逐模型 token_scale：必须与上下文估算同口径（util/tokens.dart）。
  final double tokenScale;

  /// 提示里的预览长度。
  final int previewChars;

  /// 重定向写入器；null = 没有写入能力（直接走截断）。
  final ResultRedirectWriter? writer;

  /// 可读日志（写入失败、退化截断等）。
  final void Function(String message)? log;

  final DateTime Function() _clock;

  /// 本次运行内的重定向序号（门控实例与一次 run 同生命周期）。
  int _seq = 0;

  /// 已经重定向过的结果（工具名 + 原文 → 相对路径）。
  ///
  /// 为什么要缓存：历史翻译会被反复触发（每轮重建上下文、压缩后重新装配上下文），
  /// 没有它，同一个超大结果会落下一堆内容相同的文件。只留最近 [cacheLimit] 条，
  /// 避免把大字符串长期挂在这个实例上。
  final Map<String, String> _cache = <String, String>{};

  /// 重定向缓存容量。
  static const int cacheLimit = 16;

  /// 该结果是否超过门控阈值。
  bool exceeds(String text) =>
      estimateTokens(text, scale: tokenScale) > thresholdTokens;

  /// 门控后**送模型的那一份**的字符数（同步、不落盘）。
  ///
  /// 上下文估算必须用它而不是 [text].length：历史里的超大结果**store 存全文、
  /// 送模型只有预览**，按全文估算会让压缩阈值提前触发（估算里凭空多出几十万字符）。
  /// 未超阈值时就是原文长度；超了则落点提示 + 预览，长度基本恒定。
  int forModelChars(String text) {
    if (!exceeds(text)) return text.length;
    final int preview = text.length < previewChars ? text.length : previewChars;
    return noticeChars + preview;
  }

  /// 重定向提示本身的字符数（模板 + 时间戳路径 + 工具名，量级恒定）。
  ///
  /// 估算只需要量级正确：这里刻意不复刻路径与 token 数字的每一位，
  /// 真要逐字一致就该以端点 usage 为准。
  static const int noticeChars = 480;

  /// 把工具结果换算成"送模型的那一份"。
  ///
  /// **同一个结果重复过门控是允许的**（历史重载、每轮重建上下文都会再走一遍）：
  /// 没超阈值时原样返回，超阈值时重新落一份文件并返回提示。
  Future<String> apply(String toolName, String text) async {
    if (!exceeds(text)) return text;
    final ResultRedirectWriter? write = writer;
    if (write == null) {
      log?.call(
        '工具结果超长（$toolName，${text.length} 字符），但没有重定向写入能力，'
        '退化为截断',
      );
      return _truncated(text);
    }
    // 同一个结果（同一次 run 内）只落一次文件：重复过门控直接复用原路径
    final String cacheKey = '$toolName\u0000$text';
    final String? cached = _cache[cacheKey];
    if (cached != null) return _notice(toolName, text, cached);
    final String relativePath = _nextPath(toolName);
    try {
      await write(agentId, relativePath, text);
    } catch (error) {
      // 写不进去（路径非法 / 磁盘满 / SSH 断开）绝不能让本轮生成失败
      log?.call('工具结果重定向写入失败（$toolName → $relativePath）：$error；退化为截断');
      return _truncated(text);
    }
    _cache[cacheKey] = relativePath;
    if (_cache.length > cacheLimit) _cache.remove(_cache.keys.first);
    log?.call('工具结果已重定向：$toolName（${text.length} 字符）→ $relativePath');
    return _notice(toolName, text, relativePath);
  }

  /// 生成本次重定向的相对路径：`.self/results/<时间戳>_<序号>.<工具名>.result`。
  String _nextPath(String toolName) {
    _seq++;
    final String seq = _seq.toString().padLeft(3, '0');
    return '$resultsDir/${_stamp(_clock())}_$seq.${safeToolName(toolName)}.result';
  }

  /// 写给模型的提示（照旧后端文案，补上 token 口径）。
  String _notice(String toolName, String text, String relativePath) {
    final int tokens = estimateTokens(text, scale: tokenScale);
    final String preview = text.length <= previewChars
        ? text
        : text.substring(0, _safeCut(text, previewChars));
    final String tail = text.length <= previewChars ? '' : '…';
    return '[工具结果已重定向] $toolName 返回结果过长'
        '（${text.length} 字符 ≈ $tokens token > $thresholdTokens 阈值），'
        '完整结果已写入工作空间文件 $relativePath，未直接展示。\n'
        '如需查看：\n'
        '1) 用 read 工具对该文件分多次读取（file_path + start_line/line_count 控制范围）；\n'
        '2) 或用 terminal 工具（grep / sed / python 等）对该文件做进一步解析，'
        '只提取需要的有效信息。\n'
        '文件预览（前 $previewChars 字符）：\n'
        '$preview$tail';
  }

  /// 没有写入能力时的退化路径：按阈值截断（字符上限 = 阈值 × 比例）。
  String _truncated(String text) {
    final int limit = math.max(1, (thresholdTokens * tokenScale).round());
    if (text.length <= limit) return text;
    final int cut = _safeCut(text, limit);
    return '${text.substring(0, cut)}\n'
        '...[结果过长，共 ${text.length} 字符，已截断至 $cut 字符'
        '（$thresholdTokens token @ token_scale $tokenScale）]';
  }

  /// 不切断代理对（避免截出半个 emoji 变成乱码）。
  static int _safeCut(String text, int limit) {
    if (limit <= 0) return 0;
    if (limit >= text.length) return text.length;
    final int unit = text.codeUnitAt(limit - 1);
    final bool highSurrogate = unit >= 0xD800 && unit <= 0xDBFF;
    return highSurrogate ? limit - 1 : limit;
  }

  /// 文件名里的工具名：只留安全字符（工具名可能带命名空间前缀如 mcp__x__y）。
  static String safeToolName(String raw) {
    final String name = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return name.isEmpty ? 'tool' : name;
  }

  /// 本地时间戳（yyyyMMdd_HHmmss，与旧后端 time.strftime 同形）。
  static String _stamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}_'
        '${two(time.hour)}${two(time.minute)}${two(time.second)}';
  }
}
