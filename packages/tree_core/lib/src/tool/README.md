# tool（工具层）

模型能做的事都在这里：工具契约、工作空间执行器、内置工具集，以及 MCP / 插件工具的动态注入与兜底入口。

## 文件

| 文件 | 作用 |
| --- | --- |
| [tool_runner.dart](tool_runner.dart) | 工具契约（`ToolSpec` / `ToolInvocation` / `ToolOutcome`）与 `EmptyToolRunner` |
| [workspace_tool_runner.dart](workspace_tool_runner.dart) | 工作空间执行器：IO 解析与缓存、内置 + MCP + 插件工具分派、结果（默认不）截断 |
| [builtin_tools.dart](builtin_tools.dart) | 内置工具集：read / write / edit / grep / terminal / set_todo_list / ask_user_question（**一次可问多道题**：`questions:[{question,options}]`，`question` 是单问简写；+ `with*` 开关下的团队与 Spec 工具） |
| [message_tool.dart](message_tool.dart) | 团队通信域：`send_message` / `broadcast` / `wait_for` |
| [team_tool.dart](team_tool.dart) | 团队管理域：建队、成员名单与档案、审核状态 |
| [spec_tool.dart](spec_tool.dart) | 任务型规范：`select` / `create` / `update` |
| [mcp_tool.dart](mcp_tool.dart) | MCP 工具的发现入口（help / call）与"已配置但当前不可用"的如实说明 |
| [plugin_tool.dart](plugin_tool.dart) | 插件工具发现入口与按定义来源路由的兜底调用 |
| [question_channel.dart](question_channel.dart) | 提问通道契约（工具层 ↔ 编排层，避免反向依赖） |
| [subagent_tool.dart](subagent_tool.dart) | **临时员工**工具（`subagent`）：形状/schema 校验 + 落点契约（`SubagentChannel`）与消息标记（`SubagentTag`） |
| [status_text.dart](status_text.dart) | 每次工具结果前拼的"会话状态"（todo + 已选 Spec） |
| [todo_store.dart](todo_store.dart) | 待办存储（markdown 勾选清单 + 内存实现） |
| [terminal_hooks.dart](terminal_hooks.dart) | 后台长任务管理器（terminal 的 hook 模式）：本机与远端**同一套台账**，执行/日志委托给 `BackgroundExecHost`；任务落盘并跨重启**接续**；登记进运行中工具表（可见可关） |
| [hook_ledger.dart](hook_ledger.dart) | 后台任务**落盘台账**（`<数据根>/hooks/<task_id>.json`，原子写）：远端 hook 跨核心/应用重启接续的凭据（任务 id / 归属会话 / 命令 / 日志相对路径 / 远端 pid） |
| [tool_run_registry.dart](tool_run_registry.dart) | **运行中工具/请求登记表**（内存）：挂载点在 `WorkspaceToolRunner` 一次入口；超阈值 warning（默认 300s，会话 + `core.log`）、广播站 `system.tool.timeout`、REST 快照、**显式关闭**（同一实现，绝不自动杀） |
| [tool_runs_tool.dart](tool_runs_tool.dart) | 内置工具 **`tool_runs`**：`action=list`（自己 + 直属下级正在执行的运行）/ `action=close`（按 handle 关闭，与右栏按钮 / 执行站 `tool.close` 同一实现） |
| [tool_runs_scope.dart](tool_runs_scope.dart) | `tool_runs` 的**作用域**（自己 + 直属团队成员 + 直属临时员工）与越权拒绝（`ToolCloseOutcome.denied`） |
| [llm_request_guard.dart](llm_request_guard.dart) | 把「运行中的 **LLM 请求**」登记进同一张表的现成实现（沉默才登记；关闭即取消这一跳） |

## 不变量（assertions）

