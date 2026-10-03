# 架构

> 面向**改代码的人**。协议细节：[packages/tree_protocol/README.md](../packages/tree_protocol/README.md)；
> 插件协议：[plugin-development.md](plugin-development.md)；团队语义：[team.md](team.md)。

## 1. 进程模型

```
Flutter UI 进程（lib/）                     核心进程（packages/tree_core_cli）
  main.dart → CoreProcessLauncher.start()
    ① 附着模式：TREE_CORE_URL + TREE_CORE_TOKEN
    ② 否则拉起 tree_core（应用同目录 → .output/）
    ③ 读 stdout 首行握手 → 注入 baseUrl + token
  ApiService / WebSocketService ──HTTP+WS──▶ 127.0.0.1:<随机端口>
```

- 核心只监听 `127.0.0.1`，**每次启动都重新生成一次性 token**，只经 stdout 的单行 JSON
  （`CoreHandshake`：`{port, token, pid, version}`）交给父进程；stdout 不放任何其它内容（日志走 stderr）。
- **关窗 ≠ 退出**（默认）：关闭按钮被 `window_manager` 拦下，改为隐藏窗口到系统托盘，核心与在跑的
  agent 任务继续；真正退出走托盘菜单「退出 Tree」或设置页的退出按钮——那时才向核心 stdin 写一行
  `shutdown`，核心优雅退出，超时才强杀，不留孤儿进程。托盘装不上时关闭按钮退回"直接退出"。
- **同一数据根只允许一个实例**：UI 在拉起核心**之前**先抢一把回环端口锁（锁键 = 数据根：
  `TREE_HOME`，未设即 `default`），第二个实例握手确认后立刻退出，并请已有实例把窗口叫到前面；
  端口被别的程序占着时照常启动（不因为撞端口把用户挡在门外）。见 `lib/io/single_instance.dart`。
- 核心可执行文件查找顺序：`TREE_CORE_EXE` → 应用同目录 → 向上 8 层找 `.output/tree_core.exe`（开发期）。
  都找不到时 UI 显示**带修复指引**的错误页。

## 2. 核心模块

| 模块 | 职责 |
| --- | --- |
| `CoreServer` | HTTP 路由 + WS 帧分发 + 鉴权（token）+ 路由覆盖度不变量（未实现的路由显式登记为 501） |
| `ConversationService` | `user_message`/`stop` → 落库 + 流式下行；**按 agent×会话**串行链、插话打断、`stop` 级联、`agent_status` 广播 |
| `LlmAgentEngine` + `LlmSession` | OpenAI 兼容 SSE 客户端 + **无轮次上限**的工具循环；用量累计、上下文压缩、取消粒度 |
| `WorkspaceToolRunner` | 工具表组装（内置 + MCP + 插件）+ 工具执行 + 工作空间 IO 缓存与**私有目录分栏** |
| `WorkspaceIO`（`tree_local_exec`） | 本机（`dart:io`）与 SSH（`dartssh2`）同一接口：读 / 写 / 编辑 / grep / 列目录 / exec / git |
| `TreeStore` | 数据根读写：`agents/*.yaml`、`config/*.yaml`、`data/<agent>/<session>/{session.json,messages.jsonl}`，写入走 write-behind 队列 |
| `TeamService` + `MessageDispatcher` | 成员即 agent；创建/审核/移除；派活、广播、`wait_for`；活动日志；失活 fail-closed + 待补发 |
| `SpecService` | 内置规范播种 + 自定义规范扫描 + 索引/已选全文两个快照（进系统提示词） |
| `McpService` | stdio / Streamable HTTP MCP 客户端；懒连接、心跳判活、工具命名空间化 |
| `PluginBus` + 站点体系 | 插件子进程 JSON-RPC；广播 / 执行 / 中转 / 收集四类站点、17 个点位 |

## 3. 一次会话运行的链路

1. **落库 + 入队**：`user_message` 先写 `messages.jsonl`，再按 `agentId|sessionId` 入链
   （同一会话串行；**不同会话并行**，见 §5）。
2. **构造上下文**（`ConversationService._contextOf` → `systemPromptWithWorkspace`）：
   ```
   [0] system  = 工作空间基础段(.self/system_prompt.md) + agent.system_prompt
                 + 工作空间软约束 + Spec 索引 + 已选 Spec 全文
   [1..n] 历史 = 逐字重建的"实发那一份"（见 §4）
   [last] 本轮输入
   ```
