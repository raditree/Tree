# UI 插件化验收清单

> 配套：[ui-pluginization.md](ui-pluginization.md)（核心侧设计）、[ui-pluginization_detailed.md](ui-pluginization_detailed.md)（首个 UI 插件构建）、[agent_pluginization.md](agent_pluginization.md)（agent 插件化）。
> 本文只回答一个问题：**每个批次做到什么程度算完成。**

## 0. 判定原则

1. **可复现**：每条验收都给操作步骤与观测点，不写"功能正常"这类不可判定的描述。
2. **无降级通过**：不允许"基本通过""除某场景外通过"。任一验收项失败 ⇒ 该批次不完成。
3. **删除必须与交接同批**：核心侧代码只有在插件侧对应验收项通过后才可删除（不变量 27）。
4. **缺陷分级**：P0 = 数据丢失/静默失效/越权；P1 = 可读失败但功能不可用；P2 = 文案与体验。P0/P1 未清零不得推进下一批次。

## 1. 通用门禁（每片必跑）

| 门禁 | 命令 | 期望 |
| --- | --- | --- |
| 静态检查 | `dart analyze packages/tree_protocol packages/tree_core` | 无新增 error / warning |
| 协议测试 | `dart test packages/tree_protocol` | 全绿 |
| 核心测试 | `dart test packages/tree_core` | 全绿 |
| UI 测试 | `flutter test` | 仅 E 片与 UI 插件片需要 |
| 领域词检查 | `rg -n "agents\|sessions\|questions\|teammates\|models" packages/tree_core/lib` | 批次 G 后仅命中 `migration/` 与兼容映射白名单 |

## 2. 批次 A：协议面

| ID | 操作 | 期望 |
| --- | --- | --- |
| A-1 | 运行路径覆盖度用例 | 核心 router 键集 == `coreOwned`（39）；`coreOwned ∩ delegated == ∅`；`pendingHandoffRoutes` 为空集；核心 router 路径 ⊆ `kept` |
| A-2 | 检查新增路径 | `/api/meta`、`/bootstrap`、`/api/bootstrap/session` 在 `kept` 内 |
| A-3 | 编码/解码新帧 | `ui.hello`、`station/subscribe`、`station/unsubscribe`、`station_delivery`、`station/trigger`、`station/register`、`station/unregister` 往返一致 |
| A-4 | 契约防漂移 | 删除任一路径或改任一帧名 ⇒ 契约测试变红（故意改一次验证后还原） |
| A-5 | 委派命名空间（L-28 + 双跑） | 自造 `/api/x` ⇒ 可申报且出现在 `/api/meta.routes`；保留前缀（`/api/plugin/...`）与 `coreOwned` 同键 ⇒ 可读拒收；**核心已实现的同键 ⇒ 接受并标 shadowed**（归属表/meta 可见，HTTP 仍由核心承接），核心删实现后自动生效 |

## 3. 批次 B：站点总线接 WS

前置：核心启动，装一个测试插件（含一个自建广播站）。

| ID | 操作 | 期望 |
| --- | --- | --- |
| B-1 | UI 连 WS → `ui.hello` → `station/subscribe` 订自建广播站 → 插件发布 | UI 收到 `station_delivery{state:"data"}`，`origin_plugin_id` 与 `topic` 正确 |
| B-2 | 空 scope 订阅 | 收全量事件（不因 team/mode 缺失漏收） |
| B-3 | `topics[]` 过滤 | 只收指定 topic，其余不投递 |
| B-4 | 订阅内置中转站 / 执行站 / 收集站 | 三种均被可读拒绝，错误码与原因明确 |
| B-5 | `ui.hello` 报未在 `plugins.yaml` 声明为 `runtime: ui` 的 id | 拒绝连接，原因可读 |
| B-6 | 插件下线 | 该站订阅者收到 `station_delivery{state:"closed", reason}` |
| B-7 | 插件申报路由/能力后读 `/api/meta` | `routes` / `stations` / `capabilities` 增长；核心无静态清单可对账 |
| B-8 | 两条 UI 连接同时订阅 | 各自独立投递；一条断开不影响另一条 |
| B-9 | UI 发布自有自建广播站 → 另一条 UI 连接订阅 | 投递成功（自环允许，带 `origin_plugin_id`） |
| B-10 | UI 向他人自建广播站发布 | 可读拒绝 |
| B-11 | UI 连上后核心触发 `system.collect.ui.branding` | 收到申报回包；**先后两个 UI 申报，后者生效**；后一个断开后回退到前一个 |

## 4. 批次 C：18 条委派

前置：`mcp` / `files` 插件已交付；spec 2 条由 tree.agent 承接（无独立 spec 插件）；**git 已删除，不再交付**。

| ID | 操作 | 期望 |
| --- | --- | --- |
| C-1 | 18 条端点逐一请求，插件已在位 | 200/正常回包，由插件处理；核心实现按 3.6 暂留，待仓外插件交付后同批删除 |
| C-2 | 归属插件未安装 / 已停用 / 已销账 | 停用或下线 ⇒ **503**；**未申报**或归属表已无该路由 ⇒ 404。两者都不得把「有归属但不可用」伪装成 404 |
| C-3 | 插件已安装但停用 | 503 + 原因区分"停用"与"未安装" |
| C-4 | 插件在位但超时不回 | 504 + 原因 |
| C-5 | 插件回包 schema 非法 | 502 + 原因 |
| C-6 | 两家插件申报同一 `method+pattern` | 整条拒收并记原因，不按启动顺序择一 |
| C-7 | 委派请求信封 | 必含 `workspace_dir` / `data_dir` / `agent_id` / `team_id`；缺任一 ⇒ 视为契约不完整（插件侧可读失败） |
| C-8 | 上传 100MB 文件 | 走 `body_path`；信封不含内联体、文件字节精确、分块流式、结束清理。RSS 采样在同进程测试不可靠，以结构断言为准（若要 RSS 基线，需独立进程压测） |
| C-9 | 下载 100MB 文件 | 走 `result_path`；不得 base64 内联；结束临时文件被清理 |
| C-10 | 路径归属校验 | 插件返回的 `result_path` 指向自己命名空间之外 ⇒ 拒收 |
| C-11 | 迁移期核对 | 18 条在插件侧 C-1..C-10 全绿**之后**才删除核心实现（同一 commit） |

## 5. 批次 D：`runtime: ui`

| ID | 操作 | 期望 |
| --- | --- | --- |
| D-1 | 启用两个 `runtime: ui` 插件 | 两个进程并存，各自连 WS，`/api/meta.ui` 两条 |
| D-2 | 卸载其中一个（正在运行） | 进程退出、文件可删（无占用）、另一个不受影响 |
| D-3 | 全部停用 | 核心健康、`/api/meta.ui` 为空、其余端点正常 |
| D-4 | UI 进程崩溃 | `plugin_status` 变 `failed`（正常停止才是 `stopped`），`disabled_reason` 注明异常退出；不反复拉起（除非配置允许） |
| D-5 | 检查 `UiHost` 行为 | 不发 `tools/list`、不注册站点、不进状态池；日志中无握手记录 |
| D-6 | 注入环境 | UI 进程拿到 `TREE_CORE_URL` / `TREE_CORE_TOKEN`，能直连核心 |
| D-7 | 未实现 `tools/list` 的普通插件 | 仍能正常上线（核心不生成工具占位、不写专用日志、不新增工具接口），与 UI 无关 |
| D-8 | 启用一个依赖 `tree.agent >=1.0` 但未安装该依赖的 UI | **409** + 结构化 `missing_dependencies`；不得启动进程 |
| D-9 | 点击"自动安装依赖" | 只补齐缺失，**不升级**已装插件；成功后原插件可启用 |
| D-10 | 两个插件要求同一依赖的不同不兼容区间 | 可读失败，逐条列出各方要求；不得擅自择一 |
| D-11 | 依赖成环（A→B→A） | 拒收并列出环路径 |
| D-12 | 卸载被依赖的插件 | 提示"N 个插件依赖它"；确认后依赖方被**停用**而非卸载 |

