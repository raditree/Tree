# 侦查 + 计划：tree.agent 与两个 UI 插件的热重启支持

> 状态：**核心侧 S1~S3 + 打包透传（S7 的一部分）已实施**（2026-11-26）；
> UI 侧 S4/S5 与 tree.agent S6 待插件仓。

> 范围：`packages/tree_core`（插件平台）、`packages/tree_protocol`（帧名与门禁）、
> `plugins/tree.agent`、`plugins/tree.ui.default`、`plugins/tree.ui.feishu`、
> `plugins/tree.ui.default/lib/io/protocol_contract.dart`（零依赖自持契约）、`tool/package_ui_plugin.dart`。
> 相关不变量：核心只认 35 条自有路由（本方案**不新增 REST**）；UI 只是 API 消费者；
> 插件快照只在核心内存（不落盘）；判活只认事件、不认时长。
>
> 本档同时是**实施合同**：§4~§6 是「要做什么」，§8 是「做到什么算对」，§9 是「不许做什么」。
> 任何实现与本文不一致的地方，以本文为准；要改口径必须先改本文。

---

## 1. 结论摘要

1. **tree.agent 已经声明并实现了 `suspension: keep`**（转储 / 续跑 / era 计数都在），
   但续跑里有一条**会误报成功的轮次为中断**的判据（§3.3-①），另有冷启动在途台账无人清扫、
   在途提问不收尾两类缺口。本次**不重写**它，只做「定性权归旧世 + 冷启动清扫 + 幂等」三件事。
2. **两个 UI 插件今天根本没有热重启**：核心的 `hotRestart` 只认 stdio 宿主
   （`_hosts`），UI 走 `_uiHosts`，于是 `hot` 请求实际执行的是「强杀 + 换一个新窗口号重新拉起」：
   快照为空、`resumed=false`、回包原因还写着「实例本来不在跑」（假话）。
   同时 `UiHost.stop()` 在 Windows 上是 `Process.kill()`——**不给界面任何收尾机会**。
3. 因此本次要给 UI 补一条**与 stdio 同语义、不同传输**的热重启：
   `suspend`（WS 帧）→ 界面把**视图状态**交给核心状态池 → 自己退出 → 核心**等到退出事件**再拉起
   **同一 window_id** 的下一世 → 新世 `ui.hello` 后核心把那一份切片推回去。
   核心不认识「草稿 / 滚动 / 会话」——载荷对核心**完全不透明**（只做 JSON 与字节上限）。
4. 三个必须同时发生的配套动作，否则会做出「看起来热重启、实际更糟」的东西：
   - **等旧进程退出**再拉起（否则托盘归属、单实例锁、sidecar、窗口号全打架）；
   - **窗口身份跨世不变**（`w1` 还是 `w1`）；
   - **退出走专门路径**（不能复用 `TrayService.quit()`：它会调 `closeAllUiWindows` ⇒ 核心整体收尾）。
5. 文档口径要改一处：`docs/pluginization/ui-pluginization.md` §6.2 第 2 条现在写着
   「不参与状态池与热重启续跑」——本次**只放开「生命周期握手 + 视图状态」**，其余（连接计数、
   scope、订阅）不动。

---

## 2. 名词与语义定义（先钉死，再写代码）

| 词 | 本次口径 |
| --- | --- |
| **可挂起** | 插件条目声明 `suspension: keep`（`plugins.yaml` / `plugin.json`），且对 UI 插件还要求 `ui.hello.capabilities` 含 `ui.lifecycle`。两者缺一 ⇒ 不参与，按冷重启。 |
| **续上（resumed）** | 新一世**实际取走了**至少一个窗口的切片。核心只按「切片被取走」记 true，不按「进程起来了」记。 |
| **冷重启** | 强杀 + 新进程 + 无快照。**必须**在回包与日志里说清原因（现状那句「实例本来不在跑」对 UI 是假话，见 §3.2-④）。 |
| **中断** | 轮次/工具调用因**进程消失**而没有终态。只有「旧世自己写下的终态」与「台账里的 inflight」能判定中断；**不拿快照猜**（§3.3-①）。 |
| **视图状态** | 只描述「用户此刻看到/正在编辑什么」：窗口几何、选中项、滚动锚点、展开态、草稿、右栏页签。**不含**任何领域事实（消息正文、工具结果、轮次状态、提问答案）。 |
| **进程退出事件** | `UiHost.exited`。UI 没有心跳，这是唯一活性事件；「退出宽限」不是一个判活时钟（§4.4）。 |

---

## 3. 现状侦查（带证据）

### 3.1 核心侧：stdio 热重启是完整的

