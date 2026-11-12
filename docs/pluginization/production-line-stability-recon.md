# 生产线稳定性侦查（STAB-PL）

> 2026-11-12 已拍板 D1~D8（见 §5），**进入落地**；不再只侦查。
> 输入：用户提供的 9 张现场截图；对码范围：
> `plugins/tree.production.line`（0.8.0）、`plugins/tree.ui.default`（1.0.8+1）、
> `plugins/tree.agent`、`plugins/files`、`packages/tree_core`。
> 记录原则：只写**已核验**的代码事实（路径 + 行号）；推测一律标「待确认」。

---

## 1. 结论摘要

| ID | 现象（截图） | 判定 | 影响 | 根因位置 | 建议 |
| --- | --- | --- | --- | --- | --- |
| STAB-PL-1 | 新建任务即报「操作失败：task_id 不能为空」 | **P0 缺陷** | 产线无法从 UI 排任务 | UI 不下发 `id`；插件 `createTask` 强制 `id` | 后端缺省生成 `T<millis>`（同 `prepare.intake`） |
| STAB-PL-2 | 写域「可空」，但留空不能打包；用户期望留空=产线工作目录 | **P1 语义缺口（需拍板）** | 任务建完卡在 `queued` | UI 文案与三道后端闸门冲突 | 空→`['**']`（串行）或改成必填并一键填根 |
| STAB-PL-3 | 模型下拉出现模型池里没有的 `lfm3` | **P1 缺陷** | 配置看似完整，打包/执行才失败 | UI 默认值 + 下拉把当前值并进池；后端也默认 `lfm3` 且不校验 | UI 默认取池内第一个；存量标失效；池空禁止提交 |
| STAB-PL-4 | 模型页报「未知接口：/api/agents//models-info」 | **P2 缺陷** | 空态被渲染成错误态 | 未选 Agent 时 `agentId=''` 仍发请求 | 空 `agentId` 走空态，不发请求 |
| STAB-PL-5 | 选中产线后文件窗仍提示「先选 Agent」 | **P1 能力缺口** | 产线工作空间不能在文件窗浏览 | 文件窗只认 `_selectedAgent.workspaceId` | 短期改文案兜底；中期让产线工作空间成为文件作用域 |
| STAB-PL-6 | 执行工具只有一组，未按角色分别选 | **P2 能力变更（需拍板）** | 打包/专家工具不可调，`orchestrator` 是死配置 | UI 只暴露 executor 工具；后端三角色各用默认表 | 四块角色卡 + 按硬边界禁选项；或移除「主控」 |
| STAB-PL-7 | 产线列表选中行是直角矩形 | **P3 视觉** | 与全仓圆角不一致 | 产线面板未接入 `AppRadius` | `Material` 加 `borderRadius` + `clipBehavior` |
| STAB-PL-8 | 新增模型被「模型已存在：xxx」挡住 | **P1 设计冲突（需拍板）** | 同一 `model_id` 的多端点/多账号不能并存 | 模型池身份与去重键都是 `model_id`；显示名无唯一校验 | 身份拆成 key / 端点模型名 / 显示名；本期先改文案与列表分组 |
| STAB-PL-9 | 思考强度下拉直接给 `low/high/max` | **P1 缺陷** | 兜底值被当成端点声明并写进 YAML | 新增时不能探测；候选恒有兜底；提交总是回写 options | 未探测不落盘、不显示假选项；探测后才列真实档位 |

**阶段口径提醒**：稳定性迭代只允许「修缺陷、补测试」。
`STAB-PL-2`（写域语义）与 `STAB-PL-6`（按角色配工具）属于**能力/语义变更**；
`STAB-PL-8`（模型池身份）属于**存储身份改造**；均需先拍板（见 §5 D2/D5/D7），
否则不进本期。

---

## 2. 逐项侦查

### STAB-PL-1 新建任务必然失败（P0）

**现象**：工作台「新建任务」填写标题与写域后点「创建」，SnackBar 报
`操作失败：task_id 不能为空`（截图：`production line 创建任务时失败.png`）。

**证据链**

1. UI 组请求体时只放四项，没有 `id`：
   `plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart:223-233`
   （`title / status / priority / write_scope`）。
2. 新建任务对话框只收集标题与写域：
   `.../production_line_workbench.dart:1042-1051`。
3. 插件 REST 入口把 `task` 原样交给命令门面：
   `plugins/tree.production.line/lib/src/api.dart:199-209`。
4. `production.task.create` 直接调用 `store.createTask`：
   `plugins/tree.production.line/lib/src/service.dart:107-116`。
5. `createTask` **强制**读取 `input['id']`，空即抛错：
   `plugins/tree.production.line/lib/src/store.dart:405-408`；
   报错模板见 `store.dart:1109-1113`（`'$what 不能为空'`）。
6. 对照：准备阶段建任务会自己生成 id（`T<millis>`）：
   `plugins/tree.production.line/lib/src/preparation_service.dart:130-142`。
   插件 API 测试也都显式传 `id`（`test/api_test.dart:259-268`），掩盖了 UI 缺口。

**根因**：REST 建任务缺少「id 缺省生成」策略；UI 按“后端生成”实现，后端按“调用方必填”实现，契约在两侧理解不一致。

**修复方向**

- **A（推荐）**：`store.createTask` 在 `id` 为空时生成 `T<millis>`（与 `prepare.intake` 同口径），已存在仍走 `task_exists`。UI 零改动。
- B：UI 生成 id 后下发。缺点：客户端时钟/并发碰撞、多客户端重复实现。
- C：把 `id` 定为必填并修 UI + 文案。缺点：把内部实现细节暴露给所有调用方。

