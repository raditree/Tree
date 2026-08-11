# Agent Team Desktop 效率工具 Spec

## Why
当前缺乏一款能够根据任务难度动态配置 agent 团队规模、适配无限上下文 LLM 的桌面端效率工具。本产品旨在填补这一空白，提供云端运行模式 + 本地控制的混合工作流，让 LLM agent 团队像飞书团队一样协作。

## What Changes
- 新建 Python 后端服务（`server/`），提供 LLM agent 团队的完整运行时
- 新建 Flutter 桌面前端，提供三栏式工作界面（agent 列表 | 消息交互 | 文件管理）
- 接入微信登录认证体系
- 实现 Docker 多 agent 工作空间隔离（每个工作空间初始化为 Git 仓库）
- 实现 Git 仓库层级架构：子 agent 通过 git push 向父 agent 提交工作成果，用户仅可见顶部 agent 工作目录
- 实现团队层级限制（至多四级：Level 0-3）
- 实现 LLM OpenAI 协议接入 + 每模型独立配置文件
- 实现内置 tool_call 体系：help / team / set / mcp / refresh
  - team 工具涵盖：成员管理（创建含模型池选择、成员管理表含多维评分、查询、状态查询）、消息管理（点对点、广播、文件发送）、任务管理（分配、跟踪）
- 实现 MCP 工具集成：read / write / edit / terminal / embed_search
- 实现普通 LLM 记忆管理 + 无限上下文 LLM 原子上下文管理 + 上下文持久化
- 实现 agent 上下文隔离（子 agent 工作成果通过摘要汇报，不淹没父 agent 上下文）
- 实现文件查看器（多格式）+ 双向文件同步 + Git 历史查看
- **BREAKING**: 替换当前 Flutter 模板计数器应用为完整应用框架

## Impact
- Affected code: `lib/main.dart`（完全重写）、`pubspec.yaml`（新增大量依赖）、`windows/runner/runner.exe.manifest`（已配置 Win7，无需改动）
- New code: `server/` 目录（全新 Python 后端）、`lib/` 下多个模块
- 外部依赖: Docker（后端工作空间隔离 + Git remote 网络）、Visual Studio 2019 Build Tools（已安装）

---

## ADDED Requirements

### Requirement: 后端项目结构与基础服务
后端 SHALL 在 `server/` 目录下创建 Python 3.10+ 项目，提供 HTTP/WebSocket API 服务。

#### Scenario: 后端启动
- **WHEN** 执行 `python server/main.py`
- **THEN** 服务在配置端口启动，提供 REST API 和 WebSocket 端点
- **AND** 加载所有模型配置文件（`server/configs/models/` 下每个 `.yaml` 一个模型）
- **AND** 初始化 Docker 客户端连接

#### Scenario: 模型配置文件
- **WHEN** 后端启动时扫描 `server/configs/models/` 目录
- **THEN** 每个 `.yaml` 文件解析为一个模型配置，包含：`name`、`base_url`、`api_key`、`model_id`、`is_limitless_context`（布尔）、以及该模型特有的参数（如 `max_seqlen`、`temperature`、`top_k` 等）
- **AND** 配置文件中 `is_limitless_context: true` 的模型被标记为无限上下文类型

---

### Requirement: 微信登录认证
系统 SHALL 支持微信扫码登录，前端展示微信登录二维码，后端验证微信 OAuth 回调。

#### Scenario: 微信登录流程
- **WHEN** 用户打开应用未登录时
- **THEN** 前端展示微信登录二维码页面
- **AND** 后端调用微信 OAuth API 生成二维码
- **WHEN** 用户扫码确认
- **THEN** 后端收到微信回调，获取 access_token 和用户信息
- **AND** 后端生成 JWT 会话 token 返回前端
- **AND** 前端保存 token 并跳转到主界面

#### Scenario: 会话保持
- **WHEN** 前端携带 JWT token 请求 API
- **THEN** 后端验证 token 有效性，无效时返回 401
- **AND** 前端收到 401 后跳转回登录页