`PluginBus.hotRestart`（`packages/tree_core/lib/src/plugin/plugin_bus.dart:2559`）时序：
`restarting` → `host.requestSuspend()`（`plugin_host.dart`）→ 等 `plugin.stateDump` 落池
（`_awaitDump`，事件赛跑）→ `_disconnect` → `_startOne(resumeDumpId:)` → 新世 `plugin.stateFetch`。
快照池有界、只存内存（`plugin_state_pool.dart:21-44`：单条 1 MiB / 总 8 MiB / 64 条 / TTL 10 分钟）。

### 3.2 UI 侧：为什么「热」不起来（六条硬事实）

1. **`hotRestart` 只看 `_hosts`**（`plugin_bus.dart:2587`）。UI 宿主在 `_uiHosts` / `_uiWindows`
   （`:329-337`），所以 `host == null` ⇒ 直接进「冷启动」分支。
2. **回包原因是假话**：`host == null` 时写「实例本来不在跑 ⇒ 直接按冷启动拉起（无得可转储）」
   （`:2594-2595`），可 UI 明明在跑。面板据此显示「按冷启动」——事实是对的，原因是错的。
3. **UI 的停法是硬杀**：`UiHost.stop()` 在 Windows 直接 `Process.kill()`
   （`ui_host.dart:166-186`），`close(waitForExit:false)` 不等退出；`_disconnect` 默认
   `awaitExit:false`（`plugin_bus.dart:6256-6270`）。⇒ 草稿、未落盘状态、sidecar 收尾全部没有机会。
4. **窗口号每世都变**：`_startUiOne` 走 `_nextUiWindowId`（`:1055-1057`、`:1005-1017`），
   序号只增不复用。⇒ 重启后 `w1` 变 `w2`，任何按窗口号存的状态都对不上；核心侧
   `GET /api/plugin/windows` 也会越滚越大。
5. **UI 没有把状态交给核心的通道**：`plugin.stateDump` / `stateFetch` 是 `station/command`
   的插件命令，而 WS 桥只放行五条站点帧（`station_ws_bridge.dart:114-121`），
   UI 无法下 `station/command`；`WsInboundType` 与 `WsOutboundType` 的集合**不得相交**
   （`packages/tree_protocol/test/protocol_completeness_test.dart:322`）。
6. **打包链会把 `suspension` 丢掉**：`tool/package_ui_plugin.dart` 的 `_manifest()`
   逐字段重写 `plugin.json`，字段表里**没有** `suspension`（`:283-317`）。
   ⇒ 只在源清单里写 `keep`，装出来的条目仍然不可挂起。

### 3.3 tree.agent：已实现的与还缺的

**已实现**：`tree.agent_plugin.dart:56-130`（`dumpState` / `onResume` / `_applyResume` / `onStop`）、
`AgentRuntime.suspendSnapshot`（`runtime/agent_runtime.dart:540-558`）、
`ConversationService.suspendSnapshot` / `resumeFromSnapshot`（`agent/conversation_service.dart:395-600`）、
`plugins/_kit/plugin_kit.dart:689-728`（先转储、再 ack、再退出）。

**缺口（本次必须处理）**：

① **成功完成的轮次会被下一世误报为「中断」**（语义偏移，P1）。
`resumeFromSnapshot` 的中断判据是（`:507-515`）：
```dart
entry.status == InboxStatus.inflight ||
(wasRunning && entry.status != failed && entry.status != cancelled)
```
`runningAtDump` 是**转储那一刻**的在跑集合（`:461-466`）。转储到退出之间有一个
「写快照 → 等 stateDump 回包 → ack → stop」的窗口（毫秒~数十毫秒，含一次 RPC）。
若某轮在这个窗口里正常跑完，`:2311-2315` 会写 `done`，但快照里仍在 `running`
⇒ 新世把 `done` 覆盖成 `failed`，并给用户发「上一轮因热重启被中断，请重新发送」。
**用户会看到一条完整的回答 + 一句「被中断」**。
设计者当年加这个「或」是为了另一种情形：被 `dispose()` 取消的轮次，`job.run()` 可能
正常返回而被写成 `done`。两种情形必须有**同一个确定性判据**，而不是靠猜。
> 现有用例把这个行为**钉住**了：`test/message_machine_test.dart:534`
> 「快照说在跑、台账已被退出收尾成 done，仍按中断处理」。本次要改判据 + 改用例（§4.6）。

② **冷启动的在途台账没人收尾**。`MessageInbox.recover()`（`message/inbox_ledger.dart:155`）
把 `inflight → pending`（= 重跑，副作用会重复），而且**生产代码零调用点**（只有
`test/inbox_ledger_test.dart` 用）。核心崩溃/插件崩溃后 `inflight` 会永久留着。

③ **在途提问（ask_user_question）不随挂起收尾**。`QuestionBroker` 的 `poll`/`timeout`
定时器（`agent/question_broker.dart:176-188`）随进程消失；UI 那张提问卡停在等待态，
新世没有任何一方去说「这个问题没了」。