**验收**：空 `id` 创建成功且列表可见；同毫秒重复给出可读 `task_exists`；
新增两条测试：插件「无 id 自动生成」、UI「填标题→创建→列表刷新」。

---

### STAB-PL-2 写域留空的语义（P1，需拍板）

**现象**：新建任务弹窗写域标签是「写域（逗号分隔，可空）」，
helper 却是「执行阶段只允许改这些路径；留空则不能打包」。
用户截图标题明确期望：**留空则用产线的工作目录**。

**现状证据**

- 文案：`plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart:1008-1014`。
- 三道闸门都会拒绝空写域：
  1. 派发计划直接跳过：`plugins/tree.production.line/lib/src/queue.dart:150-157`
     （`reason=write_scope_missing`）；
  2. 打包拒绝：`.../execution_service.dart:177-183`（`write_scope_required`）；
  3. 执行拒绝：`.../execution_service.dart:404-410`（`write_scope_required`）。
- 执行后的越界判据：改动差集必须全部落在 `write_scope` 内，否则 `blocked`
  （`.../execution_service.dart:533-576`）；空 scope 时
  `matchesWriteScope` 恒为 false（`.../execution.dart:212-221`、`253-259`）。
- 设计依据：任务必须有 `write_scope`，它同时是并行判据与权限判据
  （`docs/pluginization/production-line-recon.md:424-433`、`669-671`）。

**根因**：UI 用「可空」表达了“可以不填”，后端把空写域定义为“不可执行”。
两者不是同一个语义，且提示到打包阶段才出现，用户已经把任务建完了。

**修复方向**

- **A（最小、保持安全）**：写域改为必填；留空时禁止提交并给「用工作空间根」按钮，
  自动填入 `**`。不改并行/门禁语义。
- **B（满足用户期望）**：空 → 归一为 `['**']`（整个工作空间）。
  现有通配实现可直接支撑：`execution.dart:224-250`；
  并行判据里 `**` 与任何写域都会判交叠（`queue.dart:43-63`），
  因此这类任务天然**串行**，不与“写域不相交才并行”冲突。
  但 `deny_globs` 仍是唯一禁区，必须在 UI 明示“等于不限制改动范围”。
- **C**：保留“不能打包”，仅把 UI 文案改成「留空 = 不可打包」并前置校验。

**建议**：若用户要“留空就能跑”，选 **B**，同步改三处：
① UI 文案与提交前提示；② 任务详情回显 `**`（避免用户以为没配置）；
③ 用例覆盖“空写域可打包/执行、与任何任务不并行、`.env` 仍被拦”。

**验收**：空写域创建→打包→执行全链路通过；与另一在途任务并行被拒；命中禁区仍 `blocked`。

---

### STAB-PL-3 模型“无中生有”（P1）

**现象**：角色与模型下拉出现 `lfm3`，但模型池没有该模型
（截图：`production line 模型无中生有…png`）。用户明确：默认只是使用习惯，
不是模型池里的合法条目。

**证据链**

1. UI 四个角色的默认模型都写死 `lfm3`：
   `plugins/tree.ui.default/lib/ui/widgets/create_production_line_dialog.dart:65-80`；
   初始化缺省同样回落到默认值：同文件 `121-131`。
2. 下拉选项把「当前值」无条件并进模型池：
   同文件 `412-419`（`options = 池内 model_id + current`）。
   因此即使池里没有 `lfm3`，它也会作为一项出现；池为空时更是只剩 `lfm3`。
3. 后端新建产线的默认 `line.yaml.roles` 也全部是 `lfm3`：
   `plugins/tree.production.line/lib/src/models.dart:233-260`。
4. 新建 / 修改产线都不校验 `model_id` 是否存在：
   `plugins/tree.production.line/lib/src/store.dart:123-185`、
   `models.dart:297-309`（只做浅合并）。
5. 下游才报错：产线员工查模型池失败时返回
   `模型「lfm3」不在模型池里：请到「设置 → 自定义模型」补上`
   （`plugins/tree.agent/lib/src/agent/subagent_service.dart:344-350`）。
6. 已拍板口径：P7 取消模型硬绑定，`lfm3` 只是“新建产线模板默认值”，
   模型由用户在模型池自选（`docs/project-status.md:45`）。

**根因**：把“模板默认值”当成了“合法模型”，且 UI 把当前值无条件视为可选项；
后端缺一层入口校验，错误被推迟到打包/执行。

**修复方向**

- **A（推荐，UI 侧）**：默认值改为模型池第一个 `chat` 模型（`chatModelsOf` 过滤，
  `plugins/tree.ui.default/lib/ui/services/model_pool.dart:65-71`）；
  池为空时留空并禁用提交；下拉只列池内模型。
  编辑时若已有 `model_id` 不在池内，显示「已失效：xxx」并禁止保存。
- **B（后端兜底）**：新建/修改产线拒绝空 `model_id`；
  非空存在性校验需要模型池访问通道（插件不 import 核心包），
  可新增 `agent.model.exists` 类执行站命令，或在派发受理前提前校验。
- **C（存量）**：已写 `lfm3` 的产线在配置页直接标红「模型不在池中」。

**建议**：本期做 A + C；B 的存在性校验作为 D3 拍板（是否值得新增点位）。

**验收**：池内无 `lfm3` 时下拉不出现 `lfm3`；新产线必须选池内模型；
存量产线打开配置即提示失效；错误不再拖到打包阶段。

---

### STAB-PL-4 模型信息页加载失败（P2）

