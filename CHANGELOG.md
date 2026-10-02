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

## [1.0.0] — 未发布（首个开源版本）

### 断言变化（新增 / 修改的 README 不变量）

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
  `tool_calls` 没有 reasoning"⇒ 端点 400。
- **提问的 `createdAt` 严格递增**（[agent/README.md](packages/tree_core/lib/src/agent/README.md) 不变量 8）：
  `QuestionStore.add` 把提问时间抬成"全库严格递增"（与消息时间戳同一条规则，共用 `monotonicStamp`）——
  否则同一毫秒的两条在 `GET /api/questions` 的"最新的排前面"里顺序漂移（`List.sort` 不保证稳定）；
  装载旧文件只读不改，不追改用户数据。
- **grep 的三个数字各管一件事**（[tree_local_exec/README.md](packages/tree_local_exec/README.md) 不变量 7）：
  `scannedFileCount` 是计数、`scannedFilePaths` 只留 20 条抽样、`GrepQuery.maxResults`（默认 200）是命中行数上限。
- **成员与 leader 共享工作目录与 SSH、私有状态按 agent 分栏**（[team/README.md](packages/tree_core/lib/src/team/README.md) 不变量 2/3/4）：
  成员 yaml 里的 `workspace_dir` **不生效**、`ssh:` 缺省取 TOP 的、`.self` 落在 `.tree/<agent_id>/`。
- **左栏列出全部 agent（含团队成员）**（[lib/README.md](lib/README.md) 不变量 6、[docs/team.md](docs/team.md) §7）：
  成员也是独立 agent 文件，点开就是它自己的会话；顺序 = 顶层在前（保持接口顺序）＋ 成员紧跟各自的
  TOP，`team_id` 指向的 TOP 不在列表里时兜底列在末尾。**成员其余口径不变**：工具根 / 系统提示词 /
  文件面板仍解析到 leader 的工作目录与 SSH，插件作用域仍按 `teamScopeId` 回指团队。

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
