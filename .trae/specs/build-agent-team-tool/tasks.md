# Tasks

## Phase 1: 后端基础架构

- [x] Task 1: 创建后端项目结构与服务骨架
  - [x] SubTask 1.1: 创建 `server/` 目录结构：`main.py`、`api/`、`core/`、`tools/`、`mcp_tools/`、`configs/models/`、`configs/app.yaml`
  - [x] SubTask 1.2: 创建 `requirements.txt`（fastapi、uvicorn、openai、docker、pyyaml、PyJWT、httpx、mcp）
  - [x] SubTask 1.3: 实现 FastAPI 应用骨架，包含 REST 路由和 WebSocket 端点
  - [x] SubTask 1.4: 实现应用配置加载（`configs/app.yaml` → 端口、Docker 配置、微信 OAuth 配置、资源配额、最大成员数）
  - [x] SubTask 1.5: 实现模型配置加载器，扫描 `configs/models/*.yaml` 并解析为模型配置对象（含 `is_limitless_context` 字段）

- [x] Task 2: 实现微信登录认证
  - [x] SubTask 2.1: 实现微信 OAuth 后端接口（生成二维码 URL、回调处理、获取用户信息）
  - [x] SubTask 2.2: 实现 JWT token 生成与验证中间件
  - [x] SubTask 2.3: 实现会话管理（token 刷新、失效）

- [x] Task 3: 实现 Docker 工作空间隔离与 Git 初始化
  - [x] SubTask 3.1: 封装 Docker 客户端，实现容器创建/停止/删除
  - [x] SubTask 3.2: 实现工作空间卷管理（创建独立卷、挂载到 `/workspace`）
  - [x] SubTask 3.3: 构建 agent 工作空间 Docker 镜像（预装 MCP 工具运行环境 + Git）
  - [x] SubTask 3.4: 实现工作空间创建时 Git 仓库初始化（`git init`、配置 user.name、创建 `.self/` 目录）
  - [x] SubTask 3.5: 实现工作空间生命周期管理 API
  - [x] SubTask 3.6: 实现 Docker 资源配额（CPU/内存/磁盘上限，从配置读取）

- [x] Task 3.5: 实现 Git 仓库层级架构
  - [x] SubTask 3.5.1: 实现父 agent 工作空间作为 Git remote 的配置（支持 push 的仓库或 bare repo）
  - [x] SubTask 3.5.2: 实现子 agent 工作空间创建时配置父 agent Git remote 地址
  - [x] SubTask 3.5.3: 实现 Docker 网络配置，确保子 agent 可访问父 agent Git remote
  - [x] SubTask 3.5.4: 实现子 agent 独立分支策略（分支名 = 成员 ID）
  - [x] SubTask 3.5.5: 实现父 agent Git 操作 API（fetch、diff、merge 子 agent 分支）
  - [x] SubTask 3.5.6: 实现 Git 提交历史查询 API（供前端展示）

## Phase 2: 后端 LLM 与 Agent 核心

- [x] Task 4: 实现 LLM 接入层
  - [x] SubTask 4.1: 封装 OpenAI SDK client 工厂（根据模型配置创建 client）
  - [x] SubTask 4.2: 实现普通 LLM 调用流程（注入系统提示词+记忆、注册 tool_call、循环执行）
  - [x] SubTask 4.3: 实现普通 LLM 上下文压缩（基于 `max_seqlen` 触发）
  - [x] SubTask 4.4: 实现无限上下文 LLM 调用流程（前缀一致性验证、原子追加）
  - [x] SubTask 4.5: 实现无限上下文 LLM 上下文跨任务持久保留

- [ ] Task 5: 实现内置 Tool — set
  - [ ] SubTask 5.1: 定义 set 工具的参数 schema（普通 LLM 版 vs 无限上下文版）
  - [ ] SubTask 5.2: 实现参数设置逻辑（max_seqlen 校验 < 上下文上限、temperature/top_k、mcp_tools 选择）
  - [ ] SubTask 5.3: 实现 teammates 参数（从已有成员中选择、设置 can_lead_team、参考多维评分）
  - [ ] SubTask 5.4: 实现新任务开始时的 set 推荐提示

