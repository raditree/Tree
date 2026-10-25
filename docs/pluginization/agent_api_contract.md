# Agent 面 REST 契约逐条对照表（G-1 前置产物）

> **状态**：2026-10-25 建立。对应台账 L-19（对照表本身）**已闭环**；L-01（插件侧逐条实现与等价验收）**仍未开始**。
> **定位**：把 [agent_pluginization.md](agent_pluginization.md) §1.2 的 **36 条**（34 存量 + 2 条上行改委派新增）逐条钉成契约：方法、路径、请求、成功/失败回包、副作用与已知缺口。迁移时**以本表为功能等价基线**（§5 清单），插件侧任何一条行为不同都算交接失败。
>
> **范围**：§1.1 的 17 条 + §1.2 的 17 条 = **34 条存量**，加 §1.2 表 1-2 的 **2 条新增** = G-1 的 36 条。§1.2 还多列了 **2 条 spec 端点**（#18/#19），它们归 `spec` 插件（批次 C）、**不属 G-1**；列在这里是因为它们与 agent 面共用数据层与错误口径，拆成两份文档更易漂。
> **数据源**：`packages/tree_core/lib/src/server/core_server.dart` 的 `_registerRoutes()` 与各 handler；路径常量逐字取自 `packages/tree_protocol/lib/src/api_paths.dart`；字段形状来自 handler 写出的 JSON 与 `toApiJson` / `toJson` 等。**未凭记忆补字段**。
> **行号口径**：以 2026-10-25 提交 `33f8115` 的工作树为准（`core_server.dart`）。此后该文件有改动时行号会漂，定位以"处理函数名"为准（行号只作辅助）。
> **姊妹文档**：[ui-pluginization.md](ui-pluginization.md)（核心收束）、[agent_pluginization.md](agent_pluginization.md)（迁移计划）、[ui-pluginization_acceptance.md](ui-pluginization_acceptance.md)（验收）。

---

## 0. 全局约定（36 条全部适用）

1. **鉴权**：只认 `Authorization: Bearer <主 token>`（`token_registry.dart` 的 `resolveAuthorization`）。缺失/格式不对/过期 ⇒ `401 {"detail":"本地 token 无效或已过期"}`（`core_server.dart:1498-1505`）；引导会话 token 对这批路由一律 `403 {"detail":"引导会话 token 只放行插件端点与 GET /api/meta"}`（`1507-1520`）。
2. **错误体是 `{"detail":"<可读中文>"}`**（`http_io.dart:134` 的 `errorBody`），**不是** `{ok:false,error}`。未捕获异常由 `_dispatch` 兜底 ⇒ `500 {"detail":"核心进程内部错误：…"}`（`1464-1475`）；未匹配路径 ⇒ `404 {"detail":"未知接口：<path>"}`（`1547-1549`）。
3. **另一种错误体只属于委派传输层**：插件承接的路由在"插件不可用 / 超时 / 回包非法"时回 `{"ok":false,"error":"service_unavailable|gateway_timeout|bad_gateway","plugin_id":…,"reason":…}`（`_writeDelegateError` 4679-4692、错误码映射 4694-4698）；插件自己的回包原样透传（`4367`）。**两条新增端点（本文 §1.3）属于这一类。**
4. **成功一律 200**（没有 201），`content-type: application/json; charset=utf-8`。
5. **非法 JSON body 有两种口径**（代码现状，文档原先未写）：只有 `POST …/compact` 走 `_jsonBody` ⇒ `400 {"detail":"请求体非法：…"}`；其余处理器直接 `readJsonBody`，`FormatException` 未被捕获 ⇒ 全局兜底 **500**。字段类型不符（`as` 强转失败）同样是 **500**。见 C-02/C-03。
6. **路由查表顺序**：已实现 router → 委派归属表 → 501 桩 → 404。`CoreServer.stubApiPaths` 为空集（`190`、`2064-2073`），所以"未实现且无插件申报"的路径今天是 `404`，不是 501。
7. **迁移状态**：34 条存量仍在 `ApiPaths.pendingHandoffRoutes`（"此刻仍由核心实现、待交接"）；2 条新增只在 `ApiPaths.delegated`（核心未注册，今天请求是 404）。
8. **分页**：只有 `GET /api/conversations/{agentId}` 分页；其余列表端点（sessions / questions / specs / tools.running / subagents）都是一次性返回。
9. **时间字段两种口径**：agent / 成员 / 会话的 `created_at`/`updated_at` 是**毫秒整数**；消息与子 agent 的 `timestamp`/`created_at` 是 **ISO-8601 字符串**（`JsonTime.encode`）。逐字段见样例。
10. **路径占位符**：由 `CoreRouter` 的 `{name}` 提取，已按 `Uri.pathSegments` 解码一次。**同名占位符重复时后者覆盖前者**——`ApiPaths.teammateLog` 的模板就是两个 `{memberId}`（见 C-04）。
11. **双跑期路由申报（2026-10-25）**：插件在 A2~A4 必须先申报、后交接。与核心**当前已实现**路由同键的申报**接受并标 shadowed**（进入归属表与 `/api/meta.routes`，HTTP 仍由核心 router 承接；核心删除该实现后自动生效）；只有 `coreOwned` / 保留前缀整段拒收。等价验证走 `packages/tree_core/tool/verify_agent_equivalence.dart`（同一数据根：核心 HTTP vs 插件 `api/delegate`，比状态码 / Content-Type / body 字节）。

---

## 1. 逐条对照表

### 1.1 agent 定义 / 子 agent / 团队 / 模型池（17 条）

