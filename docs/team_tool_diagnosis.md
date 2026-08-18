# team 工具可用性诊断报告（Tree 项目）

> 诊断时间：2026-08-18（第一轮）→ 2026-08-18（第二轮补充审查）
> 诊断方式：静态代码审查 + 运行时实证（Windows + Docker Desktop）

---

## 0. 结论（TL;DR）

team 工具存在**架构级双轨制缺陷**（team 工具内部走 Docker 容器，LLM 工具走本地目录），叠加**任务闭环断裂**（roster 中成员工作状态卡死在 working 已实证）、**成员→leader 消息链路 4 层断裂**、**广播/文件发送不投递**等逻辑 bug，导致团队协作状态不可靠、任务无法闭环、成员间无法正常通信。

---

## 1. 环境事实（实测）

| 项 | 实测结果 |
|---|---|
| 平台 | Windows 10（cmd），Flutter + FastAPI |
| 后端 | `server/main.py` 运行中（PID 136824，:8000），venv 内 docker SDK 7.2.0 可用 |
| 我的容器 | `workspace_agent_1787022784638`，activity.log 记录我的工具调用 |
| Leader 容器 | `workspace_agent_1787015498656`，**`.self/team_roster.md` 存在**（3 成员） |
| roster 实况 | 3 名成员 work_status **全部卡在 working** |
| 成员 .self | 位于 Leader 容器 `workspaces/{member_id}/.self`（各自独立，符合设计） |
| 共享映射 | `member_1787015857_ij3yml` / `x3clpa` / `7xql6q` → `agent_1787015498656` |
| 本机 `shutil.which("sh")` | None（Git 在 `D:\Download\Git`，`_resolve_sh` 只探测 C 盘固定路径） |

---

## 2. 架构级问题（最严重）

### 2.1 【双轨制】team 工具与 LLM 工具指向不同工作空间

- LLM 工具（read/write/terminal/embed_search）：
  - 本地模式 → `LocalWorkspaceIO` → 反向 WS → 前端 `LocalExecutorService` → 用户工作目录（`.self` 路径映射 `<baseDir>/workspaces/{id}`）；
  - 云端模式 → `CloudWorkspaceIO` → docker exec 到容器（MCP server.py 经 `WORKSPACE_ID` 绑定）。
- team 工具内部（roster/identity/activity.log/git/文件）一律 `docker_manager.exec_in_workspace`：
  - Docker 可用 → 容器；Docker 不可用 → 后端 `server/workspaces/{id}`。
- **两套判断互不联动**：`DockerManager._use_local()`（= not available）与 `LocalExecutorClient.is_local()`（前端注册）。本地模式下：roster 写容器、LLM 读本地目录，物理隔离。

实证：我的 activity.log 在容器中，而 terminal 实际执行在本地项目根；Leader 容器内有 roster，本地 `workspaces/` 却无对应容器。

### 2.2 【已修正·非 bug】roster 读写路径"不一致"

第一轮曾把"成员读 roster 时 `.self` 被重写为 `workspaces/{member}/.self`"列为 bug。**此判断有误**：`.self` 空间本就应各自独立，成员未建过子团队时读自己空间 roster 为空是**正确行为**（实证：成员 .self 确实独立于 `workspaces/{member_id}/.self`）。

但要注意：
- **Leader 的 roster 只存在于 Leader 自己的 `.self`**（容器 `/workspace/.self/team_roster.md`）；本地模式下 LLM 工具读 `<baseDir>/workspaces/{leader_id}/.self` → 读不到 → 双轨制的直接后果。
- 前端 `/api/agents/{id}/teammates` 读容器 roster，与 LLM 工具路径（本地目录）也不一致。

### 2.3 【实证】共享成员 Git 提交与 Leader 主工作区混合

Leader 容器 `/workspace` 是**单一 git 仓库**：`term_probe1.txt`、`.output/`、`.self/`、`workspaces/` 全部在同一仓库内（`git status` 显示 No commits yet + 全部 untracked 混在一起）。

