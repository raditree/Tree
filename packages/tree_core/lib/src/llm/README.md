# llm（LLM 接入与工具循环）

把「存储里的会话历史 + agent 配置」翻成 LLM 请求，跑完工具循环，产出 `AgentEvent`。
**所有与厂商相关的细节**都收在本模块——换端点只改这里的编解码。

## 文件

| 文件 | 作用 |
| --- | --- |
| [llm_types.dart](llm_types.dart) | 与厂商无关的数据类型：`LlmMessage` / `LlmToolSpec` / `LlmRequest` / `LlmUsage` / 流式事件 |
| [openai_codec.dart](openai_codec.dart) | OpenAI 兼容协议的编解码（请求体构造 + 流式分片解码） |
| [sse_parser.dart](sse_parser.dart) | SSE 增量解析（严格按空行事件边界） |
| [llm_transport.dart](llm_transport.dart) | `HttpSseTransport`：`dart:io HttpClient` + 心跳判活 + 取消即断流 + **有限重试（5 次退避，零增量才重试）** |
| [llm_session.dart](llm_session.dart) | 一轮完整会话：增量拼接、usage 累计、上下文裁剪、门控、工具循环 |
| [llm_agent_engine.dart](llm_agent_engine.dart) | `AgentEngine` 实现：模型解析、历史翻译、门控、`token_scale` 学习、传输缓存、中转点钩子 |
| [llm_result_gate.dart](llm_result_gate.dart) | `ToolResultGate`：超长工具结果重定向到 `.self/results/` |
| [llm_summarizer.dart](llm_summarizer.dart) | 压缩用的总结补全（**不带工具**） |
| [llm_json_caller.dart](llm_json_caller.dart) | `llm.call`：一次性、**硬设 JSON 返回形式** |
| [vision_files.dart](vision_files.dart) | 图像附件「上传 → `file_id` 引用」链路 + 跨轮缓存；**端点不支持 / 上传失败时回退内联 base64**（`VisionImageRef`） |

## 不变量（assertions）

1. **厂商细节只出现在 [openai_codec.dart](openai_codec.dart) 与 [vision_files.dart](vision_files.dart)**，上层只用 `LlmTypes`。不引第三方 LLM 包：核心要零第三方依赖，且必须精确控制流式增量（`tool_call` 参数按 index 分片到达、thinking 字段名各家不同、usage 只在最后一帧）——第三方封装往往只给"最终的工具调用对象"，丢掉增量与中间态。
2. **无静态总时长上限**：判死只看**心跳丢失**——流式期间收到任意字节即算一次心跳，连续 I × N 没有字节才判链路失活，并以**显式错误**结束（`LlmFailureEvent.livenessLost`）。唯一保留的短超时是**建连 + 等响应头**，它只服务可诊断性（"端点根本没起"要立刻说得清），不限制推理时长。
   **全仓同一条口径（用户 2026-10-03 定稿）：没有任何硬超时；限制只有两类——①心跳丢失 ②软超时；软超时之后只允许显式关闭。**
   落地：工具侧 `exec(timeout:)` 到点**不杀进程**、转后台 / 交还句柄（见 [../tool/README.md](../tool/README.md)）；
   `llm.call` 的 `timeout` 到点**只留痕 + 登记成"可关闭的运行"**（不再中止，见不变量 10）；
   会话请求悬挂（**零事件**）时登记进**同一张表**（`LlmSession._watchRequest`）。
   **显式关闭只有一个实现**——用户右栏「正在执行的 tool」/ 插件执行站 `tool.close` /
   agent 内置工具 `tool_runs action=close` / REST，四者等价；关闭即让在途调用**收敛**并释放连接。
   **边界情形（不是"运行"的硬超时，别与上面混为一谈）**：建连 + 等响应头（`connectTimeout`）、
   vision 上传 / 取响应、`file_service` 的 `archiveTimeout` / `gitTimeout`（用户 REST 操作）、
   启动预热预算、进程关停宽限、单实例握手、插件启动探测；传输层的 **5 次重试上限**是**策略**
   （失败时**显式报错**、可取消），不是超时。
