# UI 插件化与核心收束（设计文档）

> 状态：已定稿（2026-10-20）。
> 定位：本文是**唯一的事实来源**。实施时若与本文冲突，先改本文再改代码。
> 范围：本仓（核心 + Flutter 前端）与 `tree-plugins` 仓的联动改动，一次性覆盖到终态。

---

## 0. 一句话

把「整个 Flutter 前端」做成插件平台里的**一种插件**（`kind: ui`），把原本由核心提供的**能力型 API** 逐组委派给插件，核心只保留内核状态与平台控制面。

**核心不是被冻结，是被收束。** 收束完成后核心不再需要为新增界面/功能而发版；新增能力全部落在插件侧。

---

## 1. 目标与非目标

### 1.1 目标

1. UI 前端可安装、卸载、启停、替换，与现有插件走**同一条**分发/落盘/生命周期管道。
2. 主题、布局、窗口形态（主窗口 / 悬浮球 / 托盘 / 多窗口）全部由 UI 插件自己决定，核心不感知。
3. 核心的 REST 面从 60 条收束到 **42 条永久内置 + 18 条委派**（JSON 7 + 二进制 11）。
4. 全部 UI 被卸载后，系统仍可恢复：由一个**不可卸载的极小引导壳**提供插件管理。
5. 删除旧的「插件 UI 面板协议」（受限控件集），站点体系成为插件对外的**唯一贡献面**。

### 1.2 非目标

- 不做 Flutter 运行时代码热加载（AOT 决定了做不到）。UI 替换的单位是**可执行体**。
- 不迁插件到 WS，也不迁 UI 到 stdio。传输按各自适配保留：stdio 给 headless 插件，WS 给 UI。
- 不让 UI 插件对外提供 API（`api/delegate` 只发普通插件）。
- 不引入工具审批层（既有设计事实，见 plugin/README 不变量 9）。

---

## 2. 终态架构

### 2.1 三个进程角色

| 角色 | 进程 | 传输 | 说明 |
| --- | --- | --- | --- |
| 内核 | `tree_core.exe` | HTTP + WS（127.0.0.1，随机端口 + token） | 常驻；唯一持有内核状态 |
| 功能插件 | `plugins/*` | stdio 行分隔 JSON-RPC 2.0 | 现状不变 |
| UI 插件 | `plugins/*`（`kind: ui`） | WS 客户端（`TREE_CORE_URL` + `TREE_CORE_TOKEN`） | 新增 |
| 引导壳 | `Tree.exe`（非 Flutter） | 拉起核心 + 打开浏览器 | 新增，**不可卸载** |

启动顺序由「UI 拉起核心」反转为「loader 拉起核心 → 核心按配置拉起 UI 插件」。

### 2.2 插件对外的三类贡献面

| 面 | 方向 | 用途 |
| --- | --- | --- |
| **广播站** | 核心 → 订阅者（增量事件） | 事件通知：工具调用、轮次、插件阶段…… |
| **收集站** | 核心 → 订阅者（请求/应答，取当前态） | 拉取快照：工具定义、点位声明、**API 路由声明** |
| **委派** | UI/任意客户端 → 核心 → 插件 | 插件承担原本核心的 REST 端点 |
| **发现面** | `/api/meta` 聚合 | UI 连接时枚举"我现在能用什么" |

一句话口径：**广播拿增量，收集拿当前态，委派替核心干活，发现面告诉 UI 这三样现在都有什么。**

发现面不是静态表：它把「委派路由」与「站点能力」两处收集站的结果聚合起来。**插件一申报，UI 可用的面就变长，核心零改动。**

### 2.3 UI 插件是单类型

核心**不区分**主界面 / 悬浮球 / 托盘 / 浮层。它只持有两条事实：

1. 哪些 UI 进程连着（`ui.hello` 自报 `plugin_id` / `version` / `capabilities`）；
2. 每条连接订了哪些站点。

窗口形态是 UI 插件自己的事。**「全功能界面」与「悬浮球」的差别退化为数据差异**——各自订阅哪些站点不同而已。

---

## 3. 协议变更总清单

> 顺序规则：**新增与修改先进 A–D 片，删除集中在 E 片**。任何提交都必须能独立通过门禁。

### 3.1 REST 新增