④ **续跑不是幂等的边界没测**：`resumeFromSnapshot` 连跑两次时，第一次入队的消息
第二次会走「已在队列中 ⇒ 标 failed」（`:545-550`）——语义上说得通，但没有用例钉住。

### 3.4 两个 UI 插件的现状

**tree.ui.default（默认界面）**

- 启动：`main.dart:60-70` 单实例锁**只在没有 window_id 时**生效（核心拉起的窗口都不抢锁）；
  `:100-130` 主题/字号/字体/阻尼都先读本地偏好再画第一帧。
- 视图状态分布（本次要转储的就是这些）：
  - `_MainPageState._selectedAgent` / `_currentSessionId`（`ui/pages/main_page.dart:161,164`）；
  - 右栏页签与宽度（`_rightPanelEntries`，`:2029`）；
  - `MessagePanel._feed` 窗口（`services/message_feed.dart`）与 `_userDetached`；
  - 折叠展开组 `_expandedAnchorIds`（`widgets/message_list.dart:393`）；
  - 草稿 `MessageDraftCache`（`widgets/message_input.dart:99-132`，注释明确写「只放内存、重启后为空」）；
  - 窗口几何：**没有任何持久化**（全仓无 `setBounds` 存档路径）。
- 退出：`TrayService.quit()`（`io/tray_service.dart:315-339`）会先
  `_closeAllUiWindows()`（`:274-298`）⇒ 核心认为「UI 主动退出」⇒ 可能整体收尾。
  **挂起退出绝不能用它**。

**tree.ui.feishu（飞书远程控制）**

- `main.dart:60-120`：**无条件**抢单实例锁（不看 window_id）；`RemoteService` 有
  `recoverActiveTurns()`（`remote/remote_service.dart:161-183`）——它把上次遗留的
  「进行中」占位卡改成「插件重启，本轮已中断」。**这正是热重启不该发生的事**：
  热重启只换 UI 进程，`tree.agent` 的轮次还在跑，用户会收到假的「已中断」。
- 需要跨世的视图状态：`_Turn`（chat_id / agent_id / session_id / placeholder_id /
  activity_message_id / started_at / segments / final_text / midway_cards /
  last_keepalive_minute / pending_question_id，`remote_service.dart:1000+`）与 `_pendingQuestions`。
- sidecar：Dart 侧 `SidecarClient.dispose()`（`io/sidecar_client.dart:366-378`）才 kill 子进程；
  Go 侧在 stdin EOF 后 return（`sidecar/main.go:51-71`）。⇒ 父进程被**硬杀**时，
  sidecar 靠 EOF 退出有延迟；新世立刻起第二个 sidecar 会出现「两条飞书长连接」。

### 3.5 文档口径冲突（必须先改文档）

`docs/pluginization/ui-pluginization.md:419`：

> **不做 stdio 握手**、不接 `tools/list`、不注册站点、**不参与状态池与热重启续跑**

本次把它改成：「不参与 stdio 握手与工具面；**生命周期握手与视图状态快照例外**（§6.2.1）」，
其余不动。`docs/plugin-development.md` §6.5 增「UI 插件的那一条传输」小节。

---

## 4. 设计

### 4.1 机制总览（与 stdio 同语义，传输换成 WS）

```
核心                                         UI 插件进程（第 N 世）
 │  hotRestart(id)  [runtime=ui]
 │  lifecycle=restarting（已有）
 │
 ├─ plugin.suspend ───────────────────────────▶ 停输入/停动画；采集视图状态
 │                                             （只读内存，不落盘）
 ◀──────────────────────── plugin.suspendAck ── {ok, window_id, payload|error}
 │
 ├─ statePool.put(pluginId#generation, {windows:{wN: payload}})   ← 核心代收
 │
 ├─ 等 exited（宽限 uiSuspendGrace 后 kill）      UI 自己收尾并 exit(0)
 │
 ├─ _startOne(resumeDumpId, 原 window_id 列表) ─▶ 第 N+1 世（同一批 wN）
 │
 ◀──────────────────────── ui.hello(window_id) ── 身份（已有）
 ├─ plugin.resume ────────────────────────────▶ {has_snapshot, payload: 本窗口切片}
 │  （无论有没有快照都发：UI 用这条做「首帧前先等一等」的确定性信号）
```

**为什么每条都是这样：**

- **为什么核心代收快照**（而不是 UI 自己写盘）：状态池已经有「一份只喂一世、有界、TTL、
  审计」四件事（`plugin_state_pool.dart`），自己再写一份等于造第二套会漂的语义；
  而且「不落盘」是既有红线。
- **为什么载荷对核心不透明**：核心不认识草稿/滚动/会话；核心只校验「是 JSON 对象、不超限」。
  **任何在核心里出现的 `draft` / `scroll` / `session` 字段名 = 实现偏差**（§8-②）。
