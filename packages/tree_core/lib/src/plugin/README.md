# plugin（插件宿主与站点体系）

进程外插件（stdio JSON-RPC）的宿主，以及插件与核心之间**唯一**的交互面：站点。
四类站点、若干点位，外加执行站挂载、插件工具定义与 UI 槽位桥。

## 宿主与配置

| 文件 | 作用 |
| --- | --- |
| [plugin_host.dart](plugin_host.dart) | 进程外插件宿主：行分隔 JSON-RPC 2.0，入站报文分三类（响应 / 请求 / 通知） |
| [plugin_bus.dart](plugin_bus.dart) | 总线：配置、实例生命周期、事件分发、工具聚合、站点体系、心跳判活 |
| [plugin_config_store.dart](plugin_config_store.dart) | `plugins.yaml` 读写层：直接在原始 Map 上"读 → 改 → 原子写"（保留未知键） |
| [builtin_plugins.dart](builtin_plugins.dart) | 内置插件静态清单 + 运行时 / 脚本解析 |
| [plugin_guide.dart](plugin_guide.dart) | 插件开发指南在工作空间内的落点（`.self/docs/plugin-development.md`）与播种 |

## 站点

| 文件 | 作用 |
| --- | --- |
| [station_ids.dart](station_ids.dart) | 内置点位 id **常量**（只放常量，谁都要引、不能有依赖） |
| [station_points.dart](station_points.dart) | **点位表**：类型 / 中文名 / 说明 / 命令 / 订阅别名——点位的唯一定义处 |
| [station_schema.dart](station_schema.dart) | 站点类型枚举与收集站 schema |
| [station_scope.dart](station_scope.dart) | 隔离四元组与调用点上下文 |
| [station_instance.dart](station_instance.dart) | 四类站实例与各自的触发方法 |
| [station_runtime.dart](station_runtime.dart) | 一次触发的输入输出（订阅者 / 请求 / 回包 / 活性 / 分类计数） |
| [station_store.dart](station_store.dart) | 站点实例落盘 `config/stations.yaml`（跨重启保留） |
| [stations.dart](stations.dart) | 站点中枢：内置点位、插件自建站、订阅、下线注销、快照 |

## 接入点

| 文件 | 作用 |
| --- | --- |
| [execute_mounts.dart](execute_mounts.dart) | **系统内置挂载位置**：把执行站各命令族接到核心既有实现，并做四元组隔离 |
| [plugin_tool_definition.dart](plugin_tool_definition.dart) | 收集站首个接入点：插件定义 tool → 动态工具表 |
| [plugin_ui_bridge.dart](plugin_ui_bridge.dart) | 插件通知 → 前端 UI 帧（槽位）+ 当前态缓存（供后连的前端重放） |
| [agent_events.dart](agent_events.dart) | agent 事件发布器（工具调用开始 / 结束等） |

## 不变量（assertions）

