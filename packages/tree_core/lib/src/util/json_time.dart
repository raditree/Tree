/// 时间字段的 JSON 编解码。
///
/// 持久化文件（M2 的 agent yaml / session json / messages jsonl）统一用
/// **ISO-8601 字符串**，因为桌面分支的核心诉求之一是"用户可以直接打开文件
/// 查看和手改"；而前端模型（`ChatSession.fromJson`）要求毫秒整数，故
/// 两种形态都要支持。`decode` 同时接受 ISO 字符串与毫秒整数，使
/// 手改文件时两种写法都能生效。
abstract final class JsonTime {
  /// 毫秒时间戳 -> ISO-8601（本地时区带偏移，人读友好）。
  static String encode(int milliseconds) =>
      DateTime.fromMillisecondsSinceEpoch(milliseconds).toIso8601String();

  /// ISO-8601 字符串或毫秒整数 -> 毫秒时间戳；无法解析返回 null。
  static int? decode(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String && value.isNotEmpty) {
      // 手改文件时可能把毫秒数写成带引号的字符串，故先尝试纯数字
      final String text = value.trim();
      if (RegExp(r'^-?\d+$').hasMatch(text)) return int.tryParse(text);
      return DateTime.tryParse(text)?.millisecondsSinceEpoch;
    }
    return null;
  }
}