**现象**：右栏「模型信息」显示「模型信息加载失败
Exception: 未知接口：/api/agents//models-info」
（截图：`production line 模型页加载失败.png`）。注意 URL 中 `agents//` 为空段。

**证据链**

1. 窗口无条件注册，`agentId` 取当前 Agent，未选则为空串：
   `plugins/tree.ui.default/lib/ui/pages/main_page.dart:1812`、
   `1858-1865`。
2. 面板 `initState` 直接加载，没有空值保护：
   `plugins/tree.ui.default/lib/ui/widgets/model_info_panel.dart:147-151`。
3. URL 直接字符串拼接，无空值短路、无编码：
   `plugins/tree.ui.default/lib/io/api_service.dart:934-936`。
4. 核心路由匹配不到空段，返回 404 文案「未知接口」：
   `packages/tree_core/lib/src/server/core_server.dart:544`。
5. 引导步骤「配模型」也会在未选 Agent 时打开该窗：
   `main_page.dart:1633-1641`（`agentModel → modelInfo`）。

**根因**：右栏窗口对“没有 Agent”没有空态分支；错误态直接接管了本应是空态的场景。

**修复方向**

- 面板入口判断 `agentId.isEmpty` → 渲染空态「请先在左侧选择或创建一个 Agent」，
  不发请求（与文件窗同款，`main_page.dart:1915-1930`）。
- 引导步骤在无 Agent 时改跳「创建 Agent」或「设置 → 模型池」。
- 请求侧对 `agentId` 做 `Uri.encodeComponent` 并对空值短路，避免同类问题复发。

**验收**：未选 Agent 打开模型信息不发请求、无错误；选 Agent 后正常加载；引导路径不再落到错误页。

---

### STAB-PL-5 选中产线后无法浏览文件（P1 能力缺口）

**现象**：左栏选中产线（截图里 `test / pl_1794353085268 · idle`）后，
右栏文件窗仍是「请先在左侧选择或创建一个 Agent」
（截图：`production line 选择后为什么没法浏览文件.png`）。

**证据链**

1. 选中产线只记录 `_selectedProductionLine` 并展开中栏，
   不改 `_selectedAgent`：`plugins/tree.ui.default/lib/ui/pages/main_page.dart:1733-1739`。
2. 文件窗只认 `_selectedAgent.workspaceId`：
   `main_page.dart:1812-1831`；为空即空态（`1822-1824`、`1915-1930`）。
3. 文件插件的根目录解析是“Agent 的 `workspace_id` / `id` →
   `workspace_dir`”：`plugins/files/lib/src/workspace.dart:79-145`。
4. 产线的 `workspace_dir` 是独立绝对路径（`line.yaml`），
   与 Agent 的 workspace 不是同一个标识。

**根因**：文件窗的作用域模型只有“Agent 工作空间”，产线的 `workspace_dir` 没有进入 UI 的作用域解析。

**修复方向**

- **A**：选中产线时，若 `executor.agent_id` 非空，自动把该 Agent 设为当前 Agent。
  前提是“产线目录 == 执行 Agent 目录”；不一致会看错目录，需先校验。
- **B（中期）**：让产线工作空间成为文件作用域（新增 files 路由/租约支持产线根，
  `FilePanel` 增加 line 模式）。
- **C（短期兜底）**：明确文件窗只跟随 Agent；把工作台「产物」做成可点开的入口，
  并在空态补一句「产线文件请看工作台『产物』或先选执行 Agent」。

**建议**：本期先 C（零架构改动、消除误解），把 B 立项到下一轮；
A 只有在产线与执行 Agent 目录一致时才可用。

**验收**：从产线上下文能到达其工作空间文件，或得到明确的操作指引。

---

### STAB-PL-6 执行工具按角色分别配置（P2 能力变更）

**现象**：配置页只有一组「执行工具」chips（截图：`production line 执行工具应针对每个角色单独选.png`），
实际只对执行角色生效。

**证据链**

1. UI 只维护一份 `_tools`，仅写进 `roles.executor.tools`；
   其余角色沿用手写默认值：
   `plugins/tree.ui.default/lib/ui/widgets/create_production_line_dialog.dart:113-114`、
   `217-239`、`357-385`。
2. 后端各角色独立消费自己的 `roles.<role>.tools`：
   packer `plugins/tree.production.line/lib/src/execution_service.dart:236`、
   executor `:488`、expert `:768`。
3. 角色默认工具在 UI 与插件各维护一份：
   UI `create_production_line_dialog.dart:65-80`；
   插件 `execution_service.dart:34-38`。
4. 专家还有硬边界（禁 `write/edit/subagent/team/ask_expert`）：
   `plugins/tree.production.line/lib/src/expert.dart:26-35`、`181-191`。
5. `orchestrator`（主控）只存在于默认模板
   （`models.dart:234-237`），执行链没有任何读取点 —— **死配置**。
6. UI 没有专家开关与次数上限；`_buildRoles` 只是保留旧值
   （`create_production_line_dialog.dart:226-231`）。

**根因**：角色模型/工具在数据层是完整的，UI 只实现了 1/4；「主控」沿用了模板但后端未接线。

**修复方向**

- **A**：四个角色卡各自一组工具 chips + 模型下拉；
  按后端硬边界禁用非法项（packer/expert 禁写；executor 必须含 `write` 或 `edit`）。
- **B**：若主控暂不接线，UI 移除或标注「预留（未接线）」，避免用户误配。
- **C**：专家 `enabled` / `max_per_task` 一并暴露。

**建议**：这是一次**配置页语义纠偏**，不是纯缺陷；稳定性阶段需 D5 拍板。
若不在本期，登记为下一快速迭代的第一切片。