| 组 | # | 方法 | 路径 | 处理函数:行号 | 请求 | 成功回包 | 失败 | 备注 |
|---|---|---|---|---|---|---|---|---|
| agent 定义 | 1 | GET | `/api/agents` | `_listAgents:2349`（注册 2076） | path 无 · query 无 · body 无（第 2 参为 `_`，完全不读 query） | `200` `{"agents":[AgentApi]}`<br>AgentApi 22 键：`id`, `name`, `type`（常量 `'normal'`）, `system_prompt`, `model_id`, `workspace_id`, `workspace_dir`, `has_ssh`(bool), `last_message`(string), `last_message_time`(int 毫秒 或 null), `unread_count`(恒 0), `avatar_url`(恒 null), `pending_member_count`(int), `team_id`, `parent_agent_id`, `level`(int), `role`, `duty`, `can_lead_team`(bool), `review_status`, `created_at`, `updated_at`（后两者是**毫秒整数**，不是 ISO 串） | `401` `{detail}`<br>`403` `{detail}`<br>`500` `{detail}`<br>（本端点自身无 404） | 只读；**无分页**；排序 = `updatedAt` 降序（file_store.dart:73-74）；每项额外做一次 `lastTextMessage` 与 `pendingMemberCountFor`（未接团队服务 ⇒ 0）；**不返回 ssh 详情**，只有 `has_ssh` |
| agent 定义 | 2 | POST | `/api/agents` | `_createAgent:2367`（注册 2077） | body：`name`（必填/string/trim 后非空）· `model_id`（必填/string/须已存在于模型池）· `system_prompt`（可选/string/默认 `''`）· `team_member_count`（可选/num→int/默认 0）· `max_level`（可选/归一：≤0→3、>5→5）· `max_members_per_level`（可选/≤0→7、>100→100）。**不能**指定 `team_id`/`parent_agent_id`/`level`/`role` | `200` `{"success":true,"agent":AgentApi}`<br>新 agent 取值：`last_message`=`''`、`last_message_time`=null、`unread_count`=0、`pending_member_count`=0、`has_ssh`=false、`team_id`=`''`、`level`=0、`role`=`''`、`duty`=`''`、`review_status`=`''` | `400` `{"detail":"name 不能为空"}` / `{"detail":"model_id 不能为空"}` / `{"detail":"模型不存在：<modelId>"}`<br>`500`（非法 JSON、类型不符）<br>`401` / `403` | 写；落盘 `agents/<id>.yaml` + 建默认会话 `session_default`（file_store.dart:98-127）；**不推送 WS 事件**；不预建任何站点（注释 2391-2392） |
| agent 定义 | 3 | GET | `/api/agents/{agentId}` | `_getAgent:2399`（注册 2078） | path `agentId` · query 无 · body 无 | `200` `{"agent":AgentApi,"ssh":{...}}`<br>`ssh` 仅在已配置时出现：`host`, `port`, `username`, `auth`（`'password'`/`'key'`/`'none'`）, `root`(条件), `login_shell`(条件), `key_path`(条件) | `404` `{"detail":"agent 不存在"}`<br>`401` / `403` / `500` | 只读；**绝不回显 password / key_passphrase**（`_sshView` 2636-2639 + `redacted()` ssh_config.dart:106-115）；未做"必须是真 agent"校验：传 `sub_…` 也能查到（SubagentStore.agent 返回其运行配置快照） |
| agent 定义 | 4 | PATCH | `/api/agents/{agentId}` | `_updateAgent:2416`（注册 2079） | path `agentId`；body 全部可选（键缺省=不改）：`model_id`（非空且须在模型池；**空串=不改**⇒无法清空模型）· `system_prompt`（键在即覆盖，可 `''`）· `workspace_dir`（须绝对路径或 `''`；`''`=用默认工作空间）· `ssh`（object 或 null；null=清除；object 需 `host`，`password` 缺键=保留、`''`=清空，`password` 与 `key_path` 不能都空）· `clear_model_overrides`（true ⇒ 四项覆盖一次清空）· `reasoning_effort`（string）· `max_seqlen`（正整数 或 null）· `max_output_tokens`（正整数 或 null）· `compress_threshold`（0.1~0.95 或 null）· `thinking`（bool 或 null） | `200` `{"success":true,"agent":AgentApi,"ssh":{...}}`<br>`ssh` 仅在最终有配置时出现；其余键同第 1 条 | `400` 共 10 种：`模型不存在：<id>` / `workspace_dir 必须是绝对路径或空串（空 = 用默认工作空间）` / `ssh.host 不能为空` / `SSH 需要 password 或 key_path 之一` / `ssh 必须是对象或 null` / `max_seqlen 必须为正整数，或 null 清除该项覆盖` / `max_output_tokens 必须为正整数，或 null 清除该项覆盖` / `compress_threshold 必须在 0.1~0.95 之间，或 null 清除该项覆盖` / `thinking 必须是 true / false，或 null 清除该项覆盖`<br>`404` `{"detail":"agent 不存在"}`<br>`500` / `401` / `403` | 写；**不能改** `name`/`team_id`/`parent_agent_id`/`level`/`review_status`/`role`；`store.updateAgent` **无条件重写 yaml 并 bump updatedAt**（空 body 也写）；`workspace_dir` 变更 ⇒ `_syncWorkspaceMirrors()` 把共享目录镜像进成员 yaml（落盘，失败只记 errorLog，2629-2631）；按 2026-10-04 断言**不重建**已钉住的系统提示词（只写日志，2438-2445）；**无 WS 事件** |
| agent 定义 | 5 | DELETE | `/api/agents/{agentId}` | `_deleteAgent:2660`（注册 2080） | path `agentId`；query `cascade`（可选；只有 `'1'` 或 `'true'` 生效，缺省 false）；body 无 | `200` `{"success":true,"removed":["<id>",...],"cascade":bool}` + `questions_removed`（仅当 >0）<br>`removed` 为**叶→根**顺序、含自身 | `404` `{"detail":"agent 不存在"}`<br>`409` 有下级未级联：`{"detail","error","cascade_required":[{"member_id","name","level","parent_agent_id"}],"hint"}`<br>`409` 运行中（`_busyBody` 2758-2765）：`{"detail":"agent 正在运行，不能删除","error":"...","running":["<id>"],"hint":"..."}`<br>`401` / `403` / `500` | 写；**无分页**；通过闸门后顺序：停（作废排队任务+收尾在途提问）→ `store.flush` → 取消并删提问记录 → 叶→根删 → 回填存活 TOP 的 `team_member_count` → 再 flush；落盘删 `agents/<id>.yaml` 与 `data/<id>/`（**workspace 目录不动**）；**广播 `agent_status` idle 帧**（经 `_stopAgentTree` 2975-2986，`own_running:false`）；两个 409 分支都不改任何东西 |
| agent 定义 | 6 | GET | `/api/agents/{agentId}/models-info` | `_agentModelsInfo:2767`（注册 2081） | path `agentId` · query 无 · body 无 | `200` `{"agent":{"id","model_id","system_prompt"},"models":[ModelApi],"overrides":{...}}`<br>ModelApi 11 键：`model_id`, `name`（空则回落 `model_id`）, `base_url`（**脱敏**为 协议+host[:port]）, `thinking`, `if_vision`, `reasoning_effort`, `reasoning_effort_options`(string[]), `max_seqlen`, `max_output_tokens`, `token_scale`(double), `longest_session_tokens`(int)<br>`overrides` 只含真正设置过的键：`reasoning_effort` / `max_seqlen` / `max_output_tokens` / `compress_threshold` / `thinking` | `404` `{"detail":"agent 不存在"}`<br>`401` / `403` / `500` | 只读；`models` 按 `model_id` 升序（core_settings.dart:438-446）；**无 api_key**；此端点**外发 system_prompt**（与列表接口不同）；`overrides` 口径见 team_model.dart:45-56 |
| agent 定义 | 7 | GET | `/api/agents/{agentId}/todos` | `_agentTodos:2792`（注册 2082） | path `agentId`；query `session_id`（可选/string/默认 `'session_default'`，即 `TreeStore.defaultSessionId`）；body 无 | `200` `{"todos":[{"id","content","status","progress","updated_at"}],"session_id"}`<br>`status` ∈ `pending` / `in_progress` / `completed` / `blocked`（非法回落 `pending`）；`progress` 0~100；`updated_at` 毫秒 int（手写 markdown 缺元数据时为 0） | `404` `{"detail":"agent 不存在"}`<br>`401` / `403` / `500` | 只读；**无分页**；数据源 `data/<agentId>/<sessionId>/todos.md`（FileTodoStore，读不到 ⇒ 空数组）；未接线 `todoStore` 时用 MemoryTodoStore（进程内、重启即空）；写入方是 `set_todo_list` 工具，与读端同一份数据 |
| 子 agent | 8 | GET | `/api/agents/{agentId}/subagents` | `_agentSubagents:2821`（注册 2083） | path `agentId`；query `session_id`（可选/默认 `'session_default'`）；body 无 | `200` `{"agent_id","session_id","total":int,"subagents":[...]}`<br>元素 10 键：`id`, `name`, `owner_agent_id`, `session_id`, `parent_id`, `level`, `scope`, `run_count`, `created_at`, `updated_at`（时间字段是 **ISO-8601 字符串**，经 `JsonTime.encode`，**不是毫秒 int**） | `404` `{"detail":"agent 不存在"}`<br>`401` / `403` / `500` | 只读；`total` 只是数组长度（**无分页**）；读 `data/<agentId>/<sessionId>/subagents.json`；**不含** subagent 的 agent 配置快照；跨会话不保留（查别的会话通常得空表） |
| 子 agent | 9 | GET | `/api/agents/{agentId}/subagents/{subagentId}/transcript` | `_agentSubagentTranscript:2856`（注册 2084-2088） | path `agentId`, `subagentId`；query `session_id`（可选/默认 `'session_default'`）；body 无 | `200` `{"agent_id","subagent_id","session_id","total":int,"messages":[MessageJson]}`<br>MessageJson 固定 16 键：`id`, `agent_id`, `session_id`, `role`, `content`, `timestamp`（ISO 串）, `kind`, `tool_name`, `tool_arguments`(obj 或 null), `tool_result`(string), `tool_call_id`, `usage`(obj 或 null), `attachments`(array 或 null), `options`(string[]), `answered`(bool), `is_streaming`(恒 false)<br>条件键：`tool_arguments_raw` / `tool_result_for_model` / `questions` / `llm_hidden` / `subagent_id` / `subagent_name` / `subagent_parent_id` / `subagent_level`；`kind == 'ask_user_question'` 时叠加 `answered` / `answer` / `questions` / `answers` / `options` | `404` `{"detail":"agent 不存在"}`<br>`404` `{"detail":"临时员工不存在：<subagentId>"}`（`subagents` 未接线也走这条）<br>`404` `{"detail":"临时员工「<name>」属于会话 <sid>，不在这个会话（<sid>）里——跨会话不保留是硬不变量。"}`<br>`401` / `403` / `500` | 只读；`total` 为**全量条数**（无分页）；先 `subagents.ensureSession(agentId, sessionId)` 幂等装载名册再核对记录自己的 `(ownerAgentId, sessionId)`；读取经 SubagentStore.messages 过滤 `m.subagentId == <subagentId>` 且排除完成报告（subagent_store.dart:228-242）；结果按 `timestamp` 升序 |
| 团队 | 10 | GET | `/api/agents/{agentId}/teammates` | `_agentTeammates:2900`（注册 2089） | path `agentId` · query 无 · body 无 | `200` `{"agent_id","members":[MemberView],"pending_member_count":int,"self":{"id","name","level","is_member","top_agent_id","top_agent_name"}}`<br>MemberView 15 键 + 3：`id`, `name`, `role`, `duty`, `model_id`, `level`, `can_lead_team`, `parent_agent_id`, `leader_name`, `relation`（`team_leader`/`direct`/`peer`/`indirect`）, `work_status`（`working`/`idle`）, `review_status`, `log_path`, `created_at`(毫秒 int), `workspace_id`, `overrides`, `effective`{`reasoning_effort`,`max_seqlen`,`max_output_tokens`,`thinking`}, `live_status` | **无 404**（不校验 agent 是否存在）：<br>agent 不存在 ⇒ `200` `{"agent_id":"<id>","members":[],"pending_member_count":0,"self":null}`<br>`teamService` 未接线 ⇒ `200` `{"agent_id":"<id>","members":[],"pending_member_count":0}`（**无 self 键**）<br>`401` / `403` / `500` | 只读；**无分页**；名册 = 该 agent **自己的下属**（TOP ⇒ 整队、按 createdAt 升序；成员 ⇒ `descendants`）；**不含** system_prompt / comment / scores；`pending_member_count` = 名册里 `review_status` ∈ {`pending_model`, `pending_review`} 的条数 |
| 团队 | 11 | PATCH | `/api/agents/{leaderId}/teammate/{memberId}` | `_updateTeammate:2923`（注册 2090） | path `leaderId`, `memberId`；body **至少一个**：`model_id`（string；`''`=清空；非空须在模型池）· `review_status`（`pending_model`/`pending_review`/`approved`/`rejected`）· `reasoning_effort`（string）· `max_seqlen`（正整数 或 null）· `max_output_tokens`（正整数 或 null）· `compress_threshold`（0.1~0.95 或 null）· `thinking`（bool 或 null） | `200` `{"success":true,"member":{...},"top_agent_name":"<name>"}`<br>`member` = MemberView 15 键 + `comment` + `scores` + `system_prompt` + `overrides` + `effective` + `live_status`（共 21 键） | `501` `{"detail":"团队服务尚未接入"}`（`teamService`==null）<br>`404` `{"detail":"成员不存在: <memberId>"}`（agent 不存在 / 是 TOP / `member.team_id` 不等于 `leaderId`）<br>`400` `{detail}`：未提供任何可改字段 / `模型不存在: <id>（可先用 GET /api/models 获取可用模型池）` / `审核状态非法: <s>（可选: ...）` / `<key> 必须为正整数` / `compress_threshold 必须在 0.1~0.95 之间` / `thinking 必须是 true / false，或 null 清除该项覆盖`<br>`401` / `403` / `500` | 写；**用户侧唯一能改 `model_id` 的入口**（team 工具三处都拒绝）；改模型时若未显式给 `review_status` 会联动推导（空模型 ⇒ `pending_model`，非空 ⇒ `approved`）；落盘 `agents/<id>.yaml`（`putAgent`）；`assignModel` 原始错误体是 `{error,hint?}`，handler 只取 `error` 重新包成 `{detail}` —— **hint 丢失** |
| 团队 | 12 | GET | `/api/agents/{memberId}/teammate/{memberId}/log`（常量原文，注意同名占位符重复） | `_teammateLog:3070`（注册 2091） | path：第 1 段（模板里叫 `memberId`，实为 leader，**代码从不读取**）+ 第 2 段 `memberId`；query `lines`（可选/int/默认 60；解析失败也回落 60）；body 无 | `200` `{"success":bool,"log":string,"path":string}`<br>当前实现恒 `success:true`；`log` = 尾部 `lines` 行（总数不足则全文，无日志为 `''`）；`path` 有日志时为常量 `'.self/activity.log'`，无日志时为 `''` | `501` `{"detail":"团队服务尚未接入"}`（`messageDispatcher`==null）<br>`401` / `403` / `500`<br>**无 404**（未知 id ⇒ 200 空 log） | 只读；**路径模板有两个同名 `{memberId}`**，`CoreRouter` 后者覆盖前者 ⇒ 实际只用第 2 段，第 1 段既不读也不校验；无存在性校验；读 `.tree/<memberId>/.self/activity.log`（本地或 SSH 工作空间 IO，读不到再回退本机绝对路径）；无分页（只有尾部 N 行）；**代码推导**：`lines` 为负数且日志非空 ⇒ `all.sublist(len - lines)` 抛 RangeError ⇒ 兜底 500 |
| 团队 | 13 | POST | `/api/agents/{leaderId}/teammate/{memberId}/message` | `_teammateMessage:3096`（注册 2092） | path `leaderId`（**未被使用/未校验**）, `memberId`；body `content`（必填/string/trim 后非空）· `session_id`（可选/string/默认 `'session_default'`） | `200`，**HTTP 恒 200、成败看 body.success**：<br>成功 `{"success":true,"detail":{"target","id","name","type","status":"sent"}}`<br>闸门拒绝 `{"success":false,"error":"投递失败（通道拒绝或未就绪）","detail":{"target","id","name","type","status":"rejected","reason":"..."}}`<br>链路失活 `{"success":false,"error":"投递失败（<reason>）","detail":{...,"liveness_lost":true},"resend_pending":int}`<br>成员不存在 `{"success":false,"error":"成员不存在: <id>"}`<br>content 为空 `{"success":false,"error":"缺少 content"}` | `501` `{"detail":"团队服务尚未接入"}`<br>`401` / `403` / `500` | 写 + 副作用：目标 agent **起一轮生成**（`deliver` 异步、不等待，717-731）、向目标连接推 WS 帧、向 `.self/activity.log` 追加 `[start(成员)]`/`[done(成员)]`/`[blocked]` 行、链路失活时登记待补发队列；未过审核的成员被 `reviewBlock` 拒；**不校验 memberId 是否属于 leaderId** |
| 模型池 | 14 | GET | `/api/models` | `_listModels:3125`（注册 2093） | path 无 · query 无 · body 无 | `200` `{"models":[ModelApi]}`<br>ModelApi 11 键同第 6 条（`model_id`, `name`, `base_url` 脱敏, `thinking`, `if_vision`, `reasoning_effort`, `reasoning_effort_options`, `max_seqlen`, `max_output_tokens`, `token_scale`, `longest_session_tokens`）；**无 api_key** | `401` / `403` / `500` | 只读；按 `model_id` 升序；无分页 |
| 模型池 | 15 | POST | `/api/models` | `_createModel:3134`（注册 2094） | body：`model_id`（必填）· `base_url`（必填）· `api_key`（必填）· `name`（可选/默认 `''`）· `thinking`（bool/默认 false）· `if_vision`（bool/默认 false）· `reasoning_effort`（默认 `''`）· `reasoning_effort_options`（string[]/默认 `['low','high','max']`）· `max_seqlen`（int/默认 0）· `max_output_tokens`（int/默认 0） | `200` `{"success":true,"model":ModelApi}`<br>`name` 为空时 API 回显 `model_id`；`token_scale`=2.0、`longest_session_tokens`=0（学习状态初值） | `400` `{"detail":"model_id 不能为空"}` / `{"detail":"base_url 不能为空"}` / `{"detail":"api_key 不能为空"}`<br>`409` `{"detail":"模型已存在：<modelId>"}`<br>`401` / `403` / `500`（类型不符） | 写；落盘 `config/models/<model_id>.yaml`（含 api_key）；body 里的 `token_scale` / `longest_session_tokens` 被忽略 |
| 模型池 | 16 | PATCH | `/api/models/{modelId}` | `_updateModel:3152`（注册 2095） | path `modelId`；body 全部可选，字段同第 15 条（不含 token_scale）；merge 语义：`base_url` / `api_key` **空串 = 保留原值**；`reasoning_effort_options` 空数组 = 忽略；未知键忽略 | `200` `{"success":true,"model":ModelApi}` | `404` `{"detail":"模型不存在"}`<br>`401` / `403` / `500`（`max_seqlen`/`max_output_tokens`/`thinking` 类型不符时 `as num?`/`as bool?` 抛 TypeError ⇒ 兜底 500） | 写；**无字段级校验**（空 body 也 200，且仍重写 yaml）；**无法清空** base_url / api_key（只能换新值）；不改 token_scale |
| 模型池 | 17 | DELETE | `/api/models/{modelId}` | `_deleteModel:3171`（注册 2096） | path `modelId` · query 无 · body 无 | `200` `{"success":true,"bound_agents":["<agentId>",...]}`<br>`bound_agents` = 仍绑定该模型的 agent id 列表（前端据此提示"需重新指定模型"） | `404` `{"detail":"模型不存在"}`<br>`401` / `403` / `500` | 写；落盘删除 `config/models/<modelId>.yaml`；**不阻止**删除仍被引用的模型（只回 bound_agents），也**不会**自动清空 agent 的 `model_id`；顺序 = `store.agents()`（updatedAt 降序） |

