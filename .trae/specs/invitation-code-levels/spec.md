# 邀请码分级注册与等级体系 Spec

## Why
当前注册免邀请码、无分级，任何注册用户都共享同一套资源上限（`agents.max_per_user: 5`、`agents.max_level: 2`、`docker.max_members_per_level: 7`），且无并发数与 API 频率限制，无法做差异化运营与限量邀请。需要引入「邀请码 + 等级（common/pro/ultra/beta）」体系：注册需邀请码、等级决定并发/团队/限流上限、支持老用户升级，并把所有数字沉淀到 app.yaml。

## What Changes
- 新增 `registration` 配置段：开关（`enabled`）、各等级参数（`max_users` / 有效期 / 冷却 / 并发 agent 数 / 团队深度 / 每级成员数 / 不限流 API 上限 / 主动限流 API 上限）、重启后是否恢复等级（`restore_level`）、`.key` 文件目录（`key_dir`）。
- 新增邀请码模块：按等级各生成一个邀请码，写入 `server/invitation_code_<level>.key`；按各自有效期独立自动更新（beta 到期后冷却 18 分钟才重新生成）；后端启动即全部重新生成。
- 注册接口改造：`registration.enabled=true` 时注册必须填有效邀请码，按码所属等级创建用户。
- 新增升级接口：已注册用户在设置页填邀请码升级等级（升级计入该码名额），升级后等级保持至后端重启。
- 等级存储与恢复：等级落盘（`users` 表新增 `level` 列）但默认不恢复（由 `restore_level` 控制），默认后端重启后所有用户回 common。
- 并发 agent 数限制（取代「TOP agent 数」语义）：用户总 agent 数不限，按等级限制**并发执行**的 agent 数；超限以 429 语义拒绝，并向发送者自动回复「请稍后再试」。
- 分级 API 限流：未开启主动限流时按等级 `rate_per_minute` 封顶（12/24/60/300 次/分钟），开启主动限流时按 `active_rate_per_minute`（各等级均 6 次/分钟）。
- 分级团队规模：团队深度 `max_level` 与每级成员数上限 `max_members_per_level` 按用户等级生效。
- **BREAKING**：`agents.max_per_user` 不再作为顶层 agent 创建上限（总 agent 数不限，改由并发数限制约束）。

## Impact
- Affected specs: build-agent-team-tool（团队规模/并发）、refactor-v2（用户/认证/限流）
- Affected code:
  - 配置：`server/configs/app.yaml`
  - 启动：`server/main.py`
  - 认证/用户：`server/data/routes.py`、`server/data/user_store.py`
  - 新增：`server/data/invitation_code.py`（邀请码生命周期）
  - 限流：`server/llm/rate_limit.py`
  - 并发与投递：`server/agent/chat.py`
  - 团队规模：`server/tool/team_tool.py`、`server/data/team_init.py`、`server/agent/routes.py`
  - 前端：`lib/ui/pages/login_page.dart`、`lib/ui/pages/settings_page.dart`、`lib/io/api_service.dart`

## ADDED Requirements

### Requirement: 邀请码分级注册
系统 SHALL 在 `registration.enabled=true` 时要求注册必须携带有效邀请码，并根据邀请码所属等级创建用户（等级写入内存缓存并落盘）。

#### Scenario: 使用有效邀请码注册
- **WHEN** 用户在注册页填写用户名/密码/昵称与一个有效且未超名额的邀请码
- **THEN** 注册成功，新用户等级为该邀请码所属等级，返回的 `user` 含 `level`；该码名额 +1

#### Scenario: 邀请码无效/过期/超名额
- **WHEN** 邀请码不存在、已过期，或该码使用人数已达 `max_users`
- **THEN** 注册被拒绝（400），并提示对应原因（无效 / 已过期 / 名额已满）

#### Scenario: 关闭注册开关
- **WHEN** `registration.enabled=false`
- **THEN** 注册接口不要求邀请码，新用户按默认等级 common 创建

### Requirement: 邀请码有效期与自动更新
系统 SHALL 为每个等级维护一个邀请码，写入 `server/invitation_code_<level>.key`；各码按各自有效期独立自动更新；后端启动时全部重新生成。

#### Scenario: 有效期制多人使用
- **WHEN** 邀请码处于有效期内
- **THEN** 可被最多 `max_users` 个不同用户（注册或升级）使用，人数以「码」为单位计数，随重新生成清零

