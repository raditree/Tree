# llm（LLM 接入与工具循环）

把「存储里的会话历史 + agent 配置」翻成 LLM 请求，跑完工具循环，产出 `AgentEvent`。
**所有与厂商相关的细节**都收在本模块——换端点只改这里的编解码。

## 文件

| 文件 | 作用 |
| --- | --- |
| [llm_types.dart](llm_types.dart) | 与厂商无关的数据类型：`LlmMessage` / `LlmToolSpec` / `LlmRequest` / `LlmUsage` / 流式事件 |
| [openai_codec.dart](openai_codec.dart) | OpenAI 兼容协议的编解码（请求体构造 + 流式分片解码） |
| [sse_parser.dart](sse_parser.dart) | SSE 增量解析（严格按空行事件边界） |
| [llm_transport.dart](llm_transport.dart) | `HttpSseTransport`：`dart:io HttpClient` + 心跳判活 + 取消即断流 |
| [llm_session.dart](llm_session.dart) | 一轮完整会话：增量拼接、usage 累计、上下文裁剪、门控、工具循环 |
| [llm_agent_engine.dart](llm_agent_engine.dart) | `AgentEngine` 实现：模型解析、历史翻译、门控、`token_scale` 学习、传输缓存、中转点钩子 |
| [llm_result_gate.dart](llm_result_gate.dart) | `ToolResultGate`：超长工具结果重定向到 `.self/results/` |
| [llm_summarizer.dart](llm_summarizer.dart) | 压缩用的总结补全（**不带工具**） |
| [llm_json_caller.dart](llm_json_caller.dart) | `llm.call`：一次性、**硬设 JSON 返回形式** |
| [vision_files.dart](vision_files.dart) | 图像附件「上传 → `file_id` 引用」链路 + 跨轮缓存 |

## 不变量（assertions）

1. **厂商细节只出现在 [openai_codec.dart](openai_codec.dart) 与 [vision_files.dart](vision_files.dart)**，上层只用 `LlmTypes`。不引第三方 LLM 包：核心要零第三方依赖，且必须精确控制流式增量（`tool_call` 参数按 index 分片到达、thinking 字段名各家不同、usage 只在最后一帧）——第三方封装往往只给"最终的工具调用对象"，丢掉增量与中间态。
2. **无静态总时长上限**：判死只看**心跳丢失**——流式期间收到任意字节即算一次心跳，连续 I × N 没有字节才判链路失活，并以**显式错误**结束（`LlmFailureEvent.livenessLost`）。唯一保留的短超时是**建连 + 等响应头**，它只服务可诊断性（"端点根本没起"要立刻说得清），不限制推理时长。
3. **工具循环无轮次上限**：终止条件只有取消、出错、模型给出最终文本。要限制"模型与工具互相踢皮球"，由插件监视轮次后经执行站 `agent.stop` 停下——那是编排策略，不该硬编码在会话里。
4. **钩子的 `await` 必须在 SSE 消费循环之外**（红线）：流内 await 会阻塞读取，把传输层的活性看门狗假触发成"心跳丢失"。
5. **门控只改"送模型那一份"**：完整结果落库 + 前端卡片保留全文（桌面端历史同时就是界面历史），送模型的那份换成"提示 + 预览"；没有写入器或写入失败则**按阈值截断**（上下文必须有界，宁可让模型看到半截）。落点文件名**只由 (工具名, 结果原文) 决定**——名字带时间戳 / 序号会让送模型的字节逐轮变化，前缀缓存全丢。
6. **历史翻译**：thinking **不回灌**（不把思考当对话上下文）；连续 tool 消息合并成"一条 assistant 的多个 `tool_calls` + 多条 tool 结果"，保证严格配对（否则端点直接 400）；结果缺失补一句占位；`toolArgumentsRaw` / `toolResultForModel` **逐字复用**——这是端点前缀缓存命中与否的命门。
7. **token 口径唯一**（[../util/tokens.dart](../util/tokens.dart)）：历史里的超大结果按"送模型那一份"估算，不能按全文，否则压缩阈值凭空提前触发（估算里多出几十万字符）。
8. **vision 三条硬约束**：① 只读工作空间 IO（SSH 成员的图在**远端**，绝不拼本机绝对路径）；② 失败一律降级、**绝不阻断本轮**；③ 密钥只进 `Authorization` 头，日志里只有端点与 `file_id`。`file_id` 是**内容块的同级字段**（嵌套形状真端点一律 400）；缓存键必须带**工作空间身份**，否则换主机会命中另一台机器上的旧 `file_id`（用户看到"我发的明明是另一张图，模型答的是老图"）。
9. **总结器不带工具、复用原模型的输出长度**：`max_tokens` 是**思考 + 正文**的总预算，另立一个小值是长会话的必然失败（实测 2048 全花在思考上，`finish_reason=length`、正文一个字都没有）。
10. `llm.call` 在**站点处硬设** `response_format = json_object`，端点不支持就**如实失败**（不静默去掉再试）；它是独立调用，不进任何中转点位、不计入对话用量、不写会话历史。

## 测试

```bash
cd packages/tree_core
dart test test/llm_protocol_test.dart test/llm_session_test.dart test/llm_tool_loop_test.dart \
          test/llm_prefix_stability_test.dart test/llm_transport_liveness_test.dart \
          test/http_sse_transport_test.dart test/llm_result_gate_test.dart \
          test/llm_summarizer_test.dart test/vision_files_test.dart test/reasoning_toolcall_test.dart
```

假传输夹具 `test/fake_transport.dart`、`test/fake_files_api.dart`——LLM 会话因此可以完全脱离网络单测。
`llm_prefix_stability_test` 是"历史逐字复用"这条红线的钉子。
