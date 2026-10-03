/// 一条「正在执行的工具」读数：核心的**运行中工具登记表**快照里的一项。
///
/// 数据源是 `GET /api/tools/running`（只读 REST，见 `ApiService.getRunningTools`）：
///
/// ```json
/// {"runs": [{"handle": "toolrun_...", "agent_id": "...", "session_id": "...",
///            "tool": "terminal", "command_preview": "find /mnt/space ...",
///            "started_at": "2026-10-03T20:00:00.000Z", "elapsed_ms": 1830,
///            "over_threshold": false}]}
/// ```
///
/// **为什么要在前端再建一个模型**：面板要渲染的是"一眼看清 + 一键关掉"，而 JSON 里的
/// 字段形如 `handle` / `over_threshold`——散在 widget 里读会变成一串下标访问，
/// 也就没法单测"脏数据会不会把面板搞崩"。这里做**只解析、不判策略**的归一：
/// 阈值口径只有一个（核心的 `over_threshold`），前端**不自己**拿 `elapsed_ms` 去比 120 s，
/// 免得两处算法漂移出"面板说超时、核心说没超"。
///
/// 与 `UsageCallView` 同一个做法：解析全程不抛异常（类型不对退默认值），
/// 只有真正"没有这个信息"的 `started_at` 才留 null。
class ToolRun {
  const ToolRun({
    required this.handle,
    this.agentId = '',
    this.sessionId = '',
    this.tool = '',
    this.commandPreview = '',
    this.startedAt,
    this.elapsedMs = 0,
    this.overThreshold = false,
  });

  /// 关闭用的**句柄**（`toolrun_<ms>_<rand>_<n>`）；核心重启后旧句柄失效 ⇒ 关闭会
  /// 以可读原因拒绝（见 `tool.close`）。
  final String handle;

  /// 发起这次工具调用的 agent / 会话（面板只用来标注"这是谁的"）。
  final String agentId;
  final String sessionId;

  /// 工具名（`terminal` / `read` / `find` …）。
  final String tool;

  /// 命令摘要（核心已经截过的预览；前端还会再压行截断一次，见面板里的
  /// `toolCommandPreview`——命令可能很长且带换行）。
  final String commandPreview;

  /// 开始时间；解析不出为 null（核心没给或形状不对）。
  final DateTime? startedAt;

  /// 已执行时长（毫秒）。
  final int elapsedMs;

  /// 是否已超核心的阈值（默认 120 s，可配）。**以核心为准**。
  final bool overThreshold;

  /// 从 runs 项解析（脏数据不抛异常）。
  factory ToolRun.fromJson(Map<String, dynamic> json) => ToolRun(
    handle: _asString(json['handle']) ?? '',
    agentId: _asString(json['agent_id']) ?? '',
    sessionId: _asString(json['session_id']) ?? '',
    tool: _asString(json['tool']) ?? '',
    commandPreview: _asString(json['command_preview']) ?? '',
    startedAt: _asTime(json['started_at']),
    elapsedMs: _asInt(json['elapsed_ms']) ?? 0,
    overThreshold: _asBool(json['over_threshold']) ?? false,
  );
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