**验收**：每个角色可独立选模型与工具；非法组合 UI 拦截且后端仍 fail-closed；
「主控」不再作为可配置项误导用户。

---

### STAB-PL-7 选中态无圆角（P3）

**现象**：产线列表选中行是浅绿直角矩形（截图：`UI 没给圆角.png`）。

**证据**

- 选中底色直接涂在 `Material` 上，`InkWell` 没有 `borderRadius` / `clipBehavior`：
  `plugins/tree.ui.default/lib/ui/widgets/production_line_panel.dart:302-315`。
- 同仓其他列表行已统一用圆角令牌：
  `plugins/tree.ui.default/lib/ui/widgets/agent_list_item.dart:43-49`
  （`AppRadius.sm`）。

**根因**：L 车道圆角化按“文件区域避让”推进，后加的产线面板（H 车道）没有纳入令牌覆盖。

**修复方向**：`Material` 改为透明，内层用
`Ink(decoration: BoxDecoration(color:…, borderRadius: BorderRadius.circular(AppRadius.sm)))`，
或用 `Material(color:…, borderRadius:…, clipBehavior: Clip.antiAlias)`；
选中/悬停共用同一半径。

**验收**：深/浅主题、选中/未选中、240px 窄栏均无直角溢出；`flutter analyze` 0。

---

### STAB-PL-8 模型池去重键应为显示名（P1，需拍板）

**现象**：新增模型时保存失败：
`保存失败：Exception: 模型已存在：deepseek-v4.1-flash`
（截图：`模型池去重应以显示名而非模型id.png`）。
用户期望的唯一性/去重口径是**显示名**，而不是端点模型名 `model_id`。

**证据链**

1. 新建模型以 `model_id` 作为模型池字典键，重复直接返回 null：
   `plugins/tree.agent/lib/src/settings/domain_settings.dart:409-418`。
2. REST 层据此回 409，且错误详情打印的是 `model_id`：
   `plugins/tree.agent/lib/src/delegate.dart:563-576`。
3. `model_id` 同时是配置文件名（`<data_root>/config/models/<model_id>.yaml`）
   与全局身份：Agent 绑定、`/api/models/{id}` 路由、模型元数据缓存都按它索引
   （`domain_settings.dart:409-418`、`delegate.dart:583-641`）。
4. `model_id` 还被**原样当作端点请求的 `model` 字段**发出：
   `plugins/tree.agent/lib/src/llm/llm_agent_engine.dart:301` / `323` / `515` / `671`；
   `plugins/tree.agent/lib/src/llm/embedding_client.dart:126-139`；
   `plugins/tree.agent/lib/src/llm/openai_codec.dart:29`（`'model': request.model`）。
5. 显示名 `name` 没有任何必填/唯一校验：
   `validateNewModel` 只查 `model_id / base_url / api_key`
   （`domain_settings.dart:436-445`）；`toApiJson` 在 `name` 为空时回落到
   `model_id`（`domain_settings.dart:148-150`）。
6. 模型池列表也按行展示 `name` + `model_id`，没有按显示名合并/去重：
   `plugins/tree.ui.default/lib/ui/pages/settings_page.dart:1783-1843`。

**根因**：模型池把“配置身份”“端点模型名”“用户可见身份”压成了同一个字段 `model_id`。
同一底层模型走官方/中转两个端点时，端点模型名相同，于是第二条配置被身份冲突挡住；
用户即使改了显示名也无法保存。

> **待确认（D7）**：上述“同一 `model_id` + 不同显示名并存”是从标题与截图推断的场景。
> 若用户实际诉求是“同显示名视为重复并拒绝”，则不需要拆分存储身份，
> 只需给 `name` 加必填 + 唯一校验；两种读法的改动量差一个数量级，拍板前先确认。

**影响**：同一模型的多端点、多账号、多区域无法并存；
用户若强行改 `model_id` 绕过，端点会收到错误的模型名（请求失败或路由到别的模型）。

**修复方向**

- **A（推荐，身份拆分）**：引入三个概念并分离：
  - `key`：唯一配置键（文件名 / Agent 绑定 / REST 路径），新建时生成；
  - `model_id`：端点 `model` 字段，可重复；
  - `name`：用户可见显示名，做唯一性校验（去重键）。
  旧配置 `key == model_id` 保持兼容，Agent 绑定不需要迁移。
- **B（A 的最小变体）**：保留 `model_id` 字段给端点，另加 `config_id` 作为池键；
  新建时 `config_id = slug(name)`，冲突加后缀。
- **C（本期兜底，不改身份）**：维持 `model_id` 唯一，只改 409 文案
  （“model_id 已被占用；同一模型的多端点请用不同别名”），
  并在模型池/选择器里按显示名分组展示，先消除“看起来重复”的困惑。

**建议**：A/B 是**模型池存储身份改造**，属下一快速迭代，不在稳定性阶段夹带；
本期做 C 的文案与分组展示，并把 A 立项。拍板项 D7。

**验收**（A/B）：同一 `model_id` + 不同显示名可并存，请求仍发正确的端点模型名；
同显示名被拒绝且提示可读；旧配置与 Agent 绑定零迁移损失。

---

### STAB-PL-9 思考强度档位不应由兜底值冒充端点声明（P1）

**现象**：新增模型时「思考强度默认档位（reasoning_effort）」直接列出
`不设置 / low / high / max`（截图：`思考模式设置应从 API 端点取.png`）；
用户期望候选来自 API 端点声明，而不是硬编码兜底。

**证据链**

1. 新增模型时**不能**探测端点：探测按钮只在编辑态显示
   （`plugins/tree.ui.default/lib/ui/pages/settings_page.dart:2580-2599`），
   新增态只提示“保存后可从端点探测价格与思考档位”。