3. **工具循环无轮次上限**：终止条件只有取消、出错、模型给出最终文本。要限制"模型与工具互相踢皮球"，由插件监视轮次后经执行站 `agent.stop` 停下——那是编排策略，不该硬编码在会话里。
4. **钩子的 `await` 必须在 SSE 消费循环之外**（红线）：流内 await 会阻塞读取，把传输层的活性看门狗假触发成"心跳丢失"。
5. **门控只改"送模型那一份"**：完整结果落库 + 前端卡片保留全文（桌面端历史同时就是界面历史），送模型的那份换成"提示 + 预览"；没有写入器或写入失败则**按阈值截断**（上下文必须有界，宁可让模型看到半截）。落点文件名**只由 (工具名, 结果原文) 决定**——名字带时间戳 / 序号会让送模型的字节逐轮变化，前缀缓存全丢。
6. **历史翻译**：thinking **不回灌**（不把思考当对话上下文）；连续 tool 消息合并成"一条 assistant 的多个 `tool_calls` + 多条 tool 结果"，保证严格配对（否则端点直接 400）；结果缺失在**引擎的把关处自动修复**（写回失败信息，见 [../agent/tool_result_repair.dart](../agent/tool_result_repair.dart)；未接线时退回老占位 `(该工具调用未完成，没有结果)`）；`toolArgumentsRaw` / `toolResultForModel` **逐字复用**——这是端点前缀缓存命中与否的命门。**这条批是原子的**：一条 assistant 的 `tool_calls` 与它的**全部** tool 结果必须相邻，落在这批**中途**的 hook 提示 / 用户插话一律**推迟到该批的结果之后**（工具结果是**逐条**落库的；跑在远端 SSH 上的慢工具尤其容易让注入卡在两条结果之间）。就地发会把批量切成"前半批带 reasoning、后半批没有"，请求立刻变成"以 tool 结果收尾、前面那条 `tool_calls` 没有 reasoning"⇒ 端点 400 `The reasoning_content in the thinking mode must be passed back to the API.`（真机现场见 `.self/plan/20261001-thinking-400-and-interrupt/recon-addendum.md`）。**判据是"这一轮还在飞"**，所以推迟的时机不止"批已有结果"：**这一跳的思考已经落库、它的工具卡还没回来**时（插话落在**工具执行期间**，远端 SSH 上的慢工具把窗口拉得很宽）同样要推迟——就地 `flushRound()` 在"还没东西可发"时会**什么也不发**却清空待回传的思考，那段 CoT 就此丢失，紧接着的工具卡批会以"没有 reasoning"的形态收尾 ⇒ 同样 400（`test/reasoning_toolcall_test.dart` 的『插话落在工具执行期间』钉住这条）。
7. **token 口径唯一**（[../util/tokens.dart](../util/tokens.dart)）：历史里的超大结果按"送模型那一份"估算，不能按全文，否则压缩阈值凭空提前触发（估算里多出几十万字符）。
8. **vision 三条硬约束**：① 只读工作空间 IO（SSH 成员的图在**远端**，绝不拼本机绝对路径）；② 失败一律降级、**绝不阻断本轮**；③ 密钥只进 `Authorization` 头，日志里只有端点与 `file_id`。`file_id` 是**内容块的同级字段**（嵌套形状真端点一律 400）；缓存键必须带**工作空间身份**，否则换主机会命中另一台机器上的旧 `file_id`（用户看到"我发的明明是另一张图，模型答的是老图"）。
   **两条送达路径（`VisionImageRef`）**：先 Files API（`file_id` 引用，可跨轮复用）——**上传表单带 `model`**（值取该 agent 解析出的 `CoreModelConfig.modelId`，不硬编码），但**别把它当那次 400 的解药**：2026-10-05 真机探针（`tool/probe_vision_upload.dart`）实测 `token.ai-galaxy.com/v1` 对**不带 / 表单带 / 查询串带**三种**一律 400**，而官方 `api.deepseek.com` 不带与带都成功（未知字段被忽略 ⇒ 零回归）⇒ 该中转站**就是不支持 Files API**，真正让图送达模型的是**内联回退**；端点不支持 Files API / 上传失败（非 2xx、网络错、响应无 `id`、缺 `base_url`·`api_key`）时**回退内联 base64**：`{"type":"image_url","image_url":{"url":"data:<mime>;base64,…"}}`（形状依据见 `llm_types.dart` 的 `LlmContentPart.imageUrl`；**不是** `{"type":"file","file_data":…}`——那个取值形态无文档依据）。内联受官方口径 **单张 ≤ 32 MiB**（`visionMaxInlineBytes`）限制，超限或连字节都读不到才退回"提示词里给路径"。
