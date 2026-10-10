import 'dart:convert';
import 'dart:typed_data';

import 'constants.dart';

/// 单帧超过 [kMaxFrameBytes] 时抛出（**发送侧**的保护：宁可显式失败，也不发一条对端必拒的帧）。
class FrameTooLargeException implements Exception {
  FrameTooLargeException(this.byteLength);

  final int byteLength;

  @override
  String toString() =>
      '帧过大：$byteLength 字节 > $kMaxFrameBytes（请分块：fs.read/fs.write 用 offset/length）';
}

/// 把一个 JSON 对象编码成**一行帧**（`\n` 结尾的 UTF-8）。
///
/// 行分隔是刻意的：两侧都是 stdio/exec 通道，没有消息边界，只有字节流；
/// 而 JSON 里不会出现裸 `\n`（二进制一律 base64）⇒ 按 `\n` 切分永远正确。
Uint8List encodeFrame(Map<String, dynamic> message) {
  final List<int> bytes = utf8.encode('${jsonEncode(message)}\n');
  if (bytes.length > kMaxFrameBytes) {
    throw FrameTooLargeException(bytes.length);
  }
  return Uint8List.fromList(bytes);
}

/// 增量式**行分隔 JSON-RPC 帧解码器**（两侧共用：插件读 agent、核心读插件）。
///
/// 语义（每一处都对应一个真实故障面）：
/// - 一行一帧；`\n` 结尾；允许并忽略行尾 `\r`（PTY / 某些通道会补）；
/// - 空行**直接跳过**（不是错误）；
/// - 单行超过 [maxFrameBytes] ⇒ 调 [onError] 并**丢弃到下一个 `\n`**，不静默截断成半个 JSON；
/// - 解析失败（非法 UTF-8 / 非法 JSON / 不是对象）⇒ 调 [onError]，**读循环继续**
///   （绝不能因为一条坏帧把整条通道搞哑）。
///
/// 刻意**不做**任何 RPC 语义：只把字节流切成 JSON 对象。语义在 [rpc.dart] 与各端自己那里。
class LineFrameDecoder {
  LineFrameDecoder({
    this.maxFrameBytes = kMaxFrameBytes,
    this.onFrame,
    this.onError,
  });

  final int maxFrameBytes;
  final void Function(Map<String, dynamic> message)? onFrame;
  final void Function(String reason)? onError;

  final List<int> _buf = <int>[];

  /// 正在丢弃一条**超长行**的剩余部分（直到下一个 `\n`）。
  bool _droppingOversized = false;

  /// 喂入一段字节；回调可能在本次调用内触发多次。
  void add(List<int> chunk) {
    if (chunk.isEmpty) return;
    _buf.addAll(chunk);
    int consumed = 0;
    while (true) {
      final int nl = _indexOfNewline(consumed);
      if (nl < 0) break;
      final int length = nl - consumed;
      if (_droppingOversized) {
        _droppingOversized = false;
      } else if (length > maxFrameBytes) {
        onError?.call('frame_too_large: $length 字节超过上限 $maxFrameBytes');
      } else if (length > 0) {
        _emit(Uint8List.fromList(_buf.sublist(consumed, nl)));
      }
      // length == 0（空行）落到这里，直接跳过
      consumed = nl + 1;
    }
    if (consumed > 0) _buf.removeRange(0, consumed);
    // 还没遇到 `\n` 就已经超过上限 ⇒ 这一行注定超限，丢掉已缓冲的部分并进入"丢到换行"模式
    if (_buf.length > maxFrameBytes) {
      onError?.call(
        'frame_too_large: 单行已缓冲 ${_buf.length} 字节（上限 $maxFrameBytes），开始丢弃',
      );
      _buf.clear();
      _droppingOversized = true;
    }
  }

  /// 丢弃缓冲（通道重建时调；半个帧不该跨到新连接上）。
  void reset() {
    _buf.clear();
    _droppingOversized = false;
  }

  int _indexOfNewline(int from) {
    for (int i = from; i < _buf.length; i++) {
      if (_buf[i] == 0x0A) return i;
    }
    return -1;
  }

  void _emit(Uint8List raw) {
    int end = raw.length;
    if (end > 0 && raw[end - 1] == 0x0D) end -= 1; // 容忍行尾 \r
    String text;
    try {
      text = utf8.decode(raw.sublist(0, end));
    } catch (_) {
      onError?.call('非法 UTF-8 帧（${raw.length} 字节），已丢弃');
      return;
    }
    if (text.trim().isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      onError?.call('非法 JSON 帧（${text.length} 字符），已丢弃');
      return;
    }
    if (decoded is! Map) {
      onError?.call('帧不是 JSON 对象（${decoded.runtimeType}），已丢弃');
      return;
    }
    onFrame?.call(decoded.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)));
  }
}
