# 侦查落档：会话存储改纯 Dart 数据库（显示/详细分离）+ 中栏工具调用折叠

> 状态：**本期只做侦查与落档，不实施**。文档落档即为本期交付物。
> 日期：2026-11-01。适用版本口径：1.0.5+1。
> 两条需求**同时作用于主对话栏与临时员工/成员窗口**。

用户原话（需求锚点，逐字）：

1. 「将数据存储由 jsonl 改为 litesql，数据分为显示数据和详细数据。（仅显示工具卡片根本不需要拉取全量数据），详细数据在用户点击工具/思考卡片时即时查数据库获取，不缓存。显示数据缓存（仍设上限<一万条）」
2. 「UI 增加折叠设计，相邻的大量工具调用可以折叠为一条显示，分隔的标志为模型的中途消息『折叠 n 次工具调用，点击展开 >』（注意盯住这里的展开，不是在右栏，而是在中间的对话栏，将折叠的展开）。（折叠是用于减轻 UI 渲染负担的，别反倒成累赘。保持只有一处展开）」

「litesql」定案（2026-11-01）：**不用 SQLite，改用纯 Dart 数据库**（推荐 Sembast，决策依据见 §1.5，全部拍板记录见 §6）。

---

## 1. 现状侦查：存储层（jsonl 全链路）

### 1.1 数据布局