| 路径 | 方法 | 用途 |
| --- | --- | --- |
| `/api/meta` | GET | 发现面聚合：`core_version`、`api_version`、`ui[]`、`can_manage_plugins`、`routes[]`（委派）、`stations[]`（可订阅广播 + 可触发收集）、`capabilities[]`（插件申报，原样透传） |
| `/bootstrap` | GET | 送磁盘上的引导页 HTML（内容不冻结，可独立更新） |
| `/api/bootstrap/session` | POST | 一次性票据兑换短时会话 token |

### 3.2 WS 帧新增

| 帧 | 方向 | 说明 |
| --- | --- | --- |
| `ui.hello` | 上行 | UI 连接自我声明：`{plugin_id, version, capabilities[]}` |
| `station/subscribe` | 上行 | WS 侧订阅站点（仅允许广播站，含插件自建广播站）；可选 `topics[]` 只订公告板的部分 topic |
| `station/unsubscribe` | 上行 | 退订 |
| `station/register` | 上行 | UI 注册自建站（**只允许广播类型**，见 §6.8） |
| `station/unregister` | 上行 | 注销自建站 |
| `station/trigger` | 上行 | 触发收集站（取当前态）；也用于向自建广播站发布 |
| `station_delivery` | 下行 | 站点投递给 WS 订阅者：`{station_id, point, topic?, payload, scope, origin_plugin_id, state}`；`state` 取值 `data` \| `closed`（站点注销/插件下线时终止订阅，附 `reason`） |

### 3.3 插件 RPC 新增

| 方法 | 方向 | 说明 |
| --- | --- | --- |
| `api/delegate` | 核心 → 插件（请求/应答） | 委派一次 HTTP 请求；回包 `{status, headers?, body}` |

`api/delegate` 必须登记进 `PluginRpcMethods.coreToPlugin`，并同步 `plugin_rpc_method_gate_test.dart` 的计数基线。

### 3.4 点位新增（六件同时交付，见 plugin/README 不变量 30）

| 点位 id | 别名 | 类型 | 说明 |
| --- | --- | --- | --- |
| `system.collect.api.routes` | `api.routes` | 收集 | 插件按 schema 申报自己承担的 `{method, pattern}` 列表；核心缓存归属表 |

六处：表项（含四段式 readme）、`StationHubIds` 常量、进 `StationHubIds.all`、核心投递口（插件就绪/变更时触发一次）、派生用例计数、面板顺序。

### 3.5 清单元数据（`plugin.json` / `plugins.yaml`）

| 键 | 取值 | 归属 |
| --- | --- | --- |
| `runtime` | `python` \| `binary` \| **`ui`** | 第三档，与既有两档并列 |
| `routes` | `[{method, pattern}]`（可选，仅作开发期声明与面板展示） | 运行期**以收集站申报为准**，清单值不参与路由 |

`runtime: ui` 的条目在 `plugins.yaml` 中沿用既有字段；未知键保留规则不变。

### 3.6 删除（全部在 E 片）

| 对象 | 文件 |
| --- | --- |
| 受限控件集协议 | `packages/tree_protocol/lib/src/plugin_ui.dart` |
| UI 帧桥与缓存 | `packages/tree_core/lib/src/plugin/plugin_ui_bridge.dart` |
| 前端槽位注册表 / 渲染器 / 接入点 | `lib/ui/services/plugin_ui_registry.dart`、`lib/ui/widgets/plugin_ui_view.dart`、`lib/ui/widgets/plugin_ui_slots.dart` |
| 槽位接线 | `lib/ui/pages/main_page.dart` 内 activity / panel / status / card 四处 |
| 帧名 | `plugin_ui_manifest`、`plugin_ui_update`、`plugin_ui_action`（含 `WsInboundType.pluginUiAction`） |
| 文档 | `docs/plugin-development.md` §7.2 整节 |

插件侧依赖（`ssh_executor` 的 `ui_panel.dart`）由 `tree-plugins` 仓同步迁到站点广播，**不随本仓删除**。

---

## 4. API 端点归属总表（60 条全量）

> 判据：**卸载的是能力，端点跟着能力走。** 只把端点搬走、能力仍在核心，属于纯代理，不算卸载。

### 4.1 永久内置（42 条，不可委派）

**平台控制面（14）** — 装插件的前提，也是引导页唯一依赖。