1. **站点只有四种类型**（广播 / 执行 / 中转 / 收集），插件**不得发明新类型**；每类下若干**点位**，**每个点位是一个独立的全局实例**（各自唯一订阅者、各自计数、各自挂载位置、面板各自一行）。
2. **站点 id 不含 team / mode**：team / agent / session / mode 是**每次交互携带的信封**（消息 scope）与订阅声明，只在投递时用于匹配订阅者。按 team 复制站点会让站点数随团队数膨胀（一堆没人用的空壳），全局化后跨 team 数据整合天然可行，而隔离仍在投递判定处 fail-closed。
3. **点位表是唯一定义处**：加一个点位只该改 [station_points.dart](station_points.dart)（外加 `StationHubIds` 一个常量，且**必须加进 `all`**——否则会被当成别人的自建站、被归属校验收掉），不该去动订阅 / 路由 / 预建 / 面板四段逻辑。点位是**数据**不是行为。
4. **隔离 fail-closed**：按四元组（team / agent / session / mode）解析目标，任何归属**证明不了**就拒绝并给可读原因。执行站每条命令的第一件事就是校验：`agent_id` 与站点 scope 不一致拒、team 不一致拒、目标 agent 的**工作空间模式**（local | ssh）不一致拒（否则 SSH 团队的命令会打到本地工作空间）。
5. **中转站 fail-open 红线**：无订阅者 / 订阅者心跳丢失 / 回包非法 / 处理异常，一律**放行原数据**并给出可读原因，绝不抛出、绝不出半成品。压缩中转点的这份原因还**经 `PluginBus.compactionSkipSink` 上报**（带 `hasSubscriber` 分级位：早退 vs 有订阅者却没接管），接线方接到 `CompactionService.noteRelaySkip` ⇒ 原因能进 REST 响应与会话通知——否则"我装了压缩插件为什么没生效"只能去翻 stderr。
   **回包可选键 `reason`（2026-10-05 新增，纯增量）**：插件回 `payload: null`（= 不接管）时可以顺手说明
   **为什么**（`StationReply.reason` → `StationRelayResult.reason`）——原因于是从"只活在插件自己的内存面板"
   升级成**核心日志 + `relay_skip_reason` + 会话提示**；不带该键的老插件行为**逐字不变**。
   同理，**命令类失败若带着产出**（`llm.call` 解析不出 JSON 时的模型正文）要用
   `StationCommandOutcome.failedWith(error, payload)` 回，别只回一句 `error`——那等于把插件已付费的
   那次调用彻底丢掉（现场是 734k prompt 的总结，见 [../llm/README.md](../llm/README.md) 不变量 14）。
   **而且这份 `payload` 必须"穿到底"**：`StationInstance.execute()` 的 `ok:false` 分支也要把
   `outcome.payload` 放进 `StationCommandResult`（**曾经就漏在这一跳**：核心明明把原文放进了回包，
   插件收到的 `payload` 却是 null、报"原文 0 字"当场弃权，那笔 448k prompt 的总结又整包白扔；
   见 [../../../../../docs/known-issues.md](../../../../../docs/known-issues.md) #31「真机复现」）。
   判据：**"写进了回包" ≠ "走到了插件"**——执行站 → 插件总线 → 插件进程每一跳都要有用例钉住
   （`test/plugin_execute_new_commands_test.dart` 钉这一跳，`test/compact_plugin_e2e_test.dart` 钉真进程那一跳）。
