# 工具结果大小门控（超长结果重定向到 .self 文件）

## 摘要

在 LLM 工具循环的唯一出口（`server/llm/llm.py` 的 `_run_completion_loop`）增加**工具结果大小门控**：单个工具结果的字符串化文本超过 **10_000 字符**时，不再把完整结果塞进上下文，而是将其写入工作空间私有目录 `.self/results/` 下的重定向文件，并只把「重定向文件位置 + 推荐查看方式 + 重定向原因（含大小信息）」告诉 agent（即写回上下文 / 前端卡片 / 历史表的内容）。写入能力缺失或写入失败时退化为本地截断，保证上下文始终有界。

该门控与上一轮 grep 工具侧截断互补：grep 工具侧截断防止管道（docker exec / WS）被撑爆；本门控在统一出口兜底，覆盖所有工具（read / terminal / document 等可能返回超大内容的工具）。

## 现状分析（基于探索）

- **唯一 choke point**：所有工具（内置 + MCP + embed_search）结果最终都在 `llm.py:_run_completion_loop` 中插入上下文：
  - `result_str = _stringify_tool_result(result)`（llm.py:966）
  - `yield {"type":"tool_call", "result": result_str}`（llm.py:968-973）→ 前端展示与历史表持久化均取自该值（chat.py:1568 `result = item.get("result","")` → chat.py:1599 `tool_end`、chat.py:1609 `_store_message(tool_result=...)`）
  - `base_content = self._tool_context_content(result, result_str)`（llm.py:978）→ `self.context.append({"role":"tool",...})`（llm.py:1008-1012）
- **当前无大小门控**：`_stringify_tool_result`（llm.py:91-138）仅对列表字段做保护（30 项 / 8 字段 / 120 字符，llm.py:37-39），`content/output/result/...` 主字段与 `stdout` 等普通字符串字段**零截断直通**。
- **超大风险工具**：document 系列（read_pdf/docx/pptx/xlsx，整文档 JSON）、terminal stdout、read 全文、MCP stdio 结果。
- **`.self` 私有目录已具备写入能力**，三种模式均自动建父目录，无需显式 mkdir：
  - 云端：`docker_manager.write_file`（mkdir -p + put_archive，docker_manager.py:1730-1741）
  - 本地：前端 `_writeFile`（`file.parent.create(recursive:true)` + writeAsString，local_executor_service.dart:768）
  - SSH：SFTP `_sftpMkdirP`（ssh_workspace_executor.dart:366-385）
  - 共享成员 `.self` 自动路由到 `workspaces/{id}/.self`（`resolve_private_path`，docker_manager.py:234-254）
- **会话已持有 `workspace_id`**（llm.py:296），但没有 IO 通道；chat.py 已有现成的三模式统一 IO 构建器 `_get_workspace_io(user_id, agent_id)`（chat.py:859-877）与 `run_io`（已导入）。
- **会话创建点**（需注入写入器）：chat.py:1756（成员消息路径）、chat.py:2350（用户消息路径）。routes.py:172（compact 恢复路径）不跑工具循环，无需注入。

## 变更方案

### 1. `server/llm/llm.py` — 门控核心

**常量**（放在 `_MAX_LIST_ITEMS` 附近）：
```python
# 工具结果大小门控：超过该字符数时不再直进上下文，重定向到 .self 文件
RESULT_REDIRECT_THRESHOLD = 10_000
# 重定向提示中附带的结果预览长度
_REDIRECT_PREVIEW_CHARS = 300
```

**`AgentLLMSession.__init__`** 新增可选参数（带中文 docstring 说明）：
```python
result_redirect_writer: Optional[Callable[[str, str], None]] = None,
```
存为 `self.result_redirect_writer`，并初始化 `self._redirect_seq = 0`。

**新增方法 `_maybe_redirect_result(self, tool_name: str, result_str: str) -> str`**：
- `len(result_str) <= RESULT_REDIRECT_THRESHOLD` → 原样返回。
- 超限且 `self.result_redirect_writer` 可用：
  - `self._redirect_seq += 1`；`ts = time.strftime("%Y%m%d_%H%M%S")`
  - `rel = f".self/results/{ts}_{self._redirect_seq:03d}.{tool_name}.result"`
  - 调用 `self.result_redirect_writer(rel, result_str)` 写入完整结果（try/except 包裹）
  - 返回重定向提示，内容含：`[工具结果已重定向]` + 工具名 + 实际字符数与阈值 + 文件相对路径 + 推荐查看方式（① 用 read 工具对该文件分多次读取（start_line/line_count 控制范围）；② 或用 terminal 工具（grep/sed/python 等）对文件做进一步正则化解析提取有效信息）+ 前 `_REDIRECT_PREVIEW_CHARS` 字符预览。