| 端点 |
| --- |
| `GET /api/plugin/snapshot` |
| `GET|POST /api/plugin/configs`、`PATCH|DELETE /api/plugin/configs/{id}`、`POST /api/plugin/configs/{id}/restart` |
| `GET /api/plugin/builtins`、`POST .../{id}/enable`、`POST .../{id}/disable` |
| `GET /api/plugin/release`、`POST .../refresh`、`POST .../{id}/install`、`POST .../{id}/uninstall` |
| `GET /api/plugin/stations/{id}`、`PATCH .../{id}/config`、`POST .../{id}/subscribers/{key}` |

**agent / 模型 / 团队（10）** — 内核状态机（`agents.yaml`、模型池、团队关系）。

`GET|POST /api/agents`、`GET|PATCH|DELETE /api/agents/{id}`、`/models-info`、`/todos`、`/teammates`、`PATCH /api/agents/{leader}/teammate/{member}`、`/teammate/{id}/log`、`/teammate/{id}/message`、`GET|POST /api/models`、`PATCH|DELETE /api/models/{id}`

**会话 / 历史（6）** — 生成循环与落盘。

`GET|DELETE /api/conversations/{id}`、`GET|POST /api/agents/{id}/sessions`、`GET|PATCH|DELETE /api/agents/{id}/sessions/{sid}`、`POST .../specs`、`POST /api/agents/{id}/reset`、`POST /api/agents/{id}/compact`

**运行监督 / 提问 / 远端链路（7）** — 内核唯一持有的内存登记表与判活。

`GET /api/tools/running`、`POST /api/tools/running/{handle}/close`、`GET /api/agents/{id}/subagents`、`GET .../subagents/{sid}/transcript`、`GET /api/questions`、`POST /api/questions/{qid}/answer`、`POST /api/agents/{id}/ssh/reconnect`

**传输 / 判活设置（5）** — 交给插件会与传输层形成循环依赖。

`/api/settings/frame-rate`、`/token-rate`、`/heartbeat-interval`、`/missed-heartbeat-limit`、`/data-collection`

### 4.2 可委派 · JSON 面（7 条，批次 C-1）

| 端点 | 承接插件 | 说明 |
| --- | --- | --- |
| `GET /api/files/{ws}/git-status` | `git` | |
| `GET /api/workspaces/{ws}/git/log` | `git` | |
| `GET /api/workspaces/{ws}/git/branches` | `git` | |
| `GET /api/agents/{id}/specs` | `spec` | 工作空间文件 CRUD |
| `GET /api/agents/{id}/specs/{specId}` | `spec` | |
| `GET|POST /api/mcp/services` | `mcp` | 只搬**配置面**，MCP 客户端仍在核心 |
| `DELETE /api/mcp/services/{name}` | `mcp` | |

**硬规则：不得只搬 Git 三条。** C-1 的 7 条必须一次搬完、全部有对应用例；C-2 的 11 条同理。两组都搬完才算批次 C 完成。

### 4.3 可委派 · 二进制 / 大体积面（11 条，批次 C-2）

`/api/files/{ws}`（GET/DELETE）、`/content`（GET/PUT）、`/pdf_info`、`/upload_init`、`/upload_chunk`、`/upload_complete`、`/syncToLocal`、`/download`、`/download_folder`、`/mkdir`、`/rename`

**这些不再依赖核心的 `WorkspaceIO`。** 插件自身有磁盘权限，缺的只是路径——由委派信封的 `workspace_dir` 提供（§5.2）。

一条必须现在就定的约定（否则冻结后改不了）：**大体积 / 二进制不走 JSON 内联**。

| 方向 | 约定 |
| --- | --- |
| 大请求体（上传） | 核心先落临时文件，信封带 `body_path`，插件自己读 |
| 大响应体（下载） | 插件把结果写临时文件，回 `{result_path}`，核心流式回写并负责清理 |
| 小 JSON | 仍用内联 `body` / `result` |

禁止用 base64 把整文件塞进一行 JSON——那是几十 MB 级别的复制与内存峰值。

### 4.4 合计数

| 分类 | 条数 |
| --- | --- |
| 永久内置 | 42 |
| 可委派 · JSON 面（C-1） | 7 |
| 可委派 · 二进制面（C-2） | 11 |
| **合计** | **60** |

委派完成后核心**不再持有任何文件类、Git 类、Spec 类、MCP 配置类路由**。