---

### Requirement: Docker 多 Agent 工作空间隔离
后端 SHALL 为每个 agent 工作空间创建独立的 Docker 容器，实现文件系统和进程隔离。每个工作空间初始化为 Git 仓库。

#### Scenario: 创建工作空间
- **WHEN** 系统为 agent 创建新工作空间时
- **THEN** 后端启动一个 Docker 容器，挂载独立的工作目录卷
- **AND** 容器内工作目录路径为 `/workspace`
- **AND** 容器内预装 MCP 工具运行所需环境
- **AND** 工作目录初始化为 Git 仓库（`git init`）
- **AND** 配置 Git 用户信息（agent 名称作为 user.name）
- **AND** 创建 `.self/` 目录用于存储 agent 元数据（memory.md、team_roster.md 等）

#### Scenario: 工作空间 Git Remote 配置
- **WHEN** 子 agent 工作空间创建时
- **THEN** 父 agent 的工作空间被配置为子 agent 的 Git remote
- **AND** 子 agent 可通过 Docker 网络访问父 agent 的 Git remote 地址
- **AND** 子 agent 工作完成后可通过 `git push` 提交工作成果到父 agent

#### Scenario: 工作空间生命周期
- **WHEN** agent 任务完成且不再需要工作空间
- **THEN** 后端可停止/删除容器，但工作目录卷保留（可手动清理）
- **AND** 容器状态变更同步通知前端

#### Scenario: 资源限制
- **WHEN** 创建工作空间时
- **THEN** Docker 容器设置资源配额（CPU、内存、磁盘上限可配置）
- **AND** 每级团队最大成员数可配置（默认 10）

---

### Requirement: Git 仓库架构与工作目录层级
系统 SHALL 基于 Git 仓库实现 agent 间工作成果的层级化同步。用户仅可见顶部 agent 的工作目录。

#### Scenario: 工作目录层级
- **WHEN** 系统运行时
- **THEN** 顶部 agent（Level 0）的工作目录是用户唯一可见的工作目录
- **AND** 子 agent 的工作目录对用户不可见
- **AND** 子 agent 工作成果通过 Git 提交同步到父 agent 仓库

#### Scenario: Git 工作流
- **WHEN** 子 agent 完成工作
- **THEN** 子 agent 在自己的工作目录中 `git commit` 工作成果
- **AND** 子 agent 通过 `git push` 提交到父 agent 的 Git remote
- **AND** 每个子 agent 使用独立分支（分支名 = 成员 ID），避免并发冲突
- **WHEN** 父 agent 需要 review 子 agent 工作
- **THEN** 父 agent 可 `git fetch` + `git diff` 查看子 agent 的提交
- **AND** 父 agent 决定是否 `git merge` 合并到主分支

#### Scenario: 用户可见的工作目录
- **WHEN** 用户通过前端文件管理查看文件
- **THEN** 展示的是顶部 agent 工作目录的 Git 仓库内容
- **AND** 可查看 Git 提交历史（包含所有子 agent 的提交记录）
- **AND** 可查看分支列表和合并状态

#### Scenario: Git 作为检查点
- **WHEN** agent 崩溃或异常终止
- **THEN** 可从最后一次 Git 提交恢复工作进度
- **AND** 父 agent 仓库保留了所有子 agent 的提交历史

---

### Requirement: 团队层级限制
系统 SHALL 限制团队嵌套层级至多四级，防止过度递归。

#### Scenario: 层级定义
- **WHEN** 系统运行时
- **THEN** 团队层级至多四级：Level 0（顶部主 agent）→ Level 1 → Level 2 → Level 3
- **AND** Level 3 agent 不可继续创建子团队

