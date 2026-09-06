# 检查清单

## ID 模型
- [x] `top_agent_id`/`exec_id` 在 server/ 与 lib/ 全局更名为 `team_id`/`tool_id`，搜索清零
- [x] 用户直发消息统一标记 agent_id="0"，消息接口行为一致
- [x] 所有入口（WS/REST/内部 dispatch/前端 handler）缺必需 id 时拒绝并回错，无空串降级路径
- [x] tool_exec_request payload 必携带非空 team_id 与 tool_id

## per-team 执行器
- [x] Local/Ssh 执行器状态为 Map<team_id, State>，team A（SSH）与 team B（local）同时工作互不串扰
- [x] 启动/切换 agent 不批量注册；首次向 team 发消息时懒创建
- [x] team 删除/应用退出时生命周期收口，无残留注册与连接
- [x] SshConnectionManager 同 team 并发首连只建一条连接（in-flight 去重）
- [x] 归属校验为集合匹配，不依赖 UI 当前选中 agent

## 后端委托链
- [x] pending/计数 key 为 (user_id, team_id)；注销仅失效本 team 的 pending
- [x] SSH 执行器连续超时自动停用并回退云端，其他 team 不受影响
- [x] WS 断连按 connection_id 清理执行器注册；死连接写超时被剔除，不堆积协程

## 文件 IO 三模式一致
- [x] SSH 模式上传的文件落在远端 workspace `.input/yyyymmdd/`，agent 可读取
- [x] SSH 模式文件栏 list_files/content/download 显示远端 workspace（不再显示沙箱）
- [x] cloud 模式上传/文件栏行为不回归
- [x] 大文件分片上传可用（cloud 组装 / local 直写 / SSH SFTP 续写），完成校验通过，失败分片可重试

## agentspace 与 .self/沙箱
- [x] top 与成员工作根目录均为其 base（local 本机 / ssh 远端用户指定目录 / cloud /workspace），成员不再隔离于 agentspace/<member_id>/
- [x] base 下创建 agentspace/；各 agent .self 位于 agentspace/<agent_id>/.self/，系统提示词直接给出其 .self 绝对路径
- [x] .self 允许所有 agent 查看，无 agent 间读权限隔离
- [x] 文件栏展示 base/ 且隐藏 agentspace/ 与 .git；top agent terminal 工作目录为 base
- [x] local/ssh 不创建 docker 沙箱、不在沙箱执行命令
- [x] team 首条消息时锁定模式并持久化；local/ssh 创建 agentspace/ 目录；仅 cloud 创建沙箱（每 team 一个）
- [x] 不做旧数据兼容；旧测试数据（DB 测试库与 `base/.self`、`base/workspaces/<id>/` 旧目录）已清除，功能不回归

## 消息语义
- [x] 消息接口携带 active 参数；active=true 触发最后总结反向推送（active=false）
- [x] 跨 team 消息接收方无会话时自动建会话，前端可见消息

## auth_token
- [x] 每用户 token 列表落库；多设备同时在线各自有效
- [x] REST 与 WS 统一校验"在表 ∧ 未撤销 ∧ 未过期"；登出仅撤销单 token
- [x] 过期/撤销 token 被拒绝，列表有惰性+定期清理

## 工具调用链
- [x] SSH hook 输出落盘且可取消（远端任务可终止）
- [x] tool_id 贯穿 pending/hook/取消/响应
- [x] SSH grep 路径穿越校验对齐 local；SSH exec 超时/异常关闭 session，无通道泄漏

## 回归
- [x] server/tests 全量通过；flutter analyze 无错误