`ApiPaths.kept` 语义随之改变：从「核心实现」变为「契约内路径」。新增静态集合 `ApiPaths.delegated`，门禁从 `router ∪ stub ⊆ kept` 改为 **`router ∪ stub ∪ delegated == kept`**。

---

## 5. 委派机制

### 5.1 声明：收集站

1. 插件就绪（`plugin_status: registered`）或路由声明变更时，核心触发收集站 `system.collect.api.routes`；
2. 订阅者按 schema 回 `{routes: [{method, pattern}]}`；
3. 核心缓存归属表 `method+pattern → plugin_id`；
4. 同一 `method+pattern` 被两家申报 ⇒ **整条拒收并记录可读原因**（不先到先得：路由归属必须确定，否则请求会随启动顺序漂移）。

### 5.2 查表与投递

请求路径：`_handle` 依次尝试 `router` → `stubRouter` → **`DelegatedRouter`** → 404。

匹配成功：
1. 核心完成 token 校验与四元组解析（fail-closed），把 `scope` 作为信封传给插件；
2. 发 `api/delegate`，信封字段**固定**为：

```
{method, path, params, query,
 headers(白名单), scope,
 workspace_dir, data_dir, agent_id, team_id,
 body?, body_path?,        // 小 JSON 用 body；大体积用 body_path
 request_id}
```

3. 插件回 `{status, headers?, body? | result_path?}`；
4. 核心原样写回，仅做 `Content-Type` 白名单与路径归属校验。

`workspace_dir` / `data_dir` / `agent_id` / `team_id` 是**只读上下文**，由核心从已校验状态中取出，插件不自行推导。这是「真卸载」与「假卸载」的分界线：有这些字段，插件才能自己读盘；没有，它只能反过来调核心的文件端点，一次请求变两次。

### 5.3 失败语义

| 情形 | 回包 |
| --- | --- |
| 插件未安装 / 已停用 | **503** + `{ok:false, error, plugin_id, reason}` |
| 插件在 `restarting/suspended/booting` | 进既有站点暂存队列（不变量 27） |
| 插件超时未回 | 不按墙钟杀；按"未响应"回 504 且可读 |
| 回包不合 schema | 502 + 可读原因（不把半成品当结果） |

**禁止 404**：404 表示"核心没有这个接口"，而在委派语义下真相是"承接方不在"，两者混淆会让用户去升级核心。

### 5.4 隔离

- 四元组校验**只在核心**做，插件收到的 `scope` 是已校验结果；
- 委派层不得放行 `delegated` 之外的路径（白名单静态化）；
- 插件不得通过 `api/delegate` 反向触发另一个委派（只允许核心发起）；
- **`api/delegate` 只发往普通插件（stdio）**。UI 插件是委派端点的消费者，不接收委派——它是 WS 客户端，传输上也不成立。

---

## 6. UI 插件

### 6.1 清单

```json
{
  "id": "tree_ui_default",
  "name": "默认界面",
  "version": "1.0.0",
  "runtime": "ui",
  "files": ["tree_ui_default.exe"],
  "command": "tree_ui_default.exe",
  "args": []
}
```

无 `role` / `entry` 字段。窗口形态只写在 `description` 里供人看。

### 6.2 `UiHost`

与 `PluginHost` 同级，职责极窄：

1. `Process.start`，注入 `TREE_CORE_URL`（`ws://127.0.0.1:<port>` 基址）、`TREE_CORE_TOKEN`；
2. **不做 stdio 握手**、不接 `tools/list`、不注册站点、不参与状态池与热重启续跑；
3. 判活 = 进程退出事件 + 该插件的 WS 连接是否在场；
4. 退出后按既有 `lifecycle` 置 `stopped`；被配置停用则不再拉起。

`PluginBus._startOne` 按 `kind` 分叉：`ui` 走 `UiHost`，其余两档路径**逐字不变**。

### 6.3 `ui.hello` 与身份

```
{type: "ui.hello", data: {plugin_id, version, capabilities: ["plugin.manage", ...]}}
```

- `plugin_id` 必须与 `plugins.yaml` 中某条 `runtime: ui` 条目**同串**，否则拒绝该连接（断开并记日志）；
- **scope 以声明为准**，不采信连接自述（对齐 plugin/README 不变量 11）；
- 订阅时 `scope` 留空 = 通配（订阅侧空 = 不设条件，见 `station_scope.dart`）；
- 订阅者身份键仍为 `plugin_id|scope`，用于**可列举**与**可单独禁用**——身份不用于过滤。