1. 工具层**不认识 LLM 类型**：只声明名字 / 说明 / JSON Schema，转成 `LlmToolSpec` 是引擎的事——工具实现因此可脱离 LLM 单测。
2. 工具参数一律**工作空间相对路径**；绝对路径 / 盘符 / `..` 由 `WorkspaceIO.resolve` 拒绝。
3. 每个 agent 一个 IO，按需创建并缓存；`.self` 的翻译**只发生在 `PrivateWorkspaceIO(agentId)` 一处**——规范文本、系统提示词、结果门控、插件文档播种都经 `WorkspaceToolRunner.ioFor` 生效，所以它们的路径常量**一个都不用改**。**终端命令不经过翻译**（`exec` 直接在根下跑 shell）。
4. **默认不截断工具结果**：有界性由 LLM 侧的 `ToolResultGate` 负责（超长结果写进 `.self/results/`，送模型只留提示 + 预览）。工具层若抢先按字符砍到 24000，门控的 8000 token 阈值就只覆盖 16000~24000 这一段，再长根本走不到重定向。`maxResultChars` 只给确实要硬上限的调用方。
5. MCP 与插件工具**不在内置集里**：按"已就绪的服务"动态注入，工具名带 `mcp__<服务>__` / `plugin__<id>__` 前缀；服务列表是运行期才知道的。工具表**每轮现取**（不进系统提示词前缀）。
6. `message` 的 `session_id` 默认取**发起会话**（`invocation.sessionId`）⇒ 派活与回信都落在发出消息的那个会话里，不会跑去默认会话。
7. 每个工具结果前拼"会话状态"（todo + 已选 Spec），且**实时取**：模型可能在工具循环中途改 todo 或挂 Spec，状态必须是当下的。
8. **后台任务（`hook=true`）在本机与远端是同一套语义，且是"看得见 + 关得掉"的一等运行项**
   （[terminal_hooks.dart](terminal_hooks.dart)、[hook_ledger.dart](hook_ledger.dart)、
   `tree_local_exec` 的 `BackgroundExecHost`）：
   - **执行与日志都走工作空间 IO 的原语**：本机 = 脚本文件 + shell 重定向直写日志、进程句柄在手；
     远端（SSH）= `nohup` 起在**远端**、日志落**远端工作空间**、退出码靠哨兵文件 + **3s** 间隔轮询。
     因此远端的 `hook=true` 不再"把远端路径当本机路径用"（旧实现在 SSH 下必然报 `No such file`）；
   - **`hook=true` 必须"立刻返回"**（不许退化成同步调用）：远端的命令形状把后台化与 `echo $!` 都放进
     **子壳**（`( setsid nohup … > <日志> 2>&1 < /dev/null & echo $! )`）⇒ 子壳立刻退出、SSH 通道立刻
     EOF、工具立刻返回；`setsid` 让命令自成进程组（pgid == pid），`cancel` 的 `kill -TERM -<pid>` 才落在
     正确进程组。旧形状 `{ … ; } & echo $!` 会让承载组的子壳握着通道、**阻塞到命令结束**（实测
     `sleep 25` 阻塞 25.09s，见 [../../../../../docs/known-issues.md](../../../../../docs/known-issues.md) #23）；
   - **通知一律如实**：结束写结束标记并回调唤醒 agent；远端进程消失但没留下退出码 ⇒ 给可辨退出码；
     链路判失活 ⇒ 记 `remoteFailureExitCode` 并写明"拿不到远端状态"；
   - **远端任务落盘台账**：核心/应用**重启后接续**——启动即探一次哨兵，已结束就立刻把完成提示
     **投递回原会话**（台账里的 agent + 会话），未结束就重挂轮询；agent / 会话已不存在则**如实记日志、
     台账保留**，不假装投递成功；
   - **关停语义两端不同且如实**：本机杀进程树；**远端不杀**（关应用不该杀掉远端训练），台账留待下次接续；
   - **右栏可见、用户可关**：登记进 `ToolRunRegistry`（`watchdog: false` ⇒ 长任务不判超时、不刷 warning；
     `crossCall: true` ⇒ 跨工具调用存活），用户点关闭 = 取消该 hook（本机真杀进程树；远端尽力 `kill`，
     拿不到 pid 时**如实**回原因）。**不做**"两个新站点 + leader 可杀"（用户暂缓）。
