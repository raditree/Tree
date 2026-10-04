# Changelog

记录本仓库**桌面线**（单机核心进程形态）的变更，自首个开源版本 **1.0.0** 起。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/)；版本号与 `pubspec.yaml` 的 `version:` 一致
（有测试钉住两处不漂移）。

> **历史**：1.0.0 之前是闭源迭代期，且是另一条形态（服务端线：Flutter + Python FastAPI）。
> 桌面线把后端逻辑整体迁入本机核心进程、从零重写，历史条目与新代码不逐条对应，因此不再保留；
> 需要溯源请看 git 历史与 [docs/archive/](docs/archive/README.md)。

> **条目口径（只记断言）**：条目只写**新增或修改的断言**——即各模块 `README.md` 的
> 「不变量（assertions）」条款（包级 README 同样算：`tree_local_exec` / `tree_protocol` …），
> 每条给出断言原文与出处文件。**实现细节、重构、修 bug 若没有改动任何断言，就不写 CHANGELOG**
> ——溯源看 git 历史。理由：断言是"行为契约"的最小可验证单位，功能流水账既读不完、也对不上代码。
> 下面的 `### Added` / `Changed` / `Fixed` / `Docs` 是**首个版本（从零重写）的总览**：
> 断言上百条无法逐条列举，保留总览形态，不再往里加条目。

## [1.0.2+1] — 2026-10-04

### 断言变化（新增 / 修改的 README 不变量）

- **`terminal` 的 `hook=true` 在本机与远端（SSH）是同一套语义，且远端任务跨重启接续**（新增
  [tree_local_exec/README.md](packages/tree_local_exec/README.md) 不变量 16、
  [tool/README.md](packages/tree_core/lib/src/tool/README.md) 不变量 8，**用户要求 2026-10-04**：
  「`hook=true` 那条路看不到我远端工作空间的文件……你应该修好它」；现场事故见
  [docs/known-issues.md](docs/known-issues.md) #22）：
  后台执行由新的 `BackgroundExecHost` 原语承担（本机 = 脚本 + shell 重定向直写日志、进程句柄在手；
  远端 = `nohup` 起在**远端**、日志落**远端工作空间**、退出码写哨兵文件 + **3s** 轮询，含"进程消失没留哨兵"
  的可辨退出码），日志读写一律经它 ⇒ 远端的 `read` 与 `hook_action=status` 看到的是**同一份**；
  **远端任务落盘台账**（`<数据根>/hooks/<task_id>.json`，原子写）：核心/应用**重启后接续**——启动即探一次哨兵，
  已结束就立刻把完成提示**投递回原会话**（台账里的 agent + 会话），未结束就重挂轮询；agent / 会话已不存在
  则**如实记日志、台账保留**，不假装投递成功；关停语义两端不同且如实（本机杀进程树，**远端不杀**）。
- **右栏「正在执行的 tool」每行标注来源（agent · 会话）且点得动**（新增 [lib/README.md](lib/README.md) 不变量 23、
  [lib/ui/widgets/tool_runs_panel.dart](lib/ui/widgets/tool_runs_panel.dart)、
  [lib/ui/pages/main_page.dart](lib/ui/pages/main_page.dart) 的 `_handleNavigateToToolRun`，**用户要求 2026-10-04**：
  「右侧面板上正在执行的工具要加上来源（定位到 agent/session）」）：点整行切中栏到该运行所属的 agent / 会话
  （**只切上下文、不滚动到某条消息**，与「问题回复」页的定位是同一范式）；agent 名与会话标题取不到时
  **回退显示 id**（`session_default` → 「默认会话」），名字接口挂了不影响列表与关闭；未接定位回调或该行没有
  agent id ⇒ **整行不可点**（不假装能跳）。后台 hook 与普通工具运行共用同一条来源字段。
- **后台 hook 出现在右栏「正在执行的 tool」，用户可关**（[tool/README.md](packages/tree_core/lib/src/tool/README.md)
  不变量 8、[tool_run_registry.dart](packages/tree_core/lib/src/tool/tool_run_registry.dart)）：
  登记进运行中工具表（`watchdog: false` ⇒ 长任务**不判超时、不刷 warning**；`crossCall: true` ⇒ 跨工具调用存活），
  用户点关闭 = 取消该 hook（本机真杀进程树；远端尽力 `kill`，拿不到 pid **如实回原因**）——
  与右栏按钮 / 执行站 `tool.close` / agent 的 `tool_runs` 仍是**同一个实现**。**不做**"两个新站点 + leader 可杀"（暂缓）。
- **「本轮调用列表」展开后"最近一次在最上面"，且整块有界可滚**（修改 [lib/README.md](lib/README.md)
  不变量 20，新增 ⑤；[lib/ui/widgets/usage_calls_panel.dart](lib/ui/widgets/usage_calls_panel.dart)、
  [test/usage_calls_panel_test.dart](test/usage_calls_panel_test.dart)，**用户要求 2026-10-04**：
  「展开后应该把最近一次的放顶上，最早的放底下，并支持滚动（现在 20 条直接掉到页面外了，
  最近的调用反而看不到）」）：截断口径一个字没改（`maxRows` 仍只取**最近** N 次），
  但**渲染顺序翻成新→旧**（`calls` 仍是旧→新，翻转只在渲染那一层）；展开区改为**有界高度 +
  区内滚动**（`UsageCallsPanel.maxListHeight`，缺省 240px ≈ 6 行，行数不足时按内容高度收缩，
  用自己的 `ScrollController`、不吃外层 primary）——20 条因此只让这一块自己滚，
  **不再把中栏的消息流挤出页面**。

## [1.0.2] — 2026-10-03

### 断言变化（新增 / 修改的 README 不变量）

