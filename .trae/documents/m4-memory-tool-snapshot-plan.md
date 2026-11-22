# M4 实施计划：记忆工具 + 快照段（AGENT-MEM）

## Context

方案真源 `docs/pluginization/agent-memory-upgrade-plan.md` §6/§7/§10：M4 要把 `memory` 工具、记忆段注入、快照查看器收口，出口判据是「两处拼装同字节；快照重建前后钉住」。

当前工作区（plugins 仓）已存在 M4 半成品：`memory_tool.dart`、`memory_section.dart`、`agent_runtime._runMemoryTool`、`station_tool_runner.memoryRunner`、快照查看器。但仍有 5 个缺口：

1. `buildMemorySection` 从未被注入系统提示词，`workspace_prompt` 没有 `memorySectionProvider`。
2. `MemoryPipelineDeps` 生产无人构造，消息落库后没有 `tick`。
3. 快照查看器用硬编码 `tokenScale: 2.0` 重算，与真实注入口径不一致；`sections` 缺 `source`。
4. `recall` 缺 `level?/tags?`，`forget` 缺 `reason`；工具分组缺「记忆」；提示词种子缺工具路由行。
5. 缺 M4 出口测试（同字节 / 钉住）。

本期只做 M4；M5 的 agent 配置页 UI 不在本计划内。

## 实施步骤

### 1. 记忆段 provider（`lib/src/agent/workspace_prompt.dart`）

- 在 `selectedSpecsProvider` 旁新增：
  `String Function(CoreAgent agent, String sessionId)? memorySectionProvider;`
- `systemPromptWithWorkspace` 末尾追加记忆段：`tail = '$suffix$index$hook$memory'`，`memory` 为空串时不注入（保持现有字节不变）。
- 顺序与 `memory_section.dart#kPromptSectionTitles` 一致（记忆段最后）。

### 2. 段解析补 source（`lib/src/memory/memory_section.dart`）

- 新增「章节标题 → 来源」常量映射（agent 提示词源 / 工作空间 / Spec 索引 / 已选 Spec 全文 / 记忆）。
- `splitPromptSections` 每项补 `source` 字段（只用于展示，不参与拼装）。
- 新增 `memorySectionOfPrompt(String prompt)`：从钉住提示词里提取记忆段正文，供 dirty 比对（避免 `contains` 误报）。
- 记忆段标题保持现有 `## 记忆（本次快照，按 score 排序）`。

### 3. 运行时缓存 + 预热接线（`lib/src/runtime/agent_runtime.dart`）

- 新增进程内缓存 `_memorySections`（key = agentId）与 `Set<String> _memoryCacheOwners`；`AgentRuntime.debugCloseAll()` / `close()` 时清理（测试隔离）。
- 新增 `Future<String> refreshMemorySection(String agentId)`：
  - `MemoryDbRegistry.openAt(paths.root, agentId)`；
  - `config = readConfig()`、`records = readAll()`；
  - `tokenScale = settings.model(agent.modelId)?.tokenScale ?? tokens.defaultTokenScale`；
  - `buildMemorySection(...)` 写入缓存并返回。
- 构造器末尾接线（仅两行）：
  - `conversation.promptStatePrewarm = (agentId, sessionId) async { await refreshMemorySection(agentId); };`
  - `memorySectionProvider = (agent, session) => _memorySections[agent.id] ?? '';`
- 不在 provider 内做 IO；缓存为空时返回空串（本轮不注入），由预热补齐。
- `compaction_service` 两处 `systemPromptWithWorkspace` 自动同口径，无需改。

### 4. 管道生产触发（`conversation_service.dart` + `agent_runtime.dart`）

- `ConversationService` 新增 `void Function(String agentId, String sessionId)? memoryTickRequest;`
- 三个触发点（均 fire-and-forget，不 await）：
  - `acceptMessage` 的 `_appendInbound` 之后；
  - `deliver` 的 `_appendInbound` 之后；
  - `_runReply` 收尾 `_running.remove(runKey)` 之后，且 `subagent == null`（临时员工消息由父会话下一跳覆盖）。
- runtime 构造器接线：按 agentId 懒建 `MemoryPipeline`（`MemoryPipelineDeps(llmCaller, settings.domain, paths.root).build(agentId, agentModelId: ...)`），调用 `unawaited(pipeline.tick(...).catchError(log))`；失败只写日志，不影响回答。
- 允许注入 `memoryPipelineFactory` 供测试打桩。

