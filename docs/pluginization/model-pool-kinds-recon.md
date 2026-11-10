# 模型池 kind / protocol 扩展侦察与落档（MP 系列）

> **状态**：2026-11-08 侦察完成，**本期只落档，不实施**。
> **目标**：在现有模型池上加 `kind`（`chat` / `embedding` / `decision`）与 `protocol`，
> 支持 embedding 模型与 JEV 决策模型；供 docnorm 检索与 production line 决策点使用。
> **前置拍板**：上 embedding、模型库增加 JEV（[doc-normalization-recon.md](../doc-normalization-recon.md) D26/D33）。
> **本期出口**：schema、兼容策略、消费方矩阵、切片与验收冻结；不改代码。

---

## 1. 结论先行

1. **只做加法**：`kind` 缺省 = `chat`、`protocol` 缺省 = `openai`；旧 `config/models/*.yaml` 一字不改。
2. **三类模型协议不同，禁止串用**：`chat` 走现有 HTTP/SSE 工具循环；`embedding` 走 `/embeddings`；
   `decision`（JEV）走 typed questions，返回概率与置信度。
3. **选择器按 `kind` 过滤**：Agent / 产线打包 / 执行 / 专家只看到 `chat`；docnorm 只看到 `embedding`；
   产线主控可选 `decision`（没有就回退 `chat`）。
4. **`kind` 创建后不可改**：改类型等于换协议，直接删旧建新；避免已绑定消费方拿到不兼容模型。
5. **模型池仍归 `tree.agent`**：`GET/POST/PATCH/DELETE /api/models` 不搬家，只加字段与校验；
   不新增核心 REST 面。
6. **失败显式降级**：embedding 缺失 ⇒ docnorm 走 lexical 并标 `mode`；decision 缺失/置信度低 ⇒
   回退 chat 或问用户，并记 `decision_mode`。

---

## 2. 现状

| 事实 | 证据 | 影响 |
| --- | --- | --- |
| 模型配置字段只有 chat 面 | `plugins/tree.agent/lib/src/settings/domain_settings.dart:18-107`（`model_id/name/base_url/api_key/thinking/if_vision/reasoning_effort/max_seqlen/max_output_tokens/token_scale`） | 没有 `kind` / `protocol` / `dimensions` |
| 前端视图统一走 `toApiJson` | 同上 `:95-107`；`lib/src/model_catalog.dart:8-15` | 加字段只改一处投影 |
| 新增校验只要求三件套 | `domain_settings.dart:313-322`（model_id / base_url / api_key） | 无法阻止把 embedding 当 chat 选 |
| 模型池 REST 已存在 | `lib/src/delegate.dart:47`（`/api/models`）、`:60`（`/api/models/{modelId}`）、`:488-535` | 不需要新路由 |
| 设置页模型编辑器只有 chat 字段 | `plugins/tree.ui.default/lib/ui/pages/settings_page.dart:2207-2339` | 需要 kind 下拉与条件字段 |
| 创建 Agent 时列出全部模型 | `lib/ui/widgets/create_agent_dialog.dart:86-98`、`:356-392` | embedding/decision 会误入 chat 选择 |
| 模型信息面板同样列全部 | `lib/ui/widgets/model_info_panel.dart`（模型下拉） | 同样要过滤 |
| 团队/成员模型解析按 id 查池 | `lib/src/teammates.dart:30-47`、`:94` | 加 kind 后仍需按 chat 过滤 |

---

## 3. 目标 schema（只加不改）

```yaml
# chat（现有字段保持不变）
model_id: lfm3
name: LFM3
kind: chat                 # 缺省 chat
protocol: openai           # 缺省 openai
base_url: http://127.0.0.1:8000/v1
api_key: sk-...
thinking: false
if_vision: false
max_seqlen: 131072
max_output_tokens: 8192

# embedding（新增）
model_id: bge-m3
name: BGE-M3
kind: embedding
protocol: openai
base_url: http://127.0.0.1:8000/v1
api_key: sk-...
dimensions: 1024           # 必填；与端点返回维度必须一致
max_input_tokens: 8192

# decision（JEV）
model_id: jev
name: JEV (TypeSafe)
kind: decision
protocol: jev
base_url: https://api.jev.example/v1   # 或 OpenRouter / AIMLAPI 网关
api_key: sk-...
max_input_tokens: 262144   # 官方口径约 262k，接入时以实际为准
confidence_threshold: 0.7  # 低于阈值回退 chat/人工
# 单次请求问题数上限暂固定 16（DecisionClient.maxQuestions），配置化延后
```