6. 中转站是 `scopeKeyUnique` **先到先得**：同键位第二人被拒（显式 `replace` 才替换并回报被替换者）——一个接入点只能有一个处理者。这也是点位各自成实例的原因：否则"接管 LLM"的插件会顺带垄断"系统提示词构造""上下文压缩"。
7. **收集站**：schema **必填**（订阅者必须按它产出，校验失败按可读错误回报该订阅者）；**不回填**原数据流（返回值即结果，后续处理由触发方负责）；某订阅者未响应（心跳丢失 / 窗口内无回 / 校验失败 / 回包报错）⇒ 返回**已收集部分 + 显式列出未响应者**，不静默、不阻塞、不整体失败。
8. **无静态总时间上限**（M9 §1.1）：看门狗每拍 `ping`，连续 N 拍没有心跳 ⇒ 只标记 `health: degraded` 并让前端可见，**不自动终止插件**（长任务跑多久都不因时间被杀）；心跳恢复自动清除；用户可显式 `restart`。唯一保留的短窗口是**建连握手**——没有它就诊断不出"插件根本没起来"。**站请求 / `tools/call` 同样没有静态超时**（`plugin_host.requestStation` 明写这条）；未响应只记"未响应者清单"。**软窗口之后只允许显式收手**（用户 `restart` / 关闭那一次运行）——全仓同一条口径见 [../llm/README.md](../llm/README.md) 不变量 2。
9. **插件与 agent 同权**：本仓库**没有工具审批层**，`tool.call` 走工具层唯一入口，与模型调用工具是同一条路径、同一份权限。这是设计事实，文档如实写出来，而不是假装有沙箱。
10. **写回配置必须保留未知键**：直接在原始 Map 上改 + 原子写，不经 `PluginConfig.fromJson` 中转（它会丢未知键，改一个开关会把文件改瘦成核心认识的形状）。id 白名单 `[A-Za-z0-9_.-]`（防止 id 被当成路径分段用）；校验失败一律返回**可读中文原因**，不抛异常。
11. **插件 UI 安全边界（fail-closed）**：`plugin_id` 一律取**实例 id**，不采信通知里的自述（否则 A 插件能注销 / 覆盖 B 的槽位）；`team_id` 以配置声明为准，冲突以声明为准并记日志；槽位条数 / `slot_key` / 视图大小都有上限，超限**整帧拒绝**。不做 webview / iframe、不执行插件 JS——视图只能是受限控件集的 JSON，未知控件由前端渲染成占位。
12. **UI 帧缓存只存"桥已放行"的帧**：插件槽位声明是一次性的，而广播是"当下有谁在听就发给谁"——前端刷新 / 重连、插件比前端先就绪、断线期间插件重启，都会让面板**永久消失**直到插件进程重启。缓存按帧类型存最后一个生效帧，新连接注册时重放（前端对同内容重放幂等）。越权 / 非法声明连缓存都进不去，重放**不是**绕过校验的旁路。
13. **agent 事件发布失败绝不冒泡**：发布发生在生成循环里（工具调用处），订阅方抛异常只回报 `onError`、事件丢弃——插件侧的任何问题都不该让生成失败。默认未接线 = **纯 no-op**。
14. 内置插件的"身份"由**核心**认定（前端只拿到 id / 名称 / 说明 / 开关状态）；解析不出运行时必须给可读错误（「未检测到 Python，请先安装或改用自定义命令」）——静默失败在界面上表现为"点了开关没反应"。
15. 执行站挂载位置的依赖**没接线时不做静默降级**：以「未接线」的可读原因失败。
16. 代理归属校验与订阅可见性**两处都按 team fail-closed**；插件要订阅站点就必须声明 `scope.team_id`，因此事件与命令的 `team_id` 一律取 agent 的**有效团队归属**（顶层 agent 自成一队，取它自己的 id），不能只读 `agent.teamId`（那会让顶层 agent 的事件永远带空 team，声明了 team 的插件反而收不到自己的事件，计数静默归零）。
17. **中转站 = 「处理拓展点位」（而不是只是「数据拦截-回填」），SSH 执行因此与工具改写同构**（2026-10-10 新增、**2026-10-15 定位重写**）：
    - **新定位**：中转站不只会拦下数据让插件改写，还会把**整块处理工作**交给插件。SSH 工作空间因此新增内置点位
      `system.relay.ssh.execute`（别名 `ssh.execute`，中转站唯一订阅者）：核心把 `ensure` / `request` / `state` /
      `reconnect` / `close` / `shell.*` 都投成一次 `station/request`，插件自己完成到目标机的通信与回包，
      共 22 个内置点位（广播 5 + 执行 9 + 中转 7 + 收集 1）。
    - 选路信号：`PluginBus.sshExecuteStationSubscribed()`（新，按「中转站点位有没有订阅者」）
      与 `PluginBus.sshExecutorLookup()`（旧，按 `hello.capabilities` + 进程在跑）**OR**：
      旧插件只报 capability 不订站点 ⇒ 行为与今天一致（走 `tunnel.*` 顶层方法）；
      新插件订上站点 ⇒ 核心优先走站点投递；两者都没 ⇒ 回退内置 `dartssh2`。
      热切换（插件重启/启用/停用）由既有基础设施接住：插件下线 ⇒ 订阅自动注销 ⇒ `sshExecuteStationSubscribed()` 变 false；
      重新上线 ⇒ 重新 subscribe，核心下一次 `_ioFor` 自动重新选路。
    - 旧体系**不一次性删除**，`PluginTunnelLink` + `tunnel.*` 方法在新体系上量后才会逐次降级为**兼容层**（行为不变、仅写清楚“兼容旧插件”的注释）；
    - `PluginBus.relaySshExecute()`（新）与中转站既有方法同一套 fail-open / scope 校验 / 无静态超时；回包非 `Map` ⇒ null（回退内置）。
    - 内置目录加 `kind: python|binary`：binary 型**不做运行时探测**，直接解析可执行文件同级的 `plugins/<name>[.exe]`（`build/plugins/` 是开发态落点）；
    - `defaultEnabled` 的播种**只处理“从来没落盘过这一条”**：用户显式关过就绝不再自动打开。
