---
id: flutter-fastapi
title: 产品设置项+后端限流/停止级联+多端适配（Flutter+FastAPI）
task_type: complex
description: Flutter+FastAPI agent 团队产品的「设置项新增+后端限流/停止级联+多端适配」类任务：开关设置走 前端 Switch 卡片 + REST 设置接口 + SQLite 偏好表 + 内存缓存；停止按钮级联 TOP+成员（取消事件+清 broker 队列+复位状态+推送 idle）；多端注意平台通道守卫与权限
when:
  - 前端设置页新增开关/滑块（token 获取帧率、推送刷新帧率、数据收集等），需前后端同步
  - 后端需限制 agent 流式输出节奏或做停止级联
  - Flutter 应用多端适配（Windows/Android/Linux）
  - 移动端（Android/iOS）响应式布局或平台能力守卫（目录选择/保存对话框/本地执行）
tags: [complex]
pinned: false
builtin: false
created_at: 1787467805
updated_at: 1787467805
---

## 工作流（workflow）



## 该类任务规范

- 开关类设置：前端 Switch + SharedPreferences(本地) + REST 设置接口(权威) + SQLite 偏好表 + 内存缓存，避免每次查库。
- 停止级联：TOP agent 停止时取消 TOP+全部成员**所有会话**任务（不只当前会话），清空 top_chat_broker/team_broker 排队消息防复活，复位 team_members work_status=idle，推送 agent_status=idle 让 UI 立即停。
- 平台通道守卫：仅桌面支持的插件（desktop_drop）必须用 Platform/kIsWeb 判断后再包裹，避免移动端 MissingPluginException。
- Android 联网：INTERNET 权限 + usesCleartextTraffic（本地开发 http 场景）。
- 平台默认后端：Android 模拟器 10.0.2.2，其余 localhost；HTTP 与 WS 必须同源（改 ApiService.baseUrl 同时改 WebSocketService.baseUrl）。
- 提交纪律：每完成一个里程碑立即 git commit（指定文件），便于回滚。
- **移动端响应式**：统一用 lib/io/platform_support.dart（isAndroid/isDesktop/isMobile，先判 kIsWeb）；移动端单栏+底部导航（复用 AgentList/MessagePanel/FilePanel），桌面三栏；最小窗口限制（1024×600）仅桌面生效。
- **file_picker 平台差异**：getDirectoryPath / saveFile 仅桌面支持，移动端隐藏入口或降级（下载保存到 getApplicationDocumentsDirectory）；pickFiles 全平台可用。
- **本地执行模式（LocalExecutorService）移动端禁用**：setEnabled/syncRegistration/register 守卫 isMobile；ModeSwitchButton 加 showLocal 参数隐藏菜单项。
- **Android minSdk 21**：file_picker 5.x 要求（Flutter 3.7 默认 16 会构建失败），显式写 android/app/build.gradle。
- **Linux 窗口标题**：改 linux/my_application.cc 的 gtk_header_bar_set_title / gtk_window_set_title（默认是项目名，产品名在 Windows 由 runner 资源、Android 由 android:label 定义）。

## 注意事项

- **成员任务核实**：成员显示 working 不等于有产出——以 git status / 文件 mtime / 提交为准；成员任务可被 TOP 接管（先 send_message 取消再自查）。
- **并行工作流冲突**：仓库可能存在其他成员并行改动（如 compact 优化），提交时用 `git add <指定文件>` 而非 `git add -A`，避免把他人 WIP 混入。
- **CRLF 陷阱**：Windows 下部分 py/dart 文件是 CRLF，edit 工具精确匹配失败时先转 LF（git core.autocrlf=true 下仓库仍存 LF，diff 干净）。
- **运行中进程锁文件**：Windows 构建若 LNK1168 无法写 exe，说明应用正在运行，勿强杀用户进程，报告即可。
- **立即停止的边界**：cancel_event 检查点在「循环开始/流式分块/工具执行前/限流与重试等待期」；正在阻塞执行的同步工具（长 terminal）无法强杀线程，返回后在检查点退出——如实说明。
- 前端 Switch 卡片仿照数据收集卡片：本地 SharedPreferences + 后端 REST 双写，后端失败不阻塞本地。
- 限流等待期间必须可被取消（分片 wait + cancel_event），否则「停止」会被限流等待拖住。