### 6.4 订阅权限

| 站点类型 | UI 可否订阅 | 理由 |
| --- | --- | --- |
| 广播（内置点位） | **可以** | 纯增量事件，多订阅者天然支持 |
| 广播（插件自建站） | **可以** | 插件推送给 UI 的主渠道，见 §6.7 |
| 收集 | 不可订阅；只能 `station/trigger` | 收集需要按 schema 回包与心跳，UI 走触发取当前态 |
| 中转 | 不可 | 中转站是**核心→插件的内部拦截链**，订阅即进入接管规则；UI 的功能扩展不走这条链，走委派端点 |
| 执行 | 不可 | 由核心命令驱动，无"触发一次"语义；UI 不在接收方白名单 |

**总纲：UI 能做什么 = 委派端点（插件主动提供 API）+ 广播站（插件主动推事件）。** 不通过订阅中转 / 执行站来扩展功能——那会把 UI 接进内核的调用拦截层，扩展面从此有两个来源。

越界订阅 ⇒ 可读拒绝，不静默降级。

### 6.5 多窗口

订阅是按**连接**而非按插件：一个 UI 进程可开 N 条 WS 连接，各订不同站点，每个窗口只收自己要的数据。多个 `kind: ui` 插件也可并存。核心不引入任何"窗口"概念。

### 6.6 `capabilities`

`plugin.manage` 表示"该连接所在 UI 能完成插件安装/卸载/启停"。`/api/meta` 聚合成 `can_manage_plugins`。

该能力**只影响要不要开引导窗**，不是权限边界（权限仍在核心）。自报失真最坏结果是作者自己的悬浮球让人装不了插件。

**未知 capability 一律原样透传到 `/api/meta`**，核心不解释、不校验。这样插件可以自报"我能渲染图表""我需要一个通知出口"之类，供 UI 之间互相发现——与 `system.collect.capability` 的自演进思路同口径。

### 6.7 插件 → UI 推送

后台插件要往界面推消息，**有三条路，全部不需要核心改代码**。优先级从高到低：

| 路 | 做法 | 适用 |
| --- | --- | --- |
| **自建广播站**（首选） | 插件 `station/register` 注册自己的广播站 → `station/trigger` 发布 → UI 订阅该站 | 有明确归属的持续事件流（下载进度、任务状态） |
| **通用公告板** | 插件向 `system.broadcast` 发布 `topic = "<plugin_id>.<event>"`，UI 订阅该站并可选 `topics[]` 过滤 | 零散通知；本站是持久公告板，**晚连上的 UI 能回看最近若干条** |
| 专用内置点位 | 核心加点位常量 + 投递口 | **不采用**：每加一个就要核心发版，正是本方案要消除的 |

约束：

1. **topic 命名必须带插件 id 前缀**，避免多家撞名；核心不解析 topic，只原样透传。
2. **UI 通过 `/api/meta.stations` 发现可订站**（内置点位来自核心，自建站来自 `system.collect.capability` 申报），不硬编码站名。
3. **插件下线时**核心必须给订阅者发 `station_delivery {state: "closed", reason}`，否则 UI 会挂着一条已死的订阅（静默失效，违反"失败可读"）。
4. **推送是单向。** 若插件需要 UI 回话：插件发一条广播（如"待确认"），UI 通过该插件提供的**委派端点**回传结果。请求方向始终是 UI→插件，不引入反向请求通道。

### 6.8 UI 自建站规则

UI 插件**可以**注册自建站，但只开放广播类型。

| 站点类型 | UI 可否注册 | 理由 |
| --- | --- | --- |
| 广播 | **可以** | 多窗口之间的事件总线、给其他插件看的界面状态 |
| 收集 | 不可 | 需要核心→WS 的请求/应答帧与超时语义，等于给 UI 开第二条 RPC；现有"广播 + 委派端点"已能表达同一流程 |
| 中转 | 不开放 | **注册自建中转站不抢占任何人**（自建与订阅是两回事）；但同一能力会因此有两种表达（自建站 vs 委派端点），`/api/meta` 出现两个来源，UI 不知道该用哪个 |
| 执行 | 不可 | 由核心命令驱动，UI 不在命令白名单的接收方之列 |