规则：

- `kind ∈ {chat, embedding, decision}`；`protocol ∈ {openai, jev}`；
- `chat` 只允许 `protocol=openai`；`embedding` 只允许 `protocol=openai`（`/embeddings`）；
  `decision` 只允许 `protocol=jev`；
- `embedding` 必须有 `dimensions > 0`；`decision` 必须有 `confidence_threshold ∈ (0,1)`；
- `api_key` 继续只回 `has_api_key`，永不回显；
- 未知 `kind` / `protocol` ⇒ 400，不猜。

---

## 4. 两类新协议的最小契约

### 4.1 embedding（`protocol: openai`）

采用 OpenAI 兼容 `/embeddings`（本地或网关均可）：

```jsonc
// 请求
POST {base_url}/embeddings
{"model": "bge-m3", "input": ["文本 1", "文本 2"], "dimensions": 1024}

// 回包
{"data": [{"index": 0, "embedding": [0.01, -0.02, ...]}], "usage": {"prompt_tokens": 12}}
```

规则：

- `base_url` 与现有 chat 同一拼接口径（用户填到 `/v1` 为止，客户端只追加 `/embeddings`）；
- 单次 `input` 条数上限 64、单条字符上限按模型 `max_input_tokens` 估算，超限分批；
- 回包向量长度必须等于配置的 `dimensions`，不等 ⇒ **整批失败、不写索引**；
- 向量归一化由 docnorm 侧做（flat cosine），存储层只存原始 float 列表；
- 无 embedding 模型/调用失败 ⇒ `mode: lexical`，不阻塞 baseline。

### 4.2 JEV（`protocol: jev`）

JEV 是 **System One 决策模型**，不是 chat / embedding：

- 输入：一段 state（文本/结构化）+ 一组类型化问题；
- 问题原语：`noul`（是/否概率）、`choice`（选项 + 概率分布）、`score`（有序分值 + 分布）；
- 输出：每个问题的选中值/概率/置信度；**没有自然语言回答**；
- 接入：官方 API 或 OpenRouter / AIMLAPI 等网关；`base_url` 可配，`api_key` 走同一套脱敏；
- 客户端：独立 `DecisionClient`，**不得**复用 chat 的 SSE 工具循环；
- 低置信度：`confidence < confidence_threshold` ⇒ 不执行不可逆动作，回退 chat 或向用户提问；
- 用途：产线主控的“继续/重试/询问/停止”、工具/角色选择；docnorm 的冲突分级（可选）。

最小请求/回包示意（字段以实际接入网关为准）：

```jsonc
// 请求
{"state": "任务上下文 / 当前状态",
 "questions": {
   "route": {"type": "choice", "options": ["continue", "retry", "ask", "stop"]},
   "urgent": {"type": "noul"},
   "difficulty": {"type": "score", "levels": ["low", "mid", "high"]}}}

// 回包
{"answers": {
   "route": {"choice": "continue", "probabilities": {"continue": 0.72, "retry": 0.18, "ask": 0.08, "stop": 0.02}, "confidence": 0.83},
   "urgent": {"noul": 0.12},
   "difficulty": {"score": 2.1, "probabilities": {"low": 0.05, "mid": 0.35, "high": 0.60}, "confidence": 0.71}}}
```

外部事实（接入时复核）：JEV 上下文约 262k token；官方有 Decisions API 与 System One 两种面；
网关的请求/回包字段可能不同，需在 MP-6 用真实端点做契约测试并留一份录制回包作 fixture。

---

## 5. API 与兼容

| 端点 | 变更 |
| --- | --- |
| `GET /api/models` | 每条加 `kind` / `protocol` / `dimensions` / `max_input_tokens` / `confidence_threshold`（后两者可空）与 `has_api_key`（布尔，密钥永不出插件） |
| `POST /api/models` | 校验 `kind/protocol` 组合；embedding 校验 `dimensions`；decision 校验 `confidence_threshold` |
| `PATCH /api/models/{modelId}` | **`kind` / `protocol` 不可改**（仅新值 ≠ 旧值才 400；同值视为无变化）；其余字段可改；存量条目被手改成未知类型时 PATCH 也拒绝 |
| `DELETE /api/models/{modelId}` | 不拦截删除，返回 `bound_agents` 供 UI 提示；embedding/decision 的消费方不在 `agents/`，下次使用 fail-closed |
| `GET /api/agents/{id}/models-info` | `models[]` 保留全部并带 `kind`，由前端按用途过滤；后端不做隐式过滤 |