- **为什么必须等退出事件**：托盘归属（`TrayService.claimTrayOwner`）、飞书单实例锁、
  sidecar、`TREE_UI_WINDOW_ID` 都必须「旧的一世真的没了」才成立。现路径
  `kill()` 之后立刻拉起 = 把这些都交给运气。
- **为什么窗口号要复用**：窗口号是「窗口级状态」的身份（`TREE_UI_WINDOW_ID`），
  也是面板上多窗口的读数。每世 +1 会让按窗口存的东西对不上，还会让
  `GET /api/plugin/windows` 越滚越多。
- **为什么 suspend 只发给声明了能力的连接**：一个窗口现在有 2~3 条 WS 连接
  （业务 / 站点 / 插件监控），只有一条能拿到视图状态。用 `ui.hello.capabilities`
  里的 `ui.lifecycle` 指名，核心就不用猜「发给谁」。

### 4.2 协议（新增 3 个帧名，2 个方向）

| 方向 | type | 语义 | 载荷 |
| --- | --- | --- | --- |
| 核心→UI | `plugin.suspend` | 请求挂起（**不是**广播，有明确目标与回执） | `{reason:"hot_restart", generation, plugin_id}` |
| UI→核心 | `plugin.suspendAck` | 应答 + 本窗口切片 | `{ok, dumped, window_id, plugin_id, bytes?, payload?, error?}` |
| 核心→UI | `plugin.resume` | 新世取回（每次 hello 后都发） | `{has_snapshot, generation, dump_id?, window_id, payload?, reason?}` |

约定（写进 `packages/tree_protocol/lib/src/ws_inbound.dart` / `ws_outbound.dart` 与 UI 侧
`protocol_contract.dart` 的同一张表）：

1. `WsInboundType.all` 与 `WsOutboundType.all` **不得相交**（门禁已有）⇒ 三个名字互不相同。
2. 三条帧都只对**已 `ui.hello` 的连接**有效；未绑定的连接收到即 `error` 帧并记日志。
3. `plugin.suspend` 只发给 `bond.capabilities` 含 `ui.lifecycle` 的连接；同
   `(plugin_id, window_id)` 的**首条 ack 生效**，重复 ack 丢弃并记一行。
4. `plugin.resume` 在每次 `ui.hello` 之后由核心推一条（冷启动也推，`has_snapshot:false`
   + 可读 `reason`）。UI 用它决定「是否先恢复再画第一帧」；**不允许**用定时器等它。
5. 载荷上限沿用状态池（单条 1 MiB、总 8 MiB），超限 ⇒ 该插件本次按冷启动，
   回包与日志写明「转储过大」，**不截断、不落盘**。
6. 旧 UI（不声明 `ui.lifecycle`）与旧核心（不认这三条帧）互不影响：
   核心侧缺能力就走冷启动；UI 侧收到未知帧按既有「忽略并 debugPrint」处理。

### 4.3 核心改动（逐文件）

**`packages/tree_protocol/lib/src/ws_inbound.dart` / `ws_outbound.dart`**
- 增 `pluginSuspendAck`（inbound）、`pluginSuspend` / `pluginResume`（outbound），
  进 `all` 与基线增量表；`test/protocol_completeness_test.dart` 的计数断言同步。

**`packages/tree_core/lib/src/plugin/station_ws_bridge.dart`**
- `_UiConnectionState` 暴露 `bond`（已有）与 `connection`；新增：
  - `List<WsConnection> lifecycleConnectionsOf(String pluginId)`：按 capability 过滤；
  - `Future<UiSuspendAcks> requestSuspend(String pluginId, {required Set<String> windowIds, required Duration grace})`：
    每窗口发一条 `plugin.suspend`，等 ack / 连接关闭 / `exited`（由调用方传入的 future）；
    返回 `{acks: Map<windowId, payload>, missing: Set<windowId>, reason}`；
  - `void pushResume(String pluginId, String windowId, Map<String, dynamic> payload)`；
  - hello 处理后回调 `onUiHello`（已有）——**resume 的推送放在 PluginBus 的回调里**，
    不让桥认识状态池。
- `_handleSuspendAck`：校验 bond、去重、把 ack 交给 `onUiSuspendAck` 回调。

**`packages/tree_core/lib/src/plugin/ui_host.dart`**
- 新增 `Future<bool> awaitExit(Duration grace)`：只等 `_exited`，超时返回 false（**不 kill**）。
- `close({bool waitForExit, bool gracefulFirst = false})`：`gracefulFirst` 时先 `awaitExit`
  再决定是否 `kill`；其余调用方行为逐字不变。

**`packages/tree_core/lib/src/plugin/plugin_bus.dart`**
- `hotRestart`：
  - 判定 `config.runtimeKind == ui` ⇒ 走 `_hotRestartUi`；
  - 非 UI 分支**逐字不改**。