四条附属规则：

1. **归属按 `plugin_id`，不按连接。** 同一 UI 插件的多个窗口共享一份站点注册表；`station/register` 幂等，同 id 不同配置 ⇒ 可读拒收（不做覆盖）。
2. **注销条件是「该 `plugin_id` 的最后一条连接断开」或显式 `station/unregister`**。关掉一个窗口不得销毁其他窗口仍在用的站点。
3. **投递带 `origin_plugin_id`**：同一插件的其他窗口可以订阅自己的站（主窗口发"打开文件"，悬浮球订阅），据此判断是否忽略自环。
4. 自建站随 UI 进程退出一并注销，并向订阅者发 `state:"closed"`（不变量 15）。

典型用途：主窗口、悬浮球、独立预览窗三者在**不经过核心**的情况下互发事件。

---

## 7. 引导壳

### 7.1 触发判据

进入引导模式的条件（**二者之一**成立）：

1. `/api/meta.ui` 为空，且无 `runtime: ui` 条目处于 `booting`；
2. `ui` 非空，但**没有任何一条连接声明 `plugin.manage`**。

第 2 条是必须的：只剩一个悬浮球时，系统"看得见"却"装不上"，体验上等同不可用。悬浮球通常不内置插件安装页，因此它连上也应该开引导窗。

判据只看「有没有一条能管插件的 UI 连接」，**没有 main / aux 的概念**。

### 7.2 一次性 token 流程

1. loader 拉起核心，拿到主 token（握手首行，现状不变）；
2. loader 申请票据，得到 `http://127.0.0.1:<port>/bootstrap?t=<ticket>`；
3. 浏览器打开 → 核心校验票据并**当场作废**（单次使用）→ 返回 HTML；
4. 页面立即 `POST /api/bootstrap/session` 用票据换**短时（10 分钟）、仅限插件端点**的会话 token；
5. UI 连上后核心**吊销**该会话 token。

主 token 永不离开核心。票据关闭后如用户手动刷新，页面提示「链接已过期」，由 loader 托盘菜单**重签**一张。

### 7.3 HTML 页面职责边界

**只做插件管理**，共 11 条端点（全部已存在）：

`GET /api/meta` · `GET /api/plugin/configs` · `PATCH .../{id}` · `POST .../{id}/restart` · `GET /api/plugin/snapshot` · `GET /api/plugin/builtins` · `POST .../{id}/enable` · `POST .../{id}/disable` · `GET /api/plugin/release` · `POST .../refresh` · `POST .../{id}/install` · `POST .../{id}/uninstall`

**不含**「打开数据目录 / 查看日志」——那是本地 OS 动作，由 loader 托盘承担，核心不新增 `/api/system/*`。

页面轮询 `/api/meta`，`ui` 由空变非空时提示「界面已就绪，可关闭本页」。

页面**随核心种子化**到 `<数据根>/bootstrap/index.html`（与 `plugin_guide` 同一套种子化口径），因此可独立更新，不进冻结面；冻结的只有「存在 `/bootstrap` 这条路由」。

### 7.4 loader 职责

1. 拉起 / 附着核心（复用 `CoreProcessLauncher` 现有能力）；
2. 读 `/api/meta` 决定是否开引导页；
3. 托盘菜单：重新签发票据、打开数据目录、打开日志、退出；
4. **不使用 Flutter**——否则"卸掉全部 UI"之后仍背着几十 MB 运行时。

---

## 8. 不变量（本文档新增，编号独立）

