# SSH 运行模式设计（docs/ssh_mode_design.md）

## 目标
为 Tree 项目提供第三种运行模式：**SSH 远程执行**。与现有 云端沙箱（Docker 容器）/ 本地执行（反向 WS）并列，
通过 SSH 连接远程主机执行工具调用（read/write/terminal/git 等）。

**关键约束**：SSH 配置的 IP 是**相对前端机器**的（无论后端部署在本机还是远程服务器都成立）。因此 SSH 连接
由**前端（Flutter + dartssh2，纯 Dart）发起并持有**，后端不再直接连接远端主机，只做配置持久化与模式判定，
工具调用经现有反向 WS（`tool_exec_request` / `tool_exec_response`）委托给前端执行器。

## 架构（与现有模式对齐）
现有：`WorkspaceIO` 抽象 → `CloudWorkspaceIO`（Docker）/ `LocalWorkspaceIO`（反向 WS 到前端本地执行器）
SSH：`SSHWorkspaceIO` 是 `LocalWorkspaceIO` 的**委托子类**，复用本地模式的委托链路，SSH 会话由前端 dartssh2 建立。

```
后端 (Python)                       前端 (Flutter, 发起 SSH 连接)
─────────────────                  ─────────────────────────────
SSH 模式判定 (mode_resolver)
SSHWorkspaceIO ──tool_exec_request──▶ SshExecutorService
   │  (委托)          (反向 WS)           │
   │                                   SshConnectionManager (dartssh2)
   │                                   SshWorkspaceExecutor ──▶ 远端主机
   └─────────── tool_exec_response ◀───┘
```

```
WorkspaceIO (ABC)
├── CloudWorkspaceIO  云端沙箱（Docker 容器）
├── LocalWorkspaceIO  本地执行（反向 WS → 前端 LocalExecutorService）
└── SSHWorkspaceIO    委托 LocalWorkspaceIO（反向 WS → 前端 SshExecutorService，SSH 由前端 dartssh2 发起）
```

## 模式判定优先级（main._get_workspace_io）
1. `local_executor.is_local(user_id, top_agent_id)` → LocalWorkspaceIO
2. `ssh_executor.is_ssh(user_id, top_agent_id)` → SSHWorkspaceIO
3. 否则 → CloudWorkspaceIO

优先级 `local > ssh > cloud`；同顶部 agent 下 local 与 ssh 互斥（由 mode_resolver 保证）。

## SSH 配置模型（DB 表 ssh_connections）
| 列 | 说明 |
|---|---|
| user_id | 用户标识 |
| agent_id | 顶部 agent 标识（模式按顶部 agent 隔离，与本地模式一致） |
| host | 远程主机（相对前端机器可达） |
| port | 端口（默认 22） |
| username | 用户名 |
| auth_type | password \| private_key |
| password | 密码（auth_type=password 时，落库加密） |
| private_key_path | 私钥路径（auth_type=private_key 时） |
| remote_base_dir | 远程工作目录（默认 ~） |
| created_at / updated_at | 时间戳 |

主键 (user_id, agent_id)。持久化在 `server/data/ssh_store.py`（SQLite）。

## SSHWorkspaceIO（后端：委托前端）
`SSHWorkspaceIO` 继承 `LocalWorkspaceIO`，七个方法（read/write/exec_shell/exec_argv/grep/git/list + hook）
全部复用父类逻辑：把工具调用包装成 `tool_exec_request` 经反向 WS 推给前端，等待 `tool_exec_response` 回传。
后端不再执行任何 SSH/SFTP/命令解析逻辑。

## SSHConnectionManager（后端：仅配置/模式管理，不持有连接）
- `register(user_id, agent_id, config)`：仅持久化配置并激活（**不再测试连接**，连接测试由前端完成）
- `unregister(user_id, agent_id)`：删除配置并停用
- `is_ssh(user_id, agent_id)`：存在持久化配置即为 SSH 模式
- `get_config(user_id, agent_id)`：读取配置（前端 `syncRegistration` 时使用）

## 前端（已实现）
- **SshConnectionManager（lib/io/ssh_connection_manager.dart）**：按 top_agent_id 懒建立 dartssh2 `SSHClient`，
  transport 失活自动重建；`testConnection()` 用于启用时前端本机建连验证。
- **SshWorkspaceExecutor（lib/io/ssh_workspace_executor.dart）**：SFTP/exec 执行工具；路径映射与穿越防护
  复刻后端原语义（顶部 agent → remote_base_dir；成员 → remote_base_dir/workspaces/{workspace_id}）。
- **SshExecutorService（lib/io/ssh_executor_service.dart）**：`enable()`（前端建连测试 → 注册 → 缓存连接）、
  `disable()`、`syncRegistration()`、`_handleToolExecRequest()` 执行并回传 `tool_exec_response`。
- **WebSocketService**：`tool_exec_request` 支持多处理者（本地/SSH 共存，按模式路由）。

## 后端接线
1. `io_/mode_resolver.py` / `tool/__init__.py` / `io_/routes.py`：SSH 分支构造 `SSHWorkspaceIO(state.local_executor, state.ws_manager, user_id)`。
2. `ws/endpoints.py`：`register_ssh_executor` / `unregister_ssh_executor` 在 `ssh_manager.register/unregister` 后同步
   `local_executor.register_ssh/unregister_ssh`（保证委托守卫通过）。
3. `io_/local_executor.py`：`_ssh_users` 登记 SSH 模式，`request()` 守卫放行 local/ssh 共同的前端委托通道。
4. `main.py`：不再持有/关闭 SSH 连接。

## 验收标准
1. 前端 `flutter pub get` 解析 `dartssh2 2.8.2`（兼容本项目 Dart 2.19.6 锁定的 meta 1.8.0）。
2. `flutter analyze` 无新增错误；`pytest server/tests/` 全量通过（改写后的前端委托用例）。
3. 启用 SSH 模式：前端本机建连测试通过（IP 相对前端）；不可达主机快速返回失败。
4. 真实 SSH 主机（若有）read/write/exec/git/list 全链路经前端执行可用。
5. 后端部署在远程机器时，前端仍从本机发起 SSH 连接并正常执行。
6. 重启后端后 SSH 配置仍生效（DB 持久化）。