#### Scenario: 创建成员时层级校验
- **WHEN** agent 通过 `team` 工具创建新成员
- **THEN** 系统检查当前 agent 的层级深度
- **AND** 如果当前 agent 已是 Level 3，拒绝创建并返回错误提示
- **AND** 新成员层级 = 当前 agent 层级 + 1

#### Scenario: set.teammates 中的递归建队控制
- **WHEN** LLM 通过 `set` 工具设置 `teammates` 参数
- **THEN** 可为每个成员设置 `can_lead_team` 标志（是否允许继续带团队）
- **AND** 即使 `can_lead_team: true`，Level 3 成员仍不可创建子团队（系统强制限制）

---

### Requirement: Agent 上下文隔离与控制
系统 SHALL 控制 agent 上下文增长，避免顶部 agent 上下文被子 agent 详细工作过程淹没。

#### Scenario: 子 agent 工作成果汇报
- **WHEN** 子 agent 完成任务
- **THEN** 子 agent 通过 Git 提交工作成果
- **AND** 子 agent 向父 agent 发送工作成果摘要消息（非完整工作过程）
- **AND** 父 agent 上下文仅接收摘要，不包含子 agent 的完整工作日志

#### Scenario: 顶部 agent 上下文内容
- **WHEN** 顶部 agent 维护上下文
- **THEN** 上下文主要包含：任务描述、团队成员信息、关键决策记录、子 agent 工作成果摘要
- **AND** 不包含子 agent 的逐条 tool_call 执行记录

---

### Requirement: 无限上下文 LLM 上下文持久化
系统 SHALL 将无限上下文 LLM 的完整上下文定期持久化到磁盘，支持崩溃恢复。

#### Scenario: 上下文持久化
- **WHEN** 无限上下文 LLM 每次完成一轮交互后
- **THEN** 系统将完整上下文持久化到工作目录 `.self/context_snapshot.json`
- **AND** 持久化操作在 LLM 回复完成后异步执行，不阻塞交互

#### Scenario: 崩溃恢复
- **WHEN** 无限上下文 LLM 的 agent 崩溃后重启
- **THEN** 系统从 `.self/context_snapshot.json` 恢复完整上下文
- **AND** 验证恢复的上下文前缀一致性
- **AND** 如果恢复失败，记录严重警告并通知前端

---

### Requirement: LLM 接入与 OpenAI 协议
后端 SHALL 通过 Python OpenAI SDK 调用 LLM，遵循 OpenAI 协议，每个模型一个配置文件。

#### Scenario: 普通 LLM 调用
- **WHEN** agent 需要与普通 LLM 交互
- **THEN** 后端使用对应模型配置创建 OpenAI client
- **AND** 注入系统提示词（含记忆内容）+ 对话历史
- **AND** 注册内置 tool_call 函数
- **AND** 将 LLM 返回的 tool_call 分发执行，循环直到 LLM 返回最终文本

#### Scenario: 无限上下文 LLM 调用
- **WHEN** agent 需要与无限上下文 LLM 交互
- **THEN** 后端确保本次输入前缀与上一次输入完全一致（原子追加）
- **AND** 仅追加新内容到上下文末尾
- **AND** 如果检测到前缀不一致，记录警告日志并拒绝发送
- **AND** 上下文跨任务持久保留，不执行上下文压缩

---

### Requirement: 内置 Tool — help
系统 SHALL 提供 `help` 工具，列出所有内置工具及其介绍。

#### Scenario: 调用 help
- **WHEN** LLM 调用 `help` 工具
- **THEN** 返回所有内置工具的名称和功能描述
- **AND** 返回当前可用的 MCP 工具列表（通过 refresh 获取的）

---

### Requirement: 内置 Tool — team
系统 SHALL 提供 `team` 工具，涵盖成员管理、消息管理、任务管理三大子域（对标飞书）。