1. **核心只增不改**：收束期内核心不得删除既有字段/路径，只有 `delegated` 白名单内的路径会从核心实现移出。
2. **卸载的是能力，不是端点**：端点离开核心必须伴随能力下沉；纯代理不算卸载。
3. **委派白名单静态化**：`ApiPaths.delegated` 是静态集合，门禁要求 `router ∪ stub ∪ delegated == kept`。
4. **委派失败禁止 404**：未装/停用 ⇒ 503，未响应 ⇒ 504，回包非法 ⇒ 502，均带可读原因。
5. **UI 订阅只限广播站**：中转 / 执行 / 收集的订阅一律可读拒绝。
6. **UI 身份以声明为准**：`plugin_id` 必须匹配 `plugins.yaml` 的 `runtime: ui` 条目，scope 取声明。
7. **UI 单类型**：核心不引入 `role` / `entry` / `main` / `aux` 概念。
8. **广播是增量，收集是当前态**：新连上的 UI 必须靠 `station/trigger` 取初始态，广播不负责重放。
9. **引导壳不可卸载**，触发判据是「零 UI 连接 **或** 无连接声明 `plugin.manage`」，不是「无主界面」。
10. **一次性票据单次使用**：兑换即作废；会话 token 短时且仅限插件端点。
11. **UI 进程不做 stdio 握手**：`UiHost` 不接工具表、不注册站点、不参与状态池。
12. **删除只在 E 片**：A–D 片一律只增不删，保证每个提交独立可用。
13. **发现面只聚合，不硬编码**：`/api/meta` 的 `routes` / `stations` / `capabilities` 全部来自收集站，核心不得维护第二份静态清单。
14. **推送单向**：插件 → UI 只走广播；需要回话时由 UI 调该插件的委派端点，禁止新增反向请求通道。
15. **站点下线必须可读**：插件注销自建站或下线时，核心向 WS 订阅者发 `station_delivery {state: "closed", reason}`。
16. **UI 可订插件自建广播站**：这是插件扩展 UI 推送面的唯一途径，不得限制为仅内置点位。
17. **UI 自建站只限广播**：收集 / 中转 / 执行一律可读拒收；归属按 `plugin_id`，最后一条连接断开才注销。
18. **自建站注册不覆盖**：同 id 重复注册幂等；同 id 不同配置 ⇒ 拒收并给原因，避免多窗口互相顶掉。
19. **UI 功能扩展只走委派端点**：插件主动申报 API 能力，UI 调用；**不得新增内置中转站作为 UI 扩展通道**，否则扩展机制出现第二套。
20. **自建与订阅分离**：注册自建站不构成对任何内置点位的占位；禁止以"抢占"为由拒绝合法注册，拒绝理由只能是机制分工。
21. **委派只发普通插件**：UI 插件是消费者；`api/delegate` 不走 WS。
22. **信封必带只读上下文**：`workspace_dir` / `data_dir` / `agent_id` / `team_id` 是固定字段，缺任何一个都视为契约不完整。
23. **二进制不走 JSON 内联**：大请求用 `body_path`，大响应用 `result_path`，禁止 base64 内联。

---

## 9. 迁移批次（全量，不允许中途停）

| 批次 | 内容 | 承接插件 | 完成判据 |
| --- | --- | --- | --- |
| B | 站点总线接 WS 订阅 + `/api/meta` | — | UI 能订广播、能触发收集 |
| C | **18 条**委派（C-1 JSON 7 条，C-2 二进制 11 条） | `git` / `spec` / `mcp` / `files` | 18 条全部由插件供，核心对应路由全部移除 |
| D | `kind: ui` + `UiHost` | — | 多个 UI 可并存、可独立卸载 |
| E | 引导壳 + 删除旧 UI 面板协议 | — | 卸掉所有 UI 后能从引导页装回 |

**批次 C 是一次性迁移，不接受"先做 Git 三条"的中间态。** C-1 与 C-2 各自必须整组完成；两组都完成才算批次 C 结束。若同组内某条阻塞，该组挂起，不拆开交付。

---

## 10. 实施切片 A–E

每片一提交，门禁顺序固定：`dart analyze`（无新增 error/warning）→ 受影响包全量 `dart test` → `tree_protocol` 契约测试 → 涉及 UI 才跑 flutter。

