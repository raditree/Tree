# 四个内置 Spec 全面优化计划

## 一、总览（Summary）

将四个内置 Spec（`easy-task` / `complex-task` / `hard-task` / `team-meeting`）从基础演示级别提升至专业实用水平：

1. **模板内容深化重写**（核心）：修正错误的工具名引用，增加判型检查清单、量化判据、异常/失败路径、完整模板（汇报/纪要/决策记录/选型矩阵），篇幅提升至详尽完整型（每个约 150-220 行）。
2. **支撑代码修正**：`spec_store.py` 过时注释修正（"内置 3 个"实为 4 个）；`spec_tool.py` 的 `_render_spec_markdown` 与内置 front matter 结构对齐（补 version/classification/risk/changelog 字段），`create`/`update` 支持新元数据参数。
3. **前端体验优化**：`spec_panel.dart` 修正过时注释、task_type 中文徽章、展示 description、选中高亮、正文轻量 Markdown 渲染。
4. **系统提示词最小同步**：`task-paradigm.md` 与深化后的判据保持一致。

**范围边界（用户已确认）**：模板 + 代码 + 前端；**不改 DB schema**（specs 表不加列）；不动 `builtin.yaml`（spec 工具描述）；不动 `chat.py` 注入逻辑。

---

## 二、现状分析（Current State Analysis）

### 架构事实（已核实）