3. **工具循环**：请求 → 流式事件（thinking / text / tool_call / usage）→ 执行工具 → 把结果回灌 →
   下一跳。**没有轮次上限**，只有取消、出错或模型给出最终文本才结束。
4. **下行与落库**：思考段 / 正文段 / 工具卡片各自独立成消息（`msg_start`/`msg_chunk`/`msg_end`），
   增量按刷新帧率攒帧合并；最终文本段挂 usage。
5. **结束**：仍打开的分段收尾 → 该 agent 没有其它在途会话时广播 `agent_status(idle)`。

## 4. 前缀缓存策略（省 token 的关键）

| 对象 | 位置 | 策略 |
| --- | --- | --- |
| 系统提示词 | 消息 `[0]` | **按会话钉住**：只在会话初始化、压缩后、显式失效（改 agent 配置 / 重置工作空间）时重建；中途不重建 |
| 历史消息 | `[1..n]` | 逐字复用"当初发出去的那份字节"（`tool_arguments_raw` / `tool_result_for_model`），不重新推导 |
| 工具表 | 请求体 `tools` 字段 | **每轮现取**（MCP / 插件随时可能上线新工具）；它不进消息前缀，刷新不伤缓存 |
| 超长工具结果 | 工作空间文件 | 门控重定向：完整结果落 `.self/results/`，送模型的只有提示 + 预览 |

配套：压缩发生后系统提示词按新会话状态重建（一次不可避免的换字节），因此压缩**只在阈值触发**时发生，
不做"每轮小修"。详见 [known-issues.md](known-issues.md) 的 #6 / #8。

**token 口径（全局唯一）**：`tokens = ceil(字符数 / token_scale)`，`token_scale` **逐模型**存在
`config/models/<id>.yaml`（初值 2.00，两位小数）。上下文进度、压缩阈值、超长结果门控、token 帧率节流、
工具参数计量**全部走同一个函数**（`util/tokens.dart`）。学习：端点回真实 `prompt_tokens` 且**超过**该模型
`longest_session_tokens` 时，用"当次请求上下文字符数 / 真实 prompt_tokens"刷新 `token_scale` 写回 yaml
（无 usage 的端点只读不写）——长会话才逼近真实比值，因为系统提示词/工具声明这类固定开销不随字符增长。

## 5. 会话与并发

- 运行键是 `agentId|sessionId`（`ConversationService._runKey`）：
  **同一会话内串行**（同一会话的流式片段交错会污染前端 `msg_chunk` 追加），
  **不同会话并行**（前端按 `session_id` 过滤下行帧）。
- **插话**：同一会话在途时又来新消息 ⇒ 取消在途那一轮（工具循环在下一跳收口，不再发言），
  新消息那轮接着跑；**跨会话不打断、不排队**——各会话历史互相独立，打断只会白白毁掉答复。
- **`stop`** 是 **agent 级**：该 agent 的全部在途会话 + 排队任务一起停（epoch 作废排队任务）。
  用户按 stop 会看到"已停止本轮生成。"；被新消息插话则**不提示**（那条消息本身就是上下文）。
- `agent_status`：`working` 随轮次开始广播；`idle` 只在该 agent **一个在途轮次都不剩**时广播。

## 6. 工作空间与私有目录

- **模式**：agent 的 `ssh:` 段非空 = SSH 模式（工具跑在远端，`ssh.root` 是工作空间根）；
  否则本机模式，根 = `workspace_dir`（空 = `<数据根>/workspaces/<agent_id>`）。
- **团队成员共享工作目录**：成员与 leader 同一个根（同一份项目文件）；
  **私有状态按 agent 分栏**：`.self/…`（模型口径）在磁盘上是 `.tree/<agent_id>/.self/…`。
  翻译由 `PrivateWorkspaceIO` 装饰器一处完成（工具 / Spec / 提示词 / 结果门控 / 文件面板全覆盖）；
  **终端命令不经过翻译**，所以系统提示词里写明真实路径。