#### Scenario: 创建成员
- **WHEN** LLM 通过 `team` 工具请求创建新成员
- **THEN** 系统返回可用模型池列表（含每个模型的名称、能力描述、上下文长度、是否无限上下文）
- **AND** LLM 从模型池中选择合适模型
- **AND** 后端为新成员分配 agent 实例
- **AND** 后端创建 Docker 工作空间（含 Git 仓库初始化、父 agent Git remote 配置）
- **AND** 配置基本信息：成员 ID（唯一）、名称、模型、层级深度（= 父层级 + 1）
- **AND** 新成员作为独立个体持久保留（不随任务结束而销毁）
- **AND** 新成员记录到当前 agent 的 `.self/team_roster.md` 成员管理表
- **AND** 返回成员 ID 和基本信息

#### Scenario: 成员管理表
- **WHEN** agent 维护团队成员时
- **THEN** 成员管理表存储在 agent 工作目录的 `.self/team_roster.md` 中
- **AND** 表格记录每个成员的：ID、名称、模型、层级、创建时间、工作状态、简短评价、多维评分
- **AND** 多维评分维度包括：任务完成质量、效率、协作性、准确性
- **AND** 评分由父 agent 在子 agent 完成任务后填写
- **AND** 评分作为未来 `set.teammates` 选择成员的参考依据

#### Scenario: 成员查询
- **WHEN** LLM 通过 `team` 工具查询成员
- **THEN** 可查询所有成员列表（返回完整成员管理表）
- **AND** 可按条件筛选（按模型、按层级、按工作状态、按评分）
- **AND** 可查询单个成员详细信息

#### Scenario: 工作状态查询
- **WHEN** LLM 通过 `team` 工具查询成员工作状态
- **THEN** 返回成员当前状态（空闲、工作中、等待输入、已停止、异常）
- **AND** 返回当前正在执行的任务描述（如工作中）
- **AND** 返回最后一次 Git 提交信息（时间、message、hash）

#### Scenario: 点对点消息发送
- **WHEN** LLM 通过 `team` 工具向指定成员发送消息
- **THEN** 消息被路由到目标成员的 agent 上下文
- **AND** 消息通过 WebSocket 实时推送到前端对应会话
- **AND** 消息记录在双方的对话历史中

#### Scenario: 广播消息
- **WHEN** LLM 通过 `team` 工具广播消息
- **THEN** 消息同时发送给所有团队成员
- **AND** 每个成员的 agent 上下文收到该消息
- **AND** 前端所有相关会话更新

#### Scenario: 文件发送
- **WHEN** LLM 通过 `team` 工具向成员发送文件
- **THEN** 文件从发送者工作空间复制到接收者工作空间
- **AND** 接收者收到文件路径通知
- **AND** 文件发送与 Git 提交独立（即时通信，不等同于工作成果提交）

#### Scenario: 任务分配
- **WHEN** LLM 通过 `team` 工具向成员分配任务
- **THEN** 任务包含：任务描述、优先级、预期输出
- **AND** 任务记录在成员的任务队列中
- **AND** 成员工作状态更新为"工作中"
- **AND** 任务完成后成员通过 Git 提交工作成果并通知父 agent

#### Scenario: 任务跟踪
- **WHEN** LLM 通过 `team` 工具查询任务状态
- **THEN** 返回所有已分配任务的状态（待执行、进行中、已完成、失败）
- **AND** 返回任务关联的 Git 提交记录（如有）

---

### Requirement: 内置 Tool — set
系统 SHALL 提供 `set` 工具，允许 LLM 设置自身参数。

#### Scenario: 普通 LLM 设置参数
- **WHEN** 普通 LLM 调用 `set` 工具
- **THEN** 可设置以下参数：
  - `max_seqlen`：决定上下文压缩时机（必须 < OpenAI SDK 返回的上下文长度上限）
  - `temperature`：采样温度
  - `top_k`：Top-K 采样
  - `teammates`：从已存在成员中选择本次任务的团队成员，可为每个成员设置 `can_lead_team`（是否允许继续带团队），选择时可参考成员管理表中的多维评分
  - `mcp_tools`：从 refresh 返回的所有工具中选择本次任务的 MCP 工具
