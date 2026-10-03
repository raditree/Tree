import 'dart:convert';

import '../util/json_time.dart';
import 'atomic_file.dart';
import 'tree_paths.dart';
import 'write_queue.dart';

/// 一次 LLM 调用的**来源**（`usage.jsonl` 的 `source` 字段，也是插件面板的分类键）。
///
/// 四类互斥：对话本身的一跳 / 内置压缩的一次总结 / 执行站 `llm.call` /
/// 被插件整体接管的 `llm.handle` 一跳。前端与插件面板按它分组显示。
abstract final class UsageSource {
  /// 对话本身的一跳（引擎的工具循环：**每次** API 调用一条，含带工具调用的跳）。
  static const String turn = 'turn';

  /// 内置压缩（`LlmSummarizer` 的一次总结补全）。
  static const String compact = 'compact';

  /// 执行站 `llm.call`（插件发起的一次性调用，压缩插件走的就是它）。
  static const String llmCall = 'llm.call';

  /// `llm.handle` 被插件**整体接管**的一跳（用量由插件回填，无则本地估算）。
  static const String plugin = 'plugin';

  /// 全部合法取值（协议/契约自检用）。
  static const List<String> all = <String>[turn, compact, llmCall, plugin];
}

/// 用量回调（**可注入**）：把一次调用的账目交给落盘方。
///
/// [agentId] 由调用点补（`LlmSummarizer` / `LlmJsonCaller` 都按 agent 解析模型），
/// 会话由接线方在闭包里绑定（见 [UsageLog.sinkFor]）。
typedef UsageSink = void Function(String agentId, UsageCall call);

/// **一次 LLM 调用的用量账目** = `<会话目录>/usage.jsonl` 的一行。
///
/// 为什么要"逐调用"而不是"每轮回复一条"：一轮回复里的工具循环可以打十几次端点，
/// 而账单是**按次**计的。只记最后一条时（旧行为）用户看到的用量与账单对不上，
/// 也看不出钱花在"对话 / 压缩 / 插件"哪一类上。
///
/// 口径（与既有 `agentUsageMap` 的关系）：
/// - [promptTokens] 是**这一跳发出去的输入长度**（端点真值优先，缺失则本地估算）；
/// - [completionTokens] 是**这一跳**生成的 token（不累计——累计口径属于前端进度条，
///   由实时帧承载，这里要的是"每次调用花了多少"）；
/// - [estimated] = true 表示这行里有本地估算值（端点没给 usage），**不要当计费依据**；
/// - [cachedTokens] 为 null 表示**端点没有这个字段**（不编造 0）；有值才是"命中多少"。
class UsageCall {
  const UsageCall({
    required this.at,
    required this.source,
    required this.model,
    this.promptTokens = 0,
    this.cachedTokens,
    this.completionTokens = 0,
    this.estimated = false,
    this.durationMs = 0,
  });

  /// 这次调用**结束**的时刻（与 `session.json` / `messages.jsonl` 同口径：
  /// 本机时区的 ISO-8601 字符串，见 [JsonTime.encode]）。
  final DateTime at;

  /// 来源，取值见 [UsageSource]。
  final String source;

  /// 实际请求的模型 id（成员级覆盖之后的那一个）。
  final String model;

  /// 这一跳的输入 token（端点真值优先，缺失则本地估算并标 [estimated]）。
  final int promptTokens;

  /// 命中前缀缓存的输入 token；**null = 端点没给这个字段**。
  final int? cachedTokens;

  /// 这一跳生成的 token。
  final int completionTokens;

  /// 数值里是否含本地估算值。
  final bool estimated;

  /// 这一跳从发出请求到收流的耗时（毫秒）。
  final int durationMs;

  /// `usage.jsonl` 的一行（**字段表就是对外契约**，插件面板按它消费）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'at': JsonTime.encode(at.millisecondsSinceEpoch),
    'source': source,
    'model': model,
    'prompt_tokens': promptTokens,
    'cached_tokens': cachedTokens,
    'completion_tokens': completionTokens,
    'estimated': estimated,
    'duration_ms': durationMs,
  };

  /// 从 `usage.jsonl` 的一行还原；**看不懂就返回 null**（由调用方跳过并计数）。
  ///
  /// 容错口径：只有 `source` 与 `at` 是必须的（缺了这行就没法归类和排序），
  /// 其余字段缺失按默认值处理——手改文件、跨版本读写都不该把整份账本读崩。
  static UsageCall? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final String source = '${raw['source'] ?? ''}'.trim();
    if (source.isEmpty) return null;
    final int? at = JsonTime.decode(raw['at']);
    if (at == null) return null;
    return UsageCall(
      at: DateTime.fromMillisecondsSinceEpoch(at),
      source: source,
      model: '${raw['model'] ?? ''}',
      promptTokens: _asInt(raw['prompt_tokens']) ?? 0,
      cachedTokens: _asInt(raw['cached_tokens']),
      completionTokens: _asInt(raw['completion_tokens']) ?? 0,
      estimated: raw['estimated'] == true,
      durationMs: _asInt(raw['duration_ms']) ?? 0,
    );
  }

  /// 从引擎夹带的"本次调用读数"构造（内部键见 `LlmSession.callUsageKey`）。
  ///
  /// 为什么需要这条专门入口：公开 usage map 是**已入帧、已落库**的既有契约
  /// （累计口径），不能塞进逐调用字段；引擎把逐调用读数放在内部键里，
  /// 读完即剥掉，只用来落这一份账。
  static UsageCall? tryFromCallUsage(
    Object? raw, {
    required String source,
    required String model,
    DateTime? at,
  }) {
    if (raw is! Map) return null;
    return UsageCall(
      at: at ?? DateTime.now(),
      source: source,
      model: model,
      promptTokens: _asInt(raw['prompt_tokens']) ?? 0,
      cachedTokens: _asInt(raw['cached_tokens']),
      completionTokens: _asInt(raw['completion_tokens']) ?? 0,
      estimated: raw['estimated'] == true,
      durationMs: _asInt(raw['duration_ms']) ?? 0,
    );
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}

