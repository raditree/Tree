# terminal 工具增加 hook 模式（后台长任务 + 完成回调唤醒）

## 1. 概述

给内置 `terminal` 工具增加 **hook 模式**：

- 以**独立进程**在后台执行一条长命令（本地=前端在本机起的进程；云端=Docker exec；SSH=远端进程），**输出实时重定向**到工作空间内指定文件（`command > file 2>&1`）。
- 工具**立即返回**（不再阻塞 tool loop），agent 可以就此结束本轮/停止 tool loop。
- 命令结束后，后端 **hook 回调**向**发起该命令的 agent** 投递一条 `[terminal hook] ...` 工具提示（经既有 broker 派发通道，同一会话续跑），agent 据此读取输出文件继续推进任务。
- 支持通过 `terminal` 的 `hook_action`（`status` / `cancel`）查询/取消后台任务。

核心复用现有能力，不改动 LLM 工具循环本身：
- **唤醒续跑**完全复用 AskUserQuestion 的 `resume_after_answer` 通道（`_dispatch_agent_message` → `top_chat_broker` / `team_broker` → `_handle_user_message` / `_process_member_message` → `session.chat(...)`）。
- **执行通道**复用 `WorkspaceIO` 抽象（cloud / local / ssh），只在 local 模式新增“前端托管分离进程”能力以支撑长任务与真实取消。

## 2. 现状分析

- [terminal_tool.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/terminal_tool.py)：`execute` 为同步阻塞调用 `run_io(io.exec_shell(...))`，有超时（默认 120s，封顶 3600），无后台/回调能力。
- [workspace_io.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/workspace_io.py)：`WorkspaceIO` 抽象了 cloud/local/ssh 三种执行；`LocalWorkspaceIO` 经反向 WS 转发到前端执行器。
- [local_executor.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/local_executor.py)：`LocalExecutorClient.request` 默认 **120s 响应超时**（`_LOCAL_EXEC_TIMEOUT`），这是本地模式长任务无法直接用 `exec_shell` 等待的原因——必须改为前端托管分离进程 + 退出时回传，才能支持长任务并拿到真实退出码。
- [chat.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/agent/chat.py)：`_dispatch_agent_message`（顶部 agent 走 `top_chat_broker`、成员走 `team_broker`）与 `resume_after_answer` 就是“唤醒 agent 续跑”的现成机制；`_register_tools` 中能拿到 `session/user_id/agent_id/top_agent_id/session_id/is_member`，可构造闭包回调。
- [tool/__init__.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/__init__.py)：`register_builtin_tools` 构造 `TerminalTool(io, workspace_id)` 并注册；`_make_handler` 会把 kwargs 传给 `execute`。
- 工具描述来源：[builtin.yaml](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/prompt/versions/1.0.0/tools/builtin.yaml)（`versions.active_tool_description("terminal")`），参数 schema 在 `get_tool_definition()`。
- 前端本地执行器 [local_executor_service.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/local_executor_service.dart) 用 `Process.run` 执行（无句柄可 kill）；[websocket_service.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/websocket_service.dart) 只把 `tool_exec_request` 路由给本地执行器。

## 3. 设计决策（已与用户确认）

1. **输出重定向**：实时 shell 重定向 `command > <output_file> 2>&1`（cmd/sh/bash 均支持），运行期间可 tail 查看。
2. **查询/取消**：需要支持。`hook_action=status|cancel` 查询/取消后台任务。
3. **执行方式**：
   - **本地 / SSH 模式**（用户主力场景）：两者共用 `LocalWorkspaceIO` 通道（`SSHWorkspaceIO` 为其子类），前端新增 `exec_shell_hook` 分离进程 op（`Process.start` 托管句柄），进程退出时回传 `tool_exec_response`（不再受 120s 后端等待上限约束，拿到真实退出码）；取消 = 前端 `process.kill()`。
   - **云端模式**：后端独立后台线程执行新增的 `io.exec_shell_no_timeout`（**去掉 `timeout N` 包装，与本地一样无时长上限**）；命令以 `... & echo $! > <pidfile>; wait` 包装，取消 = `kill -TERM $(cat <pidfile>)`。
