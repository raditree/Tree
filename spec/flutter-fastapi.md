---
id: flutter-fastapi
title: 产品设置项+后端限流/停止级联+多端适配（Flutter+FastAPI）
task_type: complex
description: Flutter+FastAPI agent 团队产品的「设置项新增+后端限流/停止级联+多端适配」类任务：开关设置走 前端 Switch 卡片 + REST 设置接口 + SQLite 偏好表 + 内存缓存；停止按钮级联 TOP+成员（取消事件+清 broker 队列+复位状态+推送 idle）；多端注意平台通道守卫与权限
when:
  - 前端设置页新增开关（主动延迟/数据收集等），需前后端同步
  - 后端需限制 agent API 调用频率或做停止级联
  - Flutter 应用多端适配（Windows/Android/Linux）
  - 并行成员工作流共存时需安全提交
tags: [complex]
pinned: false
builtin: false
created_at: 1787464084
updated_at: 1787464084
---

## 工作流（workflow）

## 工作流
1. **判型**：跨前后端/多模块 → complex/hard；先 spec search。
2. **摸底**：read 关键文件（settings_page/api_service/ws endpoints/chat/llm/tool 定义），git status 确认基线与其他并行改动。
3. **拆解**：set_todo_list 分解（后端限流 / 停止级联 / team 工具描述 / 前端开关 / 多端适配 / 测试 / 提交），每里程碑提交一次。
4. **后端实现**：
   - 限流：令牌桶（固定时间步 pacing，平均 6 次/min/agent），等待可被 cancel_event 取消；REST 设置接口写 SQLite + 更新内存缓存；启动预载。
   - 停止级联：`_stop_agent_tree`（TOP+成员取消全部会话任务 + broker.cancel_agent 清队列 + `_reset_member_status_to_idle` 复位 + 推送 idle）。
   - team 工具 description 提醒先查成员 role/duty/model_id，为空用 update_member 补充；list_members 返回 hint。
5. **前端实现**：ApiService 封装设置接口 + defaultBackendHost()；设置页 Switch 卡片（本地+后端双写）；main.dart 同步设置 HTTP/WS baseUrl；DropTarget 平台守卫；AndroidManifest 权限。
6. **测试**：限流器单测（加速间隔、取消、按 agent 独立、存储往返隔离临时 DB）；停止级联单测（_active_tasks 操作、broker 队列）；全量 pytest + flutter analyze。
7. **构建验证**：flutter build windows（注意运行中进程锁）；Android/Linux 依赖 SDK/GTK，环境不具备时验证配置正确性 + 文档说明。
8. **汇报**：提交历史（每里程碑一个）、验证结果、并行工作流说明、遗留事项。

## 该类任务规范

## 规范
- 开关类设置：前端 Switch + SharedPreferences(本地) + REST 设置接口(权威) + SQLite 偏好表 + 内存缓存，避免每次查库。
- 停止级联：TOP agent 停止时取消 TOP+全部成员**所有会话**任务（不只当前会话），清空 top_chat_broker/team_broker 排队消息防复活，复位 team_members work_status=idle，推送 agent_status=idle 让 UI 立即停。
- 平台通道守卫：仅桌面支持的插件（desktop_drop）必须用 Platform/kIsWeb 判断后再包裹，避免移动端 MissingPluginException。
- Android 联网：INTERNET 权限 + usesCleartextTraffic（本地开发 http 场景）。
- 平台默认后端：Android 模拟器 10.0.2.2，其余 localhost；HTTP 与 WS 必须同源（改 ApiService.baseUrl 同时改 WebSocketService.baseUrl）。
- 提交纪律：每完成一个里程碑立即 git commit（指定文件），便于回滚。

## 注意事项

## 注意事项
- **成员任务核实**：成员显示 working 不等于有产出——以 git status / 文件 mtime / 提交为准；成员任务可被 TOP 接管（先 send_message 取消再自查）。
- **并行工作流冲突**：仓库可能存在其他成员并行改动（如 compact 优化），提交时用 `git add <指定文件>` 而非 `git add -A`，避免把他人 WIP 混入。
- **CRLF 陷阱**：Windows 下部分 py/dart 文件是 CRLF，edit 工具精确匹配失败时先转 LF（git core.autocrlf=true 下仓库仍存 LF，diff 干净）。
- **运行中进程锁文件**：Windows 构建若 LNK1168 无法写 exe，说明应用正在运行，勿强杀用户进程，报告即可。
- **立即停止的边界**：cancel_event 检查点在「循环开始/流式分块/工具执行前/限流与重试等待期」；正在阻塞执行的同步工具（长 terminal）无法强杀线程，返回后在检查点退出——如实说明。
- 前端 Switch 卡片仿照数据收集卡片：本地 SharedPreferences + 后端 REST 双写，后端失败不阻塞本地。
- 限流等待期间必须可被取消（分片 wait + cancel_event），否则「停止」会被限流等待拖住。
