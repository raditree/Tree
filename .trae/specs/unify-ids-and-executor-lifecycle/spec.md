# ID 体系统一与多 Team 执行器重构 Spec

## Why

现行实现存在六类已确诊故障：①前端执行器为"单槽位"（单一 `_currentTopAgentId` 上下文），多 team 无法同时工作，跨模式请求被误路由或超时；②id 链路缺失（IO 构造点不传 `agent_id`、payload 缺 `top_agent_id`），SSH 模式归属校验全部失效；③上传接口固定写入 docker 沙箱（[routes.py#L419-498](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/routes.py#L419-L498)），SSH/local 模式下 agent 无法读取；④跨 team 消息接收方无对应会话导致 UI 不显示；⑤文件栏 `list_files`/`get_file_content` 只有 local/docker 两分支（[routes.py#L211-L268](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/routes.py#L211-L268)），SSH 模式漏到 docker 分支显示沙箱文件（git 端点因正确调 `resolve_mode` 而正常）；⑥SSH teammate 的 `list_members` 仅显示数量（team_store 查询依赖的 `top_agent_id` 上下文缺失 + roster 回退读远端失败）。另认证为无状态 JWT（[auth.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/ws/auth.py)），撤销表仅内存、无多设备 token 管理。

## 术语与 ID 模型（全局约定）

自本 Spec 起，`top_agent_id` 全部更名为 **`team_id`**（后端 payload 字段、REST query、函数参数、缓存 key、前端 Dart 标识符、注释文档）。

| id 名称 | 作用 | 生成时机 |
| --- | --- | --- |
| `user_id` | 区分不同用户 | 用户注册时 |
| `connection_id` | 区分单个用户的不同 WS 连接 | WS 连接创建时（后端生成） |
| `team_id` | 区分单个用户的不同 top agent（**原 `top_agent_id` 更名**）；"创建 top agent"语义改为"创建 team" | team 创建时 |
| `session_id` | 区分 team 下不同 session | session 创建时 |
| `agent_id` | 区分 user 下的不同 agent；**用户自身的 agent_id = "0"**（统一消息接口中用户直发以此为标记） | agent 创建时 |
| `tool_id` | 区分单个 agent 下不同工具调用（**现 `exec_id` 更名/升格**，继续充当委托链配对 key） | tool loop 中每次调用 |
| `uuid` | 按具体情况而定 | 按具体情况而定 |

**BREAKING**：WS/REST payload 字段 `top_agent_id` → `team_id`、`exec_id` → `tool_id`。前后端同仓库同步升级，不保留兼容读取层；发布说明中标注。

`connection_id` 用途收敛为：断连清理（执行器注册、pending 归属）、多设备/多连接审计。消息回发仍按 user 广播 + 前端按 team 过滤，不做连接级寻址（避免过度设计）。

## What Changes

- **ID 透传与存在性校验**：IO 构造点（`tool/__init__.py` 工具装配、`io_/routes.py` 文件/git 端点）补传 team_id；所有入口（WS 消息、REST、内部 dispatch、前端执行器 handler）对 `user_id/team_id/session_id/agent_id/tool_id` 做存在性校验，缺失即拒绝并回错，不再以空串降级放行。
- **前端执行器：单槽位 → per-team 注册表**：`LocalExecutorService`/`SshExecutorService` 状态改为 `Map<team_id, ExecutorState>`（enabled/baseDir/config/registered）；**不在启动或切换 agent 时全量加载**，首次向某 team 发消息（或该 team 即将收到消息）时懒创建；维护生命周期（team 删除时注销清理，应用退出时统一收口）；SSH 连接管理器 `connect()` 增加 in-flight 去重；归属校验改为"请求 team ∈ 本前端已注册且启用的 team 集合"。
- **后端委托链按 (user_id, team_id) 隔离**：`_pending`/`_last_ok`/`_consecutive_timeouts` 全部收窄到二元组粒度；`unregister`/`unregister_ssh` 只失效本 team 的 pending；自动停用覆盖 SSH；WS 断连按 connection_id 清理执行器注册；`send_message` 每连接写超时 + 失败剔除。
- **文件 IO 三模式一致**：上传/下载/列表按 mode 分派——cloud 走 docker 沙箱（保留），local/ssh 统一经 WorkspaceIO（SSH 由前端执行器 SFTP 写远端 `.input/`）；文件栏在 SSH 模下列远端 workspace；大文件走分片上传通道（init/chunk/complete），小文件保留单请求。
- **agentspace 布局与 .self/沙箱策略统一**：**所有 agent（top 与成员）工作根目录均为其 base**（local=用户指定本机目录、ssh=远端用户指定目录、cloud=沙箱 `/workspace`），不按 agent 隔离工作区；base 下创建 `agentspace/` 集中存放各 agent 私有数据，`.self` 统一位于 `agentspace/<agent_id>/.self/`；**`.self` 允许所有 agent 查看，不做按 agent 的路由与读权限隔离，系统在提示词中直接给出各 agent 的 `.self` 绝对路径**；右侧文件栏展示 base/（隐藏 agentspace/ 与 .git），terminal 工作目录为 base；local/ssh 不创建 docker 沙箱、不在沙箱执行命令；cloud 每 team 仅一个沙箱、沙箱内同构路径；模式在 team 首次发送消息时锁定，锁定后按需创建目录/cloud 沙箱。
- **消息 active 语义**：消息发送接口显式携带 `active` 参数；主动发起（active=true）时复用消息发送接口反向推送最后总结（标记 active=false）。
- **接收方会话保障**：跨 team 消息投递时确保接收方 session 存在（不存在则创建），推送带 session 元数据；前端收到未知 session 消息时自动创建会话并显示。
- **auth_token 生命周期**：每用户 token 列表（DB 持久化），支持多设备同时在线；签发/校验/撤销/过期清理全生命周期管理；REST 与 WS 统一校验。
- **工具调用链修复**：SSH hook 路由由 `isinstance` 改为显式 mode 判断（输出重定向/取消恢复可用）；`tool_id` 贯穿 pending/hook/取消/响应；SSH 侧补路径穿越防护。

## Impact

- Affected specs: 取代 `.trae/specs/stress-test-ssh-io-toolchain`（压测方案作废，以本重构为先）。
- Affected code:
  - 后端：`server/io_/`（local_executor、mode_resolver、routes、workspace_io、ssh_workspace_io）、`server/ws/`（endpoints、ws_manager、auth）、`server/agent/chat.py`、`server/tool/`（team_tool、`__init__`、hook_manager）、`server/data/`（team_store、新增 token store）、`server/configs/app.yaml`（token 配置）。
  - 前端：`lib/io/`（local_executor_service、ssh_executor_service、ssh_connection_manager、ssh_workspace_executor、websocket_service、api_service）、`lib/ui/`（message_panel、file_panel、file_sync_button、main_page）。

## ADDED Requirements

### Requirement: ID 模型与存在性校验

系统 SHALL 按上表统一 ID 命名，并在所有边界入口强制校验 id 存在性。

#### Scenario: 缺 id 拒绝
- **WHEN** WS 消息 / REST 请求 / 内部 dispatch 缺少必需 id（如 tool_exec_request 无 team_id 或 tool_id）
- **THEN** 拒绝处理并回传明确错误（不再以空串继续执行或被前端空值守卫放行）

#### Scenario: payload 携带 team_id
- **WHEN** 后端构造 tool_exec_request（工具装配与文件/git 端点）
- **THEN** payload 携带非空 `team_id`，前端仅当 team ∈ 已注册启用集合时接管

### Requirement: per-team 前端执行器（懒创建 + 生命周期）

前端执行器 SHALL 以 team 为单位维护执行状态，支持多 team 并行、多模式混布。

#### Scenario: 多 team 并行
- **WHEN** 同一用户同一前端的 team A（SSH）与 team B（local）同时有工具调用请求
- **THEN** 两请求分别由各自 team 的执行器上下文正确接管执行，互不串扰、无误路由

#### Scenario: 懒创建
- **WHEN** 应用启动或切换 agent 视图
- **THEN** 不批量加载/注册全部 team 的执行器；仅当首次向某 team 发消息（或其即将接收消息）时创建该 team 的执行器状态并注册

#### Scenario: 生命周期收口
- **WHEN** team 被删除或应用退出
- **THEN** 对应执行器状态注销（后端 unregister、连接关闭、持久化清理按语义区分），无残留注册

### Requirement: 后端委托链隔离与健壮性

后端委托链 SHALL 按 (user_id, team_id) 隔离状态，失联可快速失败且不误伤。

#### Scenario: 失联快速失败
- **WHEN** 某 team 的前端执行器失联（连续超时/断连未注销）
- **THEN** 自动停用该 team 执行器（local 与 SSH 同规则）并回退云端，其他 team 不受影响

#### Scenario: 注销不误伤
- **WHEN** 注销/重注册某 team 的执行器
- **THEN** 仅失效该 team 的 pending 请求，同用户其他 team 的在途请求不受影响

#### Scenario: 死连接不阻塞
- **WHEN** 某条 WS 连接写入阻塞
- **THEN** 写超时后剔除该连接，不无限堆积发送协程，同用户其他连接投递正常

### Requirement: 文件 IO 三模式一致

上传/下载/文件列表 SHALL 在 local/ssh/cloud 三模式下语义一致，agent 可读取用户上传的文件。

#### Scenario: SSH 模式上传可读
- **WHEN** SSH 模式下用户上传文件
- **THEN** 文件经执行器写入远端 workspace `.input/yyyymmdd/`，agent 可读取；不再落入后端沙箱

#### Scenario: SSH 模式文件栏显示远端
- **WHEN** SSH 模式下打开右侧文件栏
- **THEN** 列出/读取的是远端 workspace 文件（与 git 历史面板同源），而非后端沙箱

#### Scenario: 大文件分片上传
- **WHEN** 上传超过阈值（`upload.chunk_threshold`，默认 8MB，可配置）的文件
- **THEN** 走分片通道（init/chunk/complete）：cloud 由后端组装落沙箱，local 由执行器本地直写，SSH 由执行器经 SFTP 按偏移续写；完成时校验分片数与总大小，失败分片可重试

### Requirement: agentspace 布局与 .self/沙箱策略

所有 agent（top 与成员）SHALL 以其 base 为工作根目录（local=用户指定本机目录、ssh=远端用户指定目录、cloud=沙箱 `/workspace`），不按 agent 隔离工作区；base 下 SHALL 创建 `agentspace/` 集中存放各 agent 私有数据；`.self` 统一位于 `agentspace/<agent_id>/.self/`，允许所有 agent 查看，系统直接告知各 agent 其 `.self` 绝对路径。

#### Scenario: agentspace 创建与文件栏/terminal 语义
- **WHEN** local/ssh 模式 agent 首次使用（模式锁定后）
- **THEN** 在 base 下创建 `agentspace/`；top 与成员的 terminal/文件操作工作根均为 base；右侧文件栏展示 base/（隐藏 `agentspace/` 与 `.git`）

#### Scenario: .self 集中与全可见
- **WHEN** 任意 agent（top 或成员）读写自身 .self（todo/spec/记忆/roster/activity.log）
- **THEN** 其 .self 位于 `<base>/agentspace/<agent_id>/.self/`，系统提示词直接给出该绝对路径，不做相对路径自动路由；其他 agent 也可查看（不设 agent 间读权限隔离）

#### Scenario: local/ssh 无沙箱
- **WHEN** local/ssh 模式运行（.self 读写、activity.log、roster 等）
- **THEN** 不创建 docker 沙箱、不在沙箱执行命令，全部经 WorkspaceIO 直接落在用户本机/远端

#### Scenario: 模式锁定与沙箱创建时机
- **WHEN** team 收到第一条消息
- **THEN** 锁定该 team 的模式并持久化；cloud 在此时按需创建沙箱（每 team 一个，`/workspace` 挂载 base，沙箱内 `/workspace/agentspace/<agent_id>/.self` 同构），local/ssh 仅创建 `agentspace/` 目录

### Requirement: 消息 active 语义与接收方会话保障

消息发送接口 SHALL 显式区分主动/被动语义，并保证接收方会话可见。

#### Scenario: 主动消息反向推送总结
- **WHEN** 以 active=true 发起消息（用户直发或 agent 主动派发）
- **THEN** 复用消息发送接口反向推送该会话最后总结，标记 active=false；被动触发（active=false）不推送

#### Scenario: 跨 team 消息 UI 可见
- **WHEN** 消息送达尚无对应会话的接收方 agent（含跨 team）
- **THEN** 后端确保 session 存在并推送会话元数据，前端自动创建会话条目并显示消息

### Requirement: auth_token 生命周期管理

认证 SHALL 支持每用户多 token（多设备同时在线）与全生命周期管理。

#### Scenario: 多设备登录
- **WHEN** 同一用户在多设备分别登录
- **THEN** 各设备持有独立 token，均有效；单设备登出仅撤销该 token

#### Scenario: 校验与过期
- **WHEN** REST/WS 携带 token 访问
- **THEN** 校验 token 存在于该用户 token 列表、未撤销、未过期；过期/撤销的 token 被拒绝，列表定期与惰性清理

### Requirement: 工具调用链修复

工具调用 SHALL 以 tool_id 全链路寻址，SSH 模式 hook 与路径防护与 local 模式语义一致。

#### Scenario: SSH hook 可用可取消
- **WHEN** SSH 模式执行 hook 任务（terminal 长任务）与取消
- **THEN** 输出正确落盘、取消能终止远端任务（按显式 mode 路由，不再因继承关系误入 local 分支）

#### Scenario: 工具链路径防护
- **WHEN** SSH 模式执行 grep 等带路径参数的工具
- **THEN** 路径经穿越校验，与 local 模式防护语义一致

## 开放问题决议（已确认）

1. **tool_id 与 exec_id**：`tool_id` 即现 `exec_id` 的更名/升格，不新增第二层 id。
2. **旧数据迁移**：不做兼容读取/迁移（项目未正式发布，现有 DB 均为测试数据）；修改完成后直接移除旧测试数据（DB 测试库与旧目录 `base/.self`、`base/workspaces/<id>/`），不保留兼容路径。
3. **模式解锁**：允许改模式；变更时清理旧模式资源（沙箱/执行器注册）并重新锁定。
4. **SSH 上传通道容量**：实现大文件分片上传（见「大文件分片上传」场景），阈值 `upload.chunk_threshold` 默认 8MB。
5. **token 数量上限**：不设并发设备上限，仅按过期与手动撤销清理。
6. **agent_id="0" 兼容面**：仅在接口层归一，不订正历史数据（旧数据按第 2 条清除）。