- 新增 `_hotRestartUi(id, {keepState})`：
  1. `_setLifecycle(restarting)`（已有）；
  2. `final windows = _liveUiWindowsOf(id)`（**先取快照再断开**）；
  3. `keepState && cfg.canSuspend` ⇒ `bridge.requestSuspend(...)`；否则 reason 写明；
     否则（未声明）reason = 「没声明 suspension: keep ⇒ 冷重启」；
  4. 汇总 payload 成 `{schema:1, windows:{wN: {...}}}` → `statePool.put(pluginId, generation, payload, scope: StationScope.parse(cfg.scope))`；
     put 被拒 ⇒ reason 用 put 的 error，仍继续冷重启；
  5. 每个 `UiHost`：`close(gracefulFirst: true)`（先等退出，宽限 `uiSuspendGrace`，超时才 kill），
     并把 `windows.length` / 退出结论记进日志；
  6. `_startOne` 的 UI 分支改调 `_startUiOne(config, generation: g+1, windowIds: 原列表, resumeDumpId: id)`；
  7. `statePool.take(pluginId, generation: g, scope)` 取一次，切成
     `Map<windowId, payload>` 放进 `_resumeSlices[pluginId]`（generation 变了就清）；
  8. `PluginHotRestartResult`：`resumed = 至少一个窗口的切片被取走`，新增
     `windows: [{window_id, resumed, bytes}]`（只增键）。
- `noteUiHello` 之后（同一回调）调用 `_pushResumeIfAny(pluginId, windowId)`：
  取该窗口切片 → `plugin.resume` → 标记已取走；没有快照也推 `has_snapshot:false`。
- `_pluginState` 的 `running`：UI 插件按「有活窗口」算（现在是 `_hosts` ⇒ 恒 false，
  这是既有假读数，顺手修正并在用例里钉住）。
- 新增常量 `uiSuspendGrace`（默认 5s，可注入；注释写明「这不是判活，UI 没有心跳」）。

**`tool/package_ui_plugin.dart`**
- `_manifest()` 透传 `suspension`（只允许空 / `keep`，与 `build_plugins.dart:681` 同口径）。

### 4.4 时序与边界（实现时逐条对照）

| 场景 | 期望行为 |
| --- | --- |
| 未声明 `suspension: keep` | 不走 suspend，直接冷重启；回包 reason 必须是「没声明」而不是「没在跑」。 |
| 声明了但 hello 没带 `ui.lifecycle`（旧构建） | 同上；reason 写「本构建不支持挂起」。 |
| ack 超时（窗口卡住） | 到 `uiSuspendGrace` 后 `kill`；**已收到的切片仍然有效**，下一世照常续。 |
| ack 成功但进程 5s 不退 | `kill` 并记一行；切片有效。 |
| 多窗口 | 每个窗口各自 ack 一份；缺哪个窗口就哪个窗口冷启动，其余续上。 |
| 旧连接迟到 hello（旧进程还没死透） | 只认当前世代的宿主表（`noteUiHello` 已有校验收紧到 **window_id 必须在活窗口表里**），否则丢弃并记日志。 |
| 新世起不来 | 现有失败隔离：`failed` + 可读原因；切片按 TTL 自然过期（不手工删，避免「删了但日志说续上了」）。 |
| 核心重启 | 快照随核心内存消失（既定语义），UI 冷启动；**UI 不得自己落盘兜底**（否则绕过 TTL/一份一世）。 |
| 挂起期间用户点退出 | ack 后 UI 直接退出；核心等到退出事件，不重复 kill。 |
| 状态池满 / 单条超限 | 冷启动 + 可读原因；UI 自己不得重试第二次 dump（重复 put 会覆盖同键）。 |

### 4.5 默认 UI（tree.ui.default）改动

**新增 `lib/io/ui_lifecycle.dart`**
- `UiLifecycleClient`：挂在 `StationClient` 的**同一条连接**上（它是 app 级单例、身份已绑定、
  与业务帧无关），声明 capability `ui.lifecycle`（`ui_identity.dart` 增加常量与 hello 字段）。
- `handleFrame`：识别 `plugin.suspend` / `plugin.resume`，转给 `UiStateRegistry`。
- `Future<void> suspendAndExit()`：
  1. 调 `UiStateRegistry.snapshot()`（同步、只读内存；**不许** await 网络/REST）；
  2. 发 `plugin.suspendAck`（带 payload / error）；
  3. 停 sidecar（默认 UI 没有）/ 释放托盘归属（`TrayService.releaseTrayOwner`）/ 释放单实例锁（如有）；
  4. `windowManager.destroy()` → `exit(0)`；
  5. **绝不**调 `closeAllUiWindows`（`TrayService._closeAllUiWindows` 那条路）。
- 若 `snapshot()` 抛错：ack `{ok:true, dumped:false, error}`，仍退出（宁可冷启动，不可卡住核心）。