18. **断连的两种"不可用"必须在插件边界就分清**（2026-10-11 新增，协议 §10）：
    `PluginTunnelLink` 把插件的 `error_kind` 原样翻进 `TunnelUnavailableException`——
    `tunnel_not_ready`（还没好）与 `tunnel_down`（判死/已关闭/通道断在中途）**不许混**。
    核对判死的责任在 `tree_local_exec`（只看心跳快照 + 插件是否还可用），
    但**核心这一侧**多提供一件事：`TunnelSession.pluginAvailable` / `unavailableReason`
    实时查 `PluginBus.sshExecutorLookup()`，让"插件进程没了"能作为**本地事实**参与判死
    （而不是靠"某次请求失败"去猜）。
19. **插件"正在启动"与"没有插件"必须分开，且前者要**有界等待**（2026-10-11 用户真机）**：
    插件是异步拉起的，SSH 解析可能比它就绪只早**几十毫秒**（用户机器实测 53ms）。那时直接回退内置，
    这条 IO 会被 `WorkspaceToolRunner._ios` 缓存住、不会自己回切 ⇒ **整场都跑在内置后端上**。
    所以：`sshExecutorStarting()` 只对"条目启用、但实例没起来（且无错误记录）/ 未申报能力"回 true；
    `sshExecutorLookupWaitingForStart(timeout, interval)` 只在这一种情形下有界等待（生产 1s / 100ms），
    其它原因（条目停用 / 启动失败 / 通道断）**立即返回**，绝不空等。
20. **每个站点都必须有介绍（`readme`），且介绍的来源按「内置 / 自建」分开**（2026-10-14 用户定稿，断言 3）：
    插件 `station/register` 时 `readme` **必填**（非空且不全空白），缺了就 `ok:false` + 指名 `readme` 的可读原因，
    且**不会建出半个站点**（拒绝都发生在校验阶段、建实例之前；用例末尾逐条核过"一个都不该留下"）；
    内置点位的介绍来自**点位表**
    [station_points.dart](station_points.dart)（`readme` 空则回落 `description`），面板因此永远不留空白。
    `readme` 与 `shared` / `allowed_plugins` / `config` / 每个订阅者的禁用标记一起**落盘**
    `config/stations.yaml`（不变量 22）。**同名重复注册 = 幂等**：返回既有站点、不报错、
    **也不覆盖**第一次写的 `readme`——插件重启会再注册一遍，这次没带介绍不该把既有站拒掉。
    面板上能改的面按「内置 / 自建」分开：内置站**只**能改「可订阅插件数量」。参见
    [test/plugin_request_test.dart](../../../test/plugin_request_test.dart)
    （`station/register：自建广播站 ⇒ id 由核心拼装…`、`…name 非法 / 缺 readme / 执行站 / 收集站缺 schema 都是可读拒绝`）
    与 [test/plugin_station_test.dart](../../../test/plugin_station_test.dart)
    （`介绍与共享声明落盘…内置点位的介绍来自点位表`）。
21. **跨插件调用只认显式声明，且订阅与触发共用同一把闸门**（2026-10-14，断言 2）：
    自建站默认 `shared: false` ⇒ 别人的插件连门都摸不到；`shared: true` ⇒ 别人能 `station/subscribe`
    （成为下游）、也能 `station/trigger`（调用它）；`allowed_plugins` 非空 ⇒ 名单外一律拒（原因里写出当前名单）。
    判定只有一个入口 `StationInstance.callableBy(pluginId, isOwner:, isBuiltin:)`——**订阅与触发两条路都调它**，
    所以不存在「绕开订阅直接喊」的旁路；**所有者永远能用我自己的站**（门是给别人的，不是防自己的）。
    另外三条硬口径：**内置点位不可被插件触发**（触发时机由核心在固定接入点决定，要用内置能力请下
    `station/command`）、**执行站不可触发**（由命令驱动，没有「触发一次」的语义）、触发消息**必须带确定的
    `mode_key`**（空 mode 在订阅里是通配，但投递判定是「消息 → 订阅者」，没有工作面的消息定不了投给谁；
    拒绝原因要指向 `mode_key` 这个可改的字段）。站点自定义 `config` 随 `meta` 下发给订阅者（`meta` 里另有
    `triggered_by`）——核心**不解释**这些键的含义，但订阅者必须读得到，否则界面上配的「其他参数」就是摆设。
    用例：[test/plugin_request_test.dart](../../../test/plugin_request_test.dart)
    （`自建站声明 shared ⇒ 别的插件可订阅，也可被 station/trigger 触发（断言 2）`、
    `shared 的 allowed_plugins ⇒ 只有名单内的插件能用（所有者不受限）`）。
    **断言 1（左侧站点栏可见）由「快照不按 team 过滤」保证**：站点 id 里不含 team / mode（不变量 2），
    `stationList()` / `snapshot()` 给的就是全局那一份，插件自建站因此与内置点位同栏同列表出现。
