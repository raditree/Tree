# Changelog

本文件记录 Agent Team Desktop 应用的所有变更。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/)。

---

## [Unreleased] - 2026-08-12

### Added

#### 用户体验优化
- **Working 状态标识**：agent 工作时标题栏显示"工作中"动画与橙色标识
- **停止按钮**：工作期间可随时点击停止按钮取消当前任务（基于 `threading.Event` 的线程安全取消机制）
- **中间输出独立成消息**：agent 每次中间输出作为独立消息发送，不再合并为单条
- **工具调用折叠卡片**：每次工具调用以可折叠卡片展示（默认折叠），展开可查看参数与执行结果
- **内置工具定制卡片样式**：为每个内置工具（help/set/refresh/mcp/team/ask_user_question/read/write/edit/terminal/embed_search）配置专属图标、配色与标题
- **工具卡片人类可读参数**：展开后按工具类型格式化展示参数（文件路径、命令、操作类型等），不再显示原始 JSON
- **大输出可滚动容器**：terminal/read/mcp 等工具输出超过 200 字符时使用可滚动容器展示
- **重定向输出参数**：每个内置工具增加 `redirect_output` 参数，可将工具结果保存到工作空间内指定文件，返回保存提示
- **MCP 工具嵌套参数展示**：mcp 工具的 `tool_name` 与嵌套 `arguments`（如 `cmd`/`path`）展开为独立参数行
- **工具结果可读化**：后端 `_stringify_tool_result` 将 dict 结果格式化为人类可读文本（提取 content/message 字段或格式化为 `标签: 值` 行），不再显示原始 JSON
- **图片文件 base64 返回**：`get_file_content` 对图片文件（png/jpg/gif 等）返回 base64 编码内容，前端正确解码渲染

#### AskUserQuestion 内置工具
- 新增 `ask_user_question` 内置工具（非 MCP tool），允许 agent 在任务中向用户提问
- 支持 question/options/default_answer 参数
- 前端弹窗展示问题与选项，用户选择/输入后回传给 agent
- 超时自动使用默认答案或提示 agent 重新提问

#### Teammates 工作进度窗口
- 新增 teammates 拓扑可视化窗口，展示 leader 与成员的层级关系
- 每个成员卡片显示名称、实时工作状态（工作中/空闲）、模型、层级与评价
- 点击成员进入详情页，包含进度/日志/文件/消息四个 Tab
  - 进度：实时消息与工具调用卡片（WS 推送 + 历史加载）
  - 日志：成员工作空间的活动日志
  - 文件：成员沙箱文件浏览器（支持目录导航）
  - 消息：直接向成员发送消息
- 成员工作状态通过 WebSocket 实时更新（working/idle）
- 成员详情页支持 `DefaultTabController` 提供 Tab 切换

#### Compact 机制重新设计
- 保留最近 N 次用户要求原文（`KEEP_RECENT_USER_MSGS`），确保当前任务上下文完整
- 调用 LLM 总结更早的工具调用轨迹与任务上下文，生成 summary 消息替代
- 手动压缩按钮（compact）跳过阈值判断，强制执行压缩

#### 文件同步
- 实现 `syncToLocal` 接口：将工作空间文件打包（tar + base64）下载到本地
- 逐个解包 tar 成员，已存在文件覆盖、目录跳过创建，不删除目标目录中的其他文件
- 含路径穿越防护（拒绝 `../../` 之类的恶意路径）

#### 工具调用轨迹持久化
- 对话历史数据库新增 kind/tool_name/tool_arguments/tool_result 字段
- 中间文本输出与工具调用结果实时写入历史，重启后不丢失
- 前端加载历史时自动渲染工具调用卡片

### Fixed

- **`surfaceContainerHighest` 编译错误**：Flutter 3.7.12 不支持该 getter，替换为 `surfaceVariant`
- **`Not a constant expression`**：`_toolStyle` default 分支字符串插值不能用于 `const`，去掉 `const`
- **`No TabController for TabBar`**：teammates 详情页用 `DefaultTabController` 包裹 Scaffold
- **team_broker 事件循环错误**：`dispatch()` 在 chat 消费线程中调用时无 running loop，改为构造时捕获主事件循环引用，使用 `run_coroutine_threadsafe` 调度
- **服务关停时 worker 异常日志**：`_on_worker_done` 未捕获 `concurrent.futures.CancelledError`，补充捕获
- **teammates 沙箱文件目录无法点击**：`_MemberFileBrowser` 缺少目录导航逻辑，增加 `onTap` 与面包屑导航
- **teammate 进度页一直为空**：成员处理流程不写历史且前端不加载历史，后端补 `_store_message`、前端补 `getConversationHistory`
- **teammate 卡住不动**：成员会话创建时缺少 `_register_tools`，LLM 无法调用任何工具
- **消息列表频繁滑到底部**：添加 `_nearBottom` 标志，仅在用户已处于底部附近时才跟随滚动
- **teammate 状态不实时更新**：拓扑页增加 WebSocket 连接，监听 `agent_status` 事件维护 `_workingMembers` 集合
- **syncToLocal 重复同步报错**：改为逐个解包 tar 成员，不再清空目标目录
- **工具卡片显示原始 JSON**：后端 `str(result)` 将 dict 转为 Python dict 字符串，前端无法可靠解析；改为后端 `_stringify_tool_result` 统一提取可读内容
- **MCP 工具参数不显示**：mcp 工具参数为嵌套结构（`tool_name` + `arguments`），之前只取不存在的 `tool` 键，改为正确解析嵌套参数
- **PNG 图片无法渲染**：`get_file_content` 用 `cat` 读取二进制图片导致损坏，改为对图片文件使用 `base64` 命令编码返回
- **Dart 类型转换语法错误**：`(member['live_status'] as String? == 'working')` 括号位置错误，改为 `((member['live_status'] as String?) == 'working')`

### Changed

- **WebSocketManager 支持多连接**：同一用户可同时维护多个 WS 连接（主面板 + teammates 窗口）
- **TeamMessageBroker 线程安全**：`queue.Queue` 替代 `asyncio.Queue`，worker 通过 `run_coroutine_threadsafe` 调度到主事件循环
- **流式推送架构**：`_stream_agent_reply` 在后台线程消费 chat 生成器，通过线程安全 `asyncio.Queue` 回传事件循环逐条推送

---

## [0.1.0] - 2026-08-10

### Added

- 账号密码注册/登录（替代微信扫码登录）
- 注销账号（十日倒计时 + 31 天数据保留）
- Agent 创建、列表、删除
- Normal LLM 与 Limitless Context LLM 两种 agent 类型
- Docker 沙箱工作空间隔离（Windows 7 本地目录模式回退）
- MCP 工具集成（read/write/edit/terminal/embed_search）
- 内置工具：help/set/refresh/mcp/team
- Team 工具：成员创建、消息投递、任务分配、表格追踪
- 文件管理：上传、浏览、内容查看、PDF 预览
- Git 历史、分支查看
- 对话历史持久化与上下文恢复
- LLM 上下文压缩（compact）
- Agent 工作空间 rule.md 初始化与注入
- 沙箱网络白名单与 pip 单次下载限制
- activity.log 工作空间活动日志