### 5. 工具口径补齐

- `lib/src/memory/memory_tool.dart`：
  - `recall` 增加 `tags`（string[]）参数；`level` 描述扩展为「in 的层级 / recall 的过滤」。
  - `_recall` 按 `level` 与 tag 交集过滤池子；`include_archive` 语义不变。
  - `forget` 增加 `reason`（string）；缺失时返回可读错误，存在时 `db.archive(id, reason: reason)`。
- `lib/src/tool/tool_policy.dart`：新增 `kToolGroupMemory = 'memory'`、标签「记忆」、`toolGroupOf` 加 `case 'memory'`。
- `lib/src/settings/prompt_store.dart`「需求 → 工具路由」加一行：`- **记忆**：memory（in 写入 / recall 检索 / forget 归档；写入前先 recall 去重，L0 仅用户明示）`。

### 6. 快照查看器一致化（`lib/src/memory/memory_delegate.dart`）

- `_promptSnapshot` 复用同一个 runtime：用该 agent 的 `modelId` 取 `tokenScale`，调用 `runtime.refreshMemorySection(agentId)` 得到与注入完全同口径的当前段，替换硬编码 `2.0`。
- `sections` 直接带 `source`（步骤 2）。
- dirty 判据：`pinned` 非空时，比较 `memorySectionOfPrompt(pinned)` 与当前段（去尾空白）：
  - 当前非空且不同 → dirty；
  - 当前为空但 `pinned` 含记忆段 → dirty；
  - 相同 → 不报。
- `next_rebuild_hint` 文案保持。

### 7. 测试

- 新建 `test/memory_section_test.dart`：空记忆返回空串；L0 预算裁剪；L1/L2 TOP N；`splitPromptSections` 的 `source`；`memorySectionOfPrompt`。
- 新建 `test/memory_prompt_pin_test.dart`（用 `AgentRuntime` + `ScriptedAgent` + 临时数据根）：
  - 写一条记忆 → 首轮后 `conversation.pinnedSystemPrompt` 与直接 `systemPromptWithWorkspace(agent, sessionId: ...)` 逐字相等；
  - 首轮后再写一条 → 第二轮钉住字节不变；
  - `invalidateSystemPrompt` 后重建 → 新钉住包含新记忆段。
- 扩展 `test/memory_tool_test.dart`：recall 按 level/tags 过滤；forget 缺 reason 报错、带 reason 归档。
- 扩展 `test/memory_delegate_test.dart`：`sections` 含 `source`；当前记忆为空但钉住有记忆段判 dirty。
- 扩展 `test/tool_policy_test.dart`：`memory` 归「记忆」组。
- 扩展 `test/workspace_prompt_test.dart`：provider 为空时字节不变；非空时追加在最后且两次调用同字节。
- 扩展 `test/agent_runtime_test.dart`：钩子触发 pipeline（打桩 factory）、单飞（第二次 tick 返回已在运行）、异常不影响消息链路。

### 8. 文档收尾（与代码同批提交）

- `plugins/tree.agent/lib/src/memory/README.md`：M4 状态、注入与触发口径。
- `docs/project-status.md` 车道 N：M4 已完成、M5 剩余。
- `docs/work-log.md` 补 M1~M4 行。
- `docs/pluginization/agent-memory-recon.md` MEM-R8 基线更新为 35/88/123。

## 验证

```powershell
cd e:\programs\Tree\desktop\plugins\tree.agent
D:\app\flutter-sdk-3.47.5\flutter\bin\dart analyze   # 必须 0
D:\app\flutter-sdk-3.47.5\flutter\bin\dart test      # 全量
```

- 若改动触及 `tree_protocol` 契约，再跑协议契约测试（当前预期 123 条）。
- 未改 UI，不跑桌面 `flutter test`；若 M5 另行处理。

## 风险与回滚

- **全局 provider 跨 runtime 污染**：缓存按 agentId 共享，`debugCloseAll` 清理；生产单数据根，测试用临时目录 + tearDown。
- **首钉字节变化**：首次注入记忆段会改变 `[0] system`，属预期一次性代价；已钉住会话继续逐字复用。
- **每轮 tick 成本**：单飞 + 水位无新增即早退；若实测偏高，可只在轮次收尾触发。
- 回滚顺序：先撤两个钩子（tick / prewarm）→ 撤 provider 接线 → 撤工具/种子增量；前三步均为加法，回滚不改既有字节。