- **成员跟随 leader 的 SSH**：成员没有自己的 `ssh:` 就用 TOP 那份（同一台远端主机、同一个根）。
- 旧工作空间的 `.self` 由核心启动时一次性迁移到 `.tree/<TOP id>/.self`（幂等）。
- 文件投递（`message send_message files:`）落到接收方 `.input/<日期>/`：**四种组合都支持**——local↔local（本机 `File.copy`）、
  local↔SSH、SSH↔SSH（含跨主机，**经本机中转**）；判据是**有效 SSH 接线**（`teamSshConfigFor`），不是 `agent.sshConfig`；
  单文件 ≤32 MB、越界路径拒绝、部分失败如实回 `files_failed`（见 [team/README.md](../packages/tree_core/lib/src/team/README.md) 不变量 15）。

## 7. 团队与消息

- **成员即 agent**：成员就是 `agents/<member_id>.yaml`，带 `team_id`（TOP）/ `parent_agent_id`（直属上级）/
  `level`；新建成员**恒为无模型 + 待审核**，用户赋模型并审核后才接活（`reviewBlock` 闸门）。
- **没有"任务"对象**：派活就是 `message send_message`；`wait_for` 用"先观测到 working 再转 idle"判完成，
  没有静态时长上限；成员/链路失联 ⇒ 返回**部分结果 + 未响应者清单**，不整体失败。
- **会话归集**：派活默认落在**发起这一跳的会话**（`ToolInvocation.sessionId`），成员的执行与回信因此都留在
  用户当前会话里（teammates 窗口按会话过滤，才看得到进度）。
- **活动日志**：`.self/activity.log`（真实路径 `.tree/<agent_id>/.self/activity.log`），
  通过该 agent 的工作空间 IO 读写 ⇒ **SSH 模式的 agent 也写自己远端那份**。

## 8. Spec（规范）与提示词资产

内置模板内嵌在核心包里，首次用到某工作空间时播种到 `.self/spec/`（升级会先备份成 `.bak.<n>`）；
自定义规范同样落在那里。系统提示词注入两段：**索引**（id + 适用条件）与**已选全文**（会话级，挂 hook）；
`spec select` 直接返回全文，因此不依赖提示词也能干这一步。

### 8.1 提示词资产（**改提示词先看这张表**）

模型看到的每一段文字都在下表里，**没有第二处**；括号里是可用于 grep 的符号名：

| 提示词 | 源码（唯一真源） | 运行期落点 |
| --- | --- | --- |
| 默认系统提示词（`defaultSystemPromptSeed`） | [agent/system_prompt_file.dart](../packages/tree_core/lib/src/agent/system_prompt_file.dart) | `.tree/<agent_id>/.self/system_prompt.md`——**只播种一次**：落盘后用户改文件即改提示词，代码不再覆盖；右侧「重置」先备份成 `.bak.<n>` |
| 系统提示词拼装顺序（`systemPromptWithWorkspace`） | [agent/workspace_prompt.dart](../packages/tree_core/lib/src/agent/workspace_prompt.dart) | 基础段 + agent 自己的 `system_prompt` + 工作空间软约束 + Spec 索引 + 已选 Spec 全文 |
| 内置 Spec 模板（`kBuiltinSpecs` / `kBuiltinSpecTexts`：general-task / hard-task / team-meeting / plugin-creator + 四条共享的「第 0 步」） | [spec/builtin_specs.dart](../packages/tree_core/lib/src/spec/builtin_specs.dart) | `.tree/<agent_id>/.self/spec/<id>.md`——**核心管理的快照**：模板内容变了就刷新（旧副本备份成 `<id>.md.bak.<n>`），副本 `version` 高于模板则保留不动 |
| 插件开发指南（模型读的协议口径） | [plugin-development.md](plugin-development.md) | 选中 `plugin-creator` 规范时播种到 `.self/docs/plugin-development.md`（[spec/builtin_spec_assets.dart](../packages/tree_core/lib/src/spec/builtin_spec_assets.dart) + [plugin/plugin_guide.dart](../packages/tree_core/lib/src/plugin/plugin_guide.dart)） |
| 附件说明片段（`attachmentPrompt`） | [agent/attachment_prompt.dart](../packages/tree_core/lib/src/agent/attachment_prompt.dart) | 拼进 user 消息的附件路径说明；生成与压缩估算**共用同一份**（逐字一致） |
| 工具描述 / 参数 schema（模型读的"工具用法"） | [tool/](../packages/tree_core/lib/src/tool/) 各文件的 `ToolSpec`：`builtin_tools.dart` / `message_tool.dart` / `team_tool.dart` / `spec_tool.dart` / `mcp_tool.dart` / `plugin_tool.dart` | 每轮重新下发的工具表（**不进前缀缓存**）；MCP / 插件工具的描述由服务与插件自带 |
| 每次工具结果前拼的会话状态（`sessionStatusText`） | [tool/status_text.dart](../packages/tree_core/lib/src/tool/status_text.dart) | todo 三态 + 已选 Spec 三态 |
| 压缩摘要提示词 | [llm/llm_summarizer.dart](../packages/tree_core/lib/src/llm/llm_summarizer.dart) | 压缩时的一次总结调用（不带工具、复用模型输出长度） |

