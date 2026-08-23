# Tree 项目 8 大项改造 — 架构评审意见（v1）

> 评审人：晏清（架构师）｜日期：2026-08-22
> 评审对象：`docs/plan.md`（8 大项改造方案 v1）
> 评审方式：逐项对照真实代码核实假设后给出结论（风险点 / 修正建议 / 实现顺序）
> 结论先行：**方案总体成立、可实施**；5 项关键决策中 2 项存在必须修正的架构风险（取消机制边界、if_vision 透传），其余 3 项方向正确但需补细节。

---

## 0. 代码核实结论（评审依据）

| 方案假设 | 核实结果 | 出处 |
| --- | --- | --- |
| `get_agent_teammates` 读 `.self/team_roster.md` 文件 | ✅ 属实，`_parse_roster_table` 解析后叠加 `_active_tasks` | `agent/routes.py` |
| `_build_api_kwargs` messages 直接透传 `self.context` | ✅ 属实，无 vision 格式转换点 | `llm/llm.py` ~265 |
| `ModelConfig` 未知字段进 `extra` | ✅ 属实，`if_vision` 若放 yaml 顶层会进 extra | `config/models.py` `from_dict` |
| **extra 中未保留字段会被透传为 OpenAI 顶层参数** | ✅ **属实（关键风险源）** | `llm/llm.py` `_build_api_kwargs` 末尾循环 |
| `_run_completion_loop` 同步阻塞点：`for chunk in stream` + `handler(**args)` | ✅ 属实，两处均无取消检查 | `llm/llm.py` 385 起 |
| `chat()` 已有 `_repair_context()` 上下文自愈 | ✅ 属实（停止后上下文不一致已有兜底） | `llm/llm.py` `chat()` 入口 |
| `_store_message` / `_register_tools` 已带 session_id | ✅ 属实，全链路透传已有基础 | `agent/chat.py` |
| `team_store` 为权威表（teams/team_members），`render_roster_md` 生成视图 | ✅ 属实 | `data/team_store.py` |
| `read_tool._is_valid_path` 白名单 `[A-Za-z0-9/_.-]` | ✅ 属实，**拒绝空格/中文路径** | `tool/read_tool.py` |
| `GET /api/models` 已存在（model_id/name/max_seqlen） | ✅ 属实，models-info 需与其协调 | `agent/routes.py` `list_models` |
| `create_agent` 无条件 `init_team_for_top` | ✅ 属实 | `agent/routes.py` |

---

## 1. 会话隔离：session_id 全链路透传审计 —— ✅ 通过（方向正确）

**评价**：低风险、高收益的正确性修复，且代码已有较好基础（`_store_message`/`_register_tools`/`_build_member_topology_text` 均已带 session_id），审计工作量可控。

**风险点**：
- R1.1 隐式回退点不易穷举：`DEFAULT_SESSION` 作为参数默认值散落多处，审计时容易漏掉**工具执行内部**（team 消息投递 `_dispatch_agent_message`、MCP 调用）与 **agent_status / usage 记账**的推送路径，这些是"串会话"的隐蔽来源。
- R1.2 前端 `_modeLocked`"按历史动态判断"依赖后端返回的 session_id 正确性，后端一旦某条路径回退默认会话，前端锁定逻辑会被误导。

**修正建议**：
- 1-1 建立**审计清单式测试**：为每条「写路径」（`store_message`、`save_context`、agent_status 推送、usage 记账、tool 结果入库）各写一条用例，断言非默认会话下无 `DEFAULT_SESSION` 落库。
- 1-2 `DEFAULT_SESSION` 只允许出现在**显式缺省**的 API 入口（`session_id: str = DEFAULT_SESSION` 作为路由参数），**内部函数一律强制传参、禁止使用默认值**（可加类型/静态检查或注释约定）。
- 1-3 前端锁定逻辑依赖后端：审计完成后，后端在响应中显式回显 `session_id`，前端以回显值为准，不自行推断。

---

## 2. 停止按钮：cancel_event 的有效性边界 —— ⚠️ 有条件通过（必须补边界定义）

**核实结论**（方案自己也承认"阻塞在 tool/LLM 时停止无效"）：
`_run_completion_loop` 存在三类阶段，取消有效性不同：

