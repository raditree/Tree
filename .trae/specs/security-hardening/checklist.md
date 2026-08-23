# 检查清单

- [x] Task 1 工作空间归属授权：全部工作空间/文件/Git 端点均校验归属，他人 workspace 返回 403/404 且不执行操作
- [x] Task 2 路径穿越：read_tool/write_tool 拒绝 `..` 与绝对路径；SSH 远端路径约束在 base 目录下
- [x] Task 3 WebSocket 归属校验：`user_answer`/`cancel_question` 仅本人 qid 生效
- [x] Task 4 账号状态脱敏：`/api/auth/account/status` 不含 password_hash/salt
- [x] Task 5 SSH 密码加密落库：库中无明文；存量兼容；重启后可连接
- [x] Task 6 登录限流：login/register 窗口内超限返回 429
- [x] Task 7 CORS：不再 `*`+credentials；允许源随配置
- [x] 回归：`server/tests/` 现有测试通过，无回归