两条配套规则：

- **改法**：改 `defaultSystemPromptSeed` 只影响**新工作空间**（已有工作空间的 `.self/system_prompt.md` 是用户文件，
  不覆盖——要让线上生效得用右侧「重置」，见 [known-issues.md](known-issues.md) #5）；改 Spec 模板要**同时 bump `version:`
  并把原因写进 `changelog:`**（刷新按内容比对，同版本内容不同也会刷新并备份；版本号是"副本比模板新就保留"与审计的依据）。
- **工具使用策略写在哪三处**：模型"知道何时 / 如何用某个工具"靠三处文字——工具描述（每轮随工具表下发）、
  系统提示词种子（动手之前的策略章，如「临时员工（subagent）使用策略」）、内置 Spec（按规范分工时的口径）。
  三处必须同口径，由 [test/subagent_tool_test.dart](../packages/tree_core/test/subagent_tool_test.dart) 钉住；
  改其中一处就要同步另两处（改法同上：工具描述随代码走、种子只影响新工作空间、内置 Spec 要 bump version）。
- **侦察口径（已写进系统提示词与 general-task / hard-task）**：侦察**从文档开始**——`README.md` 与本索引 →
  相关模块 README 的「不变量（assertions）」→ `development.md` 的命令 / `known-issues.md` 的坑 → 领域指南 →
  **再进代码核对**。文档与代码冲突**以代码为准**，但偏差要写进侦察笔记（那是顺手要修的文档问题）。

## 9. MCP 与插件

- **MCP**：`config/mcp.yaml` 声明服务（stdio / Streamable HTTP），工具命名空间化为
  `mcp__<service>__<tool>`；懒连接 + 心跳判活；坏服务只影响自己。
- **插件**：进程外子进程，行分隔 JSON-RPC 2.0。核心 → 插件：`hello` / `tools/list` / `tools/call` /
  `ping` / `shutdown` / `station/request` / `station/cancel` / `event`；
  插件 → 核心（主动请求）：`station/command` / `station/subscribe` / `station/unsubscribe` /
  `station/register` / `station/unregister`，通知推流 `station/stream`。
- **站点体系**四类：广播（`system.broadcast[.tool.pre|.tool.post]`）、执行
  （`fs` / `terminal` / `agent` / `ui` / `llm` / `tool` / `session`）、中转
  （`tool.pre` / `tool.post` / `llm.handle` / `llm.request` / `context.compact` / `prompt.system`）、
  收集（`plugin.tool.define`）；隔离四元组 `team_id / agent_id / session_id / mode_key` 由核心按**真实归属**解析，
  不信任插件声明。
- **隔离判定一律 fail-closed**：落点是"消息 ↔ 订阅者"两侧精确匹配（站点本身不绑 scope）；
  订阅可以声明更细的粒度，但**不得放大**到别的 team/agent；`mode_key` 必须区分 `local` 与 `ssh`
  （否则 SSH 团队的插件命令会打到本地工作空间）。写插件看 [plugin-development.md](plugin-development.md)。

## 10. 存储

```
<数据根>/                          # %APPDATA%\Tree；TREE_HOME / --data-dir 覆盖
├── config/{settings,models/*,mcp,plugins,stations}.yaml
├── agents/<agent_id>.yaml         # agent / 成员；system_prompt 可多行
├── logs/core.log(+core.1..4.log)  # 核心日志落盘：stderr 之外的第二份，8 MiB × 5 轮转，行带 pid=
├── data/questions.json            # 提问（跨会话队列）
└── data/<agent>/<session>/
    ├── session.json               # 会话元数据（原子快照；含 selected_spec_ids / 压缩摘要）
    └── messages.jsonl             # 消息追加日志（一行一条；工具原始参数与"送模型那份"一并落库）
```