定义在 [tree_paths.dart](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/store/tree_paths.dart#L8-L23)：

```
<root>/data/<agent_id>/<session_id>/
    ├── session.json      # 会话元数据（原子快照：写临时文件再改名）
    ├── messages.jsonl    # 消息追加日志（一行一条）
    └── usage.jsonl       # 逐调用用量账本（遥测，非对话）
```

- 当初选 jsonl 的理由（注释原文）：单会话实测 2433 条 / 2.9 MB，全量重写会 O(n) 写放大；且强调「**人类可直接阅读与手改**」。SQLite 化会放弃后者，需要导出工具补偿（§5.1.7）。
- 根目录解析：`--data-dir` → `TREE_HOME` → 平台默认（Windows `%APPDATA%\Tree`）。

### 1.2 写入路径（唯一写者 = tree.agent 插件）

- 核心 [core_server.dart](file:///e:/programs/Tree/desktop/packages/tree_core/lib/src/server/core_server.dart) 已**没有任何 conversations 端点 handler**（grep 无命中）；会话读写全部由 tree.agent 经 `system.collect.api.routes` 申报接管。
- 插件自带一份 store 拷贝：[plugins/tree.agent/lib/src/store/](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/store/file_store.dart)（file_store / memory_store / records / atomic_file / subagent_store / usage_log）。
- 追加落盘：`store.appendMessage` → [file_store.dart L414-L448](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/store/file_store.dart#L414-L448) → `AtomicFile.appendLine`（单行 writeString，硬杀最多丢一行）。调用点集中在 [conversation_service.dart](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/agent/conversation_service.dart)（L282/L368/L834/L861/L1230/L1308/L1549）与团队消息 [message_dispatcher.dart L874](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/team/message_dispatcher.dart#L874)。
- **单调序号不变量**（[tree_store.dart L5](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/store/tree_store.dart#L5)、store/README.md 第 5 条）：同一 (agent, session) 内 `appendMessage` 必须把时间戳抬成严格递增——一轮回复的思考段/正文/工具卡片常落在同一毫秒，历史接口按 timestamp 排序、Dart sort 不稳定，重载顺序会漂移。**SQLite 化后这个不变量应由 `seq INTEGER` 列显式承接**（现在它藏在 timestamp 抬升里）。
- 核心侧 [packages/tree_core/lib/src/store/](file:///e:/programs/Tree/desktop/packages/tree_core/lib/src/store/records.dart) 仍有一份同构 store：仅被等价性校验工具（`tool/verify_agent_equivalence.dart` 等）引用，运行期无调用方。改造时两份要么同步改、要么让校验工具直接对比插件。
- compaction **不改写 messages.jsonl**：[compaction_service.dart](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/agent/compaction_service.dart) 无消息文件写操作，压缩摘要只写 `session.json` 的 `compacted_summary/compacted_message_count`（只影响模型上下文，不影响显示流）。SQLite 化不涉及 compaction 迁移。

### 1.3 读取路径（当前全量读盘点）

| 调用方 | 位置 | 行为 |
|---|---|---|
| `GET /api/conversations/{agentId}`（分页） | [conversation_store.dart L28-L37](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/conversation_store.dart#L28-L37) | **每次请求全量 `readMessages` + 全量 sort**，再 sublist 出一页。`session_id=all` 时遍历所有会话合并 |
| 会话列表 `message_count` | [session_store.dart L190-L219](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/session_store.dart#L190-L219) | `messageCountOf` 也是全量读文件逐行 decode（口径：排除 kind==tool 与多数 subagent 消息） |
| 会话详情端点（全量 messages） | [delegate.dart L995-L1009](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/delegate.dart#L995-L1009) | 返回整份消息（UI 目前**无调用方**，`getSessionDetail` 在 api_service 里定义未用） |
| 提问状态叠加 | [conversation_store.dart L74-L111](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/conversation_store.dart#L74-L111) | `ask_user_question` 消息逐条查 `FileQuestionStore`（真源在 questions 存储，历史行只是快照） |

`readMessages`（[session_store.dart L152-L187](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/session_store.dart#L152-L187)）：整文件 readAsBytesSync → LineSplitter → 逐行 jsonDecode → `_messageToJson` 规范化；坏行跳过。

### 1.4 消息字段形态（显示 / 详细切分的依据）

一行消息的完整键集见 [_messageToJson L221-L271](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/session_store.dart#L221-L271) 与核心 [records.dart L569-L601](file:///e:/programs/Tree/desktop/packages/tree_core/lib/src/store/records.dart#L569-L601)：

- **显示数据**（列表渲染一行卡片头所需）：`id`、`agent_id`、`session_id`、`role`、`kind`、`timestamp`、`tool_name`、`tool_call_id`、`subagent_id/name/level`、`llm_hidden`、`answered`；文本类消息（kind=text）的 `content` 本体就是显示数据（气泡全文渲染）；工具行的"一行关键值" `toolLineValue` 由 `tool_arguments` 现场提取（见 §2.2）。
- **详细数据**（只有点开才用）：`tool_arguments`（Map，可含整文件内容）、`tool_result`（可几千行）、`tool_arguments_raw`、`tool_result_for_model`、thinking 消息的 `content` 正文、`attachments`（含内联图像，受既有 [360p,1024p] 尺寸约束与 JSON 上限→result_path 规则）、`questions` 全量、`usage`。
- kind 枚举实测：`text` / `thinking` / `tool` / `ask_user_question` / `subagent_report`（事件流生成处 [conversation_service.dart L832-L982](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/agent/conversation_service.dart#L832-L982)）。**折叠分隔标志 = kind=text 的模型正文**（定案二轮：thinking 不作分隔，被吸收进折叠组，§3.2）。

### 1.5 数据库依赖现状与选型定案

- 全仓 pubspec.yaml / pubspec.lock **无任何 sqlite/数据库依赖**（grep 无命中），纯增量的绿地。
- **定案（2026-11-01）**：不用 SQLite——`package:sqlite3` 在 Windows 要随插件发布 `sqlite3.dll`（native 资产进发布链路，违背插件包"排除核心二进制"的轻量口径）。改用**纯 Dart 嵌入式数据库**，推荐 **Sembast**：
  - 纯 Dart、零 native 依赖，tree.agent（纯 Dart 进程）直接可用；
  - 事务写（`database.transaction`）、单文件多 store、`Sorter/Finder/useIndex` 支持带索引的过滤+排序+游标分页与 `count`；
  - 自身落盘也是**追加日志 + 检查点**（崩溃最多丢末条、内置 compact），与现有 jsonl 的崩溃模型同构，迁移心智成本最低。
  - 备选 Hive：纯 Dart 但无事务、无条件查询，排序分页全要自建，弃。
- UI 不直接触库：一切经 REST 委派端点（硬约束：UI 插件只是 API 消费者）。核心也不触库：路由归属转发即可。

### 1.6 UI 侧现有加载行为（供改造对照）

- 主面板 [message_panel.dart](file:///e:/programs/Tree/desktop/lib/ui/widgets/message_panel.dart)：首屏只拉末尾 51 条（`kMessageWindowRadius`，[message_window.dart L230](file:///e:/programs/Tree/desktop/lib/ui/services/message_window.dart#L230)）；上滑 `gapsFor → from=` 补页（L1107-L1120）；定位 `at=`（L1208）；回底 `resetTail`（L1000）；远处槽位 `evict` 回 88px 占位。
- **槽位表里存的是整份重负载 ChatMessage**（含 tool_result 全文）——网络分页是懒的，但每页 51 条里可能夹着几 MB 的工具结果；这正是"显示/详细分离"要解决的 UI 侧痛点。
- `loadedList` 全量读消费者：临时员工过程分栏、详情快照、上下文读数（[message_window.dart L282-L288](file:///e:/programs/Tree/desktop/lib/ui/services/message_window.dart#L282-L288)）。
- 队友/成员窗口 [teammates_window_page.dart L615-L627](file:///e:/programs/Tree/desktop/lib/ui/widgets/teammates_window_page.dart#L615-L627)：**无 limit 全量拉整份历史**，`_liveMessages` 全量 List 直接喂 `MessageList(slots:)`（L932-L934），无窗口化无淘汰。

---

## 2. 现状侦查：UI 渲染与展开交互

### 2.1 中栏列表结构

[message_list.dart](file:///e:/programs/Tree/desktop/lib/ui/widgets/message_list.dart)：`ListView.builder` 懒构建，按全局下标取槽位（L982），null 槽渲染恒定 88px 占位（L172）；滚动条几何以**槽位表长度**为分母（只随新消息增长，不随加载/淘汰变化）；补页高度变化已有 `padAboveStamp` / `contentShiftStamp` 两条校正路径（L318-L323、message_panel L1134-L1141）。

### 2.2 工具/思考卡片的现行交互

- [ToolCallCard](file:///e:/programs/Tree/desktop/lib/ui/widgets/tool_call_card.dart#L16-L62)：**一行**（图标+中文标签+`toolLineValue` 关键值+diff/转圈），完整参数与结果**不在中栏展开**；`onTap → DetailSelection.toggle(m)`（点一下选中、再点取消，L62）。
- [ThinkingCard](file:///e:/programs/Tree/desktop/lib/ui/widgets/thinking_card.dart#L34-L49)：同一套 `DetailSelection.toggle`。
- [DetailSelection](file:///e:/programs/Tree/desktop/lib/ui/services/detail_selection.dart)：全局单例，存**整份消息快照**；[right_panel_host.dart L207-L220](file:///e:/programs/Tree/desktop/lib/ui/widgets/right_panel_host.dart#L207-L220) 据此在右栏自动打开详情窗口。**即：现在的"看详情"= 中栏点击 → 右栏渲染内存快照，全量数据本来就在 UI 内存里**——详细数据改即时查库后，这条链要改成"点击 → 按 id 查详情端点 → 右栏渲染"。
- `toolLineValue`（[L175-L253](file:///e:/programs/Tree/desktop/lib/ui/widgets/tool_call_card.dart#L175-L253)）从 `tool_arguments` 提取一行关键值（文件路径/命令/查询词/subagent task/提问摘要）——显示/详细分离后列表拿不到 arguments，**这个 preview 必须前移到写入侧预生成**（§5.1.2）。

### 2.3 折叠/分组现状

- 全 UI grep `collapse|fold|group|merge|折叠`：**消息流没有任何既有折叠/分组逻辑**，纯空白地，无兼容负担。
- 相邻 tool 消息目前逐条各占一行渲染；一轮任务动辄几十条（tool_call_card.dart L18 注释原话），是折叠要收敛的对象。

---

## 3. 方案设计（文档级，供后续切片实施）

### 3.1 存储：jsonl → 纯 Dart 数据库（Sembast），显示/详细两分

**3.1.1 库粒度（定案 A，备选 B）**

- **A. 每 agent 一个 `data/<agent_id>/conversation.semdb`**（Sembast 单文件、内含两个 store）：`session_id=all` 合并、跨会话 `message_count` 都是单查询；会话目录仍保留 `session.json`（元数据不动）。
- B. 每会话一个 db：文件数爆炸（会话×agent），`all` 视图要开多库合并，否决倾向。
- 并发：核心已有**单实例约束**（runtime/core.json 探活），一个 agent 的消息写者只有该 agent runtime 一个进程 → Sembast 的单写者模型天然成立。

**3.1.2 逻辑模式（Sembast 两 store 映射）**

- `messages_display` store（列表页只读这张，记录小、可整段缓存）：key = `seq`（INTEGER，(agent,session) 内单调，**排序唯一依据**，替代 timestamp 排序），value 字段：
  `session_id` / `msg_id` / `role` / `kind` / `timestamp` / `tool_name` / `tool_call_id` / `preview`（写入侧预生成的工具一行关键值，toolLineValue 前移）/ `content`（仅 kind=text 存正文——气泡即显示数据；tool/thinking 置空）/ `tool_running` / `answered` / `llm_hidden` / `subagent_id` / `subagent_name` / `subagent_level`。
  建 `(session_id, seq)` 索引（`useIndex` + `Sorter`）；`all` 视图 = 全 store 按 seq 有序读。
- `messages_detail` store（点击才查）：key = `msg_id`，value = `{ payload }`（JSON：tool_arguments / tool_result / tool_arguments_raw / tool_result_for_model / thinking 正文 / attachments / questions / usage）。
- `total`/`offset`/`has_more` 端点响应形状不变（display store `count(finder)` + seq 游标分页），UI 协议向后兼容。
- 提问状态：questions 仍是真源，读取时叠加（保留旁路，不动 questions）。

**3.1.3 读写路径改造**

- 写：`appendMessage` 经 `database.transaction` 同事务写 display+detail 两条记录（替换 AtomicFile.appendLine；单调 seq 事务内取 display store 当前最大 key +1）。
- 读列表：`conversationPage` 改 display store 有序查询（Finder：session 过滤 + seq Sorter + 游标分页）——**终结"每次请求全量读盘+排序"**（§1.3 表第一行，长会话首屏与翻页延迟都受益）；`messageCountOf` 改 `count(finder)`，同样不再全量读文件。
- 读详情（**新增端点**）：`GET /api/conversations/{agentId}/messages/{messageId}?session_id=…` → 查 messages_detail 返回 payload。委派路由 +1，`agent_api_contract.md` 与路由基线口径（40/54/94/72）同步更新。
- **在途一致性**：正在流式/跑着的工具尚未落库完整结果——runtime 内存里有在途消息；详情端点应**先查在途表、未命中再查库**（否则点开跑着的卡片看到空结果，属行为回归）。

**3.1.4 UI 侧显示数据缓存（首屏常量级一段 + 窗口补拉）**

- **首屏只拉末尾一段显示行**（`kInitialDisplayRows = 200`，见 known-issues #47）：槽位表存轻量显示行（preview + 小字段），更早段是 88px 占位槽、滑到哪补哪、离得远淘汰；详细数据按点击即查、**不缓存**（右栏详情关闭即释放）。
  - **为什么不是一次拉满**：`RenderSliverList` 首次布局只能从下标 0 逐条往后布局，首帧贴底时几千条真消息会在同一帧全部建出来（7,578 条实测 98.8s ⇒ Windows 判 AppHang）；占位槽是固定 88px 的极轻量格子（同一份 7,578 槽位表 3.5s）。
- **不再有"整份缓存"的显式上限**：已加载显示行被窗口机制自发限制在"视口 ± 窗口半径 + 末尾 51 条"（`_evictFarSlots` 始终淘汰，不再按"会话是否超过 9999 条"决定是否淘汰）。
- 队友/成员窗口同规则（末尾一段，或带定位目标时用 `at=` 拉目标那一段）。

**3.1.5 迁移与回退**

- 插件启动时逐 agent 检测：会话目录有 `messages.jsonl` 且 `conversation.semdb` 里无该会话记录 → 一次性导入（按现有 timestamp 序生成 seq，preview 现场计算），成功后 jsonl 改名 `messages.jsonl.migrated` 保留一个发布周期作回滚底。
- 导入幂等：semdb 里该会话已有记录即跳过；半途崩溃 = jsonl 未改名，重启重导。

### 3.2 折叠：相邻工具调用（连带思考段）收敛为一条，有就折叠

**3.2.1 判别规则（纯渲染层，不动数据与窗口模型）**

- **run** = 槽位表中连续的「**已完成工具 + 思考段**」段（`kind=='tool'` 或 `kind=='thinking'`），**含至少 1 条已完成工具即折叠**（定案 2026-11-01 二轮：「要不有就折叠」——展开不费事，用户主要想看的是文本消息而非具体工具调用；即使只有一次工具调用也赚了，因为组内思考段连带一起折叠）；
- **分隔标志** = run 被"真正的中途消息"打断即闭合——即模型**文本正文**（kind=text）、用户消息、`ask_user_question`、`subagent_report`；**thinking 不再充当分隔，被吸收进组**；
- **纯思考段**（组内只有 thinking）同样折叠（定案三轮：「收」），文案「折叠 m 段思考，点击展开 >」，无类型简述；
- 跑着的/流式的工具与流式中的 thinking **永不参与折叠**（用户要看得见进行中状态），组在其边界闭合；`ask_user_question` 永不折叠（需作答）。

**3.2.2 折叠行与展开**

- 折叠行文案：**「折叠 n 次工具调用（edit×a · write×b · terminal×c · grep×d · …）[· 含 m 段思考]，点击展开 >」**——n = 组内工具条数；括号内是**干了啥的简述**：按工具类型计数，类型口径复用既有 `toolLabel`/`toolStyleOf` 的分类（read/edit/write/terminal/grep/search…）；类型过多时按条数降序保留前几项、其余并入 `等×m`，整行超长走单行 ellipsis；组内思考段 m>0 时追加「含 m 段思考」（思考只计数、不分型，展开时随组一并显示）；**纯思考组**（无工具）文案为「折叠 m 段思考，点击展开 >」。
- **简述零后端成本**：计数由渲染层对 run 内显示行现算——`tool_name` 本来就在显示数据里，详细数据不碰。单行高度，样式对齐 ToolCallCard 一行式。
- **展开只有一处、只在中栏原地**：点击折叠行 → run 就地展开为 n 行；再次点击 → 收起。**全局同时只允许一个展开组**——点开新组时旧组自动收起（这就是"保持只有一处展开"与"别反倒成累赘"的落实：展开态是 O(1) 的单个 runId，渲染负担上限 = 一个 run + 视口）。
- 与右栏详情的关系：折叠展开 = 中栏列出 n 行；点开单行详情 = 仍走 DetailSelection → 右栏（§3.1.3 改为即查库）。**两个动作不合并**：折叠展开绝不往右栏推，右栏也永不出现"展开折叠组"的入口。
- **展开/收起锚点不变量（用户三轮点名，TC-COLLAPSE-01）**：折叠行以下方内容增长为唯一效果——折叠行在视口内时，展开/收起**不得让折叠行上方的内容产生任何位移**（高度增量只作用于组自身区域）；组横跨视口顶时，上方增量必须用既有 `padAboveStamp` 路径**精确补偿，净位移仍为 0**。不新造机制、不触发滚底/重锚。
- run 索引表增量维护（监听槽位表变更：place/appendTail/evict/resetTail 五个入口各打一次标记），**不做每帧全表扫描**。
- 实现落点：`MessageList` 内部加一层"槽位下标 ↔ 显示行"映射（折叠 run 映射为 1 个显示行）；滚动条分母仍是全局槽位数（折叠不改变会话总条数，几何口径不破坏）。
- 队友/成员窗口共用 `MessageList` 组件 → 折叠自动生效（其全量 `_liveMessages` 喂入同样适用 run 判别）。

---

## 4. 影响面清单（实施期切片草案，本期不动代码）

| 切片 | 内容 | 关键文件 |
|---|---|---|
| F1 存储 | Sembast store 实现、写读路径、jsonl 迁移、详情端点 | `plugins/tree.agent/lib/src/store/*`、`session_store.dart`、`conversation_store.dart`、`delegate.dart`、`tree.agent/pubspec.yaml`、`verify_agent_equivalence.dart` |
| F2 协议/核心 | 路由申报 +1、契约文档与路由基线口径更新 | `agent_api_contract.md`、`system.collect.api.routes` 申报处 |
| F3 UI 显示/详细 | DisplayMessage 拆分、显示缓存 ≤9999、点击即查详情（不缓存）、队友窗口接入 | `api_service.dart`、`models/message.dart`、`message_panel.dart`、`detail_selection.dart`、`right_panel_host.dart`、`teammates_window_page.dart` |
| F4 UI 折叠 | run 映射层、折叠行组件、单展开态、**TC-COLLAPSE-01** | `message_list.dart`、`message_window.dart`（索引标记）、新 widget、`test/message_collapse_test.dart` |

**TC-COLLAPSE-01（用户 2026-11-01 三轮点名，必须包含）**：构造 100 条混杂消息（工具调用多种类型 × 文本 × 思考 × 提问交错），滚动到第 50 条位置、该处有连续若干次工具调用——点击展开后，**上方内容不发生任何位移**；再次折叠后，**上方内容仍不发生任何位移**。判定口径：取折叠行上方各行在渲染树中的像素 top，展开前/展开后/收起后三次采样逐行对比，差值必须为 0（widget test，`_builtTopsFromRenderTree` 现成可用，见 message_list.dart L666）。

闸门按仓库惯例：dart analyze → 受影响包全量 dart test → tree_protocol 访问控制 → 涉 UI 才跑 flutter。

## 5. 风险与不变量核对

1. **人类可读性丧失**：jsonl 的「可直接阅读与手改」设计原则（tree_paths.dart L7）被 DB 打破 → 需提供导出子命令/端点（本期落档记债）。
2. **等价性校验工具**：核心与插件两份 store 同构拷贝（§1.2），插件改纯 Dart 库后 `verify_agent_equivalence` 的对比基准失效，需同步改造或退役。
3. **timestamp 排序 → seq 排序**：历史行为里同毫秒靠"单调抬升"定序，DB 化后以 seq 为准；迁移导入必须按现有 sort 结果落 seq，否则老会话重载顺序漂移（不变量：store/README 第 5 条）。
4. **在途详情**：§3.1.3 先查内存再查库，漏了就是行为回归。
5. **折叠不得反噬渲染**：run 映射必须增量维护；若实施中出现折叠层每帧 O(total) 扫描，视为违背需求本意（「别反倒成累赘」）。
6. **既有硬约束复核**：插件不得 import 核心包（sembast 是纯 Dart 第三方包，合规、零 native 资产）；UI 仅 REST 委派消费（详情端点走委派，合规）；大字段传输——payload JSON 超限时沿用 `result_path` 磁盘传递规则。
7. questions / usage.jsonl / subagent 名册**不在本期范围**（仍 jsonl），落档以免后续误扩。

## 6. 拍板记录（用户 2026-11-01，全部关闭）

- **Q1**：不用 SQLite，**纯 Dart 数据库**（推荐 Sembast，理由见 §1.5）。
- **Q2**：采纳 A——每 agent 一个 `conversation.semdb`，内含 display/detail 两 store。
- **Q3**：采纳——显示缓存上限 9999 条；**2026-11-10 修正**：首屏不再按上限一次拉满，改为只拉末尾 `kInitialDisplayRows=200`、更早段交给窗口补拉 + 淘汰（长会话一次装满是 AppHang 根因，见 known-issues #47 / §3.1.4）。
- **Q4（三轮定案，覆盖首轮 n>3）**：**有就折叠**——run 含 ≥1 条已完成工具即折叠；**思考段连带入组**（分隔标志只剩模型文本正文/用户消息/提问/汇报）；**纯思考段同样折叠**（「折叠 m 段思考，点击展开 >」）；折叠行追加**干了啥简述**（按工具类型计数 edit/write/terminal/grep/etc，渲染层现算）+「含 m 段思考」，§3.2。
- **TC-COLLAPSE-01**（三轮点名）：100 条混杂消息滚到第 50 条处展开/收起，**上方内容两次都零位移**——已写入 §3.2.2 锚点不变量与 §4 F4 验收，实施漏掉即打回。
- **Q5**：采纳——全局同时只展开一个折叠组，展开仅在中栏原地。「有就折叠」后几乎每段工具区都是组，**这条是渲染负担不回退的唯一保险，实施必须落实**。
- **Q6**：作废——纯 Dart 方案无 native dll 打包问题。
- **Q7**：采纳——jsonl 迁移后改名保留一个发布周期。

---

## 附：本档引用的关键代码坐标

- 布局与写者：[tree_paths.dart](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/store/tree_paths.dart#L8-L23)、[file_store.dart](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/store/file_store.dart#L414-L448)
- 全量读盘：[conversation_store.dart](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/conversation_store.dart#L28-L37)、[session_store.dart](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/session_store.dart#L152-L219)
- 字段形态：[session_store.dart _messageToJson](file:///e:/programs/Tree/desktop/plugins/tree.agent/lib/src/session_store.dart#L221-L271)
- 委派透传：[core_server.dart _delegateQuery](file:///e:/programs/Tree/desktop/packages/tree_core/lib/src/server/core_server.dart#L1693-L1703)
- 工具行与右栏详情：[tool_call_card.dart](file:///e:/programs/Tree/desktop/lib/ui/widgets/tool_call_card.dart#L16-L62)、[detail_selection.dart](file:///e:/programs/Tree/desktop/lib/ui/services/detail_selection.dart)、[right_panel_host.dart](file:///e:/programs/Tree/desktop/lib/ui/widgets/right_panel_host.dart#L207-L220)
- 窗口机制：[message_window.dart](file:///e:/programs/Tree/desktop/lib/ui/services/message_window.dart)、[message_panel.dart](file:///e:/programs/Tree/desktop/lib/ui/widgets/message_panel.dart#L860-L913)
- 队友窗口全量：[teammates_window_page.dart](file:///e:/programs/Tree/desktop/lib/ui/widgets/teammates_window_page.dart#L615-L627)
