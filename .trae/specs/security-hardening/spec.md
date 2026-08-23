# 安全加固 Spec

## Why

全量安全审查发现多项后端越权与敏感数据暴露缺陷：工作空间接口缺少归属校验（可任意执行他人容器命令）、SSH read/write 工具放行 `..` 路径穿越、WebSocket 提问回答缺乏归属校验、账号状态接口泄露密码哈希、SSH 密码明文落库；另登录接口无速率限制、CORS 配置 `allow_origins=["*"]` 与 `allow_credentials=True` 组合不规范。

## What Changes

- 为 `io_/routes.py` 全部工作空间/文件/Git 端点增加「当前用户 → 工作空间归属」授权校验，拒绝访问非本人（或非其团队成员）的工作空间。
- 收紧 `tool/read_tool.py`、`tool/write_tool.py` 文本路径白名单，拒绝 `..` 段与绝对路径；SSH 远端路径在拼接前做归一化与根目录约束。
- 在 WebSocket `user_answer` / `cancel_question` 分支校验 `pending["user_id"] == 连接用户`，不符则拒绝。
- `/api/auth/account/status` 响应剔除 `password_hash` 与 `salt` 敏感字段。
- SSH 密码改为对称加密落库（引用密钥解密后用于连接），不再明文存储。
- 为 `/api/auth/login`、`/api/auth/register` 增加登录速率限制（窗口内超限返回 429）。
- 修正 CORS：`allow_origins` 改为读取配置，不再使用 `*` 与 `allow_credentials=True` 组合。

> 注：审查报告中的 #1（LLM API Key 硬编码）与 #2（JWT 默认密钥）不在本次改动范围内，用户未要求修复，另行处理。

## Impact

- Affected specs: 后端认证授权、运行模式（SSH）、会话/账号
- Affected code:
  - `server/io_/routes.py`（工作空间/文件/Git 归属校验）
  - `server/tool/read_tool.py`、`server/tool/write_tool.py`、`server/io_/ssh_workspace_io.py`（路径穿越）
  - `server/ws/endpoints.py`（提问回答归属）
  - `server/data/routes.py`（账号状态脱敏、登录限流）
  - `server/data/ssh_store.py`、`server/io_/ssh_connection_manager.py`（SSH 密码加密）
  - `server/main.py`、`server/configs/app.yaml`（CORS 配置）

## ADDED Requirements

### Requirement: 工作空间归属授权

系统 SHALL 对每个以 `workspace_id` 定位资源（文件列表、读取、上传/下载、打包、exec、git、创建/删除）的 REST 端点，在执行任何操作前校验该工作空间归属于当前认证用户（或其团队成员）。

#### Scenario: 越权访问他人工作空间被拒绝
- **WHEN** 用户 A 以 A 的 token 访问用户 B 的工作空间 `workspace_id`
- **THEN** 返回 403/404，且不执行任何容器/文件/git 操作

#### Scenario: 访问本人工作空间正常
- **WHEN** 用户访问本人或其团队成员的 `workspace_id`
- **THEN** 正常返回结果，行为与现有一致

### Requirement: SSH/文本工具路径穿越防护

文本文件路径校验 SHALL 拒绝 `..` 段与绝对路径；SSH 模式远端路径拼接后 SHALL 约束在 `remote_base_dir` 之下。

#### Scenario: 尝试读取 base 目录之外文件
- **WHEN** read_tool/write_tool 收到含 `../` 或绝对路径的 `file_path`
- **THEN** 拒绝该路径，不向远端发起点读/写

### Requirement: WebSocket 提问回答归属校验

`user_answer` / `cancel_question` 分支 SHALL 校验待答问题的 `user_id` 与当前连接用户一致。

#### Scenario: 回答他人待答问题被拒绝
- **WHEN** 用户发送 `user_answer`/`cancel_question` 且 `question_id` 归属其他用户
- **THEN** 返回错误，不写入答案、不唤醒他人会话

### Requirement: 登录速率限制

`/api/auth/login` 与 `/api/auth/register` SHALL 在固定时间窗口内限制同一来源（IP/用户名）的尝试次数，超限返回 `429 Too Many Requests`。

#### Scenario: 频繁尝试登录被限流
- **WHEN** 同一来源在窗口内超过阈值次数
- **THEN** 后续请求返回 429，并给出提示

### Requirement: 账号状态响应脱敏

`/api/auth/account/status` 的响应 SHALL 不包含 `password_hash` 与 `salt`。

#### Scenario: 查询账号状态
- **WHEN** 用户调用 `/api/auth/account/status`
- **THEN** 返回的用户对象不含任何密码哈希与盐值

### Requirement: SSH 密码加密存储

SSH 连接密码 SHALL 加密后写入 `ssh_connections` 表，读取时解密用于连接；存储层 SHALL 不返回明文，连接层密文不出库。

#### Scenario: 注册 SSH 连接
- **WHEN** 用户注册带密码的 SSH 连接
- **THEN** 数据库仅存加密密文，连接时用密钥解密

### Requirement: CORS 配置修正

应用 SHALL 不再使用 `allow_origins=["*"]` 与 `allow_credentials=True` 的组合；允许源从配置读取，未配置时不得携带凭据开放任意源。

#### Scenario: 配置允许源
- **WHEN** 提供配置中的 allowed origins
- **THEN** CORS 仅放行这些源，且凭据开关与配置一致

## MODIFIED Requirements

无。

## REMOVED Requirements

无。