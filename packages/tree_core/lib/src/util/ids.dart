import 'dart:math';

/// 核心进程内的唯一 id 生成器。
///
/// 形态 `<prefix>_<epoch_ms>_<rand6>_<seq>`：
/// - **epoch 毫秒**保证跨进程重启仍单调递增（与现状 server 的
///   `phs_<epoch_ms>_<seq>` 命名约定一致）；
/// - **进程内自增序号**避免同一毫秒内连续生成时碰撞；
/// - **6 位随机十六进制**避免多进程同时启动时的极端碰撞。
///
/// 不使用 UUID 包：核心进程要保持零第三方依赖，便于 `dart compile exe`
/// 产出单文件可执行。
abstract final class CoreIds {
  static final Random _random = Random.secure();
  static int _seq = 0;

  /// 生成带前缀的唯一 id。
  static String next(String prefix) {
    _seq = (_seq + 1) & 0xFFFFFF;
    final int ms = DateTime.now().millisecondsSinceEpoch;
    final String rand = _random
        .nextInt(0x1000000)
        .toRadixString(16)
        .padLeft(6, '0');
    return '${prefix}_${ms}_${rand}_${_seq.toRadixString(16)}';
  }

  /// agent id。
  static String agent() => next('agt');

  /// 会话 id。
  static String session() => next('ses');

  /// 消息 id。
  static String message() => next('msg');

  /// WS 连接 id（仅用于日志排障）。
  static String connection() => next('conn');
}