- [ ] Task 6: 实现内置 Tool — help
  - [ ] SubTask 6.1: 实现帮助信息生成（遍历所有内置工具，返回名称+描述）
  - [ ] SubTask 6.2: 集成当前可用 MCP 工具列表到 help 返回

- [ ] Task 7: 实现内置 Tool — team（成员管理）
  - [ ] SubTask 7.1: 实现创建成员流程（返回可用模型池列表 → LLM 选择模型 → 分配 agent 实例 → 创建 Docker 工作空间含 Git → 配置成员 ID/名称/模型/层级 → 记录到 team_roster.md）
  - [ ] SubTask 7.2: 实现成员管理表（`.self/team_roster.md`，记录 ID/名称/模型/层级/创建时间/工作状态/评价/多维评分）
  - [ ] SubTask 7.3: 实现多维评分机制（任务完成质量、效率、协作性、准确性，由父 agent 在子 agent 完成任务后填写）
  - [ ] SubTask 7.4: 实现成员查询（全量列表、按条件筛选、单成员详情）
  - [ ] SubTask 7.5: 实现工作状态查询（空闲/工作中/等待输入/已停止/异常、当前任务、最后一次 Git 提交信息）

- [ ] Task 8: 实现内置 Tool — team（消息管理）
  - [ ] SubTask 8.1: 实现点对点消息发送（路由到目标成员 agent 上下文、WebSocket 推送前端、记录双方对话历史）
  - [ ] SubTask 8.2: 实现广播消息（同时发送所有成员、前端所有会话更新）
  - [ ] SubTask 8.3: 实现文件发送（工作空间间文件复制、接收者收到路径通知、与 Git 提交独立）

- [ ] Task 9: 实现内置 Tool — team（任务管理）
  - [ ] SubTask 9.1: 实现任务分配（任务描述/优先级/预期输出、记录到成员任务队列、状态更新为工作中）
  - [ ] SubTask 9.2: 实现任务完成流程（成员 Git 提交工作成果 → 通知父 agent → 父 agent 评分 → 更新成员管理表）
  - [ ] SubTask 9.3: 实现任务跟踪（查询所有任务状态、关联 Git 提交记录）

- [ ] Task 9.5: 实现团队层级限制
  - [ ] SubTask 9.5.1: 实现 agent 层级深度追踪（Level 0-3）
  - [ ] SubTask 9.5.2: 实现创建成员时层级校验（Level 3 不可创建子团队）
  - [ ] SubTask 9.5.3: 实现 set.teammates 中 can_lead_team 与层级限制的联合校验

- [ ] Task 10: 实现内置 Tool — refresh
  - [ ] SubTask 10.1: 实现扫描所有已注册 MCP 服务，返回完整工具列表（名称/描述/参数 schema）
  - [ ] SubTask 10.2: 实现 `task_only` 模式（仅返回 set.mcp_tools 选中的工具）

- [ ] Task 11: 实现内置 Tool — mcp
  - [ ] SubTask 11.1: 实现 MCP SDK 集成框架（注册/管理 MCP 服务）
  - [ ] SubTask 11.2: 实现 mcp help 命令（列出 MCP 服务 + 各工具使用方法）
  - [ ] SubTask 11.3: 实现 MCP 工具调用分发

- [ ] Task 12: 实现基础 MCP 工具集
  - [ ] SubTask 12.1: 实现 `read` 工具（读取文件，支持编码指定）
  - [ ] SubTask 12.2: 实现 `write` 工具（写入文件，自动创建父目录）
  - [ ] SubTask 12.3: 实现 `edit` 工具（精确字符串替换，错误处理）
  - [ ] SubTask 12.4: 实现 `terminal` 工具（Docker 内 shell 执行含 git 命令，超时控制）
  - [ ] SubTask 12.5: 实现 `embed_search` 工具（向量嵌入 + 语义搜索）

