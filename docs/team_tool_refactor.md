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