| 阶段 | 是否可取消 | 说明 |
| --- | --- | --- |
| `while True` 循环开头（`_compress_context` 前后） | ✅ 可 | 加检查点即可 |
| `for chunk in stream` 流式接收 | ❌ **不可**（同步阻塞） | 期间无法响应 cancel_event，直到流结束 |
| `handler(**args)` 单个 tool 执行 | ❌ **不可**（同步阻塞） | 长命令（terminal 分钟级）期间停止无效 |
| tool_call 之间 / `on_tool_turn` 间隙 | ✅ 可 | 检查点自然存在，需显式检查 |

**风险点**：
- R2.1 **方案把「TerminalTool 超时」当作停止手段是概念混淆**：超时是"命令跑太久自动放弃"，停止是"用户主动终止"，两者语义不同。超时后应**终止进程**而非仅返回错误继续循环；停止时应**不再启动新 tool 调用**。
- R2.2 取消后上下文一致性：若在 tool_call 处理中断言（assistant 带 tool_calls、缺 tool 响应），下轮网关必返 400。虽然 `chat()` 已有 `_repair_context()` 自愈，但**自愈是下轮对话前触发**，停止场景应在**取消当下**主动修复。
- R2.3 生成器协议：cancel 后 `_run_completion_loop` 若直接 `return`/`break`，上层 `_stream_agent_reply` 无法区分"正常结束"与"被取消"，WS 推送与状态机（agent_status）需要显式 `{"type": "cancelled"}` 信号。

**修正建议**（按投入产出排序）：
- 2-1 **必做**：`AgentLLMSession` 增加 `cancel_event`（`threading.Event`），`_run_completion_loop` 在①循环开头②每个 `handler` 执行前③`handler` 返回后 三处检查；命中则 yield `{"type": "cancelled"}` 后 return。上层 `_stream_agent_reply` 收到后置 agent_status 为 cancelled/stopped，并**主动调用 `_repair_context()`** 修复上下文。
- 2-2 **必做**：`TerminalTool` 改为**进程级超时 + 可终止**——本地模式用 `subprocess.Popen`（`timeout` + `terminate()/kill()` 兜底 SIGKILL）；云端/ssh 模式用 docker exec 的 session 终止或设置命令超时参数。超时与停止都走同一"终止进程"路径，语义统一。
- 2-3 **可接受的有界不可取消区**：流式接收阶段（`for chunk in stream`）保持不可取消，但需在文档中**明示该边界**（通常 TTFB 后流式有界，秒级~数十秒），不作为 bug；若要彻底取消，可把 stream 迭代移入线程 + `client.close()`，复杂度高、收益低，**不建议 v1 做**。
- 2-4 停止后**不再启动新 tool**：检查点在 handler 前的目的即为此，需用测试断言"取消后无新 tool_call 发出"。

---

## 3. team 跨模式：get_agent_teammates 优先 team_store 表 —— ✅ 通过（方向正确，注意一致性）

**评价**：表是权威、roster 是视图（`render_roster_md` 已存在），优先读表是消除跨模式丢成员根因的正确做法，且 `team_tool._load_roster` 已先行验证过该模式可行。

**风险点**：
- R3.1 **双写一致性问题**（最需关注）：`team_tool._save_roster` 写文件、`team_store.update_member` 写表，两条写路径并存。若改表后不刷新 roster 视图文件，LLM 侧（读 `.self/team_roster.md` 注入 system prompt）与 REST 侧（读表）会看到**不一致拓扑**。
- R3.2 回退路径残留写逻辑：方案"表空回退 roster 文件"若只在读路径做，会掩盖"表为什么空"（老数据未迁移？建队失败？），且回退读文件得到的是旧格式，字段映射要与表查询对齐。
- R3.3 老用户数据迁移：存量 TOP 若在表引入前已建队（仅 roster 文件有数据），切读表后成员消失，属**数据迁移风险**，需一次性迁移脚本（roster → team_store）而非仅回退。

**修正建议**：
- 3-1 **统一写路径**：成员变更一律写 `team_store`（权威），随后**同步调用 `render_roster_md` 刷新 roster 视图文件**（LLM 侧继续读文件不受影响）。`team_tool._save_roster` 改为"写表 + 刷新视图"两步，杜绝旁路直写文件。
- 3-2 回退策略限定为**只读文件、不写**，且加日志告警（"表空，回退 roster 文件"），便于发现存量数据未迁移。
- 3-3 提供一次性**迁移函数** `migrate_roster_to_team_store`（解析 roster → upsert team_members），在启动或首次读表为空时触发；`create_agent_endpoint` 的无条件 `init_team_for_top` 保持不变（新建即建队）。
- 3-4 `get_agent_teammates` 返回字段需与前端契约逐一对齐（id/name/model/level/created_at/work_status/comment/role/duty/scores），直接查表映射，**去掉 `_parse_roster_table` 依赖**。

