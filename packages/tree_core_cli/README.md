# tree_core_cli

核心进程的**入口与组合根**：解析命令行、读数据根、组装存储 / LLM / 工具 / 团队 / Spec / MCP / 插件、
启动 `CoreServer`、写握手行、处理 `shutdown`。这里**只做装配**，业务逻辑一律在 `tree_core`。

## 关键内容

| 位置 | 内容 |
| --- | --- |
| [bin/tree_core.dart](bin/tree_core.dart) | 组合根：`--port/--data-dir/--verbose/--chunk-delay-ms`；provider 接线（系统提示词文件、Spec 索引/已选、团队工作目录）；`ioFor` 后置绑定给消息派发；旧 `.self` 一次性迁移；stdout 只写握手行 |
| [test/binary_smoke_test.dart](test/binary_smoke_test.dart) | 门控真进程冒烟：编译产物能起、能握手、鉴权生效、能优雅退出 |

## 不变量（assertions）

1. **stdout 只允许握手行**（单行 JSON）；日志一律 stderr，并由 `CoreLogSink` **同时**落一份到
   `<数据根>/logs/core.log`（带 `pid=` 前缀、按大小轮转、写失败只提示一次后降级为纯 stderr）；关停前必须 `flush()`。
2. 端口默认随机、只监听 `127.0.0.1`；token 每次启动重新生成。
3. `shutdown`（stdin 一行）必须优雅退出并 `store.flush()`。
4. provider 接线必须成对：`CoreServer.close()` 时按身份解绑，避免旧实例把过期数据留在全局 provider 上。
5. 启动期的一次性迁移（`.self` → `.tree/<agent_id>/.self`）**幂等**，失败只记日志、不阻断启动。
6. **临时员工（subagent）的装配只在这里**：`FileTreeStore` 外面包一层 `SubagentStore`（内存覆盖层 + 会话级名册），
   再交给工具层 / 文件服务 / 会话服务——"临时员工是谁"因此只有一处答案，既有 `store.agent(id)` 调用点一个都不用改。
   三个后置绑定的槽（与 `ioSink` / `deliverSink` 同一范式）：`probeWorkspace`（工具层建好后）、
   `runner = server.conversation.runSubagent`（起监听后）、`onFinished`（后台完成 → **既有** `tools.onHookFinished → conversation.wake` 那条路，带 subagent 标记）。
7. 未知的 `sub_*`（名册未装载 / 已被清理）在 `resolveWorkspaceDir` / `resolveSshConfig` 里**不猜**：
   后者返回 null、前者返回空串，让上层显式失败——绝不落回 `workspaces/<id>` 那个并不存在的工作空间。

## 测试

```bash
dart analyze bin
# 需要先有编译产物
$env:TREE_CORE_EXE='<仓库>/dist/tree_core.exe'; dart test
```
