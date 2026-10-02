# tree_core

核心进程：**全部业务逻辑**（服务、LLM、工具、存储、团队、Spec、MCP、插件）都在这里，纯 Dart、无 Flutter 依赖，
可 `dart compile exe` 成单文件。入口在 [../tree_core_cli/bin/tree_core.dart](../tree_core_cli/bin/tree_core.dart)（组合根）。

## 职责边界

- **负责**：REST/WS 协议实现与鉴权、会话与消息落库、LLM 调用与工具循环、工具实现（内置 + MCP + 插件）、
  工作空间 IO 的解析与缓存、团队/成员、Spec、插件宿主与站点体系、上下文压缩、前缀缓存策略。
- **不负责**：进程启动与握手（`tree_core_cli`）、UI 渲染（`lib/`）、协议常量定义（`tree_protocol`）、
  本机/SSH 文件读写的具体实现（`tree_local_exec`）。

## 模块地图

`lib/src/` 下每个业务模块都有自己的 README（文件清单 + 不变量 + 测试）；改哪个模块就读哪个：

| 模块 | 内容 |
| --- | --- |
| [agent](lib/src/agent/README.md) | 会话编排：引擎契约与事件、帧映射与落库、按 agent×会话并发、压缩、提问、私有目录分栏；**默认系统提示词种子（`defaultSystemPromptSeed`）与拼装顺序在这里** |
| [llm](lib/src/llm/README.md) | LLM 接入：OpenAI 兼容编解码、SSE、传输与心跳判活、工具循环、结果门控、图像附件 |
| [tool](lib/src/tool/README.md) | 工具层：工具契约、工作空间执行器、内置工具集（**工具描述 / 参数 schema 就是模型读到的提示词**）、MCP / 插件工具注入与兜底 |
| [team](lib/src/team/README.md) | 团队领域：成员即 agent、共享工作目录与 SSH 跟随、消息派发与活动日志 |
| [store](lib/src/store/README.md) | 数据根布局、记录模型、落盘 / 内存实现、写队列与原子快照 |
| [files](lib/src/files/README.md) | 工作空间文件服务（唯一的路径安全边界）：读 / 写 / 上传 / 打包 / Git |
| [spec](lib/src/spec/README.md) | 任务型规范：**内置 Spec 模板（`kBuiltinSpecs`，改文案要 bump version）**、播种与刷新、索引注入提示词、select / create / update |
| [mcp](lib/src/mcp/README.md) | MCP 客户端（stdio + Streamable HTTP）与服务管理 |
| [plugin](lib/src/plugin/README.md) | 插件宿主、四类站点与点位、执行站挂载、插件工具与 UI 槽位 |
| [server](lib/src/server/README.md) | 回环 HTTP + WS 门面：路由、鉴权、响应编码、WS 发送活性 |
| [ws](lib/src/ws/README.md) | WS 注册表与广播、帧分片与接收侧重组 |
| [settings](lib/src/settings/README.md) | 设置、模型池与 SSH 配置（脱敏与手改友好） |
| [util](lib/src/util/README.md) | token 口径、id、时间编解码、心跳活性台账 |

顶层文件 [lib/src/version.dart](lib/src/version.dart) 只有版本号常量。

## 入口（先读这几处）

| 文件 | 作用 |
| --- | --- |
| [lib/src/server/core_server.dart](lib/src/server/core_server.dart) | HTTP 路由注册 + WS 帧分发 + 鉴权；provider 接线（Spec 快照 / 团队工作目录）与 `close()` 解绑 |
| [lib/src/agent/conversation_service.dart](lib/src/agent/conversation_service.dart) | `user_message`/`stop`/`deliver`/`wake` → 落库 + 流式下行；**按 agent×会话**的串行链与插话 |
| [lib/src/llm/llm_agent_engine.dart](lib/src/llm/llm_agent_engine.dart) · [lib_session](lib/src/llm/llm_session.dart) | OpenAI 兼容 SSE + 工具循环（无轮次上限）+ 压缩钩子 |
| [lib/src/tool/workspace_tool_runner.dart](lib/src/tool/workspace_tool_runner.dart) | 工具表组装与执行；工作空间 IO 缓存 + 私有目录分栏（`PrivateWorkspaceIO`） |
| [lib/src/store/tree_store.dart](lib/src/store/tree_store.dart) · [file_store.dart](lib/src/store/file_store.dart) · [records.dart](lib/src/store/records.dart) | 数据根读写与记录模型 |
| [lib/src/team/](lib/src/team/) | 团队服务、消息派发、工作目录口径（`team_workspace.dart`） |
| [lib/src/spec/](lib/src/spec/) · [lib/src/mcp/](lib/src/mcp/) · [lib/src/plugin/](lib/src/plugin/) | Spec 体系 / MCP 客户端 / 插件宿主与站点 |
| [lib/src/terminal/](lib/src/terminal/) | 集成终端（Ctrl+J）：伪终端会话管理 + 会话生命周期（平台实现由 tree_local_exec 注入） |

## 不变量（assertions）

1. **路径**：工具参数一律工作空间相对路径；越界（绝对路径 / 盘符 / `..`）由 `WorkspaceIO.resolve` 拒绝，
   REST 侧同一条边界在 `FileService`。
2. **私有状态只在 `.tree/<agent_id>/.self/`**；项目文件与 leader 共享；翻译只发生在 `PrivateWorkspaceIO` 一处。
3. **系统提示词按会话钉住**（`ConversationService._systemPrompts`）：只在会话初始化、压缩后、显式失效时重建；
   历史逐字复用（`tool_arguments_raw` / `tool_result_for_model`）；**工具表每轮现取**（不进前缀）。
4. **并发**：同一会话串行、不同会话并行；插话按会话取消、`stop` 按 agent 取消（epoch 作废排队任务）；
   `idle` 只在该 agent 没有在途轮次时广播。
5. **没有静态任务超时**：判活只认心跳 / 进程存活；本地 terminal 的"软超时"**不杀进程**，转 hook 后台任务。
6. **失败必须可读**：工具结果、`error` 帧或日志至少一处说明原因；`wait_for` 先部分结果后收口，不整体失败。
7. **落库优先**：先写 `messages.jsonl` 再触发生成；`close()` 前 `store.flush()`。
8. **密钥不进日志/帧**；`GET /api/models` 走字段白名单。
9. **协议常量只从 `tree_protocol` 取**；新增路由必须登记（未实现的显式 501）。

## 测试

```bash
cd packages/tree_core && dart test            # 全量（存储 / LLM / 工具 / 团队 / Spec / MCP / 插件 / REST+WS 端到端）
dart analyze lib test                         # 必须零告警
```

门控真机用例：`test/ssh_files_integration_test.dart`（设 `TREE_SSH_TEST_HOST/USER/KEY` 才跑）。
关键回归钉子：`llm_prefix_stability_test`（前缀逐字）、`system_prompt_pin_test`（提示词钉住）、
`tool_list_refresh_test`（工具表刷新）、`message_interrupt_test`（会话并行/插话/stop）、
`team_workspace_test` + `private_workspace_io_test`（团队目录与私有分栏）。