- [ ] Task 13: 实现 LLM 记忆管理
  - [ ] SubTask 13.1: 实现工作空间初始化时创建 `.self/memory.md`
  - [ ] SubTask 13.2: 实现记忆注入到系统提示词（普通 LLM 专用）
  - [ ] SubTask 13.3: 实现记忆更新触发机制（任务结束后、上下文压缩前发送更新提示）
  - [ ] SubTask 13.4: 实现无限上下文 LLM 跳过记忆注入

- [ ] Task 14: 实现无限上下文 LLM 上下文一致性与持久化
  - [ ] SubTask 14.1: 实现前缀一致性验证逻辑（新输入前缀 == 上次输入）
  - [ ] SubTask 14.2: 实现生产环境警告与拒绝发送
  - [ ] SubTask 14.3: 实现上下文持久化（每次交互后异步写入 `.self/context_snapshot.json`）
  - [ ] SubTask 14.4: 实现崩溃恢复（从 snapshot 恢复 + 前缀一致性验证）
  - [ ] SubTask 14.5: 编写测试用例验证原子上下文操作（断言前缀不一致时终止）

- [ ] Task 14.5: 实现 Agent 上下文隔离
  - [ ] SubTask 14.5.1: 实现子 agent 工作成果摘要汇报机制（非完整工作日志）
  - [ ] SubTask 14.5.2: 实现顶部 agent 上下文内容控制（任务描述/团队成员/关键决策/摘要，排除子 agent 逐条 tool_call）

## Phase 3: 后端 API 层

- [ ] Task 15: 实现前后端通信 API
  - [ ] SubTask 15.1: 定义 REST API 路由（登录、agent 列表、文件列表、文件上传/下载、文件同步、Git 历史/分支）
  - [ ] SubTask 15.2: 定义 WebSocket 消息协议（消息类型、消息格式）
  - [ ] SubTask 15.3: 实现 WebSocket 连接管理（鉴权、心跳、重连）
  - [ ] SubTask 15.4: 实现消息流式推送（agent 回复 → WebSocket → 前端）

## Phase 4: 前端基础架构

- [x] Task 16: 搭建前端项目框架
  - [x] SubTask 16.1: 更新 `pubspec.yaml`，添加依赖（web_socket_channel、http、file_picker、desktop_window 等，确保兼容 Dart 2.19.6）
  - [x] SubTask 16.2: 创建目录结构：`lib/models/`、`lib/services/`、`lib/pages/`、`lib/widgets/`
  - [x] SubTask 16.3: 重写 `lib/main.dart`（路由管理、主题、WebSocket 连接初始化）
  - [x] SubTask 16.4: 实现本地 JWT token 存储与读取

- [x] Task 17: 实现微信登录页
  - [x] SubTask 17.1: 创建登录页面 UI（二维码展示区、登录状态提示）
  - [x] SubTask 17.2: 实现二维码获取与轮询登录状态
  - [x] SubTask 17.3: 实现登录成功后保存 token 并跳转主界面

- [x] Task 18: 实现主界面三栏布局
  - [x] SubTask 18.1: 实现三栏 Scaffold 布局（左栏 Agent 列表 | 中栏消息 | 右栏文件管理）
  - [x] SubTask 18.2: 实现栏宽可拖拽调整
  - [x] SubTask 18.3: 设置窗口最小尺寸 1024x600

## Phase 5: 前端功能实现

- [ ] Task 19: 实现左栏 Agent 列表
  - [ ] SubTask 19.1: 实现 agent 列表数据模型与 API 调用
  - [ ] SubTask 19.2: 实现 agent 列表项 UI（头像、名称、类型标识、最后消息预览、未读数）
  - [ ] SubTask 19.3: 实现普通 agent 与无限上下文 agent 的视觉区分
  - [ ] SubTask 19.4: 实现点击切换中栏会话