| 片 | 内容 | 涉及文件 | 验收 |
| --- | --- | --- | --- |
| A | 协议面新增 | `api_paths.dart`（+3 路径、`delegated` 集合）、`ws_inbound.dart`（+6 帧）、`ws_outbound.dart`（+1 帧）、`station_ws.dart`、`meta.dart`、`plugin_rpc_methods.dart`（+`api/delegate`） | 路径覆盖度与新帧编解码用例全绿 |
| B | 站点接 WS + meta + 推送通道 | `core_server.dart`（连接身份、`ui.hello`、`/api/meta`）、`station_instance.dart`（订阅通道抽象、`closed` 终止帧）、`stations.dart`（订阅与注册权限、`topics[]` 过滤、按 `plugin_id` 归属）、`plugin_bus.dart`（投递分流） | 订广播收到投递 / 订自建站收到推送 / 下线收到 `closed` / 订中转被拒 / 身份不符被拒 / 申报后 `meta` 增长 / UI 自建站只限广播 / 关窗不销毁 |
| C | 委派 + **18 条全搬** | `http_router.dart`（`DelegatedRouter`）、`core_server.dart`（查表点、信封构造、`body_path`/`result_path` 落盘与清理）、`station_points.dart`（新收集站）、`station_ids.dart`、`plugin_bus.dart`（`api/delegate` 路由）、移除 18 条核心路由 | 插件未装/停用/在位三态正确；`kept == router ∪ stub ∪ delegated`；大文件下载无完整内存驻留 |
| D | kind:ui | `builtin_plugins.dart`（`kindUi`）、`plugin_config_store.dart`（`runtime`）、`ui_host.dart`、`plugin_bus.dart`（`_startOne` 分叉）、`plugin_downloader.dart`（卸载目标） | 多 UI 并存；卸一个不影响其他；全停用后核心健康 |
| E | 引导壳 + 删除 | token 作用域注册表、`/bootstrap`、`/api/bootstrap/session`、`assets`→种子化 HTML、非 Flutter loader、删除 §3.6 全部对象 | 全量测试 + flutter；手工走通「卸光 → 引导页装回」与「只剩悬浮球 → 仍开引导页」 |

---

## 11. 测试清单

| 层 | 用例 |
| --- | --- |
| 协议 | 路径覆盖度（`kept == router ∪ stub ∪ delegated`）、新帧名登记、`api/delegate` 计数基线 |
| 核心 · 站点 WS | 订广播投递、越界订阅拒绝、`ui.hello` 身份不符拒绝、空 scope 通配、`topics[]` 过滤生效 |
| 核心 · UI 自建站 | 可注册广播；注册收集/中转/执行被拒；同 id 不同配置拒收；关一个窗口不销毁站点；最后连接断开注销并广播 `closed`；自环投递带 `origin_plugin_id` |
| 核心 · 推送 | 插件自建广播站 → UI 收到；插件下线 → 收到 `state:"closed"`；公告板晚连回看 |
| 核心 · 发现面 | 插件申报路由后 `meta.routes` 增长；自建站注册后 `meta.stations` 增长；未知 capability 原样透传 |
| 核心 · 委派 | 三态回包（503/504/502）、双家申报拒收、四元组与只读上下文透传、白名单外路径 404、`body_path`/`result_path` 流式与临时文件清理 |
| 核心 · 生命周期 | `kind: ui` 分叉不影响 python/binary；UI 退出置 stopped；卸载四段顺序 |
| 核心 · meta | UI 连接数、`can_manage_plugins`、委派摘要 |
| 引导壳 | 票据单次使用、会话 token 限权（插件端点外一律 401）、到期失效、**只有 `plugin.manage` 缺席时才开窗** |
| 前端 | 槽位相关用例随 E 片整体删除；`main_page` 无残留引用 |

---

## 12. 风险与回退

| 风险 | 缓解 |
| --- | --- |
| 委派增加一跳，长文件/大响应受影响 | 小 JSON 内联；大体积走 `body_path` / `result_path` 流式，内存不整块驻留 |
| 双家申报路由导致行为漂移 | 运行时拒收而非先到先得（§5.1） |
| UI 插件崩溃后无人管插件 | `can_manage_plugins` 为假 ⇒ loader 仍开引导页 |
| 删除 UI 面板协议后现有功能丢失 | E 片前先由 `tree-plugins` 迁完 `ssh_executor` 面板；E 片单独可回退 |
| 一次性票据被浏览器历史留存 | 票据单次使用 + 兑换即作废；主 token 不出核心 |

回退粒度：A–D 片都是纯增量，直接 revert；E 片是唯一不可逆提交，单独成一个 commit 便于整体回退。

---

## 13. 附：WS 面冻结清单

除 §3.2 新增帧外，以下既有面在收束后不再改动形状：

- 流式增量：`message`、`tool_start`、`tool_end`、`agent_status`、`agent_done`、`agent_error`
- 平台：`heartbeat`、`plugin_status`、`plugin_event`
- 终端：`terminal.*`（PTY 全部走 WS，不设 REST 端点）
- 上行：`send_message`、`cancel`、`answer_question`、`terminal.*`

新增键只允许**可选**，不得改动既有键的语义（对齐 plugin/README 不变量 25 的兼容口径）。