**绑定校验（后端，不靠前端）**：`POST /api/agents`、`PATCH /api/agents/{id}`、团队成员创建/改模型
都必须拒绝 `kind != chat` 的模型（400，说明“该模型是 embedding/decision，不能作为对话模型”）；
否则前端过滤只是摆设，REST 仍能把 Agent 绑到 embedding 上。

兼容策略：

- 旧 YAML 无 `kind` / `protocol` ⇒ 读取时补默认值，**不回写文件**；
- 旧 UI 忽略新字段；新 UI 对缺省值按 `chat` 显示；
- 删除模型时若被 embedding/decision 消费方引用，消费方在下次使用时 fail-closed 并给可读原因。

**实现陷阱（MP-1 必改四处）**：

1. `CoreModelConfig.merge()` 是**逐键白名单**（`domain_settings.dart:131-172`），新键不加进去会被静默忽略；
2. `withOverrides()` 用固定字段列表复制（`:188-203`），新字段不复制 ⇒ 成员级覆盖后 `kind` 丢失、回退成 `chat`；
3. `toJson` / `fromJson` / `toApiJson` 三处都要补，且 `toApiJson` 的默认值要与“旧文件缺省 chat”一致；
4. 核心里的 `CoreModelConfig` 是遗留（`packages/tree_core/lib/src/settings/file_settings_sink.dart:61` 明确核心不再装载模型池），**不要顺手改核心**，写者只有 `tree.agent`。

---

## 6. 消费方矩阵

| 消费方 | 允许 kind | 缺失/失败时 |
| --- | --- | --- |
| Agent 主模型 / 团队成员 | `chat` | 报“模型不可用” |
| 产线打包 / 执行 / 专家 | `chat` | 拒绝启动任务 |
| 产线主控（流程决策） | `decision`（可选） | 回退 `chat`，记 `decision_mode: chat` |
| docnorm 检索 | `embedding` | 退 lexical，标 `mode: lexical` |
| docnorm 冲突分级（可选） | `decision` | 回退 `chat` 或只报告 |
| 任何文本生成 | **禁止** `embedding` / `decision` | 直接拒绝 |

UI 落点：

- 设置页模型编辑器：`kind` 下拉 + 条件字段（embedding 显示 `dimensions`/`max_input_tokens`；
  decision 显示 `confidence_threshold`/`max_input_tokens`）；模型列表加 kind 徽标；
- 创建 Agent / 模型信息 / 产线模型配置：下拉只列 `chat`；
- 产线主控：单独一个「决策模型」下拉，只列 `decision`，允许留空（回退 chat）；
- docnorm 设置：一个「检索 embedding 模型」下拉，只列 `embedding`，允许留空（lexical）。

---

## 7. 切片（MP 系列）

| 切片 | 范围 | 验收 |
| --- | --- | --- |
| **MP-1 schema + 兼容** | `CoreModelConfig` 加 `kind/protocol/dimensions/max_input_tokens/confidence_threshold`；旧文件缺省补 chat | 旧模型读写字节不变；`toApiJson` 带默认值 |
| **MP-2 API 校验** | POST/PATCH 组合校验；kind/protocol 不可改；`/api/models` 投影；Agent/成员绑定拒绝非 chat | 非法组合 400；旧客户端仍可用 |
| **MP-3 设置页编辑器** | kind 下拉 + 条件字段 + 列表徽标 | 三类模型都能建/改；密钥不回显 |
| **MP-4 消费方过滤** | Agent / 团队成员 / 产线 chat 选择器只列 chat | 非 chat 不出现；强行绑定被拒 |
| **MP-5 embedding 客户端** | OpenAI `/embeddings` 客户端 + 维度校验 + 批量上限 | 维度不符报错；失败不污染索引 |
| **MP-6 JEV 客户端** | `DecisionClient`：noul/choice/score、置信度、超时、回退 | 低置信度不执行；网关字段差异有契约测试 |
| **MP-7 兼容性探测** | 模型能力探测（工具调用 / embedding 维度 / JEV 可用性） | 不支持时给可读降级，不空转 |

