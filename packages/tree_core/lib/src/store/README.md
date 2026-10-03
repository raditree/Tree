# store（数据根与存储层）

`<数据根>` 的路径布局、记录模型与读写实现。核心的单用户数据都在这里，且全部是**人能直接打开手改**的文本。

## 文件

| 文件 | 作用 |
| --- | --- |
| [tree_paths.dart](tree_paths.dart) | 数据根解析（override → `TREE_HOME` → 平台规范位置 → `~/.tree`）与布局定义 |
| [records.dart](records.dart) | 四个记录：`CoreAgent` / `CoreSession` / `CoreMessage` / `CoreSubagent`（临时员工）；持久化形态 `toJson` 与前端形态 `toApiJson` |
| [subagent_registry.dart](subagent_registry.dart) | **临时员工名册**：会话级内存索引（`id → 记录`、会话键 → 列表）+ 会话内**树**（`parent_id`/`level`）+ 按需装载/按树收 |
| [subagent_store.dart](subagent_store.dart) | **内存覆盖层**（`TreeStore` 装饰器）：`sub_…` 走名册，其余转发真 store |
| [tree_store.dart](tree_store.dart) | 存储契约（两个实现共享同一份语义说明） |
| [file_store.dart](file_store.dart) | 落盘实现：YAML 配置 + 缩进 JSON 会话元数据 + jsonl 消息；懒加载 + 进程内缓存 + write-behind |
| [memory_store.dart](memory_store.dart) | 纯内存实现（测试与"无落盘"场景） |
| [write_queue.dart](write_queue.dart) | 每文件串行的后台写队列 |
| [usage_log.dart](usage_log.dart) | **逐调用用量账本**：`<会话目录>/usage.jsonl`（一行一次 LLM 调用）+ 可注入的 `UsageSink` |
| [atomic_file.dart](atomic_file.dart) | 原子快照（临时文件 + 改名）与 jsonl 读取（坏行跳过并计数） |
| [yaml_codec.dart](yaml_codec.dart) | 读取用 `package:yaml`（宽容手写），写入自己实现（稳定键序 / 文件头注释 / 块标量） |

## 不变量（assertions）

1. **布局固定**：`config/settings.yaml`、`config/models/<id>.yaml`、`agents/<id>.yaml`、`logs/core.log`、`data/<agent_id>/<session_id>/{session.json,messages.jsonl,usage.jsonl}`。
   消息为什么用 jsonl：单个会话实测已达 2433 条 / 2.9 MB，全量重写会让每次追加变成 O(n) 写放大并放大崩溃损坏面；追加日志天然只影响一行。
2. **写语义是 write-behind**：写操作先改内存缓存并立即返回，落盘任务排进 `WriteQueue`（同路径串行、不同路径并行）。`flush()` **必须**在关停与测试里调用；进程被硬杀时未 flush 的任务会丢失——这是明确接受的代价。
3. **原子性**：会话元数据与其它快照一律"临时文件 + 改名"，任何时刻磁盘上要么旧、要么新，不会是半截。
4. **崩溃容错**：jsonl 里无法解析的行**跳过并计数**（`JsonlReadResult.skipped`），绝不因为一行坏数据让整个会话打不开。
5. **单调序号**：`appendMessage` 必须把时间戳抬成同一 `(agent, session)` 内**严格递增**——一轮回复的多条消息（思考段 / 中间正文 / 工具卡片 / 最终回复）常落在同一毫秒，而历史接口按时间戳排序、Dart 的 `List.sort` 又不保证稳定，重载顺序会漂移。
6. **压缩不删消息**：`setCompacted` 与 `setCompactedContext` 各自**清空对方**——"列表覆盖 12 条 + 摘要覆盖 6 条"不能同时挂在同一个会话上。
7. **两种形态各司其职**：持久化用 ISO-8601 字符串（人读友好、手改方便），前端形态用毫秒整数（`ChatSession.fromJson` 要求 int）；`JsonTime.decode` 两种都收，文件里怎么写都生效。
8. `messageCount` 只数**文本**消息：工具卡片不算"开始过对话"（前端据此锁定运行模式），口径必须与前端一致。
9. 不保证与**外部同时修改同一目录**的其它进程一致（桌面形态是单用户单实例，多实例各持内存缓存、互不感知）。
10. **`llm_hidden`（`llm_hidden: true` 落在 jsonl 里）是"用户看得见、模型看不见"的唯一开关**：打了标记的消息照常落库、照常下发（前端当普通气泡渲染），引擎重建请求时整条跳过。用它的是**系统发言**（失败 / 停止提示）与**过程提示**（重试进度）。
    为什么不做成新的 `kind`：`system` 会被读成 system prompt（协议里真有 `LlmRole.system`），而"进不进提示词"与"这条消息是正文 / 思考 / 工具卡 / 提示"是**两件正交的事**——`kind` 管渲染与翻译形态，这个布尔标记只管要不要喂模型。