## 6. 批次 E：引导壳与旧协议删除

| ID | 操作 | 期望 |
| --- | --- | --- |
| E-1 | 卸光所有 UI 后重启 | loader 不死；自动打开 `/bootstrap?t=...` |
| E-2 | 票据复用 | 同一票据第二次使用 ⇒ 401 可读原因 |
| E-3 | 引导页权限 | 用引导会话 token 请求非插件端点（如 `/api/agents`）⇒ 403 + 可读原因（只放行插件端点与 `GET /api/meta`） |
| E-4 | 引导页装回一个 UI | 安装 → 自动拉起 → `/api/meta.ui` 非空 → 页面提示可关闭 |
| E-5 | 只剩悬浮球（未声明 `plugin.manage`） | 仍打开引导页（判据为"无连接能管插件"） |
| E-6 | 只有悬浮球且声明了 `plugin.manage` | **不**打开引导页 |
| E-7 | 会话 token 生命周期 | UI 连上后引导会话 token 立即失效 |
| E-8 | 控制台"重新签发票据" | 生成新票据并可打开页面（本期 loader 为控制台菜单，托盘延后） |
| E-9 | 旧协议残留 | 全仓 grep 无 `plugin_ui_manifest` / `plugin_ui_action` / `PluginUiRegistry` / `plugin_ui_view` 引用 |
| E-10 | 现有 UI 回归 | 卸载 UI 面板协议后，主界面既有功能（会话、文件、设置等）逐项可用 |
| E-11 | UI 条目声明了 `plugin.manage`，但**被停用** | **仍然打开引导页**（判据只认活连接） |
| E-12 | 仅在 `plugin.json` 静态声明 `plugin.manage`、从未连接 | 不抑制引导页 |
| E-13 | 有效图标申报 | loader 把快捷方式 `IconLocation` 指向插件目录的 `.ico`；窗口/托盘图标由 UI 插件自己应用；**exe 文件本身未被改写**（哈希不变） |
| E-14 | 超限图标（过大 / 尺寸不足 / 目录外路径 / URL） | 拒收并可读原因，回退默认图标，不留旧图 |
| E-15 | 申报图标的文件被删除后重启 | 回默认 + 一条可读日志；不出现破图 |

## 7. 批次 F：日志与存储

| ID | 操作 | 期望 |
| --- | --- | --- |
| F-1 | `GET /api/logs/sources` | 列出核心与各插件日志源 |
| F-2 | `GET /api/logs/tail` | 尾部读取，支持行数上限；大文件不整块载入 |
| F-3 | `POST /api/logs/clear` | 清空后可读，且不影响写入中的文件 |
| F-4 | `PUT /api/store/{ns}`，`ns == plugin_id` | 成功，返回 `etag` |
| F-5 | 同一键旧 `etag` 覆盖 | 409 + 可读原因 |
| F-6 | `ns != plugin_id` | **403**，不泄露其他命名空间是否存在 |
| F-7 | 配额超限 | 可读失败，不影响核心其他功能 |
| F-8 | 核心不解值内容 | 存入任意二进制/JSON 后原样取回 |
| F-9 | 启动一个向 stderr 写行的插件 | `/api/logs/plugin:<id>` 能读到 `[stderr] <原始行>`（核心负责落盘，插件不建日志文件） |
| F-10 | 插件发 `log` 通知（带 level/message） | 同一源能读到 `[notify:<level>] <message>`，且 `plugin_event` 广播行为不变 |

## 8. 批次 G：agent 面交接

细节见 [agent_pluginization.md](agent_pluginization.md) §5/§7；本仓侧验收：

> **2026-10-25 状态：A1 骨架已完成（tree-plugins `3704101`）；G-1~G-7 的等价验收尚未开始。**
> A1 证据：`--selftest` 8 项全绿；真核心拉起 AOT 产物后 ready，stderr 与 `log` 通知两路日志都出现在
> `/api/logs/plugin:tree.agent`，`enabled:false` 热应用后下线。A2~A5（只读面 / 写路径与生成 / 帧迁移 /
> 核心删除）仍按 [agent_pluginization.md](agent_pluginization.md) §6 与 [agent_api_contract.md](agent_api_contract.md) 推进。
> A2 进行中：`api/delegate` 管道 + `GET /api/agents`、`GET /api/agents/{id}`、`GET …/teammates`、
> `GET /api/conversations/{id}`、`GET …/sessions`、`GET …/sessions/{id}`、`GET …/todos`、`GET …/subagents`、
> `GET /api/models`、`GET …/models-info` 已用 `packages/tree_core/tool/verify_agent_equivalence.dart`
> 做双跑对照（12 条均状态码 / Content-Type / body 逐字节一致）。仅剩 tools-running（依赖工具层随迁，A3 再搬）。
> A3 已开工：存储层（FileTreeStore / records / TreePaths / YAML / 原子写 / 写队列 / 子 agent 注册表 /
> 容错 UTF-8 解码）已平移到插件包并通过独立自检；领域设置（模型池 / token 速率 / 覆盖 /
> token_scale 学习）也已平移，模型只读视图改为与生成循环同源；提问回路与待办存储（含读写）
> 也已平移并通过移植的核心契约测试；LLM 协议层（类型/编解码/SSE 传输）与引擎契约、
> 脚本引擎也已平移；生成循环的兼容门面（插件侧 CoreSettings）、帧常量/序号兼容层与
> 提示词小件、用量账本、工具结果门控与团队工作目录口径也已就位（插件测试 123 条）；
> `workspace_prompt` 与 `compaction_service` 已平移并通过移植的核心测试（插件测试 160 条）；
> `private_workspace_io` 的 WorkspaceIO 装饰器留到执行站接线后再搬。ConversationService 已平移
> （脚本引擎可跑，流式序号/分段测试通过；WsHub 用最小帧出口、LLM 专属轮内压缩钩子暂缺）。
> C-08 两条新端点（发消息/停止）已接，由插件内 `AgentRuntime` 承载；`LlmAgentEngine` 已平移并
> 切为默认引擎（compaction/usage 接线、轮内压缩钩子恢复），工具执行器暂为 `EmptyToolRunner`。
> `tools-running` 两条路由已接（登记表随工具编排接线填充），**A2 只读面全部完成**。
> 下一步：工具编排（`workspace_tool_runner` + 执行站）让真实工具跑起来。
> **口径修正**：A5 已于 2026-10-25 提前删除核心领域实现；本段「核心路由与领域帧保持原样」仅代表 A1~A4 期间的历史口径，现已被 A5 取代（见下条与 §12.G）。