### 1.2 会话 / 维护 / 提问 / 运行监督 / 设置（17 条，G-1）+ Spec（2 条，附录，归 C 批）

### 表 1-1 现存 19 条（核心当前实现）

| 组 | # | 方法 | 路径 | 处理函数:行号 | 请求 | 成功回包 | 失败 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 会话/历史 | 1 | GET | /api/conversations/{agentId} | _conversationHistory:3296（注册 2097） | 路径 agentId；query：session_id（可选，默认 session_default；all=合并该 agent 全部会话）、limit（int，可选，默认 0=整份，>0 夹到 2000）、before（string，可选，默认空）、from（int，可选，默认 null）、at（string，可选，默认空） | 200 {agent_id, session_id, messages[], total, offset, has_more}；messages[] 元素=CoreMessage.toJson 的 16 个固定键（见样例 1）+ 可选 tool_arguments_raw / tool_result_for_model / questions[] / llm_hidden / subagent_id / subagent_name / subagent_parent_id / subagent_level；kind=ask_user_question 时再叠加 answered / answer / questions[] / answers[] / options[] | 401（全局）；403（引导会话 token）；404 {detail:"agent 不存在"}；500（全局兜底） | 只读；分页（末尾优先 + before 游标 + from 下标 + at 定位）；非流式；结果按 timestamp 升序；session_id=all 时跨会话合并后排序；指定了不存在的 session_id **不报 404**，回空 messages（只有 agent 不存在才 404） |
| 会话/历史 | 2 | DELETE | /api/conversations/{agentId} | _clearConversation:3403（注册 2098） | 路径 agentId；query：session_id（可选；缺省/空/all ⇒ 清该 agent 全部会话） | 200 {success:true, deleted:int} | 401/403（全局）；无 404（agent/会话不存在也 200，deleted=0）；500 | 写；只删消息（messages.jsonl），不删会话本身；删除走落盘队列；无事件推送 |
| 会话/历史 | 3 | GET | /api/agents/{agentId}/sessions | _listSessions:3195（注册 2099） | 路径 agentId；无 query | 200 {agent_id, sessions:[{session_id, agent_id, title, status, selected_spec_ids[], message_count, created_at, updated_at}]} | 401/403；404 {detail:"agent 不存在"}；500 | 名义只读但**有写副作用**：ensureDefaultSession 会创建 session_default（写 session.json，3186）；按 updated_at 倒序；message_count 只数非工具消息；无分页 |
| 会话/历史 | 4 | POST | /api/agents/{agentId}/sessions | _createSession:3220（注册 2100） | 路径 agentId；body：title（string，可选，默认 "" ⇒ 落盘为"新会话"）、session_id（string，可选，缺省生成 ses_…；已存在则返回既有会话） | 200 {success:true, session:{session_id, agent_id, title, status, selected_spec_ids[], message_count, created_at, updated_at}} | 401/403；404 {detail:"agent 不存在"}；非 string 的 title/session_id ⇒ 未捕获 TypeError ⇒ 500；非法 JSON ⇒ 500；500 兜底 | 写（落 session.json）；已存在 session_id 不报 409 而是幂等返回；响应里 message_count 恒为 0（toApiJson() 未传计数，3217） |
| 会话/历史 | 5 | GET | /api/agents/{agentId}/sessions/{sessionId} | _sessionDetail:3240（注册 2101） | 路径 agentId + sessionId；无 query | 200 {session:{…同表 1-1 #3 元素…}, messages:[CoreMessage.toJson…]} | 401/403；404 {detail:"会话不存在"}；500 | 只读；messages 与 #1 同为 16 键形态，但**不叠加**提问状态（直接 m.toJson()，3238）；不分页；非流式 |
| 会话/历史 | 6 | PATCH | /api/agents/{agentId}/sessions/{sessionId} | _renameSession:3262（注册 2102） | 路径 agentId + sessionId；body：title（string，可选；空串/缺省 ⇒ 保留原标题，file_store.dart:258） | 200 {success:true} | 401/403；404 {detail:"会话不存在"}；非 string title ⇒ 500；非法 JSON ⇒ 500 | 写（session.json）；不推送 session 更新帧 |
| 会话/历史 | 7 | DELETE | /api/agents/{agentId}/sessions/{sessionId} | _deleteSession:3279（注册 2103） | 路径 agentId + sessionId；无 body | 200 {success:true} | 401/403；404 {detail:"会话不存在"}；500 | 写 + 落盘删除；特殊副作用：先 subagents.forgetSession 摘内存索引，再递归删整个会话目录（messages.jsonl、subagents.json）；不删 agent |
| 会话/历史 | 8 | POST | /api/agents/{agentId}/sessions/{sessionId}/specs | _setSessionSpecs:3417（注册 2104） | 路径 agentId + sessionId；body：spec_ids（string[]，可选，缺省 [] ⇒ 清空；元素逐个 toString） | 200 {success:true, selected_spec_ids:[string]} | 401/403；404 {detail:"会话不存在"}；spec_ids 非数组 ⇒ 500；非法 JSON ⇒ 500 | 写（session.json 的 selected_spec_ids）；副作用：specService 非空时刷新该会话已选 Spec 快照（refreshSelectedSpecs，3417-3422，可能读工作空间） |
| 维护 | 9 | POST | /api/agents/{agentId}/reset | _resetWorkspace:3503（注册 2107） | 路径 agentId；body：target（string，可选，默认 all；只接受 system_prompt / spec / all，trim+小写归一） | 200 {success:true, system_prompt:{path, backup, restored(bool)}, spec:{spec_dir, backup_index, backed_up[], removed[], restored[]}}（两子对象按 target 出现） | 401/403；400 {detail:"target 只能是 system_prompt / spec / all"}；400 {detail:"工作空间不可用（未接线 / SSH 配置不完整），无法重置"}（io==null）；404 {detail:"agent 不存在"}；非法 JSON ⇒ 500；落盘异常 ⇒ 500 | 写 + 落盘；先备份 .bak.N（序号顺延、不覆盖旧备份）再写默认内容；**不重建**已钉住的系统提示词快照（只记一行日志，3519-3524）；spec 重置会删自定义 Spec 文件（备份里可找回）；注意两处 restored 类型不同（bool vs 路径数组） |
| 维护 | 10 | POST | /api/agents/{agentId}/compact | _compactAgent:2292（注册 2108） | 路径 agentId；body：session_id（string，可选，缺省/空 ⇒ 默认会话，compaction_service.dart:473-478） | 200 {success:true, compressed, context_size, summarized_messages, ...}，可选键 reason / source / session_id / degraded / degraded_reason / relay_skip_reason（CompactionResult.toJson，compaction_service.dart:977-992）；生成中另有早退体 {success:true, compressed:false, reason:"agent_working", context_size:0} | 401/403；404 {detail:"agent 不存在：agentId"}（service 返回 error，status=404）；501 {detail:"上下文压缩尚未接入"}（先判 501 再读 body）；400 {detail:"请求体非法：..."}；500 兜底 | 写；可能真调 LLM 总结（有成本）；推 agent_status compacting，结束按实际状态推 working/idle（2296-2311）；压动后落一条 llm_hidden 会话消息（_notifyManualCompact，2303）；不删任何消息，只改 compacted_summary / compacted_context 与水位线 |
| 维护 | 11 | POST | /api/agents/{agentId}/ssh/reconnect | _reconnectAgentSsh:2257（注册 2109） | 路径 agentId；body：无（不读 body） | 200 {ok:true, agent_id, stale:bool} | 401/403；404 {detail:"agent 不存在：agentId"}；501 {detail:"工具执行器尚未接入，无法重连远端链路"}；400 {detail:reason}（仅 not_ssh：本地工作空间）；500 {detail:reason}（重连失败 / 工作空间不可用） | 写/副作用：重建该 agent 缓存里那条 SSH 链路的底层连接（同一实现也被执行站 ssh.reconnect 复用）；文档注释写响应含 missed，代码不写（见 U1） |
| 提问 | 12 | GET | /api/questions | _listQuestions:3554（注册 2110） | 无路径参数；query：agent_id（可选）、session_id（可选）、status（可选，pending / answered / cancelled；空=全部；非法值不报错，只是过滤为空） | 200 {questions:[{qid, agent_id, team_id, session_id, is_member, questions:[{question, options[]}], answers[], question, options[], answer, status, created_at, answered_at}], total} | 401/403；500；无 404（broker 未接线 ⇒ 空列表 + total=0） | 只读；按 created_at 倒序；无分页；total 是**过滤后**条数（3561）；question/options/answer 是"第一问"的兼容读法 |
| 提问 | 13 | POST | /api/questions/{qid}/answer | _answerQuestion:3585（注册 2111） | 路径 qid；body：answers（string[]，优先；缺项按未作答补齐）或 answer（string，单值=第一问；老前端兼容） | 200 {success:true, qid, status:"answered", answers:[string]}（answers 为归一后的逐题答案） | 401/403；501 {detail:"提问回路尚未接入"}（先判 501 再读 body）；404 {detail:"没有等待回答的问题"}（qid 不存在）；400 同文案（已作答/已取消/并发竞态只有第一次生效）；非法 JSON ⇒ 500 | 写；幂等（并发 WS+REST 只有第一次生效）；落盘 data/questions.json；推 ask_user_question_resolved 帧；无在途等待时把答案写进会话（「重启后补答」路径） |
| 运行监督 | 14 | GET | /api/tools/running | _listRunningTools:2218（注册 2209） | 无参数 | 200 {runs:[{handle, agent_id, session_id, tool, command_preview, started_at, elapsed_ms, over_threshold}]} | 401/403；500 | 只读；内存登记表（重启清空、无历史）；无分页；command_preview 单行、≤160 字符（tool_run_registry.dart:51、191-196）；只含"正在跑"的 |
| 运行监督 | 15 | POST | /api/tools/running/{handle}/close | _closeRunningTool:2229（注册 2210） | 路径 handle（形如 toolrun_…）；无 body | 200 {closed:true, tool, elapsed_ms, note}（ToolCloseOutcome.toJson） | 401/403；400 {detail:"缺少 handle（形如 toolrun_…）"}（正常路由匹配下不可达）；404 {detail:可读原因 note}（句柄失效/越权，fail-closed）；500 | 写；先尽力终止进程树，再把运行从登记表移除，并让在途工具调用收敛（tool_run_registry.dart:490-530）；不自动杀，超阈值只 warning |
| 设置 | 16 | GET | /api/settings/token-rate | _getTokenRate:3644（注册 2114） | 无参数 | 200 {token_rate, min:20, max:1000} | 401/403；500 | 只读；默认 1000（近似不限速）；区间常量 CoreSettings.tokenRateMin/Max（core_settings.dart:301、304） |
| 设置 | 17 | POST | /api/settings/token-rate | _setTokenRate:3652（注册 2115） | body：token_rate（num，可选；缺省 ⇒ 按 1000 写入；写入前夹到 [20,1000]） | 200 {token_rate:生效值, min:20, max:1000} | 401/403；token_rate 非 num ⇒ 未捕获 TypeError ⇒ 500；非法 JSON ⇒ 500 | 写：settings.setTokenAcquisitionRate 夹取后经 sink 落 settings.yaml（core_settings.dart:508-520）；夹取不报错、不回 notice；空 body 或缺字段不是 no-op，而是把值**重置为 1000** |
| Spec | 18 | GET | /api/agents/{agentId}/specs | _listSpecs:3448（注册 2105） | 路径 agentId；query：session_id（可选，默认 session_default） | 200 {specs:[{id, spec_id, title, task_type, description, when[], tags[], pinned, builtin, version, classification, risk, created_at, updated_at}], selected_spec_ids[]} | 401/403；500；无 404（agent/session 不存在也 200；specService 未接线 ⇒ specs=[] 且 selected_spec_ids 取会话或 []） | 名义只读、**实际会写工作空间**：specService.index → seedInto 播种/升级 .self/spec/*.md（旧副本 .bak.N 备份），并更新索引快照（spec_service.dart:278-304、147-204）；specs[] 只含元数据、不含正文；无分页 |
| Spec | 19 | GET | /api/agents/{agentId}/specs/{specId} | _getSpec:3474（注册 2106） | 路径 agentId + specId；无 query | 200 {meta:{…同 #18 的规格元数据 14 键…}, content:"文件原文（front matter+正文）"}；specService 未接线 ⇒ 200 {meta:{}, content:""} | 401/403；404 {detail:"Spec 不存在: specId"}；500 | 只读（工作空间文件优先，内置模板兜底）；content 是 raw 原文、逐字与磁盘一致；无分页 |

### 表 1-2 新增 2 条（核心未实现，单列一节）

| 组 | # | 方法 | 路径 | 处理函数:行号 | 请求 | 成功回包 | 失败 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 上行改委派（未实现） | 20 | POST | /api/agents/{agentId}/messages | 无（核心未注册；_registerRoutes 无此条，stubApiPaths 为空） | 路径 agentId；body 设计上"与旧 WS 上行 send_message 同形"，即 WS user_message 帧字段：content（string）、session_id（string，可选；空 ⇒ 新建会话且标题取内容前 30 字）、attachments（list，元素为 {path, name?, size?, type?} 或纯路径字符串；可选）；body 里的 agent_id 是否保留：（代码未明确） | （代码未明确；核心未实现，docs/pluginization/agent_pluginization.md §1.3 也未定义回包形状） | 未申报插件时实际命中 404 {detail:"未知接口：/api/agents/{agentId}/messages"}；插件申报后由核心转发，传输失败 ⇒ 503（插件不可用）/504（超时）/502（回包非法）{ok:false, error, plugin_id, reason}；插件回包原样透传 | 写；替代 WS 上行 send_message；语义与 ConversationService.handleUserMessage 相同（落库 user 消息、打断同会话在途轮次、入队生成）；当前若前端已改用该路径会 404（插件未上线） |
| 上行改委派（未实现） | 21 | POST | /api/agents/{agentId}/cancel | 无（核心未注册） | 路径 agentId；body：无 | （代码未明确） | 未申报插件时实际命中 404 {detail:"未知接口：/api/agents/{agentId}/cancel"}；转发失败同上 503/504/502 | 写；替代 WS 上行 cancel（协议包里实际帧名是 stop）；现有核心 cancelAgent(agentId) 是 agent 级：取消该 agent 全部在途会话 + 名下 subagent，并作废排队任务；是否沿用 WS stop 的团队级联：（代码未明确） |

### 1.3 两条新增路由（核心未实现）的字段出处

- WS 上行类型常量里**没有** send_message / cancel 这两个字面量：packages/tree_protocol/lib/src/ws_inbound.dart 只有 userMessage = 'user_message'（第 13 行）与 stop = 'stop'（第 16 行）；send_message / cancel 仅出现在 api_paths.dart 的注释与 docs 的 §1.3 表里（设计文档沿用了旧 Python 端的叫法）。
- 消息字段的真实出处：conversation_service.dart:265-272 的帧字段注释与读取代码 = {type, agent_id, content, attachments, session_id}；attachments 归一化见同文件 2042-2081（{name, path, size, type}，非法项丢弃）。
- 取消字段的真实出处：conversation_service.dart:311-320（帧为 {type, data:{agent_id, session_id}}）与 core_server.dart:3002-3012（data 与顶层都接受，agent_id 必填，session_id 只用于状态帧）。cancelAgent 本身忽略 session_id（agent 级取消）。

---

## 2. 逐条样例

### 2.1 agent 定义 / 子 agent / 团队 / 模型池（17 条）

## 第二部分：逐条样例

> JSON 里的值用占位符，**键名全部来自代码**。

### 1) GET /api/agents
- 请求：`GET /api/agents`，Header `Authorization: Bearer <main-token>`（无 path / query / body）
- 200 响应：`{"agents":[{"id":"agt_1","name":"拓扑","type":"normal","system_prompt":"你是…","model_id":"deepseek-chat","workspace_id":"ws_agt_1","workspace_dir":"","has_ssh":false,"last_message":"你好","last_message_time":1730000000000,"unread_count":0,"avatar_url":null,"pending_member_count":1,"team_id":"","parent_agent_id":"","level":0,"role":"","duty":"","can_lead_team":true,"review_status":"","created_at":1730000000000,"updated_at":1730000000000}]}`
- 空列表：`{"agents":[]}`
- 失败：`401 {"detail":"本地 token 无效或已过期"}` · `500 {"detail":"核心进程内部错误：<error>"}`

### 2) POST /api/agents
- 请求：`POST /api/agents`，body `{"name":"拓扑","system_prompt":"你是…","model_id":"deepseek-chat","team_member_count":0,"max_level":3,"max_members_per_level":7}`
- 200 响应：`{"success":true,"agent":{"id":"agt_1","name":"拓扑","type":"normal","system_prompt":"你是…","model_id":"deepseek-chat","workspace_id":"ws_agt_1","workspace_dir":"","has_ssh":false,"last_message":"","last_message_time":null,"unread_count":0,"avatar_url":null,"pending_member_count":0,"team_id":"","parent_agent_id":"","level":0,"role":"","duty":"","can_lead_team":true,"review_status":"","created_at":1730000000000,"updated_at":1730000000000}}`
- 失败：`400 {"detail":"模型不存在：nope"}` · `400 {"detail":"name 不能为空"}`
- 失败（注意）：非法 JSON 不是 400，而是 `500 {"detail":"核心进程内部错误：FormatException: ..."}`

### 3) GET /api/agents/{agentId}
- 请求：`GET /api/agents/agt_1`（无 query / body）
- 200 响应：`{"agent":{"id":"agt_1","name":"拓扑","type":"normal","system_prompt":"你是…","model_id":"deepseek-chat","workspace_id":"ws_agt_1","workspace_dir":"E:\\work\\demo","has_ssh":true,"last_message":"你好","last_message_time":1730000000000,"unread_count":0,"avatar_url":null,"pending_member_count":0,"team_id":"","parent_agent_id":"","level":0,"role":"","duty":"","can_lead_team":true,"review_status":"","created_at":1730000000000,"updated_at":1730000000000},"ssh":{"host":"10.0.0.5","port":22,"username":"dev","auth":"key","root":"/srv/app","key_path":"~/.ssh/id_ed25519"}}`
- 未配 SSH 时**没有** `ssh` 键；`auth` 取值 `'password'` / `'key'` / `'none'`
- 失败：`404 {"detail":"agent 不存在"}`

### 4) PATCH /api/agents/{agentId}
- 请求：`PATCH /api/agents/agt_1`，body `{"system_prompt":"你是 A","model_id":"deepseek-chat","workspace_dir":"E:\\work\\demo","max_seqlen":64000,"compress_threshold":0.8,"thinking":true}`
- 200 响应：`{"success":true,"agent":{"id":"agt_1",...,"has_ssh":false,...},"ssh":{"host":"10.0.0.5","port":22,"username":"dev","auth":"password"}}`（`ssh` 仅当最终有配置；`agent` 的 22 键同第 1 条）
- 空 body：`200` 且 `{"success":true,"agent":{...}}`——但 `agents/<id>.yaml` 仍被重写、`updated_at` 已变
- 失败：`400 {"detail":"compress_threshold 必须在 0.1~0.95 之间，或 null 清除该项覆盖"}` · `404 {"detail":"agent 不存在"}`

### 5) DELETE /api/agents/{agentId}
- 请求：`DELETE /api/agents/agt_1?cascade=1`
- 200 响应：`{"success":true,"removed":["agt_3","agt_2","agt_1"],"cascade":true,"questions_removed":2}`（`removed` 叶→根；`questions_removed` 仅在 >0 时出现）
- 409（未级联）：`{"detail":"该 agent 还有 1 个下级成员，未指定 cascade","error":"该 agent 还有 1 个下级成员，未指定 cascade","cascade_required":[{"member_id":"agt_2","name":"前端","level":1,"parent_agent_id":"agt_1"}],"hint":"..."}`
- 409（运行中）：`{"detail":"agent 正在运行，不能删除","error":"agent 正在运行，不能删除","running":["agt_1"],"hint":"..."}`
- 副作用：向 WS 广播 `{"type":"agent_status","data":{"agent_id":"agt_1","status":"idle","own_running":false}}`

### 6) GET /api/agents/{agentId}/models-info
- 请求：`GET /api/agents/agt_1/models-info`
- 200 响应：`{"agent":{"id":"agt_1","model_id":"deepseek-chat","system_prompt":"你是…"},"models":[{"model_id":"deepseek-chat","name":"DeepSeek Chat","base_url":"https://api.deepseek.com","thinking":false,"if_vision":false,"reasoning_effort":"high","reasoning_effort_options":["low","high","max"],"max_seqlen":64000,"max_output_tokens":8192,"token_scale":2.0,"longest_session_tokens":0}],"overrides":{"max_seqlen":32000}}`
- `overrides` 为空时是 `{}`（只有设置过的键）
- 失败：`404 {"detail":"agent 不存在"}`

### 7) GET /api/agents/{agentId}/todos
- 请求：`GET /api/agents/agt_1/todos?session_id=session_default`（`session_id` 可省，默认 `session_default`）
- 200 响应：`{"todos":[{"id":"t1","content":"实现登录接口","status":"in_progress","progress":40,"updated_at":0}],"session_id":"session_default"}`
- 无待办文件：`{"todos":[],"session_id":"session_default"}`
- 失败：`404 {"detail":"agent 不存在"}`

### 8) GET /api/agents/{agentId}/subagents
- 请求：`GET /api/agents/agt_1/subagents?session_id=session_default`
- 200 响应：`{"agent_id":"agt_1","session_id":"session_default","total":1,"subagents":[{"id":"sub_1","name":"临时员工","owner_agent_id":"agt_1","session_id":"session_default","parent_id":"agt_1","level":1,"scope":"整理日志","run_count":2,"created_at":"2026-10-25T10:00:00.000","updated_at":"2026-10-25T10:05:00.000"}]}`
- 名册为空：`{"agent_id":"agt_1","session_id":"session_default","total":0,"subagents":[]}`
- 失败：`404 {"detail":"agent 不存在"}`

### 9) GET /api/agents/{agentId}/subagents/{subagentId}/transcript
- 请求：`GET /api/agents/agt_1/subagents/sub_1/transcript?session_id=session_default`
- 200 响应：`{"agent_id":"agt_1","subagent_id":"sub_1","session_id":"session_default","total":1,"messages":[{"id":"msg_1","agent_id":"sub_1","session_id":"session_default","role":"user","content":"整理日志","timestamp":"2026-10-25T10:00:01.000","kind":"text","tool_name":null,"tool_arguments":null,"tool_result":"","tool_call_id":null,"usage":null,"attachments":null,"options":[],"answered":false,"is_streaming":false,"subagent_id":"sub_1","subagent_name":"临时员工","subagent_parent_id":"agt_1","subagent_level":1}]}`
- 失败：`404 {"detail":"agent 不存在"}` · `404 {"detail":"临时员工不存在：sub_9"}`
- 失败（跨会话）：`404 {"detail":"临时员工「临时员工」属于会话 session_2，不在这个会话（session_default）里——跨会话不保留是硬不变量。"}`

### 10) GET /api/agents/{agentId}/teammates
- 请求：`GET /api/agents/agt_1/teammates`
- 200 响应（TOP 视角）：`{"agent_id":"agt_1","members":[{"id":"agt_2","name":"前端","role":"","duty":"","model_id":"deepseek-chat","level":1,"can_lead_team":true,"parent_agent_id":"agt_1","leader_name":"拓扑","relation":"direct","work_status":"idle","review_status":"approved","log_path":".tree/agt_2/.self/activity.log","created_at":1730000000000,"workspace_id":"ws_agt_2","overrides":{},"effective":{"reasoning_effort":"high","max_seqlen":64000,"max_output_tokens":8192,"thinking":false},"live_status":"idle"}],"pending_member_count":1,"self":{"id":"agt_1","name":"拓扑","level":0,"is_member":false,"top_agent_id":"","top_agent_name":""}}`
- agent 不存在：`200 {"agent_id":"agt_9","members":[],"pending_member_count":0,"self":null}`（**不是 404**）
- teamService 未接线：`200 {"agent_id":"agt_1","members":[],"pending_member_count":0}`（无 `self` 键）

### 11) PATCH /api/agents/{leaderId}/teammate/{memberId}
- 请求：`PATCH /api/agents/agt_1/teammate/agt_2`，body `{"model_id":"deepseek-chat","max_seqlen":32000,"thinking":null}`
- 200 响应：`{"success":true,"member":{"id":"agt_2","name":"前端","role":"","duty":"","model_id":"deepseek-chat","level":1,"can_lead_team":true,"parent_agent_id":"agt_1","leader_name":"拓扑","relation":"team_leader","work_status":"idle","review_status":"approved","log_path":".tree/agt_2/.self/activity.log","created_at":1730000000000,"workspace_id":"ws_agt_2","comment":"","scores":{},"system_prompt":"你是前端","overrides":{"max_seqlen":32000},"effective":{"reasoning_effort":"high","max_seqlen":32000,"max_output_tokens":8192,"thinking":false},"live_status":"idle"},"top_agent_name":"拓扑"}`
- 失败：`404 {"detail":"成员不存在: agt_9"}` · `400 {"detail":"至少提供 model_id / review_status / 模型参数覆盖之一（可覆盖项：reasoning_effort, max_seqlen, max_output_tokens, compress_threshold, thinking）"}`
- 失败：`400 {"detail":"审核状态非法: done（可选: pending_model, pending_review, approved, rejected）"}`
- 未接线：`501 {"detail":"团队服务尚未接入"}`

### 12) GET /api/agents/{memberId}/teammate/{memberId}/log
- 请求：`GET /api/agents/agt_1/teammate/agt_2/log?lines=20`（第 1 段 `agt_1` 不被读取；`lines` 可省，默认 60）
- 200 响应：`{"success":true,"log":"[start(成员)] 收到  消息: 把日志发我","path":".self/activity.log"}`
- 说明：用户发的消息 senderId 为空，`_nameOf('')` 返回 `''`，所以那一行确实是「收到  消息」（两个空格）；成员/agent 发的则会带名字
- 无日志 / 未知 id：`200 {"success":true,"log":"","path":""}`（**不是 404**）
- 失败：`501 {"detail":"团队服务尚未接入"}` · `500（lines<0 且日志非空，代码推导的 RangeError）`

### 13) POST /api/agents/{leaderId}/teammate/{memberId}/message
- 请求：`POST /api/agents/agt_1/teammate/agt_2/message`，body `{"content":"把日志发我","session_id":"session_default"}`
- 200 响应（成功）：`{"success":true,"detail":{"target":"agt_2","id":"agt_2","name":"前端","type":"member","status":"sent"}}`
- 200 响应（被闸门拒绝）：`{"success":false,"error":"投递失败（通道拒绝或未就绪）","detail":{"target":"agt_2","id":"agt_2","name":"前端","type":"member","status":"rejected","reason":"投递失败（通道拒绝或未就绪）"}}`
- 200 响应（链路失活）：`{"success":false,"error":"投递失败（连接心跳丢失（链路失活），消息未投递、已登记待补发：<原因>）","detail":{"target":"agt_2","id":"agt_2","name":"前端","type":"member","status":"rejected","reason":"...","liveness_lost":true},"resend_pending":1}`
- 200 响应（空 content）：`{"success":false,"error":"缺少 content"}`；成员不存在：`{"success":false,"error":"成员不存在: agt_9"}`
- 未接线：`501 {"detail":"团队服务尚未接入"}`

### 14) GET /api/models
- 请求：`GET /api/models`
- 200 响应：`{"models":[{"model_id":"deepseek-chat","name":"DeepSeek Chat","base_url":"https://api.deepseek.com","thinking":false,"if_vision":false,"reasoning_effort":"high","reasoning_effort_options":["low","high","max"],"max_seqlen":64000,"max_output_tokens":8192,"token_scale":2.0,"longest_session_tokens":0}]}`
- 空模型池：`{"models":[]}`；响应中**永远没有 api_key**

### 15) POST /api/models
- 请求：`POST /api/models`，body `{"model_id":"deepseek-chat","name":"DeepSeek Chat","base_url":"https://api.deepseek.com","api_key":"sk-<secret>","thinking":false,"if_vision":false,"reasoning_effort":"high","reasoning_effort_options":["low","high","max"],"max_seqlen":64000,"max_output_tokens":8192}`
- 200 响应：`{"success":true,"model":{"model_id":"deepseek-chat","name":"DeepSeek Chat","base_url":"https://api.deepseek.com","thinking":false,"if_vision":false,"reasoning_effort":"high","reasoning_effort_options":["low","high","max"],"max_seqlen":64000,"max_output_tokens":8192,"token_scale":2.0,"longest_session_tokens":0}}`
- 失败：`400 {"detail":"api_key 不能为空"}` · `409 {"detail":"模型已存在：deepseek-chat"}`

### 16) PATCH /api/models/{modelId}
- 请求：`PATCH /api/models/deepseek-chat`，body `{"name":"DS","base_url":"","api_key":"","reasoning_effort_options":["low","high"],"max_output_tokens":4096}`（`base_url`/`api_key` 空串 = 保留原值）
- 200 响应：`{"success":true,"model":{"model_id":"deepseek-chat","name":"DS","base_url":"https://api.deepseek.com","thinking":false,"if_vision":false,"reasoning_effort":"high","reasoning_effort_options":["low","high"],"max_seqlen":64000,"max_output_tokens":4096,"token_scale":2.0,"longest_session_tokens":0}}`
- 失败：`404 {"detail":"模型不存在"}` · `500（max_seqlen 传字符串 ⇒ as num? 抛 TypeError）`

### 17) DELETE /api/models/{modelId}
- 请求：`DELETE /api/models/deepseek-chat`（无 query / body）
- 200 响应：`{"success":true,"bound_agents":["agt_1","agt_2"]}`
- 无人绑定：`{"success":true,"bound_agents":[]}`
- 失败：`404 {"detail":"模型不存在"}`

## 附：自检与不确定项

**覆盖度**：17/17，注册行 2076-2096 与 handler 行号一一对应，路径字符串全部逐字取自 api_paths.dart（`/api/agents` … 第 28 行；`/api/agents/{agentId}` 第 29 行；`/api/agents/{agentId}/models-info` 第 30 行；`/api/agents/{agentId}/todos` 第 31 行；`/api/agents/{agentId}/teammates` 第 32 行；`/api/agents/{leaderId}/teammate/{memberId}` 第 33 行；`/api/agents/{memberId}/teammate/{memberId}/log` 第 34-35 行；`/api/agents/{leaderId}/teammate/{memberId}/message` 第 36-37 行；`/api/models` 第 38 行；`/api/models/{modelId}` 第 39 行；`/api/agents/{agentId}/subagents` 第 264 行；`/api/agents/{agentId}/subagents/{subagentId}/transcript` 第 274-275 行）。

**不确定 / 需人工确认（共 6 项，均未编造）**：

1. `ApiPaths.teammateLog` 的模板是 `'/api/agents/{memberId}/teammate/{memberId}/log'`——**同一个占位符名出现两次**。代码行为确定（后者覆盖前者，第 1 段不被读取/校验），但这是否是契约本意（疑似历史遗留或笔误）**代码未明确**；迁移到 tree.agent 时是否要顺手改成 `{leaderId}` 需产品确认。
2. 对 `sub_…`（临时员工）id 调 `GET/PATCH/DELETE /api/agents/{agentId}`：`SubagentStore` 会把它当 agent 处理（`agent()` 返回运行配置快照、`updateAgent()` 直接回原对象、`deleteAgent()` 删整棵临时员工子树）。**这些端点没有"必须是真 agent"的显式拦截**，具体期望语义**代码未明确**（迁移时建议显式拒绝或保持现状，需确认）。
3. `GET /api/agents/{agentId}/teammates` **没有 404 分支**（agent 不存在 ⇒ 200 + `"self":null`），与同批其它 `{agentId}` 端点不一致。是否有意为之**代码未明确**（注释只解释了"未接团队服务回空树而不是 501"）。
4. `GET …/teammate/…/log` 传 `lines` 为负数且日志非空时，`all.sublist(all.length - lines)` 会抛 RangeError ⇒ 兜底 500（纯代码推导，**未实测**；正数与非数字都已确定）。
5. `MessageJson` 里 `usage` / `attachments` 是透传的 Map / List，**其内部键形状代码未明确**（本文件只到"对象/数组或 null"这一层）。
6. `POST /api/agents` 未提供任何"创建成员（带 team_id / parent_agent_id）"的入口——本批只能建 TOP。若插件的 agent 创建端点需要支持建成员，**契约缺口代码未明确**（team 工具另走 `create_member`，不在本批 17 条内）。

### 2.2 会话 / 维护 / 提问 / 运行监督 / 设置（17 条）+ Spec 附录（2 条）+ 新增路由（2 条）

> 编号在本节内独立（1–21）；与 §2.1 的 1–17 不连号。表格同理（§1.1 表 1–17、§1.2 表 1–19 与表 1–2 的 20–21）。

## 2. 第二部分：逐条样例（21 条）

> 所有请求都另带 Authorization: Bearer 本地 token（全局 401 语义）。JSON 里中文为占位值，键名均来自代码。

### 1) GET /api/conversations/{agentId}

请求: GET /api/conversations/agt_01?session_id=session_default&limit=2
响应 200:
    {"agent_id":"agt_01","session_id":"session_default","messages":[{"id":"msg_07","agent_id":"agt_01","session_id":"session_default","role":"user","content":"你好","timestamp":"2026-10-25T10:12:37.123","kind":"text","tool_name":null,"tool_arguments":null,"tool_result":"","tool_call_id":null,"usage":null,"attachments":null,"options":[],"answered":false,"is_streaming":false}],"total":10,"offset":8,"has_more":true}
说明: timestamp 是 ISO-8601 字符串（JsonTime.encode），其余时间戳字段才是毫秒整数；kind=ask_user_question 时该元素会多出 answer / questions[] / answers[] 并覆盖 answered。

### 2) DELETE /api/conversations/{agentId}

请求: DELETE /api/conversations/agt_01?session_id=session_default
响应 200:
    {"success":true,"deleted":12}
说明: session_id 缺省/空/all ⇒ 清该 agent 全部会话；agent 或会话不存在 ⇒ 仍 200 且 deleted=0。

### 3) GET /api/agents/{agentId}/sessions

请求: GET /api/agents/agt_01/sessions
响应 200:
    {"agent_id":"agt_01","sessions":[{"session_id":"session_default","agent_id":"agt_01","title":"默认会话","status":"active","selected_spec_ids":[],"message_count":0,"created_at":1761360000000,"updated_at":1761360000000}]}
说明: created_at/updated_at 是毫秒整数（与消息的 ISO 字符串不同）；该 GET 会顺手创建 session_default。

### 4) POST /api/agents/{agentId}/sessions

请求: POST /api/agents/agt_01/sessions   body: {"title":"第二个"}
响应 200:
    {"success":true,"session":{"session_id":"ses_01","agent_id":"agt_01","title":"第二个","status":"active","selected_spec_ids":[],"message_count":0,"created_at":1761360000000,"updated_at":1761360000000}}
说明: session_id 已存在 ⇒ 返回既有会话（幂等，不 409）；响应里 message_count 恒 0（未传计数）。

### 5) GET /api/agents/{agentId}/sessions/{sessionId}

请求: GET /api/agents/agt_01/sessions/ses_01
响应 200:
    {"session":{"session_id":"ses_01","agent_id":"agt_01","title":"第二个","status":"active","selected_spec_ids":[],"message_count":3,"created_at":1761360000000,"updated_at":1761360000001},"messages":[{"id":"msg_01","agent_id":"agt_01","session_id":"ses_01","role":"user","content":"你好","timestamp":"2026-10-25T10:12:37.123","kind":"text","tool_name":null,"tool_arguments":null,"tool_result":"","tool_call_id":null,"usage":null,"attachments":null,"options":[],"answered":false,"is_streaming":false}]}
说明: 这里 messages 直接用 CoreMessage.toJson，不叠加提问记录状态（与 #1 的差异）。

### 6) PATCH /api/agents/{agentId}/sessions/{sessionId}

请求: PATCH /api/agents/agt_01/sessions/ses_01   body: {"title":"改名后"}
响应 200:
    {"success":true}
说明: title 为空串或缺字段 ⇒ 保留原标题；会话不存在 ⇒ 404 {"detail":"会话不存在"}。

### 7) DELETE /api/agents/{agentId}/sessions/{sessionId}

请求: DELETE /api/agents/agt_01/sessions/ses_01
响应 200:
    {"success":true}
说明: 副作用是删会话目录（messages.jsonl 与 subagents.json 一起消失）；不存在 ⇒ 404。

### 8) POST /api/agents/{agentId}/sessions/{sessionId}/specs

请求: POST /api/agents/agt_01/sessions/ses_01/specs   body: {"spec_ids":["general-task","spec_a"]}
响应 200:
    {"success":true,"selected_spec_ids":["general-task","spec_a"]}
说明: spec_ids 缺省或 [] ⇒ 清空选择；随后刷新该会话已选 Spec 快照（可能读工作空间）。

### 9) POST /api/agents/{agentId}/reset

请求: POST /api/agents/agt_01/reset   body: {"target":"all"}
响应 200:
    {"success":true,"system_prompt":{"path":".self/system_prompt.md","backup":".self/system_prompt.md.bak.3","restored":true},"spec":{"spec_dir":".self/spec","backup_index":3,"backed_up":[".self/spec/general-task.md → .self/spec/general-task.md.bak.3"],"removed":[".self/spec/custom.md"],"restored":[".self/spec/general-task.md"]}}
说明: target ∈ system_prompt / spec / all（缺省 all），非法值 400；两个 restored 含义不同（bool vs 路径数组）。

### 10) POST /api/agents/{agentId}/compact

请求: POST /api/agents/agt_01/compact   body: {"session_id":"session_default"}
响应 200:
    {"success":true,"compressed":true,"context_size":5,"summarized_messages":8,"source":"builtin","session_id":"session_default"}
说明: 未压动也是 200（如 {"success":true,"compressed":false,"reason":"too_few_messages","context_size":0,"summarized_messages":0}）；生成中 ⇒ reason="agent_working"；未接线 501。

### 11) POST /api/agents/{agentId}/ssh/reconnect

请求: POST /api/agents/agt_01/ssh/reconnect   body: 无
响应 200:
    {"ok":true,"agent_id":"agt_01","stale":false}
说明: 本地工作空间 ⇒ 400；重连失败/工作空间不可用 ⇒ 500；工具执行器未接线 ⇒ 501；文档里的 missed 键代码不产出。

### 12) GET /api/questions

请求: GET /api/questions?agent_id=agt_01&session_id=session_default&status=pending
响应 200:
    {"questions":[{"qid":"q_01","agent_id":"agt_01","team_id":"","session_id":"session_default","is_member":false,"questions":[{"question":"要不要继续？","options":["要","不要"]}],"answers":[],"question":"要不要继续？","options":["要","不要"],"answer":"","status":"pending","created_at":1761360000000,"answered_at":0}],"total":1}
说明: 按 created_at 倒序；total 是过滤后条数；broker 未接线 ⇒ {"questions":[],"total":0}。

### 13) POST /api/questions/{qid}/answer

请求: POST /api/questions/q_01/answer   body: {"answers":["要"]}
响应 200:
    {"success":true,"qid":"q_01","status":"answered","answers":["要"]}
说明: 多问题时 answers 与题目等长、未答项补 ""；老前端可只给 {"answer":"要"}；重复作答/已取消 ⇒ 400。

### 14) GET /api/tools/running

请求: GET /api/tools/running
响应 200:
    {"runs":[{"handle":"toolrun_1761360000000_ab12_1","agent_id":"agt_01","session_id":"session_default","tool":"terminal","command_preview":"pnpm test","started_at":1761360000000,"elapsed_ms":4200,"over_threshold":false}]}
说明: 空表也是 {"runs":[]}；数据源是纯内存登记表，重启即清空。

### 15) POST /api/tools/running/{handle}/close

请求: POST /api/tools/running/toolrun_1761360000000_ab12_1/close   body: 无
响应 200:
    {"closed":true,"tool":"terminal","elapsed_ms":4200,"note":"已终止进程树（taskkill /T）"}
说明: 句柄失效 ⇒ 404 {"detail":"该句柄已失效（toolrun_…）：…"}；成功响应无 success 字段，键是 closed/tool/elapsed_ms/note。

### 16) GET /api/settings/token-rate

请求: GET /api/settings/token-rate
响应 200:
    {"token_rate":1000,"min":20,"max":1000}

### 17) POST /api/settings/token-rate

请求: POST /api/settings/token-rate   body: {"token_rate":1}
响应 200:
    {"token_rate":20,"min":20,"max":1000}
说明: 缺字段 ⇒ 以 1000 写入再夹取；非 num ⇒ 500；写入落 settings.yaml。

### 18) GET /api/agents/{agentId}/specs

请求: GET /api/agents/agt_01/specs?session_id=session_default
响应 200:
    {"specs":[{"id":"general-task","spec_id":"general-task","title":"通用任务","task_type":"general","description":"<简介>","when":["<适用场景>"],"tags":["<标签>"],"pinned":false,"builtin":true,"version":3,"classification":"内部规范","risk":"low","created_at":0,"updated_at":0}],"selected_spec_ids":["general-task"]}
说明: 只回元数据、不回正文；该 GET 会播种/升级工作空间 .self/spec/*.md（写副作用）；specService 未接线 ⇒ specs=[]。

### 19) GET /api/agents/{agentId}/specs/{specId}

请求: GET /api/agents/agt_01/specs/general-task
响应 200:
    {"meta":{"id":"general-task","spec_id":"general-task","title":"通用任务","task_type":"general","description":"<简介>","when":["<适用场景>"],"tags":["<标签>"],"pinned":false,"builtin":true,"version":3,"classification":"内部规范","risk":"low","created_at":0,"updated_at":0},"content":"<front matter + 正文原文>"}
说明: content 是文件 raw 原文；不存在 ⇒ 404 {"detail":"Spec 不存在: general-task"}；specService 未接线 ⇒ 200 {"meta":{},"content":""}。

### 20) POST /api/agents/{agentId}/messages（核心未实现）

请求: POST /api/agents/agt_01/messages   body: {"content":"你好","session_id":"session_default","attachments":[{"path":".input/20261025/a.png","name":"a.png","size":1234,"type":"image/png"}]}
当前实际响应（无插件申报）404:
    {"detail":"未知接口：/api/agents/agt_01/messages"}
说明: 成功回包（代码未明确）；若插件申报并由核心转发，传输失败为 503/504/502 {"ok":false,"error":"bad_gateway","plugin_id":"tree.agent","reason":"可读原因"}，插件回包原样透传。

### 21) POST /api/agents/{agentId}/cancel（核心未实现）

请求: POST /api/agents/agt_01/cancel   body: 无
当前实际响应（无插件申报）404:
    {"detail":"未知接口：/api/agents/agt_01/cancel"}
说明: 成功回包（代码未明确）；语义替代 WS stop（agent 级取消 + 作废排队 + 取消在途提问），是否含团队级联（代码未明确）。

---

## 3. 迁移前必须拍板的契约缺口（C-01 ~ C-12）

> 下列各条都是**代码现状与设计文档/直觉不一致**的地方。G-1 要求"行为与迁移前一致"，所以要么插件逐字复刻现状，要么先改核心/文档再迁移——**不能一边复刻一边改**。原始证据见 §4 的 U 编号。

| ID | 现象 | 影响 | 建议 |
| --- | --- | --- | --- |
| C-01 | 错误体是 `{"detail"}`，不是设计文档常写的 `{ok:false,error}` | 插件若按后者实现，前端的错误解析与提示会变形 | 插件**逐字复刻** `{"detail"}`；委派传输层的 `{ok,error,plugin_id,reason}` 由核心产生，插件不重复 |
| C-02 | 非法 JSON：只有 `/compact` 回 400，其余 500 | 插件侧若统一 400，前端行为会从"内部错误"变成"请求非法" | 先拍板：**建议插件统一 400**（更正确），并在同一批里改核心 + 前端断言；若坚持零差异则复刻 500 |
| C-03 | 字段类型不符（`title` / `session_id` / `spec_ids` / `token_rate` 等 `as` 强转）⇒ 500 | 同上 | 随 C-02 一起决定；建议统一 400 |
| C-04 | `ApiPaths.teammateLog` = `/api/agents/{memberId}/teammate/{memberId}/log`，**两个同名占位符**；第 1 段（leader）从不读取 | 路径语义错误但前端已按此调用；改成 `{leaderId}` 会改契约 | 建议改 `{leaderId}`（核心 + 前端 + 插件同批），并把"leader 不参与校验"的行为写清 |
| C-05 | `GET …/teammates` 无 404：未知 agent ⇒ 200 + `"self":null`；teamService 未接线 ⇒ 200 且无 `self` 键 | 插件若加 404，前端空态逻辑会变 | 建议保留现状（空态优于报错），在契约里写明"无 404" |
| C-06 | `ssh/reconnect` 的 `api_paths.dart` 注释含 `missed`，代码只回 `{ok,agent_id,stale}`；"SSH 配置不完整"实际走 500 而非注释说的 400 | 前端若读 `missed` 会永远拿不到 | 建议**改注释与文档**，保持代码；400 只留给"本地工作空间" |
| C-07 | `agentCompact` 注释写"核心尚未实现：显式 501"，实际已实现；501 只在压缩服务未接线时出现 | 迁移时容易误以为该端点可跳过 | 改注释；G-1 按"已实现"验收 |
| C-08 | 两条新增端点（`messages` / `cancel`）的**成功回包形状未定义**（核心未实现、文档未写）；`cancel` 是否沿用 WS `stop` 的团队级联也未定 | 插件无法开工 | **G-1 之前必须拍板**：`messages` 建议回 `{success:true, agent_id, session_id, message_id, queued:true}`；`cancel` 回 `{success:true, agent_id, cancelled:[…]}` 并明确是否 cascade |
| C-09 | `POST /api/agents` 不能指定 `team_id/parent_agent_id/level/role`（只能建 TOP） | "建成员"目前没有 REST 入口，只能靠 team 工具 | 产品决策：G 只做等量迁移则复刻；若补入口另立遗留项 |
| C-10 | `GET …/specs` 名义只读，实际会播种/升级工作空间 `.self/spec/*.md`（备份 `.bak.N`） | 插件若按只读实现，会丢这个写副作用（工作空间规范文件不再更新） | 迁移时**保留**该副作用；把"GET 也会写盘"写进契约 |
| C-11 | 细节不一致：`POST …/sessions` 响应 `message_count` 恒 0；`GET conversations` 未知 session 不 404；`DELETE conversations` 无 404；`POST token-rate` 空 body 会把值重置为 1000 | 前端已按现状工作；插件容易"顺手修正" | G-1 期间**逐字复刻**；修正留到 G 之后单独评审 |
| C-12 | `sub_…` id 传给 `GET/PATCH/DELETE /api/agents/{agentId}` 会落到 SubagentStore 分支（返回运行配置快照 / 可能改写） | 语义未定义；迁移后可能变成另一种行为 | 建议明确"agent 端点只接受真 agent id"并加 404；需产品确认 |

---

### 3.1 G-1 决策（2026-10-25 拍板：等价优先）

> 口径：**G-1 只做等量迁移**。除"没有现状可复刻"的两条新增端点（C-08）外，一律**复刻核心现状**；"更正确"的改法登记为 G 后清理，不与迁移混做（L-27 同口径）。

| ID | 决策 | 理由 / 后续 |
| --- | --- | --- |
| C-01 | 插件**逐字复刻** `{"detail":…}` | 前端按该形状解析错误；委派层错误体由核心产出，插件不重复 |
| C-02 | **复刻现状**：除 `/compact` 外，非法 JSON ⇒ 500 | 不改行为；统一 400 登记 G 后清理项 L-30 |
| C-03 | **复刻现状**：字段类型不符 ⇒ 500 | 随 C-02，登记 L-30 |
| C-04 | **保持现有路径**（双 `{memberId}`，leader 段不读取） | 改路径要同时改前端与契约，风险不属于 G；登记 L-31 |
| C-05 | **复刻无 404**：未知 agent ⇒ 200 + `self:null`；未接线 ⇒ 200 且无 `self` | 空态优于报错，前端已依赖 |
| C-06 | 只改 `api_paths.dart` 注释（去 `missed`、修正 400/500 口径） | 代码行为不变；注释已随本决策修正 |
| C-07 | 只改 `api_paths.dart` 注释（compact 已实现；501 仅限未接线） | 同上 |
| C-08 | **两条新增端点回包定稿**（见 §3.2） | 无现状可复刻，必须先定，否则插件无法开工 |
| C-09 | **复刻现状**：`POST /api/agents` 不提供建成员参数 | G 只做等量迁移；建成员 REST 入口登记 L-32 |
| C-10 | **保留** `GET …/specs` 的播种/升级写副作用 | 用户可见的规范文件更新依赖它 |
| C-11 | **逐字复刻**四个细节（sessions.message_count=0、conversations 无 404、token-rate 空 body 重置、DELETE 无 404） | 前端已按现状工作；修正登记 L-33 |
| C-12 | **复刻现状**（不拦 `sub_…`） | 语义待产品定；登记 L-34 |

### 3.2 C-08 定稿：两条新增端点的回包

#### `POST /api/agents/{agentId}/messages`

- **请求**：`{content: string（必填，trim 后非空）, session_id?: string, attachments?: array}`。字段与旧 WS `user_message` 帧一致；路径已带 `agentId`，body 里的 `agent_id` **忽略**。
- **成功 200**：`{success:true, agent_id, session_id, session_created:bool}`。`session_id` 是解析后的会话（请求为空且新建时回新 id）；`session_created` 供 UI 决定是否切会话（替代旧 WS 的 `session_created` 帧）。
- **失败**：`400 {"detail":"content 不能为空"}`（缺/空）；`404 {"detail":"未知 agent：<id>"}`；其余 `500` 兜底。
- **语义**：与 `ConversationService.handleUserMessage` 一致——落库 user 消息、打断同会话在途轮次、把回复入队；`sub_…` 收件人走同一条"直接对临时员工说话"路径（`sendToSubagent`）。
- **不新增反向请求通道**：生成过程仍由插件以广播 topic 推送（不变量 14/30）。

#### `POST /api/agents/{agentId}/cancel`

- **请求**：body 可空；可选 `{session_id?: string}`（只影响状态帧里带的 session）。
- **成功 200**：`{success:true, agent_id, cascade:bool, cascade_ids:[...], cancelled:[...], idle:[...], any_running:bool}`——即 `_stopAgentTree` 的摘要。`cascade` 在收件人是 `sub_…` 时为 `false`（只停它自己），否则 `true`（团队级联）。
- **语义**：与 WS `stop` 相同的级联与作废排队；**没有在途任务时仍回 200 + `any_running:false`**——不复刻 WS 的"没有进行中的任务可停止" error 帧（REST 用 200 + 空结果表达同一事实）。
- **失败**：`404 {"detail":"未知 agent：<id>"}`（REST 侧新增存在性校验）；其余 `500` 兜底。

---

## 4. 提取时登记的未决项（U1 ~ U13，原文保留）

### 4.1 原始提取清单

- U1 找不到键 missed：api_paths.dart:62 注释写 200 响应是 {ok, agent_id, stale, missed}，但 core_server.dart:2273-2277 只写 ok / agent_id / stale，SshReconnectOutcome 也没有 missed 字段（workspace_tool_runner.dart:872-910）。以代码为准：没有 missed。
- U2 状态码口径不一致：api_paths.dart:63 说 400 覆盖"不是 SSH 工作空间**或 SSH 配置不完整**"；代码里只有 resolveSshConfig==null（本地工作空间，即 not_ssh）是 400，而 _ioFor 失败/返回 null（SSH 配置不完整）走 SshReconnectOutcome.failed ⇒ **500**（core_server.dart:2280-2284、workspace_tool_runner.dart:680-688）。
- U3 agentCompact 的文档注释（api_paths.dart:54）写"核心尚未实现：显式 501"，实际已实现（_compactAgent:2292-2330），501 只在 compaction 服务未接线时出现。
- U4 协议包里没有 send_message / cancel：packages/tree_protocol 的 WsInbound 只定义 user_message / stop（ws_inbound.dart:13、16）；两个名字只存在于 api_paths 注释与设计文档 §1.3。新增端点的 body 字段只能从 conversation_service.dart:265-272 与 core_server.dart:3002-3012 读出（content / attachments / session_id；stop 为 data.{agent_id, session_id}）。
- U5 第 20/21 条的成功回包形状：核心未实现、设计文档 §1.3 未定义 ⇒（代码未明确）。连"是否带 agent_id 在 body 里"也未定义（REST 版路径已含 agentId）。
- U6 第 21 条的取消层级：WS stop 在核心层对 TOP 做团队级联（_stopAgentTree），而 ConversationService.cancelAgent 是 agent 级（含名下 subagent、作废排队、取消在途提问）。REST 版采用哪一层级联（代码未明确）。
- U7 错误体形状：任务描述里的 {ok:false,error} 不是核心实现路由的形状。核心是 {"detail": string}；只有委派传输层是 {"ok":false,"error":"service_unavailable","plugin_id","reason"}。迁移时插件应逐字复刻前者，否则前端错误解析会变。
- U8 非法 JSON 的 500：除 /compact 外，readJsonBody 的 FormatException 未在处理器内捕获（直接冒到 _dispatch 兜底 ⇒ 500），文档没有承诺这种行为，插件侧是否复刻（代码未明确 / 建议按 400 重新约定）。
- U9 类型错误也是 500：title / session_id / spec_ids / token_rate 用 as 强转，非期望 JSON 类型会抛 TypeError ⇒ 500（不是 400）。这属于当前实现的隐含契约，文档未写。
- U10 GET .../specs 的"只读"标签不准确：index→seedInto 会向工作空间写入/升级 .self/spec/*.md 并备份 .bak.N；GET 也能改工作空间文件（spec_service.dart:278-304、147-204）。
- U11 POST .../sessions 的响应 message_count 恒 0：因为 3236 调 toApiJson() 未传计数；前端若拿它判断"会话是否有消息"会得到错误结论（与 #3/#5 口径不同）。
- U12 handle 为空的 400 分支（_closeRunningTool:2234-2237）在正常 URL 路由匹配下不可达（/api/tools/running//close 不会匹配 {handle}）；保留为防御分支。
- U13 记录类型：第 20 条的附件形状来自服务端归一化后的落库形态 {name, path, size, type}；WS 帧实际接受 {path,name?,size?,type?} 或纯字符串，REST 版是否同样宽松（代码未明确，但"同形"意味着沿用）。