11. **一条断言：临时员工只在它被召来的那个会话里存在，跨会话一律不保留。** 逐条口径：
    - **随会话持久化**：记录落 `data/<agentId>/<sessionId>/subagents.json`（与会话数据同目录、同一份"原子快照 + write-behind"语义）。核心重启后打开**同一会话**它还在、还能复用；换会话（哪怕同一个父 agent 的新会话）名册为空。
    - **跨会话复用 = 可读错误**：复用入口（id 或名称）只在同一会话内有效；拿另一个会话的旧 id 来复用必须报"该临时员工属于另一个会话，不能跨会话复用"，**不许**静默新建、也不许错命中同名条目。
    - **删会话即随之消失**：`deleteSession` 递归删会话目录，名册文件随之消失；内存索引由装饰器同步摘掉——不残留到任何全局位置。
    - **不是全局 agent**：不写 `agents/<id>.yaml`、不进 `agents()` / `teams()` / `members()`、不可被 `message` 寻址、不计 `team_member_count`；`SubagentStore.agents()` 刻意**不**列它。
    - **但既有查询路径认它**：`store.agent(sub_…)` 能查到它（工作空间 / SSH / 系统提示词 / 结果门控因此一处都不用改）。名册是"打开会话时装载"的，`agent(sub_…)` 未命中时会**按需扫一遍各会话名册**兜底（只扫一次并记忆），绝不静默答"不知道"。
    - **消息口径**：`messages(agent, session)` 是"该 agent 自己"的对话，**排掉**临时员工的消息（父 agent 的模型上下文必须保持工具批原子：assistant 的 `tool_calls` 与它的 tool 结果之间不能插进别的消息，带 tools 的思考模式端点会 400）；用户要看的完整消息流走 `sessionMessages`。唯一例外是**后台完成报告**（`kind=subagent_report`）：它带 subagent 标记，却是**发起者**的"新输入"，因此进父上下文、不进临时员工自己的历史。 **自动修复**走 `repairToolResult`：按 `tool_call_id` 把失败信息写回**同一张**工具卡（幂等、不新增消息——`tool_call_id` 重复会让端点严格配对校验过不去）。
    - **会话内是一棵树**：临时员工可以再召临时员工（`parent_id` + `level`，层级上限 `SubagentLimits.maxDepth`）；删一个按**树**收（它召出来的一起走），避免悬空 `parent_id`——与团队自愈要解决的悬空 `parent_agent_id` 是同一类问题。

12. **`usage.jsonl` 是"逐调用用量"的唯一落点，`messages.jsonl` 的行形状不动。** 一行一次 LLM 调用，字段表固定为
    `at` / `source` / `model` / `prompt_tokens` / `cached_tokens` / `completion_tokens` / `estimated` / `duration_ms`
    （`source ∈ turn | compact | llm.call | plugin`；`cached_tokens` 为 `null` = **端点没给这个字段**，不编造 0）。
    为什么另起一份：用量是**遥测**不是对话——混进消息日志会改变既有行形状的兼容面（老前端/老会话/`CoreMessage` 契约）。
    读取与消息日志同一容错口径（坏行跳过并计数；文件不存在 = 空账本，不是错误），写入复用
    `WriteQueue` + `AtomicFile.appendLine`。落账口：**对话跳**在引擎（`LlmAgentEngine(usageLog:)`；逐调用读数由
    `LlmSession.callUsageKey` 夹带、引擎读完即剥掉 ⇒ 帧与 `messages.jsonl` 的 `usage` 逐字不变）、**内置压缩**与
    **`llm.call`** 走各自可注入的 `UsageSink`。

## 测试

```bash
cd packages/tree_core
dart test test/file_store_test.dart test/memory_store_test.dart \
          test/atomic_file_test.dart test/records_test.dart test/tree_paths_test.dart \
          test/yaml_codec_test.dart test/subagent_registry_test.dart \
          test/subagent_isolation_test.dart test/usage_log_test.dart \
          test/messages_jsonl_shape_test.dart
```

（`store_contract.dart` 是共享契约库、没有 `main()`，由上面几个测试文件 `import` 使用，不能单独 `dart test`。）

- `store_contract.dart` 是**共享契约**：两个实现跑同一份断言，业务代码因此不会依赖内存实现特有的行为；临时员工的会话级读写、按树收、`messages()` / `sessionMessages()` 的分工也在这里双向钉住。
- `subagent_registry_test.dart`：名册索引、跨会话隔离、`agents()/teams()/members()` 不列它、`messages(sub_…)` 是它自己那一段、按树收、`forgetSession` 只摘内存索引。
- `subagent_isolation_test.dart`：**真 FileTreeStore + 真磁盘**逐条验证不变量 11 的六条（同会话可见 / 跨会话不可见、跨会话复用可读错误、重启后同会话仍可复用、删会话即消失、不落成全局 agent、存储位置只在该会话范围内）。