22. **面板对站点的写面只有三格，且「禁用 ≠ 退订」**（2026-10-14，界面升级的落点）：
    ① `updateConfig` 改 `max_subscriptions`（内置站唯一可改项，非法值显式报错且**一个键都不写**）；
    ② 自建站另可改 `readme` / `shared` / `allowed_plugins` / `config`（PATCH = 局部更新，**没发的键不改动**）；
    ③ `setSubscriberDisabled(stationId, key, disabled)` 按订阅键位（`plugin_id|scope`）开关某个订阅者。
    **禁用保留订阅关系与回包通道**，只是触发时不投给它；每条跳过都写进 `result.skipped` 并计入
    `skipped_disabled`——**不静默**。禁用标记跨重启保留，插件重新上线**也不会把用户关掉的东西悄悄打开**。
    用例：[test/plugin_station_test.dart](../../../test/plugin_station_test.dart)
    （`updateConfig：面板上能改什么按「内置 / 自建」分开（改完立即生效并落盘）`、
    `订阅者的禁用标记落盘：重启后仍是关着的（不会被重新订阅悄悄打开）`）、
    [test/plugin_request_test.dart](../../../test/plugin_request_test.dart)
    （`站点所有者禁用订阅者 ⇒ 触发不再投递，原因写在 skipped（不静默）`）。

23. **插件的“退出”只认事件与心跳两个判据，不认时长**（2026-10-15 插件热重启，D8）：
    `PluginHost.close()` **没有任何 `timeout(...)`**，也**没有任何 `.kill(...)`**（由用例从
    源码层面钉住）。拆两阶段是因为一个 bug 形状：原来 `shutdown` 之后立刻 `_failPending`，
    会把**正在转储的在途请求自己关掉**。新口径：
    - `requestSuspend()` → 快照入池 → **才** `close()`（所以 `_failPending` 留在转储之后是安全的）；
    - **默认不等退出**（`waitForExit = false`）：一个赖着不退的插件绝不能拖住串行对账；
      只有“真的必须拿到退出码”才显式 `awaitExit: true`（Windows 替换二进制前的文件锁），
      等的也是“进程结束”这个事件而不是时长；
    - 还没确认退出的宿主挂进**收尸台账**（`_reaping`，按实例而不是按插件 id，否则旧进程会被
      “忘”在台账外）；看门狗对它们**只记丢拍、不 ping**（stdin 已关，ping 必定假），
      连续 N 拍无入站证据才 `killStray()`。任何入站报文都是 `recordBeat` ⇒ “心跳在、只是慢”
      永远走不到那一行；
    - `killStray()` 全项目只有两个合法来源：**判失活后的收尸**与**用户显式动作**；
      不单独起保活定时器（看门狗就是节拍本身，两套时钟会打架）。
    用例：[test/plugin_close_no_hard_timeout_test.dart](../../../test/plugin_close_no_hard_timeout_test.dart)、
    [test/plugin_hot_restart_test.dart](../../../test/plugin_hot_restart_test.dart)。