**新增 `lib/io/ui_state.dart`**
- `UiStateRegistry`：注册若干 `UiStatePart`（`String key; Map<String,dynamic> Function() snapshot; void Function(Map) restore;`）。
- 注册点（谁的状态谁提供，避免一个上帝类）：
  - `MainPage`：`selection`（agent / team / session）、`right_panel`（页签 + 宽度）、`route`；
  - `MessagePanel` + `MessageList`：`middle`（窗口两端全局下标、锚点消息 id + 视口内偏移、`following`、展开组 id）；
  - `MessageInput`：`drafts`（`MessageDraftCache` 全量，按 `team|session` 键；单条 ≤ 8 KiB、总 ≤ 256 KiB，超限即丢最旧并记日志）。
- 恢复顺序（**这是防抖动/防闪的关键**）：
  1. `main()` 起 `UiLifecycleClient` 并**等** `plugin.resume`（有界：连接建立/重连本身有超时；
     不许自己加定时器）；拿不到就按冷启动；
  2. `MainPage` 先恢复 `selection`（这样首屏就拉对 agent 的末尾页，不会「先默认再跳」）；
  3. 末尾页落地后，`MessagePanel` 按锚点 id 走一次既有 `at=` 定位（复用
     `_locateMessage` 的「拉页 + 定位」路径，但**不带高亮动画**、`bottomJump=false`）；
  4. 锚点失败（消息已被裁剪 / 会话已变）⇒ 贴底 + 一行日志；
  5. 草稿在输入框 `initState` 的 `_restoreDraft` 之前灌进 `MessageDraftCache`；
  6. 窗口几何在 `windowManager` ready 后 `setBounds` + `maximize`（一次，不反复）。
- **不恢复**（写进注释，防止下一次有人顺手加）：提问答案、未发送工具动作、
  `working` 徽标（真值来自核心）、临时员工 transcript（按会话重拉）、
  字体/主题/阻尼（本地偏好本来就有）、终端会话（执行器侧自己重连）。

**`protocol_contract.dart`**
- 增三条帧名 + `ui.lifecycle` 能力常量；进「帧完备性」集合与基线增量注释。
- 该文件**零依赖**：不得 import 任何包（门禁）。

### 4.6 tree.agent 改动

① **中断定性权归旧世**（修 §3.3-①）：
- `ConversationService.dispose()` 改成 `Future<void> shutdown({bool interrupted = false})`：
  对每个仍在 `_running` 的 token，**先**写台账 `failed`（原因 `hot_restart_interrupted` /
  `process_exit_interrupted`），再置 `cancelled`，并在 `_drainMessages` 的
  「`!failed` ⇒ done」分支加一道闸：`_interruptedMessageIds` 命中的 id 一律写
  `cancelled`，绝不写 `done`；
- `resumeFromSnapshot` 的中断判据**只保留 `entry.status == inflight`**；删掉
  `wasRunning && ...done` 这一支（`runningAtDump` 只用于日志与诊断，不再覆盖终态）；
- 用例改写：`message_machine_test.dart:534` 改成「快照说在跑、台账已 done ⇒ **保持 done**，
  不播中断提示」；新增「dispose 先定性」用例（模拟 run 正常返回 + 已完成写入竞争）。

② **冷启动在途清扫**：插件 ready 后（`_onReady` 内、`_applyResume` **之前**）对
`agentInstances` 的每个会话台账执行一次 `markOrphansFailed()`（新方法：
`inflight → failed('上一进程退出时该轮未收尾')`）。**不要**调 `recover()`（它改成 pending ⇒ 重放副作用）。
若本次有续跑快照，则**跳过**这一步（续跑自己会收），顺序写进注释。

③ **在途提问收尾**：`QuestionBroker` 挂起/关停时对所有 flight 发 `cancelled` 帧
（UI 那张卡变成「已取消」），并在续跑时对上一世遗留的提问补一条可见提示（llmHidden）。

④ **幂等**：`resumeFromSnapshot` 连跑两次的用例（第二次 0 interrupted / 0 requeued，
且不重复播报）。

⑤ `--selftest` 增一条「两世」用例（假核心：suspend → dump → 新进程 fetch → 报告）。

### 4.7 飞书（tree.ui.feishu）改动

- 声明 `ui.lifecycle`，接 `plugin.suspend` / `plugin.resume`（同 §4.5 的 client，代码可复制但要与
  默认 UI 同构，避免两份行为漂移；**不要求**抽公共包——两个插件各自 import 自己的 `_kit`）。
- 快照：`window`（bounds）、`shell`（展开/收起）、`turns`（§3.4 全部字段，`segments` 里只留
  文本；单条上限 4 KiB，总上限 128 KiB，超限丢最旧 segment 并记日志）、`pending_questions`。
- 恢复：**不调用** `recoverActiveTurns()`（它是崩溃语义）；改为：
  1. 先恢复 turns；
  2. 起 keepalive 后向核心查一次真实运行态（已有 `agent.state` 读口/广播）；
  3. 只有「核心说不跑了 / 轮次确实没了」才把占位卡收口成中断；
  4. 用户能看到的差别：热重启后是「继续更新」，不是「已中断」。
