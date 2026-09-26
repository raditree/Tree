/// WS 传输层分片参数（核心进程与前端共用）。
///
/// 现状 server 侧由 `ws_manager` 的 `_FRAME_*` 常量产出分帧，前端
/// `websocket_service.dart` 负责重组。桌面分支中核心进程成为产出方，
/// 两侧必须使用**同一组阈值**，故上移到协议包作为单一事实来源。
///
/// 分帧三件套的类型名见 [WsOutboundType.frameBegin] /
/// [WsOutboundType.frameChunk] / [WsOutboundType.frameEnd]。
library;

/// 大帧分片阈值（UTF-8 字节）：单帧编码后超过该值即分片传输。
///
/// 取 12 MiB：留出余量覆盖 JSON 转义膨胀，同时显著低于任何合理单帧上限。
const int kWsFrameChunkThresholdBytes = 12 * 1024 * 1024;

/// 单个分片的最大 UTF-8 字节数（按字符边界回退，不切断码点）。
const int kWsFrameChunkPartBytes = 4 * 1024 * 1024;

/// 接收侧在途分片序列的保活时限：超时未收齐即丢弃（防内存泄漏与永久悬挂）。
const Duration kWsFrameChunkTtl = Duration(seconds: 30);