- 无写入器或写入异常 → 退化为本地截断：`result_str[:RESULT_REDIRECT_THRESHOLD] + "\n...[结果过长，共 N 字符，已截断至阈值]"`。

**`_run_completion_loop` 调用点**（llm.py:966 后立即）：
```python
result_str = _stringify_tool_result(result)
result_str = self._maybe_redirect_result(tc["name"], result_str)
```
之后 yield 与 context.append 均使用门控后的 `result_str`，无需改动下游。图像结果（`image_base64`）走 `_tool_context_content` 摘要，`result_str` 很短不会触发门控；`_build_image_user_msg` 独立 user 消息路径不受影响（按用户决策图像不门控）。

### 2. `server/agent/chat.py` — 注入写入器

新增模块级辅助函数（放在 `_get_workspace_io` 附近）：
```python
def _make_result_redirect_writer(
    workspace_id: str, user_id: str, agent_id: str,
) -> Callable[[str, str], None]:
    """构造工具结果重定向写入器：把超长工具结果写入 .self 私有目录。

    与内置工具共用同一 WorkspaceIO 通道（三模式统一），保证
    .self 路径语义一致（本地 baseDir / 云端容器 / SSH）。
    """
    io = _get_workspace_io(user_id, agent_id)

    def _writer(rel_path: str, content: str) -> None:
        run_io(io.write_file(workspace_id, rel_path, content))

    return _writer
```

在**两处** `AgentLLMSession(...)` 调用（chat.py:1756、chat.py:2350）中追加参数：
```python
result_redirect_writer=_make_result_redirect_writer(
    workspace_id, user_id, agent_id
),
```

### 3. `server/tests/test_tool_result_gate.py`（新增）— 单元测试

仿照现有测试（如 `test_thinking.py:83`）构造 `ModelConfig` 与 `AgentLLMSession`，直接对 `_maybe_redirect_result` 做纯单元测试：
- 短结果（≤ 阈值）原样返回；
- 超长结果 + 写入器 → 返回重定向提示（含文件路径、原因、预览）、写入器收到完整原文与 `.self/results/` 相对路径、文件名含工具名；
- 超长结果、无写入器 → 返回截断文本，长度 ≤ 阈值，且含截断标记；
- 写入器抛异常 → 退化为截断文本（不抛错）。

## 假设与决策

- 阈值单位为**字符数**（`len(result_str)`），与 grep 工具侧字符级截断一致；`10_000` 为模块常量，后续如需可配置化再抽到 config。
- 门控覆盖 LLM 上下文 + 前端 tool_end 卡片 + 历史表持久化三处（用户确认「统一门控三者」）：三处都只看到重定向提示与文件位置。
- 图像 base64 不门控（用户确认）：继续走现有 vision 独立 user 消息通道。
- `_ASK_PAUSED_KEY` 分支（llm.py:955-963）先于门控执行，占位内容短，不受影响。
- 重定向文件放在 `.self/results/` 子目录（`<ts>_<seq>.<tool>.result`）；三种模式的 write_file 均自动建父目录，无需显式 mkdir。共享成员的 `.self` 由既有 `resolve_private_path` 自动路由到 `workspaces/{id}/.self`。
- 门控在 todo/spec 前缀注入（llm.py:979-1007）之前完成，前缀仍照常拼在重定向提示之前（内容短，无影响）。
- `_redirect_seq` 为会话级计数器，`_run_completion_loop` 单线程执行，无并发问题。

## 验证

1. 运行单元测试：`python -B -m unittest tests.test_tool_result_gate tests.test_grep_tool -v`（server 目录、`.venv`）。
2. 全量回归（可选）：`python -B -m unittest discover tests -v`。
3. 手动验证：向本地/云端 agent 发送指令触发超大工具结果（如 grep/read 一个超长文件、terminal cat 大日志），确认：
   - 工具卡片显示重定向提示而非完整内容；
   - 工作空间 `.self/results/` 下生成 `<ts>_<seq>.<tool>.result` 文件且内容完整；
   - 历史表 `tool_result` 只存提示（不存 MB 级行）；
   - agent 用 read/terminal 能正常查看该文件。