2. 档位候选的优先级是「端点声明 → 已存档位 → 兜底」：
   `settings_page.dart:2366-2375`；兜底正是 `kFallbackReasoningEfforts`
   （`plugins/tree.ui.default/lib/ui/services/model_pool.dart:95`，
   编辑器引用在 `settings_page.dart:2354-2358`）。
3. 提交时**无条件**把候选列表写回请求体：
   `_currentDraft` 传 `reasoningEffortOptions: _candidateEfforts`
   （`settings_page.dart:2526-2544`）；`ModelEditorDraft.toPayload` 非空即写入
   （`model_pool.dart:235-241`）。
4. 后端构造默认值同样是兜底，并且 `toJson` **总是**落盘：
   `plugins/tree.agent/lib/src/settings/domain_settings.dart:54-73`、`127-145`；
   `merge` 仅在请求带非空 options 时覆盖（`:242-256`）。
5. 结果是：新建一个端点**未声明**档位的模型，YAML 也会被写成
   `reasoning_effort_options: [low, high, max]`；下次打开编辑器时它被当作
   “已存档位”，假声明就此固化。
6. Agent 覆盖档位有同一个兜底：`models-info` 未下发时直接列
   `low/high/max`（`plugins/tree.ui.default/lib/ui/widgets/model_info_panel.dart:135-144`）。
7. 现有测试把兜底当契约：
   `plugins/tree.ui.default/test/model_pool_test.dart:111-127`；
   `plugins/tree.agent/test/domain_settings_test.dart:59-60`。

**根因**：“端点声明”“未探测”“系统兜底”三种状态没有区分；UI 与后端都默认
`low/high/max` 是合法档位，并把它持久化成了模型配置。

**影响**：用户可能选到端点不接受的档位（请求 400 或静默退化）；
真正由端点声明的档位与系统兜底无法区分，排障时误导。

**修复方向**

- **A（正确性，必做）**：`reasoning_effort_options` 默认改为空；
  空则不落盘（`toJson` 省略键）、不当作“已存档位”；
  `models-info` 未声明时下发空数组，由消费方明确显示“端点未声明”。
- **B（新增时可探测）**：增加“草稿探测”能力——请求体带
  `base_url / api_key / model_id`，只探测不落盘；或保存成功后自动
  `POST /api/models/{id}/meta` 再回填。新增表单据此展示真实档位。
- **C（无探测时）**：下拉只保留「不设置」，并提示“端点未声明档位，可保存后探测”；
  不再列 `low/high/max`。
- **D（Agent 覆盖面）**：`models-info` 只下发真实声明；未声明时禁用覆盖下拉或提示。

**建议**：本期做 A + C（消除假选项与假落盘），B/D 作为 D8 拍板。
注意 A 会改 `docs/pluginization/agent_api_contract.md` 的模型回包示例与上述两条测试口径。

**验收**：新建未探测模型时 YAML 不含 `reasoning_effort_options`；
UI 不显示假档位；探测成功后只显示端点声明；Agent 覆盖面板同口径；
存量文件下次保存时不再自动写入兜底。

---

## 3. 横向问题（比单点更值得修）

1. **契约口径分裂**
   - `task_id`：UI 认为可空，插件认为必填（STAB-PL-1）。
   - `write_scope`：UI 写“可空”，插件三道闸门认为必须非空（STAB-PL-2）。
   - 模型默认：模板写 `lfm3`，产品口径是“不硬绑”（STAB-PL-3）。
   这三处都不是实现 bug，而是**接口契约没有单一出处**。
2. **测试盲区**
   - UI mock 不校验请求体，且「新建任务」用例只打开弹窗、不点创建
     （`plugins/tree.ui.default/test/production_line_panel_test.dart:445-453`；
     mock 没有 `POST /tasks` 分支，`:136-194`）。
   - 插件 API 测试全部显式传 `id`，因此 STAB-PL-1 不会红。
   建议补一条“UI 真实提交体”契约测试，而不是只测渲染。
3. **默认值双份维护**
   角色默认工具/模型在 UI 与插件各一份（`create_production_line_dialog.dart:65-80`
   vs `execution_service.dart:34-38`），已经出现“主控只在一边”的漂移。
   建议由插件在 `production.line.get` / 模板接口下发角色默认值，UI 只渲染。
4. **产线工作空间不是 UI 一等作用域**
   文件窗只认 Agent workspace（STAB-PL-5）；产物、审计、写域都围绕产线目录，
   但浏览入口仍绕在 Agent 上。
5. **新增面未接入设计令牌**
   产线面板的圆角（STAB-PL-7）、角色默认值、下拉选项都存在“就地硬编码”。
6. **“兜底值”被持久化成了“声明值”**
   思考档位（STAB-PL-9）与产线模型（STAB-PL-3）是同一个模式：
   UI 为了让控件不空，拿系统兜底填进去；一旦提交就变成用户配置，
   下一轮读取时无法区分“端点声明”与“系统猜的”。
7. **一个字段承担三种身份**
   `model_id` 同时是配置键、REST 路径、Agent 绑定和端点模型名（STAB-PL-8）。
   任何“同一模型多端点”的需求都会撞上身份冲突，靠文案无法真正解决。

---

## 4. 建议执行顺序（拍板后）

