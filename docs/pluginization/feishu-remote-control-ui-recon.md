# 飞书远程控制 UI 插件方案（FEISHU-REMOTE）

> **状态**：2026-11-24 侦查完成，**同日完成 D1~D8 拍板并回写方案**；本轮仍只改文档，不实施。
> **目标**：新增一个 `runtime: ui`、**声明 `plugin.manage`**、无主窗口的插件：常驻悬浮球，点击弹出飞书配置窗口；通过飞书机器人远程向 TREE agent 发消息并接收回复；顺带承担「UI 类插件启停」的最小管理面。
> **前置**：无。核心平台已具备多 UI 并存、能力自报、广播订阅、REST 委派与多窗口承载。
> **出口**：可行性结论、方案对比、切片与验收冻结；D1~D8 已拍板（§10）；不改代码、不改核心点位。

---

## 1. 结论先行

1. **可实施，且核心零改动**。平台已明确支持「多个 UI 插件并存」「UI 插件自定义主界面 / 悬浮球 / 面板形态」「UI 只订广播站 + 走 REST 委派」（[ui-pluginization.md §4.1.1/§6.5](ui-pluginization.md)、[ui-pluginization.md:24](ui-pluginization.md#L24)、[ui-pluginization.md:517](ui-pluginization.md#L517)）。
2. **「无实际窗口」只能是「无主窗口」**（D1 拍板 A）。悬浮球本身必须是窗口；严格零窗口只能用托盘图标 + 按需弹配置窗。采用形态：一个 56×56 透明无边框置顶窗口当球，点击原地扩成配置窗，可隐藏到托盘。
3. **飞书接入采用内置官方 SDK sidecar**（D7 拍板）。飞书长连接是 SDK 内能力（内置加密与鉴权），官方只提供 Go/Java/Python/Node SDK，无 Dart。随插件内置一个 Go sidecar（`oapi-sdk-go` 长连接 + 发消息 + 扫码建应用），Flutter 与 sidecar 走本机 stdio/回环通信。
4. **扫码注册是官方能力，不是自造**。飞书提供基于 OAuth 2.0 Device Authorization Grant（RFC 8628）的「一键创建应用」：出链接/二维码，用户扫码确认后直接返回 `client_id`/`client_secret`，并预置机器人能力、权限与事件订阅（默认长连接）。有效期 10 分钟、一次性。
5. **控制面数据齐全，不需新核心点位**。`tree.agent` 已自注册 agent 列表、会话、发消息、取消、提问作答、配置只读；回复流在广播站 `plugin.tree.agent.broadcast.events` 上，`msg_start` 自带 `kind=text|thinking`，工具事件独立成帧，天然可做「默认只发 agent 消息」。
6. **主要成本不在核心，而在三处**：飞书 sidecar 的构建与分发、最小插件管理封装、以及远程控制的安全模型。
7. **拍板改为声明 `plugin.manage`**（D2）：悬浮球就是「存活且声明管理能力」的 UI 连接，因此引导页不再自动开窗；插件内置一个最小管理封装，只做 `runtime: ui` 条目的启用/停用，并提供「打开插件管理引导页」逃生口（用核心 `POST /api/bootstrap/ticket` 拿一次性票据）。
8. **不做 agent 配置**（D3）：避免与默认 UI 两份实现漂移。配置窗只做 agent 选择、只读摘要与「去默认界面修改」提示；不复制模型/工具/记忆/提示词四个 tab。
9. **保活提示只维护一条消息**（D6）：每轮开始时发一条占位消息，任务仍在进行则每 60 秒原地更新为「已工作 N min」，结束时把同一条消息更新为最终答复或失败原因；不额外刷屏。

---

## 2. 需求拆解与判定

| 需求 | 判定 | 关键条件 / 依据 |
| --- | --- | --- |
| `runtime: ui` + 声明 manage | **可行（已拍板）** | `ui.hello.capabilities` 带 `plugin.manage`；核心不按插件 id 分支；球在线即视为可管理 UI，引导页不再自动开窗 |
| 最小插件管理封装 | **可行** | `GET /api/plugin/configs` + `GET /api/plugin/snapshot` 列 `runtime: ui` 条目；`PATCH /api/plugin/configs/{id}` 只发 `enabled`；`POST /api/bootstrap/ticket` 打开官方引导页 |
| 无主窗口 / 悬浮球 | **可行（有窗口）** | 悬浮球是「无边框 + 透明 + 置顶 + 不进任务栏」的小窗口；`window_manager 0.5.2` 已具备 `setAsFrameless` / `setAlwaysOnTop` / `setSkipTaskbar` / `setBackgroundColor` / `setIgnoreMouseEvents` |
| 飞书手动注册 | **可行** | 开发者后台建企业自建应用 + 机器人能力 + 权限 + `im.message.receive_v1` + 长连接；粘贴 App ID/Secret |
| 飞书扫码注册 | **可行（需实测租户）** | 官方 `registerApp` 设备流；预置权限/事件；返回凭据 |
| agent 选择 | **可行** | `GET /api/agents`、`POST /api/agents/{id}/sessions` 等均由 `tree.agent` 承接，UI 走 REST 委派 |
| agent 配置一致 | **不做（已拍板）** | 只读摘要 + 「去默认界面修改」；避免复制四个 tab 造成双实现漂移 |
| 默认只发 agent 消息 | **可行** | 事件帧可区分 `msg_start.kind=thinking/text` 与 `tool_start/tool_end` |
| 每分钟保活 | **可行** | 每轮仅一条消息；`PUT /im/v1/messages/{message_id}` 原地更新「已工作 N min」，完成时同条改为最终答复 |
| 特殊命令 `/help` `/new` 等 | **可行** | 插件侧解析；`/new` 调会话创建；`/stop` 调 cancel |
| 与默认 UI 并存 | **可行** | 多 UI 插件并存、连接级订阅互不影响 |

**可行性等级**：平台承载 高；控制面 高；飞书接入 中；浮窗体验 中；配置编辑 不做；安全 需自建；打包分发 中。

---

## 3. 平台事实（带证据）

| 事实 | 证据 | 对本插件的影响 |
| --- | --- | --- |
| 插件执行形态只有 `runtime: ui / headless`，`UiHost` 只注入 `TREE_CORE_URL`/`TREE_CORE_TOKEN`，不要求主窗口 | [ui-pluginization.md:411-423](ui-pluginization.md#L411-L423) | 可以有「无主窗口」的 UI 进程 |
| 主界面 / 悬浮球 / 面板形态由 UI 插件自己决定 | [ui-pluginization.md:24](ui-pluginization.md#L24) | 悬浮球是官方认可的形态，不需要核心新增窗口类型 |
| 多窗口 = 多进程；同一插件可开 `w1/w2`，核心注入 `TREE_UI_WINDOW_ID` | [ui-pluginization.md:224-231](ui-pluginization.md#L224-L231)、[ui-pluginization.md:682](ui-pluginization.md#L682) | 单窗口方案最稳；确需独立配置窗时可用 `POST /api/plugin/windows` |
| 多个 `runtime: ui` 插件可并存，核心不引入「窗口」概念 | [ui-pluginization.md:450-452](ui-pluginization.md#L450-L452) | 默认 UI + 飞书 UI 可同时在线 |
| `ui.hello` 必须自报 `plugin_id`/`version`/`capabilities`，`plugin_id` 必须匹配 `plugins.yaml` | [ui-pluginization.md:425-434](ui-pluginization.md#L425-L434)、实现见 [ui_identity.dart:59-76](../../plugins/tree.ui.default/lib/io/ui_identity.dart#L59-L76) | 身份从同目录 `plugin.json` 读取；本插件声明 `plugin.manage` |
| 引导页判据 = 不存在「存活且声明 `plugin.manage` 的 UI 连接」 | [ui-pluginization.md:556-562](ui-pluginization.md#L556-L562) | 拍板声明 manage 后不再触发；球自身成为引导页的替代管理面（仅 UI 类启停），见 §8 |
| UI 插件只能订广播站，不能触发其他插件的收集/执行站；上行白名单含 `station/*`、PTY、heartbeat | [ui-pluginization.md:517](ui-pluginization.md#L517) | 只能用广播站 + REST 委派 |
| 核心退出条件 = 所有 UI 窗口退干净；`_hasLiveUiWindow()` 遍历所有 UI 插件 | [plugin_bus.dart:1373-1417](../../packages/tree_core/lib/src/plugin/plugin_bus.dart#L1373-L1417) | 悬浮球活着，核心就不会因默认 UI 关闭而退出 |
| 一个 UI 进程可开 N 条 WS，连接级订阅；`plugin.manage` 只影响引导窗，未知 capability 原样透传 | 同上 §6.5 / §6.6 | 后续可扩展自定义 capability，不影响核心 |

**关键结论**：核心不需要为「多一个 UI 插件」改任何代码；插件只需在 `plugins.yaml` / 发布索引中出现，并按 `ui` 形态打包。

---

## 4. 飞书接入方案

### 4.1 两种注册方式

**A. 手动注册（稳定兜底）**

1. 开发者后台创建「企业自建应用」，添加机器人能力；
2. 开通应用身份权限：`im:message:send_as_bot`、`im:message.p2p_msg:readonly`、`im:message.group_at_msg:readonly`（群聊 @ 场景）、`im:resource`（文件/图片，v1 可不开）；
3. 事件订阅添加 `im.message.receive_v1`，订阅方式选「使用长连接接收事件」；
4. 创建版本并发布（企业内应用通常需管理员审核；个人版/自己就是管理员时可自审）；
5. 把 App ID / App Secret 填入悬浮球配置窗，sidecar 建连。

**注意**：长连接订阅方式保存时要求「至少有一个在线客户端」，否则保存失败（飞书文档明示）。手动流程因此有顺序要求：先让 sidecar 带着凭据跑起来，再去后台保存订阅方式。

**B. 扫码注册（官方一键建应用）**

- 协议：OAuth 2.0 Device Authorization Grant（RFC 8628）；
- SDK 返回验证链接（可渲染成二维码），链接形如 `https://open.feishu.cn/page/launcher?user_code=XXXX-XXXX&from=sdk...`；
- 用户在飞书内打开/扫码 → 选择「新建应用」或「已有应用」→ 确认后返回 `client_id` / `client_secret`，并已预置机器人能力、权限与事件订阅（默认 WebSocket 长连接）；
- 支持 `addons` 增量补权限/事件、`createOnly`、`appPreset`（头像/名称/描述）；
- 限制：10 分钟有效、一次性；仅适用于企业自建应用；扫码人需具备建应用/授权能力。

**判定**：两条都保留。扫码优先降低门槛，手动作为兜底与「已有应用复用」入口。

### 4.2 技术路线对比

| 路线 | 可行性 | 成本/风险 | 结论 |
| --- | --- | --- | --- |
| **内置 Go sidecar（官方 `oapi-sdk-go`）** | 高 | 需插件仓 CI 增加 Go 1.23+ 构建；单文件约 15~25 MB；长连接/加密/重连由 SDK 负责 | **推荐** |
| Dart 直接实现长连接协议 | 低 | 协议帧加密与鉴权在 SDK 内部，无公开 wire 规范；逆向风险与维护成本高 | 不采用 |
| 内置 `lark-cli`（开源 Go，约 48 MB） | 中 | 现成 `event consume` + IM 命令；但凭据注入/配置隔离/进程编排不受控，包体更大 | 仅作参考实现 |
| Webhook + 公网隧道 | 低 | 桌面端需要公网入口或第三方隧道，违背「开箱即用」；事件重试与验签另做 | v1 不做 |

**sidecar 职责边界**：
- 长连接接收 `im.message.receive_v1`，3 秒内 ack，转成 NDJSON 交给 Flutter；
- 发送/更新消息（`im/v1/messages`），持有 token 缓存；
- 扫码建应用（设备流轮询）与凭据校验；
- 不接触 TREE 核心、不读 agent 数据；与 Flutter 通过 stdio 或 `127.0.0.1` 随机端口 + 每次启动令牌通信。

### 4.3 飞书侧硬限制（会影响产品设计）

| 限制 | 数值 | 设计动作 |
| --- | --- | --- |
| 长连接事件处理时限 | 3 秒，超时重推 | 收帧立即入队并 ack，异步处理；按 `event_id`/`message_id` 去重 |
| 每应用长连接数 | 最多 50 | 单实例常驻即可 |
| 长连接投递模式 | 集群模式，同一应用多客户端只随机一个收到 | 同一 App 凭据只允许一个插件实例；重复启动需提示 |
| 单群发消息频控 | 约 5 QPS | 每会话串行发送，合并/节流 |
| 消息体上限 | 文本 150 KB，卡片/富文本 30 KB | 长回复分片；优先纯文本 |
| 消息更新频控 | 50 次/秒 | 流式卡片更新建议 1~2 秒一次或干脆只发最终结果 |
| 长连接适用范围 | 仅企业自建应用 | 商店应用/个人未认证场景需提示 |

---

## 5. 产品形态

### 5.1 窗口形态（D1 拍板 A）

| 方案 | 描述 | 评价 |
| --- | --- | --- |
| **A. 单窗口悬浮球（推荐）** | 56×56 透明无边框置顶窗口；点击原地扩为 420×560 配置窗；失焦可收纳；托盘常驻 | 与「悬浮球」需求一致；实现最简；不涉及多进程窗口 |
| B. 托盘图标 + 按需配置窗 | 平时零窗口，托盘点击弹配置窗 | 严格意义的「无窗口」，但没有悬浮球 |
| C. 悬浮球 + 独立配置窗口 | 球一个窗口，配置窗用 `POST /api/plugin/windows` 再开一进程 | 体验更接近桌面工具，但多进程状态同步成本高 |

A 的窗口能力已具备：`setAsFrameless` / `setAlwaysOnTop` / `setSkipTaskbar` / `setBackgroundColor(transparent)` / `setIgnoreMouseEvents`（`window_manager 0.5.2` 的 `lib/src/window_manager.dart:118-709`）。需在真机验证 Windows 10/11 透明背景、阴影、多屏 DPI 与点击穿透。

其他实现约束：
- 不申报 `branding`：核心按「最后一次有效申报」设置窗口/托盘/快捷方式图标，申报会抢占默认 UI 的品牌；
- 启动前应用 `TREE_APP_USER_MODEL_ID`（核心注入），保证任务栏归组；
- 单实例互斥（命名 mutex），避免同一 App 凭据多实例抢长连接；
- 托盘菜单至少：打开配置 / 暂停远程 / 退出。

### 5.2 配置窗口信息架构

| 页 | 内容 |
| --- | --- |
| 连接 | 飞书状态（未配置/连接中/在线/错误）、扫码注册、手动填 App ID/Secret、测试连接、应用信息（名称/机器人）、断开 |
| Agent | agent 列表与状态；远程默认 agent；按会话/群覆盖；只读摘要（模型/工具数/会话数）+「去默认界面修改」提示；**不提供配置编辑** |
| 消息 | 推送策略（默认仅最终回复；可开工具调用/思考摘要）、保活提示开关与间隔（默认 60s）、流式开关与节流、长消息分片、错误通知 |
| 命令 | 命令清单与说明、启用开关、别名 |
| 安全 | 首次绑定码、允许的飞书用户/群列表、群聊开关、高风险工具确认、审计日志入口 |
| 插件管理 | 仅 `runtime: ui` 条目：名称/版本/启停状态/进程与窗口数；启用 / 停用（含自身二次确认）；「打开插件管理引导页」逃生口（安装/更新仍走官方引导页） |

### 5.3 命令集（v1）

| 命令 | 行为 |
| --- | --- |
| `/help` | 返回命令与用法（也可注册机器人菜单） |
| `/new [标题]` | 为当前飞书会话新建 TREE 会话并切换 |
| `/agents` | 列出 agent 及状态 |
| `/agent <id\|名称>` | 切换当前飞书会话绑定的 agent |
| `/stop` | 取消当前会话在途请求 |
| `/status` | 显示 agent、会话、连接、队列状态 |
| `/bind <6位码>` | 首次绑定（未绑定前只接受该命令） |
| `/unbind` | 解除当前用户/群绑定 |
| 普通文本 | 发送给当前 agent；若绑定的是群，需 @机器人 |

v1 不做：文件/图片上下行、语音、卡片按钮回调、多用户角色与审批流。

### 5.4 飞书会话 ↔ TREE 会话映射

- 键：`chat_id`（单聊即用户）+ 可选 `open_id`；
- 值：`{agent_id, session_id, bound_at, title}`，持久化在插件自己的数据目录；
- 默认：每个飞书会话固定一个 TREE 会话，`/new` 轮换；插件重启后沿用；
- 同一 TREE 会话若同时在默认 UI 打开，双方看到同一消息流；发送侧需按会话串行，避免并发写。

### 5.5 保活提示与单消息生命周期（D6 拍板）

每个用户消息触发一轮任务，**整轮只维护一条机器人消息**，用更新代替刷屏：

| 时点 | 动作 |
| --- | --- |
| T0 收到消息 | 创建占位消息「已开始处理…」，记录 `message_id` / `chat_id` / `session_id` / `start_at` |
| 进行中 | 每 60 秒 `PUT /im/v1/messages/{message_id}` 更新为「已工作 N min…」；N 取整分钟；只在任务仍 active 时更新 |
| 完成 | 同一条消息更新为最终答复；超 150 KB 时本条放首段、剩余续发 |
| 取消 / 失败 | 同一条消息更新为「已停止」/「失败：原因」 |
| 等待确认 | 同一条消息更新为「等待你的确认」，问题与选项另发一条 |
| 新消息打断 | 同一会话最多一个 active 消息；先收口旧消息为「已中止（被新消息打断）」，再开新轮 |
| 插件重启 | 依据持久化的 active 记录，把旧消息更新为「连接中断，任务状态以 TREE 为准」，避免僵尸「已工作」 |

- 开关与间隔可配（默认开启、60 秒）；关闭后只在完成时发最终答复。
- 若开启流式，流式更新与保活共用同一条消息，按较短周期（建议 1~2 秒）节流，避免两条消息互相打架。
- 保活文案不展示工具名、思考内容与绝对路径；频控 60 秒一次，远低于飞书 50 次/秒更新上限。

---

## 6. 控制面映射（全部走 REST 委派 + 广播站）

| 能力 | 接口 / 帧 | 证据 |
| --- | --- | --- |
| agent 列表 | `GET /api/agents` | [delegate.dart:41](../../plugins/tree.agent/lib/src/delegate.dart#L41) |
| 会话列表 / 新建 | `GET/POST /api/agents/{id}/sessions` | [delegate.dart:44](../../plugins/tree.agent/lib/src/delegate.dart#L44) |
| 会话改名 | `PATCH /api/agents/{id}/sessions/{sid}` | 默认 UI 同名调用 [api_service.dart:2357](../../plugins/tree.ui.default/lib/io/api_service.dart#L2357) |
| 发消息 | `POST /api/agents/{id}/messages` `{content, session_id, attachments?}` | [delegate.dart:941-964](../../plugins/tree.agent/lib/src/delegate.dart#L941-L964) |
| 停止 | `POST /api/agents/{id}/cancel` `{session_id}` | [delegate.dart:968-980](../../plugins/tree.agent/lib/src/delegate.dart#L968-L980) |
| 历史 | `GET /api/conversations/{agentId}`、单条详情 | [protocol_contract.dart:24-30](../../plugins/tree.ui.default/lib/io/protocol_contract.dart#L24-L30)、[api_service.dart:602-658](../../plugins/tree.ui.default/lib/io/api_service.dart#L602-L658) |
| 提问作答 | 帧 `askUserQuestion` → `POST /api/questions/{qid}/answer` | [question_broker.dart:133-145](../../plugins/tree.agent/lib/src/agent/question_broker.dart#L133-L145)、[delegate.dart:52](../../plugins/tree.agent/lib/src/delegate.dart#L52) |
| agent 只读摘要 | `GET /api/agents/{id}`（**不提供 PATCH**） | 拍板 D3：配置编辑只在默认 UI，避免双实现漂移 |
| UI 插件清单 | `GET /api/plugin/configs`（过滤 `runtime: ui`）+ `GET /api/plugin/snapshot`（状态/进程/窗口数） | 核心自带点位，无需新增 |
| UI 插件启停 | `PATCH /api/plugin/configs/{id}`，仅发送 `enabled` | 同上；启用后核心按既有生命周期拉起 |
| 打开引导页 | `POST /api/bootstrap/ticket` 取一次性 URL，外部浏览器打开 | 安装/更新仍由官方引导页负责 |
| 保活消息更新 | `PUT /im/v1/messages/{message_id}` | 飞书编辑消息接口，见 §5.5 |
| 回复流 | 订阅 `plugin.tree.agent.broadcast.events` | [tree_agent_loop.dart:146-155](../../plugins/tree.agent/lib/tree_agent_loop.dart#L146-L155) |
| 事件形状 | `msg_start(kind=text/thinking)` + `msg_chunk`；`tool_start/tool_end`；`ask_user_question` | [conversation_service.dart:199-202](../../plugins/tree.agent/lib/src/agent/conversation_service.dart#L199-L202) |

**推送过滤**：默认只处理 `kind=text` 的 `msg_start`/`msg_chunk` 与最终消息；`thinking`、`tool_*` 仅在用户开启「全过程推送」时以摘要形式发送。提问帧必须推送（否则远程无法回答工具确认）。

**流式策略**：建议 v1 只发最终回复；开启流式时用「每 1~2 秒 update 一条消息」而不是每个 token 新建。`station_delivery` 的 `lagged`/seq 断裂时用历史接口补快照，避免丢帧。

---

## 7. 安全与可靠性

### 7.1 安全（远程控制 = 本机执行能力，必须默认拒绝）

1. **首次绑定**：悬浮球生成 6 位绑定码（10 分钟有效）；未绑定的飞书消息只接受 `/bind`；
2. **白名单**：绑定后记录 `chat_id` + `open_id`；其他用户/群一律拒绝并回提示；
3. **群聊默认关闭**：开启后必须 @机器人，且只允许白名单群；
4. **命令面最小化**：只解析固定命令，不接受任意 shell/路径；
5. **高风险工具**：建议为远程场景单独建一个 agent（受限 `tool_policy`），或要求工具提问必须确认；不复用本地全权 agent；
6. **凭据**：App Secret 不落明文展示、不写日志、不回显；优先用 `tree.settings` 的 secret 类型或 Windows DPAPI 加密后落盘；
7. **回传脱敏**：不把 `TREE_CORE_TOKEN`、App Secret、绝对路径等发到飞书。

### 7.2 可靠性

- 长连接断线指数退避重连，状态在配置窗可见；
- 3 秒内 ack，业务异步；重推按消息 id 幂等；
- 同一 App 凭据单实例（集群模式下多实例会随机丢消息）；
- 每会话发送串行 + 频控；长回复分片，失败重试一次；
- 核心重启后 `TREE_CORE_TOKEN` 会变，UI 重连后 sidecar 继续使用原飞书凭据即可；
- 事件订阅按连接恢复；`lagged` 时重拉历史，保证飞书侧不漏最终答复。

---

## 8. 生命周期与 manage 后的行为（D2 拍板）

| 场景 | 行为 | 设计动作 |
| --- | --- | --- |
| 悬浮球在线 | 存在声明 `plugin.manage` 的 UI 连接 ⇒ 引导页不再自动开窗 | 球承担最小管理面；默认 UI 缺失时由它启用或打开引导页 |
| 默认 UI 未运行 / 未安装 | 引导页不自动开；已安装则在本插件「插件管理」页启用；未安装则点「打开引导页」走官方安装/更新 | 逃生口必须显眼，避免用户无路可走 |
| 停用自己 | 二次确认；停用后球进程退出，若无其他 manage UI，核心回到引导页模式 | 按钮旁写明后果，不建议一键自停 |
| 无任何 UI 时核心启动 | 核心先起，浏览器引导页负责安装/启用；球安装并启用后接管管理面 | 保留官方兜底路径 |
| 悬浮球退出 | 若还有默认 UI / 其他 UI，核心不退；否则核心收尾退出 | 托盘「退出 TREE」二次确认 |
| 核心被杀 / 崩溃 | sidecar 在 Job Object 内被内核一并终止 | 下次启动核心重新拉起插件，长连接重建 |
| 插件升级 / 热重启 | 飞书短时不可用 | 配置窗显示「重连中」；active 保活消息收口为「连接中断」 |

**建议**：托盘提供「退出 TREE（含默认界面）」；仅关闭默认 UI 不视为退出应用，保证远程常驻符合预期。

---

## 9. 缺口与未知项（必须真机/真租户实测）

1. 一键创建应用在「个人版 / 非管理员」账号下是否可用；创建后是否免发布即可收发消息。
2. 扫码创建的应用是否已把订阅方式设为长连接（否则仍需在线客户端才能保存）。
3. 群聊 @ 机器人的事件与权限组合；是否需要 `im:message.group_at_msg.include_bot:readonly`。
4. 飞书卡片按钮回调是否必需；v1 纯文本命令能否覆盖答题与确认。
5. 透明置顶窗口在 Win10/11、多屏、不同缩放下的显示与点击穿透表现。
6. 「停用自己 / 停用最后一个 UI 插件」时核心与引导页的实际时序（是否立即退出、是否自动开引导页）；`PATCH enabled` 后 UI 拉起延迟与状态刷新间隔。
7. 同一 TREE 会话被默认 UI 与飞书同时写入时的并发语义；是否需要「远程独占会话」。
8. 远程附件（截图/文件）需求强度；v1 明确不支持是否可接受。
9. 飞书「更新消息」接口对文本消息的可编辑时限、`msg_type` 一致性与长文本截断行为，需真租户实测。
10. 无其他 UI 且未安装默认 UI 时，`POST /api/bootstrap/ticket` 在浏览器内的安装链路是否完整可用。

---

## 10. 拍板记录（2026-11-24，D1~D8 已冻结）

| ID | 事项 | 拍板结果 | 落地要点 |
| --- | --- | --- | --- |
| D1 | 窗口形态 | **A：单窗口悬浮球** | 56×56 透明无边框置顶；点击原地扩为配置窗；托盘常驻 |
| D2 | 管理能力 | **声明 `plugin.manage` + 最小插件管理封装** | 只列 `runtime: ui` 条目并做启用/停用；停用自身二次确认；提供「打开插件管理引导页」入口；原「非 manage」作废 |
| D3 | agent 配置 | **不做配置编辑** | 只做 agent 选择、只读摘要与「去默认界面修改」；不复制四个 tab |
| D4 | 秘钥存储 | **默认 `tree.settings` secret；不可用则 DPAPI** | 不落明文、不回显、日志脱敏 |
| D5 | 安全模型 | **绑定码 + 白名单 + 群聊默认关闭** | 建议远程使用独立受限 agent；高风险工具确认必开 |
| D6 | 推送默认 | **仅最终回复 + 提问必推 + 60s 保活** | 保活与最终答复共用同一条消息，原地更新；工具/思考默认关闭 |
| D7 | sidecar 形态 | **自研 Go sidecar（`oapi-sdk-go`）** | 长连接 + 发消息 + 扫码建应用；与 Flutter 走本机 IPC |
| D8 | 退出语义 | **球常驻；托盘「退出 TREE」二次确认** | 关闭默认 UI 不视为退出应用，保证远程常驻 |

未单列的实现细节按 §1、§5、§6、§7 的默认项执行；若实施中发现与飞书实测冲突，回到本文档登记后再改切片。

---

## 11. 切片与验收

| 切片 | 内容 | 门禁 |
| --- | --- | --- |
| **S1 插件骨架与外壳** | `plugin.json`（`runtime: ui`、`ui.hello` 声明 `plugin.manage`、不申报 branding）；悬浮球/托盘/配置窗壳；单实例；配置存取；`TREE_APP_USER_MODEL_ID`；最小插件管理封装（仅 `runtime: ui` 启停 + 打开引导页） | `dart analyze` 0 新问题；插件仓单测；打包自检 |
| **S2 飞书 sidecar** | Go 模块（`oapi-sdk-go`）：长连接、收发文本、扫码建应用、凭据校验、重连；与 Flutter 的本机 IPC | Go 单测；真租户手动/扫码各连通一次；断网重连 |
| **S3 控制面与消息生命周期** | agent/会话/发消息/取消/提问作答；事件订阅、过滤、聚合、幂等；命令解析；飞书会话映射；单消息保活（60s 原地更新 → 最终答复） | tree.agent 受影响套件全绿；UI 契约黑盒；真机单聊闭环 |
| **S4 配置与安全** | agent 选择 + 只读摘要 + 「去默认界面修改」；绑定码与白名单；推送/保活开关；错误与状态面；日志脱敏 | UI 单测；安全用例（未绑定/非白名单/群聊）；秘钥不回显 |
| **S5 打包发布** | sidecar 入包、版本、索引、文档、E2E 清单 | 产物自检；全新安装/覆盖安装；Release 资产 |

**验收用例（TC-FR）**：

| ID | 场景 | 判据 |
| --- | --- | --- |
| TC-FR-01 | 与默认 UI 并存 | 两窗同时在线；默认 UI 品牌图标不被抢占 |
| TC-FR-02 | manage 与引导页 | 球在线时不自动开引导页；管理页可启用/停用其他 UI；未安装 UI 时可打开引导页 |
| TC-FR-03 | 手动凭据 | 填 App ID/Secret 后在线；错误凭据有明确提示 |
| TC-FR-04 | 扫码建应用 | 二维码/链接可用；超时/拒绝有提示；成功后自动落配置 |
| TC-FR-05 | 单聊闭环 | 发「你好」→ agent 最终回复到达飞书；默认无工具/思考 |
| TC-FR-06 | 命令 | `/help` `/new` `/agents` `/agent` `/stop` `/status` 行为正确 |
| TC-FR-07 | 提问 | agent 提问推送到飞书，回复后 TREE 继续执行 |
| TC-FR-08 | 安全 | 未绑定/非白名单消息被拒；群聊未开启时拒绝 |
| TC-FR-09 | 长消息 | 超长回复分片且顺序正确，无 150 KB 报错 |
| TC-FR-10 | 恢复 | 断网、核心重启、插件重启后自动重连且不漏最终答复 |
| TC-FR-11 | 退出 | 托盘退出后无孤儿进程；默认 UI 关闭但球在线时核心不退 |
| TC-FR-12 | 去重 | 飞书重推同一事件不产生重复回复 |
| TC-FR-13 | 保活 | 长任务每 60s 只更新同一条消息为「已工作 N min」，完成时同条变最终答复，不新增刷屏消息 |
| TC-FR-14 | 插件管理 | 仅列 UI 类；启用/停用生效；停用自身有二次确认且核心按规则收尾 |

---

## 12. 不做

- 不新增核心点位，不改核心代码；
- 不做完整插件管理面板：仅 `runtime: ui` 的启用/停用；安装、更新、依赖管理走官方引导页逃生口；
- 不做 agent 配置编辑（模型 / 工具 / 记忆 / 提示词）；配置只在默认 UI 修改；
- 不声明 `plugin.manage` 之外的新能力；不按插件 id 做核心分支；
- 不支持飞书商店应用 / 多租户分发 / 公网 Webhook；
- v1 不支持文件、图片、语音上下行与卡片按钮回调；
- 不把默认 UI 的整仓代码引入；跨插件只走站点与 REST；
- 不改 `tree.agent` 的配置语义；远程与本地共享同一 agent 配置。

---

## 13. 关键证据索引

- 平台与形态：[ui-pluginization.md](ui-pluginization.md) §4.1.1 / §6.5 / §6.6 / §7.1；[ui-pluginization.md:24](ui-pluginization.md#L24)、[:224](ui-pluginization.md#L224)、[:450](ui-pluginization.md#L450)、[:556](ui-pluginization.md#L556)
- 插件清单与身份：[plugin.json](../../plugins/tree.ui.default/plugin.json)、[ui_identity.dart](../../plugins/tree.ui.default/lib/io/ui_identity.dart)
- 生命周期：[plugin_bus.dart:1373-1417](../../packages/tree_core/lib/src/plugin/plugin_bus.dart#L1373-L1417)
- 控制面：[delegate.dart:38-86](../../plugins/tree.agent/lib/src/delegate.dart#L38-L86)、[:941-980](../../plugins/tree.agent/lib/src/delegate.dart#L941-L980)、[question_broker.dart:110-150](../../plugins/tree.agent/lib/src/agent/question_broker.dart#L110-L150)、[tree_agent_loop.dart:146-155](../../plugins/tree.agent/lib/tree_agent_loop.dart#L146-L155)
- 配置字段：[api_service.dart:890-965](../../plugins/tree.ui.default/lib/io/api_service.dart#L890-L965)
- 管理面：[core_server.dart:2229-2250](../../packages/tree_core/lib/src/server/core_server.dart#L2229-L2250)（`GET /api/plugin/configs`）、[:2355-2413](../../packages/tree_core/lib/src/server/core_server.dart#L2355-L2413)（`PATCH` 启停）、[:657](../../packages/tree_core/lib/src/server/core_server.dart#L657)（`POST /api/bootstrap/ticket`）、[plugin_bus.dart:5976-6070](../../packages/tree_core/lib/src/plugin/plugin_bus.dart#L5976-L6070)（快照含 `runtime`/`status`/`windows`）
- 飞书：[使用长连接接收事件](https://open.feishu.cn/document/server-docs/event-subscription-guide/event-subscription-configure-/request-url-configuration-case?lang=zh-CN)、[一键创建应用概览](https://open.larkoffice.com/document/mcp_open_tools/integrating-agents-with-feishu/overview)、[NodeJS 扫码建应用](https://open.larkoffice.com/document/mcp_open_tools/integrating-agents-with-feishu/scan-to-create-an-app-in-one-click-nodejs)、[回复消息（长度限制）](https://open.feishu.cn/document/server-docs/im-v1/message/reply?lang=zh-CN)、[消息 FAQ（频控）](https://open.feishu.cn/document/server-docs/im-v1/faq?lang=zh-CN)、[编辑消息](https://open.feishu.cn/document/server-docs/im-v1/message/update?lang=zh-CN)
