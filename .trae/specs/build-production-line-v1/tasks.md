# Tasks

> 按冻结方案实施。每个任务完成后必须跑对应门控并留证据；未过门控不得勾选。
> 门控编号见 [production-line-gates.md](../../docs/pluginization/production-line-gates.md)。

## Phase 1：驱动与基线

- [x] Task 1: 修复执行驱动与产线状态（PC-1）
  - [x] SubTask 1.1: `orchestrator_service.dart` 定时 tick 认 `queued`/可推进任务，不再因无在途任务跳过
  - [x] SubTask 1.2: 任务执行结束、准备 `finalize` 后触发 tick；事件驱动与手动派发共用同一入口，保持幂等
  - [x] SubTask 1.3: 产线状态由后端投影为 `idle/working/paused`，不再由 UI 推断
  - [x] SubTask 1.4: 手动派发补依赖/并行/写域/预算/就绪门护栏；拒绝时返回结构化原因
  - [x] SubTask 1.5: 补单测覆盖上述四条；旧行为不回归
  - 验证：`dart analyze`；`dart test`（tree.production.line）；TG-01~06 相关用例

## Phase 2：L0 就绪门

- [x] Task 2: 项目结构整理硬门（PC-2D）
  - [x] SubTask 2.1: 结构报告模型与生成：包职责映射、公共 API 清单、依赖环/分层、重复、规模、文档、TODO
  - [x] SubTask 2.2: `structure.ready` 判定与 `organizing` 阶段；非 cleanup 任务返回 `409 structure_not_ready`
  - [x] SubTask 2.3: cleanup 任务类型与允许命令白名单；清理后重审
  - [x] SubTask 2.4: 逐项豁免（owner/原因/到期），无全局跳过；豁免到期失效
  - [x] SubTask 2.5: 单测覆盖结构未过/cleanup 可跑/重审放行/豁免/ready 后 stale 阻断
  - 验证：LG-01、TG-06；`dart analyze` + `dart test`

- [x] Task 3: 文档归一化预检写入与复合就绪门（PC-2C/PC-2B）
  - [x] SubTask 3.1: `production.normalize.plan/apply/rollback/status`，复用 docnorm `commit=false/true`
  - [x] SubTask 3.2: 写前 `before_sha256` + 备份/补丁；只追加/索引；rewrite 需 allowlist + 二次确认
  - [x] SubTask 3.3: 幂等、失败回滚、不自动 commit；写入期间暂停开新任务
  - [x] SubTask 3.4: 复合就绪门 LG-02~07 与 `line.ready`；未就绪统一 409
  - [x] SubTask 3.5: 单测覆盖 plan 0 写盘、apply 一致、重复 apply、回滚、越权 rewrite、路径穿越
  - 依赖：Task 2
  - 验证：LG-02~07；`dart analyze` + `dart test`（test/normalization_test.dart，191 用例全绿）

- [x] Task 4: 1 分钟理解与双查询检索（PC-2A）
  - [x] SubTask 4.1: LLM #1 输出 `requirement_summary/keywords/constraints/attachment_summaries/ambiguities`
  - [x] SubTask 4.2: 查询 A 原文 + 查询 B 关键词；两次 embed 并行、合计 ≤5s；RRF 合并去重
  - [x] SubTask 4.3: 检索阶段 10s 门控；超时 partial/recall_gap，不补第三轮
  - [x] SubTask 4.4: LLM #2 理解卡与首轮问题；结论必须带 `evidence_id`，无证据进未知
  - [x] SubTask 4.5: T+0 任务落盘、T+60s 首版卡；分段耗时 `摘要/检索/模型`
  - [x] SubTask 4.6: 单测覆盖 1 分钟 SLO、双查询、超时、证据约束
  - 依赖：Task 3
  - 验证：AG-01/02、TC-PL-C19/20

## Phase 3：任务与计划

