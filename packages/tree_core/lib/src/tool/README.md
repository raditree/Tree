# tool（工具层）

模型能做的事都在这里：工具契约、工作空间执行器、内置工具集，以及 MCP / 插件工具的动态注入与兜底入口。

## 文件

| 文件 | 作用 |
| --- | --- |
| [tool_runner.dart](tool_runner.dart) | 工具契约（`ToolSpec` / `ToolInvocation` / `ToolOutcome`）与 `EmptyToolRunner` |
| [workspace_tool_runner.dart](workspace_tool_runner.dart) | 工作空间执行器：IO 解析与缓存、内置 + MCP + 插件工具分派、结果（默认不）截断 |
| [builtin_tools.dart](builtin_tools.dart) | 内置工具集：read / write / edit / grep / terminal / set_todo_list / ask_user_question（+ `with*` 开关下的团队与 Spec 工具） |
| [message_tool.dart](message_tool.dart) | 团队通信域：`send_message` / `broadcast` / `wait_for` |
| [team_tool.dart](team_tool.dart) | 团队管理域：建队、成员名单与档案、审核状态 |
| [spec_tool.dart](spec_tool.dart) | 任务型规范：`select` / `create` / `update` |
| [mcp_tool.dart](mcp_tool.dart) | MCP 工具的发现入口（help / call）与"已配置但当前不可用"的如实说明 |
| [plugin_tool.dart](plugin_tool.dart) | 插件工具发现入口与按定义来源路由的兜底调用 |
| [question_channel.dart](question_channel.dart) | 提问通道契约（工具层 ↔ 编排层，避免反向依赖） |
| [status_text.dart](status_text.dart) | 每次工具结果前拼的"会话状态"（todo + 已选 Spec） |
| [todo_store.dart](todo_store.dart) | 待办存储（markdown 勾选清单 + 内存实现） |
| [terminal_hooks.dart](terminal_hooks.dart) | 后台长任务管理器（terminal 的 hook 模式） |

## 不变量（assertions）

1. 工具层**不认识 LLM 类型**：只声明名字 / 说明 / JSON Schema，转成 `LlmToolSpec` 是引擎的事——工具实现因此可脱离 LLM 单测。
2. 工具参数一律**工作空间相对路径**；绝对路径 / 盘符 / `..` 由 `WorkspaceIO.resolve` 拒绝。
3. 每个 agent 一个 IO，按需创建并缓存；`.self` 的翻译**只发生在 `PrivateWorkspaceIO(agentId)` 一处**——规范文本、系统提示词、结果门控、插件文档播种都经 `WorkspaceToolRunner.ioFor` 生效，所以它们的路径常量**一个都不用改**。**终端命令不经过翻译**（`exec` 直接在根下跑 shell）。
4. **默认不截断工具结果**：有界性由 LLM 侧的 `ToolResultGate` 负责（超长结果写进 `.self/results/`，送模型只留提示 + 预览）。工具层若抢先按字符砍到 24000，门控的 8000 token 阈值就只覆盖 16000~24000 这一段，再长根本走不到重定向。`maxResultChars` 只给确实要硬上限的调用方。
5. MCP 与插件工具**不在内置集里**：按"已就绪的服务"动态注入，工具名带 `mcp__<服务>__` / `plugin__<id>__` 前缀；服务列表是运行期才知道的。工具表**每轮现取**（不进系统提示词前缀）。
6. `message` 的 `session_id` 默认取**发起会话**（`invocation.sessionId`）⇒ 派活与回信都落在发出消息的那个会话里，不会跑去默认会话。
7. 每个工具结果前拼"会话状态"（todo + 已选 Spec），且**实时取**：模型可能在工具循环中途改 todo 或挂 Spec，状态必须是当下的。
8. 后台任务（hook 模式）：shell 把输出**直接重定向进日志文件**，核心只留一个进程句柄——核心进程重启也不丢日志，还少一层管道缓冲；任务结束（含取消）后写结束标记并回调唤醒 agent；关停时杀掉全部在途任务（进程不随应用退出存活）。
9. 待办落盘是 markdown 勾选清单，**正文放在最后**（正文里出现任何符号都不破坏解析）；`status=` 是**权威值**，勾选框只同步人类可读性；缺元数据的行也能读出来（id 自动生成、状态按勾选框推断）。
10. 提问通道是**具名契约**：工具层不反向依赖编排层（依赖方向 `tool` ← `agent`）。

## 测试

```bash
cd packages/tree_core
dart test test/builtin_tools_test.dart test/terminal_hooks_test.dart test/terminal_hook_wake_test.dart \
          test/terminal_soft_timeout_test.dart test/todo_store_test.dart test/tool_relay_test.dart \
          test/tool_list_refresh_test.dart test/session_status_test.dart test/team_tool_test.dart \
          test/plugin_tool_define_test.dart test/plugin_tool_table_test.dart test/plugin_broadcast_tool_test.dart
```