**MP-2~MP-7 实施记录（2026-11-08）**：`plugins/tree.agent` 已落地后端校验、两个客户端与 API 绑定约束。

- **MP-2**：`DomainSettings.validateModelKindFields` / `validateNewModel` / `validateModelChange`
  / `modelKindError` 成为唯一判据：`chat`/`embedding` 只能 `openai`、`decision` 只能 `jev`；
  embedding 必须 `dimensions>0`，decision 必须 `confidence_threshold∈(0,1)`；
  `POST /api/models` 按此校验，`PATCH /api/models/{id}` 拒绝改 `kind` / `protocol`（400）。
- **MP-4（后端）**：`POST /api/agents`、`PATCH /api/agents/{id}` 与团队成员 `assignModel`
  只接受 `kind=chat`，非 chat 一律 400 并说明"该模型是 embedding/decision，不能作为对话模型"；
  前端过滤不再承担安全职责。
- **MP-5**：`EmbeddingClient`（`lib/src/llm/embedding_client.dart`）走 OpenAI 兼容
  `/embeddings`：单批 ≤64 自动分批；单条超过 `max_input_tokens` 估算直接拒绝；
  向量长度必须等于配置 `dimensions`，不符整批失败（不返回半截）；HTTP/超时可读。
- **MP-6**：`DecisionClient`（`lib/src/llm/decision_client.dart`）走 JEV typed questions
  （`noul` / `choice` / `score`）：问题数 ≤16、空名/重名/选项不足被拒；回包解析概率与置信度
  （网关没给 confidence 时按概率推导）；低于模型阈值由 `DecisionResult.lowConfidence()` 标出，
  调用方据此回退 chat / 提问。
- **MP-7**：两个客户端都提供 `probe()`，返回 `{ok, dimensions|confidence}` 或
  `{ok:false, code, error}`，不支持时给可读降级。
- **MP-3（前端）**：设置页模型编辑器增加 `kind` 下拉、协议只读推导、条件字段
  （embedding：dimensions / max_input_tokens；decision：confidence_threshold /
  max_input_tokens）与列表 kind 徽标；编辑模式禁止改 kind/protocol。
- **MP-4（前端）**：创建 Agent、右栏模型信息、团队成员模型分配只列 `kind=chat`
  （旧数据缺 kind 视为 chat）。
- **自检遗留修正**：`models` / `models-info` 快照补 MP-1 新键；`conversations` 提问卡片补
  `preview` / `seq`；agents 列表在 `updatedAt` 同刻时按 id 升序（消除 Windows 扫描顺序导致的
  偶发换序，自检不再抖动）。
- 验证（截至 2026-11-08，`has_api_key` 与员工 kind 校验见下方追加记录）：tree.agent
  analyze 0、全量 **451/451**、`--selftest` **186/0**；
  `domain_settings_test` 9/9、`delegate_test`（含新增 3 条）、`team_service_test` 20/20、
  `embedding_client_test` 6/6、`decision_client_test` 6/6；UI `flutter analyze` 仅 7 条既有
  `thinking_window_test` 告警、`model_pool_test` 13/13、受影响组件 45/45；全量 UI 938 条中
  937 通过，唯一失败是既有版本常量 1.0.5 / pubspec 1.0.6 漂移（与本切片无关）。
- 集成预留：embedding/decision 目前是插件库能力；docnorm 的消费随 **DN-9** 的站点契约接入，
  MP 切片不伪接线。JEV 的真实网关录制回包 fixture 留到接入时补（当前用同契约 fake 端点测试）。

**2026-11-10 发版前审查追加**：

- `CoreModelConfig.toApiJson` 补 `has_api_key`（布尔）：此前前端按它判断“未配置密钥”，
  字段缺失导致所有模型都误显“未配置 API Key”。密钥原文仍永不出插件。
- `agent.worker.run` 增加 `kind=chat` 校验（`model_kind_invalid`）：产线打包 / 执行 / 专家
  不能再绑 embedding / decision；与 Agent、团队成员的后端校验对齐（MP-4）。
