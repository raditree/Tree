# team 工具改造实施记录（第三轮）

> 时间：2026-08-18
> 范围：统一消息 API / update memory 门控与锁 / terminal 内置化 / list_members 分组 / send_file 取消 / 成员回复回传 leader

---

## 1. 统一消息发送 API（收敛出口）

新增 ``main._dispatch_agent_message(user_id, target_ids, content, source_agent_id, top_agent_id, system_prompt, extra)``：

- **User-Agent 与 Agent-Agent 消息统一走此入口**（原 ``_dispatch_user_message``、routes 的 ``send_teammate_message``、team 工具的 ``send_message``/``broadcast`` 均已收敛）；
- **原生支持一对多**：``target_ids`` 传字符串或列表；
- **团队隔离**：仅允许发送给有关系的对象（上级 leader / 直属成员 / 同顶部 agent 旗下成员），跨顶部 agent 直接拒绝；
- **目标解析**：顶部 agent 经 agent_store 查询；成员经顶部 agent 的 roster（team_roster.md）解析；
- **update memory 锁检查**：目标正在记忆维护时拒绝投递；
- **路由**：顶部 agent 走 ``_top_chat_broker``，成员走 ``_team_broker``。

修复了原 bug：成员向 leader 发消息时 ``model_id=""`` 被静默丢弃（现从 agent_store 补齐模型配置）。

## 2. update memory 门控 + 锁

- **工具计数落盘**：新增 ``agent_tool_count`` 表（``(user_id, agent_id)`` 主键，各 agent 隔离），``get_tool_count`` / ``increment_tool_count`` / ``reset_tool_count``；
- **门控**：``_run_memory_update`` 入口检查工具计数 >= 7 才触发（“7 次以上”含 7）；update memory 完成后计数清零重新累积；
- **锁**：``_memory_updating`` 集合（``_lock_memory_update`` / ``_unlock_memory_update``）；记忆维护期间，用户消息（``_dispatch_user_message`` / ``_handle_user_message`` 兜底）、队友/leader 消息（``_process_member_message``）、统一消息 API 全部拦截；
- teammates 与顶部 agent 走同一 ``_run_memory_update`` 逻辑（处理流程一致）。
状态机：working → updating_memory → idle（记忆维护结束后由调用方直接发送 idle，不再回跳 working）。

## 3. 工作空间工具全部内置化（read / write / edit / terminal）

- 新建 ``server/tools/read_tool.py`` / ``write_tool.py`` / ``edit_tool.py`` / ``terminal_tool.py``（均基于 ``WorkspaceIO``，云端容器 / 本地目录统一）；
- 从 MCP workspace 服务（``mcp_tools/server.py``、本地 handler、tool_defs）移除 read/write/edit/terminal 暴露，该服务仅保留 embed_search；
- 删除旧 ``mcp_tools/read_tool.py`` / ``write_tool.py`` / ``edit_tool.py`` / ``terminal_tool.py``；
- 四个工具作为内置工具直接注册到 LLM 会话，**避免 MCP stdio 嵌套导致的解析错误**。

## 4. list_members 分组

``team list_members`` 改为分组返回：

- ``team_leader``：当前 agent 的上级 leader（成员视角）；
- ``teammates``：当前 agent 创建的直属成员（下属，保留原筛选参数）；
- ``team_member``：本顶部 agent 旗下其他成员（经上级 roster 查到的平级成员）。

## 5. send_file 取消

- action 从工具定义（enum）与 execute 分发中移除；
- ``_action_send_file`` 保留但直接返回“已取消”（理由：team leader 与 teammates 共享工作目录 base，文件直接写入双方可见空间即可）。

## 6. 成员回复自动回传 leader

- ``_process_member_message`` 在成员工具循环完成后，把最后一次回复 content 经统一消息 API 回传 ``leader_id``（前缀 ``[成员 xxx 完成回复]``），leader 收到后作为普通消息进入其串行队列。

## 7. 验证结果

- 所有修改文件 ``ast.parse`` 语法检查通过；``import main`` OK；
- 功能测试（stub broker / agent_store / roster）通过：
  1. 用户 → 成员：sent，payload model_id 正确、leader_id=顶部 agent；
  2. 成员 → leader：sent，payload model_id 正确（修复丢失 bug）、走 top broker；
  3. 跨顶部 agent：error / rejected；
  4. leader → 多成员（一对多）：sent 全部投递；成员 → 同级成员：sent；
  5. 给自己发：拒绝；update memory 锁期间：拒绝。