yaml 里**不属于已知键**的内容会被原样保留并写回（用户手写的注释/键不会丢）。
写入统一走 `store/write_queue.dart` 的 write-behind 队列，`flush()` 保证落盘。

**核心日志**（`util/core_log_sink.dart`）：所有 `[core:*]` 日志的唯一出口 = stderr（发布版看不到）**加**一份
落盘 `<数据根>/logs/core.log`；写文件失败只提示一次并降级为纯 stderr，**永不抛、永不阻塞生成**。
核心在握手（`core_handshake.dart`）里带上 `data_root`（**可选字段**，为空时不写键 ⇒ 老前端零感知），
应用据此在「设置 → 核心日志」提供"查看最近 N 行 / 打开日志目录"。核心库内仍有 3 处直写 stderr 未纳入
（见 `docs/known-issues.md`）。

## 11. 活性与超时口径（M9 规约 1.1）

| 通道 | 超时判据 |
| --- | --- |
| 消息发送（WS / 团队派发） | 无静态上限；连接心跳丢失 ⇒ 判失活并**登记补发**，重连后重播（帧无 TTL） |
| 执行器命令（local / ssh） | 无静态上限；心跳丢失 ⇒ 显式失败并触发重连 |
| 本地 terminal | 无静态上限（进程活着就一直等）；可选**软超时**：到点不杀进程，转 hook 后台任务，完成后再唤醒 agent |
| 插件宿主（stdio） | 无静态上限；连续 N 拍无心跳 ⇒ 标 `degraded`（面板橙色角标），**不杀进程** |
| MCP 客户端 | 无静态上限；每 I 发一次 ping，连续 N 拍无心跳 ⇒ 在途请求显式抛错 |
| LLM 传输 | 只有建连保留短超时；流式读取**无总时长上限**，收到任意字节即续心跳 |
| 前端 WS 心跳 | 前端每 **10s** 发一次 `heartbeat`，**必须小于**核心判活窗口 I×N = 30s |

唯一保留的静态窗口是收尾性质的：本地进程**已经死后**，残余管道再等 300ms 输出静默 + 3s 兜底。

## 12. 安全边界

- **路径**：工具参数一律**工作空间相对路径**；`WorkspaceIO.resolve` 拒绝绝对路径 / 盘符 / `..` 逃逸，
  `FileService` 是 REST 侧同一条边界。
- **鉴权**：REST/WS 全部要求 `Authorization: Bearer <一次性 token>`；核心只监听回环地址。
- **密钥**：模型 `api_key` 只出现在请求头，绝不进日志/帧；`GET /api/models` 走字段白名单。
- **权限**：插件/站点的跨 team、跨 mode 命令按四元组 fail-closed 拒绝。
- **工作空间隔离**：团队成员共享项目目录，但私有状态（`.tree/<agent_id>/.self`）各自一栏。

## 13. 跨模块不变量（assertions）

改代码时这些**不许破**，破了必须同步改文档并补防回归用例（见 [CONTRIBUTING.md](../CONTRIBUTING.md)）：

1. 工具参数是工作空间相对路径，越界必须显式报错，不能"尽力而为"。
2. 私有状态只写 `.tree/<agent_id>/.self/`；项目文件才共享。
3. 系统提示词只在会话初始化 / 压缩后 / 显式失效时重建；工具表每轮现取。
4. 不存在静态任务超时；判活只认心跳或进程存活。
5. 插话按**会话**、`stop` 按 **agent**；被插话掐掉的那一轮不再发言。
6. 任何失败都必须**可读上报**（日志 / 帧 / 工具结果三选一以上），禁止静默丢弃。
7. 协议常量只从 `tree_protocol` 取；新增 REST/WS 必须进完备性清单。
8. 落库优先：先写 `messages.jsonl` 再行动（重启后可恢复）。
9. 密钥与 token 不进日志、不进帧、不进仓库。
10. 每个新能力都要有"它坏了会怎样"的显式路径（降级 / 报错 / 部分结果），而不是"希望它不出错"。
11. **Windows runner 在"带着 RedirectionGuard"启动时会自愈重启**
    （[../windows/runner/main.cpp](../windows/runner/main.cpp)、[../tool/installer/tree-desktop.iss](../tool/installer/tree-desktop.iss)，
    机制与实测见 [known-issues.md](known-issues.md) #16）：Windows 11 的 RedirectionGuard
    （`EnforceRedirectionTrust`）让进程**拒绝跟随"非管理员创建的"重定向点**，而它**沿调用链传播**；
    安装器是提权进程 ⇒ 被它拉起的 Tree 及其整棵子树（核心 / 集成终端 / 用户在终端里跑的构建命令）
    都拒绝跟随 `windows/flutter/ephemeral/.plugin_symlinks/*` ⇒ `flutter build windows` 在那里必然失败
    （而用户自己开的终端里能成功）。这条策略**清不掉**（`SetProcessMitigationPolicy(id, 0)` →
    `ERROR_ACCESS_DENIED`）、**也没有创建期开关**，所以 runner 的处置是：启动时读一次
    `GetProcessMitigationPolicy(ProcessRedirectionTrustPolicy)`，非零就**经 explorer 重新拉起自己**
    （explorer 那条链实测是 0x0，能跟随）后退出；`--tree-rt-selfcheck` 只报状态与决定（打包自检 /
    回归用例用它，不起 Flutter）；重启失败、或重启后仍非零 ⇒ 往 **stderr** 留一句可读的话再照常启动
    （**不静默、也不把用户挡在门外**）。安装器里"启动 Tree"**必须经 `explorer.exe`**（不能直接 Filename
    指 app），否则新装的实例一出生就带着这条缓解。