9. 待办落盘是 markdown 勾选清单，**正文放在最后**（正文里出现任何符号都不破坏解析）；`status=` 是**权威值**，勾选框只同步人类可读性；缺元数据的行也能读出来（id 自动生成、状态按勾选框推断）。
10. 提问通道是**具名契约**：工具层不反向依赖编排层（依赖方向 `tool` ← `agent`）。**多问题口径**
    （用户要求 2026-10-04：「ask_user_question 工具仅支持单个问题（改为支持多问题）」）：
    - 工具 schema 收 `questions`（数组，每项 `{question, options}`，**1~`BuiltinTools.maxQuestionsPerCall`(10) 道**）
      与单问简写 `question`/`options`（数组优先）；都缺 / 题面为空 / 选项项不是对象 / 超过上限
      ⇒ **一律可读错误**（不静默截断、不假装问过）；
    - 形状与排版只有一份实现：`question_channel.dart` 的 `AskedQuestion`（形状）、
      `normalizeAnswers`（答案归一成与题数等长、缺项未作答）、`formatAnswerLines`（**单问输出与
      "只支持单问题"时期逐字一致** `用户回答：B`；多问逐题成行、未答写 `（未作答）`）、
      `prefixFirstQuestion`（来源标记只加第一问，别在别处再写一套）；
    - 结果交给模型前不做任何"猜"：未答项如实标注，模型据此决定追问或按假设继续。
    - **等待作答期间不被插话打断**（用户 2026-10-04 断言：「任何工具调用执行期间不被插话打断，
      插入消息（包括 terminal/subagent hook 完成消息）在工具调用期间必须排队等待」）：
      `AskQuestionRequest.isCancelled` 必须是**硬取消**谓词（`stop` / 删除 agent / 关服），
      插话（用户新消息、terminal/subagent hook 完成提示）不在其中——它只让消息**排队**等到作答或显式取消
      （软 / 硬两条谓词的分工见 [../agent/README.md](../agent/README.md) 不变量 13）。
11. **`subagent` 与其它工具同权、同三站**（用户硬断言，不给它开后门）：
    - **执行站**：`subagent` 一律经 `WorkspaceToolRunner._execute` → `BuiltinTools.run` 分派——和 `edit` / `write` / `team` 同一个入口。执行站命令 `tool.call`（`runFromPlugin`）因此能以 `tool: 'subagent'` 跑起来，权限口径与模型调用完全一致（**没有**特例白名单、**没有**特例拦截）；`origin` / `source_plugin_id` / `relay:false 默认绕开站点` 这些语义与普通工具逐字一致。
    - **中转站**：`system.relay.tool.pre` / `.post` 对 `subagent` 照常生效——pre 改写的 `task` / `name` **真正生效**（子 agent 拿到的就是改写后的那份），post 可改结果文本。
    - **广播站**：`system.broadcast.tool.pre` / `.post` 各发一条（单向、不等回包），载荷字段与普通工具完全相同（`point` / `phase` / `tool` / `call_id` / `round` / `origin` / `arguments`、post 还有 `result`）。
    - **子 agent 自己的工具调用同样三站齐全**：临时员工跑在**同一个** `WorkspaceToolRunner` 上（同一份 relay/broadcast、同一份 `origin='agent'` 语义），绝不因为"跑在后台"就绕开站点；轮次序号按**调用**分配（`_relaySeq` 不是共享实例字段），父调用与嵌套调用、同名工具的并行调用都不会串号。
    - 声明即能力：`specsFor` 在接了 `subagentService` 时**包含** `subagent`，未接线时**不包含**；`BuiltinTools.needsWorkspace('subagent')` 恒为 **false**（工具本身不读文件，子 agent 的工作空间由它自己在运行时解析，缺工作空间给**可读错误**）。
    - 唯一的口径差异（**权限，不是绕站**）：临时员工的工具表**没有** `team` / `message`（不能被派活、不能建队/管队），但**有** `subagent`（可以再召，把同一个大任务拆细；层级上限 `SubagentLimits.maxDepth`）。

