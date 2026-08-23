# SSH 配置改为"相对前端"（前端建连 + 后端执行委托）

## 摘要

当前 SSH 模式的 TCP 连接由**后端 paramiko** 发起，SSH 配置 IP 是"相对后端"的。目标改为**由前端（Flutter）用纯 Dart 的 `dartssh2` 库发起并持有 SSH 连接**，使 IP 相对前端机器（无论后端部署在本机还是远程服务器都成立）。

实现方式复用现有本地模式（local）的「后端委托前端执行」链路 `tool_exec_request` / `tool_exec_response`：

- **后端**：SSH 模式下不再用 paramiko 连接远端，而是把工具调用通过现有反向 WS 委托给前端；仅负责 SSH 配置持久化与模式判定。
- **前端**：新增 Dart SSH 连接管理器与 SSH 工具执行器；启用 SSH 模式时在前端本机测试连接（真正"相对前端"的验证）；收到后端 `tool_exec_request` 后经自身 SSH 会话执行工具并回传 `tool_exec_response`。

## 当前进度（2026-08-23 复核）

**后端（server/）已完成 ✅**
- [local_executor.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/local_executor.py)：`_ssh_users` + `register_ssh/unregister_ssh/is_ssh` + `_has_frontend_executor` 守卫（local/ssh 共用委托通道）。
- [ssh_connection_manager.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/ssh_connection_manager.py)：去 paramiko，仅配置持久化 + `is_ssh/get_config/register/unregister`，`register()` 不再测试连接。
- [ssh_workspace_io.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/ssh_workspace_io.py)：`SSHWorkspaceIO(LocalWorkspaceIO)` 委托子类，无任何 paramiko 执行逻辑。
- [endpoints.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/ws/endpoints.py#L297-L348)：`register_ssh_executor`/`unregister_ssh_executor` 已接入 `register_ssh/unregister_ssh`。
- [mode_resolver.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/mode_resolver.py#L68-L72)、[tool/__init__.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/__init__.py#L173-L174)、[io_/routes.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/routes.py#L986-L1033)：三个构造点统一为 `SSHWorkspaceIO(state.local_executor, state.ws_manager, user_id)`。
- [main.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/main.py)：已移除 `ssh_manager.close_all()`。
- server/ 目录已无 paramiko 引用。

**前端（lib/）已完成 ✅**
- [pubspec.yaml](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/pubspec.yaml)：已加 `dartssh2: 2.8.2`（`flutter pub get` 已通过，规避 meta 冲突，见风险 1）。
- 新增 [ssh_connection_manager.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/ssh_connection_manager.dart)：Dart SSH 连接管理器（懒建连/缓存/失活重建/testConnection）。
- 新增 [ssh_workspace_executor.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/ssh_workspace_executor.dart)：SFTP/exec 执行 + 路径映射/穿越防护。
- [websocket_service.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/websocket_service.dart)：`tool_exec_request` 已改多处理者（add/removeToolExecRequestHandler）。
- [local_executor_service.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/local_executor_service.dart)：改用多处理者 + SSH 模式守卫。
- [ssh_executor_service.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/ssh_executor_service.dart)：已重写，接入建连/执行/注册同步。
- [ssh_config_dialog.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/ssh_config_dialog.dart)：主机地址提示"需从前端所在机器可达（IP 相对前端）"。

**验证 ✅**
- `flutter pub get` 成功（锁定 dartssh2 2.8.2）；`flutter analyze` 无新增问题（仅 2 个既有 info，非本次改动文件）。
- `pytest server/tests/` 全量 289 通过（含改写后的 test_ssh_workspace_io.py 委托用例）。
- [docs/ssh_mode_design.md](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/docs/ssh_mode_design.md) 已同步为"前端 dartssh2 建连 + 后端委托"架构。

## 现状分析（基于 Phase 1 探索的事实）

### 三运行模式（按 `(user_id, top_agent_id)` 判定，`local > ssh > cloud`）
- cloud：后端 `CloudWorkspaceIO` 走 Docker 容器（[workspace_io.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/workspace_io.py)）。
- local：后端 [LocalWorkspaceIO](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/workspace_io.py#L320-L409) 经 [LocalExecutorClient.request()](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/local_executor.py#L181-L276) 推 `tool_exec_request` 到前端，前端 [LocalExecutorService](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/local_executor_service.dart) 在本机执行并回传 `tool_exec_response`。
- ssh：后端 [SSHWorkspaceIO](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/ssh_workspace_io.py) 经 [SSHConnectionManager](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/ssh_connection_manager.py)（paramiko）直接连接远端主机执行。**IP 相对后端**。

### 关键事实
1. `tool_exec_request`/`tool_exec_response` 是模式无关的通用链路；前端 [WebSocketService._handleData](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/websocket_service.dart#L95-L113) 把 `tool_exec_request` 路由到**单个**回调 `onToolExecRequest`，当前仅 `LocalExecutorService.attach()` 设置它。
2. 后端注册链路：[endpoints.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/ws/endpoints.py#L297-L348) 的 `register_ssh_executor` 调 `ssh_manager.register()`，内部先 `test_connection()`（paramiko）再持久化。
3. `SSHWorkspaceIO` 构造点共 3 处：[mode_resolver.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/mode_resolver.py#L68-L71)、[tool/__init__.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/__init__.py#L168-L171)、[io_/routes.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/routes.py#L983-L992)。
4. SSH 配置持久化在 [ssh_store.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/data/ssh_store.py)（SQLite），与连接无关，保留复用。
5. 前端 `SshExecutorService` 已持久化 `enabled`/`config` 到 SharedPreferences，`attach()` 已绑定 WS（[message_panel.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/message_panel.dart#L309-L316)）。
6. 路径映射（后端 SSH 语义）：顶部 agent（`workspace_id == top_agent_id`）→ `remote_base_dir`；成员 → `remote_base_dir/workspaces/{workspace_id}`，含穿越防护（[ssh_workspace_io.py#L52-L94](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/ssh_workspace_io.py#L52-L94)）。
7. **技术可行性**：`dartssh2` 是纯 Dart 的 SSH/SFTP 客户端，支持 Windows 桌面；`dartssh2 2.18.0` 要求最低 Dart SDK 2.17，与本项目 Dart `>=2.19.6 <3.0.0` 兼容。pub.dev 上同名 `ssh2` 是原生插件（仅 iOS/Android），不可用。

## 目标架构

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
- SSH 连接、连接测试、工具执行全部发生在前端 → IP 相对前端。
- 后端只做：配置持久化、模式判定、委托转发。

## 改动清单

### 一、后端（server/）

**1. [io_/local_executor.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/local_executor.py) — 前端执行器客户端同时登记 SSH 模式**
- 新增 `_ssh_users: Dict[str, Set[str]]`（user_id -> 已注册 SSH 的 top_agent_id 集合）。
- 新增方法：`register_ssh(user_id, top_agent_id)`、`unregister_ssh(user_id, top_agent_id)`、`is_ssh(user_id, top_agent_id=None)`。
- 修改 `request()` 守卫：`if not self.is_local(user_id)` → `if not (self.is_local(user_id) or self._ssh_users.get(user_id))`，保证 SSH 模式下委托请求不因"未注册本地执行器"而失败。
- `_register_timeout()` 自动停用逻辑**只作用于 local 注册**（不动 SSH 注册，避免静默回退云端误伤 SSH 用户；SSH 侧冷启动短超时仍快速失败，见决策 4）。
- 更新类 docstring：该客户端同时服务 local / ssh 两种"前端执行"模式。

**2. [io_/ssh_connection_manager.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/ssh_connection_manager.py) — 去掉 paramiko，仅保留配置/模式管理**
- 删除：`import paramiko`、`_build_connect_args`、`test_connection`、`_clients`/`_lock`、`_drop_client`、`get_connection`（客户端缓存全部移除）。
- `register()`：去掉 `test_connection`，仅持久化配置（`ssh_store.save_connection`），仍返回 `(True, "")`。
- 保留：`is_ssh`、`get_config`、`unregister`。
- 更新模块 docstring（不再由后端建立连接）。

**3. [io_/ssh_workspace_io.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/ssh_workspace_io.py) — 改为委托实现**
- `class SSHWorkspaceIO(LocalWorkspaceIO)`：与 local 相同的 `(local_executor, ws_manager, user_id)` 构造；七个方法全部继承（委托到前端）。
- 删除全部 paramiko 执行逻辑（SFTP/exec/grep/git/ls 解析、路径映射等）。
- 更新模块 docstring：SSH 模式下后端仅转发，连接与执行由前端 dartssh2 完成。

**4. [ws/endpoints.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/ws/endpoints.py#L297-L348) — 注册/注销链路调整**
- `register_ssh_executor`：`ssh_manager.register()` 成功后追加 `state.local_executor.register_ssh(user_id, top_agent_id)`（使委托守卫通过）；其余（互斥校验、清会话缓存、ack）不变。连接测试改由前端完成，后端不再测试。
- `unregister_ssh_executor`：`ssh_manager.unregister()` 后追加 `state.local_executor.unregister_ssh(user_id, top_agent_id)`。

**5. [io_/mode_resolver.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/mode_resolver.py#L68-L71)**
- `build_workspace_io` 的 ssh 分支改为：`SSHWorkspaceIO(state.local_executor, state.ws_manager, user_id)`。

**6. [tool/__init__.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tool/__init__.py#L168-L171)**
- ssh 分支构造改为 `SSHWorkspaceIO(state.local_executor, state.ws_manager, user_id)`（去掉 `state.ssh_manager` 实参）。

**7. [io_/routes.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/routes.py#L983-L992)**
- SSH 模式 git_log 委托构造改为 `SSHWorkspaceIO(state.local_executor, state.ws_manager, user_id)`。

**8. [main.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/main.py#L150-L158)**
- 移除关闭时 `state.ssh_manager.close_all()` 调用（后端已无持连接）。

**9. requirements**：确认无其他 paramiko 引用后，从依赖中移除 `paramiko`（实现时以 grep 结果为准）。

### 二、前端（lib/）

**10. [pubspec.yaml](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/pubspec.yaml)**
- 新增 `dartssh2`（当前已写 `2.11.0`，fe1 进行中）。
- 版本说明：`dartssh2 >=2.12.0` 依赖 `meta ^1.16.0`，与本项目 Flutter SDK 锁定的 `meta 1.8.0` 冲突（Dart 2.19.6）；2.11.0 也要求 `meta ^1.15.0`。**若 `flutter pub get` 报 meta 冲突，回退锁定 `dartssh2: 2.8.2`**（依赖 `meta ^1.1.6`，兼容 1.8.0，min Dart 2.14）。
- 风险缓解见"风险"节第 1 条。

**11. 新增 [lib/io/ssh_connection_manager.dart] — Dart SSH 连接管理器**
- 按 top_agent_id 懒建立 dartssh2 `SSHClient`，transport 失活自动重建（对齐后端原语义）。
- `Future<(bool, String)> testConnection(Map config)`：建立→关闭，验证主机/端口/认证（用于启用时前端侧测试）。
- `Future<SSHClient> connect(String topAgentId, Map config)`、`SSHClient? getClient(String topAgentId)`、`Future<void> close(String topAgentId)`、`Future<void> closeAll()`。
- 认证：password 用 `onPasswordRequest`；key 用 `SSHKeyPair`（从 `private_key_path` 读取 PEM）。dartssh2 精确 API 以实现时查 2.18.0 文档为准。

**12. 新增 [lib/io/ssh_workspace_executor.dart] — SSH 工具执行器**
- 覆盖本地执行器同款操作集（后端在 ssh 模式也会发这些 op）：`list_files / read_file / read_file_bytes / write_file / exec_shell / exec_argv / grep_search / git_log / git_branches`。
- 路径映射与穿越防护**完全复刻**后端原 `SSHWorkspaceIO` 语义（`remote_base_dir`；成员 → `remote_base_dir/workspaces/{workspace_id}`），避免行为回归。
- 返回结果结构与后端/本地执行器一致（`{exit_code, stdout, stderr}`、`{error}`、`{files}`、`{commits}`、`{content_base64}` 等）。

**13. [lib/io/websocket_service.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/websocket_service.dart) — tool_exec_request 支持多处理者**
- 把单一 `onToolExecRequest` 回调改为 `List` + `addToolExecRequestHandler()` / `removeToolExecRequestHandler()`；`_handleData` 遍历调用。

**14. [lib/io/local_executor_service.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/local_executor_service.dart)**
- `attach()` 改用 `ws.addToolExecRequestHandler(_handleToolExecRequest)`。
- `_handleToolExecRequest()` 开头加守卫：`if (SshExecutorService.instance.enabled) return;`（当前顶部 agent 处于 SSH 模式时交给 SSH 执行器，避免双处理）。import `ssh_executor_service.dart`（无循环依赖）。

**15. [lib/io/ssh_executor_service.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/ssh_executor_service.dart) — 接入建连与执行**
- 持有 `SshConnectionManager` + `SshWorkspaceExecutor` 引用。
- `attach(ws)`：保留 `_ws`，追加 `ws.addToolExecRequestHandler(_handleToolExecRequest)`。
- `enable(config)`：① 前端本机 `testConnection(config)`（失败即返回 `{success:false, message}`，不再发后端）；② 测试通过后发送 `register_ssh_executor` 等待 ack；③ ack 成功则建立并缓存 SSH 连接。
- `disable()`：关闭 SSH 连接 + 发送 `unregister_ssh_executor`。
- `syncRegistration()`：enabled 时重建 SSH 连接并重发注册（配置后端已持久化）。
- 新增 `_handleToolExecRequest(msg)`：取 `exec_id/op/workspace_id/data` → `SshWorkspaceExecutor` 执行 → 回传 `tool_exec_response`（格式对齐 LocalExecutorService）。
- `cleanup()`：`closeAll()` + `removeToolExecRequestHandler`。
- 更新 docstring：SSH 连接由前端发起，IP 相对前端。

**16. UI 文案（[ssh_config_dialog.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/ui/widgets/ssh_config_dialog.dart)）**
- 主机地址 hint 补充"（从前端所在机器可达）"，明确 IP 相对前端。

### 三、测试与文档

**17. [server/tests/test_ssh_workspace_io.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/tests/test_ssh_workspace_io.py)**
- 由"mock paramiko 执行"改写为"mock 前端执行器委托"：验证 SSHWorkspaceIO 七方法把请求转发给 `local_executor.request()` 且结果透传。
- 若存在针对 `ssh_connection_manager` 连接缓存/探活重连的用例，按新职责删除或改写为"配置持久化 + is_ssh/get_config"。

**18. 设计文档同步**：`docs/ssh_mode_design.md` 中"后端 paramiko 直连远端"的描述更新为"前端 dartssh2 建连 + 后端委托"（仅更新描述，不新增文档）。

## 关键决策与假设

1. **复用 `LocalExecutorClient`（state.local_executor）作为 local/ssh 共同的前端委托通道**：WS 消息格式与前端路由天然按模式区分，无需新增一条通道；改动集中在 `register_ssh`/守卫。
2. **保留 `SSHWorkspaceIO` 类名**（作为 `LocalWorkspaceIO` 子类），避免改动 `mode_resolver`/`tool`/`routes` 的类型判定与可读性。
3. **连接测试迁移到前端**：`enable()` 先在前端建连测试，失败即止；后端 `register` 不再测试（后端也无法验证"相对前端"的可达性）。
4. **SSH 超时不自动停用**：`_register_timeout` 只停用 local 注册；SSH 侧沿用冷启动短超时快速失败（约 15s），不静默回退云端（SSH 是用户显式选择的执行位置）。
5. **前端路由限制沿用现状**：`tool_exec_request` 不含 top_agent_id，前端按当前选中顶部 agent 的模式分发（与本地模式相同约束，不在本次范围扩展）。
6. **`read_file_bytes` 等后端可能直接下发的 op** 由前端 SSH 执行器一并覆盖（超集，无副作用）。

## 风险与缓解

1. **dartssh2 传递依赖的 meta 版本冲突**：`dartssh2 >=2.12.0` 依赖 `meta ^1.16.0`（2.11.0 亦要求 `^1.15.0`），与本项目 Flutter SDK 锁定的 `meta 1.8.0`（Dart 2.19.6）冲突。缓解：`flutter pub get` 失败时锁定 `dartssh2: 2.8.2`（依赖 `meta ^1.1.6`、min Dart 2.14）。
2. **dartssh2 API 差异**：exec 退出码获取、SFTP mkdir/write、私钥 PEM 解析的精确 API 需以所选版本文档为准（实现第一步先写最小连通性冒烟）。
3. **委托链路由错误导致双执行/漏执行**：通过多处理者 + local 侧守卫（`SshExecutorService.enabled`）保证互斥；验证阶段覆盖 local 回归。
4. **Windows 7 + Dart 2.19 编译**：`dartssh2` 纯 Dart 无原生代码，风险低；仍需 `flutter analyze` + Windows 构建验证。

## 验证步骤

1. **依赖解析**：`flutter pub get` 成功且锁定 dartssh2（若失败按风险 1 处理）。
2. **前端静态检查**：`flutter analyze` 无新增错误。
3. **后端测试**：`pytest server/tests/test_ssh_workspace_io.py` 通过（改写后的委托用例）。
4. **回归**：本地模式（local）开关 + 工具执行不回归（多处理者与守卫改动）。
5. **手动端到端（本机后端）**：启用 SSH 模式 → 前端建连测试通过（可达主机）→ 触发 read_file/exec_shell → 结果正确回显；不可达主机 → enable 快速返回失败文案。
6. **远程后端场景**：后端部署到远程机器，前端仍从本机发起 SSH 连接并正常执行（验证"IP 相对前端"）。