## 14. M9 语义决策速查（已落地）

M9 阶段定的 14 项语义决策已全部实现，逐项的**实现记录**归档在
[archive/m9-plan.md](archive/m9-plan.md)；这里只留"现在是什么口径"，改代码时按它对照。

| 决策 | 现在的口径 | 落在哪 |
| --- | --- | --- |
| 取消静态超时，改心跳判超时 | 见 §11；本地执行体活性 = 进程存活 | `util/liveness.dart`、各通道心跳台账 |
| 站点隔离矩阵 | 四元组 fail-closed，订阅不得放大，`mode_key` 区分 local/ssh | §9、`plugin/station_scope.dart` |
| token 口径统一 | `ceil(字符/scale)` 唯一换算 + 逐模型学习 | §4、`util/tokens.dart` |
| Q1 上下文超限未压缩 / 超长工具结果 | 阈值触发压缩；超长结果重定向到 `.self/results/` 只送预览 | §4、`llm/llm_result_gate.dart` |
| Q2 删除 cloud 模式 | 只有 local / ssh 两种工作面（`mode_key`） | `workspace_io`、执行器服务 |
| Q3 消息分段 | 思考段 / 正文段 / 工具卡片各自独立成消息，中间输出不并进最终回复 | §3、`ui/widgets/message_panel.dart` |
| Q4 远端 Git | 远端经工作空间 IO 的 exec 通道跑 git，非仓库返回空态 | `files/file_service.dart`、`tree_local_exec` |
| Q5 多文件粘贴 | 输入框支持多附件（上传到 `.input/<日期>/` 后再发消息） | `lib/ui/widgets/message_input.dart` |
| Q6 草稿缓存 | 草稿按 **team + session** 缓存，切会话不丢 | `lib/ui/widgets/message_panel.dart` |
| Q7 下载列表"打开所在位置" | 前端调系统文件管理器定位下载文件 | `lib/ui/services/file_reveal.dart` |
| Q8 工具轮次上限 | 核心**不设上限**；要限由插件订阅 `agent.tool_call` 后 `agent.stop` | `llm/llm_session.dart`、`plugin/agent_events.dart` |
| Q9 spec 工具瘦身 + 索引前置 | `spec` 只有 select/create/update；索引进系统提示词、`select` 直接返回全文 | `spec/spec_service.dart` |
| Q10 grep 无匹配 | 返回**实际扫描清单**与生效的排除目录，区分"真没有"与"被排除" | `tree_local_exec` 的 `GrepOutcome` |
| Q11 站点体系 | 四类站点 / 17 个点位 / 收集站申报工具 | §9、[plugin-development.md](plugin-development.md) |
| Q12 插件布局 | 前端与协议先行、核心侧接线；插件面板 / 编辑器 / UI 槽位 | `lib/ui/widgets/plugin_*`、`plugin/plugin_ui_bridge.dart` |
| Q13 token rate 管道 | 思考 / 正文 / 工具参数**共用同一条节拍器**，速率现读设置 | `agent/conversation_service.dart` 的 `TokenPacer` |
