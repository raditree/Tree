import 'dart:convert';
import 'dart:math';

/// 本地回环 token 的生成与校验。
///
/// 核心进程只监听 127.0.0.1，但同机其他进程仍可发起连接，因此每次启动都
/// 生成一次性随机 token，并要求全部 HTTP 请求与 WS 握手携带它。token 仅
/// 通过 stdout 握手行交给父进程，不落盘、不重复使用。
abstract final class CoreToken {
  /// token 熵（字节）；base64url 后为 43 个字符。
  static const int entropyBytes = 32;

  /// 生成一次性本地 token（base64url，无填充）。
  static String generate() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(
      entropyBytes,
      (_) => random.nextInt(256),
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// 恒定时间比较 [expected] 与 [provided]。
  ///
  /// 逐字符提前返回会把"前几位是否猜对"编码进响应时间，故先比长度、再对
  /// 全串做异或累积。长度不同直接返回 false（长度本身不是秘密）。
  static bool matches(String expected, String? provided) {
    if (provided == null) return false;
    final List<int> a = utf8.encode(expected);
    final List<int> b = utf8.encode(provided);
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// 从 `Authorization: Bearer <token>` 头解析并校验。
  static bool matchesAuthorization(String expected, String? header) {
    if (header == null) return false;
    const String prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return false;
    return matches(expected, header.substring(prefix.length).trim());
  }
}