- 四个内置模板位于 [server/tool/spec/builtin/](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/spec/builtin)，结构为 front matter（YAML 风格）+ 三段正文（工作流/该类任务规范/注意事项）。
- [spec_store.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/data/spec_store.py) 的 `_register_builtin_specs()` 在每次进程首次访问 DB 时把 front matter 的 title/task_type/description/when/tags **幂等同步**进 `specs` 表（UPDATE 路径会刷新元数据）→ **改 .md 文件内容后重启 server 即自动生效，无需 DB 迁移**。
- [chat.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/chat.py#L628-L669) 注入：Spec 索引（章节⑦，限摘要）+ 已选 Spec **全文**（章节⑧，含 front matter）→ 篇幅直接影响 token 成本（用户已接受详尽型成本）。
- 系统实际工具名（[builtin.yaml](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/prompt/versions/1.0.0/tools/builtin.yaml) 已核实）：`read` / `write` / `grep` / `edit` / `terminal` / `mcp` / `team` / `set_todo_list` / `ask_user_question` / `spec`。
- team 工具实际动作（[team_tool.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/team_tool.py#L319-L329) 已核实）：`list_teams` / `list_members` / `create_member` / `query_member` / `update_member` / `view_member_output` / `view_member_log` / `send_message` / `assign_task`（spec 中这些引用正确）。
- todo 工具动作：`set` / `update` / `clear` / `get`（工具名为 `set_todo_list`）。

### 发现的问题

| # | 问题 | 位置 | 严重性 |
|---|------|------|--------|
| 1 | 引用不存在的工具名 `ReadFile`/`EditFile`/`WriteFile`/`Terminal`/`AskUserQuestion`/`SetTodoList`（实际为 `read`/`edit`/`write`/`terminal`/`ask_user_question`/`set_todo_list`） | 四个 .md 全部 | 高（误导模型路由） |
| 2 | 工作流缺少异常路径（验证失败怎么办、成员任务失败怎么办、会议无共识怎么办） | 四个 .md | 高 |
| 3 | 缺少可执行模板（汇报模板/会议纪要/决策记录/选型矩阵）与量化判据 | 四个 .md | 中 |
| 4 | 注释过时："内置 3 个"实为 4 个 | spec_store.py L4/L46/L82/L232-245、spec_panel.dart L8 | 中 |
| 5 | `_render_spec_markdown` 生成的自定义 spec front matter 与内置结构不一致（缺 version/classification/risk/changelog） | spec_tool.py L432-L474 | 中 |
| 6 | 前端不展示 description；task_type 显示原始英文；正文纯文本渲染 | spec_panel.dart | 中 |
| 7 | changelog front matter 用嵌套结构，`_parse_front_matter` 解析不干净（子键泄漏为顶层键） | 四个 .md | 低（无下游消费，但脆弱） |

---

## 三、变更方案（Proposed Changes）

### 变更 1：重写 `easy-task.md`（v2，目标约 160 行）

路径：`server/tool/spec/builtin/easy-task.md`

**front matter 修改**：
- `description` 保持单行（`_parse_front_matter` 按行解析，多行会坏），措辞精确化。
- `version: 2`；`changelog` 改为**扁平字符串列表**（修复问题 7）：
  ```yaml
  changelog:
    - "v2(2026-08-30): 修正工具名引用；新增判型/执行/汇报检查清单、验证失败处理路径、汇报模板"
    - "v1(2026-08-23): 初版：纳入版本化提示词体系，补充版本与审计元数据"
  ```
- `created_at: 0` / `updated_at: 0` 保留 0（模板时间以 changelog 为准，字段不入库无功能影响）。其余字段（pinned/builtin/tags 等）保持。

**正文结构（统一保留三个规范段名，`_merge_spec_body` 按段名前缀匹配）**：

1. `## 判型确认（开工前必查）` — 新增
   - 5 项判据检查清单（全部满足才走 easy）：单文件或 ≤3 文件局部改动 / 明确问答或查资料 / 预计 tool call ≤5 / 无新增依赖与接口变更 / 改动影响面可预判。
   - 任一项不满足 → 上调 complex；命中架构级/高危判据 → hard。
   - 3 个典型正例（改一处文案/修一个明确 bug/回答一个明确问题）+ 2 个典型反例（要动多文件/要引新依赖）。
2. `## 工作流（workflow）` — 深化为 5 步，**全部使用实际工具名**：
   1. 判型与澄清：意图模糊（改哪个文件/期望行为不明）→ `ask_user_question` 一次性澄清，禁止猜。
   2. 读上下文：`grep` 先定位 → `read` 精读（大文件用 start_line/line_count 只读相关段）。
   3. 直接执行：已有文件局部修改用 `edit`（old_text 必须唯一）；新建/整文件重写用 `write`；环境操作用 `terminal`。
   4. 验证：`terminal` 跑构建/测试；预计耗时长的命令传 `hook=true` 后台执行，结束读输出文件。**验证失败处理路径**：读输出定位 → 修复 → 重验，最多 2 轮；仍失败 → 升级 complex 并向用户如实汇报已尝试内容。
   5. 汇报：按汇报模板输出。
3. `## 该类任务规范` — 保留并强化：先读后写 / 最小改动范围（禁止顺手优化与无关重构）/ 改后必验证 / 单人单会话完成不建 todo 不召集团队。
4. `## 汇报模板` — 新增，完整展开：
   - 改动点（文件 + 一句话摘要，逐条列出）
   - 修改原因
   - 验证结果（执行了什么命令 + 结论）
   - 影响面与潜在风险（若有）
   - 可选的后续优化建议（仅建议不实施）
5. `## 边界与异常处理` — 新增：
   - 升级触发条件表：tool call 已超 8 未收敛 / 发现跨文件跨模块影响 / 需要新增依赖 / 需要多方案比较 → **立即切换 complex-task**。
   - 目标文件不存在 / edit 匹配不唯一 → 回到 `read` 确认再改。
   - 用户中途追加需求 → 判断是否超出原范围，超出则重新判型。
6. `## 注意事项` — 保留原文核心（easy 是初判非承诺 / 越做越复杂即重判型 / 回答类任务不过度用工具）。

### 变更 2：重写 `complex-task.md`（v2，目标约 200 行）

路径：`server/tool/spec/builtin/complex-task.md`

**front matter**：同变更 1 的模式（version: 2 + 扁平 changelog，记录"修正工具名；新增判型清单、分工与冲突处理、中断恢复、汇报模板"）。

**正文结构**：

1. `## 判型确认（开工前必查）` — 新增：判据清单（跨文件跨模块 / 需分工协作 / 新功能多组件 / 环境依赖变更，任一命中 → complex）；与 easy（全部不满足）和 hard（架构级/高危/高不确定）的边界判别。
2. `## 工作流（workflow）` — 深化为 7 步，实际工具名：
   1. 检索 Spec：`spec search`；明确命中 → `spec read` + `spec select` 挂 hook 并遵循其工作流；未命中 → 走本流程，完成后 `spec create` 沉淀。
   2. 任务分解：`set_todo_list`；拆分标准：每项可独立验证、有明确完成判据、粒度适中（一项 = 一个可验证交付物）；首项固定为"检索 Spec 与确认环境"。
   3. 团队分工：先 `list_members` 看拓扑 → `update_member` 设职责 → `assign_task` 指派；指派四要素：目标 / 输入（相关文件与上下文）/ 验收标准 / 期望产出物。激活 1-3 名成员。
   4. 按 todo 执行：每项走 `read` → `edit`/`write`/`terminal` → 验证循环；**完成一项立即 `set_todo_list update` 更新状态，不得攒批**。
   5. 成员产出验收：`view_member_output` / `view_member_log` 或直接 `read` 产物文件；验收三问：是否达到验收标准 / 是否引入回归 / 相关文档是否同步。
   6. 全量验证：构建 + 测试 + 关键路径人工核对清单。
   7. 汇报与沉淀：按汇报模板输出；无适用 Spec 时 `spec create`。
3. `## 该类任务规范` — 保留并强化（todo 必建全程跟踪 / 先检索后执行 / 分工明确再指派 / 并行避免同文件冲突 / 高风险先 `ask_user_question` 确认）。
4. `## 分工与冲突处理` — 新增：
   - 并行拆分原则：按模块/目录划分，同一文件同一时刻只允许一个负责人（文件所有权）。
   - 强耦合任务 → 串行执行或 leader 自做，不强行拆给团队。
   - 成员任务失败/超时处理：先读其日志定位 → 给出修正指令重试一次 → 仍失败则收回由 leader 自做或换成员。
   - 回滚策略：开工前 `terminal` 确认 git 工作区干净；破坏性步骤前记录检查点。
5. `## 中断恢复` — 新增：todo 状态以 `.self/todos.md` 为准（禁止对话口头跟踪）；会话 compact / 重建后先 `spec list` 确认 selected、`read` 恢复上下文再继续。
6. `## 汇报模板` — 新增，完整展开：完成项（对照 todo 逐项）/ 验证结果（命令 + 结论）/ 遗留项与原因 / 沉淀记录（是否 create 了新 Spec 及其 id）。
7. `## 边界与异常处理` — 新增：升级 hard 触发（架构级影响 / 方案分歧大 / 高危操作）；降级 easy 触发（发现单文件即可完成）；范围变更处理（用户加需求 → 重新分解 todo 并同步影响）。
8. `## 注意事项` — 保留原文核心。

### 变更 3：重写 `hard-task.md`（v2，目标约 220 行）

路径：`server/tool/spec/builtin/hard-task.md`

**front matter**：同上模式（version: 2 + 扁平 changelog）。

**正文结构**：

1. `## 判型确认（开工前必查）` — 新增：hard 判据清单（架构级/框架级变更 / 新领域无经验 / 高不确定需多方案比较 / 高危操作（安全/性能/数据迁移/兼容性）/ 用户明示"重新设计/大重构/企业级/谨慎处理"，任一命中）；与 complex 的边界（多文件但无架构影响 ≠ hard）。
2. `## 工作流（workflow）` — 深化为 6 步，实际工具名：
   1. 检索 Spec：`spec search`；明确命中 → `spec select` 并**回归 complex-task 流程**；模糊/无命中 → 走下方流水线。
   2. 界定边界：范围 / 明确不做项 / 约束条件 / 验收标准，写入 `.self/` 或 `docs/` 文档（可追溯）。
   3. 团队会议：遵循 **team-meeting** Spec（会议期间只讨论不落地）；`update_member` 激活架构/前端/后端/测试/安全等角色；方案比较与决策记录见决策记录模板。
   4. 标准流水线（不跳阶段）：需求分析 → 方案设计 → 方案评审 → 实现 → 测试 → 交付；每阶段准入/准出标准见"流水线阶段标准"。
   5. 高危确认：涉及破坏性/安全/数据迁移操作 → `ask_user_question` 确认单（操作内容 / 影响范围 / 回滚方案 / 是否继续）。
   6. 补充 Spec：**强制** `spec create`（缺失则任务未闭环）。
3. `## 该类任务规范` — 保留并强化（必须过会议 / 每阶段产出物与评审 / 高危必确认 / 末尾必补 Spec / 方案比较记录理由 / `set_todo_list` 建全任务计划含各阶段评审点）。
4. `## 流水线阶段标准` — 新增（每阶段：产出物 + 评审要点 + 准出条件）：
   - 需求分析：产出需求说明（用户目标/功能点/不做项/验收标准）；评审要点：完整/一致/可验证。
   - 方案设计：产出设计方案（架构图或模块划分/接口约定/数据流）；评审要点：可行性/风险/成本/兼容性/可回滚。
   - 方案评审：团队评审通过才准实现；不通过 → 迭代设计（最多 2 轮）→ 仍无共识 → 升级用户决策。
   - 实现：按设计实现，`set_todo_list` 跟踪；实现中发现方案不可行 → 回退设计阶段并在决策记录中追加原因。
   - 测试：全量验证 + 关键路径 + 回归。
   - 交付：向用户汇报（含验证结果与遗留项）。
5. `## 决策记录模板（ADR 风格）` — 新增，完整展开：背景与问题 / 候选方案（A/B/C 各自优劣势与成本）/ 选型结论与理由（为什么选 A 不选 B）/ 风险与缓解措施 / 回滚方案。写入工作空间文档供追溯。
6. `## 风险评估框架` — 新增：概率（高中低）× 影响（高中低）矩阵；高危操作清单（数据迁移/批量删除/安全相关/兼容性破坏/不可逆变更）——命中即触发第 5 步高危确认。
7. `## 边界与异常处理` — 新增：问题过大拆分原则（按模块或阶段拆成多个 hard-task 分别处理）；降级 complex 触发（会议中确认无架构级影响）；评审不通过的迭代路径；实施中方案不可行的回退路径。
8. `## 注意事项` — 保留原文核心。

### 变更 4：重写 `team-meeting.md`（v2，目标约 200 行）

路径：`server/tool/spec/builtin/team-meeting.md`（`risk: review` 保留）

**front matter**：同上模式（version: 2 + 扁平 changelog）。

**正文结构**：

1. `## 适用场景与判型` — 新增：何时开会（hard-task 会议阶段 / 用户或 leader 明确要求"开会/讨论/先出方案" / 架构级多方案选型 / 高不确定需团队评审）；何时不开会（信息充分可直接执行的任务）。
2. `## 工作流（workflow）` — 深化为 6 步，实际工具名（`read`，其余 team 动作名本就正确）：
   1. 会议召集（leader）：明确主题/目标/参会成员/背景材料，`team send_message` 发召集消息（用召集消息模板，**明确标注只讨论禁落地**）。
   2. 成员发言：只围绕主题给结构化方案（按发言模板四要素：方案思路/利弊分析/风险点/所需前置信息）；**严禁** write/edit/terminal/assign_task。
   3. 方案汇总（leader）：按选型矩阵比较，记录理由。
   4. 定案与分工：`team update_member` 明确分工 → 发**明确的执行指令**（assign_task / send_message 注明"开始执行任务：xxx"）。
   5. 进入执行：收到明确执行指令后成员方可落地。
   6. 会议纪要：结论/选型理由/分工/待办沉淀到 `.self/` 或 `docs/`（用纪要模板）。
3. `## 该类任务规范` — 保留并强化（会议 ≠ 开工 / 发言结构化 / 决策闭环不悬空 / 产出可追溯 / 与 hard-task 衔接 / 会议期间可 `read` 不可改）。
4. `## 会议召集消息模板` — 新增，完整展开（含"本次为会议讨论，请只给方案/意见，禁止改代码、跑命令、派活"的显式声明）。
5. `## 成员发言模板` — 新增，完整展开（方案思路 / 理由与利弊 / 风险点 / 前置问题四段）。
6. `## 方案比较矩阵模板` — 新增：维度（可行性/实现成本/风险/可维护性/回滚难度）× 候选方案的对照表格式。
7. `## 会议纪要模板` — 新增，完整展开：议题与目标 / 参会成员 / 讨论要点摘要 / 结论与选型理由 / 分工与待办（负责人 + 验收标准）/ 风险与后续。
8. `## 边界与异常处理` — 新增：
   - leader 消息未明确"只讨论" → 成员默认先讨论不落地，回复中确认。
   - 议题发散 → leader 收敛回主题。
   - 无共识 → leader 给默认方案（含理由）或升级用户决策，**避免无限开会**；发言控制在 ≤2 轮。
   - 高危议题 → 方案必须含风险评估，落地前用户确认。
   - 把"收集方案"误当"分配任务" → assign_task 只在定案后使用。
9. `## 注意事项` — 保留原文核心。

### 变更 5：`spec_store.py` 注释修正（纯注释，无逻辑变化）

路径：`server/data/spec_store.py`

| 行号 | 原文 | 改为 |
|------|------|------|
| L4 | （内置 3 个为服务端模板…） | （内置 4 个为服务端模板…） |
| L46 | 注册内置 3 个 Spec 的元数据 | 注册内置 4 个 Spec 的元数据 |
| L82 | 把内置 3 个 Spec… | 把内置 4 个 Spec… |
| L232 | 内置 3 个置顶 + 该 agent… | 内置 4 个置顶 + 该 agent… |
| L245 | 内置 3 个按固定顺序置顶 | 内置 4 个按固定顺序置顶 |

（`BUILTIN_SPEC_IDS` 本就有 4 个 id，代码逻辑正确，仅文档失真。）

### 变更 6：`spec_tool.py` front matter 渲染对齐 + 新元数据参数

路径：`server/tool/spec_tool.py`

1. **`get_tool_definition()`**：参数 schema 新增：
   - `risk`：`{"type": "string", "enum": ["low", "medium", "high", "review"], "description": "create 用：风险等级（easy→low/complex→medium/hard→high/评审类→review）"}`（update 亦可用）。
   - `classification`：`{"type": "string", "description": "create 用：规范分类（如 内部规范/团队约定/领域规范）"}`。
2. **`_render_spec_markdown()`**：签名增加 `risk: str = "low"`、`classification: str = "内部规范"`、`version: int = 1`、`changelog: Optional[List[str]] = None`；front matter 渲染补齐（与内置结构一致）：
   ```
   version: {version}
   classification: {classification}
   risk: {risk}
   changelog:
     - "v{version}({date}): {首条}"
   ```
   `pinned: false` / `builtin: false` 保持。
3. **`_action_create()`**：读取 `risk`（非法值回退 `low`）与 `classification`（默认"内部规范"）；changelog 初始条目为 `"v1(日期): 初始创建"`。
4. **`_action_update()`**：从现有文件 front matter 解析 `version`（复用 `spec_store._parse_front_matter`，int 化，缺省 1）→ +1；changelog 头部插入 `"vN(日期): 经 spec update 更新"`（保留原条目——从原文件解析 changelog 列表，解析失败则仅新条目）；传参 `risk`/`classification` 时覆盖，未传保留原值。
5. 不改 `_merge_spec_body`（正文三段合并逻辑不受影响）；不改模块 docstring（其"内置 4 个"本就正确）。

### 变更 7：`spec_panel.dart` 前端体验优化

路径：`lib/ui/widgets/spec_panel.dart`

1. L8 注释："内置 3 置顶" → "内置 4 置顶"。
2. **task_type 中文映射**：`easy→简单`、`complex→复杂`、`hard→困难`、`custom→自定义`（未知值原样显示）；渲染为小徽章，配色用 colorScheme 容器色区分（easy→primaryContainer / complex→tertiaryContainer / hard→errorContainer / custom→surfaceVariant）。
3. 卡片增加 `description` 一行（maxLines: 2，现有 UI 未展示该字段）。
4. **选中态高亮**：`selected` 时 Card 加 `Border.all(color: _cs.primary, width: 1.5)`。
5. **`_ExpandedMarkdown` 轻量渲染增强**（保持无第三方依赖）：
   - `## `/`###` 开头行 → 加粗 + primary 色。
   - `- ` 开头行 → 缩进 + bullet 符号。
   - `**text**` → 加粗（正则替换为富文本 span）。
   - 其余原样。逐行构建 `List<InlineSpan>`/Widget 列表，不做完整 Markdown 解析。
6. 空状态文案优化："暂无可用 Spec" → 追加引导（"内置 Spec 由服务端提供；任务完成前可用 spec 工具沉淀自定义 Spec"）。

### 变更 8：`task-paradigm.md` 最小同步

路径：`server/prompt/versions/1.0.0/chapters/task-paradigm.md`

- 四个 spec 的概括行与 v2 内容对齐：确认判据阈值一致（tool call >8 升级、验证失败 2 轮升级、发言 ≤2 轮收敛等）；在 easy 行补"验证失败 2 轮未修复即升级"半句；其余保持简短（系统提示词 token 敏感，**只做最小同步不扩写**）。
- `spec-maintenance.md` 内容为流程性描述，与 v2 无冲突，不改。

### 变更 9：新增渲染回归测试

新建 `server/tests/test_spec_render.py`（unittest 风格，与现有测试一致）：
1. `_render_spec_markdown` 输出含 `version:` / `classification:` / `risk:` / `changelog:` 行且 pinned/builtin 为 false。
2. `_render_spec_markdown` changelog 列表项格式与 `_parse_front_matter` 往返兼容（渲染结果可被解析回 risk/version 值）。
3. `SpecTool._action_create` 带 `risk="high"` 时落盘文件含 `risk: high`（mock io，仿 `test_spec_tool_select.py` 的临时目录模式）。

---

## 四、假设与决策（Assumptions & Decisions）

| 决策 | 理由 |
|------|------|
| 不改 DB schema | 用户确认范围；内置元数据同步机制（`_register_builtin_specs` 幂等 UPDATE）已保证 .md 改动自动生效 |
| 不动 `builtin.yaml` 的 spec 工具描述 | 描述只列动作不列参数细节；改它会牵动 prompt 版本与 `test_prompt_versions.py`，收益低风险高 |
| spec 正文统一保留"工作流（workflow）/该类任务规范/注意事项"三个规范段名 | `_merge_spec_body` 按段名前缀匹配，保持自定义 spec update 兼容 |
| front matter 写作约束：description 单行、when 每项单行、changelog 用扁平字符串列表 | `_parse_front_matter` 逐行解析的限制（现状即如此，v2 显式遵守并修复 changelog 嵌套解析脆弱点） |
| 篇幅详尽完整型（150-220 行/个） | 用户确认接受 token 成本；全文经章节⑧注入上下文 |
| changelog 日期用 2026-08-30（今天） | 与现有 v1 条目日期风格一致 |
| `created_at`/`updated_at` front matter 保持 0 | 该字段不入库无功能影响；版本演进以 changelog 为准 |

---

## 五、验证步骤（Verification）

1. **单元测试**（server 目录下）：
   ```
   python -m pytest server/tests/test_spec_render.py server/tests/test_spec_tool_select.py server/tests/test_data_stores.py server/tests/test_prompt_versions.py -v
   ```
   （若 pytest 不可用则 `python -m unittest` 对应模块；全部通过，无回归。）
2. **front matter 解析验证**：小脚本或 REPL 调 `spec_store._parse_front_matter` 解析 4 个新 .md，确认 title/task_type/description/when/tags/version/risk 解析值正确、无子键泄漏。
3. **注册同步验证**：启动 server 后 `GET /api/agents/{id}/specs`，确认 4 个内置 spec 的 description/when 已更新（幂等 UPDATE 生效）。
4. **前端验证**：`flutter analyze lib/ui/widgets/spec_panel.dart` 无告警；运行 app 打开 Spec 面板，目视确认中文徽章、description 行、选中高亮、正文轻量渲染。
5. **工具名一致性抽查**：grep 四个新 .md 确认不再出现 `ReadFile|EditFile|WriteFile|Terminal|AskUserQuestion|SetTodoList`（Terminal 作为普通英文单词出现在"终端"语境除外——统一用中文"终端/命令行"表述规避误报）。