4. **唤醒消息**：以 `user` 角色消息注入（与 AskUserQuestion 续跑一致），内容带 `[terminal hook]` 前缀；成员续跑沿用 `session.sender_id` 决定是否回发总结。

## 4. 改动方案

### 4.1 新增 `server/tool/hook_manager.py` —— 后台任务管理器（模块级单例）

`HookTaskManager`（`get_hook_manager()` 提供单例）：

- `start(io, workspace_id, command, output_file, timeout, on_complete) -> dict`
  - 生成 `task_id`（uuid hex），登记状态 `running`。
  - 先 `run_io(io.write_file(workspace_id, output_file, ""))` 建占位文件（自动建父目录，三模式通用），保证重定向目标存在。
  - 按 `isinstance(io, LocalWorkspaceIO)` 分流：
    - **local**：`run_io(io.exec_shell_hook(workspace_id, task_id, wrapped, timeout, on_done))`；`wrapped = f"{command} > {output_file} 2>&1"`（前端 cmd/bash 执行）。
    - **cloud/ssh**：`wrapped = f"{command} > {output_file} 2>&1 & echo $! > {output_file}.pid; wait"`（sh 语法）；起 `threading.Thread(daemon=True)` 跑 `run_io(io.exec_shell_no_timeout(workspace_id, wrapped))`（**不经 `timeout` 包装、无上限**），结束调 `_on_complete`。
  - 返回 `{"task_id": ..., "output_file": ...}`。
- `_on_complete(task_id, result)`：更新状态（completed/failed/cancelled）、记录 `exit_code`，调 `on_complete(task_id, exit_code, output_file, cancelled, error)`。
- `status(task_id) -> dict`：`{"state", "exit_code", "output_file", "command", "started_at", "finished_at", "error", "task_id"}`；未知 task_id 返回 error。
- `cancel(task_id) -> dict`：
  - 置 `cancelled=True`；
  - local：`run_io(io.cancel_exec_hook(task_id))`（后端发 `tool_exec_cancel` WS → 前端 kill，进程退出后仍走 `_on_complete`，标记 cancelled）；
  - cloud/ssh：`run_io(io.exec_shell(workspace_id, f"kill -TERM $(cat {output_file}.pid) 2>/dev/null || true", 10))` 尽力终止；
  - 返回最新状态。

### 4.2 `server/tool/terminal_tool.py` —— 参数 + 分支

- `get_tool_definition()` 增加可选参数：
  - `hook`（bool）：true 则后台启动；
  - `output_file`（string，hook 启动用）：输出重定向文件（工作空间相对路径，如 `.output/xxx.log`；缺省 `.output/hook_<task_id>.log`）；
  - `hook_action`（string：`status`|`cancel`）；
  - `task_id`（string：status/cancel 用）。
- 构造函数新增 `hook_callback`（会话级完成回调，由 chat.py 注入）。
- `execute()` 分支顺序：
  1. `hook_action == "status"` → 返回 `hook_manager.status(task_id)`；
  2. `hook_action == "cancel"` → 返回 `hook_manager.cancel(task_id)`；
  3. `hook` 为真 → 校验/派生 `output_file`，调 `hook_manager.start(..., on_complete=self.hook_callback)`，返回 `{"stdout": "后台任务已启动（hook 模式），输出已重定向到 <file>，任务结束后会自动通知你继续", "task_id": ..., "output_file": ...}`；
  4. 否则保持现有阻塞逻辑不变。

### 4.3 `server/io_/local_executor.py` —— 非阻塞 hook 通道