| 顺序 | 切片 | 类型 | 改动面 | 门禁 |
| --- | --- | --- | --- | --- |
| 1 | STAB-PL-1 后端自动生成任务 id | 缺陷 | `tree.production.line/store.dart` + 测试 | analyze 0；插件单测；UI 建任务用例 |
| 2 | STAB-PL-3 UI 默认取池 + 存量失效提示 | 缺陷 | `create_production_line_dialog.dart` + 测试 | analyze 0；UI 单测；池空/失效两态 |
| 3 | STAB-PL-9-A/C 档位默认空 + 不显示假选项 | 缺陷 | `domain_settings.dart` / `settings_page.dart` / `model_pool.dart` + 测试 | analyze 0；UI + 插件单测；YAML 不含兜底 |
| 4 | STAB-PL-5-C 空态文案与产物入口 | 兜底 | `main_page.dart` / 工作台 | analyze 0；UI 单测 |
| 5 | STAB-PL-4 空 Agent 空态 | 缺陷 | `model_info_panel.dart` / `main_page.dart` | analyze 0；UI 单测 |
| 6 | STAB-PL-7 圆角令牌 | 视觉 | `production_line_panel.dart` | analyze 0；真机深/浅 |
| 7 | STAB-PL-8-C 409 文案 + 列表按显示名分组 | 兜底 | `delegate.dart` / `settings_page.dart` | analyze 0；UI 单测；不改存储 |
| 8 | STAB-PL-2 空写域语义 | **需拍板** | 插件 + UI + 用例 | 全链路：建→包→跑→并行/禁区 |
| 9 | STAB-PL-6 按角色配工具 | **需拍板** | 配置页 + 角色默认值下发 | 三角色配置 + 非法组合 fail-closed |
| — | STAB-PL-8-A 模型池身份拆分 | **下一迭代** | 存储 + 迁移 + 全链路绑定 | 旧配置零迁移；多端点并存 |
| — | STAB-PL-9-B/D 草稿探测 / 覆盖面板 | **需拍板** | 新增探测接口或自动探测 | 探测成功才显示档位 |

执行约束：每个切片独立提交、独立门禁；稳定性阶段不夹带新能力。
涉及 UI 的切片需跑 `flutter analyze lib` + `flutter test`（受影响用例）；
涉及插件需跑 `dart analyze` + 单测 + `--selftest`。
STAB-PL-9-A 会改 `docs/pluginization/agent_api_contract.md` 与现有测试口径，需同批更新。

---

## 5. 拍板结果（2026-11-12）

| ID | 用户拍板 | 落地口径 |
| --- | --- | --- |
| D1 | 后端（插件） | `production.task.create` 在 `id` 为空时生成 `T<millis>`（与 `prepare.intake` 同口径）；UI 不下发 id。 |
| D2 | 等于工作根 | 空 `write_scope` 归一为 `['**']`；打包、执行、派发计划三处同一判据；任务详情回显 `**`，并明示“等于不限制范围（禁区仍拦）”。 |
| D3 | 好 | 按推荐：**不新增**独立 `agent.model.exists` 点位；模型存在性由 provider 模型缓存 + UI 过滤保证，`agent.worker.run` 仍保留兜底。 |
| D4 | 产线作用域 | 文件窗新增“产线工作空间”作用域：选中产线时按 `line.workspace_dir` 浏览；未选产线才回落到 Agent 工作空间。 |
| D5 | 未选 Agent 但选了 production line，production line 也要模型配置 | 产线角色模型配置完全独立于 Agent：未选 Agent 时，产线配置页/工作台仍能加载 provider/模型池并配置四角色；“模型信息”窗在产线上下文下以产线角色为目标，而不是强制先选 Agent。 |
| D6 | 本期做 | PL-6 按角色配置本期落地；`orchestrator`（主控）保留并接线——先接“模型/工具配置 + 准备阶段消费”，完整的“继续/重试/询问/停止”决策循环单列切片，避免语义未定就硬塞。 |
| D7 | `provider/model_id`，新增 provider 池 | 见 §5.1；模型身份、去重、URL/密钥、自动拉取与缓存全部按 provider 层重建；旧配置与旧 Agent 绑定零迁移可用。 |
| D8 | 按 D7 的回复做 | 思考档位只来自 provider 模型缓存或用户显式值；未声明时不落盘、不展示 `low/high/max` 假选项。 |

**阶段口径**：用户明确“稳定迭代不等于停滞”——不做大模块迁移，但该补的功能、语义与遗留项照做。
D7 是新增加的一层（provider），不是把 tree.agent 拆走；旧 `config/models/*.yaml` 原地可读。

---

### 5.1 D7：Provider 池与模型池落地设计

#### 5.1.1 身份与去重

- 模型唯一键：`provider_id/model_id`（例：`deepseek/deepseek-v4.1-flash`）。
- `provider_id`：由 provider 显示名 slug 生成，稳定不可改；冲突加 `-2` 后缀。
- `model_id`：端点请求里的 `model` 字段，允许跨 provider 重复。
- 显示名 `name`：用户可见标签，允许重复（同一模型多别名不做硬唯一，避免再挡住用户）。
- 旧的裸 `model_id` 作为兼容别名：解析顺序 `provider/model_id` 全等 → 裸 `model_id` 唯一匹配 → 报“绑定有歧义，请重新选择”。

#### 5.1.2 Provider 配置（`config/providers/<provider_id>.yaml`）

```yaml
id: deepseek
name: DeepSeek 官方
base_url: https://api.deepseek.com/v1
api_key: ''                 # 与 api_key_env 二选一；明文只在本插件进程内
api_key_env: DEEPSEEK_API_KEY   # 非空时优先读环境变量
protocol: openai            # v1 只支持 openai
enabled: true
created_at: '...'
updated_at: '...'
```