> **2026-10-25 A5 审计（最新）**：核心领域实现已清空（router == coreOwned 36；七个领域目录不存在），**G-2 达成**；G-1 进行中（36 条申报；12 条双跑 + H1 24 条真实 HTTP 对照：21 一致 / 3 已知差异）；G-3 部分（核心不再产生领域帧，插件广播站未接）；G-4~G-7 未完成/未验证。**G1 决策**：git 3 条契约删除，`pendingHandoffRoutes` 清零，UI Git 下线。**D2 决策**：files 插件承接 13 条、spec 2 条保留并增加原生 spec 工具。逐条见 §12.E/F/G。
> 上段「123 条 / 160 条」是当时的进度记录；测试/自检计数以 [agent_pluginization.md §10.5](agent_pluginization.md#105-测试与自检计数2026-10-25-实测) 为准（审计起点 tree.agent 330 / 124；D2 时 356 / 186；files 9 / 44）。

| ID | 操作 | 期望 |
| --- | --- | --- |
| G-1 | 36 条端点逐条对照（34 存量 + 2 新增） | 每条都能由 `tree.agent` 提供，且行为与迁移前一致（不变量 27） |
| G-2 | 核心路由表 | 不含 agents / sessions / questions / teammates / models / ssh 相关路由 |
| G-3 | 领域帧 | 核心不再构造 `msg_chunk` / `tool_start` / `agent_status` 等，只转发 `station_delivery` |
| G-4 | 过渡映射删除 | G+1 提交后，旧帧 → topic 映射代码为 0 |
| G-5 | 数据接管 | 首次启动接管 `agents.yaml` 与会话历史，备份存在，回滚可用 |
| G-6 | 性能基线 | 流式增量 50ms/32 token 合并生效；首字延迟与迁移前差值 ≤ 50ms（压测记录） |
| G-7 | agent 插件崩溃 | 领域端点 503 + 可读原因；UI 显示"服务不可用"，不静默空白 |

## 9. UI 插件（U1–U6）

| ID | 操作 | 期望 |
| --- | --- | --- |
| U-1 | 连接流程 | 连 WS → `ui.hello` → 读 `/api/meta` → 按 map 订阅；不硬编码站名 |
| U-2 | 功能调用 | 全部经 REST；唯一例外是 PTY |
| U-3 | 推送收口 | 所有领域事件经 `frame_router` 的 topic 映射进入既有渲染入口，渲染逻辑不变 |
| U-4 | 快照对齐 | 先订阅缓冲 → 拉快照（`seq` 水位）→ 丢弃 ≤ 水位 → 应用增量；无重复、无缺口 |
| U-5 | 断线重连 | `closed` 后自动重订阅；`reset` 后强制重拉快照 |
| U-6 | 多窗口 | 同一插件多连接各自订阅；关窗不销毁共用站点（**核心侧已由 `test/ui_windows_test.dart` 覆盖**；真机多窗口手工项见 §10） |

> **2026-10-25 状态**：U-1 已通过端到端实测（打包 `tree_ui.exe` + `UiHost` 拉起，
> `/api/meta.ui` 返回本插件）；U-5 的重连后自动重订阅与 `closed` 顶部横幅由
> `test/station_client_test.dart` 覆盖（无真实核心）；U-6 的“多窗口 = 多进程 / 关窗不打断
> 另一窗口 / 最后一个窗口才发 `closed`”已由 `test/ui_windows_test.dart` 覆盖。
> **尚未验收**：U-2（依赖真实 REST 委派场景）、U-3（真实领域帧生产者联调）、U-4（快照 `seq` 水位对齐尚未实现）。

## 10. 端到端场景（必须手工跑通）

| ID | 场景 | 通过标准 |
| --- | --- | --- |
| E2E-01 | 卸光所有 UI → 引导页 → 装回 | 全程无黑屏、无不可恢复状态 |
| E2E-02 | 只剩悬浮球 | 系统可用；悬浮球单独存活；引导页按能力判据决定是否打开 |
| E2E-03 | LLM 流式生成 | `seq` 连续递增；无丢帧；无逐 token 行式 JSON（日志抽样） |
| E2E-04 | 生成中重连 UI | 快照 + 增量对齐，界面无重复段落、无缺字 |
| E2E-05 | 慢消费者压测 | 触发 `lagged` → UI 重拉快照 → 内容完整；不得静默丢帧 |
| E2E-06 | agent 插件热重启 | 订阅者收到 `closed`；重连后 `reset`；快照恢复；会话不丢 |
| E2E-07 | ~~Git 面板~~ **已删除** | 用户决定删 git 3 条路由；UI Git 面板/状态着色下线，不再作为 E2E 项 |
| E2E-08 | 插件互通 | 甲向乙的自建执行站下令成功；深度 > 1 被拒；越权被拒 |
| E2E-09 | UI 越权尝试 | WS 触发收集/执行站、发布他人站、订阅中转站，全部可读拒绝 |
| E2E-10 | 卸载运行时插件 | 进程退出后文件可删；不残留句柄；重启后不复活 |
| E2E-11 | 依赖链（A→B→C） | 自动安装补齐整链；卸载 C 后 A/B 被停用且原因可读；再次装回 C 后可重新启用 |
| E2E-12 | 品牌切换 | UI₂ 连上后图标切到 UI₂；UI₂ 卸载后回退 UI₁；全部卸载回默认；exe 哈希始终不变 |
| E2E-13 | 多窗口 / 多 UI 插件 | 托盘「新建窗口」→ 出现第二个窗口（标题带 `w2`）；两窗口各自选不同 agent 互不干扰；关掉一个窗口，另一个的站点订阅（终端/事件）不断；同时启用两个 UI 插件时各自开窗、只有**一个**托盘图标；托盘「退出 Tree」把所有窗口一起关掉 |

## 11. 不变量覆盖矩阵

| 不变量 | 验收项 |
| --- | --- |
| 1–3 核心只增/真卸载/白名单 | A-1、C-11 |
| 4 委派不得 404 | C-2、C-3、C-4、C-5 |
| 5 / 17 / 18 / 20 UI 站权限 | B-4、B-10、E-9 |
| 6 UI 身份以声明为准 | B-5 |
| 7 UI 单类型 | D-1 |
| 8 / 32 广播增量 + 快照对齐 | U-4、E2E-04 |
| 9 引导壳判据 | E-1、E-5、E-6、E-11、E-12 |
| 10 票据单次使用 | E-2、E-3、E-7 |
| 11 UI 不做 stdio 握手 | D-5 |
| 12 删除只在 E 片 | E-9、C-11 |
| 13 发现面只聚合 | B-7 |
| 14 / 30 推送单向 | B-9、E2E-09 |
| 15 / 16 下线可读、可订自建站 | B-6、B-1 |
| 19 UI 扩展只走委派 | U-2、E2E-09 |
| 21 / 22 / 23 委派契约 | C-7、C-8、C-9、C-10 |
| 24 / 26 核心无领域概念 | G-2、G-3、§1 领域词检查 |
| 25 存储隔离 | F-6 |
| 27 迁移零丢失 | G-1、C-11 |
| 28 / 29 UI 功能走 REST + 上行白名单 | U-2、E2E-09 |
| 31 站传输无关 | B-1、B-9 |
| 33 背压与合并 | E2E-03、E2E-05 |
| 34 依赖是启用闸门 | D-8、D-12 |
| 35 依赖只装不升 | D-9、D-10、D-11 |
| 36 品牌申报可撤回 | B-11、E-13、E-14、E-15 |

## 12. 遗留项台账（2026-10-25 落档）

> 用途：一次把「还没做完 / 还没验完 / 还不能做」的项全部登记，避免靠对话记忆。
> 每项都写清**为什么停在这里**与**解除条件**；解除后在本表就地改为「已闭环」并注明提交号。
> 已闭环不再重复讨论：`requires.api` 闸门（`24b25d2`）、U1 附着化、U2 打包脚本、U3 `ui.hello`、
> U4 站点客户端（订阅/重连/`closed` 横幅）、E-9 旧协议残留清理、L-28 委派白名单去静态化（`6a30e81`）、
> F 片写入侧补齐：插件 stderr 与 `log` 通知落进 `plugin:<id>` 日志（`33f8115`）、
> L-19 G-1 对照表（`docs/pluginization/agent_api_contract.md`）。

### A. 代码项

| ID | 项 | 状态 | 阻塞 / 原因 | 解除条件与下一步 |
| --- | --- | --- | --- | --- |
| L-01 | G-1 端点等价对照（按实测 **36 条 = 34 存量 + 2 新增**；旧口径 23/25 已作废） | **已完成（2026-10-25）**：36 条 G-1 + 2 条 spec 附录全部申报（tree-plugins `0c6ee1d`）；**12 条**只读双跑逐字节一致；**H1 24 条真实 HTTP 对照：21 条一致 + 3 条差异全部清零** | 3 条差异的处理：① spec `version` 3→4：插件模板与核心 HEAD **逐字相同**（8/8/6/4），差异来自当时工作空间未刷新的旧副本，`seedInto` 会自动升级 ⇒ 无代码改动；② compact `relay_skip_reason`：插件 `toJson()` 与核心同形（仅非空时出现），补回归用例；③ reset 路径前缀：`SpecService.reset` 统一归一成 `.self/spec/<名>`，补回归用例。剩余唯一不等价项是 L-31 的占位符命名（HTTP 形状等价） | — |
| L-02 | G-2 核心路由表去除领域路由 | **已完成（2026-10-25 独立复核）** | 实测 `CoreServer.router == ApiPaths.coreOwned` 36 条；`pendingHandoffRoutes` 已清零（G1 删 git 后）；`stubApiPaths` 为空 | — |
| L-03 | G-3 领域帧改 `station_delivery` | **代码已接（2026-10-25），待真机签收** | 核心领域目录与领域帧生产代码已删；`tree.agent` 启动注册 `plugin.tree.agent.broadcast.events`，每帧以 `topic=tree.agent.<session>.<kind>` 经 `station/trigger` 发布；UI 订阅 + `FrameRouter` 还原旧帧名 | 缺口：真机双轨比对（帧序 / 丢帧 / closed / reset）与 50ms/32token 合并未做 | 按 E2E 跑一轮事件面，记录帧数与水位 |
| L-04 | G-4 过渡映射删除 | 未开始（过渡代码**存在**，见 E 节更正） | 依赖 G-3 完成一个版本周期 | G+1 提交时删除映射代码 |
| L-05 | G-5 数据接管（`agents.yaml` + 会话历史原地接管、备份、回滚） | 未设计 | 存储布局已定为「插件自带 store + 原地接管」，但插件内无接管/备份/回滚代码与用例 | 按原地接管写备份/回滚用例；前提是 L-22 settings 拆分完成 |
| L-06 | G-6 性能基线（50ms/32 token 合并、首字延迟差 ≤ 50ms） | 未测 | 依赖 G-3 | 压测脚本 + 迁移前后对比记录 |
| L-07 | G-7 agent 插件崩溃 → 领域端点 503 + UI 可读提示 | **已完成（2026-10-25）** | 核心委派层对「归属插件停用 / 启动失败 / 崩溃」回 503（C-2）；UI 侧 `ApiService._handleResponse` 识别 503 ⇒ `ServiceAvailability` 记原因，主界面顶部显示「服务不可用：…」提示条（可「知道了」关闭，领域端点下一次成功自动撤掉；平台面端点不参与清除）。用例：`test/service_availability_test.dart` 2 条 | 真机项：用可崩溃测试插件跑一次（崩溃 → 503 提示 → 重启插件后自动消失） | 与 L-03 同批真机验 |
| L-08 | U-3 推送收口 `frame_router`（topic → 既有渲染入口） | **已完成（2026-10-25）** | 新增 `lib/io/frame_router.dart`（topic kind → `type`，补 `session_id`）+ `LegacyFrameBus`（多订阅者）；消息面板与团队页已注册；`test/frame_router_test.dart` 5 条通过 | 真机联调（`station/trigger` 实际投递） | 与 L-03 同批签收 |
| L-09 | U-4 快照 `seq` 水位对齐（重连去重、无重复段落） | **已完成（2026-10-25）** | ① 核心**每次订阅成功都发 `reset`**（seq 是通道级计数，新通道从 1 开始；以前只在"同键重订"时发 ⇒ 断线重连会拿旧水位丢掉首批帧，E2E-04 丢帧根因）；② `FrameRouter` 把领域事件站的 `reset`/`lagged` 合成 `station_resync`；③ 消息面板收到即**整表重拉会话详情 REST**（tree.agent 承接）作为快照，补齐断线期间缺的帧 | 真机项：生成中拔网重连（E2E-04） | `ui_station_ws_test`（首次订阅即 reset）+ `frame_router_test`（resync 只对领域站） |
| L-10 | U-2 「从面板安装本地 zip」 | 未实现 | 核心只有发布仓库安装（`/api/plugin/release/{id}/install`），无本地 zip 端点；UI 面板也只调发布仓库 | 要么补安装端点，要么明确该场景不在本期范围 |
| L-11 | U-6 多窗口（同插件多连接各自订阅、关窗不销毁共用站） | **已完成（2026-10-25）** | 多窗口 = 多进程：`POST /api/plugin/windows` 由核心拉起 `w1`/`w2`…（`TREE_UI_WINDOW_ID` 注入、`ui.hello.window_id` 回带）；关一个窗口不打断另一个，最后一个窗口才发 `closed`；多个 UI 插件互不挤占；托盘按回环端口锁选唯一归属 | 真机手工项：核心 + 两个窗口 + 两个 UI 插件跑一次 | `test/ui_windows_test.dart` 4 条 |
| L-12 | C-11 删除领域端点核心实现（原文 18 路径/21 方法；git 3 方法已按 G1 删除） | **核心删除完成；mcp/spec/files 承接齐全；C-11 原顺序未满足** | A5 后核心 router 仅 39 条（36 + UI 多窗口 3）；mcp 3 由 mcp 插件承接；spec 2 由 tree.agent 承接（并新增原生 spec 工具）；files 13 由 files 插件承接，**SSH 缺口已于 2026-10-25 清零**（列表 size/mtime、分块读写、pdf 定读、syncToLocal、download_folder、原子 rename）；git 3 删除；C-1..C-10 未全绿即删除 | 补 C-1..C-10 验收；补回滚预案 |
| L-13 | loader 托盘 | 延后 | 源码明确写「本期不做 Windows 托盘图标」，以控制台菜单替代（`tool/tree_launcher/bin/tree_launcher.dart`；E-8 已按此口径） | 托盘实现单独排期，不影响其它项 |
| L-14 | 历史已知问题：从仓库更新「运行中的内置插件」可能挂起 | 待复核 | 未找到对应回归用例（`test/` 无运行中更新场景） | 补一条「运行中更新」回归，确认是否已修 |
| L-20 | 平台能力：按声明「逐 agent 单独起实例」 | 不支持（复核维持） | `PluginBus._hosts` 仍是 `Map<String, PluginHost>`（按 plugin id 唯一，`plugin_bus.dart:374`）；`granularity` 只做解析/序列化/重启比较，无按声明建实例分支（勘测见 [agent_pluginization.md §10.2](agent_pluginization.md#102-勘测插件平台是否支持按声明逐-agent-起实例)）。**新参考**：UI 侧已用 `_uiWindows`（plugin → window → host）实现“同 id 多实例”，stdio 侧尚未套用同一形状 | 本期由 `tree.agent` 内部调度；未来要支持需把 UI 的窗口表形状推广到 stdio（实例键 + 按需启停 + 按 `agent_id` 路由） |
| L-21 | 插件仓禁止 import 核心包（CI 闸门） | **部分闭环（2026-10-25 更新）**：桌面仓合同用例 + 插件仓可独立运行的等价脚本 | tree-plugins CI 尚未实际挂载；脚本以单文件提供，CI 需加一步调用 | 已有 `plugin_repo_contract_test`（mutation 验证会变红）；新增 `tool/check_plugin_repo_contract.dart`：零三方依赖，扫全部插件 `.dart` 的 import/export 与 `pubspec.yaml` 依赖键，`--plugin-root` 可指向插件仓根，`--selftest` 5/5 通过；桌面仓根与 `plugins/` 根两次实跑均绿（11 插件 / 187 Dart / 6 pubspec）。下一步：把该文件放进 tree-plugins CI 可执行路径并加门禁步骤 |
| L-22 | `core_settings.dart` 拆分（平台级 / 领域级） | **已拍板乙方案（2026-11-01）、未实施** | 核心 `core_settings.dart` 仍同时持有 `CoreModelConfig` / `models` / `token_acquisition_rate` 与 `frame_rate` / heartbeat 等平台项 | 按 [§4.8.1](agent_pluginization.md) 分文件拆分（领域键落 `config/agent_settings.yaml`）；新增门禁「核心 `toMap()` 不得含任何领域键」（先红后绿）；拆分前不得开始 A1 数据接管 |
| L-23 | 插件 scope 去领域化（`team_id/agent_id/session_id/mode_key`） | 未开始（复核维持） | `station_scope.dart:47-65` 四字段仍在；`execute_mounts.dart` / `station_instance.dart` 仍以 team/agent/session/mode 做 fail-closed 授权（勘测见 [§10.3](agent_pluginization.md#103-勘测插件-scope-仍含领域字段应去掉)） | 三步走：通用 `context` 先扩后收；授权搬到「执行器插件 + workspace 租约」；最后删字段。协议破坏性变更，需单独立项 |
| L-24 | 新建 `local_executor` 插件（本地 `Process.start` + 文件操作 + PTY） | **已闭环（2026-10-25）** | 本地站 `plugin.local_executor.execute.local`（23/23 自检）；SSH 站 `plugin.ssh_executor.execute.ssh_workspace`（`8a5f6ee`）；本地 PTY 随插件分发（`lib/src/pty/`），终端 REST + 广播已接（见 L-26） | SSH 后台 hook 不支持 | — |
| L-25 | 执行器执行站契约（`exec.command` / `file.*` / `terminal.*`）与 workspace 租约 | **部分落地（2026-10-31 收到契约 §8 的片 1 / 2 / 3 / 4）**：本地/SSH 两个自建执行站命令表已对称成 `local.*` / `ssh.*` 各 10 条，`lease_id`、相对路径与可读错误已成型；terminal 改由 REST + 广播承载（不再进执行站命令表） | 错误码 `code` 字段链路与幂等还没落（契约 §4，片 5）；`llm.*` / `tool.*` / `agent.*` / `session.*` 无承接方（契约 §7 Q-7） | 把站点名、参数、错误码、幂等写进契约（执行站仍由插件内部定义）；**租约由执行器插件登记，核心只转发** |
| L-26 | ~~核心通用流中继原语~~ → **执行器插件提供终端 REST + 广播站** | **已闭环（2026-10-25）** | 本地：`/api/terminal/local/sessions...` + 站 `plugin.local_executor.broadcast.terminal`；SSH：`/api/terminal/ssh/sessions...` + 站 `plugin.ssh_executor.broadcast.terminal`；topic `terminal.<session>.output/.exit`；UI 传输面 `lib/ui/services/terminal_transport.dart` | SSH 侧复用 tree.agent 的租约（UI 无密码），无租约 ⇒ 409 | 详见 [known-issues #37](../known-issues.md) |
| L-19 | G-1 对照表本身（36 行，含样例） | **已闭环**（`bda9df9`，2026-10-25） | — | 见 [agent_api_contract.md](agent_api_contract.md)：36 条 G-1 + 2 条 spec 附录，含全局约定、逐条样例与 C-01~C-12 契约缺口 |
| L-28 | 委派白名单 `ApiPaths.delegated` 去静态化 | **已闭环**（`6a30e81`，2026-10-25） | — | 已落地命名空间规则 + 保留前缀 + 归属表冲突检测；双跑期同键申报接受并标 shadowed（2026-10-25 修正，见 A-5）。门禁改为「核心 router 键集 == `coreOwned`；`pendingHandoffRoutes` 为空」。证据：`ui-pluginization.md` §4.5、`http_router.dart`、`server_test.dart`、`delegated_rest_test.dart` |
| L-30 | 非法 JSON / 字段类型错误统一回 400（G-1 C-02/C-03） | 待按插件重新验收 | 核心 handler 已随 A5 删除，旧证据失效；tree.agent `delegate.dart` 多数路由仍由 `_bodyOf` 抛 FormatException、顶层兜底 500（未逐条复测） | 在插件侧统一 400，并同批更新前端断言与文档 |
| L-31 | `teammateLog` 路径占位符改 `{leaderId}`（G-1 C-04） | **未完成（A5 后暴露）** | `api_paths.dart:34-35` 仍是双 `{memberId}`；tree.agent 申报用 `{leaderId}/{memberId}`；36 条覆盖中 35 条键完全一致、此 1 条仅占位符名不同（HTTP 形状等价） | 核心 + 前端 + 插件 + 契约常量同批改，附契约测试 |
| L-32 | 建成员 REST 入口（G-1 C-09） | 未完成（插件侧仍未补） | 核心 `_createAgent` 已随 A5 删除；tree.agent `createAgent` 仍只收 name / system_prompt / model_id / team_member_count / max_level / max_members_per_level | 产品决策后补入口 |
| L-33 | G-1 C-11 四个细节修正（sessions.message_count / conversations 404 / token-rate 空 body / DELETE 404） | 待按插件重新验收 | 核心 handler 已删；tree.agent 侧 `message_count` 已按真实计数、`GET conversations` 未知 agent ⇒ 404；但未知 session 200 空列表 / `DELETE conversations` 200 / 空 body token-rate 回落 max 仍未逐条复测 | 按契约逐条复测并决定修或保留 |
| L-34 | `sub_…` id 在 agent 端点的语义（G-1 C-12） | 待按插件重新验收 | 核心 handler 已删；tree.agent agent 详情/更新走 `readAgentRecord` / store，未见显式 `sub_` 拦截，语义未复测 | 明确"只接受真 agent id"并加 404，或正式定义该语义 |

### B. 手工回归项

| ID | 项 | 状态 | 说明 |
| --- | --- | --- | --- |
| L-15 | E2E-01~12 | 未执行（A5 后阻塞） | agent 事件面已接（A4）、terminal 已接（L-26）；仍剩 files SSH 缺口；E2E-02/03/04/05/08/10 仍无法按原口径跑（E2E-07 Git 已删除） | 先完成 files SSH 缺口收口，或明确砍功能；terminal 项可随时纳入回归 |
| L-16 | §13 回归基线 12 项 | 未逐项确认 | 每项都要在收束前手工跑一遍 |

### C. 文档项

| ID | 项 | 状态 | 说明 |
| --- | --- | --- | --- |
| L-17 | `agent_pluginization.md` §1.2/§5/§6 路由数改 36 条 | **已改（再校）** | §1.2 按 34+2；ui-pluginization §4.2/§4.5 同步为 **93 条契约**（39 + 54；git 3 已删、UI 多窗口 3 已加） |
| L-18 | 插件开发文档「UI 视图受限控件集」与实际实现对齐 | 待复核（部分改） | `docs/plugin-development.md:922` 已声明旧面板协议退役，但 `docs/ssh-tunnel-protocol.md:363-369` 仍按 `ui/manifest` / `plugin_ui_action` 描述 UI 视图；代码侧已无旧协议引用。下一步：补齐退役说明或删除该段，再全仓复核 |
| L-27 | 是否裁剪功能面（token-rate / tools-running / session specs 等） | 未决（复核维持） | 未找到裁剪决策或使用数据；G 只做等量迁移。下一步：G 完成后按真实使用数据单独评审，不与迁移混做 |

### D. 已拍板（避免重复问）

| 项 | 结论 |
| --- | --- |
| 插件源码位置 | `E:\programs\Tree\desktop\plugins`；该目录远端仓库名即 `tree-plugins` |
| 包命名 | 新包 `tree_agent_loop`（`plugins/tree.agent/`）；现有 `packages/tree_agent`（目标机执行体）**不改名、不复用** |
| 子 agent 执行体 | 由 `tree.agent` **内部调度**；核心不认知子 agent 执行体 |
| MCP | 整体迁 `mcp` 插件，核心零 MCP 代码 |
| 命令执行 | 走工具插件执行站；`tree.agent` 不 `Process.start`、不持 PTY |
| 密钥 | 供应商 Key 随插件、明文 + 权限收紧；加密本期不做；**无 loader 注入** |
| 测试归属 | 领域测试随代码迁插件仓 `tree_agent_loop`；核心只留平台/协议/服务端测试 |
| 逐 agent 实例 | 平台**当前不支持**声明式多实例（勘测见 [agent_pluginization.md §10.2](agent_pluginization.md#102-勘测插件平台是否支持按声明逐-agent-起实例)）→ L-20 |
| 插件依赖边界 | **插件不得 import 任何核心包**；复用只能走核心**平台内置站**（仅通用能力）、**其它插件的自建执行站**，或 UI 的 **REST 委派端点**；通用小件由插件自备 → L-21 |
| 基础件供给 | **已定**：领域层与通用小件复制随迁，不抽共享包；清单见 [§10.1](agent_pluginization.md#101-核心基础件依赖清单2026-10-25-修正) |
| settings 拆分 | **已定**：平台级留核心（frame_rate/heartbeat/telemetry）、领域级随迁（模型池/token 节奏）→ L-22 |
| scope 去领域化 | **已定方向**：移除 `team_id/agent_id/session_id/mode_key`，授权搬到「执行器插件 + workspace 租约」→ L-23 |
| 执行与文件 | **已定**：核心零 PTY / 零文件操作；本地执行、文件修改、终端归 `local_executor`，远端归 `ssh_executor`；执行站由**两个插件内部定义**（非核心内置）→ L-24~L-26 |
| 核心职责 | 只做插件生命周期 / 站点总线 / 传输 / 通用键值存储与日志 / 认证；租约簿记与领域授权一律归插件（契约 §8.3） |
| 路由基线 | **已定**：冻结实测 36 条（34 存量 + 2 新增）为基线；核心永久面 **39 条**（36 + UI 多窗口 3）；是否裁剪另立 L-27 |
| 路由申报 | **目标形态（L-28 已落地）**：核心只硬编码自己的 **39 条**（36 基线 + UI 多窗口 3）；其余 **54 条**由插件经 `system.collect.api.routes` 运行期申报，核心只维护归属表并转发（详见 [agent_pluginization.md](agent_pluginization.md) §10.4）；放行规则为命名空间规则 + 保留前缀 + 同键申报标 shadowed（coreOwned 拒收），无静态白名单 |

### E. L-01~L-34 + G-1~G-7 最新状态矩阵（2026-10-25 审计）

> 审计基线：A5 工作树（桌面仓 HEAD `3fd9d6f` + A5-LIB 未提交删除）、tree-plugins `5b564a3`。表中「核心已删」均指 A5 工作树实测，不是计划。
> `L-29` 为空号（台账无此项）。

| ID | 状态 | 关键证据（文件 / 命令） | 前置 | 可并行组 |
| --- | --- | --- | --- | --- |
| L-01 | 已完成（三差异清零） | 12 条只读双跑一致；H1 24 条：21 一致 + 3 差异已处理（spec 模板逐字同源 / compact `relay_skip_reason` 同形 / reset 路径归一）；36 条 + spec 2 已申报 | L-19、L-28、L-24 | — |
| L-02 | 已完成 | 实测 `router == ApiPaths.coreOwned` 36；`pendingHandoffRoutes` 为空；stub 为空 | — | P2 |
| L-03 | 代码已接，待签收 | 事件站 `plugin.tree.agent.broadcast.events` + `FrameRouter` 已落地；真机双轨未跑 | L-01 事件面 | P2 |
| L-04 | 未开始 | 过渡映射**确实存在**：`lib/io/frame_router.dart` 整层就是"topic → 旧帧名"的换收口（含 `LegacyFrameBus`，`test/frame_router_test.dart` 覆盖）；原"未发现过渡代码"已更正（2026-10-31 复核） | L-03 完成 + 一个版本周期 | P2（尾） |
| L-05 | 未设计 | 插件无数据接管 / 备份 / 回滚代码与用例 | L-22、L-01 数据层 | P5 |
| L-06 | 未测 | 无压测脚本与迁移前后对比记录 | L-03 | P2（G-3 后） |
| L-07 | 已完成（2026-10-25） | 核心 503（C-2）+ UI `ServiceAvailability` 顶部提示条；`test/service_availability_test.dart` | G-2 | 真机崩溃用例 |
| L-08 | 已完成（2026-10-25） | `frame_router.dart` + `LegacyFrameBus`；5 条用例通过 | — | 与 L-03 同批签收 |
| L-09 | 已完成（2026-10-25） | 每次订阅发 `reset` + `station_resync` → 会话详情 REST 整表重拉；`ui_station_ws_test` / `frame_router_test` 钉住 | — | 真机 E2E-04 |
| L-10 | 未实现 | 核心只有发布仓库安装端点；UI 面板也只走发布仓库 | 产品范围决定 | P1 |
| L-11 | 已完成（2026-10-25） | 多窗口 = 多进程，两条诉求都已落地：① **同一插件多窗口**：`POST /api/plugin/windows` 由核心拉起 `w1`/`w2`…（`TREE_UI_WINDOW_ID` 注入、`ui.hello.window_id` 回带），关一个窗口不再打断另一个；② **多个 UI 插件并存**：`_uiWindows` 按插件分组，互不挤占；UI 侧托盘用回环端口锁选唯一归属，副窗口关窗即退出。核心 `_offlineNotified` 保证 `closed` 每世代只发一次 | — | 已闭环（`test/ui_windows_test.dart` 4 条） |
| L-12 | 核心删除完成，承接到位 | mcp 3 已交接；spec 2 由 tree.agent 承接（+原生 spec 工具）；files 13 由 files 插件承接且 SSH 缺口已清零（2026-10-25）；git 3 已删；C-1..C-10 未全绿 | 补 C-1..C-10 验收 + 回滚预案 | P4 |
| L-13 | 延后 | `tree_launcher.dart` 明示本期不做 Windows 托盘 | 单独排期 | P1 |
| L-14 | 待复核 | 未找到「运行中更新」回归用例 | 无 | P1 |
| L-15 | 未执行（已可跑，需真机） | agent 事件面已接（A4）、terminal 已接（L-26）、files SSH 缺口已清零 ⇒ E2E-01~06/08~13 均可按原口径跑；Git 项已删除 | L-03、L-09 | P6（收口） |
| L-16 | 未逐项确认 | §13 回归基线共 **12** 项（原文误写 10 项，已改） | 无 | P6（收口） |
| L-17 | 已闭环 | `agent_pluginization.md` §1.2/§5/§6 已按 36 条改 | — | — |
| L-18 | 待复核（部分改） | `docs/plugin-development.md:922` 已声明旧协议退役；`docs/ssh-tunnel-protocol.md:363-369` 仍按 `ui/manifest` / `plugin_ui_action` 描述 | 文档修订 | P1 |
| L-19 | 已闭环 | `agent_api_contract.md`（`bda9df9`） | — | — |
| L-20 | 不支持 | `PluginBus._hosts` 按 plugin id 唯一；`granularity` 仅元数据 | 平台立项 | 不在本期 |
| L-21 | 部分闭环 | 桌面仓合同用例；新增 `tool/check_plugin_repo_contract.dart`（`--selftest` 5/5、11 插件 / 187 Dart / 6 pubspec 实跑绿）；插件仓 CI 未挂 | 插件仓 CI 接线 | P1 |
| L-22 | 已定方案、未实施 | 乙方案·分文件（[§4.8.1](agent_pluginization.md)）：领域键归插件；核心仍是混装状态 | 门禁「核心 `toMap()` 不得含领域键」，先红后绿 | P1（L-05 前置） |
| L-23 | 未开始 | `station_scope.dart` 四字段仍在，跨域授权仍依赖它们 | 单独立项 | P1（独立） |
| L-24 | 已闭环 | 本地站 23/23 自检（含终端会话）；SSH 站 `8a5f6ee`；PTY 随 `local_executor` 分发，终端 REST + 广播已接 | — | — |
| L-25 | 部分落地 | 本地/SSH 站点命令、`lease_id`、相对路径、可读错误已成型；后台 hook/错误码/幂等未统一 | L-24 | P3 |
| L-26 | 已闭环 | 执行器 REST + 广播站；本地/SSH 两套同形端点，UI 传输面 `terminal_transport.dart` | L-24/L-25 | — |
| L-27 | 未决 | 无裁剪决策 / 使用数据 | 产品决策 | P1 |
| L-28 | 已闭环 | `6a30e81`，命名空间规则 + shadowed 申报 | — | — |
| L-30 | 待按插件复测 | 核心 handler 已删；tree.agent 多数路由仍由 `_bodyOf` 抛 FormatException / 顶层 500 | 插件侧复测 | P5 |
| L-31 | 未完成 | 契约常量双 `{memberId}`；tree.agent 用 `{leaderId}`；35/36 键完全一致，此条仅占位符差异 | 核心+前端+插件同批 | P5 |
| L-32 | 未完成（插件侧仍未补） | tree.agent `createAgent` 无建成员参数；核心实现已删 | 产品决策 | P5 |
| L-33 | 待按插件复测 | 插件 `message_count` 已正确、未知 agent 404；未知 session / DELETE conversations / 空 token-rate 未复测 | 插件契约复测 | P5 |
| L-34 | 待按插件复测 | 核心 handler 已删；tree.agent 未见显式 `sub_` 拦截 | 产品 / 契约 | P5 |
| G-1 | 已完成（三差异清零） | 同 L-01：12 条双跑 + H1 24 条（21 一致 + 3 差异已处理）；36 条全部申报 | — | — |
| G-2 | 已完成 | 同 L-02：router 36 == coreOwned，pending 0 | — | P2 |
| G-3 | 已完成（代码侧，待真机双轨） | 核心不再产生领域帧；tree.agent 事件广播站 + UI `StationClient`/`FrameRouter` 已接（L-03/L-08） | G-1 | P2 |
| G-4 | 未开始 | 无过渡映射代码可删 | G-3 + 一个版本周期 | P2（尾） |
| G-5 | 未设计 | 无接管 / 备份 / 回滚实现 | L-22、L-05 | P5 |
| G-6 | 未测 | 无 50ms/32 token 合并压测与首字延迟对比 | G-3 | P2（G-3 后） |
| G-7 | 已完成（2026-10-25） | 同 L-07：核心 503 + UI 全局提示条；缺真机崩溃复现 | — | 真机 |

### F. 依赖顺序与可并行拆分（2026-10-25）

**最短收束路径（关键路径）**：

1. **L-01 / G-1 已完成**：36 条均已对照（12 条双跑 + H1 24 条真实 HTTP），3 条差异已清零（spec 模板逐字同源 / compact `relay_skip_reason` 同形 / reset 路径归一）。
2. **L-02（G-2）已完成；L-03（G-3）已接**：A5 先删核心 52 条实现（违反不变量 27 顺序），H1 已补 24 条 HTTP 对照（21/3）；帧迁移核心侧已清空，`tree.agent` 事件广播站 + UI `frame_router` / `LegacyFrameBus` 已接（L-03/L-08）。
3. **G-7 / G-4 / G-6**：分别依赖 G-2、G-3+版本周期、G-3；都在 G-2/G-3 之后收口。
4. **L-30~L-34**：统一在 G-1 行为基线冻结后单独评审，避免与迁移混做。
5. **L-15 / L-16**：所有批次完成后按 12 项回归基线手工收口。

**可并行组**：

- **P1（现在就能开，互不阻塞）**：L-09（UI 客户端 `seq` 水位）、L-10（本地 zip 或明确不做）、L-13（loader 托盘）、L-14（运行中更新回归）、L-18（文档对齐）、L-21（把脚本接进 tree-plugins CI）、L-22（settings 拆分）、L-23（scope 去领域化单独立项）、L-27（产品裁剪决策）。**L-11 多窗口已闭环**（2026-10-25，剩真机手工项）。
- **P2（G 主线，串行为主）**：L-01 接受/修复 3 个 H1 差异 → L-03 插件广播站 →（G-4 ∥ G-6 ∥ G-7）；L-02 已完成。L-08 在 G-3 后接 UI 收口；L-09 的最终联调也在 G-3 后。
- **P3（执行器链，与 P2 并行）**：L-24 本地/SSH 执行站与终端已闭环（PTY 随插件分发）→ L-25 收口契约（后台 hook / 错误码 / 幂等）→ L-26 已按"执行器 REST + 广播站"闭环（不做核心流中继）。
- **P4（领域插件批，与 P2/P3 并行）**：L-12 = spec / files / mcp 承接 + C-1..C-10 全绿；mcp 3 已交接（`e817d30`），spec 2 由 tree.agent 承接且新增原生 spec 工具，files 13 由 files 插件承接（SSH 部分缺口）；**git 已删除，不交付**。
- **P5（G 后清理）**：L-05 / G-5 依赖 L-22；L-30~L-34 依赖 G-1 完成；L-31 必须核心 + 前端 + 插件同批。
- **P6（收口）**：L-15 / L-16 最后跑；任一项失败按 P1 处理，不得降级通过。

**不建议并行**：G-2 已在 G-1 未全签收时完成（A5 先删后验），后续补验只能走真实 tree.agent 实例；L-22 未拆分前不能开始 G-5 数据接管；L-23 是协议破坏性变更，不塞进 G 主线。

### G. A5 核心清空独立验收记录（2026-10-25）

> 验收对象：A5-LIB 工作树（未提交）。验收者独立复跑，不复用 a5-lib 的结论。
> 基线：桌面仓 HEAD `3fd9d6f` + A5-LIB/A5-TESTS 工作树；tree-plugins `5b564a3`。

| 验收项 | 命令 / 方法 | 实测 | 结论 |
| --- | --- | --- | --- |
| 七个领域目录不存在 | `Test-Path packages/tree_core/lib/src/{agent,files,llm,spec,team,terminal,tool}` | 七项全部 MISSING | **通过** |
| core lib analyze | `cd packages/tree_core && dart analyze lib` | `No issues found!` | **通过** |
| core CLI analyze | `cd packages/tree_core_cli && dart analyze` | `No issues found!` | **通过** |
| 协议包 analyze | `cd packages/tree_protocol && dart analyze` | `No issues found!` | **通过** |
| router == coreOwned | 临时脚本启动 `CoreServer.start()`，读 `server.router.routes` | `registered=36` / `coreOwned=36` / `equal=true` / `missing=[]` / `extra=[]` | **通过** |
| pendingHandoffRoutes 未注册 | 同一脚本求交集 | A5 时 `pending=52`、交集 `[]`；**G1 后 pending=0**（git 3 删除，集合已清零） | **通过** |
| 501 桩不再兜底 | `server.stubRouter.routes` | `[]`（`stubApiPaths` 为空） | **通过** |
| 领域 REST 404 | 临时脚本带 token 请求 | `/api/files/ws1` → 404；`/api/workspaces/ws1/git/log` → 404；`/api/agents/agt1/specs` → 404（无插件时）；`/api/agents` → 404；`/api/agents/agt1/todos` → 404；`POST /api/agents/agt1/messages` → 404 | **通过**（核心无实现且无插件时 404） |
| tree.agent 覆盖 36 条 G-1 | 解析 `tree_agent_loop.dart:kDeclaredRoutes` 与 `delegate.dart` 模式常量，对照 A5 前 `pendingHandoffRoutes` 的 34 条 agent 路由 + 2 条新增（该集合现已清零） | 申报 39 条 = 36 G-1 + 2 spec + 1 执行器激活（`POST /api/agents/{agentId}/activate`，非 G-1）；**35 条键完全一致**；`teammateLog` 1 条核心用双 `{memberId}`、插件用 `{leaderId}/{memberId}`（L-31，HTTP 形状等价） | **通过（带 1 条已知占位符差异）** |
| files 承接方 | `plugins/files/lib/src/routes.dart` | files 插件申报 13 条 `/api/files/*`；本机全量，SSH 部分缺口（见插件 README） | **已承接（带缺口）** |
| git 契约清理（G1） | `api_paths.dart` + protocol test | `delegated` 57→54、`pendingHandoffRoutes` 52→0、`kept` 70→67、`contractRoutes` 93→90；`protocol_completeness_test` 11/11 通过；UI `getGitLog/getGitBranches/getGitStatus` 抛显式 404 异常 | **已完成（用户决定）** |
| spec 承接方 | tree.agent 代码 | spec 2 条路由保留并由 tree.agent 承接；新增原生 spec 工具（list/read/select/create/update/reset，`agent_tools` 的 `spec.*`）；无独立 spec 插件 | **已承接（tree.agent）** |
| H1 24 条 HTTP 对照 | H1 任务实测（A5 前） | 21 条一致；3 条已知差异：spec 域内置 version 3→4、compact 缺 `relay_skip_reason`、reset 相对路径前缀不同 | **不宣称全等价；差异待接受** |
| 测试计数（D2 复核） | tree.agent/files/protocol/core | tree.agent 356 / 自检 186；files 9 / 自检 44；protocol 68；core 613 passed / 2 skipped | **与 §10.5 一致** |
| terminal 承接方 | 核心代码 + 插件 grep | 核心无终端路由/PTY；`local_executor` / `ssh_executor` 各申报 5 条 `/api/terminal/{local,ssh}/sessions...` 并注册各自广播站 | **已承接（L-26）** |
| 核心领域 import 残留 | grep `src/(agent|files|llm|spec|team|terminal|tool)/` | `packages/tree_core/lib` 0 命中；`tree_core_cli` 0 命中 | **通过**（仅注释/README 仍提旧路径） |
| 核心测试 | `cd packages/tree_core && dart test -j 1` | **613 passed / 2 skipped，0 failed**（串行复跑；A5-TESTS 最终态） | **通过** |

**未通过 / 未验收项（必须带进报告）**：

1. ~~`pendingHandoffRoutes` 仍是 52 条~~ **G1 已清零（0 条）**；files 已由插件承接、git 已删除，未另建 `unclaimedRoutes`。
2. **不变量 27 的顺序被打破**：A5 删除核心时 36 条 G-1 只有 12 条双跑；H1 事后补 24 条真实 HTTP 对照（21 一致 / 3 差异，差异已于 2026-10-25 清零）；C-11 的 C-1..C-10 仍未全绿。
3. **files 13 已由 `files` 插件承接且 SSH 缺口清零（2026-10-25）**：列表带 size/mtime、读写走分块通道（无 8 MiB 上限）、PDF 头尾定读、`syncToLocal`/`download_folder` 已实现、重命名改原子 `ssh.file.rename`。**git 3 已删除**，UI Git 面板/状态着色下线。
4. ~~**terminal 不可用**~~ **已闭环（L-26）**：会话管理走执行器 REST，输出走执行器广播站；核心无 PTY / 无流中继。SSH 终端依赖 `tree.agent` 已登记的租约。
5. ~~spec 的验收口径冲突~~ **已定（D2）**：spec 2 条路由保留，由 tree.agent 承接；另新增原生 spec 工具（list/read/select/create/update/reset，`spec.*`）。
6. ~~`docs_contract_test` 仍红~~ **已恢复 7/7 通过**（链路修复不在本任务，复跑确认）。
7. ~~UI 测试 2 条 git 状态着色用例~~ **已清理（task-16）**：删除 git 着色/模型测试与 Git 面板源码断言，更新为「Git 已下线、右栏不再提供该窗口」。
8. ~~**H1 3 个已知差异待接受**~~ **已清零（2026-10-25）**：spec 模板与核心 HEAD 逐字相同（差异来自旧工作空间副本，`seedInto` 自动升级）；compact `relay_skip_reason` 同形且补回归用例；reset 路径由 `_specRelativeOf` 归一成 `.self/spec/<名>` 且补回归用例。详见 [agent_api_contract.md](agent_api_contract.md) §5。

## 13. 回归基线（收束过程中不得退化）

逐项手工确认，任一项失败即 P1：

1. 会话创建 / 切换 / 重置 / 压缩
2. 流式生成、工具调用与结果展示
3. 文件浏览、读写、保存失败提示
4. **终端（PTY）输入输出与 resize**（已接：执行器 REST 管会话 + 广播站推输出，见 L-26）
5. ~~Git 面板三项~~（已按用户决定删除，不再作为回归项）
6. Spec 列表与内容
7. MCP 服务配置
8. 提问回路（发问 / 答复 / 取消）
9. 团队与子 agent
10. 插件安装 / 卸载 / 启停 / 热重启
11. 主题、字号、字重、字体设置
12. 右栏窗口化与多标签

## 13. 记录与收尾

| 项 | 要求 |
| --- | --- |
| 每批次记录 | 逐条勾选 + 失败项 ID + 证据（日志/截图/命令输出） |
| P0/P1 清零 | 未清零不得开下一批次 |
| 回退演练 | A–F 纯增量直接 revert；E、G 各自单独 commit，演练一次整体回退 |
| 文档回写 | 验收中发现与设计不符的，先改 `ui-pluginization.md`，再改代码 |