9. **总结器不带工具、复用原模型的输出长度**：`max_tokens` 是**思考 + 正文**的总预算，另立一个小值是长会话的必然失败（实测 2048 全花在思考上，`finish_reason=length`、正文一个字都没有）。
10. `llm.call` **缺省**在**站点处硬设** `response_format = json_object`，端点不支持就**如实失败**（不静默去掉再试）；**可显式传 `response_format: "text"`**（2026-10-04 新增，也接受 `{"type":"text"}`）——那条分支**不发**该字段，为的是让这次调用与对话那一轮**同形态**、从而吃得上前缀缓存。真机实测（`api.deepseek.com` 与 `token.ai-galaxy.com/v1` 两端点一致）：同一 492 token 前缀 plain 重发命中 **384/256**，**只加 `json_object` 就掉到 0**（端点为 JSON 模式改写了提示词：同一批 messages 恒定 **+22 token**，且改写落在 messages 区域之前/其中）；`tools` **没有被丢弃**（+270 token 两种模式下都在）、`max_tokens` 与显式 `{"type":"text"}` 都不影响命中。**要复用对话前缀的调用（压缩插件的总结调用）必须走 text**，见 [../../../../../docs/known-issues.md](../../../../../docs/known-issues.md) #27。它是独立调用，不进任何中转点位、不计入对话用量、不写会话历史。它的 `timeout`（默认 120s）是**软的**：到点**不中止**，只留痕 + 把这次调用登记成"可关闭的运行"（`LlmRequestRegistrar`，见不变量 2 的显式关闭四入口），回包照旧送达（**结果不丢**）；`Duration.zero` = 永不软超时。
11. **有限重试只在传输层，且只在"零增量"时发生**（[llm_transport.dart](llm_transport.dart)）：默认最多 **5 次**重试、退避 `5/10/20/40/80s`（累计 155s，覆盖"端点几分钟后恢复、任务自动接续"），**只在这一次尝试一个事件都还没交给上层时**重试——上层（会话 / 总结器 / `llm.call`）因此完全看不见重试，不存在重复输出与重复计费。**已经吐出增量的失败（半路断流）不重试**：重放会与已渲染的正文并列，那种情况如实报错。可重试 = 无 HTTP 响应（建连失败 / 等响应头超时 / 心跳丢失 / 读取中断，含 `Connection closed while receiving data`）、408、429、5xx；**不可重试** = 4xx（密钥 / 模型 / 参数错——重试只是白花 5 次配额）、流中 error 帧（`LlmFailureEvent.retryable = false`）、取消、传输层已关闭。退避等待**可取消**（250ms 一片地看取消位），用户按 stop 立刻结束而不是等满退避。**每次重试前先产出一个 `LlmRetryNotice`**（会话翻成 `AgentNotice` → 落一条 `llm_hidden` 的消息："第 2/5 次重试，10s 后"），否则用户面对的是最长两分多钟的空白。**总结器（[llm_summarizer.dart](llm_summarizer.dart)）走同一条传输层 ⇒ 同一套重试**；它没有会话/事件流可渲染，所以进度经 `ContextSummarizer.summarize(onNotice:)` 交回 `CompactionService.noticeSink`，由会话层落成一条 `llm_hidden` 的提示（用户看得见"压缩在重试"，模型看不到）。会话层另有唯一的"重试"：端点报上下文超限 → 强制压缩一次 → 重试**同一轮**（`overflowRetried`，整轮仅一次，防死循环）。
12. **`llm_hidden` = "用户看得见、模型看不见"的唯一开关**：打了这个标记的消息**照常落库、照常下发**（前端当普通气泡渲染），但引擎重建请求时**整条跳过**——模型读到那句"读取模型响应失败：…"只会把它当成**新的排查任务**（用户实测反馈）。使用者：**系统发言**（失败提示、"已停止本轮生成。"）与**过程提示**（重试进度，见不变量 11）。压缩侧的 token 估算、摘要输入与降级摘要同样跳过它（口径必须与实发那一份一致）。与 `kind == 'notice'`（hook 唤醒）方向相反：那个是**新一轮输入**、按 user 发出去，不可一刀切。
    **为什么是字段而不是新 `kind`**：`system` 会被读成 system prompt（协议里真有 `LlmRole.system`），而这里要表达的维度是"**进不进提示词**"——一个布尔标记，与"这条消息是正文 / 思考 / 工具卡 / 提示"是两件正交的事。标记是通用的：任何消息都能打。