- `api_key_env` 非空时优先读 `Platform.environment[...]`；读不到再回落到 `api_key`。
- 与现有模型 YAML 一样，api_key 只写盘、不回显；前端只拿 `has_api_key` / `api_key_env`。
- `base_url` 统一去尾 `/`；请求时拼 `/models` / `/chat/completions`。

#### 5.1.3 Provider 模型缓存（`config/provider_models/<provider_id>.json`）

```json
{
  "provider_id": "deepseek",
  "fetched_at": "...",
  "error": "",
  "models": [
    {
      "model_id": "deepseek-v4.1-flash",
      "name": "DeepSeek V4.1 Flash",
      "context_length": 131072,
      "max_output_tokens": 8192,
      "input_modalities": ["text", "image"],
      "output_modalities": ["text"],
      "reasoning_effort_options": ["low", "high"],
      "pricing": {"prompt_per_million": 0.1, "completion_per_million": 0.2, "currency": "USD"}
    }
  ]
}
```

- 新增 provider 成功即自动 `GET {base_url}/models` 拉取并缓存；失败只记 `error`，不阻断 provider 保存。
- `POST /api/providers/{id}/refresh` 手动刷新；模型池点“添加模型”时先刷新一次（失败则用旧缓存 + 可读提示）。
- 端点没声明的字段留空（不是兜底值）：`context_length` / `max_output_tokens` / 模态 / 思考档位都允许为空。
- 模态解析兼容 `architecture.input_modalities` / `output_modalities`、`capabilities`、`supports_vision` 等常见声明；解析不到就由用户手改。

#### 5.1.4 模型条目（`config/models/<provider>__<model>.yaml`）

```yaml
provider: deepseek
model_id: deepseek-v4.1-flash
name: DeepSeek V4.1 Flash
kind: chat
protocol: openai
if_vision: true
if_audio: false
if_video: false
reasoning_effort: ''
reasoning_effort_options: []   # 只存端点声明或用户显式值
max_seqlen: 131072
max_output_tokens: 8192
base_url: ''                   # 可选覆盖 provider
api_key: ''                    # 可选覆盖 provider
```

- `kind` 默认 `chat`；缓存能推断时自动填（id 含 `embed` → `embedding`；provider 声明类型则映射），用户可改；创建后按 MP-2 不可改。
- `if_vision/if_audio/if_video` 来自缓存自动填充，用户可改；未知就是 `false`，不假装支持。
- 旧文件没有 `provider`：读作 `legacy/<model_id>`，用原 `base_url` 合成一个 `legacy` provider；**不移动文件、不改 Agent 绑定**，编辑保存时才补 `provider` 键。

#### 5.1.5 API（tree.agent 委派）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET/POST | `/api/providers` | 列表 / 新增（新增后自动 refresh） |
| GET/PATCH/DELETE | `/api/providers/{providerId}` | 详情 / 改名与换密钥 / 删除（有模型绑定时拒绝，回 `bound_models`） |
| POST | `/api/providers/{providerId}/refresh` | 拉取 `/models` 并写缓存 |
| GET | `/api/providers/{providerId}/models` | 返回缓存条目 |
| GET | `/api/models` | 每项新增 `provider`、`key`（`provider/model_id`），旧字段保留 |
| POST | `/api/models` | 接受 `provider` + `model_id`；缺 provider 走 legacy 兼容 |
| POST/GET | `/api/models/{key}/meta` | key 用 URL 编码的 `provider/model_id`；裸 id 仍可解析 |

#### 5.1.6 UI（设置 → 模型池）

1. 上半区 Provider 卡片：名称、base_url、密钥状态、`api_key_env`、启用开关、模型数、上次拉取时间/错误；按钮「编辑 / 刷新 / 删除」。
2. 下半区模型列表按 provider 分组；每行显示 `provider/model_id`、显示名、kind、模态徽标、上下文/输出、思考档位来源。
3. 「添加模型」：选 provider → 自动刷新一次 → 搜索/下拉缓存里的 `model_id` → 自动填 name/kind/模态/上下文/输出/思考档位 → 用户可改 → 保存。
4. 「编辑模型」：provider 与 model_id 创建后不可改；其余可改；思考档位只列缓存声明或已存值，没有就只留「不设置」。
5. 未选 Agent 时，产线配置页仍可直接用 provider/模型池（D5）。

#### 5.1.7 兼容与迁移

- 旧 `config/models/<model_id>.yaml` 继续读；新文件用 `<provider>__<model>.yaml`，以避免跨 provider 同名冲突。
- 旧 Agent/产线绑定写的是裸 `model_id`：解析时先找精确 `provider/model_id`，找不到再按裸 id 唯一匹配；新绑定写 `provider/model_id`。
- 旧 `model_meta.json` 键是裸 id：读取时兜底；新探测缓存键改 `provider/model_id`。
- 不批量改写用户文件；只在编辑保存时补新键。

#### 5.1.8 切片

| 切片 | 内容 | 门禁 |
| --- | --- | --- |
| D7-1 | Provider 数据模型 + 文件读写 + 模型缓存 + legacy 兼容 | `dart analyze` 0；domain_settings/provider 单测 |
| D7-2 | Provider REST + `/api/models` 扩展 + refresh + 契约文档 | 路由契约测试；`--selftest` |
| D7-3 | LLM 请求解析 provider（base_url/env key），保留模型级覆盖 | tree.agent 单测；worker/agent 回归 |
| D7-4 | UI Provider 池 + 模型池改造 + 添加模型自动拉取/填充（D8 同批） | `flutter analyze lib` 0；UI 单测 |
| D7-5 | 迁移/兼容回归：旧 models、旧绑定、旧 meta 缓存 | 真机清单 + 旧数据副本回归 |