`LocalExecutorClient` 新增：
- `send_request(user_id, payload)`：把 `tool_exec_request` 的“发送”逻辑（从 `request` 中抽出，`run_coroutine_threadsafe`）独立为非阻塞发送，不等待响应。
- `register_hook(user_id, exec_id, on_done)`：把 `(user_id, exec_id)` 存入 `_pending` 并挂 `add_done_callback`，由既有 `resolve()`（收到 `tool_exec_response`）触发 `on_done`；失败兜底清理。
- `cancel_hook(user_id, exec_id)`：向前端发 `{"type": "tool_exec_cancel", "data": {"exec_id": exec_id}}`（复用线程安全发送）。
- `request()` 保持不变（普通工具仍用阻塞路径）。

### 4.4 `server/io_/workspace_io.py` —— 接口新增无超时执行 + LocalWorkspaceIO 新增 hook 通道

- `WorkspaceIO` 接口新增 `exec_shell_no_timeout(workspace_id, command)`（hook 后台任务专用，**不做 `timeout` 包装、无时长上限**；基类默认返回错误）：
  - `CloudWorkspaceIO`：`await asyncio.to_thread(self.docker_manager.exec_in_workspace, workspace_id, ["sh","-c", command])`（去掉 `timeout N` 包装与 3600 封顶）。
  - `SSHWorkspaceIO`：当前实现已改为 `LocalWorkspaceIO` 的子类（SSH 连接由前端发起，工具调用与本地模式一致委托前端执行），因此 **SSH 不实现 `exec_shell_no_timeout`**，hook 任务自动落入下方 `LocalWorkspaceIO` 分支 → 前端托管分离进程（无时长上限）。
- `LocalWorkspaceIO` 新增：
  - `exec_shell_hook(self, workspace_id, exec_id, command, output_file, timeout, on_done)`：
    - `register_hook(user_id, exec_id, on_done)`；
    - `send_request(user_id, {op:"exec_shell_hook", workspace_id, exec_id, command, output_file, timeout})`。
  - `cancel_exec_hook(self, exec_id)` → `executor.cancel_hook(user_id, exec_id)`。

### 4.5 `server/tool/__init__.py` —— 装配

- `register_builtin_tools` 新增形参 `terminal_hook_callback=None`，构造 `TerminalTool(io, workspace_id, hook_callback=terminal_hook_callback)`（其余参数原样）。
- 无需改动 `_make_handler`（hook 相关参数直接随 kwargs 进 `execute`）。

### 4.6 `server/agent/chat.py` —— 唤醒回调

- `_register_tools` 中构造闭包并传入 `register_builtin_tools(..., terminal_hook_callback=_terminal_hook_done)`：

```python
def _terminal_hook_done(task_id, exit_code, output_file, cancelled=False, error=""):
    tag = "取消" if cancelled else "结束"
    content = (
        f"[terminal hook] 你启动的后台命令已{tag}（exit_code={exit_code}），"
        f"输出已重定向到工作空间文件 {output_file}。"
        f"{('' if not error else ' ' + str(error))}"
        " 请读取该文件，根据结果继续推进你的任务。"
    )
    sender = getattr(session, "sender_id", "") or ""
    if is_member:
        _dispatch_agent_message(
            user_id, [agent_id], content,
            source_agent_id=top_agent_id or agent_id,
            top_agent_id=top_agent_id,
            extra={"session_id": session_id, "sender_id": sender},
        )
    else:
        _dispatch_agent_message(
            user_id, [agent_id], content, "",
            top_agent_id or agent_id, "", {"session_id": session_id},
        )
```

  - 顶部 agent 用 `source_agent_id=""` 避免 `_dispatch_agent_message` 的自发拒绝（目标=自己）；成员用 `source_agent_id=top_agent_id` 走 roster 解析。唤醒后由既有 broker 续跑同一 `session_id`。

### 4.7 `server/ws/endpoints.py`

- 无新增入站消息（取消消息是后端→前端 `tool_exec_cancel`，出站即可）；`tool_exec_response` 分支已存在，`resolve()` 会触发 hook 的 `on_done`。无需改动（除非需要校验，可选加日志）。

### 4.8 前端 `lib/io/local_executor_service.dart`