/// 某会话的用量账本读取结果。
class UsageHistory {
  const UsageHistory(this.calls, this.skipped);

  /// 解析成功的调用（保持文件顺序：早 → 晚）。
  final List<UsageCall> calls;

  /// 无法解析而被跳过的行数（坏行 / 手改坏 / 旧版本未知来源）。
  ///
  /// 与 `messages.jsonl` 同一容错口径：**绝不因为一行坏数据让整份账本读不出来**。
  final int skipped;

  bool get isEmpty => calls.isEmpty;
  int get length => calls.length;
}

/// **逐调用用量账本**的落盘器：一行一次调用，追加到
/// `<数据根>/data/<agent>/<session>/usage.jsonl`。
///
/// 为什么不进 `messages.jsonl`：用量是**遥测**不是对话。混进消息日志会改变既有
/// 行形状（老前端/老数据/`CoreMessage` 契约的兼容面），还会让"删掉用量"变成
/// "改对话历史"。单独一个 jsonl 的另一半好处：删会话（递归删目录）天然把它带走。
///
/// 写语义完全复用存储层既有原语：`WriteQueue`（每路径串行 + write-behind，
/// 入队即返回，写失败只落 [lastError] 不拖垮生成）+ `AtomicFile.appendLine`
/// （单次追加一行，硬杀最多丢最后一行）。**关停时必须 [flush]**。
class UsageLog {
  UsageLog(this.paths, {WriteQueue? queue, this.log})
    : _queue = queue ?? WriteQueue();

  /// 路径布局（数据根）。
  final TreePaths paths;

  /// 可读日志（路径非法等被跳过的情形）；核心进程接到 stderr。
  final void Function(String message)? log;

  final WriteQueue _queue;

  /// 读取时默认的**尾部字节数**上限（账本会随会话增长，面板只要最近的那些）。
  static const int defaultTailBytes = 256 * 1024;

  /// 记一笔（**非阻塞**：路径算完就入队返回）。
  void record(String agentId, String sessionId, UsageCall call) {
    final String path;
    try {
      path = paths.usageFile(agentId, sessionId);
    } catch (error) {
      // 路径非法（id 过不了 safeSegment）：如实记一句，绝不打断生成。
      log?.call('用量落盘跳过（路径非法，$agentId/$sessionId）：$error');
      return;
    }
    final String line = jsonEncode(call.toJson());
    _queue.enqueue(path, () => AtomicFile.appendLine(path, line));
  }

  /// 绑定**会话**、把 `agentId` 留给调用点补的可注入回调。
  ///
  /// 形状与 `LlmSummarizer` / `LlmJsonCaller` 的 `usageSink` 参数一致：
  /// 这两处的会话由接线方知道、agent 由调用点给出（它们都按 agent 解析模型）。
  UsageSink sinkFor(String sessionId) =>
      (String agentId, UsageCall call) => record(agentId, sessionId, call);

  /// 等待全部在途写入（关停与测试必须调用）。
  Future<void> flush() => _queue.flush();

  /// 最近一次落盘错误（不抛出；由调用方决定要不要报）。
  Object? get lastError => _queue.lastError;

  /// 读某会话的用量账本（**只读尾部** [tailBytes] 字节，容错跳过坏行）。
  ///
  /// 容错口径：文件不存在 / 目录不存在 ⇒ 空账本（不是错误——老会话本来就没有它）；
  /// 坏行 ⇒ 计入 [UsageHistory.skipped]；路径非法 ⇒ 空账本。
  static Future<UsageHistory> read(
    TreePaths paths,
    String agentId,
    String sessionId, {
    int tailBytes = defaultTailBytes,
  }) async {
    final String path;
    try {
      path = paths.usageFile(agentId, sessionId);
    } catch (error) {
      return const UsageHistory(<UsageCall>[], 0);
    }
    final String? text = await AtomicFile.readTailOrNull(
      path,
      tailBytes > 0 ? tailBytes : defaultTailBytes,
    );
    if (text == null) return const UsageHistory(<UsageCall>[], 0);
    final JsonlReadResult json = AtomicFile.decodeJsonl(text);
    final List<UsageCall> calls = <UsageCall>[];
    int skipped = json.skipped;
    for (final Map<String, dynamic> record in json.records) {
      final UsageCall? call = UsageCall.tryFromJson(record);
      if (call == null) {
        skipped++;
        continue;
      }
      calls.add(call);
    }
    return UsageHistory(calls, skipped);
  }
}
