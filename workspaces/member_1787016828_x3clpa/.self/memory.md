# 记忆文档 (memory.md)

## 任务记录

### 2025-08 · 任务：调查并修复 usage 统计 input tokens 增长异常（疑点核实与最小修复）

**任务目标**：
- 核实 Leader 定位的 4 个高度可疑根因（DeepSeek usage 缓存字段兼容 / usage 重复记账 / 预算摘要滚雪球 / 共享 tracker 累加口径），完成修复、补测试、提交 Git 并汇报。

**关键决策**：
- 先通读 server/core/{llm,budget,models}.py、server/main.py 预算相关段、configs/models/*.yaml。
- 用最小探针实测真实 API usage 形状（后端在本地 Windows + WSL 混合 shell，多命令不稳，改用 write 脚本 + python/venv 执行）。

**遇到的问题及解决方案**（按疑点）：
1. **疑点1（usage 缓存字段）→ 确认为真实缺口**：
   - 实测 ai-galaxy 网关（token.ai-galaxy.com/v1，deepseek-v4-flash.yaml）流式 + include_usage 返回 usage 仅含 prompt/completion/total_tokens + completion_tokens_details.reasoning_tokens，**无任何缓存字段**（即使重复前缀缓存命中也不报）。
   - 实测 DeepSeek 官方（api.deepseek.com/v1）同时返回 `prompt_tokens_details.cached_tokens` + 顶层 `prompt_cache_hit_tokens`/`prompt_cache_miss_tokens`。
   - 原实现只解析 `prompt_tokens_details.cached_tokens`，官方端点缓存命中漏解析 → cached=0 → 全价计费。
2. **疑点2（usage 重复记账）**：规范 include_usage 只有一个 usage chunk，但无守卫；已加 `usage_recorded` 每轮守卫，重复 chunk 只记一次。
3. **疑点3（预算摘要滚雪球）→ 确认为 input 异常增长主放大器**：每个工具结果都注入完整 token 明细（~140 字符）并留在 context → 上下文膨胀 → 下次输入更大。修复：工具结果注入改 compact 精简版（剩余金额+消耗比例），完整明细保留给告警/WS。
4. **疑点4（共享 tracker）→ 预期行为，无需改动**：`(user_id, top_agent_id)` 键共享 tracker，main.py 在用户向顶层发新消息时 `reset_budget_tracker` 统一重置，teammates 共享正确，未发现重复统计。

**改动文件（commit 545fb4d）**：
- `server/core/llm.py`：新增 `extract_usage_counts(usage)` 解析函数（兼容 OpenAI 协议 `prompt_tokens_details.cached_tokens`、DeepSeek 顶层 `prompt_cache_hit_tokens`/由 `prompt_cache_miss_tokens` 反推、网关顶层 `cached_tokens`，最后 clamp(0, prompt_tokens) 防御）+ 每轮 `usage_recorded` 守卫 + 工具结果预算摘要改 `compact=True`。
- `server/core/budget.py`：`get_budget_summary(price_calc, compact=False)` 支持精简版。
- `server/tests/test_usage_parse.py`：新增 8 个用例（OpenAI/DeepSeek hit/miss/网关缓存/无缓存回退/clamp/OpenAI 优先/重复 usage 只记一次）。

**验证方式**：
- 新增测试 8/8 通过；现有 test_limitless_context 7/7 通过；全套 15/15 通过；`py_compile` OK。
- 探针仅用极小请求（max_tokens=8），未泄漏 api_key（密钥仅脚本内临时读取，未入 git）。

**重要结论**：
- 当前生产网关（ai-galaxy）本身不返回缓存字段，所以实际环境里 cached_tokens 一直为 0 是网关特性；兼容 DeepSeek 官方字段为官方端点/未来网关兜底。
- 本地执行模式：终端在 cmd.exe/WSL bash 间切换，多命令不稳定 → 优先 write .sh / .py 脚本再执行；git 遇到中文 commit 消息时用 subprocess（encoding utf-8）执行，避免 cmd 编码问题。

**后续待办/提示**：
- 提交时只 add 自己改动的文件，避免带上 Leader/前端未提交的改动（lib/、server/main.py、workspaces/）。
- 若再遇 usage/预算问题：先探针确认网关 usage 字段，再对齐解析器。
