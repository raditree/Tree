# agent（会话编排）

把 WS 上行请求变成「落库 + 流式下行」，并把系统提示词、上下文压缩、提问回路、私有目录这些**会话级**的事收在这一层。
生成逻辑本身在 [../llm/](../llm/)——本模块只做编排与协议适配。

## 文件

| 文件 | 作用 |
| --- | --- |
| [agent_engine.dart](agent_engine.dart) | 引擎契约：`AgentEngine` + 事件 sealed 类 + `AgentRunContext` / `CoreMessageRef` |
| [conversation_service.dart](conversation_service.dart) | 帧映射、落库、**按 agent×会话**的串行链 / 插话 / `stop`；`deliver` / `wake` 是团队与后台 hook 的投递入口 |
| [compaction_service.dart](compaction_service.dart) | 上下文压缩：内置 compact 与中转站接管两条互斥路径、水位线、token 估算；**「插件为什么没接管」经 `relaySkipSink` 上行**（总线接 `noteRelaySkip`）到 `CompactionResult.relaySkipReason`（REST 可选键 `relay_skip_reason`，**全量**）与 `relaySkipHasSubscriber`（分级位）；压缩过程提示（重试进度）与「压缩已发生 / 降级 / 插件没接管」经 `noticeSink`（自动）与 `notifyCompactionResult`（手动）落成 `llm_hidden` 消息 |
| [workspace_prompt.dart](workspace_prompt.dart) | 系统提示词拼装（全局基础段 + agent 段 + 工作空间软约束 + Spec 索引 + 已选 Spec 全文），全部走 provider |
| [system_prompt_file.dart](system_prompt_file.dart) | `<工作空间>/.self/system_prompt.md` 的播种 / 读取 / 重置（`.bak.<n>` 递增备份） |
| [private_workspace_io.dart](private_workspace_io.dart) | 按 agent 分栏的 IO 装饰器：`.self/…` → `.tree/<agent_id>/.self/…` |
| [question_broker.dart](question_broker.dart) | 提问回路：先落盘再推帧、作答幂等、取消能打断等待 |
| [question_store.dart](question_store.dart) | 提问状态与答案的独立原子快照（跨会话列出、状态可改） |
| [attachment_prompt.dart](attachment_prompt.dart) | 附件路径提示词片段（纯函数，生成与压缩估算共用） |
| [scripted_agent.dart](scripted_agent.dart) | 占位引擎（测试替身；生产路径是 `LlmAgentEngine`） |
| [tool_result_repair.dart](tool_result_repair.dart) | **自动修复**：`ToolResultRepair` 签名 + "结果永远拿不到"的失败文案（纯函数）；引擎在把关处调用，核心接到 `ConversationService.repairToolResult` |
| [subagent_service.dart](subagent_service.dart) | **临时员工**：校验（模型 / 工作空间 / 层级）→ 名册（复用或新建）→ 阻塞或后台运行 → 记账；`SubagentTurnRunner` 由 CLI 后置绑定到 `ConversationService.runSubagent` |

## 不变量（assertions）