- 退出：`sidecar.stop()`（发 shutdown 行 → 等退出，宽限 1s 后 kill）→ 释放单实例锁 →
  `tray.destroy()` → `windowManager.destroy()` → `exit(0)`；**不调** `closeAllUiWindows`。
- 单实例锁：挂起退出必须 `lock.release()`（否则新世 `alreadyRunning` 直接退，见
  `tree.ui.feishu/lib/io/single_instance.dart`）。

---

## 5. 快照 schema

### 5.1 信封（核心侧唯一认识的部分）

```jsonc
{
  "schema": 1,
  "windows": {
    "w1": { "plugin_id": "tree.ui.default", "window_id": "w1", "saved_at": 1730000000000, "ui": { /* 不透明 */ } },
    "w2": { "...": "..." }
  }
}
```

### 5.2 默认 UI 的 `ui`

```jsonc
{
  "schema": 1,
  "window": { "bounds": [x, y, w, h], "maximized": false, "dpi": 1.0 },
  "selection": { "agent_id": "...", "team_scope_id": "...", "session_id": "..." },
  "middle": {
    "window": [oldest, newest], "total": 1234,
    "anchor_id": "msg_...", "anchor_offset": 128.5, "following": false,
    "expanded_runs": ["msg_..."]
  },
  "drafts": { "team|session": { "text": "...", "files": ["E:/a.png"] } },
  "right_panel": { "active": "files", "width": 360 },
  "route": "main"
}
```

### 5.3 飞书的 `ui`

```jsonc
{
  "schema": 1,
  "window": { "bounds": [x, y, w, h] },
  "shell": { "expanded": false },
  "turns": [{ "chat_id": "oc_...", "agent_id": "...", "session_id": "...",
              "placeholder_id": "om_...", "activity_message_id": "om_...",
              "started_at": 1730000000000, "final_text": "", "midway_cards": 2,
              "last_keepalive_minute": 7, "pending_question_id": "",
              "segments": [{ "kind": "text", "text": "..." }] }],
  "pending_questions": [{ "chat_id": "oc_...", "id": "q_...", "options": [], "count": 1 }]
}
```

---

## 6. 测试矩阵与门禁

| 层 | 必测 |
| --- | --- |
| tree_protocol | 三条帧名登记 / in-out 不相交 / 基线增量计数 / 文档契约 |
| tree_core | 假 `UiHost` + 假桥：① suspend→ack→退出→同一 wN 重拉→resume 分片；② 无 `ui.lifecycle` ⇒ 冷启动 + 原因；③ ack 超时 ⇒ kill 且切片仍续；④ 超限 ⇒ 冷启动；⑤ 多窗口缺一片；⑥ 迟到 hello 被拒；⑦ `plugin.state.running` 对 UI 为 true |
| tree.ui.default | 状态序列化/恢复（坏 JSON / 版本不符 / 字段缺失 / 超限）；恢复后**不贴底不跳**（widget test，与 `message_feed` 的锚点路径）；`suspendAndExit` 不触碰 `closeAllUiWindows`（注入假 ApiService 断言零调用） |
| tree.ui.feishu | turns 序列化/恢复；**断言恢复路径不调用 `recoverActiveTurns`**；sidecar 先 stop 再 exit 的顺序；单实例锁释放 |
| tree.agent | §4.6 的五个用例（含删掉旧判据后的负向用例） |
| 文档 | `ui-pluginization.md` §6.2、`plugin-development.md` §6.5、本档、协议基线注释 |

门禁顺序按 `docs/plugin-platform.md` §4：`dart analyze` → 包内 `dart test` → `tree_protocol` 门禁
→ `check_plugin_repo_contract.dart` → UI 的 `flutter analyze lib` + `flutter test`。

---

## 7. 实施切片（S1~S7）

| 片 | 内容 | 完成判据 |
| --- | --- | --- |
| S1 | 协议与文档口径：三条帧名 + `ui.lifecycle` + 基线表 + §3.5 两处文档 | `tree_protocol` 全绿，门禁计数已更新 |
| S2 | 核心桥：能力过滤、`requestSuspend`、`pushResume`、ack 去重 | 桥单测（假连接）全绿 |
| S3 | 核心总线：`_hotRestartUi`、窗口号复用、切片表、退出宽限、`plugin.state.running` | `tree_core` 全绿；冷路径零 diff |
| S4 | 默认 UI：lifecycle client + state registry + 恢复顺序 + `suspendAndExit` | `flutter analyze` 0 / `flutter test` 全绿 |
| S5 | 飞书：同上 + turns/sidecar/单实例 | 同上 |
| S6 | tree.agent：定性权归旧世 + 冷启动清扫 + 提问收尾 + 幂等 | `dart test` 全绿（含改用例） |
| S7 | 打包链 `suspension` 透传 + 全量门禁 + 文档收尾 | `package_ui_plugin` 产出清单含 `suspension: keep` |

