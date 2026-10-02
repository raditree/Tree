# Changelog

记录本仓库**桌面线**（单机核心进程形态）的变更，自首个开源版本 **1.0.0** 起。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/)；版本号与 `pubspec.yaml` 的 `version:` 一致
（有测试钉住两处不漂移）。

> **历史**：1.0.0 之前是闭源迭代期，且是另一条形态（服务端线：Flutter + Python FastAPI）。
> 桌面线把后端逻辑整体迁入本机核心进程、从零重写，历史条目与新代码不逐条对应，因此不再保留；
> 需要溯源请看 git 历史与 [docs/archive/](docs/archive/README.md)。

## [1.0.0] — 未发布（首个开源版本）

### Added

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
