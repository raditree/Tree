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
8. 提问四件事缺一不可：**先落盘再推帧**（进程被杀 / 重启后仍能列出待答）、**作答幂等**（WS 与 REST 可能同时到达，只有第一次生效）、**取消能打断**（等待中的工具立刻拿到 `cancelled`，工具循环因此收敛而不是永远挂着）、**`createdAt` 严格递增**（`add` 把它抬成"全库严格递增"，与消息时间戳同一条规则、共用 `store/tree_store.dart` 的 `monotonicStamp`）：`GET /api/questions` 按 `created_at` 降序，而 Dart 的 `List.sort` **不保证稳定**——同毫秒的两条提问会在两次请求之间换位置（用户看到右栏"最新的排前面"偶发漂移）。**装载旧文件只读不改**：旧数据里的平局不去追改用户数据。第 3 件事还有一层：
    **`cancel` 与"记录是否还在"解耦**——删除 agent 会直接摘掉提问记录（`QuestionStore.removeForAgent`），
    所以 `cancel` 对「记录已不在、但有在途等待」也必须完成 completer（`cancelForAgent` 按 store 的 pending 列表遍历，
    记录摘掉后它就无能为力）；删除路径因此必须**先经 broker 取消、再摘记录**，否则那一轮永远收不到工具结果
    ——`isRunning` 永远为真、连 `stop` 都救不回来。
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
13. **`stop` / 插话要连带它名下的临时员工**：`_RunToken.ownerAgentId` 记归属轮次，`cancelAgent` 与"新消息插话"都会把同一会话里正在跑的临时员工一起收敛（否则父那轮一直卡在等一个没人管的子任务上）；`isRunning` 把"它名下的临时员工"也算在内，因此后台临时员工在跑时它的发起者显示 working、最后一个跑完才报 idle。
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

## 测试

```bash
cd packages/tree_core
dart test test/conversation_segments_test.dart test/conversation_stream_seq_test.dart \
          test/message_interrupt_test.dart test/system_prompt_pin_test.dart \
          test/compaction_test.dart test/compaction_relay_skip_test.dart \
          test/question_broker_test.dart \
          test/question_store_test.dart \
          test/private_workspace_io_test.dart test/workspace_prompt_test.dart \
          test/subagent_tool_test.dart
```

钉子用例：`conversation_segments_test`（分段与落库顺序）、`message_interrupt_test`（会话并行 / 插话 / stop）、
`system_prompt_pin_test`（提示词钉住）、`private_workspace_io_test`（私有目录分栏）。