- [ ] Task 20: 实现中栏消息交互区
  - [ ] SubTask 20.1: 实现消息列表 UI（用户消息右对齐、agent 消息左对齐）
  - [ ] SubTask 20.2: 实现消息输入框与发送（WebSocket）
  - [ ] SubTask 20.3: 实现流式消息接收与实时渲染
  - [ ] SubTask 20.4: 实现文件上传到消息（附件卡片展示）
  - [ ] SubTask 20.5: 实现云端运行模式切换

- [ ] Task 21: 实现右栏文件管理
  - [ ] SubTask 21.1: 实现顶部 agent 工作目录文件树展示（展开/折叠、文件名/大小/时间）
  - [ ] SubTask 21.2: 实现 Git 历史查看（提交历史含子 agent push 记录、diff 查看、分支列表/合并状态）
  - [ ] SubTask 21.3: 实现文件点击打开查看器
  - [ ] SubTask 21.4: 实现双向文件同步（云端→本地、本地→云端，进度展示）

- [ ] Task 22: 实现文件查看器
  - [ ] SubTask 22.1: 实现 UTF-8 文本文件查看器（语法高亮）
  - [ ] SubTask 22.2: 实现 .md 文件原文件+预览（分屏/切换模式）
  - [ ] SubTask 22.3: 实现 .svg 文件原文件+预览
  - [ ] SubTask 22.4: 实现 .pdf 文件查看器
  - [ ] SubTask 22.5: 实现 .docx/.doc/.odt/.rtf 文件查看器
  - [ ] SubTask 22.6: 实现 .pptx 文件查看器
  - [ ] SubTask 22.7: 实现 .xlsx/.xls 文件查看器
  - [ ] SubTask 22.8: 实现 .jpg/.png 图片查看器
  - [ ] SubTask 22.9: 实现一键复制按钮（复制文件内容到剪贴板）

## Phase 6: 集成与测试

- [ ] Task 23: 前后端集成测试
  - [ ] SubTask 23.1: 微信登录全流程联调
  - [ ] SubTask 23.2: agent 对话全流程联调（消息发送→agent 回复→流式展示）
  - [ ] SubTask 23.3: 文件上传/下载/同步全流程联调
  - [ ] SubTask 23.4: 多 agent 团队协作场景测试（创建成员→分配任务→Git 提交→父 agent review→merge）
  - [ ] SubTask 23.5: 团队层级限制测试（Level 3 不可创建子团队）

- [ ] Task 24: 无限上下文 LLM 专项测试
  - [ ] SubTask 24.1: 测试上下文原子追加正确性
  - [ ] SubTask 24.2: 测试前缀不一致时的拒绝与警告
  - [ ] SubTask 24.3: 测试跨任务上下文保留
  - [ ] SubTask 24.4: 测试上下文持久化与崩溃恢复

# Task Dependencies
- Task 2 依赖 Task 1
- Task 3 依赖 Task 1
- Task 3.5 依赖 Task 3
- Task 4 依赖 Task 1, Task 3
- Task 5 依赖 Task 4, Task 9.5
- Task 6 依赖 Task 4
- Task 7 依赖 Task 4, Task 3, Task 3.5
- Task 8 依赖 Task 7, Task 15
- Task 9 依赖 Task 7, Task 3.5
- Task 9.5 依赖 Task 7
- Task 10 依赖 Task 11
- Task 11 依赖 Task 1
- Task 12 依赖 Task 11, Task 3
- Task 13 依赖 Task 4, Task 12
- Task 14 依赖 Task 4
- Task 14.5 依赖 Task 4, Task 9
- Task 15 依赖 Task 1, Task 4
- Task 16 无依赖（可与后端并行）
- Task 17 依赖 Task 16, Task 2
- Task 18 依赖 Task 16
- Task 19 依赖 Task 18, Task 15
- Task 20 依赖 Task 18, Task 15
- Task 21 依赖 Task 18, Task 15
- Task 22 依赖 Task 21
- Task 23 依赖 Task 15, Task 19, Task 20, Task 21, Task 22
- Task 24 依赖 Task 14, Task 23