---

## 4. read_tool 图像：if_vision + vision content 数组 —— ⚠️ 有条件通过（存在透传事故风险，必须先行修正）

**核实结论**：`ModelConfig.from_dict` 把未知字段放入 `extra`，而 `_build_api_kwargs` **会把 extra 中未保留字段作为 OpenAI 顶层参数原样透传**。若 `if_vision` 仅放 yaml 顶层（进 extra）而不处理，**每次请求都会携带 `if_vision=true` 顶层参数**，OpenAI SDK 会因未知参数抛 `TypeError`（与方案中 `thinking` 曾遇到的问题同源，代码注释里已有先例）。

**风险点**：
- R4.1 **if_vision 透传事故**（最高优先级）：必须加进 `_build_api_kwargs` 的 `reserved` 集合，或改显式字段。
- R4.2 `read_tool._is_valid_path` 白名单**拒绝空格/中文**：图像文件（如「屏幕截图 2026-08-12 183834.png」）无法通过 read 读取；需在图像分支放宽校验或允许 base64 直传参数。
- R4.3 **IO 层二进制能力未核实**：`WorkspaceIO.read_file` 返回文本 str，读取图片二进制 → base64 需要扩展 IO 接口（或加 `read_binary`），plan 未提，实现时可能卡壳。
- R4.4 **tool 消息携带图像的兼容性**：OpenAI 规范允许 tool 消息 content 为数组，但**多数网关只支持 user 消息含 image_url**；plan 的"tool 结果文本插标记 + 图像 content"方案在网关层大概率 400。稳妥做法是图像随**下一轮 user 消息**携带。
- R4.5 上下文膨胀：base64 图像 token 开销大（约 1 token/3~4 字符），需限制数量与尺寸，且 `max_seqlen` 预算不含图像 token 时可能超限。

**修正建议**：
- 4-1 **首选显式字段**：`ModelConfig` 增加 `if_vision: bool = False` 显式字段（与 `thinking` 同构），`from_dict`/`to_dict` 同步；同时**无论如何把 `if_vision` 加入 `_build_api_kwargs` 的 reserved 集合**（双保险，防未来其他布尔元数据字段再踩坑）。
- 4-2 消息格式转换集中在 `_build_api_kwargs`：构建请求时扫描 `self.context`，将"含图像的用户消息"转为 `content: [{type:"text"...},{type:"image_url"...}]` 数组；assistant/tool 消息保持字符串不动。**仅当 `self.model_config.if_vision=True` 时转换**，非视觉模型不转换（天然降级）。
- 4-3 read 工具图像分支：路径校验放宽（允许空格/中文）+ 增加 `image_max_size`（默认如 1024px 内、单图 ≤1MB）缩放压缩后 base64；`image: true` 参数或扩展名自动识别二选一（建议扩展名自动识别 + 显式 `binary: true`）。
- 4-4 图像进上下文路径改为：**图像作为独立 user 消息**（或随下一轮 user 消息）`{role:"user", content:[text 描述, image_url]}`，不在 tool 消息里塞图——先与目标网关（deepseek-v4-flash-official）实测单图请求确认兼容，再定最终格式。
- 4-5 降级策略落地：`if_vision=false/缺失` → read 图像返回 `该模型不支持图像输入` 文本，工具定义对非视觉模型**不注册图像参数**（动态生成参数 schema）。

---

## 5. 新增 REST：MCP CRUD / agent PATCH / models-info —— ✅ 通过（注意职责边界与安全）

**评价**：三项接口均贴合现有架构，但存在两个前置依赖（`agent_store` 需加 update 方法；MCPManager 需具备服务生命周期管理）与一个安全红线。

**风险点**：
- R5.1 **models-info 与 `GET /api/models` 职责重叠**：现有 `list_models` 返回 model_id/name/max_seqlen，若新接口再返回一份模型信息，两处数据源不一致时前端无所适从。
- R5.2 **agent PATCH 的副作用**：改 model_id/system_prompt 后，**已缓存的内存会话（`session_cache`）与持久化 `agent_context` 仍持有旧配置**，不清理会导致"改了不生效/新旧混用"；且 PATCH **绝不能触发 `init_team_for_top`**（建队是 create 专属）。
- R5.3 **MCP services 注册 = 外部进程启动，安全红线**：允许任意命令/参数等于开放 RCE。服务启动/停止是高危操作（spawn 外部进程），需白名单 + 防注入 + 幂等启停。
- R5.4 MCP 服务配置持久化位置未定（config yaml vs DB），删除服务时进程清理顺序（先停进程再删配置）需明确。