后果：
- 成员在共享主工作区执行 git 提交 → 全部进入 Leader 仓库，**无成员级 Git 隔离**，与 `docs/team_structure.md` 声称的"各自有独立 Docker 工作空间（Git 隔离）"**矛盾**。
- team 工具 `git_log(member_id)` 解析到 Leader 容器 → 查的是 Leader 仓库 log → 无法区分成员提交。
- `view_member_output` 的 commits/files 实为 Leader 主工作区内容，不反映成员真实产出。

---

## 3. 【新增·重点】成员→Leader 消息链路 4 层断裂

用户指出"teammate 无法向 team leader 发消息（路径未阻塞，但无法查询 leader 的 agent id）"。审查确认：**代码路径存在但实际完全不可用**，且问题不止一层：

### 3.1 无法查询 Leader 的 agent id
- team 工具**没有** `query_leader` / 任何暴露 `leader_id` 的 action；`query_member` 只能查自己 roster 里的子成员。
- help 工具身份区（`_build_identity_section`）对成员只写"你是团队成员（Level X）"，**不透出 leader 是谁/leader_id 是多少**。
- 唯一途径：成员主动 `read .self/identity.md`（含 `team_leader: xxx (agent_id)`）。

### 3.2 【实证】即使知道 id，消息也会被静默丢弃

`_action_send_message` 向 leader 发送时 target 字典：
```python
target = {"id": self.leader_id, "workspace_id": self.leader_id, "model_id": "", ...}
```
→ `_dispatch_to_member` 透传 `model_id: ""` → `_process_member_message`：
```python
model_config = _model_configs.get("")  # None
if model_config is None:
    # 写 activity.log "成员模型不存在" 后 return
```
**消息被静默丢弃**（实证：payload model_id=''，`dispatched: True` 但实际不处理）。正确做法应从 `get_agent(user_id, leader_id)` 取 Leader 的 model_id。

### 3.3 走错 broker，破坏 Leader 串行

所有 TeamTool 实例都绑定全局 `_team_broker`（process_fn=`_process_member_message`）。成员向 Leader 发消息投递 key `(user_id, leader_id)` 到 `_team_broker`，而用户消息走 `_top_chat_broker`。若 Leader 正在处理用户消息：
- 两个 broker 各起一个 worker，**并发操作同一 `get_session(user_id, leader_id)` 会话** → 上下文列表竞争、LLM 请求并发（乱序/429）。
- 成员消息未进入 Leader 的串行队列。

### 3.4 回复不回投（单向通信）

`_process_member_message` 处理 Leader 消息后：回复写入 Leader 对话历史 + 推 WS 给前端，**没有任何机制把回复投回成员**。成员发消息后永远收不到回复，其 `message_history` 也不会有 Leader 的回复。

---

## 4. 逻辑 bug（高优先级）

### 4.1 任务闭环断裂 + roster work_status 卡死（实证）
- `complete_task` / `report_task_completion` **未注册进 `execute()` 的 dispatch**（14 个 action 无二者）→ LLM 无法调用。
- 实证：Leader 容器 roster 中 3 名成员 work_status 全部为 **working**（`assign_task` 设为 working 后从未改回）。
- 前端 teammates 窗口：`_active_tasks` 为空时回退 roster 的 work_status → **永远显示"工作中"**。

### 4.2 wait_for 必然等到超时
轮询 Leader TeamTool 内存 `member.work_status`；成员完成仅发 WS 事件（`_send_status_idle`）+ 清 `_active_tasks`，**无任何代码更新 Leader 内存状态** → 轮询永不满足，默认 300s 后 timed_out=True。

### 4.3 广播不投递（实证）
`_action_broadcast` 只追加 `self.messages` 与成员 `message_history`，**从不调用 `_dispatch_to_member`** → 成员收不到广播。

