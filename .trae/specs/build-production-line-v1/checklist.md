# Checklist

## 方案与门控一致性

- [ ] 实施范围与 [production-line-product-form.md](../../docs/pluginization/production-line-product-form.md) 冻结方案一致
- [ ] 每个新增/修改门控都能对应 [production-line-gates.md](../../docs/pluginization/production-line-gates.md) 的 `- [ ]` 项
- [ ] 没有新增全局 force/skip 开关；豁免仅限结构 high 项且带 owner/原因/到期
- [ ] 旧 `task.yaml` 无新字段时仍可读取，默认 `task_type=code`、使用产线默认门控

## L0 项目结构整理

- [x] `structure.json` 含包职责、公共 API、依赖环/分层、重复、规模、文档、TODO
- [x] 结构未通过时非 `cleanup` 任务的 create/attach/dispatch/start/tick 返回 `409 structure_not_ready`
- [x] `organizing` 阶段仅 `cleanup` 任务可创建/打包/执行
- [ ] cleanup 任务有写域、门控、验收、回滚；跑完重新审计
- [x] high=0 或逐项豁免；无全局跳过；豁免到期自动失效
- [x] 结构通过后才进入 `normalizing`

## L0 文档归一化与索引

- [x] `production.normalize.plan` 返回 diff 且 0 写盘
- [x] `apply` 只追加/索引、不新建；写前有 `before_sha256` 与备份/补丁
- [x] `rewrite` 需 allowlist + 二次确认；未授权拒绝
- [x] 重复 apply 幂等；失败自动回滚；默认不自动 commit
- [x] 写入期间暂停开新任务；完成后重建索引
- [x] LG-02~07 全过才 `line.ready=true`；否则 `409 line_not_ready`
- [x] `graph_version` 含文档内容 hash，不只看 HEAD

## 理解与检索

- [x] 需求提交 T+0 任务落盘，T+60s 内出首版理解卡（允许 partial）
- [x] LLM #1 输出要求摘要、关键词、约束、附件摘要、歧义
- [x] 查询 A 原文 + 查询 B 关键词；两次 embed 合计 ≤5s
- [x] 检索阶段 P95 ≤10s；超时 partial/recall_gap，不补第三轮
- [x] LLM #2 每条结论带 `evidence_id`；无证据进未知
- [x] UI 分段显示 `摘要 / 检索 / 模型` 耗时

## 任务输入与附件

- [x] 任务支持 `brief/acceptance/references/attachments/task_type/gate/conflicts_with/serial_group`
- [x] 任务创建/编辑/批量派发 REST 可用，错误统一 `{status,code,message,missing,evidence}`
- [x] 缺内容/验收、依赖未满足、写域交叠、并行满、附件哈希不一致时阻止派发
- [x] 附件落 `.input/.../attachments/`，登记 sha256/size/type，不写项目资产、不 base64 入包
- [x] 图片边界：像素上限、EXIF/GPS、动图首帧、透明、损坏、重复、超量、SVG 禁脚本
- [x] 视觉模型可总结图片；非视觉模型标 `image_manual_reference`
- [x] PDF/Office/二进制只存不读，登记 known issue
- [x] 项目文档默认只读；文档任务显式、串行、写域只含目标文档

## 计划与任务拆分

- [x] 计划含方案设计、不变量账本、任务 DAG、每任务 `- [ ]` 门禁、追踪矩阵、风险、变更控制
- [x] 每条 `REQ-xx` 至少映射一个任务与一个门控；断链不能落档
- [x] 起草→独立批判→修正至少一轮，最多 3 轮；findings 分级可见
- [x] high findings 未关闭不能静默落档；用户看到 plan diff 与未解决项
- [x] 任务尺寸 1–5 文件/≤300 行/≤1 包；超限拆分
- [x] 依赖无环；同批写域不相交；交叠串行或拆文件
- [x] 每任务至少一个可执行门控；空话不算
- [x] 多任务功能有 `integration` 任务，依赖全部代码任务
- [x] 批次按硬依赖 + 写域不相交 + max_parallel 计算
- [x] 改计划生成 `plan-vN`；在途任务跑完当前 run

## 防漂移与出口门控

- [x] 迁移前有基线冻结（characterization/golden/API 契约/schema/事件 fixture）
- [x] 契约冻结：API/schema/权限/UX 变更需 `DEC-xx` + 双人确认
- [x] 每条不变量有 owner/检查；任务声明 preserves/changes
- [x] 行为保持型重构与行为改变型迁移分开任务
- [x] 增量迁移：strangler/adapter/flag/并行/影子/双写对账
- [x] 每个 diff 能映射到任务/需求；无法映射阻断
- [x] 每任务出口 `- [ ]` 全部勾选且每项有 evidence；无 evidence 不 done
- [x] `changed_files ⊆ write_scope`；越界拒绝
- [x] API/schema/权限/错误码未越权变更
- [x] 回滚脚本存在且演练通过
- [x] 批次跑 BG-01~08 漂移哨兵；任一 fail 停止下一批

## 执行驱动与状态

- [x] 手动派发后触发 tick
- [x] 定时 tick 存在 `queued`/可推进任务时正常决策
- [x] 准备 `finalize` 后按拍板启动执行
- [x] 手动派发同样过依赖/并行/写域/预算/就绪门护栏
- [x] 产线状态由后端投影为 `idle/working/paused`
- [x] 状态转换与旧行为不回归

## 记忆

- [x] `tree.agent` 提供 `agent.memory.get/record`
- [x] 产线只经 MemoryPort 调用，不读 `.self/memory.md`、不存记忆正文
- [x] `pack.json`/台账只存 `memory_hash/sources`
- [x] 记忆不可用时任务继续，台账记 `memory_unavailable`
- [x] 记忆升级不要求产线改代码；契约测试覆盖回包形状

## UI 与产品

- [x] 今日首屏只显示待决定/需处理/正在跑/刚完成
- [x] 准备四步线性推进；未答问题禁止落档
- [x] 任务详情在右栏 `productionTask` 窗口，不在中栏抽屉
- [x] 就绪/结构/归一化/计划/理解/任务详情均有门控状态与禁用规则
- [x] 门控清单逐条可核对，证据可跳转
- [x] `blocked` 翻译成「谁 + 为什么 + 下一步」，不显示英文错误码
- [x] 空态/异常态/依赖态/partial/degraded/stale 文案齐全
- [x] 事件 `broadcast.task_state` 单调 seq + 快照水位 + 3s 轮询兜底

## 稳定性

- [x] 同一任务同时只有一个有效租约；旧 worker 写入拒绝
- [x] 重复派发只执行一次；幂等命令不重复建任务/写文件
- [x] 崩溃/断网/部分写后恢复不丢不重
- [x] 独立门控 runner 生成 `gate.json`；执行者不能写/改证据
- [x] 执行者改门控结果被拒
- [ ] 换模型黄金任务通过
- [x] 恢复/blocked/retry SLO 指标可查

## 兼容、安全与验收

- [x] 新增路由通过 tree_protocol 访问控制；四要素 fail-closed 不放宽
- [x] 旧任务读取/执行不报错
- [x] 插件 analyze 0 + 全量测试 + 自检
- [x] UI 全量测试 + `flutter analyze`
- [x] docs_contract 7/7 通过；README 索引与相对链接有效
- [ ] 真模型 E2E 一次通过并留截图/台账/门控证据
- [ ] TC-PL-C15/19~29 对应用例通过