13. **思考模型的每条 assistant 都带 `reasoning_content` 键**（`LlmMessage.thinkingTurn`）：真端点实测（`deepseek-flash` @ `api.deepseek.com`，请求带 `tools`）——末尾 assistant（或末尾 tool 结果所属的那条 assistant）带 `reasoning_content: ""` 是 **200**，**整个键不给**才是 **400** `The reasoning_content in the thinking mode must be passed back to the API.`（对照实验：H1 空串 = 200 / H2 空串 + tool 结果 = 200 / H3 缺键 = 400 / H4 有正文 = 200）。端点只查**键在不在**，所以"这一跳没有思考可回传"必须表达成**空串**而不是省略键：模型某一跳没产出思考是真会发生的（真机现场 2026-10-03 10:10:41 契门会话——收尾正文那一跳没有思考卡，而队友的插话正好落在它前面，重建出来的请求以这条 assistant 收尾 ⇒ 整个会话卡在 400）。**打标与位置无关**（每条 assistant 都打，不管它在末尾还是中间），前缀缓存才不会因为"同一条消息这次在末尾、下次在中间"而变字节；**历史翻译**（引擎按 `config.thinking` 打标）与**工具循环在途那一跳**（`LlmSession.thinkingTurn`）两处同口径。非思考模型（`thinking: false`）**一个键都不发**：OpenAI 系端点会拒绝不认识的字段（报文与改动前逐字一致）。

14. **`llm.call` 失败要"可诊断 + 可自愈"**（解析失败 ≠ 那笔钱白花）：解析不出 JSON 时，回包除 `error` 外还带 `error_kind='json_parse'`、`text`（模型正文**原文**）、`text_length`、`truncated_suspect`（末尾不是 `}`·`]`，或括号·引号不配平）；文案**按实际响应形式分支**（`text` 形态下**没发** `response_format`，不能说"站点处硬设了 `json_object"）；并在 `[core:llm-call]` 落一条明细（agent / 模型 / 响应形式 / 正文长度 / 是否疑似截断 / 首 200 + 末 100 字 + **解析错误的原话，含 offset**——首尾预览看不出"坏在哪个字符"时这是最短的线索）——这条分支以前**一条日志都没有**，事故现场只剩"插件回 null"，事后无从诊断。`ExecuteStationMounts` 用 `StationCommandOutcome.failedWith(error, payload)` 把这份 detail **原样回给插件**（只回一句 `error` = 把已付费的调用彻底丢掉；现场是 734k prompt 的总结被整包弃用）。**这份 payload 还必须穿过执行站走到插件**：`StationInstance.execute()` 的 `ok:false` 分支也要带 `outcome.payload`——2026-10-05 18:29 真机复现就是因为漏了那一跳，插件报"原文 0 字"、自愈两段都无从下手（[../../../../../docs/known-issues.md](../../../../../docs/known-issues.md) #31）。真实现场与修法见 [../../../../../docs/known-issues.md](../../../../../docs/known-issues.md) #31。

## 测试

```bash
cd packages/tree_core
dart test test/llm_protocol_test.dart test/llm_session_test.dart test/llm_tool_loop_test.dart \
          test/llm_prefix_stability_test.dart test/llm_transport_liveness_test.dart \
          test/http_sse_transport_test.dart test/llm_hidden_test.dart \
          test/llm_result_gate_test.dart \
          test/llm_summarizer_test.dart test/vision_files_test.dart test/reasoning_toolcall_test.dart \
          test/reasoning_key_test.dart test/notice_translation_test.dart
```

假传输夹具 `test/fake_transport.dart`、`test/fake_files_api.dart`——LLM 会话因此可以完全脱离网络单测。
`llm_prefix_stability_test` 是"历史逐字复用"这条红线的钉子；`http_sse_transport_test` 的『有限重试』组（真实 HttpServer + 裸 socket 半路掐断）钉住重试的判据与次数，
`llm_hidden_test` 钉住"打了 `llm_hidden` 的消息不进请求、但仍落库可见"。
