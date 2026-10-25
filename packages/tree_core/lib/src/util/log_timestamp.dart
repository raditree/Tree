/// 日志落盘行的**行首时间戳**：本地时间 ISO8601（毫秒 3 位）+ 显式时区偏移。
///
/// 例如 `2026-10-05T07:24:31.123+08:00`；本机为 UTC 时是 `+00:00`（不写 `Z`）。
///
/// 为什么自己拼而不直接用 `DateTime.toIso8601String()`：
/// 1. 本地时间的 `toIso8601String()` **不带偏移**——日志会被拷到别的机器/时区看，
///    没有偏移就无法换算回真实时刻；
/// 2. 带微秒时它输出 **6 位**小数，与"毫秒 3 位"的固定口径不符。
///
/// 唯一来源：核心日志（[CoreLogSink]）与插件日志（`PluginLogSink`）共用同一份，
/// 否则同一次排障里两种行格式各漂各的。
String logLineTimestamp(DateTime at) {
  final DateTime local = at.toLocal();
  final Duration offset = local.timeZoneOffset;
  final int offsetMinutes = offset.inMinutes.abs();
  final String sign = offset.isNegative ? '-' : '+';
  final String date =
      '${local.year.toString().padLeft(4, '0')}'
      '-${local.month.toString().padLeft(2, '0')}'
      '-${local.day.toString().padLeft(2, '0')}';
  final String time =
      '${local.hour.toString().padLeft(2, '0')}'
      ':${local.minute.toString().padLeft(2, '0')}'
      ':${local.second.toString().padLeft(2, '0')}'
      '.${local.millisecond.toString().padLeft(3, '0')}';
  final String zone =
      '$sign'
      '${(offsetMinutes ~/ 60).toString().padLeft(2, '0')}'
      ':${(offsetMinutes % 60).toString().padLeft(2, '0')}';
  return '${date}T$time$zone';
}