## 8. 修改文件清单

| 文件 | 改动 |
|---|---|
| server/main.py | 统一消息 API、memory 锁、工具计数、入口拦截、teammates 路由收敛 |
| server/tools/team_tool.py | dispatcher 接入、send_message 一对多、broadcast 投递、list_members 分组、send_file 取消 |
| server/tools/terminal_tool.py | 新增（内置 terminal） |
| server/tools/read_tool.py / write_tool.py / edit_tool.py | 新增（内置 read/write/edit） |
| server/mcp_tools/read_tool.py 等 4 个旧文件 | 删除（已由内置版本替代） |
| server/tools/__init__.py | terminal 内置注册、message_dispatcher 透传 |
| server/tools/help_tool.py | 帮助文本更新（移除 send_file） |
| server/core/workspace_io.py | 新增 git_log / list_files 抽象与实现（统一双轨制基础） |
| server/core/conversation_store.py | 新增 agent_tool_count 持久化 |
| server/mcp_tools/server.py | 移除 terminal 工具暴露 |

---

## 9. help 永久保留 + memory/rule 注入 + compact 刷新（第九轮）

> 时间：2026-08-18（同一会话续作）
> 背景：agent 很少主动重调 help，compact 后执行模式/身份等环境认知丢失；且 memory.md 只写不读（无注入机制）。

### 9.1 help 永久保留特权（llm.compress）

- compact 时扫描历史中的 help 调用对（``assistant`` 的 ``tool_calls`` 含 ``name=="help"`` + 紧随其后的 ``tool`` 结果），**成对剥离**（OpenAI API 要求 tool 消息紧跟 assistant）；
- **只保留最靠前（最贴近系统提示词）的一次**，其余按普通消息处理（可总结区总结、保留区留存），避免 help 输出堆积膨胀；
- 重组：``system + [summary] + kept_help + to_keep``。

### 9.2 memory.md / rule.md 注入 help（workspace_extra_info）

- ``_build_workspace_extra_info`` 新增注入 ``.self/memory.md`` 与 ``.self/rule.md``；
- **大小上限 4096 字符**（``_SELF_DOC_INJECT_LIMIT``）：未超限全量注入，超限经 ``_compress_self_doc``（LLM 压缩 + 保头保尾回退 + 指纹缓存）压缩；
- help 工具新增 ``## 记忆档案 (memory.md)`` 板块（在 rule 之后）。

### 9.3 help 刷新只在 compact 触发上下文重构时发生

- 平时 ``help.execute()`` **不刷新**（用会话快照，保持前缀稳定、KV 缓存命中）；
- 新增 ``HelpTool.render_fresh_content()``：刷新 extra_info + 重新渲染；
- ``register_builtin_tools`` 绑定 ``session.help_refresh_callback``：compact 时调用刷新回调，生成新的 help 调用对（新 assistant tool_call + tool 结果），替换常驻 kept_help；
- ``llm.compress`` 在重组前调用该回调替换 kept_help——此时整个前缀必然重排，**刷新零额外缓存成本**；
- 无回调（无限上下文会话等）时保留旧块，行为不变。

### 9.4 验证

- 单元测试（stub）：平时 execute 用快照（refresh 0 次）；compact 时刷新 1 次、help 块含最新 memory/rule；tool_call 配对约束满足；
- 实测：memory.md 20281 字符 → 注入 3425；rule.md 4863 → 3426；compact 后上下文约 12k tokens（max_seqlen=204800，阈值 163840，占 7%）；
- 压缩缓存：同内容二次调用不重复触发 LLM。

### 9.5 修改文件

| 文件 | 改动 |
|---|---|
| server/core/llm.py | compact 剥离最早 help 块 + 刷新回调替换 |
| server/main.py | `_SELF_DOC_INJECT_LIMIT` / `_compress_self_doc` / memory+rule 注入 / `_register_tools` refresher |
| server/tools/help_tool.py | `render_fresh_content()` / `refresh_extra_info` 参数 / memory 板块 |
| server/tools/__init__.py | refresher 透传 / `session.help_refresh_callback` 绑定 |

**待办**：改动需重启后端（PID 40536 无 reload）生效；重启后可用 ``refresh`` 验证 help 输出含记忆档案板块。