1. **引擎不认识 WS 与存储**：只产出 `AgentEvent`；历史以 `CoreMessageRef` 传入，引擎不得反向依赖 `TreeStore`——否则引擎无法脱离存储单测，也容易出现"引擎误改历史"这类耦合。
2. **按段下发**：正文 / 思考段各是一个 `msg_start` + `msg_chunk`… 并**独立落库**，段遇工具调用即关闭。`AgentDone` 时仍开着的正文段**就是最终回复**，usage 只挂最后一条。
3. `AgentError` 必须**同时**发 `error` 帧**和**一条可见的 agent 文本消息：前端对 `error` 帧静默忽略，只发帧的话用户看不到任何反馈。这条消息（以及"已停止本轮生成。"、重试进度、**压缩已发生 / 降级 / 插件没接管**）一律落库带 **`llm_hidden`**——**给人看、不喂模型**：喂进上下文，模型会把"上一条失败"当成新的排查任务接着干（实测）。`kind` 保持 `text`，前端渲染与历史形态都不变；与 `kind == 'notice'`（hook 唤醒，是**新输入**、按 user 进上下文）方向相反。
4. **并发**：同一 `(agent, session)` 串行（同一会话的流式片段交错下发会让前端追加互相污染），**不同会话并行**；跨会话消息既不打断也不排队；`stop` 按 agent（代次作废排队任务）；`idle` 只在该 agent **没有在途轮次**时广播。
5. **提示词按会话钉住**（key = `agentId|sessionId`）：只在会话初始化 / 压缩后 / 显式失效时重建；历史逐字复用 `toolArgumentsRaw` 与 `toolResultForModel`；**工具表每轮现取**（不进前缀，否则端点前缀缓存从这条起全部落空）。
6. **压缩不删除任何消息**：只推进 `compactedMessageCount`；被总结的永远是历史的一个**前缀**；`compactedSummary` 与 `compactedContext` **互斥**（两条压缩路径的权威只能有一个）。
7. **`.self` 只在一处翻译**（`PrivateWorkspaceIO`），且**终端命令不经过它** ⇒ 提示词必须把私有目录的**真实路径**写给模型。
8. 提问四件事缺一不可：**先落盘再推帧**（进程被杀 / 重启后仍能列出待答）、**作答幂等**（WS 与 REST 可能同时到达，只有第一次生效）、**取消能打断，但只有"真取消"能打断**（等待中的工具立刻拿到 `cancelled`，工具循环因此收敛而不是永远挂着；
    **插话不算取消**：`stop` / 删除 agent / 关服 / 显式 `cancel_question` 才是取消路径，见不变量 13）、**`createdAt` 严格递增**（`add` 把它抬成"全库严格递增"，与消息时间戳同一条规则、共用 `store/tree_store.dart` 的 `monotonicStamp`）：`GET /api/questions` 按 `created_at` 降序，而 Dart 的 `List.sort` **不保证稳定**——同毫秒的两条提问会在两次请求之间换位置（用户看到右栏"最新的排前面"偶发漂移）。**装载旧文件只读不改**：旧数据里的平局不去追改用户数据。第 3 件事还有一层：
    **`cancel` 与"记录是否还在"解耦**——删除 agent 会直接摘掉提问记录（`QuestionStore.removeForAgent`），
    所以 `cancel` 对「记录已不在、但有在途等待」也必须完成 completer（`cancelForAgent` 按 store 的 pending 列表遍历，
    记录摘掉后它就无能为力）；删除路径因此必须**先经 broker 取消、再摘记录**，否则那一轮永远收不到工具结果
    ——`isRunning` 永远为真、连 `stop` 都救不回来。
8.1 **多问题（一次调用问 N 道题）不改变上面这四件事，只把"一个问题"换成"一组问题"**（用户要求 2026-10-04：
    「ask_user_question 工具仅支持单个问题（改为支持多问题）」）：一次 `ask` 仍是**一条记录 / 一个 qid /
    一张卡片 / 一个在途 Completer**（`QuestionRecord.questions` ≥ 1，单问是它的退化形态），
    只是作答改收**逐题答案** `List<String>`（缺项按未作答落库，[question_channel.dart](../tool/question_channel.dart)
    的 `normalizeAnswers` / `formatAnswerLines` 是唯一排版实现）。三条必须守住的口径：
    - **先落盘再推帧**照旧：记录与卡片消息都带完整 `questions`，帧里同时给 `questions`（新前端）与
      `question`/`options`（= **第一问**，老前端只认这两个键）；
    - **作答兼容单值**：WS/REST 同时接受 `answers`（数组）与 `answer`（单值 = 第一问），
      老前端因此不会"点了没反应"，其余题按「未作答」如实回给模型；
    - **未作答必须如实**：工具结果/补答消息里的未答项写 `（未作答）`，**不许**静默丢答案或假装全答了
      （模型据此决定追问还是按假设继续）。
9. 提示词在**两处**被拼装（会话生成 + 压缩估算），两处必须看到**逐字一致**的字符串 ⇒ 一律用 provider 接线，不做参数副本。
10. **临时员工（subagent）轮的运行标识永远是它自己的**：运行键 = `(subagentId, sessionId)`，与"正阻塞等它的父 agent"那一轮（`(parentId, sessionId)`）**绝不撞键**——撞了就是死锁；同时 N 个后台临时员工各占各的槽位，**真的并行**，不互相顶掉轮次。它跑的是 `_runTurn`（与普通轮**同一条**实现），"消息归集到谁 / 带什么标记 / 带哪段历史"由参数表达。
11. **临时员工的消息不进父 agent 的模型上下文**（`store.messages` 按标记排掉）：父那一轮的 `assistant(tool_calls=[subagent])` 与它的 tool 结果必须相邻，中间插进子 agent 的话会把批切开 ⇒ 带 tools 的思考模式端点 400。唯一例外是**后台完成报告**（`kind=subagent_report`）：它是发起者的"新输入"（`wake` 注入），带 subagent 标记但**要**进父上下文；同理它**不进**临时员工自己的历史。用户要看的完整消息流走 `store.sessionMessages`（会话历史接口用它）。
12. **用户可以直接跟临时员工说话、也可以单独停它**（用户 2026-10-04：「允许用户停止 subagent 的工作、
    向其发消息」）：界面复用同一条 `user_message` 帧（收件人是 `sub_…`）→ `sendToSubagent`：
    消息按 **`role='user'` + 它的标记**落库（它自己的历史按标记取；发起者的模型上下文照旧看不到它，
    见不变量 11），它正在跑就**先打断**（与主 agent 插话同一口径），跑完把报告注入**发起者会话**；
    跨会话 / 未知 id 一律可读错误、不静默落库。**"被人为中止"与"出错"必须分得开**：
    `SubagentTurnResult.cancelled`/`error` 一路带出来，**人为中止（用户停止 / 插话）不注入结束提示**
    （用户自己会说原因，而且他往往马上又发一条让它接着干），**出错导致的中止照旧注入**（否则发起者以为活还在干）；
    临时员工这一轮结束时**总是**报自己的 `idle`（带 `subagent_id`），否则父还在跑时它的"工作中"会一直亮着。