---

## 8. 验收清单（逐条核对，任何一条不过即返工）

**语义类**

1. `hotRestart` 对 UI 的**唯一**新行为是「挂起 → 转储 → 等退出 → 同一窗口号重拉 → 推回切片」；
   stdio 路径逐字未改（用 diff 证明）。
2. 核心代码里**不出现**任何视图域字段名（`draft` / `scroll` / `session` / `agent`）——
   载荷不透明是硬约束。
3. `resumed=true` 只在「切片被新世 hello 取走」时成立；失败一律带可读原因，
   且**不再出现**「实例本来不在跑」这种对 UI 的假话。
4. 判活仍然只认事件：新增的唯一时间是 `uiSuspendGrace`（退出宽限），注释写明它不是心跳。
5. tree.agent：已 `done` 的轮次**永不**被改写成 `failed`；被挂起打断的轮次**恰好一次**
   `failed` + 一条提示；`resumeFromSnapshot` 连跑两次无副作用。
6. 飞书热重启后**不出现**「插件重启，本轮已中断」这类假提示（只要 `tree.agent` 还在跑）。
7. 默认 UI 恢复后：选中的 agent/session 一致、滚动锚点一致（±1 行内）、草稿一致、
   窗口几何一致、右栏页签一致；**首帧不闪**（不出现「先默认 agent 再跳」）。
8. 多窗口：两个窗口都续上各自切片；窗口号不变；面板读数不因重启增长。

**实现偏差类**

9. 禁止新增 REST 路由：`ApiPaths.coreOwned` 仍 35、`contractRoutes` 仍 123。
10. 禁止把 UI 快照落盘（核心侧与 UI 侧都不许）；禁止 UI 自己重试 dump。
11. 挂起退出路径**不得**调用 `closeAllUiWindows` / 托盘 `quit()`；不得触发核心整体收尾。
12. 旧进程未退出前不得拉起新进程（用假宿主断言 spawn 发生在 exit 之后）。
13. `plugins/tree.ui.default/lib/io/protocol_contract.dart` 仍零依赖。
14. `package_ui_plugin` 产出的 `plugin.json` 带 `suspension: keep`（否则装机端仍是冷启动）。

**门禁类**

15. `dart analyze` 0（tree_core / tree_agent / tree_protocol）；UI `flutter analyze lib` 0。
16. 各包测试数量与既有基线相比**只增不减**，失败 0。
17. `docs/plugin-platform.md` §1 的 22 条硬约束无新增违反（尤其 1/15/16/21）。

---

## 9. 非目标与红线（不许做）

- **不是** Flutter 的 hot reload：本次是「换进程 + 续视图」，不做代码热替换。
- **不**把领域事实搬进快照：消息、工具结果、轮次状态、提问答案一律重新从核心/agent 拉。
- **不**为 UI 新增 REST 路由，也**不**让 UI 下 `station/command`。
- **不**改 `connections` 计数口径（现状 2~3 条/窗口，与「窗口数」的旧文案不一致，
  另案处理；本次只要求不因重启增长）。
- **不**用「多等一会儿」代替事件：除 `uiSuspendGrace` 外不得新增等待。
- **不**动 `tree.agent` 的既有续跑骨架（转储字段、`_enqueueResumed`、tip 结算），只改判据与收尾。

---

## 10. 待拍板（实施前需确认）

| 编号 | 问题 | 建议 |
| --- | --- | --- |
| Q-1 | tree.agent 的「done 不再被覆盖」会改变 2026-11-21 那条既有语义（有用例钉住） | 按 §4.6-① 改：定性权归旧世，判据只认台账；旧用例改写并保留负向断言 |
| Q-2 | 是否允许 UI 快照进状态池（与 `ui-pluginization.md:419` 冲突） | 允许，仅「视图状态」；文档改写为「生命周期握手 + 视图状态例外」 |
| Q-3 | `uiSuspendGrace` 默认 5s 是否可配 | 先写常量 + 构造参数注入（测试用），不开放用户设置 |
| Q-4 | 多窗口热重启是否整批重启 | 整批；缺片窗口单独冷启动 |

---

## 11. 参考

- 既有热重启口径：`docs/plugin-development.md` §6.5 / §6.6 / §6.7
- UI 插件化：`docs/pluginization/ui-pluginization.md` §6.2 / §6.4
- 状态池：`packages/tree_core/lib/src/plugin/plugin_state_pool.dart`
- 参考实现：`plugins/suspendable/suspendable_plugin.dart`、`plugins/_kit/plugin_kit.dart:689-728`
- 滚动模型（恢复锚点要接的路径）：`docs/scroll-model-rewrite-recon.md` §2.7