- **临时员工起的 `terminal hook` 完成之后：提示归到会话主人、唤醒的是它自己**（[agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 17、
  [test/subagent_hook_wake_test.dart](packages/tree_core/test/subagent_hook_wake_test.dart) 强制；用户 2026-10-03 现场：子 agent 的 hook 干完没人收尾）：
  `WorkspaceToolRunner._finished` 把 `tagOf(task.agentId)` 的标记透传给 `onHookFinished`；`ConversationService.wake` 用
  `subagents.handle(agentId)?.ownerAgentId` 解析**会话主人**再取会话（临时员工没有自己的会话；旧实现拿 `sub_…` 取到 `null`
  就 `return` ⇒ 完成提示不落库、子永远不被唤醒、父在 `wait_for` / 阻塞 `subagent` 上白等）。完成提示按 `kind='notice'`
  + 它的标记落在**会话主人的会话流**（不能用 `subagent_report`：会被它自己的历史排掉），那一轮仍以**它自己**的身份跑并带
  **它自己的历史**；**hook 日志与超长结果重定向仍落在会话主人那一份**（刻意口径不变）。
- **运行中的工具与 LLM 请求是"可观测 + 可显式干预"的**（新增
  [tool/README.md](packages/tree_core/lib/src/tool/README.md) 文件表 4 行与
  [tool_run_registry.dart](packages/tree_core/lib/src/tool/tool_run_registry.dart)）：
  ① 所有工具调用走 `WorkspaceToolRunner` 的**同一登记入口**；
  ② 超过阈值（默认 **300 s**，与 `terminal` 缺省软超时同值）**每次运行只 warning 一次**——
  会话一条 `llm_hidden` + `core.log` 一行；
  ③ 广播站点位 **`system.tool.timeout`** 报"句柄 + 已执行时间 + 命令内容"；
  ④ `GET /api/tools/running` 只读快照 + `POST /api/tools/running/{handle}/close`；
  ⑤ 内置工具 **`tool_runs`**（`action=list` / `action=close`，作用域 = 自己 + 直属下级，越权拒绝）；
  ⑥ **不自动杀**：超时只 warning，关闭必须显式，且用户（右栏）/ 插件（执行站 `tool.close`）/
  agent（`tool_runs`）**走同一个实现**；句柄不跨进程重启存活（旧句柄回"已失效"）。
- **工具软超时与"转 hook"两端一致**（[tree_local_exec/README.md](packages/tree_local_exec/README.md)、
  [tool/README.md](packages/tree_core/lib/src/tool/README.md)）：
  `timeout_seconds` 在**本地与 SSH 都兑现**为软超时（到点**不杀进程**、交还句柄，
  `0`/负值 = 永不软超时）；`terminal` 到点**先返回工具结果（批收尾）+ 会话继续**，
  命令结束经回调唤醒注入；SSH 侧为第三形态 `RunningSshExec`（不杀不重跑、结束补写输出与退出码、
  链路失活如实失败）。
- **工具结果"永远拿不到"时在把关处自动修复**（[agent/README.md](packages/tree_core/lib/src/agent/README.md)、
  [tool_result_repair.dart](packages/tree_core/lib/src/agent/tool_result_repair.dart)）：
  引擎组装工具批时发现结果永远拿不到的卡 ⇒ 写回一段**如实**的失败信息（幂等、不新增消息、
  **不编造**退出码/输出/耗时）；未接线时退回老占位 `(该工具调用未完成，没有结果)`。
- **批一定会收敛，但"不切开批"与"工具执行完前不接受新消息"两条语义保留**（
  [llm/README.md](packages/tree_core/lib/src/llm/README.md)）：工具 `await` 期间按间隔**对账**——
  存储里若已有这次调用（`callId` 命中）的**真实结果**就采用它让批收尾（**绝不注入合成结果**）；
  没有就**继续等显式取消**。"沉默/等待/关闭/对账"全部落 `core.log`（引擎侧生命周期留痕）。
- **运行中的 LLM 请求也可观测、可关闭**（[tool/README.md](packages/tree_core/lib/src/tool/README.md)
  `llm_request_guard.dart`）：**连续零事件**达到阈值才登记（正常长生成不进表、不 warning）；
  被显式关闭 ⇒ 这一跳以**取消**收尾并掐掉底层订阅（HTTP/SSH 连接释放、插件收到取消通知）——
  插件挂住 / socket 挂住这条**无界**路径因此可关（此前它零日志、且"停止键"管不着）。
- **`message` 的附件支持跨机投递**（[team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 15 重写、
  [files/README.md](packages/tree_core/lib/src/files/README.md) 不变量 9 补充）：
  local↔local（本机 `File.copy`）、local↔SSH、SSH↔SSH（含跨主机，**经本机中转**）四种组合都支持；
  判据是**有效 SSH 接线**（`teamSshConfigFor`），不是 `agent.sshConfig`；单文件 ≤32 MB；
  越界路径拒绝、部分失败如实回 `files_failed`；local↔local 的行为与文案逐字不变。
- **插话只打断目标那一轮**（[agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量）：
  给主 agent 发消息**不再连带取消**它名下的临时员工（它们继续跑、完成报告照旧注入）；
  终止在途临时员工只有两条**显式**路径（用户 `stop` / 在它的视角里按停止）。

- **没有任何硬超时：限制只有两类（心跳丢失 / 软超时），且软超时之后只允许显式关闭**（
  [llm/README.md](packages/tree_core/lib/src/llm/README.md) 不变量 2 加强、
  [tree_local_exec/README.md](packages/tree_local_exec/README.md) 不变量 2 加强、
  [plugin/README.md](packages/tree_core/lib/src/plugin/README.md) 不变量 8 加强，
  **用户断言 2026-10-03**：「仍旧无任何硬超时，所有超时限制仅限于心跳丢失或软超时（超时后仅允许显式关闭）」）：
  工具侧 `exec(timeout:)` 到点**不杀进程**（转后台 / 交还句柄）；**`llm.call` 的 `timeout` 到点不再中止**
  （只留痕 + 登记成"可关闭的运行"，回包照旧送达、**结果不丢**，`0` = 永不软超时）；
  会话请求悬挂（**零事件**，插件挂住 / socket 挂住那条无界路径）同样登记进同一张表；
  **显式关闭只有一个实现**——用户右栏「正在执行的 tool」/ 插件执行站 `tool.close` /
  agent 内置工具 `tool_runs action=close` / REST，四者等价，关闭即让在途调用收敛并释放连接。
  边界情形（建连握手、vision 上传 / 取响应、`file_service` 的 `archive`/`git` 超时、启动预热预算、
  进程关停宽限、单实例握手、插件启动探测、传输层 5 次重试上限）在文档里**逐条归名**，
  不与"运行的超时"混淆。

## [1.0.1] — 2026-10-03

### 断言变化（新增 / 修改的 README 不变量）

- **临时成员下拉里看得见「是否在工作中」**（[lib/README.md](lib/README.md) 不变量 22、
  [test/subagent_view_test.dart](test/subagent_view_test.dart)，**用户 2026-10-03**：「临时成员下拉里要看得见"是否在工作中"」）：
  在跑的条目多一个**克制**的状态指示（小圆点 + 「工作中」，跟随主题色），空闲态不加噪音，**主会话那条永不显示**；
  数据源是面板已有的 `_workingSubagents`（`agent_status` 带 `subagent_id` 的子级帧分流进去的那份），以**只读**参数
  传给切换器——**不**塞回 `SubagentTranscript`（那是"过程 / 入口"的分栏），主视角的发送键 / 停止键语义不变（只认 `own_running`）。
- **插话只打断目标那一轮：发给主 agent 不影响它名下的临时员工**（[agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 13、
  [docs/team.md](docs/team.md) §4，**用户 2026-10-03 硬断言**：「发消息给主 agent，其子 agent 不受影响（和『发消息给子 agent，
  父 agent 及其他子 agent 不受影响』一致）」）：`_interruptForNewMessage` **只**标记目标 `(agentId, sessionId)` 那一轮，
  不再连带取消同一会话里它名下的临时员工——它们继续跑、完成报告照旧注入发起者；父那轮若正卡在 `subagent` / `wait_for`
  上，按"正在执行的工具跑完才收敛"把新消息排队等它返回。终止在途临时员工仍只有两条**显式**路径：用户 `stop`（按 agent，
  仍连带它名下的）与"在某个临时成员视角里按停止"（`sub_…` ⇒ 只停它自己）。
- **临时员工的入口列表落盘；运行态与停止只作用在「当前视角那个人」身上**（[lib/README.md](lib/README.md) 不变量 21/22、
  [agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 16、
  [server/README.md](packages/tree_core/lib/src/server/README.md) 不变量 15，**用户断言 2026-10-03**：
  「进入某个临时成员的选项经常会无端变化」+「临时成员的运行情况不应影响主 agent 运行情况……只有切到对应视角后才改停止按钮，
  且仅停止对应临时成员」）：① 新增只读 `GET /api/agents/{agentId}/subagents?session_id=`（`ApiPaths.agentSubagents`）：
  数据源就是那份落盘名册（`data/<agentId>/<sessionId>/subagents.json`，[store/README.md](packages/tree_core/lib/src/store/README.md) 不变量 11），
  **不含** `agent` 运行配置快照；跨会话不保留照旧（只回该会话、删会话即随之消失，不新增任何跨会话存储）。
  前端 `SubagentTranscript` 多一层名册：入口 = 名册（权威、稳定）∪ 消息流观察到的，名字与「谁召来的」名册优先；
  拉取失败**不清空**（保留上一次）；切 agent / 换会话时名册层与消息层**一起**清。
  ② `agent_status` 的加法键 `own_running` / `subagent_running`：只有**主 agent 自己**的帧带 `own_running`，
  子级帧靠 `subagent_id` 区分（不冒充主 agent）；「自己收尾了、名下临时员工还在跑」时**照样发一条**
  （`own_running: false` + `subagent_running: true`）——以前这种时刻什么都不发，主视角的停止键就一直亮着。
  ③ `stop` 传 `sub_…` ⇒ `cascade: false`：只停它自己（父 / 兄弟 / 其他成员 / 团队都不受影响），
  停止回执与补推的 `idle` 都带它自己的帧标记（前端只收它那一份「工作中」）。
- **结果永远拿不到的工具卡：引擎在把关处自动修复**（[agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 15、
  [llm/README.md](packages/tree_core/lib/src/llm/README.md) 不变量 6、[store/README.md](packages/tree_core/lib/src/store/README.md) 消息口径，
  **用户口径 2026-10-03**：「在引擎的把关处，失败时自动修复」）：历史里 `kind=tool` 且 `tool_result` 为空的卡
  = 那次调用被停止 / 异常 / 核心重启收尾（结果**永远拿不到**；正在跑的调用不在历史里，不会误伤）⇒
  引擎组装工具批时把失败信息**写回同一张卡**（幂等、不新增消息：`tool_call_id` 不能重复）并把这份失败信息
  用于本次请求；写回走注入的 `ToolResultRepair`（引擎不认识存储层），核心接到 `ConversationService.repairToolResult`：
  存储层写回 + 补一条 `tool_end` 帧（界面把那张一直"运行中"的卡填成失败）。未接线 = 老行为（只在送模型那份补一句占位）。
  顺带：`ToolRunRegistry` 的 warning / `stuck_tools` 阈值 **120 s → 300 s**（与 terminal 的缺省软超时同值——
  "warning / stuck_tools / 转后台 hook"三件事在同一秒数上一起发生）。
- **核心日志有唯一出口，且永不抛、永不阻塞**（新增
  [util/README.md](packages/tree_core/lib/src/util/README.md) 不变量 8、
  [tree_core_cli/README.md](packages/tree_core_cli/README.md) 不变量 1 补充）：
  所有 `[core:*]` 日志 = stderr（逐字不变）**加**落盘 `<数据根>/logs/core.log`
  （8 MiB × 5 轮转、行带 pid）；写文件失败只提示一次并降级为纯 stderr；关停 `flush()`。
  应用侧据此在「设置 → 核心日志」提供"查看最近 N 行 / 打开日志目录"（经握手 `data_root`）。
- **握手新增可选字段 `data_root`，且可选字段必须向后兼容**（
  [tree_protocol/README.md](packages/tree_protocol/README.md) 握手字段表 `data_root?`、不变量 4 补充）：
  为空时不写键 ⇒ 老前端零感知；缺失/脏值一律宽容读成空串、不抛。
- **逐调用用量账本（`usage.jsonl`）的契约与落账口**（新增
  [store/README.md](packages/tree_core/lib/src/store/README.md) 不变量 12）：
  一行一次 LLM 调用（`at` / `source` / `model` / `prompt_tokens` / `cached_tokens` /
  `completion_tokens` / `estimated` / `duration_ms`）；**每一跳都记**（端点不回 usage 时用本地估算并标
  `estimated`），插件接管跳记 `source=plugin`、内置压缩记 `source=compact`、执行站 `llm.call` 记
  `source=llm.call`；`cached_tokens` 缺失写 `null`（不编造 0）；**`messages.jsonl` 的 `usage` 键集逐键不变**（有断言钉住）。
  压缩的"来源 / 是否降级 / 插件为什么没接管"随一条**落库**的通知可见（刷新后仍在，手动压缩同样留痕）。
- **「本轮调用列表」必须覆盖"没有对话帧的用量"**（新增 [lib/README.md](lib/README.md) 不变量 20 ④）：
  压缩那两路（内置 `compact`、插件中转经执行站 `llm.call`）只写 `usage.jsonl`、**不发对话帧**
  ⇒ 面板除挂载读一次外，还必须在 `llm_hidden` 系统提示帧到达时（自动/手动压缩都会来）与
  离开 `compacting` 状态时**重读账本尾部**；读一次就"记牢"会让用户点了压缩却永远看到「0 次」
  （用户 2026-10-03 真机：账本里那笔 `llm.call` 360269/缓存 360192/7607/49511ms 明明在，面板显示 0）。
- **中栏消息流的补页补偿必须取"实测高度差"，不得取"滚动范围差"**（
  [lib/README.md](lib/README.md) 不变量 19 补充）：懒构建列表未到底时 `maxScrollExtent` 是外推值
  （误差 ∝ 剩余条数），用它做补偿会在补页帧产生上千像素跳变；补偿量取自视口内锚点的**实测顶边差**，
  并以"视口高 × 2"限幅兜底；补页与淘汰不同帧；视口内「占位槽 → 真消息」须预补偿。
- **插件面板的动作回传判据是 `params.event`，不是 `method`**（
  [docs/plugin-development.md](docs/plugin-development.md) §7.2 补线上形状）：
  核心发的是 `{"method":"event","params":{"event":"plugin_ui_action", …}}`；
  `activity` 槽位 = 活动栏图标 + 左栏整页；压缩中转 payload 另带**可选**键
  `usage_file` / `recent_usage`（最近 50 行逐调用用量，总线侧限幅、缺键 = "没有这条通路"、
  fail-open 绝不影响压缩）——compact 面板据此把"来源"列显示出 `builtin` / `llm.call` / `plugin`
  与每次调用的耗时、token（`cached_tokens` 缺失时留白、不编造 0）。

## [1.0.0] — 2026-10-03（首个开源版本）

### 断言变化（新增 / 修改的 README 不变量）

- **SSH 那条线怎么拿到完整记录：找本机那条线代查；`message` 的附件只在本机工作空间之间可用**
  （[team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 10 补充与 15、
  [workspace_prompt.dart](packages/tree_core/lib/src/agent/workspace_prompt.dart)、[docs/team.md](docs/team.md) §6）：
  ① 系统提示词的工作空间软约束**按模式**写明：`activity.log` **不是完整记录**（只有
  `[start]/[done]/[error]/[blocked]/[stale]` 这类生命周期行，写回时还会截断——够判断"谁在动、卡在哪"，
  不够复盘"到底做了什么"）；**SSH 那条线**（工作空间在远端）看不到本机、日志也在远端，要完整查询就用
  `message send_message` 找**工作空间在本机**的团队代查，并可请它用**自己的终端**（`scp` / `rsync` 之类）
  把**原文件推到远端**；**本机那条线**照做，并把结论或落地的远端路径回给对方。
  ② `message` 的 `files` 附件**只在本机工作空间之间可用**（⇒ **1.0.1 起已扩展为跨机投递**，
  见上方 `## [1.0.2]` 与 [team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 15）：任一侧是 SSH 就不投递、
  明确回一句"未投递"，消息本身照常送达（工具描述里的 `files` 参数同步写清这条边界，免得模型以为跨机能带附件）。
- **Tree 在"带着 RedirectionGuard"启动时会自愈重启；安装器改经 shell 启动**
  （[docs/architecture.md](docs/architecture.md) §13 不变量 11、`docs/known-issues.md` #16，
  **用户断言 2026-10-03**：「这是 known-issue 好像，上一轮修复没修好吗」）：
  Windows 11 的 RedirectionGuard（`EnforceRedirectionTrust` = 0x1）让进程**拒绝跟随"非管理员创建的"重定向点**，
  而它**沿调用链传播**（实测：`Tree.exe` → `tree_core.exe` → 集成终端里的 shell → 用户在那个 shell 里跑的命令
  全是 0x1，而 `explorer.exe` 及其派生的一切是 0x0）；**安装器是提权进程**，它在安装末尾拉起 Tree ⇒
  整棵 Tree 进程树都拒绝跟随 `windows/flutter/ephemeral/.plugin_symlinks/*` ⇒ Tree 终端里的
  `flutter build windows` 必然失败（CMake `add_subdirectory … is not an existing directory`），
  而同一个命令在用户自己开的终端里能成功——**这就是 #16 的真相**（旧结论"环境侧、代码改不了"只对了一半：
  链接是"不受信任的装入点"这半改不了，但"谁被这条策略约束"这半是我们自己的）。这条策略**清不掉**
  （`SetProcessMitigationPolicy(id, 0)` → `ERROR_ACCESS_DENIED`）、**也没有创建期开关**，所以：
  runner 启动时读一次 `GetProcessMitigationPolicy(ProcessRedirectionTrustPolicy)`，非零就**经 explorer
  重新拉起自己**（explorer 那条链实测 0x0）后退出；`--tree-rt-selfcheck` 只报状态与决定（打包自检 / 用例用，
  不起 Flutter）；重启失败或重启后仍非零 ⇒ 往 **stderr** 留一句可读的话再照常启动（不静默、不把用户挡在门外）。
  安装器里"启动 Tree"改成经 `explorer.exe`（`Filename: "explorer.exe"; Parameters: """{app}\{#AppExe}"""`），
  否则新装的实例一出生就带着这条缓解。
  终端侧的防呆也**补全并改正**了：除原来的系统措辞（`不受信任的装入点` / `untrusted mount point` /
  `无法遍历该路径`）外，**CMake 措辞**（`add_subdirectory given source … which is not an existing
  directory` **且**同时出现 `.plugin_symlinks`——单看是通用措辞，故判据是"两半同时命中"）也认；
  指引文案从"先去管理员终端 `flutter pub get`"改成"**退出 Tree 从开始菜单重开一次**（新版本启动时会自愈）
  ／先在系统终端里跑这条命令"——用户实际踩到的正是 CMake 那种措辞，而上一轮的关键字里没有它。
- **`subagent`（临时员工）的使用策略写进三处提示词资产：工具描述 / 系统提示词 / 内置 Spec**
  （[tool/README.md](packages/tree_core/lib/src/tool/README.md) 不变量 12、[docs/architecture.md](docs/architecture.md) §8.1）：
  口径统一为——**什么时候用**（边界清晰、可独立完成的子任务：多份文件的同类改动、独立检索与调研、各自可验收的
  验证；要同时推进就用 `background` 一次开几个）、**什么时候不用**（单文件小改、顺手就能干完的活、验收标准
  还说不清的事、为绕开工具/权限/上下文限制的套娃、原样转包）、**`task` 必须自包含**、**只有职责/范围一致才复用**
  `subagent_id`、**并行按文件/目录划分**（共享同一工作空间）、**套娃只用于把同一个大任务拆细**（层级有上限）、
  **与 `team` 的边界**（跨会话长期协作 / 需要正式团队流程才用 team）。落点：`SubagentTool.spec()` 的
  `description`；`defaultSystemPromptSeed` 新增「临时员工（subagent）使用策略」章
  （[system_prompt_file.dart](packages/tree_core/lib/src/agent/system_prompt_file.dart)）；内置规范 general-task（v8）/ hard-task（v8）
  新增「成员 vs 临时员工（轻量并行）」判据、team-meeting（v6）把临时员工纳入"会议不许开工"的禁止面
  （[builtin_specs.dart](packages/tree_core/lib/src/spec/builtin_specs.dart)）。注意：已有工作空间的 `.self/system_prompt.md`
  是用户文件，要拿到新种子需「重置」（[known-issues.md](docs/known-issues.md) #5）。
- **中栏的窗口坐标实时化：拇指跟手、落点到位、只缓存坐标附近**（[lib/README.md](lib/README.md) 不变量 19②③、
  `docs/known-issues.md` #19，**用户断言 2026-10-03**：「页面上滚，拇指不动」「可以拖动拇指上滑，但很怪，
  且有些部分未渲染」「松开后拇指回落到底部或顶部，但中间页面不会随其回落」与「计算当前窗口在整个历史中的坐标，
  右侧拇指位置按坐标计算，保持仅缓存该坐标附近的历史，其余均丢弃，接近再加载，注意保证用户鼠标滚动丝滑流畅」）：
  窗口坐标（`MessageWindowCoordinate`：本帧构建到的下标区间 + 全局条数）**每帧**刷新——由滚动通知与
  构建两侧驱动（滚动**不重建父组件**，早先只在 `build` 里注册一次帧后回调 ⇒ 滚动期间零上报），权威区间取自
  渲染树里 SliverList **这一趟真的布局过**的子项（`childScrollOffset != null`；被 `AutomaticKeepAlive`
  留在树里的屏外子项不算），itemBuilder 收集的区间只作兜底；**拇指直接监听坐标**（滚动只重绘拇指、
  不重建列表）；落点按坐标算（以视口第一条为锚点、占位区 88px/条）并在松手/点击后用实测落点
  **反馈校正 ≤3 次**（用户一动即放弃）；补页的缺口**在视口顶切开**（先补视口及以下、再补"整段在视口上方"
  那份走高度补偿，避免上方由占位变实把正在读的一段推走）；补页 + 淘汰**同一时刻只跑一趟**、
  视口附近已加载好时零网络零 `setState`；淘汰口径 400 → **200 条**（"仅缓存坐标附近的历史，其余均丢弃"）。
- **终端：拼音不再漏进 shell（输入法通道不许回推 `setEditingState`）；清屏键真的清屏**
  （[lib/README.md](lib/README.md) 不变量 14、`docs/known-issues.md` #20/#21，
  **用户断言 2026-10-03**：「模拟终端又出问题，且清屏键无效」）：
  ① 输入法通道**绝不回推** `setEditingState`（唯一一次是 `attach` 时把模型清空）——回推会走引擎
  `TextInputModel::SetText(text)` 的**默认参数**（`composing_range = TextRange(0)` 折叠 ⇒ `composing_ = false`），
  紧接着的 `SetComposingRange` 开头就是 `if (!composing_) return false;`，救不回来；组字态一没，
  `AddText`（只有 `composing_` 为真才"删掉组字文本再插入"）就从"替换组字区"退化成"追加" ⇒
  拼音累积后被"只补差额"当成新定字转发给 PTY（引擎源码 `af7e796e…` 坐实；同一天同一条链路的第二次踩坑）；
  ② 清屏 = **本地立刻清**（往 `VtScreen` 喂 `ESC[2J` + `ESC[3J` + `ESC[H`：清屏 + 清历史 + 游标归位，
  并复位回滚视图）**＋ 仍然把 `Ctrl+L`(`0x0c`) 送给 shell**——只发 `0x0c` 是"交给 shell 办"，
  而本机默认 shell 是 `cmd.exe`（没有 `Ctrl+L` 绑定）⇒ 按下去什么都不发生。
- **关闭按钮默认不是退出**（[lib/README.md](lib/README.md) 不变量 7、[docs/architecture.md](docs/architecture.md) §1）：
  关闭窗口改为隐藏到系统托盘，核心与在跑的任务继续；真退出只有托盘菜单与设置页两条明确路径，
  都先让核心优雅退出再销毁窗口。安全底线：托盘装不上就绝不隐藏、核心启动失败的错误页不拦关闭。
- **同一数据根只允许一个实例**（[lib/README.md](lib/README.md) 不变量 8、[docs/architecture.md](docs/architecture.md) §1）：
  UI 在拉起核心前先抢一把回环端口锁（锁键 = 数据根），第二个实例握手确认后立刻退出、并把已有实例的
  窗口叫到前面，绝不拉起第二个核心；端口被别的程序占用时照常启动（不因为撞端口把用户挡在门外）。

- **LLM 传输层有限重试**（[llm/README.md](packages/tree_core/lib/src/llm/README.md) 不变量 11）：最多 5 次重试、
  退避 `5/10/20/40/80s`（累计 155s），且**只在这一次尝试一个事件都还没交给上层时**重试——半路断流（已有增量）不重试，
  4xx / 流中 error 帧 / 取消 / 传输层已关闭不重试，退避等待可取消；**每次重试前先产出 `LlmRetryNotice`**
  （落成 `llm_hidden` 的进度消息），用户不会对着两分多钟的空白猜是不是卡死了；**总结器走同一条传输层**，
  它的进度经 `CompactionService.noticeSink` 落成同一种消息。
- **`llm_hidden`：用户看得见、模型看不见**（[llm/README.md](packages/tree_core/lib/src/llm/README.md) 不变量 12、
  [agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 3、
  [store/README.md](packages/tree_core/lib/src/store/README.md) 不变量 10）：失败 / 停止提示与**重试进度**照常落库、
  照常下发（前端当普通气泡），但引擎重建请求时**整条跳过**（压缩重试进度同理）；`kind` 保持 `text`——
  不做新 kind 的理由：`system` 会被读成 system prompt，「进不进提示词」与消息类别是两件正交的事。
- **工具批是原子的：批中途的注入不切开它**（[llm/README.md](packages/tree_core/lib/src/llm/README.md) 不变量 6）：
  一条 assistant 的 `tool_calls` 与它的**全部** tool 结果必须相邻；落在批中途的 hook 提示 / 用户插话
  一律推迟到该批结果之后——工具结果逐条落库（远端 SSH 上的慢工具尤其容易让注入卡在两条之间），
  就地发会把批切成"后半批没有 `reasoning_content`"，请求随即变成"以 tool 结果收尾、前面那条
  `tool_calls` 没有 reasoning"⇒ 端点 400。**判据是"这一轮还在飞"**：不止"批已有结果"，
  **这一跳的思考已落库、工具卡还没回来**（插话落在工具执行期间）时也要推迟——就地 flush 在
  "还没东西可发"时会清空待回传的思考，那段 CoT 丢失、紧接着的批以"没有 reasoning"收尾，同样 400。
- **会话历史懒加载 + 直达底部**（[lib/README.md](lib/README.md) 不变量 14）：历史接口加 `limit`（末尾 N 条）/
  `before`（更早的一页，游标 = 当前最老那条 id）与 `has_more`/`total`；面板一次只拉 200 条并给
  「加载更早」入口（滚到顶自动拉、前插补偿滚动位置）。**直达底部**同时修硬：懒构建列表的
  `maxScrollExtent` 是估算值，跟随模式下改为**粘底**（贴住就跟着长高走，用户一上滚立刻停手），
  且程序化跳底期间不再把滚动通知误判成"用户上滚"（长会话导入"划不到底"的真根因）。
- **用户可以直接给临时员工发消息、停它，且"停"与"错"在发起者那边区别对待**
  （[packages/tree_core/lib/src/agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 12、
  [lib/README.md](lib/README.md) 不变量 18）：界面复用 `user_message` 帧（收件人是 `sub_…`）→
  会话层 `sendToSubagent`：消息按 `role='user'` + **它的标记**落库（它自己的历史按标记取，发起者的模型
  上下文看不到它）、它正在跑就先**打断**（与主 agent 插话同一口径）、跑完把报告注入发起者会话；
  **人为中止（用户停止 / 插话）不注入结束提示**（用户自己说原因，且他往往马上又发一条让它接着干），
  **出错导致的中止照旧注入**（否则发起者以为活还在干）；
- **右下角那个圆键两态：生成中且输入为空 = 停止键**（[lib/README.md](lib/README.md) 不变量 14、
  [lib/ui/widgets/stop_button.dart](lib/ui/widgets/stop_button.dart)）：一开始打字就换回发送键（发送本身就意味着
  "中止在途那一轮并另起一轮"），标题栏不再重复放一颗停止键；成员面板输入行同一口径（可顺手暂停 teammates）。
- **Ctrl+J 终端：回滚缓冲 + 在终端里给会话发消息**（[lib/README.md](lib/README.md) 不变量 14）：
  主屏整屏滚动出去的行进历史（上限 2000 行，备用屏与滚动区域内部不进——xterm 口径），鼠标滚轮翻回去、
  滚到底自动恢复跟随，翻上去时工具条给「已回滚 N 行」胶囊；**`#TSend "一段话"` / `#TSend @<文件路径>`**
  直接在终端里给当前会话发消息（走 composer 同一个发送口），实现是**按键层拦截**：以 `#` 开头且仍是
  `#TSend` 前缀的那一行只在本地缓存，一旦不是它就把缓存**原样补发**——对 shell 与用户而言等于没拦过。
- **进临时员工视角不新开窗口**（[lib/README.md](lib/README.md) 不变量 18 ③④）：借父 agent 的窗口，只把
  **对话数据**与**上下文长度条**换成它的（`ui/services/conversation_view.dart` 的 `viewMessages` / `viewContext`
  是唯一口径），输入框锁成只读；**切换的 UI 在输入框右下、发送键左侧**（与会话切换同族的胶囊 + 下拉）；
  **进入视角后锁定会话切换**（`SessionPicker.locked`：图标变锁、点它只说原因、右键重命名/删除一并关掉）。
- **终端支持中文输入（输入法通道）**（[lib/ui/services/terminal_ime_input.dart](lib/ui/services/terminal_ime_input.dart)）：
  终端没有输入行 ⇒ 必须挂一个活着的 `TextInputClient` 才收得到 IME 组字（真机现象：终端里打不出中文）；
  组字中只交**已定字**（拼音敲到一半的 "ni" 绝不进 shell），可打印字符只从这条路来（键盘事件再取一次
  会发两遍），控制键仍走 `Focus.onKeyEvent`。
- **打包不许让图标字形静默缺失**（[tool/package_windows.dart](tool/package_windows.dart)）：构建改用
  `--no-tree-shake-icons`，并在打包后逐个人 `lib/` 里用到的 `Icons.*` 对字体 cmap，缺一个就失败并点名
  （真机现场：临时员工入口那颗按钮**画不出字形**，看着像"黑的"——发布版子集里没有 `badge_outlined`）。
- **思考模型的每条 assistant 都带 `reasoning_content` 键**（[llm/README.md](packages/tree_core/lib/src/llm/README.md) 不变量 13）：
  真端点实测（`deepseek-flash` @ `api.deepseek.com`，请求带 `tools`）：末尾 assistant（或末尾 tool 结果所属的
  那条 assistant）带 `reasoning_content: ""` 是 **200**，**整个键不给**才是 **400**
  `The reasoning_content in the thinking mode must be passed back to the API.`——端点只查**键在不在**，
  不查内容。于是"这一跳没有思考可回传"的正确表达是**空串**：模型某一跳没产出思考时（真机现场
  2026-10-03 10:10:41 契门会话，收尾正文没有思考卡、队友插话正好落在它前面）省略键会把整个会话打成 400。
  历史翻译（`LlmMessage.thinkingTurn`）与工具循环在途那一跳（`LlmSession.thinkingTurn`）**同口径**，
  字节一致才不丢前缀缓存；非思考模型（`thinking: false`）**一个键都不发**（OpenAI 系端点拒绝不认识的字段）。
- **提问的 `createdAt` 严格递增**（[agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 8）：
  `QuestionStore.add` 把提问时间抬成"全库严格递增"（与消息时间戳同一条规则，共用 `monotonicStamp`）——
  否则同一毫秒的两条在 `GET /api/questions` 的"最新的排前面"里顺序漂移（`List.sort` 不保证稳定）；
  装载旧文件只读不改，不追改用户数据。
- **grep 的三个数字各管一件事**（[tree_local_exec/README.md](packages/tree_local_exec/README.md) 不变量 7）：
  `scannedFileCount` 是计数、`scannedFilePaths` 只留 20 条抽样、`GrepQuery.maxResults`（默认 200）是命中行数上限。
- **成员与 leader 共享工作目录与 SSH、私有状态按 agent 分栏**（[team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 2/3/4）：
  成员 yaml 里的 `workspace_dir` **不生效**、`ssh:` 缺省取 TOP 的、`.self` 落在 `.tree/<agent_id>/`。
- **删 agent 有两道闸门，且删除路径与 team 工具同规则**（[server/README.md](packages/tree_core/lib/src/server/README.md) 不变量 12、
  [team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 12、[lib/README.md](lib/README.md) 不变量 9）：
  有下级成员必须显式 `?cascade=1`（否则 409 + `cascade_required`，避免留下"删不掉、停不了、广播够不着却还能干活"
  的孤儿成员），**任一相关会话正在运行也拒绝**（409 + `running`，先停止并等它空闲——`stop` 抢不动正在执行的工具，
  核心不替用户等待）；通过后按「停 → 排水 → 清提问 → 叶→根删 → 回填 `team_member_count`」执行，删完不留 `data/<id>`。
- **悬空团队指针启动自愈**（[team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 12：
  `team_repair.dart`）：上级被删的成员重挂到 TOP 且整棵子树的 `team_id`/`level` 一起平移；团队也没了就把最上层孤儿
  升为独立顶层 agent；`team_id` 悬空但父链完好按父链修正。每个被改的 `agents/<id>.yaml` 先备份 `.bak.<n>`（n 递增、
  绝不覆盖），幂等。
- **伪终端（PTY）交付原始字节、缺口如实报、句柄不留孤儿**（[tree_local_exec/README.md](packages/tree_local_exec/README.md) 不变量 8/9/10）：
  `PtySession`（`startPtySession`）提供交互式伪终端：输出是**原始字节**（不解码、不清洗 ANSI）、键盘输入、改尺寸、
  退出码，`close()` 幂等且收掉进程；Windows 走 **ConPTY**（`dart:ffi` 直调 kernel32，阻塞读放独立 isolate），
  POSIX 走系统 `script`，后端或 API 缺失一律**显式抛可读错误**（`PtyUnsupportedException`），
  **绝不静默降级**成无 TTY 的一次性 `exec`；改尺寸做不到时只记日志不抛。
- **Ctrl+J 打开集成终端（真 PTY），且与焦点无关**（[lib/README.md](lib/README.md) 不变量 14、
  [terminal/README.md](packages/tree_core/lib/src/terminal/README.md)）：输入框那块整体换成终端面板并**主动展开**
  （面板高 40%，可拖），再按一次回到输入框；终端**没有输入行**——按键逐键译成终端字节（回车 / 退格 / 方向键 /
  Ctrl+字母 / UTF-8 可打印字符），Ctrl+J 留给切换。快捷键绑在 MainPage 顶层的 `CallbackShortcuts` + 全局
  `TerminalToggleRequest` 上：**焦点在文件树 / 代码编辑器 / 详情页 / 终端自身时照样唤起**，连「没有任何主焦点」
  那种情况也冒泡得到——此前挂在输入框上的局部快捷键只在输入框有焦点时才收得到。核心开**真伪终端**
  （Windows ConPTY / POSIX `script`），输出按 **base64 原始字节**走已有的那条 WS（`terminal_open/input/resize/close` 上行，
  `terminal_ready/output/exit/error` 下行），前端用自制 VT 解析器还原成屏幕（光标定位 / SGR / 备用屏 / 宽字符）。
  **两个后端都是真 PTY**：远端（SSH）agent 走 SSH 会话通道 + `pty-req`（dartssh2），并**复用那条已建好的 SSH 连接**
  （不为终端再连一次），远端的 `terminal_ready.cwd` 是空串——远端工作目录由 `SshWorkspaceIO` 自己解决，界面显示「工作区」；
  判据是**有效 SSH**（成员跟随团队 TOP，见不变量 15）。没接线时回可读错误，**绝不**悄悄在本机给远端 agent 起一个终端；
  连接断开 / 换 agent / 关面板都会收掉 shell，不留孤儿进程。协议完备性门禁要求核心逐一显式处理四种上行帧。
- **源码模式按语言着色，且只能编辑纯文本**（[lib/README.md](lib/README.md) 不变量 12）：**不引第三方高亮包**，
  一张规则表 + 单遍扫描（关键字 / 类型 / 字符串 / 注释 / 数字 / 注解 / 函数名）；只在 ≤ 128 KB 时着色（超过退回单色，
  保证输入不卡），记号按「文本 + 配色」缓存；是否文本**看字节**（前 4 KB 有 NUL 就当二进制）。只读闸门：图片 / PDF / Office、
  **被截断的大文件**（写回等于截短文件）、含 NUL 的二进制、外部显式传入的 `readOnly`。保存一律走核心并带 `if_size` 做外部改动检测
  （不符 → 409 → 覆盖保存 / 放弃并刷新 / 取消）；自动保存只做**失焦与离开**，没有定时器（可在设置里关）。
- **分屏只做二分**（[lib/README.md](lib/README.md) 不变量 13）：左右 / 上下可切、分隔可拖、
  每格独立打开与保存、太窄降级成单窗格；换文件 / 关窗格前先 `confirmLeave()`（开着失焦保存就静默写回，关着就问一次）。
- **同一个文件的两个窗格共享一份编辑缓冲**（[lib/README.md](lib/README.md) 不变量 13、
  [known-issues #11](docs/known-issues.md)、[editor_buffer.dart](lib/ui/services/editor_buffer.dart)）：两侧共用**同一个**
  `CodeEditingController` 与同一份 `dirty` / `saving` / `loadedSize`——一边打字另一边立刻可见，任一窗格保存成功两边一起
  变成已保存、`if_size` 冲突流程不变；控制器归缓冲所有，两个窗格都关掉之后才释放。
  **这推翻了旧口径"同文件双开 ⇒ 非活动窗格强制只读"**：旧理由（两份缓冲互相覆盖）在共享一份缓冲之后不成立。
- **新增 `PUT /api/files/{workspaceId}/content`**（[files/README.md](packages/tree_core/lib/src/files/README.md) 不变量 7/8）：
  源码编辑器按完整文本保存，本机与 SSH 都走已有的工作空间 IO 抽象（UTF-8 写入、原样保留换行；既有非 UTF-8 文件沿用原代码页，
  编不回去就**显式拒绝**而不是静默转码）；`if_size` 与当前字节数不符回 409（文件已不存在也算冲突、不带 `size`），
  越界路径 / 图片 / PDF / Office / 压缩包 / 含 NUL 的二进制 / 超 `maxWriteBytes`（4 MB）一律可读 400，
  远端取不到可用工作空间 IO 时不假装成功。
- **消息流改一行式：模型消息高亮，工具 / 思考各占一行，完整内容去右栏「详情」页**
  （[lib/README.md](lib/README.md) 不变量 11）：模型消息去掉整圈边框，改成左侧主色竖条 + 极淡同色底的**高亮块**；
  工具调用压成一行「中文标签 + 关键参数（等宽）」并在行尾给增量（编辑 / 写入按行数 `+N -M`）、转圈或箭头；
  增量**只从这次调用的参数算**（`edit` 取 `old_text` / `new_text`、`write` 取 `content`，即**核心 schema 的键名**；
  对错了键就是恒 `+0 -0`），编辑工具的**结果**只有「已替换 N 处」这类话、**不带 diff**，不许解析结果文本；
  参数不全 / 不是编辑写入类工具 ⇒ 行尾**不给数字**（`+0 -0` 是假信息，宁缺勿假），行数与核心 `LineSplitter` 同口径。
  思考压成一行「思考 · 首行摘要」；悬停图标提亮 + 底色，点击在中栏选中并自动切到右栏第 5 个内置页签「详情」
  （右栏收着就先展开），在那里摊开**完整**参数与结果。选中项用 `DetailSelection` 保存快照并按 id 帧后刷新——
  跑着的工具 / 思考内容是原地变更的；切 agent 或整表重拉时清空。中栏**不再就地展开**：一轮里工具几十条，
  卡片会把时间线切散。
- **输入框改成卡片式、附件在发送前就能预览**（[lib/README.md](lib/README.md) 不变量 10）：
  附件预览在上、文本域在中，底部一行左边「+」（添加文件 / 展开输入框）、右边只有圆形发送键；
  「展开」只把文本域原位变高（Esc 收起）且不动草稿与附件；附件一律可预览——图片给缩略图、
  其它给「图标+名称+大小」卡片，点开读**本机**文件（是不是图片看扩展名、是不是文本一律看字节：
  前 4 KB 有 NUL 就当二进制），文件不在或读不到时直说原因，不显示 0 B。
- **提问 `cancel` 与"记录是否还在"解耦**（[agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 8）：
  删除 agent 会摘掉提问记录，此时 `cancel` 也必须完成在途等待的 completer——否则等答案的工具永远拿不到结果，
  那一轮不收敛、`isRunning` 永远为真、连 `stop` 都救不回来。
- **左栏列出全部 agent（含团队成员）**（[lib/README.md](lib/README.md) 不变量 6、[docs/team.md](docs/team.md) §7）：
  成员也是独立 agent 文件，点开就是它自己的会话；顺序 = 顶层在前（保持接口顺序）＋ 成员紧跟各自的
  TOP，`team_id` 指向的 TOP 不在列表里时兜底列在末尾。**成员其余口径不变**：工具根 / 系统提示词 /
  文件面板仍解析到 leader 的工作目录与 SSH，插件作用域仍按 `teamScopeId` 回指团队。

- **核心启动不被外设预热拖住**（[server/README.md](packages/tree_core/lib/src/server/README.md) 不变量 13、
  [known-issues #13](docs/known-issues.md)）：MCP 首次连接（**没有超时参数**）与插件启动（**逐家串行**、每家 20s）
  **只在握手之后**预热——并行、有界（预算 3s，超预算不再等）、绝不抛（单家失败只记日志）；
  模型那一轮由 `LlmAgentEngine.awaitReady` 有界等一次预热，不会"悄悄少掉插件/MCP 工具"；
  每段往 stderr 打 `[core:boot]` 分段耗时。此前两段都排在握手**之前**，任何一家外设卡住都会让界面
  看到「核心进程未能启动（等待核心进程握手超时 25s）」。
- **成员 yaml 里的 `workspace_dir` 是"共享目录的镜像"**（[team/README.md](packages/tree_core/lib/src/team/README.md)
  不变量 13）：写进去的是**有效目录**——TOP 显式配置的，或 TOP 未配置时的默认目录；在建成员时、核心启动自愈时、
  TOP 改目录的 PATCH 之后维护（写前备份 `.bak.<n>`、幂等；TOP 自己的配置**绝不改写**）。
  它**不参与运行期解析**（仍只看 TOP 那份），只为两件事：界面显示成员实际在用的目录；
  **TOP 被删后成员升为 TOP 的无损交接**（用户断言 2026-10-03：升级后**不可以**重新选择工作目录，
  配置不能留空、按 TOP 填写）。
- **消息输入框的文本域自己不画边框**（[lib/README.md](lib/README.md) 不变量 10）：装饰必须把
  `enabledBorder` / `focusedBorder` / `disabledBorder` / `errorBorder` / `focusedErrorBorder` 一并置空
  （统一常量 [input_style.dart](lib/ui/widgets/input_style.dart)）——只写 `border: InputBorder.none` 压不住全局
  `inputDecorationTheme`（解析顺序 focusedBorder → enabledBorder → border），表现是卡片里多出主题那圈绿框；
  代码编辑器（源码视图）同一条口径。
- **「这是远端吗」的唯一判据是「有效 SSH」**（[files/README.md](packages/tree_core/lib/src/files/README.md) 不变量 9、
  [team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 3）：`teamSshConfigFor`（成员自己没有 `ssh:` 时跟随团队 TOP）
  贯穿工具层、文件面板、Git 面板与集成终端；此前文件面板只看 `agent.sshConfig`，把 SSH leader 的成员判成本机
  ——面板会拿一个远端路径去本机找目录（轻则"目录不存在"，重则读到本机同名路径），集成终端更会在本机起一个 shell。
- **运行模式与工作目录是团队级的**（[lib/README.md](lib/README.md) 不变量 15）：中栏左上角按**团队 TOP** 合成
  ——成员自己显式配的 SSH 优先、否则跟随 TOP；目录只认 TOP 那份（TOP 未配置时退回成员自己的镜像，
  因此永远显示真实目录而不是「选择目录」）；选目录**写入 TOP** 并提示"团队成员共用"；
  TOP 是 SSH 时成员**切不回本地**（核心没有"成员覆盖成 local"这个概念），界面如实拒绝并说明去哪改。
- **源码视图左侧有行号槽，且软换行感知**（[lib/README.md](lib/README.md) 不变量 12、
  [code_gutter_layout.dart](lib/ui/services/code_gutter_layout.dart)、[file_viewer.dart](lib/ui/widgets/file_viewer.dart)、
  [file_editor_test.dart](test/file_editor_test.dart)）：源码模式的**可编辑与只读两条分支**都画行号
  （图片 / PDF / Office 与 Markdown / SVG **预览**没有）；一条逻辑行软换行成多个视觉行时**只给首行编号**
  （续行不画数字），行号与正文必须用**同一套度量**——同一 TextStyle、同一 textScaler、同一内容宽度
  （窗格宽 − 槽宽 − 正文 contentPadding 左右 − 光标留白），否则折行点不同、从折行处开始数字整体错位；
  行号槽跟着正文**同一条滚动控制器**平移（不挂第二个 Scrollable）、把正文顶部 contentPadding 算进偏移；
  布局只在文本 / 可用宽度变化时重算，数字不参与命中与选择。
- **右栏文件面板是 VS Code 型资源管理器**（[lib/README.md](lib/README.md) 不变量 16，用户 2026-10-03：
  「现在太简陋了，对标 VS Code」）：① **口径变化（不是漏改）**：旧的「单层列表 + 面包屑进子目录」换成
  **惰性加载的嵌套树**（展开时才拉那一层）——面包屑取消，头部显示「根目录 + 同步作用域」，**同步作用域改由选中项推导**
  （选中目录 = 它自己，选中文件 = 其父目录），**展开状态跨刷新保持**（工具写文件、上传、切执行模式重拉之后不塌）；
  ② **行只有名字 + 类型图标**（行高 22 / 字号 13，行内左右 padding 6）：大小与修改时间两列**下到悬停 tooltip**
  （目录给「N 项 · 时间」，没加载过子项时只给时间、**不编数字**），超长名 `ellipsis`、tooltip 第一行永远是全名；
  ③ 图标与颜色是纯函数 `fileTreeVisualFor`（路径 / 是否目录 / 是否展开），**色板写死不跟主题色**（跟主色走整棵树会变成
  一坨同色），源码家族取自 `code_highlight` 的 `languageForPath`（不抄第二张扩展名表）；④ 箭头只在目录上（另有等宽空槽
  保证同级对齐）+ 每层 1px 缩进引导线 + 整行悬停 / 选中（左侧 2px 主色条）+ ↑/↓/←/→/Enter/F2/Delete 键盘导航；
  ⑤ **git 状态染色**：`GET .../git-status` **只拉一次**缓存在面板状态，整行名字染色 + 行尾 M/U/A/D/R/I
  （VS Code gitDecoration 口径，被忽略更淡），**目录聚合子项状态**（删除 > 修改 > 未跟踪 > 新增 > 重命名 > 忽略）；
  `is_repo=false` / 端点还没有 / 断网**一律静默不着色**（状态色是锦上添花，不能把它变成错误页），增删改后失效重拉；
  ⑥ **新建 / 重命名 / 删除**：名字校验（空 / 路径分隔符 / 非法字符 / Windows 保留名 / 同名）**前端先挡一道**，
  且创建前**重新列一次目录**复查——核心的写文本端点**没有「仅新建」语义**，重名会被静默覆盖；重名给**行内红字**，
  删除要确认（目录**显式** `recursive=1` 并在确认框里写明「里面的内容会一起删除」），**工作空间根永远不许删**（前后端各一道）；
  超大目录被核心截断时给一行「仅显示前 N 项」（`getFilesWithMeta` 保留 `truncated`，旧的 `getFiles` 会丢掉它）；
  ⑦ **树与查看器同屏（上下分栏）**：覆盖层口径**已被推翻**——它会让「打开文件后新建 / 改名 / 删除」根本点不到，
  `onPathRenamed` / `onPathDeleted` 接线也永远点不到；改成上下分栏（比例默认 0.4 且**记在面板状态**里），
  **没打开文件时树独占**（不留空分栏）；可用高度 < 200px 降级成**只显示查看器**；开 / 关查看器时文件子 Tab 区用
  `GlobalKey` **搬**进 / 搬出分栏而不是重建（展开状态、选中项、已加载的目录都不丢）。
- **文件面板的增删改与 git 状态端点**（[files/README.md](packages/tree_core/lib/src/files/README.md) 不变量 10/11、
  [tree_local_exec/README.md](packages/tree_local_exec/README.md) 不变量 12/13）：新增 `POST .../mkdir`、`POST .../rename`、
  `DELETE ...?path=[&recursive=1]`、`GET .../git-status`（路径常量取自协议包 `ApiPaths`，不写字面量）。结构改动
  **只走工作空间 IO 抽象**（本机 `LocalWorkspaceIO`、远端 SFTP 的 `mkdir` / `rename` / `remove`，**不起 shell**，
  因此没有引号 / 转义 / 远端有没有 coreutils 这些问题），三条硬口径：**绝不覆盖**（重命名目标已存在 → 409；SFTP 的
  `posix-rename@openssh.com` 本身就是覆盖语义，所以两端都先自检）、**绝不自动建父目录**（父目录不存在 → 400，
  静默建目录会把写错的路径变成「成功」）、**永远拒绝删工作空间根**（`path` 空 / `.` / `a/..` 归一化成根 → 400）；
  非空目录默认拒绝（409 + 可读原因里说明要带 `recursive=1`），远端后端没接线 → 可读 400，**绝不落到本机**。
  git 状态与 git 日志**共用** `GitOutput.statusArgs` / `parseStatus`（`--porcelain=v1 -z`，空格 / 中文 / 引号路径、
  重命名、暂存与工作区混合、未跟踪、被忽略、非法输入都有单测；条目上限 2000，超出即 `truncated: true`）；
  两侧都**不抛异常**：不是仓库 ⇒ `is_repo: false` + 空列表（面板空态，**不是** 400）。
- **成员面板列的是「自己的下属」，且根卡片如实标注**（[team/README.md](packages/tree_core/lib/src/team/README.md)
  不变量 14、[lib/ui/services/teammates_view.dart](lib/ui/services/teammates_view.dart)，**用户断言 2026-10-03**：
  「凌川的成员里有凌川」）：`GET /api/agents/{id}/teammates` 的名单改成**以该 agent 为根的下属子树**——
  TOP 仍是整队（取值与顺序照旧），成员的子树通常为空；**绝不把自己 / 自己的兄弟 / 自己的上级列成「它的成员」**，
  `pending_member_count` 只数这份名单。以前一律取 `members(teamIdOf(id))`，而成员 `team_id` 回指团队 ⇒
  整队（含它自己）都成了「它的成员」，根卡片还硬写着「Level 0 · 团队负责人」。响应体新增 `self` 描述符
  （`level` / `is_member` / `top_agent_name`……），界面据此显示「Level N 成员 · 隶属「TOP」」；前端再
  **滤掉自己**一道（旧核心 / 中间态兜底），拿不到描述符时用 `agent.teamId` 兜底，**不编「我是负责人」**。

- **临时员工（`subagent`）工具：会话内的「临时员工」**（[store/README.md](packages/tree_core/lib/src/store/README.md) 不变量 11、
  [tool/README.md](packages/tree_core/lib/src/tool/README.md) 不变量 11、
  [agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 10/11/12、
  [tree_core_cli/README.md](packages/tree_core_cli/README.md) 不变量 6、[tree_core/README.md](packages/tree_core/README.md)「临时员工给前端用的字段」；
  **用户断言 2026-10-04**）：模型可以现场召一个**临时员工**干活——召之即来、干完还在（同一会话内可复用）、可再派发
  （层级上限 3，超限给可读错误）。与 `team` 的本质区别是**它只活在会话里**：记录落在
  `data/<agentId>/<sessionId>/subagents.json`，不写 `agents/<id>.yaml`、不进 `agents()` / `teams()` / `members()`、
  不可被 `message` 寻址、不计 `team_member_count`；**删会话或删 agent 即随之消失**，且**跨会话一律不保留**
  （换会话查不到、拿别的会话的 id 复用给可读错误——不静默新建、也不错误命中同名条目）。它**继承发起者**：
  同一份工作空间根（私有状态归会话主人，工作空间里不留 `sub_*` 目录）、同一个**有效 SSH**、同一个模型与成员级覆盖；
  工具集继承读写/命令/搜索/待办/提问/规范/MCP/插件，但**没有** `team` / `message`（不能被派活、不能建队），
  而**保留 `subagent`**（允许把同一个大任务拆细）。
  它与其它工具**同权、同三站**，不开后门：走 `WorkspaceToolRunner._execute → BuiltinTools.run` 这条唯一入口，
  中转站 `system.relay.tool.pre/post` 能改它的参数与结果、广播站 `system.broadcast.tool.pre/post` 各发一条、
  执行站命令 `tool.call` 能调它（与模型调用同一路径、同一权限），`needsWorkspace('subagent')` 显式为 false。
  消息与帧都带 `subagent_id / subagent_name / subagent_parent_id / subagent_level`（`agent_id` 仍是会话主人，
  既有过滤口径不变），而父 agent 的**模型上下文**刻意排掉带标记的消息（工具批必须原子，否则带 tools 的思考模式
  端点 400）——只有后台完成报告（`kind = subagent_report`）既带标记、又进发起者上下文（否则「干完了却没人知道」）。
  运行键 = `(subagentId, sessionId)`：与「正阻塞等它的父那一轮」绝不撞键（撞了就是死锁），N 个后台临时员工各占各的槽位
  并行跑、逐个完成逐个注入（**不做**「只留最后一个」的单槽位）；`stop` 与新消息插话会连带停掉同一会话里正在跑的
  临时员工，否则父那轮会一直卡在等一个没人管的子任务上。
- **临时员工的消息与工具行在中栏打标，不冒充主 agent**（[lib/README.md](lib/README.md) 不变量 11）：核心把临时员工
  的一切都写进**会话主人**的消息流（`agent_id` 仍是主人，既有帧过滤口径不动），前端按 `subagent_id` /
  `subagent_name` / `subagent_level` 在**这一段开头**画一条「临时员工「名」 · 层级 N」标记（同一个人的连续消息与
  工具只在第一行顶一次，换人重新标）；`subagent` 工具卡片是普通工具卡片（中文标签「临时员工」，行正文给 `task`，
  复用与后台在行里带出来）。按 `subagent_id` 分组 / 按 `subagent_parent_id` 树形展示是后续渲染——字段已经全在
  帧与历史接口里。
- **待处理成员红点接上真实计数**（[team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 14、
  [docs/team.md](docs/team.md) §7）：`GET /api/agents` 的 `pending_member_count` 此前**从不被赋值**（恒 0），
  而 `docs/team.md` 写着「未就绪成员会在 leader 上显示红点」——左栏那排红点与角标因此**永远不亮**。
  现在按**与成员面板同一个名册口径**数：TOP 数整队、成员只数自己那棵子树里未分配模型 / 待审核的成员
  （成员不把整队的待办算在自己头上）；面板与徽章由同一个 `_rosterOf` 决定，不会出现「面板空、红点亮」。
- **文件面板三改：目录在左（可收起）+ 图标改成中性跟主题走**（[lib/README.md](lib/README.md) 不变量 16③/⑧，
  **用户断言 2026-10-04**：「文件查看器塞在目录下限制了大小，把目录放左边（允许折叠）」「文件为什么是这种橙色，
  改成图二的样式」）：① **布局从上下改回左右，上次的理由一并推翻**——上下分栏把查看器压扁（代码是按行看的，
  高度比宽度更吃紧），改成**左栏目录 / 右栏查看器**（比例默认 0.3、可拖、记在面板状态）；查看器工具条新增箭头键
  切换「目录收起 / 显示」，收起后查看器占满整格；**意愿与"这一刻能不能显示"分开**——可用宽度 < 400px 时降级成
  **只显示查看器**并在工具条上如实写出原因，拖宽右栏目录自己回来。② **图标改成中性单色**
  （`fileTreeIconColor(scheme) = onSurfaceVariant`）：目录收起 / 展开都是描边文件夹（状态交给左侧箭头），各类型靠
  **形状**区分——**推翻旧的「写死色板、不跟主题色」**（那正是用户看到的"这种橙色"），颜色只留给 git 状态
  （名字染色 + 行尾字母，口径不变）。③ 顺手修掉两处窄栏位溢出：目录头部标题走 `Flexible` + 省略号，查看器头部按
  宽度把预览切换 / 复制 / 下载收进「更多」菜单（动作键统一 28px 紧凑尺寸）。
- **首次使用的八步新手引导（处处可跳过）**（[lib/README.md](lib/README.md) 不变量 17，**用户断言 2026-10-04**）：
  顺序 = 用户定稿的 模型配置（设置页）→ 创建 agent → 配置模型信息 → 配置工作目录 → 启用插件 → 文件浏览 →
  Ctrl+J → demo 输入（「创建一名成员，负责插件开发」）。浮层**非模态**（每一步的「带我过去」要打开真实界面，
  模态会挡住它们）：设置页模型一节 / 建 agent 对话框 / 右栏「模型信息」·「文件」页 / 插件面板 / 集成终端 /
  工作目录选择器；除最后一步外只做导航，最后一步把 demo 那句话**填进输入框、不自动发送**。
  「下一步（跳过这步）」与「跳过引导」都能收工，都记进 SharedPreferences（UI 级偏好 `tree.onboarding.v1`）⇒
  之后不再自动弹；设置页新增「新手引导」卡片可**重新显示**。跨面板动作走全局广播（`ComposerPrefillRequest` /
  `WorkspacePickRequest`，与 `TerminalToggleRequest` 同一范式），右栏页签用「索引 + 请求序号」表达。

- **「全部折叠」不再「点了没反应」**（[lib/README.md](lib/README.md) 不变量 16⑤，**用户 2026-10-04**：
  「这个全部折叠点击为啥没反应」）：那一刻树本来就是全收着的，于是点了个"合法但看不见效果"的按钮。
  现在**没有展开项时这颗键置灰**（tooltip 明说「没有展开的目录（都收着呢）」，右键菜单里同一口径），
  真收了就**滚回顶部**（VS Code 同款）——每次点击都有可见反馈；顺带补一条回归测试：展开两层嵌套目录后
  点它，子行全部消失、箭头回到收起方向。

- **详情页的「变更」一段：写入给内容、编辑给带上下文的 diff**（[lib/README.md](lib/README.md) 不变量 11，
  **用户断言 2026-10-04**：「写入的具体内容呢？编辑做成 diff 的输出格式（最好带少量几行上下文方便用户阅读）」）：
  `write` 摊开写进去的**内容本身**（不再只有「内容长度 15720 字符」；超 2000 行 / 128 KB 才截断并如实标注），
  `edit` 给**带上下文的变更块**——`-` 旧行 / `+` 新行 / 无前缀是上下文，上下文取自**磁盘当前内容**（按这次调用的
  `new_text` 定位后上下各 3 行），行中间的替换按**整行**标出来（不是并列贴两段碎片）；定位不到（文件之后又被改过）
  或读不到就**如实说明**并退回「查找 / 替换」参数视图——绝不把原文伪装成 diff。纯函数在
  [tool_change_view.dart](lib/ui/services/tool_change_view.dart)（可单测），读文件要工作空间 id：`DetailPanel` 从
  FilePanel 拿到 `workspaceId` / `teamId` 后透传给 `ToolDetail`。

- **详情页变更按源码渲染 + 翻历史也给 -/+ + 临时员工独立视角 + 上下文用量隔离**（[lib/README.md](lib/README.md)
  不变量 11 / 18，**用户断言 2026-10-04**）：① `write` 的内容与 `edit` 的变更块**按源码着色**（整段词法结果按行切片：
  块注释 / 多行字符串跨行不断色，见 [code_highlight_lines.dart](lib/ui/services/code_highlight_lines.dart)）；
  ② `edit` 定位不到（文件之后又被改过）时**不再什么都不给**：退回「只用调用参数」的 `-` / `+` 变更块，并如实标注
  「上下文不可得」（那份上下文当时没存下来——要带上下文地翻历史需要核心在编辑时就把它记下来，见下条待办）；
  ③ 临时员工的输出**不进中栏主消息流**，在「调用它的那次 `subagent` 工具调用的详情页」与「它自己的工作进度页」里看，
  两处共用同一份过程渲染；④ 语义对齐：它与**发出这次调用的那个 agent** 同级（**不是**与 teammates 同级），入口挂在那个
  agent 的会话头上，措辞「由「X」召来 · 第 N 层」，不复用团队的「层级」一词；⑤ **它的上下文长度不计入主 agent 的读数**
  （实时帧带 `subagent_id` 不记账、历史恢复跳过带标记消息），只在它自己的视图里显示。

- **详情页的选中可以「再点一次取消」**（[lib/README.md](lib/README.md) 不变量 11，**用户断言 2026-10-04**）：
  点工具行 / 思考行 → 右栏「详情」摊开完整内容；**再点同一条 → 取消选中**（详情页回空态）——
  省得把鼠标移到详情页去点「关闭详情」。实现是一条 `DetailSelection.toggle()`，工具行与思考行共用
  （一边能取消、一边不能会很别扭）。

- **中栏消息流是"按全局下标寻址的窗口"**（[lib/README.md](lib/README.md) 不变量 19、
  [server/README.md](packages/tree_core/lib/src/server/README.md) 不变量 14，**用户断言 2026-10-04**：
  「右侧滑块位置按全局长度算，滑到哪加载哪，限制缓存长度，仅缓存窗口附近的消息」「回到底部按钮直接重载入历史」）：
  整份会话流当**槽位表**（下标 0 = 最旧那条，`null` = 还没取回来，列表里画成等高占位槽）⇒ 表长**只随新消息增长**
  （加载 / 淘汰都不改变它），右侧滑块改成**按全局下标算几何**（原生 `Scrollbar` 跟着"已构建内容的估算范围"走，
  窗口化列表里必然乱跳）；列表把本帧构建到的下标区间帧后报给面板，面板只补那一段
  （历史接口新增 **`from=<下标>`** 与 **`at=<id>`**，任何路径都回 **`offset`** = 这一页第一条的全局下标）、
  并淘汰离视口 400 条以外的槽位（**正在流式 / 正在跑工具的消息永不淘汰**，末尾 200 条常驻）；
  **「回到底部」= 重载末尾一段**（窗口换成"末尾页 + 比它新的实时尾巴"）再直达底部，不再在几千条估算高度里做滚动动画；
  视口**上方**补页按高度差补偿滚动位置；定位目标那一页额外钉住不被淘汰；临时员工的消息按槽位渲染成**零高度**
  （不变量 18① 的口径不变：临时员工的产出仍不进主消息流）。
- **中栏右侧只有一条滑块，且拖拽"抓哪儿是哪儿"**（[lib/README.md](lib/README.md) 不变量 19③，
  **用户断言 2026-10-03**：「这个滑块乱跳（主对话框）」）：中栏消息流**必须显式关掉**桌面自动挂上的原生
  `Scrollbar`（`ScrollConfiguration.copyWith(scrollbars: false)`）——它与自绘的 `MessageScrollbar` 会落在同一条
  14px 窄带里，原生那条按"已构建内容的估算范围"画拇指，窗口化列表里必然乱跳；
  `MessageScrollbar` 的按位置反解必须是绘制几何的**严格逆**（`messageScrollbarIndexAt`），且**拖拽期间几何输入与
  拇指位置都钉住**（指针为准、松手再对齐真实下标），滑块能指到的最靠后下标是 `total - 看得见的条数`（贴底同义），
  拖到最底下 = 直达底部。
- **集成终端：输入法只补差额 + 原样回显；能选、能复制粘贴**（[lib/README.md](lib/README.md) 不变量 14，
  `docs/known-issues.md` #15，**用户断言 2026-10-03**：「中文输入下模拟终端出 bug。还有没法选中文字，没法复制粘贴」）：
  输入法通道**只补差额**（平台送来的永远是 `TextInputModel` 的整段文本；组字尾巴一个字都不发，尾巴被引擎连在
  提交结果前一起送回来也要剥掉）且**原样回显**（一个字都不改 `setEditingState`）——旧实现截断模型 + 强制折叠
  选区，会让引擎的 `AddText` 从"替换组字区"退化成"追加"，拼音原文于是漏进 shell（真机截图已实证）；
  同一链路报一次**光标那一格**（`setEditableSizeAndTransform` + `setMarkedTextRect`）供 IME 候选窗定位。
  终端新增**选中 / 复制 / 粘贴**：左键拖拽取选区（坐标是"历史 + 屏幕"拼成的绝对行号，输出与回滚都不丢锚点，
  resize 清选区）；`Ctrl+Shift+C` / `Ctrl+Insert` / **有选中时的 `Ctrl+C`**（没选中时仍是 `0x03` = SIGINT）复制；
  `Ctrl+V` / `Shift+Insert` / 右键菜单粘贴（`\n` → `\r`，应用开了 `?2004` 时包 `ESC[200~ … ESC[201~`）；
  粘贴**不过** `#TSend` 拦截层。
- **本地/远端执行环境对齐"用户自己的终端"；终端会翻译"不受信任的装入点"**
  （[tree_local_exec/README.md](packages/tree_local_exec/README.md) 不变量 14/15、[lib/README.md](lib/README.md) 不变量 14、
  `docs/known-issues.md` #16/#17/#18，**用户断言 2026-10-03**：「Tree 的 terminal 和我（用户）直接在本机使用的 terminal
  在行为上有分歧」「SSH 下也有类似情况（上次我有 nvcc，另一个 agent 没有）」）：① **本地**执行 / 本地 PTY / 后台 hook
  的环境按**登录口径重建**（机器级 `HKLM\…\Session Manager\Environment` + 用户级 `HKCU\Environment`；`Path` 机器级在前，
  其余同名用户级覆盖；`REG_EXPAND_SZ` 按合成后的表展开；**注册表没有的继承变量原样保留**；任一步失败**整体退回继承**）
  ——纯继承会让 agent 少用户配的 PATH 项、多启动方注入的项（实测连带把 shell 选成 MSIX 打包版 pwsh）；② **SSH 远端命令
  默认套登录外壳**（`bash -lc '<cmd>'` → `sh -lc` → 原样发的三级回退，一次连接只探测一次，`ssh.login_shell` 可换模板 / 写空串关掉，
  命令走 POSIX 单引号转义），因为 exec 通道是非登录 shell ⇒ agent 看不到 `nvcc` 这类 profile PATH；`resolveRemoteRoot`
  随之改用**带标记**取远端 HOME（profile 欢迎语不再污染解析）；③ 终端把操作系统那句没法照做的话翻成指引
  （`不受信任的装入点` / `untrusted mount point` ⇒ "先去管理员终端跑一次 flutter pub get，见 #16"），跨帧稳健、每会话一次。
- **终端文字输入必须带视图 id**（[lib/README.md](lib/README.md) 不变量 14、
  [docs/known-issues.md](docs/known-issues.md) #12，**用户断言 2026-10-04**：「模拟终端现在中英文都无法输入」）：
  可打印字符**只**从平台的文本输入通道来——键事件那条路对它们一律判 `ignored`（引擎在键事件被判 `handled` 时
  **就不再派发文字**，两条路天然互斥、不会重复输入），而这条连接**必须带 `viewId`**（`View.of(context).viewId`，
  与 `EditableText` 同口径）：缺了 Windows 端 `TextInput.setClient` 直接报错、平台侧 `active_model_` 一直是空的，
  键盘交出来的文字被 `TextHook` **静默丢掉** ⇒ 一个字都打不出来；`test/terminal_panel_test.dart` 钉住发给平台的配置。

### Added（首个版本总览）

- **单进程桌面形态**：Flutter 界面 + 纯 Dart 核心 `tree_core`（可编译成单文件，约 10 MB）；
  核心只监听 `127.0.0.1` 随机端口，一次性 token 经 stdout 握手下发；关窗时优雅退出，不留孤儿进程。
- **agent 团队**：leader 用 `team` 工具建成员、审核闸门（无模型 + 待审核不接活），
  `message` 工具派活 / 广播 / `wait_for` 等交付；成员与 leader **共享同一个工作目录**（同一个项目）。
- **Spec（规范）体系**：内置 general-task / hard-task / team-meeting / plugin-creator，自定义规范落工作空间；
  索引与"已选全文"进系统提示词，`spec select` 直接返回全文。
- **MCP**：stdio 与 Streamable HTTP 两种传输、懒连接、心跳判活、工具命名空间化（`mcp__<服务>__<工具>`）。
- **插件与站点体系**：进程外插件（行分隔 JSON-RPC 2.0）+ 四类站点 / 17 个点位——广播、执行（fs / terminal /
  agent / ui / llm / tool / session）、中转（工具前 / 工具后 / LLM 接管 / 请求改写 / 压缩 / 系统提示词）、收集（工具申报）；
  插件可申报 UI 槽位与自己的工具。指南见 [docs/plugin-development.md](docs/plugin-development.md)，示例见 [examples/plugins/](examples/plugins/)。
- **SSH 运行模式**：工具、文件面板、Git 面板同一套语义；**成员跟随 leader 的 SSH**（同一台远端主机、同一个根）。
- **私有状态按 agent 分栏**：`.self/…` 真实落在 `.tree/<agent_id>/.self/…`（提示词 / 规范 / 长结果 / 活动日志）；
  团队共享项目文件、各自保留私有状态；核心启动时一次性迁移旧 `.self`。
- **会话并行**：同一 agent 的不同会话**并行**运行；同一会话内串行、新消息插话打断。
- **提问回路**：`ask_user_question` 落盘 + 卡片作答 / 取消 / 重启补答；右栏「问题回复」跨会话查看。
- **可复现的打包**：一条命令出便携 zip（构建 + 编译核心 + 拷 `pdfium.dll` + 写使用说明 + **自检** + 压缩），
  可选 Inno Setup 安装包（每用户安装、卸载不动用户数据）。

- **提示词资产索引**：模型看到的每一段文字（默认系统提示词 / 拼装顺序 / 内置 Spec 模板 / 插件指南副本 / 附件片段 /
  工具描述 / 会话状态 / 压缩摘要）在 [docs/architecture.md §8.1](docs/architecture.md) 有一张「源码 ↔ 运行期落点」对照表，
  改提示词不必再 grep 全仓；同时把「**侦察从文档开始**」（README → docs 索引 → 模块 README 的不变量 →
  development / known-issues → 再进代码核对）写进系统提示词与 general-task / hard-task 的 Recon 阶段。

### Changed

- **派活与回信归集到发起会话**：`message` 默认把接收方归集到"发起这一跳的会话"，
  teammates 窗口因此能看到成员进度与回信（此前会落到成员/leader 的默认会话，界面上什么都看不到）。
- **移除「消息切入设置」**：行为固定为"同会话插话打断 / 跨会话并行"，不再有死开关。
- 超长工具结果改为**重定向到工作空间**并只给模型预览（省 token、保全文）。

### Fixed

- **前缀缓存**：重建历史改为逐字复用"实发那一份"、系统提示词按会话钉住、Spec 快照冷热形态统一
  ⇒ 长会话不再每轮 0 命中（[known-issues #6](docs/known-issues.md) / [#8](docs/known-issues.md)）。
- **本地执行不再被"等输入"挂死**：子进程禁用交互（`-NonInteractive` + 关闭 stdin）+ 裸 `echo` 兼容翻译
  （[known-issues #7](docs/known-issues.md)）。
- **团队不再"发消息后无回复"**：跨会话消息不再掐掉另一个会话在途的轮次；
  `wait_for` 之后 leader 一定能继续发言（[known-issues #9](docs/known-issues.md)）。
- **取消一切静态任务超时**：判活只认心跳 / 进程存活；远端成员失联以"显式错误 + 部分结果"收口，不静默丢消息。

### Docs

- 文档收口（面向开源）：精简入口 [README.md](README.md)；新增
  [docs/architecture.md](docs/architecture.md)（架构 + 跨模块不变量）、[docs/development.md](docs/development.md)（构建 / 测试 / 打包 / 发布）、
  [docs/team.md](docs/team.md)（团队语义）、[CONTRIBUTING.md](CONTRIBUTING.md)（开发规则约束）与
  [docs/README.md](docs/README.md)（索引）；每个模块 README 写清职责 / 入口 / **不变量** / 测试；
  服务端线时代的历史文档移入 [docs/archive/](docs/archive/README.md)。
- 新增**文档契约门禁**（`packages/tree_protocol/test/docs_contract_test.dart`）：模块 README 的不变量节、
  入口文档、docs 索引完整性都会被测试检查。