- **AND** 参数变更立即生效

#### Scenario: 无限上下文 LLM 设置参数
- **WHEN** 无限上下文 LLM 调用 `set` 工具
- **THEN** 可设置以下参数：
  - `temperature`
  - `top_k`
  - `teammates`（同普通 LLM，含 `can_lead_team` 设置）
  - `mcp_tools`
- **AND** 不可设置 `max_seqlen`（无限上下文不需要压缩）

#### Scenario: set 推荐时机
- **WHEN** 新任务开始
- **THEN** 系统推荐 LLM 调用 `set` 设置一次参数
- **AND** 任务进行中可根据需要自行调整

---

### Requirement: 内置 Tool — mcp
系统 SHALL 提供 `mcp` 工具，通过 Python MCP SDK 接入外部工具。

#### Scenario: MCP help 命令
- **WHEN** LLM 通过 `mcp` 工具传入 `help` 参数
- **THEN** 返回所有可用 MCP 服务及其工具列表
- **AND** 可进一步查看各个 MCP 工具的具体使用方法

#### Scenario: 调用 MCP 工具
- **WHEN** LLM 通过 `mcp` 工具指定调用某个 MCP 工具
- **THEN** 后端通过 Python MCP SDK 执行该工具
- **AND** 返回执行结果给 LLM

---

### Requirement: 内置 Tool — refresh
系统 SHALL 提供 `refresh` 工具，刷新并返回所有可用的 MCP 工具。

#### Scenario: 刷新全部 MCP 工具
- **WHEN** LLM 调用 `refresh` 工具（无参数）
- **THEN** 返回所有已注册 MCP 服务提供的全部工具列表
- **AND** 每个工具包含名称、描述、参数 schema

#### Scenario: 仅返回本次任务的 MCP 工具
- **WHEN** LLM 调用 `refresh` 工具并指定 `task_only: true`
- **THEN** 仅返回通过 `set` 工具的 `mcp_tools` 参数选中的工具

---

### Requirement: 基础 MCP 工具集
系统 SHALL 提供以下基础 MCP 工具，运行在 agent 的 Docker 工作空间内。

#### Scenario: read 工具
- **WHEN** LLM 调用 `read` MCP 工具
- **THEN** 读取工作空间内指定文件内容
- **AND** 支持指定编码（默认 UTF-8）

#### Scenario: write 工具
- **WHEN** LLM 调用 `write` MCP 工具
- **THEN** 将内容写入工作空间内指定文件
- **AND** 自动创建不存在的父目录

#### Scenario: edit 工具
- **WHEN** LLM 调用 `edit` MCP 工具
- **THEN** 对指定文件执行精确字符串替换
- **AND** 替换失败时返回错误信息（未找到匹配 / 多处匹配）

#### Scenario: terminal 工具
- **WHEN** LLM 调用 `terminal` MCP 工具
- **THEN** 在 Docker 容器内执行 shell 命令
- **AND** 返回 stdout、stderr 和退出码
- **AND** 支持设置超时时间

#### Scenario: embed_search 工具
- **WHEN** LLM 调用 `embed_search` MCP 工具
- **THEN** 对工作空间内文件进行向量嵌入搜索
- **AND** 返回最相关的文件片段及其来源路径

---

### Requirement: 普通 LLM 记忆管理
系统 SHALL 为普通 LLM 提供系统辅助记忆管理。

#### Scenario: 记忆存储
- **WHEN** agent 工作空间初始化时
- **THEN** 在工作目录下创建 `.self/memory.md` 文件
- **AND** 记忆文件初始为空或包含模板

#### Scenario: 记忆注入
- **WHEN** 普通 LLM 初始化上下文时
- **THEN** 系统将 `.self/memory.md` 内容注入到系统提示词下方
- **AND** 记忆内容作为系统提示词的一部分发送给 LLM

