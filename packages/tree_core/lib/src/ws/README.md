# ws（回环 WebSocket）

核心与前端之间唯一的实时通道：**连接注册表 + 广播 + 帧分片重组**。业务帧的语义不在这里（在 [../agent/conversation_service.dart](../agent/conversation_service.dart)）。

## 文件

| 文件 | 作用 |
| --- | --- |
| [ws_hub.dart](ws_hub.dart) | `WsConnection`（对外只暴露 `send` 与统计字段）与 `WsHub`（多连接注册表 + 广播） |
| [inbound_frames.dart](inbound_frames.dart) | 接收侧分片重组（`frame_begin` / `frame_chunk` / `frame_end`） |

## 不变量（assertions）

1. 调用方**只按完整业务帧思考**：分片细节全部封在 `WsConnection` 内部。
2. 分片阈值与单片预算取自协议包（`kWsFrameChunkThresholdBytes` = 12 MiB、`kWsFrameChunkPartBytes`），**与前端同一口径**；核心必须像前端一样先重组再走业务分发，否则大帧（大工具结果、大附件）会被静默丢弃。
3. 在途分片序列有 **TTL**：超时未收齐即丢弃，防内存泄漏与永久悬挂。
4. 桌面是单用户单进程，但前端可能开多个窗口（成员独立窗口）⇒ 仍是**广播 + 多连接**语义；没有账号体系，因此帧里不带 user 维度。
5. **发送活性不在这里**，在 [../server/ws_liveness.dart](../server/ws_liveness.dart)：判失活后帧转入待补发队列、重连后补发，不静默丢帧。

## 测试

```bash
cd packages/tree_core
dart test test/util_test.dart test/ws_send_liveness_test.dart test/conversation_stream_seq_test.dart
```

共享夹具 [test/ws_harness.dart](../../../test/ws_harness.dart)；端到端用例见 `test/attachments_ws_e2e_test.dart` 与 `test/server_test.dart`。
