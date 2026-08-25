# Tasks

- [x] Task 1: 配置层 - app.yaml 新增 `registration` 段与等级解析
  - [ ] 1.1 在 `server/configs/app.yaml` 新增 `registration` 段：`enabled`（默认 true）、`restore_level`（默认 false）、`key_dir`（默认空 = server/ 目录）、`levels`（common/pro/ultra/beta 各等级：`max_users`、`validity_minutes`、`cooldown_minutes`、`max_concurrent_agents`、`max_level`、`max_members_per_level`、`rate_per_minute`、`active_rate_per_minute`），数值：common 200/1440/0/4/2/3/12/6；pro 50/360/0/12/2/5/24/6；ultra 10/30/0/72/2/7/60/6；beta 1/2/18/500/3/5/300/6
  - [ ] 1.2 提供等级配置解析辅助（默认值兜底、level 名称校验），供限流/并发/团队模块复用
  - [ ] 1.3 调整 `agents.max_per_user` 语义（-1/0/缺省 = 不限）并同步 `help_policy` 披露项（改为披露并发 agent 数上限或保留兜底）

- [x] Task 2: 邀请码模块 - `server/data/invitation_code.py`（新增）+ 启动接线
  - [x] 2.1 实现每个等级一个邀请码的生命周期：启动即生成（`secrets.token_urlsafe(16)`），写入 `server/invitation_code_<level>.key`；记录生成/过期/冷却时间
  - [x] 2.2 后台自动更新：各等级按各自 `validity_minutes` 独立到点；到期后 `cooldown_minutes=0` 立即重新生成，`>0`（beta）进入冷却、冷却结束后重新生成；生成时打印日志（含码与到期时间）并覆盖 `.key` 文件
  - [x] 2.3 校验与名额：`validate_code(code) -> (level|None, reason)`、`consume_code(level) -> bool`（线程安全，按码计数 max_users，随重新生成清零）
  - [x] 2.4 `server/main.py` 启动时初始化邀请码并启动各等级后台任务；优雅关闭时停止任务

- [x] Task 3: 等级存储与内存缓存 - `server/data/user_store.py` + 等级缓存
  - [x] 3.1 `users` 表新增 `level` 列（默认 'common'），含老库迁移（`ALTER TABLE` 幂等）
  - [x] 3.2 提供 `get_user_level(user_id)` / `set_user_level(user_id, level)`：内存缓存 + 落盘
  - [x] 3.3 启动加载：`restore_level=true` 时从 DB 恢复各用户等级到缓存；`false` 时全部回 common（不改动 DB 落盘值）

- [x] Task 4: 认证接口改造 - `server/data/routes.py`
  - [x] 4.1 `POST /api/auth/register` 请求体新增 `invitation_code`；`registration.enabled=true` 时必填并校验（无效/过期/超名额 -> 400），按码分配等级并消耗名额
  - [x] 4.2 新增 `GET /api/auth/registration-config`：返回 `{enabled, levels}`（等级元数据用于前端展示，不含邀请码本身）
  - [x] 4.3 新增 `POST /api/auth/upgrade`：已登录用户提交 `invitation_code`，校验并升级等级（计入名额），返回新等级
  - [x] 4.4 注册/登录/升级/`/auth/account/status` 等返回的 `user` 含 `level`

- [x] Task 5: 分级限流 - `server/llm/rate_limit.py`
  - [x] 5.1 将固定限速改为按用户等级 + 主动开关动态解析间隔：关闭主动 -> 60/`rate_per_minute`（按等级），开启主动 -> 60/`active_rate_per_minute`；`llm.rate_per_minute` 兜底
  - [x] 5.2 提供 `set_user_level(user_id, level)` 联动（注册/升级/启动恢复时调用），使限流即时生效
  - [x] 5.3 更新 `test_rate_limit.py` 覆盖分级场景

- [x] Task 6: 分级团队规模与 agent 创建 - `server/tool/team_tool.py`、`server/data/team_init.py`、`server/agent/routes.py`
  - [x] 6.1 `team_tool` 的 `max_team_level`（深度）与 `max_members_per_level` 按用户等级解析（TeamTool 已持有 user_id）
  - [x] 6.2 `team_init.init_team_for_top` 初始成员数按用户等级 `max_members_per_level`
  - [x] 6.3 `create_agent_endpoint` 移除 `agents.max_per_user` 硬上限（配置为 -1/0/缺省时不限）

- [x] Task 7: 并发 agent 数限制 - `server/agent/chat.py`
  - [x] 7.1 在消息投递入口（`_dispatch_agent_message` 及相关路径）检查：目标 agent 未在工作时，统计该用户当前 `_active_tasks` 中不同 agent 数，>= 用户等级 `max_concurrent_agents` 则拒绝进入 working
  - [x] 7.2 超限处理：用户侧发送返回 429 语义报错；leader→member 内部投递将 429 错误作为自然回复自动回给发送者（leader），提醒稍后再试

- [x] Task 8: 前端 - `lib/io/api_service.dart`、`lib/ui/pages/login_page.dart`、`lib/ui/pages/settings_page.dart`
  - [x] 8.1 `api_service` 新增：register 携带 `invitation_code`、`getRegistrationConfig`、`upgradeLevel`、获取当前 level
  - [x] 8.2 登录页：`registration.enabled=true` 时注册表单显示「邀请码」必填输入
  - [x] 8.3 设置页：账号卡片展示当前等级；新增「等级升级」卡片（邀请码输入 + 升级，成功后刷新等级显示）

- [x] Task 9: 测试与验证
  - [x] 9.1 新增/更新后端测试：邀请码生成与到期更新、注册/升级校验（含名额耗尽）、`restore_level` 行为、分级限流、并发拒绝
  - [x] 9.2 冒烟验证：注册（带码/不带码/错误码）、升级、重启后等级回落、429 并发提示
  - [x] 9.3 语法/诊断检查（python -m py_compile、flutter analyze）

# Task Dependencies
- Task 1（配置）先行；Task 3 依赖 Task 1
- Task 2（邀请码）依赖 Task 1；Task 4 依赖 Task 2 与 Task 3
- Task 5、6、7 依赖 Task 3（`get_user_level`）
- Task 8 依赖 Task 4（接口）
- Task 9 依赖 Task 4/5/6/7 完成后进行
