# 归档文档

这里放**不再更新、但值得留证**的历史文档：它们记录的是**服务端线（`main` 分支：Flutter 前端 + Python
FastAPI 后端）**或更早的实现形态。桌面线（本分支）从零重写核心，这些结论**多数已被推翻或已融合进**
[architecture.md](../architecture.md)（含 §14 "M9 语义决策速查"）/ [team.md](../team.md) /
[development.md](../development.md) / [known-issues.md](../known-issues.md)。

> 阅读原则：把它们当**历史资料**，不要当口径。和现行文档冲突时，一律以现行文档为准。

| 文档 | 时代 / 内容 | 为什么归档 |
| --- | --- | --- |
| [m9-plan.md](m9-plan.md) | M9 阶段 14 项修复与优化的**完整实施记录**（含全局规约、逐项定稿、站点体系、插件布局、分工与波次、验收基线、事故与教训） | 已落地：口径整合进 [architecture.md §14](../architecture.md)、测试基线进 [development.md §6](../development.md)、事故教训进 [CONTRIBUTING.md §7](../../CONTRIBUTING.md)；原文保留波次与提交溯源 |
| [design_review.md](design_review.md) | 服务端线"8 大项改造"的架构评审意见（2026-08-22，评审对象是 Python `server/`） | 被评审的代码（`server/`）已删除；结论中仍然有效的部分（会话隔离、取消机制边界、上下文压缩）已落到桌面线实现与 [architecture.md](../architecture.md) |
| [plan.md](plan.md) | 同一改造的侦察与实施方案（服务端线） | 同上；其中的代码地图是 `server/` 的 |
| [test_report.md](test_report.md) | 同一改造的测试与验证报告（pytest + 旧 Flutter 3.7.12） | 工具链与测试对象都已更换，现行测试矩阵见 [../development.md](../development.md) |
| [ssh_mode_design.md](ssh_mode_design.md) | SSH 运行模式的最初设计：**连接由前端发起**、后端只持有配置 | 现在 **SSH 连接由核心建立**（`tree_local_exec` 的 `SshWorkspaceIO` + 心跳判活）；现行口径见 [architecture.md §6](../architecture.md) 与 [team.md §3](../team.md) |
| [team_tool_diagnosis.md](team_tool_diagnosis.md) | team 工具的可用性诊断（参考实现 + Docker 容器时代） | 其中"成员各自 `workspaces/{member_id}`、`.self` 天然独立"的结论**已被推翻**：现行口径是成员与 leader **共享工作目录**、私有状态按 agent 分栏（[team.md §3](../team.md)） |
| [team_tool_refactor.md](team_tool_refactor.md) | team 工具拆分（roster / 派活 / 等待）的实施记录 | 拆分早已完成并演进（`team` 工具 + `message` 工具），代码是唯一口径 |
| [team_structure.md](team_structure.md) | 某次运行由 agent 写出的团队编制清单 | 运行期产物，不是设计文档 |

归档不删的理由：这些文档里保留着**判断过程**（当时核实了哪些代码事实、哪条假设是错的），
对后来人理解"为什么现在是这样"仍有价值；但它们的引用路径已失效，所以不放进 `docs/` 顶层索引。