### 4.4 send_file 只写文件、不通知成员
文件复制成功但成员**收不到任何到达通知**（notice 只存临时内存），不触发成员处理。

### 4.5 can_lead_team 联动死代码
`TeamTool` 无 `member_id` 属性，`getattr(self, "member_id", None)` 恒 None → 从 `session.teammates` 同步 `can_lead_team` 永不生效。

### 4.6 leader_name 恒为 "self"（实证）
`AgentLLMSession` **没有 `agent_name` 属性** → `_leader_name()` 恒返回 "self"。实证 identity.md：`team_leader: self (agent_1787015498656)`——Leader 名称丢失，只剩 workspace_id。

---

## 5. Windows / 本地模式适配

| # | 问题 | 说明 |
|---|---|---|
| 5.1 | `_resolve_sh()` 找不到 sh | `which sh`=None，候选仅 C 盘固定路径，实际 Git 在 D 盘 → 返回 None；native fallback 不支持 `tail`（view_member_log）等命令 |
| 5.2 | exec_in_workspace base64 分支误判 | `"base64" in cmd and ">" not in cmd` 可能误伤合法写命令 |
| 5.3 | send_file 大文件受限 | Docker exec 单命令 ~4MB 上限；`_sanitize_file_path` 禁止空格/中文路径 |
| 5.4 | broker worker 常驻线程 | `_run` 用 `while True` + `asyncio.to_thread(queue.get)`，空闲成员也长期占用线程池线程 |

---

## 6. 并发 / 状态 / 路由

| # | 问题 | 说明 |
|---|---|---|
| 6.1 | TeamTool 内存无锁 | members/tasks/messages 被多个 chat 消费线程并发读写 |
| 6.2 | 内存状态不持久化 | tasks/messages/work_status 重启丢失；roster 仅恢复部分字段 |
| 6.3 | `_parse_roster_md` 硬编码 | workspace_id=member_id、can_lead_team=True → 状态丢失 |
| 6.4 | routes 队友消息缺 system_prompt | `send_teammate_message` 用 7 列解析，投递时 system_prompt 为空 → 成员角色丢失 |
| 6.5 | 共享成员 rebuild 不干净 | remove 仅 unregister，容器内旧 `.self` 子目录残留 |
| 6.6 | 前端无成员→Leader 入口 | teammates 窗口只有"用户→成员"发消息，无"成员→Leader" |

---

## 7. 修复建议（按优先级）

1. **统一工作空间访问层**：team 工具改用与 LLM 工具相同的 `WorkspaceIO`（Cloud/Local），根治双轨制。
2. **打通成员→Leader 消息**：
   - 新增 `query_leader` action 或在 help 身份区透出 leader_id；
   - `_action_send_message` 向 leader 发送时从 `get_agent()` 取 model_id（修 model_id=""）；
   - 成员→Leader 消息路由到 `_top_chat_broker`（复用 Leader 串行队列）；
   - Leader 回复后经 broker 回投成员。
3. **打通任务闭环**：注册 complete_task/report_task_completion action；完成后同步更新 Leader 内存 work_status 与 roster。
4. **重做 wait_for**：轮询全局 `_active_tasks` / broker 队列长度，而非 Leader 内存 work_status。
5. **修复广播/文件通知**：broadcast/send_file 对每个成员 `_dispatch_to_member`。
6. **成员级 Git 隔离**：共享容器内为成员建立独立 git 仓库（如 `workspaces/{id}/.git`）或按目录过滤；`git_log` 按成员解析。
7. 修复 `_resolve_sh` 动态探测、TeamTool 加锁、leader_name 透传、can_lead_team 联动。

---

## 8. 验证建议

- 完整走一遍：create_member → assign_task → 成员完成 → wait_for → view_member_output，观察 roster 状态与任务闭环。
- 成员侧：read identity.md → team send_message leader → 观察是否被丢弃、Leader 是否收到、回复是否回投。
- 建议为 team_tool.py 补充单元测试（当前 tests/ 无 team 相关测试）。
