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
| [subagent_tool.dart](subagent_tool.dart) | **临时员工**工具（`subagent`）：形状/schema 校验 + 落点契约（`SubagentChannel`）与消息标记（`SubagentTag`） |
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
11. **`subagent` 与其它工具同权、同三站**（用户硬断言，不给它开后门）：
    - **执行站**：`subagent` 一律经 `WorkspaceToolRunner._execute` → `BuiltinTools.run` 分派——和 `edit` / `write` / `team` 同一个入口。执行站命令 `tool.call`（`runFromPlugin`）因此能以 `tool: 'subagent'` 跑起来，权限口径与模型调用完全一致（**没有**特例白名单、**没有**特例拦截）；`origin` / `source_plugin_id` / `relay:false 默认绕开站点` 这些语义与普通工具逐字一致。
    - **中转站**：`system.relay.tool.pre` / `.post` 对 `subagent` 照常生效——pre 改写的 `task` / `name` **真正生效**（子 agent 拿到的就是改写后的那份），post 可改结果文本。
    - **广播站**：`system.broadcast.tool.pre` / `.post` 各发一条（单向、不等回包），载荷字段与普通工具完全相同（`point` / `phase` / `tool` / `call_id` / `round` / `origin` / `arguments`、post 还有 `result`）。
    - **子 agent 自己的工具调用同样三站齐全**：临时员工跑在**同一个** `WorkspaceToolRunner` 上（同一份 relay/broadcast、同一份 `origin='agent'` 语义），绝不因为"跑在后台"就绕开站点；轮次序号按**调用**分配（`_relaySeq` 不是共享实例字段），父调用与嵌套调用、同名工具的并行调用都不会串号。
    - 声明即能力：`specsFor` 在接了 `subagentService` 时**包含** `subagent`，未接线时**不包含**；`BuiltinTools.needsWorkspace('subagent')` 恒为 **false**（工具本身不读文件，子 agent 的工作空间由它自己在运行时解析，缺工作空间给**可读错误**）。
    - 唯一的口径差异（**权限，不是绕站**）：临时员工的工具表**没有** `team` / `message`（不能被派活、不能建队/管队），但**有** `subagent`（可以再召，把同一个大任务拆细；层级上限 `SubagentLimits.maxDepth`）。

## 测试

```bash
cd packages/tree_core
dart test test/builtin_tools_test.dart test/terminal_hooks_test.dart test/terminal_hook_wake_test.dart \
          test/terminal_soft_timeout_test.dart test/todo_store_test.dart test/tool_relay_test.dart \
          test/tool_list_refresh_test.dart test/session_status_test.dart test/team_tool_test.dart \
          test/plugin_tool_define_test.dart test/plugin_tool_table_test.dart test/plugin_broadcast_tool_test.dart \
          test/subagent_tool_test.dart
```

- `subagent_tool_test.dart`：工具形状与校验（缺/空 `task`）、阻塞模式把最终报告作为工具结果返回、
  复用（同 id 续活、历史延续、不新建实体）、层级上限的可读错误、**并行后台**（同一轮 3 个真的同时跑、
  三份结果各注入一次且不串）、父 agent 在途轮次不与之撞键、工具表裁剪（临时员工没有 team/message、有 subagent）。
- `tool_relay_test.dart` / `plugin_broadcast_tool_test.dart` 里的 `subagent` 用例钉住不变量 11 的三站口径
  （pre 改写真正生效、post 改写结果、嵌套调用各有轮次、`tool.call` 默认绕开 / `relay:true` 触发）。