#### Scenario: 记忆更新提示
- **WHEN** 满足记忆更新触发条件时（如每次结束任务后、上下文压缩前）
- **THEN** 系统发送 tool 提示词要求 LLM 更新记忆
- **AND** LLM 通过 write 工具更新 `.self/memory.md`

---

### Requirement: 无限上下文 LLM 上下文管理
系统 SHALL 对无限上下文 LLM 执行严格的原子上下文管理。

#### Scenario: 上下文原子追加
- **WHEN** 向无限上下文 LLM 发送新消息
- **THEN** 系统验证新输入的前缀与上次输入完全一致
- **AND** 仅在末尾追加新内容
- **AND** 整个操作为原子操作（不允许部分写入）

#### Scenario: 上下文一致性检查
- **WHEN** 检测到前缀不一致
- **THEN** 生产环境：记录警告日志，拒绝发送，通知前端
- **AND** 测试环境：断言失败，终止测试

#### Scenario: 跨任务上下文保留
- **WHEN** 无限上下文 LLM 完成一个任务，开始新任务
- **THEN** 上下文持久保留，不从创建起删除或压缩
- **AND** 新任务的消息继续原子追加到现有上下文

#### Scenario: 无需记忆注入
- **WHEN** 无限上下文 LLM 初始化上下文时
- **THEN** 不注入 `.self/memory.md` 内容（因其上下文已持久保留全部历史）

---

### Requirement: 前端项目框架与路由
前端 SHALL 建立完整的应用框架，替换当前模板代码。

#### Scenario: 应用启动
- **WHEN** 用户启动应用
- **THEN** 检查本地是否有有效 JWT token
- **AND** 有则跳转主界面，无则跳转微信登录页

#### Scenario: 路由结构
- **WHEN** 应用运行时
- **THEN** 提供以下路由：`/login`（微信登录）、`/main`（主工作界面）
- **AND** 主界面为三栏布局

---

### Requirement: 三栏布局主界面
前端 SHALL 提供三栏式主工作界面，对标微信桌面端布局。

#### Scenario: 三栏布局
- **WHEN** 用户进入主界面
- **THEN** 界面从左到右分为三栏：
  - 左栏（~260px）：Agent 列表
  - 中栏（弹性宽度）：消息交互区
  - 右栏（~340px）：文件管理区
- **AND** 各栏宽度可拖拽调整
- **AND** 窗口最小尺寸不小于 1024x600

---

### Requirement: 左栏 — Agent 列表
前端 SHALL 在左栏展示 agent 列表，对标微信消息列表样式。

#### Scenario: Agent 列表展示
- **WHEN** 用户查看左栏
- **THEN** 展示所有 agent，每个 agent 显示：头像/图标、名称、类型标识（普通/无限上下文）、最后消息预览、未读消息数
- **AND** 普通 agent 和无限上下文 LLM agent 有视觉区分（如图标颜色/角标）
- **AND** 点击 agent 切换中栏的消息会话

#### Scenario: Agent 类型区分
- **WHEN** 渲染 agent 列表项
- **THEN** 普通 agent 显示一种图标样式
- **AND** 无限上下文 LLM agent 显示不同图标样式（如特殊徽章）
- **AND** 类型判断由后端返回，前端仅作展示

---

### Requirement: 中栏 — 消息交互区
前端 SHALL 在中栏展示消息交互界面，对标微信聊天界面。

#### Scenario: 消息展示
- **WHEN** 用户选中某个 agent
- **THEN** 中栏展示与该 agent 的消息历史
- **AND** 用户消息右对齐，agent 消息左对齐
- **AND** 消息支持文本、图片、文件附件展示
- **AND** 消息流式输出（agent 回复实时显示）

#### Scenario: 发送消息
- **WHEN** 用户在输入框输入消息并发送
- **THEN** 消息通过 WebSocket 发送到后端
- **AND** 后端将消息路由到对应 agent
- **AND** agent 回复通过 WebSocket 流式推送到前端