- [x] Task 5: 任务输入、REST 与文档边界（PC-3/PC-3C）
  - [x] SubTask 5.1: `brief/acceptance/references/attachments/task_type/gate/conflicts_with/serial_group` 进入任务模型，旧任务默认兼容
  - [x] SubTask 5.2: 补齐任务 REST：创建/编辑/附件登记/批量派发/队列计划；统一 409 错误
  - [x] SubTask 5.3: 编辑预检：缺内容/验收、依赖未满足、写域交叠、并行满、契约/附件哈希不一致
  - [x] SubTask 5.4: 项目文档默认只读；文档任务显式、写域只含文档、与同文档代码任务串行
  - [x] SubTask 5.5: 单测覆盖旧任务兼容、REST、预检、越界写 docs 被拒
  - 依赖：Task 4
  - 验证：TG-01、TG-07、AG-05

- [x] Task 6: 附件与记忆端口（PC-3A/3B/3D/PC-9）
  - [x] SubTask 6.1: 附件落 `.input/.../attachments/`，登记 sha256/size/type；不写项目资产、不 base64 入包
  - [x] SubTask 6.2: 图片边界：像素上限、EXIF/GPS、动图首帧、透明、损坏、重复、超量、SVG 禁脚本
  - [x] SubTask 6.3: 视觉模型可总结图片；非视觉模型标 `image_manual_reference`；PDF/Office 只存不读
  - [x] SubTask 6.4: `tree.agent` 提供 `agent.memory.get/record`；产线只经 MemoryPort 调用，不存记忆正文
  - [x] SubTask 6.5: 记忆不可用降级 `memory_unavailable`；任务继续
  - [x] SubTask 6.6: 单测覆盖附件边界、视觉/非视觉、记忆读取/回写/降级
  - 依赖：Task 5
  - 验证：AG-06、TC-PL-C24、TC-PL-C18；`dart analyze` + `dart test`（241 用例全绿）

- [x] Task 7: 任务拆分器（PC-3E）
  - [x] SubTask 7.1: 扩展任务字段与解析；`task_type` 含 `code/test/docs/spike/integration/chore/cleanup`
  - [x] SubTask 7.2: DAG 校验：环、跨计划依赖、写域交叠、尺寸、任务门控、集成任务
  - [x] SubTask 7.3: 确定性修正：超限拆分、微任务合并、交叠串行、去伪依赖
  - [x] SubTask 7.4: 批次计算（硬依赖 + 写域不相交 + max_parallel）
  - [x] SubTask 7.5: 计划版本 `plan-vN`；改计划生成新版本
  - [x] SubTask 7.6: 单测覆盖 PG-03~07 与版本
  - 依赖：Task 5
  - 验证：PG-03~07、TC-PL-C27；`dart analyze` + `dart test`（259 用例全绿）

- [x] Task 8: 计划多轮迭代与漂移门（PC-3F）
  - [x] SubTask 8.1: 计划 7 块模型与落盘：设计/不变量/任务/出口门禁/追踪矩阵/风险/变更控制
  - [x] SubTask 8.2: `REQ-xx` 逐条追踪；断链阻断落档
  - [x] SubTask 8.3: 起草→独立批判→修正循环，最多 3 轮；findings 分级与未解决项可见
  - [x] SubTask 8.4: `- [ ]` 门禁清单解析为机器证据；无 evidence 不得 done
  - [x] SubTask 8.5: 漂移哨兵 BG-01~08；fail 停止下一批
  - [x] SubTask 8.6: 变更单 `DEC-xx` 与 plan 版本；越权契约变更阻断
  - [x] SubTask 8.7: 单测覆盖 PG-00~10、BG-01~08
  - 依赖：Task 7
  - 验证：TC-PL-C28、AG-09；`dart analyze` + `dart test`（289 用例全绿）

## Phase 4：UI 与事件