13. **插话只打断目标那一轮；`stop` 才连带**（用户 2026-10-03 硬断言：「发消息给主 agent，其子 agent 不受影响（和『发消息给子 agent，父 agent 及其他子 agent 不受影响』一致）」）：
    `_interruptForNewMessage` **只**标记目标 `(agentId, sessionId)` 那一轮（`interrupted` + `cancelled`；用户插话另标 `userStopped`）——
    同一会话里它名下的临时员工**继续跑**、完成报告照旧注入发起者；父那轮若正卡在 `subagent` / `wait_for` 上，按"正在执行的工具跑完才收敛"把新消息排队等它返回。
    终止在途临时员工只有两条**显式**路径：**用户 `stop`**（按 agent，仍连带它名下的临时员工，[test/cascade_stop_test.dart](../../../test/cascade_stop_test.dart)）与**在某个临时成员视角里按停止**（`sub_…` ⇒ `_stopAgentTree(cascade:false)`，只停它自己，[test/subagent_tool_test.dart](../../../test/subagent_tool_test.dart)）。
    `_RunToken.ownerAgentId` 记归属轮次；`isRunning` 仍把"它名下的临时员工"算在内（后台临时员工在跑时发起者显示 working、最后一个跑完才报 idle——团队名单口径不变）。
    **插话不碰在途工具，也不作废在途提问**（用户 2026-10-04 断言：「任何工具调用执行期间不被插话打断，
    插入消息（包括 terminal/subagent hook 完成消息）在工具调用期间必须排队等待」）：
    `_RunToken` 分**两个**标记——`cancelled` / `interrupted` 是**软**收敛（插话与 `stop` 都置：
    流式立刻停、工具之间收敛），`hardCancelled` 是**硬**取消（只有 `stop` / 删除 agent / 关服置）。
    工具执行体只认硬取消：`AgentRunContext.isHardCancelled` → `LlmTurnSession.run(isHardCancelled:)`
    → `ToolRunner.run` 与 `AskQuestionRequest.isCancelled`（broker 的取消轮询用它）。
    旧实现把软信号也给了工具层 ⇒ `ask_user_question` 正等作答时，一条 hook 完成提示就能把题卡掐掉
    （[known-issues.md #26](../../../../../docs/known-issues.md)）；**代价如实说**：待答问题期间插进来的消息
    **排队等到那道题被作答或显式取消**（题卡一直可答，另见不变量 8）。
14. **「为什么没接管」分两档，别合并**：`relay_skip_reason`（REST）永远是**全量**（排障面，含"总开关关 / 作用域不匹配 / 无点位 / 无订阅者"这类**早退**）；会话历史里的通知**只写"有订阅者却没交出可用结果"**那一档（`relaySkipHasSubscriber`，没回包 / 原数据放行 / 回包非法 / 越界 / 异常）。合并的后果是：没装压缩插件的用户，每条压缩通知都多一句"没有插件订阅该点位"的废话，看两次就学会忽略整条通知了。手动压缩（REST `/compact`、执行站 `agent.compact`）与自动压缩共用 `_notifyCompacted` 这一条文案口径，别在别处复制第二套。

## 依赖方向

## 依赖方向

`agent` → `llm` / `tool` / `store` / `plugin`（事件发布）。
`tool` **不**反向依赖 `agent`：提问用具名契约隔开（见 [../tool/question_channel.dart](../tool/question_channel.dart)）。

15. **结果永远拿不到的工具卡：引擎在把关处自动修复**（用户 2026-10-03 口径：「在引擎的把关处，失败时自动修复」；
    [test/llm_agent_engine_test.dart](../../../test/llm_agent_engine_test.dart) 与 [test/store_contract.dart](../../../test/store_contract.dart) 强制）：
    历史里 `kind=tool` 且 `tool_result` 为空的卡 = 那次调用被**停止 / 异常 / 核心重启**收尾，结果**永远拿不到**
    （正在跑的调用根本不在历史里，不会误伤）⇒ 引擎组装工具批时把失败信息**写回同一张卡**（幂等、不新增消息：
    `tool_call_id` 不能重复），本次请求也用它。写回走注入的 [ToolResultRepair](tool_result_repair.dart)
    （引擎仍然不认识存储层，与 `toolTurnCompactor` 同范式），核心接到 `ConversationService.repairToolResult`：
    存储层写回 + 补一条 `tool_end` 帧（界面把那张一直"运行中"的卡填成失败）。
    **未接线 = 老行为**（只在送模型那份补一句占位，落库那份不动）、写回失败也不打断请求。

16. **运行态帧分「它自己」与「它名下的临时员工」；`stop` 传 `sub_…` 只停它自己**
    （用户 2026-10-03：「临时成员的运行情况不应影响主 agent 运行情况」+「仅停止对应临时成员，
    保证对其他成员无影响」；[test/subagent_tool_test.dart](../../../test/subagent_tool_test.dart) 强制）：
    `agent_status.data` 里，**主 agent 自己**的帧带 `own_running`（working ⇒ `true`，idle ⇒ `false`），
    并且「它自己收尾了、但名下还有临时员工在跑」时**照样发一条** `own_running: false, subagent_running: true`
    ——以前这种时刻什么都不发，主视角的停止键就一直亮着；**子级帧**照旧带 `subagent_id` 等标记、
    **不带** `own_running`（不许冒充主 agent）。`isRunning(agentId)` 的**聚合**口径一个字没改
    （含它名下的临时员工，团队名单据此显示 working）。`stop` 传 `sub_…` ⇒ `_stopAgentTree(cascade: false)`：
    只取消它自己的在途轮次与排队，父 / 兄弟 / 其他成员 / 团队都不受影响（停止回执与补推的 `idle`
    都带它自己的帧标记，前端只收它那一份「工作中」）。

17. **临时员工起的 `terminal hook` 完成之后：提示归到会话主人、唤醒它自己**（用户 2026-10-03 现场：
    子 agent 的 hook 干完没人收尾；[test/subagent_hook_wake_test.dart](../../../test/subagent_hook_wake_test.dart) 强制）：
    `WorkspaceToolRunner._finished` 必须把 `subagentService.tagOf(task.agentId)` 的标记**透传**给
    `onHookFinished`；`ConversationService.wake` 用 `subagents?.handle(agentId)?.ownerAgentId` 解析出
    **会话主人**再去取会话（临时员工没有自己的会话——`SubagentStore.session` 是纯转发；旧实现拿 `sub_…`
    取到 `null` 就 `return`：提示不落库、子永远不被唤醒、父在 `wait_for` / 阻塞 `subagent` 上白等）。
    完成提示按 `kind='notice'`+ 它的标记落在**会话主人的会话流**（不能用 `subagent_report`：那个会被它
    自己的历史排掉 ⇒ 它读不到"任务干完了"）；那一轮仍以**它自己**的身份跑（运行键 `(sub_…, session)`）、
    带**它自己的历史**（`freshContext: true`，不并父会话的压缩水位）。**hook 日志与超长结果重定向仍落在
    会话主人那一份**（刻意口径：工作空间里不会留下 `sub_*` 目录，[test/subagent_tool_test.dart](../../../test/subagent_tool_test.dart) 钉着）。

## 测试

```bash
cd packages/tree_core
dart test test/conversation_segments_test.dart test/conversation_stream_seq_test.dart \
          test/message_interrupt_test.dart test/system_prompt_pin_test.dart \
          test/compaction_test.dart test/compaction_relay_skip_test.dart \
          test/question_broker_test.dart \
          test/question_store_test.dart \
          test/private_workspace_io_test.dart test/workspace_prompt_test.dart \
          test/subagent_tool_test.dart test/subagent_hook_wake_test.dart
```

钉子用例：`conversation_segments_test`（分段与落库顺序）、`message_interrupt_test`（会话并行 / 插话 / stop）、
`llm_question_test`（提问回路端到端：作答回灌、多问题、**插话 / hook 完成提示不打断在途提问**、`stop` 取消）、
`subagent_hook_wake_test`（临时员工 hook 完成后：提示归会话主人 + 只唤醒它自己 + 用它自己的历史）、
`system_prompt_pin_test`（提示词钉住）、`private_workspace_io_test`（私有目录分栏）。