#### Scenario: 上传文件到消息
- **WHEN** 用户在消息输入区上传文件
- **THEN** 文件上传到后端并关联到当前会话
- **AND** 文件在消息流中以附件卡片展示
- **AND** 上传的文件同步出现在右栏文件管理中

#### Scenario: 云端运行模式
- **WHEN** 云端模式开启时
- **THEN** 所有实际操作在服务器上执行
- **AND** 工作目录内所有文件同步到云端
- **AND** 前端仅展示操作结果

---

### Requirement: 右栏 — 文件管理
前端 SHALL 在右栏展示文件管理界面，展示顶部 agent（Level 0）的工作目录 Git 仓库内容。

#### Scenario: 云端文件目录浏览
- **WHEN** 用户查看右栏
- **THEN** 展示顶部 agent 工作目录的文件树
- **AND** 支持展开/折叠目录
- **AND** 显示文件名、大小、修改时间

#### Scenario: Git 历史查看
- **WHEN** 用户查看 Git 历史
- **THEN** 展示提交历史（包含所有子 agent 的 push 记录）
- **AND** 可查看每次提交的 diff
- **AND** 可查看分支列表和合并状态

#### Scenario: 查看文件内容
- **WHEN** 用户点击文件
- **THEN** 在文件查看器中打开文件
- **AND** 根据文件类型展示原文件或预览

#### Scenario: 双向文件同步
- **WHEN** 用户选择"同步到本地"
- **THEN** 将云端文件下载到本地指定目录
- **WHEN** 用户选择"上传到云端"
- **THEN** 将本地文件上传到云端工作目录
- **AND** 同步进度实时展示

---

### Requirement: 文件查看器
前端 SHALL 提供文件查看器，支持多种文件格式。

#### Scenario: 支持的文件格式
- **WHEN** 用户打开文件查看器
- **THEN** 支持以下格式：
  - 任何 UTF-8 文本文件（.txt .py .js .json .yaml .xml .csv 等）
  - .docx .odt .doc .rtf
  - .pdf
  - .pptx
  - .xlsx .xls
  - .jpg .png

#### Scenario: 原文件 + 预览
- **WHEN** 用户查看支持预览的文件（如 .md .svg）
- **THEN** 同时展示原文件内容和渲染后的预览
- **AND** 可切换查看模式（仅原文 / 仅预览 / 分屏）

#### Scenario: 一键复制
- **WHEN** 用户点击文件查看器中的"复制"按钮
- **THEN** 文件内容复制到系统剪贴板
- **AND** 用户可粘贴到其他应用

---

### Requirement: 前后端通信协议
系统 SHALL 定义前后端通信协议，基于 HTTP REST + WebSocket。

#### Scenario: REST API
- **WHEN** 前端需要请求-响应式操作（登录、文件列表、文件同步等）
- **THEN** 使用 HTTP REST API，携带 JWT token

#### Scenario: WebSocket 实时通信
- **WHEN** 前端需要实时消息（agent 对话、agent 状态变更、文件同步进度等）
- **THEN** 使用 WebSocket 长连接
- **AND** 消息格式为 JSON，包含 `type` 字段区分消息类型

---

## MODIFIED Requirements

### Requirement: Flutter 应用入口
当前 `lib/main.dart` 为模板计数器应用，SHALL 被替换为完整应用入口。

#### Scenario: 新应用入口
- **WHEN** 应用启动
- **THEN** 初始化路由管理、主题配置、WebSocket 连接管理
- **AND** 根据登录状态路由到 `/login` 或 `/main`
- **AND** 移除计数器相关代码

---

## REMOVED Requirements

### Requirement: 模板计数器应用
**Reason**: 替换为完整的 Agent Team 效率工具应用
**Migration**: 删除 `lib/main.dart` 中的 `MyApp`、`MyHomePage`、`_MyHomePageState` 及计数器逻辑，替换为新应用框架