- [x] Task 9: 就绪/结构/归一化 UI 与事件流（PC-4/PC-5B/PC-5C/PC-5F）
  - [x] SubTask 9.1: `broadcast.task_state` 事件（单调 seq + 快照水位 + 3s 轮询兜底）
  - [x] SubTask 9.2: 产线头状态、就绪清单、409 文案与禁用
  - [x] SubTask 9.3: 结构整理页：包职责/API/依赖环/重复/规模/文档、cleanup 入口、逐项豁免、重审
  - [x] SubTask 9.4: 归一化预览页：diff、rewrite 二次确认、apply/取消、进度/回滚
  - [x] SubTask 9.5: UI 单测 + `flutter analyze`
  - 依赖：Task 4、Task 8
  - 验证：LG-01~07 UI、TC-PL-C29；`dart test` 296 / `flutter test` 全绿、`flutter analyze` 0

- [x] Task 10: 工作台、计划审查与右栏任务详情（PC-5/5A/5D/5E/6/7）
  - [x] SubTask 10.1: 今日/准备/执行/工具四入口；今日只显示待决定/需处理/正在跑/刚完成
  - [x] SubTask 10.2: 准备四步；未答问题禁止落档；理解卡含证据、覆盖、partial/degraded/stale
  - [x] SubTask 10.3: 计划审查：7 块、findings、追踪断链、`- [ ]` 门禁、批次、拆分/合并、plan diff
  - [x] SubTask 10.4: 右栏 `productionTask` 详情：概览/计划/打包/门控/消息专家/台账；证据可跳转
  - [x] SubTask 10.5: 任务编辑/附件上传/批量派发 UI；门控未过禁用完成
  - [x] SubTask 10.6: UI 单测 + `flutter analyze`
  - 依赖：Task 9
  - 验证：PS-1~19 相关 UI、AG-03/08/09/10

## Phase 5：稳定性与验收

- [x] Task 11: 稳定性控制面（PC-10）
  - [x] SubTask 11.1: 租约 + fencing token；旧 worker 写入拒绝
  - [x] SubTask 11.2: 幂等命令/两阶段提交；重复派发只执行一次
  - [x] SubTask 11.3: 事件日志 + 投影 + 对账；崩溃/断网/部分写恢复不丢不重
  - [x] SubTask 11.4: 独立门控 runner；执行者不能写 `gate.json`/证据；篡改拒绝
  - [x] SubTask 11.5: 换模型黄金任务；恢复/blocked/retry SLO 指标
  - [x] SubTask 11.6: 故障注入测试与脚本
  - 依赖：Task 1、Task 8
  - 验证：SG-01~06、TC-PL-C26；`dart analyze` 0、`dart test` 307 全绿

- [ ] Task 12: 真模型 E2E 与文档收口（PC-8）
  - [x] SubTask 12.1: 全链路：结构整理 → 归一化 → 索引 → 准备 → 理解 → 计划 → 打包 → 执行 → 决策 → done
  - [x] SubTask 12.2: 异常五路径：缺内容/依赖阻塞/门控失败/漂移/恢复
  - [ ] SubTask 12.3: 真模型一次通过；截图/台账/门控证据（需本机模型池与密钥；确定性 E2E 已覆盖全链路，真机脚本见 `tool/e2e_real_model.md`）
  - [x] SubTask 12.4: 插件 analyze 0 + 全量测试 + 自检；UI 全量测试；docs_contract
  - [x] SubTask 12.5: 更新提示词索引/工作日志/已知问题
  - 依赖：Task 1~11
  - 验证：AG-01~11、TC-PL-C15；`dart test` 317 / 自检 123/0 / `flutter test` 1011 / docs_contract 7/7

# Task Dependencies

- Task 1 无依赖
- Task 2 依赖 Task 1
- Task 3 依赖 Task 2
- Task 4 依赖 Task 3
- Task 5 依赖 Task 4
- Task 6 依赖 Task 5
- Task 7 依赖 Task 5
- Task 8 依赖 Task 7
- Task 9 依赖 Task 4、Task 8
- Task 10 依赖 Task 9
- Task 11 依赖 Task 1、Task 8
- Task 12 依赖 Task 1~11