**修正建议**：
- 5-1 **models-info 收敛**：不新增平行接口——扩展 `GET /api/models` 返回完整 info（thinking/if_vision/max_seqlen/base_url 脱敏/price），或新增 `GET /api/models/{model_id}` 详情；前端 create_agent_dialog 与右栏模型页共用同一数据源。若坚持 `/api/agents/{id}/models-info`，则内部复用同一序列化函数，禁止两份代码。
- 5-2 agent PATCH 语义：仅更新 `agent_store` 字段；成功后**清空该 agent 的内存会话缓存 + 软删/重建持久化上下文**（`clear_user_agent` + `clear_context`），并返回新的会话状态供前端刷新；**不重建团队**。需先给 `agent_store` 加 `update_agent`。
- 5-3 MCP CRUD 安全设计：注册时**服务端校验**——命令必须是绝对路径/白名单内可执行文件，参数为固定字符串列表（禁止 shell 元字符 `|;&$()`、禁止 `--shell`/`-c` 类参数）；启动失败回滚；DELETE 先 `stop` 再删记录；配置持久化到 DB（与现有 agent/team 存储一致），config yaml 仅作初始 seed。
- 5-4 接口命名统一：`/api/mcp/services`、`/api/agents/{id}` (PATCH)、`/api/models`（扩展）——避免 `models-info` 这类动词式路径，保持 REST 资源式风格。

---

## 6. 实现顺序建议（含依赖关系）

```
P0  [可并行] 正确性三件套（commit A）
   ├─ 1 会话隔离审计（无依赖，独立）
   ├─ 2 停止 cancel_event + TerminalTool 进程终止（无依赖，独立）
   └─ 3 team 跨模式读表 + 迁移脚本（无依赖，独立）
P1  read_tool 图像（commit A 内，依赖 ModelConfig.if_vision 先行落地）
   ├─ 4.1 ModelConfig.if_vision 显式字段 + reserved 双保险  ← 最先做（堵透传事故）
   ├─ 4.2 IO 层 read_binary 能力（若缺）
   ├─ 4.3 vision 消息格式 + 网关实测（deepseek-v4-flash-official）
   └─ 4.4 降级策略
P2  新增 REST 三件套（commit B，依赖 agent_store.update；models-info 依赖 P1 的 if_vision）
P3  前端（commit C：会话右键 / 右栏 Tab / markdown 复制 / UI）依赖 P2 接口就绪
P4  桌面图标（commit D，纯资源，零依赖，可与 P0 并行）
P5  全量回归 + 文档 + spec 沉淀（commit E）
```

**关键依赖提醒**：
- `if_vision` 字段是 P1/P2 的共同前置，**应作为 commit A 的第一笔改动**（连带 `_build_api_kwargs` reserved 修正，属 bug 级修复）。
- 前端右栏模型信息页依赖 models-info 数据，故 REST 不能晚于前端开发。

---

## 7. 结论

| 决策 | 结论 | 关键动作 |
| --- | --- | --- |
| 1 会话隔离 | ✅ 通过 | 审计清单测试 + 内部函数禁默认会话 |
| 2 停止按钮 | ⚠️ 修正后通过 | 补边界定义；TerminalTool 进程级终止；取消当下修复上下文；yield cancelled 信号 |
| 3 team 跨模式 | ✅ 通过 | 统一写路径（写表→刷新视图）；一次性迁移；回退只读+告警 |
| 4 read_tool 图像 | ⚠️ 修正后通过 | if_vision 显式字段 + reserved 双保险；图像走 user 消息；放宽路径校验；先网关实测 |
| 5 新增 REST | ✅ 通过 | models-info 收敛复用；PATCH 清缓存不建队；MCP 注册安全红线 |

**风险优先级排序**：R4.1（透传事故，必现）> R2.1/R2.2（停止语义与上下文一致性）> R3.1（双写不一致）> R5.3（MCP RCE 红线）> 其余。

**一句话结论**：方案 v1 整体可实施；先修 `if_vision` 透传与停止语义两个架构缺陷，再按 P0→P5 顺序推进即可。
