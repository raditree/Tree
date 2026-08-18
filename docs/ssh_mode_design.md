# SSH 运行模式设计（docs/ssh_mode_design.md）

## 目标
为 Tree 项目新增第三种运行模式：**SSH 远程执行**。与现有 云端沙箱（Docker 容器）/ 本地执行（反向 WS）并列，
通过 SSH 连接远程主机执行工具调用（read/write/terminal/git 等）。

## 架构（与现有模式对齐）
现有：`WorkspaceIO` 抽象 → `CloudWorkspaceIO`（Docker）/ `LocalWorkspaceIO`（反向 WS 到前端本地执行器）
新增：`SSHWorkspaceIO`（paramiko 连接远程主机）

```
WorkspaceIO (ABC)
├── CloudWorkspaceIO  云端沙箱（Docker 容器）
├── LocalWorkspaceIO  本地执行（反向 WS → 前端 LocalExecutorService）
└── SSHWorkspaceIO    新增：SSH 远程主机（paramiko）
```

## 模式判定优先级（main._get_workspace_io）
1. `local_executor.is_local(user_id, top_agent_id)` → LocalWorkspaceIO
2. `ssh_executor.is_ssh(user_id, top_agent_id)` → SSHWorkspaceIO
3. 否则 → CloudWorkspaceIO

## SSH 配置模型（DB 表 ssh_connections）
| 列 | 说明 |
|---|---|
| user_id | 用户标识 |
| agent_id | 顶部 agent 标识（模式按顶部 agent 隔离，与本地模式一致） |
| host | 远程主机 |
| port | 端口（默认 22） |
| username | 用户名 |
| auth_type | password \| private_key |
| password | 密码（auth_type=password 时） |
| private_key_path | 私钥路径（auth_type=private_key 时） |
| remote_base_dir | 远程工作目录（默认 ~） |
| created_at / updated_at | 时间戳 |

主键 (user_id, agent_id)。

## SSHWorkspaceIO 方法实现要点（paramiko）
- `read_file(workspace_id, path)` → sftp.open(path).read()，返回 `{exit_code:0, stdout:content, stderr:"", content:content}`
- `write_file(workspace_id, path, content)` → sftp 创建父目录 + 写文件
- `exec_shell(workspace_id, command, timeout)` → exec_command(f"cd {ws_dir} && {command}")
- `exec_argv(workspace_id, argv)` → exec_command(" ".join(shlex.quote(a) for a in argv))
- `grep_search(workspace_id, pattern)` → `grep -rn pattern ws_dir`
- `git_log(workspace_id, limit)` → `cd ws_dir && git log --oneline -n limit`
- `list_files(workspace_id, path)` → `ls -la` / python 递归列目录

**workspace 路径映射（与前端 LocalExecutorService._resolveWorkspaceDir 一致）**：
- 顶部 agent（workspace_id == "top" 或 == 自身 id）→ remote_base_dir
- 其他 agent（成员）→ remote_base_dir/workspaces/{workspace_id}

## SSHConnectionManager
- `register(user_id, agent_id, config)`：保存 DB + 测试连接（连接失败返回错误不激活）
- `unregister(user_id, agent_id)`：关闭连接 + 删除/停用 DB 记录
- `is_ssh(user_id, agent_id)`：DB 中有有效配置且已激活
- `get_connection(user_id, agent_id)`：懒连接 + 断线重连（transport.is_active 检查）

## main.py 接线
1. lifespan 初始化 `_ssh_executor = SSHConnectionManager()`
2. `_get_workspace_io` 三分支
3. `_build_exec_mode_text` 支持 SSH 描述：
   `执行模式：SSH 远程（user@host:port；工作目录 remote_base_dir；私人空间 .self 位于 remote_base_dir/workspaces/{id}/.self）`
4. WebSocket 消息：`register_ssh_executor` / `unregister_ssh_executor`（与 register_local_executor 同模式）

## 前端（第二阶段，可后续）
- SettingsPage 或 agent 管理加 SSH 配置表单（host/port/user/认证/remote_base_dir）
- LocalExecutorService 旁新增 SSHExecutorService：发送 register_ssh_executor
- 电源开关扩展：云端/本地/SSH 三态（或独立 SSH 开关）

## 验收标准
1. `import paramiko` 可用（已装 5.0.0）
2. SSHWorkspaceIO 六个方法在 mock paramiko 下单元测试通过
3. 真实 SSH 主机（若有）read/write/exec/git/list 全链路可用
4. main.py 三分支判定 + exec_mode 文本正确
5. 重启后端后 SSH 配置仍生效（DB 持久化）