- `PATCH /api/models/{id}`：存量条目被手改成未知 `kind` / `protocol` 时，改其他字段也拒绝
  （不替用户猜）；`kind` / `protocol` 传同值视为无变化、放行。
- decision 的 `max_questions` 不做配置项（`DecisionClient` 固定 16）；schema 示例已移除。
- 新增测试：`has_api_key` 断言、员工 kind 拒绝、存量未知类型 PATCH 拒绝、
  元数据路由 GET/POST/PATCH/DELETE 错误分支与缓存清理。
- 当前基线：tree.agent 单测 **497/497**、自检 208/0（截至本次审查；后续变更以
  `docs/work-log.md` 为准）。



门禁沿用项目规则：`dart analyze`（无新增）→ 受影响包全量 `dart test` →
`tree_protocol` 访问控制 → 涉及 UI 才 `flutter`。

---

## 8. 验收判据

| 编号 | 判据 |
| --- | --- |
| TC-MP-01 | 旧 YAML 无 `kind` 时按 `chat` 工作，文件不被改写 |
| TC-MP-02 | `kind=embedding` 缺 `dimensions` ⇒ 400；`kind=decision` 缺 `confidence_threshold` ⇒ 400 |
| TC-MP-03 | `kind` / `protocol` 创建后 PATCH 修改 ⇒ 400 |
| TC-MP-04 | Agent 创建/模型信息下拉不含 embedding/decision |
| TC-MP-05 | 产线打包/执行下拉不含 embedding/decision；主控只列 decision |
| TC-MP-06 | embedding 维度与端点返回不一致 ⇒ 报错且不写向量 |
| TC-MP-07 | JEV 置信度低于阈值 ⇒ 不执行动作，回退 chat/人工并记 `decision_mode` |
| TC-MP-08 | JEV 网关字段差异由契约测试覆盖（真实/录制回包） |
| TC-MP-09 | 删除被 docnorm 使用的 embedding 模型后，下次检索 fail-closed 并给可读原因 |
| TC-MP-10 | 模型池列表与 `models-info` 都带 `kind`，密钥仍然只回 `has_api_key` |
| TC-MP-11 | 绕过前端直接 `POST/PATCH /api/agents` 绑定 embedding/decision ⇒ 400 |
| TC-MP-12 | JEV 录制回包 fixture 通过 `DecisionClient` 契约测试；字段漂移时给出可读错误 |
| TC-MP-13 | 成员级参数覆盖后 `kind/protocol` 仍保留（`withOverrides` 不丢字段） |

---

## 9. 风险与待拍板

| 项 | 推荐 | 说明 |
| --- | --- | --- |
| JEV 接入方式 | 先走 **OpenRouter/AIMLAPI 网关**，再评估官方直连 | 网关字段更接近 OpenAI 生态，契约测试成本低 |
| `kind` 是否可改 | **不可改** | 换类型等于换协议，旧绑定会拿到不兼容模型 |
| embedding 维度来源 | **手填 + 首次调用校验** | 不自动探测，避免启动即发请求 |
| 低置信度阈值 | 默认 **0.7**，可按模型覆盖 | 太高会频繁回退，太低会误决策 |
| decision 用途边界 | 只做**流程决策**，不做内容生成 | 防止把 JEV 当 chat 用 |
| 模型池归属 | 继续留在 `tree.agent` | 不新增核心面；设置页只是 UI |

---

## 10. 证据索引

- 模型配置与投影：`plugins/tree.agent/lib/src/settings/domain_settings.dart:18-107`、`:95-107`
- 新增校验：`domain_settings.dart:286-322`
- 模型池路由：`plugins/tree.agent/lib/src/delegate.dart:47`、`:60`、`:488-535`、`:1123`、`:1168-1171`
- 前端模型编辑器：`plugins/tree.ui.default/lib/ui/pages/settings_page.dart:2207-2339`
- 创建 Agent 的模型下拉：`lib/ui/widgets/create_agent_dialog.dart:86-98`、`:356-392`
- 模型信息面板：`lib/ui/widgets/model_info_panel.dart`（模型下拉与保存）
- 团队成员模型解析：`plugins/tree.agent/lib/src/teammates.dart:30-47`、`:94`
- 模型池拍板：`docs/doc-normalization-recon.md` D26 / D33
- 车道记录：[project-status.md](../project-status.md) 车道 J