#### Scenario: 到期自动重新生成
- **WHEN** 某等级邀请码到达有效期
- **THEN** 若该等级 `cooldown_minutes=0`（common/pro/ultra），立即生成新码并覆盖 `.key` 文件；若 `cooldown_minutes>0`（beta），进入冷却期，冷却期内旧码不可用，冷却结束后才生成新码

#### Scenario: 后端重启
- **WHEN** 后端进程重启
- **THEN** 所有等级立即生成全新邀请码并覆盖 `.key` 文件，旧码全部失效；已注册用户保持注册状态（注册状态落盘）

### Requirement: 等级升级
系统 SHALL 允许已注册用户在设置页输入邀请码升级等级，升级计入该码名额。

#### Scenario: 老用户升级
- **WHEN** 已登录用户提交一个有效邀请码
- **THEN** 其等级更新为该码所属等级（升级后保持直至后端重启，除非配置恢复），该码名额 +1；接口返回新等级，前端展示刷新

### Requirement: 等级恢复策略
系统 SHALL 将用户等级落盘，但默认不恢复；是否恢复由 `registration.restore_level` 决定。

#### Scenario: 默认不恢复
- **WHEN** `registration.restore_level=false` 且后端重启
- **THEN** 所有用户（含升级用户）等级回到 common

#### Scenario: 恢复
- **WHEN** `registration.restore_level=true` 且后端重启
- **THEN** 从落盘数据恢复各用户等级

### Requirement: 并发 agent 数限制
系统 SHALL 不限制用户总 agent 数，但按等级限制并发执行 agent 数（common 4 / pro 12 / ultra 72 / beta 500）；超限以 429 语义拒绝，并向发送者自动回复提醒稍后再试。

#### Scenario: 未超并发
- **WHEN** 用户/leader 向某 agent 发消息，且该用户当前并发执行 agent 数 < `max_concurrent_agents`
- **THEN** 消息正常投递，agent 进入 working

#### Scenario: 超并发
- **WHEN** 目标 agent 未在工作，且该用户当前并发执行 agent 数 >= `max_concurrent_agents`
- **THEN** 不进入 working，以 429 语义拒绝：用户侧发送返回 429 报错；leader→member 内部投递则把该 429 错误作为一条自然回复消息自动回给发送者（leader），提醒「并发执行任务已达上限，请稍后再试」

### Requirement: 分级 API 限流
系统 SHALL 按用户等级对单 agent 的 LLM API 调用限速：未开启主动限流时上限为该等级 `rate_per_minute`，开启主动限流时上限为 `active_rate_per_minute`。

#### Scenario: 不开主动限流
- **WHEN** 用户未开启主动限流，等级为 common/pro/ultra/beta
- **THEN** 单 agent API 调用分别封顶 12 / 24 / 60 / 300 次/分钟

#### Scenario: 开启主动限流
- **WHEN** 用户开启主动限流
- **THEN** 单 agent API 调用封顶 `active_rate_per_minute`（各等级均为 6 次/分钟）

### Requirement: 分级团队规模
系统 SHALL 按用户等级应用团队深度 `max_level` 与每级成员数上限 `max_members_per_level`。

#### Scenario: 建队与扩建受等级约束
- **WHEN** 用户创建 TOP agent（自动建队）或通过 team 工具创建成员
- **THEN** 初始成员数与层级深度以该用户等级的 `max_members_per_level` / `max_level` 为上限（common 2/3、pro 2/5、ultra 2/7、beta 3/5）

## MODIFIED Requirements

### Requirement: 注册接口（原免码注册）
注册接口 `/api/auth/register` 请求体新增 `invitation_code` 字段；`registration.enabled=true` 时为必填，按码分配等级；`false` 时无需填码，按默认等级 common 创建。

### Requirement: 主动延迟限流（原固定 6 次/分钟）
主动延迟限流节奏由固定值改为按用户等级 + 主动开关动态解析：关闭主动时用该等级 `rate_per_minute`，开启时用 `active_rate_per_minute`；`llm.rate_per_minute` 保留为兜底默认值。

### Requirement: 顶层 agent 数量上限（原 `agents.max_per_user`）
不再限制用户总 agent 数（总 agent 数不限）；并发执行 agent 数按等级限制（见「并发 agent 数限制」）。`agents.max_per_user` 保留为可选的绝对硬上限配置，值为 `-1` / `0` / 缺省时表示不限。

## REMOVED Requirements

（无）