24. **可续跑状态只进核心进程内存，且一世一份**（2026-10-15，D4）：
    `PluginStatePool` **不落盘**（核心退出即丢快照，那正是“热重启续跑”的作用域），
    所以会话事实**不得**只寄存在插件状态里（不变量 8：落库优先）。
    索引键 = `(pluginId, generation)`，**generation 由核心自己推进**（每次 `_startOne` +1），
    插件报的 `dump_id` 只做一致性核对，**不许直接当键用**（否则 A 可靠猜 id 取走 B 的快照）。
    写入归属取 **`plugins.yaml` 的声明**而不是请求里带的 scope（两边同一个推导才比得出相等）；
    取回是 **fail-closed 精确相等**（改了 `team_id` 就不给旧快照，且“被拒”不算消费）。
    一份快照只喂一世；`release()` 只用于“取回后新实例未就绪就退了”那一次作废。
    单条过大 = **整条拒收不截断**（半截状态被当成完整状态恢复比失败更糟）；条数/总字节超限按 LRU 丢最旧，
    刚放入的那条不丢；所有降级都写可读原因。
    用例：[test/plugin_state_pool_test.dart](../../../test/plugin_state_pool_test.dart)、
    [test/plugin_state_pool_scope_test.dart](../../../test/plugin_state_pool_scope_test.dart)。

25. **活性 / 启停 / 阶段是三个独立的轴，`lifecycle` 只能做加法**（2026-10-15，D11/D3）：
    `health`（`ok/degraded/unavailable`，心跳判）、`status`（`registered/disabled`，启停判）、
    `lifecycle`（`stopped/booting/ready/restarting/suspended/failed`，阶段判）**取值集合互不相交**，
    谁也不得吃掉谁。对前端与快照只**新增可选键** `lifecycle` / `generation`，
    `status` 与 `health` 的产出值与升级前逐字一致（旧前端看不到新键也不受影响）。
    映射**集中在 `PluginBus` 一处**：`lifecycleOf()` 是唯一读入口、`_setLifecycle()` 是唯一写入口（台账显式
    写，不从 `isClosed`/`liveness`/`_errors` 四个源反推）；重启窗口**不降回 stopped**，对外一直是 `restarting`。
    挂起声明同样保守：`suspension` 缺省为空串 = **不可挂起**（热重启就冷启动，不报错）。
    用例：[test/plugin_lifecycle_test.dart](../../../test/plugin_lifecycle_test.dart)、
    [test/plugin_hot_apply_test.dart](../../../test/plugin_hot_apply_test.dart)（行为不得变）。

26. **`plugin.*` 六条命令分两套归属口径，快照两条不进 agent tool**（2026-10-15，D10/D9）：
    D10 定稿为「A+B 混合」：**不新增 RPC method**（本任务只新增 `suspend` 一个，由
    [tree_protocol 的门禁](../../../../tree_protocol/lib/src/plugin_rpc_methods.dart) 钉住），
    转储/取回走已有的 `station/command` ⇒ 再没有“method 不存在”这层天然护栏，命令表与归属
    必须自己钉牢。两套口径**刻意不合并**（合并就会一边假严、一边真松）：
    - 控制面四条（`list`/`restart`/`suspend`/`state`）：`scope.team_id` 证明不了就拒（fail-closed）；
    - 快照两条（`stateDump`/`stateFetch`）：发起者**必须是插件本人**且只能动自己的键（它们的闸门是
      “谁在说话”，而不是“目标 agent 属于哪个 team”——快照本来就没有 agent，所以它们在
      `ExecuteStationMounts._handle` 里**绕开四元组解析**，这是写明在代码里的故意面）。
    `PluginToolSurface` 把“哪四条可以被申报成 agent tool / 哪两条不得”定成常量（而不是“等做 tool 时再说”）。
    自重启不许挂死：目标 == 发起者时用 `Timer.run` **先应答再动手**（microtask 不够：回包本身就在
    当前回合的微任务队列里，抢在它前面写 `suspend` 等于没修）。
    用例：[test/plugin_hot_restart_station_test.dart](../../../test/plugin_hot_restart_station_test.dart)。