- 新增 `Map<String, Process> _hookProcesses`。
- `_handleToolExecRequest`：`op == 'exec_shell_hook'` 时走 `_execShellHookDeferred(wsDir, execId, data)` 并直接返回（**不立即回传**）。
- `_execShellHookDeferred`：
  - 解析命令 shell（复用 `isUnixLikePath`/cmd/bash 逻辑，与 `_execShell` 一致）；
  - 用 `_resolveInWorkspace` 解析 output_file 并 `File(fullOut).parent.create(recursive: true)` 建目录；
  - `Process.start(...)`（`workingDirectory`/bash `cd` 处理同 `_execShell`），存入 `_hookProcesses[execId]`；
  - `process.exitCode.then((code){ _hookProcesses.remove(execId); _send(tool_exec_response {exec_id, result:{exit_code: code, stdout:'', stderr:''}}); })`；
  - `ProcessException` → 立即回传 `{error}`（避免后端挂起）。
- `killProcess(execId)`：`_hookProcesses.remove(execId)?.kill()`；kill 后 exit listener 仍会回传（后端据此标记 cancelled）。
- `attach()` 里挂 `ws.onToolExecCancel = (m) => killProcess(exec_id)`。

### 4.9 前端 `lib/io/websocket_service.dart`

- 新增 `void Function(Map<String, dynamic>)? onToolExecCancel;`
- `_handleData` 中 `if (type == 'tool_exec_cancel') { onToolExecCancel?.call(json); return; }`。

### 4.10 提示词文档 `server/prompt/versions/1.0.0/tools/builtin.yaml`

- 更新 `terminal` description：说明 `hook`/`output_file`/`hook_action`/`task_id` 用法与适用场景（长任务：启动后可直接结束本轮，完成后会自动收到 `[terminal hook]` 提示继续）。

### 4.11 测试 `server/tests/test_terminal_hook.py`（新增，轻量）

- 用假 `WorkspaceIO`（`exec_shell` 短暂 sleep 后返回）验证 HookTaskManager 远端路径：`start` → 完成 → `on_complete` 触发、`status` 状态正确。
- 验证 `TerminalTool.execute` 的 `hook_action=status/cancel`、`hook=True` 分支与普通阻塞分支互不影响。

## 5. 假设与边界

- 长任务期间需保持后端在线、本地模式下前端 WS 连接在线；后端重启后进行中 hook 不持久化（会丢失，仅记日志）。
- hook 后台任务在 **local / ssh / cloud 三种模式均无时长上限**：local/ssh 共用前端 `Process.start` 分离进程（不设限）；cloud 走新增 `exec_shell_no_timeout`（去掉 `timeout N` 包装与 3600 封顶）。终止依赖 `hook_action=cancel`（local/ssh=前端 `process.kill()`；cloud=pidfile `kill -TERM`，尽力终止、不保证杀掉全部孙进程）或命令自然结束。
- `output_file` 为工作空间相对路径；路径逃逸由各 IO 层既有守卫（前端 `_resolveInWorkspace` 抛错、云端 docker 容器内路径）兜底。
- 唤醒消息以 `user` 角色注入（与 AskUserQuestion 续跑一致），前端历史中会显示该 `[terminal hook]` 提示。

## 6. 验证步骤

1. 后端单元测试：`python -m pytest server/tests/test_terminal_hook.py -q`（或项目既有测试入口）。
2. 本地模式手动验证（推荐）：
   - 让 agent 调用 `terminal` 带 `hook=true, output_file=.output/long.log, command="ping -n 8 127.0.0.1"` → 立即返回 task_id，tool loop 正常结束；
   - 运行期间用 `read`/文件面板 tail `.output/long.log` 可见实时输出；
   - 命令结束后 agent 自动收到 `[terminal hook] ...` 并继续读取文件推进；
   - `hook_action=status <task_id>` 能查到 running/completed；启动一条长命令后 `hook_action=cancel <task_id>` 能终止并收到“已取消”提示。
3. 云端模式（如有 Docker）验证同一流程 + 取消 pidfile 终止。
4. 回归：普通 `terminal`（无 hook 参数）行为与超时逻辑不变；`redirect_output` 参数行为不变。