**落地进度（2026-11-12）**：D7-1~D7-5 已完成（数据层 / REST / LLM 解析 / UI 与 D8 /
真机数据副本回归）。实现偏差（以代码为准）：

- 旧模型读作 `provider: legacy`，但**不合成** `legacy` provider 条目（不写文件、不参与 CRUD）；
- 元数据缓存键：旧模型继续用裸 `model_id`（不制造 `legacy/xxx` 重复缓存），
  provider 模型用 `provider/model_id`；读取侧两键都兜底；
- 模型文件：旧文件仍在原地写回（`storageFile` 记住原路径），新文件 `<provider>__<model>.yaml`
  （`model_id` 内非法文件名字符换成 `_`）；
- 绑定 id：`legacy` / 无 provider 的模型继续写裸 `model_id`，真 provider 模型写
  `provider/model_id`（两者解析等价，旧绑定零迁移）。

### 5.2 D4/D5/D6 落地（2026-11-12）

| 切片 | 落地 |
| --- | --- |
| D4 产线文件作用域 | files 插件新增 `line:<lineId>` workspace：`WorkspaceResolver` 先找 `production_lines/production/<id>/line.yaml`，再逐个旧团队目录兜底；根 = `workspace_dir`（必须绝对路径），不吃 Agent SSH。`main_page` 在「生产线」页选中产线时把文件窗 workspaceId 切成 `line:<id>`，未选/切回 Agent 页回落 `_selectedAgent.workspaceId`；产线没配目录显示空态。 |
| D5 产线模型配置不依赖 Agent | 右栏「模型信息」在产线上下文改用 `ProductionLineModelInfoPanel`：读全局 `GET /api/models`（不需要 Agent），逐角色显示模型 / provider / 模态 / 上下文 / 输出 / 工具 / 专家开关与上限，失效模型标红。`llm.call` 新增显式 `model_id`（模型池键）；给了它时不再要求 agent 存在，准备阶段因此可脱离 Agent 运行。 |
| D6 按角色配工具 + 主控接线 | 配置页四张角色卡：各自模型下拉 + 白名单工具 chips（`orchestrator` 读/列表/搜索/协作；`packer` 读/列表/搜索/命令/协作；`executor` 全量；`expert` 只读/列表/搜索），执行必须含 `write`/`edit`；专家暴露 `enabled` + `max_per_task`；存量非法工具在卡内如实提示、保存时剔除。`kRoleDefaultTools` 补 `orchestrator`。`PreparationService` 用 `roles.orchestrator.model_id` 调 `production.recon` / `production.scope`，并把主控工具写进侦查提示词。完整“继续/重试/询问/停止”决策循环仍单列下一片。 |

验证：production.line analyze 0 / 单测 123 / 自检 111（自检产线补角色模型，适配 D7 默认留空）；
files analyze 0 / 单测 12（新增 2 条）/ 自检 44；tree.agent analyze 0 / 单测 516 / 自检 225；
UI `flutter analyze lib` 0 / 产线相关用例 21（文件窗作用域、四角色卡、专家开关、模型信息、失效模型与空态）。

**D7-5 兼容回归（真机数据副本）**：把 `%APPDATA%/Tree` 的 `config/models`（3 个旧文件）、
`config/model_meta.json`、`agents/*.yaml` 复制到临时根后：
3 个旧模型读作 `provider=legacy`，`base_url` 与密钥解析成功；7 个 Agent 的裸 `model_id`
绑定全部唯一解析到 `legacy/<id>`；空 meta 缓存走裸键兜底；不合成 `legacy` provider 条目；
`lfm3` 不在池中（按预期失效，UI 标红）。全程不写真实数据根。

---

## 6. 证据索引（截图 ↔ 代码）

| 截图 | 对应问题 | 关键代码 |
| --- | --- | --- |
| `production line 创建任务时失败.png` | STAB-PL-1 | `production_line_workbench.dart:223-233`；`store.dart:405-408` |
| `production line 留空则用产线的工作目录.png` | STAB-PL-2 | `production_line_workbench.dart:1008-1014`；`queue.dart:150-157`；`execution_service.dart:177-183` / `404-410` |
| `production line 模型无中生有…png` | STAB-PL-3 | `create_production_line_dialog.dart:65-80` / `412-419`；`models.dart:233-260` |
| `production line 模型页加载失败.png` | STAB-PL-4 | `main_page.dart:1858-1865`；`model_info_panel.dart:147-151`；`core_server.dart:544` |
| `production line 选择后为什么没法浏览文件.png` | STAB-PL-5 | `main_page.dart:1733-1739` / `1812-1831`；`plugins/files/lib/src/workspace.dart:79-145` |
| `production line 执行工具应针对每个角色单独选.png` | STAB-PL-6 | `create_production_line_dialog.dart:217-239` / `357-385`；`execution_service.dart:34-38` / `236` / `488` / `768` |
| `UI 没给圆角.png` | STAB-PL-7 | `production_line_panel.dart:302-315`；`agent_list_item.dart:43-49` |
| `模型池去重应以显示名而非模型id.png` | STAB-PL-8 | `domain_settings.dart:409-418` / `436-445`；`delegate.dart:563-576`；`llm_agent_engine.dart:301` |
| `思考模式设置应从 API 端点取.png` | STAB-PL-9 | `settings_page.dart:2366-2375` / `2526-2544` / `2580-2599`；`domain_settings.dart:54-73` / `127-145`；`model_pool.dart:95` / `235-241` |

> 截图由用户提供（`c:\Users\kada1\Desktop\hidden\`），不入库；本文只记录其与代码的对应关系。
