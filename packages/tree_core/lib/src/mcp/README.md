# mcp（MCP 客户端与服务管理）

把用户配置的 MCP 服务变成模型工具（`mcp__<服务>__<工具>`），并管理它们的连接与活性。

## 文件

| 文件 | 作用 |
| --- | --- |
| [mcp_service.dart](mcp_service.dart) | 配置落盘 + 连接缓存 + 工具聚合 + 调用兜底 |
| [mcp_client.dart](mcp_client.dart) | stdio 传输客户端（起子进程、行分隔 JSON-RPC）与共享类型（`McpServerConfig` / `McpToolInfo` / `McpCallResult` / `McpException`） |
| [mcp_http_client.dart](mcp_http_client.dart) | Streamable HTTP 单端点客户端 |

## 不变量（assertions）

1. 配置是用户可直接手改的 `<数据根>/config/mcp.yaml`；`transport` 缺省 **stdio**——老配置（没有该字段）行为**逐字不变**。
2. 工具以 `mcp__<服务>__<工具>` **原生注入**模型工具表。服务当前不可用时，`help` 必须**如实说明**是哪个服务、为什么还没连上（懒连接在后台跑，不等待）——只让模型看到"工具少了一个"，它分不出是配置问题还是服务没起来。
3. 连接**懒建 + 缓存**：启动 `refresh` 全量连一次（不连会让首轮工具表缺项）；注册时**只连它自己**（旧实现每次注册都 `refresh(force: true)` 全量重连，正是"点了很久没反应"的根因）；其余时刻用到才连，失败按 `connectRetryDelay` 退避，不反复拉起死服务。
4. **一个坏服务只体现在它自己的错误里**：不影响其它服务，也不影响核心本身。
5. **没有任何连接 / 调用超时**（M9 规约 1.1）：判据是心跳——每 I 发一次 `ping`，一拍内没有任何协议消息记一次丢失，连续 N 拍判失活，在途请求以 `McpLivenessException` 显式失败，恢复自动清除。`heartbeatInterval` / `missedHeartbeatLimit` 是**心跳参数**，与"这次调用一共跑了多久"无关。
6. HTTP 客户端：**单端点** POST；`Accept` 同时要 `application/json` 与 `text/event-stream`；响应可能是 JSON 也可能是 SSE 流（其间有通知 / 多条报文，取 `id` 匹配那条）；`initialize` 响应头的 `Mcp-Session-Id` 原样带到后续请求，关闭时尽力 `DELETE`；后续请求带协商到的 `MCP-Protocol-Version`。
7. **诚实边界**：不做 GET 型 server→client 长流（收到就记日志并忽略，与 stdio 同口径）、不做 OAuth / 客户端证书（鉴权只靠自定义请求头）、不做旧版双端点 `HTTP+SSE`。`scope`（server / local / ssh）目前是展示与持久化字段，**不改变请求的发起位置**（都由核心进程发出）。
8. 错误文案是可读中文，能直接给模型 / 用户看。

## 测试

```bash
cd packages/tree_core
dart test test/mcp_service_test.dart test/mcp_client_test.dart \
          test/mcp_client_liveness_test.dart test/mcp_http_client_test.dart test/mcp_api_test.dart
```