27. **重启窗口对外是「暂时不可用」，不是「不在了」**（2026-10-15 阶段 2，D2/D8/不变量 6/15）：
    `lifecycle ∈ {restarting, suspended, booting}` 时，站点请求在**唯一投递点**进
    **有界暂存队列**（每插件默认 32 条 + 全局字节上限），`ready` 后按 **FIFO 重放**；
    重放前逐条复查归属（`StationIsolation.checkSubscriber`）与 `request_id` 是否已收尾
    （迟到无害口径）——复查不过的那条**丢弃并计数**，不递一个已经没人等的请求。
    - **溢出 = 当场按既有 fail-open 放行原数据**（会话不受影响），并写下可读原因；
      绝不无界堆积（那是把失败换成一次内存事故）。
    - 队列**只以三种方式收尾**：`ready` 重放 / 落到 `stopped|failed` 以可读失败收尾 /
      核心退出。收尾点挂在**生命周期跃迁那一处**（分散到四个调用方一定漏一处，
      漏掉的那一处就是「会话永远等一条不会被投递的请求」）。
    - **保活期间不得押后注销**（押后就轮不到暂存），但新一世**重新申报订阅时上一世那条
      必须当场作废**：否则改了 `scope` 的重启会让旧团队还能把请求递给新归属的进程
      （中转站那边则是「全站只许一个处理者」直接把新一世拒成 `key_conflict`）。插件侧
      `station/subscribe` 与核心侧工具表收集**两条申报路都要销账**（收集站的订阅是核心
      自己下的，插件一行代码都没写）。
    - **判死定义一个字节都没动**（不变量 15）：只有心跳快照 `down` 与插件进程不可用两处
      能判死；窗口里的活性读数如实报「无信息」⇒ 站点退回既有活性窗口，既不谎报活着，
      也不拿「暂时不可用」当死证。
    - 阶段跃迁走**自己的点位**：新增广播点 `system.broadcast.plugin.state`（别名
      `plugin.state`，单向通知，回包仅作送达确认），发布点 = `_setLifecycle()` 与看门狗
       degraded/恢复处（与 `health` **同一个判定源**，不另造时钟）；载荷含
      `plugin_id`/`lifecycle`/`previous`/`generation`/`missed_heartbeats`/`reason`/`buffer`。
      **归属证明不了就跳过并记日志**（宁可不广播，不广播一条证明不了来源的）。
      它**不进** `plugin_status` 帧（帧的产出点一个都没多）。
    - 路由判据：`stopped`/`failed` ⇒ **不投递**（可读原因，不是默认兜底）；
      `restarting`/`suspended`/`booting` ⇒ 暂存；`callTool` 在窗口里**等事件而不是等时长**。
      配置驱动的换一世（`applyConfigs` 看到 args/scope 变了）与 `hotRestart`/`restart`
      算**同一个窗口**：一个命题不能一套保活一套不保活。
    用例：[test/plugin_restart_keepalive_test.dart](../../../test/plugin_restart_keepalive_test.dart)（7）、
    [test/plugin_restart_buffer_bounded_test.dart](../../../test/plugin_restart_buffer_bounded_test.dart)（9）、
    [test/plugin_state_broadcast_test.dart](../../../test/plugin_state_broadcast_test.dart)（6）、
    [test/plugin_status_compat_test.dart](../../../test/plugin_status_compat_test.dart)（6）。

