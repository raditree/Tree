# Checklist

## 配置
- [x] app.yaml 含 `registration` 段（enabled / restore_level / key_dir / levels），各等级人数/有效期/冷却/并发数/团队深度/成员数/限流数字均在配置中，代码无硬编码
- [x] `agents.max_per_user` 语义调整为可配置的不限（-1/0/缺省），并发 agent 数限制替代其作为运营上限

## 邀请码
- [x] 每个等级一个邀请码，写入 `server/invitation_code_<level>.key`（命名：invitation_code_common/pro/ultra/beta.key）
- [x] 后端启动时所有等级立即重新生成邀请码（旧码全部失效）
- [x] 各等级按各自有效期独立自动更新；common/pro/ultra 到期立即重新生成，beta 到期后冷却 18 分钟才重新生成
- [x] 邀请码在有效期内可多人使用，且使用人数不超过该码 `max_users`（注册 + 升级均计入），重新生成后计数清零

## 注册与升级
- [x] `registration.enabled=true` 时注册必须填有效邀请码；无效/过期/超名额分别被拒绝（400）
- [x] 注册成功用户等级 = 邀请码所属等级，`user` 含 `level`
- [x] 已注册用户可在设置页输入邀请码升级等级，升级计入该码名额，接口返回新等级
- [x] `registration.enabled=false` 时注册无需邀请码，按 common 创建

## 等级恢复
- [x] 用户等级落盘（users.level 列，含老库迁移）
- [x] `restore_level=false`（默认）：后端重启后所有用户回 common
- [x] `restore_level=true`：后端重启后从落盘恢复各用户等级

## 并发 agent 数限制
- [x] 用户总 agent 数不限；并发执行 agent 数按等级限制（common 4 / pro 12 / ultra 72 / beta 500）
- [x] 消息投递（进 working 前）检查并发：未超限正常投递；超限不进入 working，用户侧 429，leader→member 自动回复提醒稍后再试

## 分级限流与团队规模
- [x] 未开启主动限流时单 agent API 上限按等级：common 12 / pro 24 / ultra 60 / beta 300 次/分钟
- [x] 开启主动限流时单 agent API 上限 `active_rate_per_minute`（各等级均 6 次/分钟）
- [x] 团队深度与每级成员数按用户等级生效：common 2/3、pro 2/5、ultra 2/7、beta 3/5

## 前端
- [x] 登录页：`registration.enabled=true` 时注册表单显示必填「邀请码」输入
- [x] 设置页：展示当前等级；提供「等级升级」卡片（邀请码输入 + 升级，成功后刷新）

## 测试
- [x] 后端测试覆盖：邀请码生成/到期更新、注册与升级校验（含名额耗尽）、restore_level 行为、分级限流、并发拒绝
- [x] 冒烟验证通过（注册带码/不带码/错误码、升级、重启等级回落、429 并发提示）
- [x] 语法/静态检查通过（python 编译、flutter analyze）