12. **`subagent` 的使用策略写在三处提示词资产里，口径一致**（[test/subagent_tool_test.dart](../../../test/subagent_tool_test.dart) 强制）：
    工具描述（[subagent_tool.dart](subagent_tool.dart) 的 `ToolSpec.description`，模型决定要不要调时看到的那段）、
    系统提示词种子（[system_prompt_file.dart](../agent/system_prompt_file.dart) 的「临时员工（subagent）使用策略」章）、
    内置规范（[builtin_specs.dart](../spec/builtin_specs.dart) 的 general-task / hard-task / team-meeting）。
    三处必须同口径：什么时候用 / 什么时候不用、`task` 必须自包含、同职责范围才复用 `subagent_id`、
    并行按文件划分（共享同一工作空间）、套娃只用于把同一个大任务拆细、与 `team` 的边界（跨会话/正式流程才用 team）。
    理由是"知道"与"被允许"发生在三个时刻：系统提示词在**动手之前**，工具描述在**决定调用的当下**，
    内置 Spec 在**按规范分工的当下**——缺任何一处，模型都可能在错误的场景派出临时员工。

## 测试

```bash
cd packages/tree_core
dart test test/builtin_tools_test.dart test/terminal_hooks_test.dart test/terminal_hook_wake_test.dart \
          test/terminal_soft_timeout_test.dart test/terminal_hooks_ssh_test.dart test/hook_ledger_test.dart \
          test/todo_store_test.dart test/tool_relay_test.dart \
          test/tool_list_refresh_test.dart test/session_status_test.dart test/team_tool_test.dart \
          test/plugin_tool_define_test.dart test/plugin_tool_table_test.dart test/plugin_broadcast_tool_test.dart \
          test/subagent_tool_test.dart
```

- `terminal_hooks_ssh_test.dart`（假 SSH 传输）：远端后台的**命令形状**（`nohup` / 三路重定向 /
  `< /dev/null` / 哨兵 / `echo $!`）、启动即返回、轮询到结束后的唤醒、`GONE` 与链路失活的**如实**退出码、
  远端 `cancel` 的尽力语义，以及**右栏登记 + 用户关闭 = 取消该 hook**。
- `hook_ledger_test.dart`：台账往返、原子写（不留 `.tmp`）、按开始时刻升序、损坏条目**记日志后跳过**、
  id 里的路径分隔符被清洗。
- `terminal_hooks_ssh_test.dart` 的接续用例：**不重跑命令**（只探测）、应用不在运行期间跑完 ⇒ 启动即
  收尾并**投递回原会话**、工作空间不可用 ⇒ 如实记日志 + 台账保留。

- `subagent_tool_test.dart`：工具形状与校验（缺/空 `task`）、阻塞模式把最终报告作为工具结果返回、
  复用（同 id 续活、历史延续、不新建实体）、层级上限的可读错误、**并行后台**（同一轮 3 个真的同时跑、
  三份结果各注入一次且不串）、父 agent 在途轮次不与之撞键、工具表裁剪（临时员工没有 team/message、有 subagent），
  以及**使用策略写在三处提示词资产**的口径钉子（不变量 12：工具描述 / 系统提示词种子 / 内置 Spec）。
- `tool_relay_test.dart` / `plugin_broadcast_tool_test.dart` 里的 `subagent` 用例钉住不变量 11 的三站口径
  （pre 改写真正生效、post 改写结果、嵌套调用各有轮次、`tool.call` 默认绕开 / `relay:true` 触发）。