28. **「热重启一个插件」是一项能力，不是一次手工操作**（2026-10-15 阶段 3，D9/D2/D8）：
    agent 侧的对外面由**三张常量表**定死，不靠下一个写 tool 的人记得：
    `PluginToolSurface.agentToolCommands` = 可申报的控制面四条、`lifecycleOnlyCommands` =
    永不进工具表的快照两条、`auditedCommands` = 前者。
    - **一个 tool + `action` 参数**（`plugin_hot_restart`）而不是四个 tool：四个 tool 会
      把模型工具表撑出四行同族条目，而它们本来就是同一个动作的四种问法。`action` 的
      枚举**由映射表推导**（改成手写的固定表就会漏项：模型按说明书填了合法值却被拒，
      而这种错只有运行时才看得见）。
    - **自重启不许挂死**：目标 == 发起者 ⇒ **先应答再动手**（`Timer.run` 排到下一事件
      循环回合；microtask 不够：回包本身就在当前回合的微任务队列里）。回包带
      `deferred: true`，审计行据此写「已受理」而**不写成功**，结论在紧随其后的
      「自重启收尾」行里；窗口内的站点请求由不变量 27 接住。
    - **控制面每一次动作留一行审计**（谁 / 何时 / 目标 / 结论），挂在
      `handlePluginCommand` **这一处**而不是四个调用点（REST / tool / 看门狗 / UI 各记一处
      就一定会漏一个，漏掉的那个恰好是最需要它的那一个）；快照两条**不审计**（它们
      每一世都要下一次，记进去只会把「谁重启了插件」淹掉）。只记结论，不记载荷。
    - **「强制停止」是全框架唯一能因为界面按钮而 `kill()` 的入口**（`PluginBus.forceStop`）：
      D8 不许的是**时长**判死，不是用户显式动作。它同时覆盖实例表与收尸台账两处目标，
      停完逐个数退出确认，并如实说明「条目仍启用 ⇒ 下一次对账会再拉起来」。
    - **内置清单必须显式带 `suspension`**：`PluginConfig.fromJson` 不保留未知键（不变量 25），
      清单不写这一项 ⇒ 落盘条目永远没有它 ⇒ 「声明了可挂起的内置插件」被冷重启，而界面上
      看上去就是「状态莫名没了」。`self_updater` 因此是 `defaultEnabled: true` + `suspension: keep`；
      播种语义严格（条目根本没有才种 / 解析失败只记日志不落盘 / 用户关过绝不再自动打开）。
    - **插件包零核心依赖 ⇒ 协议常量各自一份**，漂移由
      [tree_protocol 的门禁](../../../../tree_protocol/test/plugin_rpc_method_gate_test.dart) 把
      `packages/tree_self_updater/{lib,bin}` 列入扫描面来钉；而「工具名与插件自报 id 同串」
      由真子进程用例钉。
    - **随包自检给的是退出码**：`tree_self_updater --selftest`（输出走 stderr，
      「stdout 只有协议帧」这条规则不因模式而变）。「面板没报错」证明不了工具真能申报进表。
    用例：[test/plugin_tool_define_self_updater_test.dart](../../../test/plugin_tool_define_self_updater_test.dart)（6）、
    [test/plugin_self_restart_tool_test.dart](../../../test/plugin_self_restart_tool_test.dart)（6）、
    [test/plugin_hot_restart_station_test.dart](../../../test/plugin_hot_restart_station_test.dart)（13）；
    插件自身：[packages/tree_self_updater](../../../../tree_self_updater/test/self_updater_loop_test.dart)（16）。

## 测试

```bash
cd packages/tree_core
dart test test/plugin_test.dart test/plugin_request_test.dart test/plugin_station_test.dart \
          test/plugin_station_wiring_test.dart test/plugin_station_builtin_test.dart \
          test/station_points_test.dart test/plugin_self_station_e2e_test.dart \
          test/plugin_execute_mounts_test.dart test/execute_mounts_scope_test.dart \
          test/plugin_execute_new_commands_test.dart test/plugin_tool_define_test.dart \
          test/plugin_tool_table_test.dart test/plugin_ui_bridge_test.dart test/plugin_ui_manifest_test.dart \
          test/plugin_ui_replay_test.dart test/plugin_config_store_test.dart test/plugin_hot_apply_test.dart \
          test/builtin_plugin_script_roots_test.dart test/plugin_llm_relay_test.dart \
          test/compact_plugin_e2e_test.dart test/sample_plugin_layout_e2e_test.dart \
          test/plugin_hot_restart_test.dart test/plugin_hot_restart_station_test.dart \
          test/plugin_close_no_hard_timeout_test.dart test/plugin_state_pool_scope_test.dart \
          test/plugin_restart_keepalive_test.dart test/plugin_restart_buffer_bounded_test.dart \
          test/plugin_state_broadcast_test.dart test/plugin_status_compat_test.dart \
          test/plugin_tool_define_self_updater_test.dart test/plugin_self_restart_tool_test.dart \
          test/plugin_api_test.dart
```

SSH 执行器那条路（`sshExecutorLookup` / `tunnel/event` 分流 / `kind: binary` 解析与默认播种）
的用例在 `test/builtin_plugin_script_roots_test.dart` 与 `test/plugin_test.dart` 里；
端到端（真 sshd）见 [docs/ssh-tunnel-protocol.md](../../../../../docs/ssh-tunnel-protocol.md) 与
`tool/tunnel_e2e.dart`。

点位清单与四类站的语义另见 [docs/plugin-development.md](../../../../../docs/plugin-development.md)。
