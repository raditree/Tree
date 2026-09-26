import 'package:tree_protocol/tree_protocol.dart';

/// 接收侧分片重组（对应前端 `WebSocketService._maybeReassemble`）。
///
/// 为什么核心进程也需要它：前端 `sendMessage` 在帧编码后超过
/// [kWsFrameChunkThresholdBytes] 时会分片上行（大工具结果、大附件等），
/// 核心必须像前端一样先重组再走业务分发，否则大帧会被静默丢弃。
class InboundFrameReassembler {
  InboundFrameReassembler({this.ttl = kWsFrameChunkTtl});

  /// 在途序列的存活时限：超时未收齐即丢弃（防内存泄漏与永久悬挂）。
  final Duration ttl;

  final Map<String, _PendingFrames> _pending = <String, _PendingFrames>{};

  /// 是否为传输层分片帧。
  static bool isChunkFrame(Map<String, dynamic> frame) {
    final String? type = frame['type'] as String?;
    return type == WsOutboundType.frameBegin ||
        type == WsOutboundType.frameChunk ||
        type == WsOutboundType.frameEnd;
  }

  /// 当前在途序列数（自检用）。
  int get pendingCount => _pending.length;

  /// 喂入一个分片帧；重组完成返回原始 JSON 文本，未完成返回 null。
  String? accept(Map<String, dynamic> frame) {
    final String type = frame['type'] as String? ?? '';
    final String id = frame['id'] as String? ?? '';
    if (id.isEmpty) return null;
    _evictExpired();
    if (type == WsOutboundType.frameBegin) {
      final int total = (frame['total'] as num?)?.toInt() ?? 0;
      if (total <= 0) return null;
      _pending[id] = _PendingFrames(total, DateTime.now());
      return null;
    }
    final _PendingFrames? buffer = _pending[id];
    // 无起始帧的残片（跨重连/超时后到达）：丢弃该片，不影响其他序列
    if (buffer == null) return null;
    if (type == WsOutboundType.frameChunk) {
      final int seq = (frame['seq'] as num?)?.toInt() ?? -1;
      final String? part = frame['part'] as String?;
      if (seq >= 0 && part != null) buffer.parts[seq] = part;
    }
    final bool complete =
        buffer.parts.length >= buffer.total || type == WsOutboundType.frameEnd;
    if (!complete) return null;
    _pending.remove(id);
    return List<String>.generate(
      buffer.total,
      (int i) => buffer.parts[i] ?? '',
    ).join();
  }

  void clear() => _pending.clear();

  void _evictExpired() {
    if (_pending.isEmpty) return;
    final DateTime now = DateTime.now();
    _pending.removeWhere(
      (_, _PendingFrames buffer) => now.difference(buffer.startedAt) > ttl,
    );
  }
}

/// 单个在途分片序列。
class _PendingFrames {
  _PendingFrames(this.total, this.startedAt);

  final int total;
  final DateTime startedAt;
  final Map<int, String> parts = <int, String>{};
}
