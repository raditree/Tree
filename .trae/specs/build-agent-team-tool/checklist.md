# Checklist

## 后端基础架构
- [x] `server/` 目录结构完整，包含 `main.py`、`api/`、`core/`、`tools/`、`mcp_tools/`、`configs/models/`、`configs/app.yaml`
- [x] `requirements.txt` 包含所有必要依赖且版本兼容 Python 3.10+
- [x] FastAPI 服务可正常启动，提供 REST 和 WebSocket 端点
- [x] 应用配置从 `configs/app.yaml` 正确加载（端口、Docker、微信 OAuth、资源配额、最大成员数）
- [x] 模型配置文件可从 `configs/models/*.yaml` 正确扫描和解析
- [x] 模型配置包含 `is_limitless_context` 字段用于区分模型类型

## 微信登录认证
- [x] 后端微信 OAuth 接口可生成二维码 URL
- [x] 微信回调可正确获取 access_token 和用户信息
- [x] JWT token 可正确生成和验证
- [x] 无效 token 请求返回 401
- [x] 前端未登录时跳转登录页

## Docker 工作空间隔离与 Git 初始化
- [x] 可为 agent 创建独立 Docker 容器
- [x] 容器内工作目录挂载为 `/workspace`
- [x] 工作目录初始化为 Git 仓库（`git init`、配置 user.name）
- [x] `.self/` 目录已创建用于存储 agent 元数据
- [x] 容器可正常停止/删除，卷数据保留
- [ ] 容器状态变更可通知前端
- [ ] Docker 资源配额（CPU/内存/磁盘）已设置
- [x] 每级团队最大成员数可配置

## Git 仓库层级架构
- [x] 父 agent 工作空间可作为 Git remote 被子 agent push
- [x] 子 agent 创建时自动配置父 agent Git remote 地址
- [x] Docker 网络确保子 agent 可访问父 agent Git remote
- [x] 子 agent 使用独立分支（分支名 = 成员 ID）
- [x] 父 agent 可 fetch + diff + merge 子 agent 分支
- [x] Git 提交历史查询 API 可供前端展示
- [x] 用户仅可见顶部 agent 工作目录

## 团队层级限制
- [x] 团队层级至多四级（Level 0-3）
- [x] Level 3 agent 不可创建子团队（系统强制拒绝）
- [x] 创建成员时新成员层级 = 父 agent 层级 + 1
- [ ] set.teammates 中 can_lead_team 与层级限制联合校验

## LLM 接入层
- [x] 普通 LLM 调用流程：注入系统提示词+记忆 → 注册 tool_call → 循环执行 → 返回结果
- [x] 普通 LLM 上下文压缩在 `max_seqlen` 阈值时触发
- [x] 无限上下文 LLM 调用时验证前缀一致性
- [x] 无限上下文 LLM 上下文跨任务持久保留
- [x] 无限上下文 LLM 不执行上下文压缩

## Agent 上下文隔离
- [x] 子 agent 工作成果通过摘要汇报（非完整工作日志）
- [x] 顶部 agent 上下文不包含子 agent 逐条 tool_call 执行记录
- [ ] 顶部 agent 上下文包含：任务描述、团队成员信息、关键决策、工作成果摘要

## 内置工具 — set
- [x] 普通 LLM 可设置 max_seqlen、temperature、top_k、teammates（含 can_lead_team）、mcp_tools
- [x] 无限上下文 LLM 不可设置 max_seqlen
- [ ] max_seqlen 设置值 < OpenAI SDK 返回的上下文长度上限
- [x] teammates 选择可参考成员管理表中的多维评分
- [x] 新任务开始时系统推荐调用 set

## 内置工具 — help
- [x] help 返回所有内置工具名称和描述
- [x] help 返回当前可用的 MCP 工具列表

## 内置工具 — team（成员管理）
- [ ] 创建成员时返回可用模型池列表（名称/能力描述/上下文长度/是否无限上下文）
- [x] LLM 可从模型池中选择模型
- [x] 创建成员时分配 agent 实例 + Docker 工作空间（含 Git 初始化）
- [x] 成员配置包含 ID、名称、模型、层级深度
- [x] 新成员持久保留（不随任务结束销毁）
- [x] 成员管理表存储在 `.self/team_roster.md`
- [x] 成员管理表记录：ID/名称/模型/层级/创建时间/工作状态/评价/多维评分
- [x] 多维评分维度：任务完成质量、效率、协作性、准确性
- [x] 评分由父 agent 在子 agent 完成任务后填写
- [x] 成员查询支持全量列表、按条件筛选、单成员详情
- [x] 工作状态查询返回：状态/当前任务/最后一次 Git 提交信息

## 内置工具 — team（消息管理）
- [ ] 点对点消息可正确路由到目标成员 agent 上下文
- [ ] 消息通过 WebSocket 实时推送到前端
- [x] 广播消息可同时发送所有团队成员
- [x] 文件发送可在工作空间间复制文件
- [x] 文件发送与 Git 提交独立（即时通信）

## 内置工具 — team（任务管理）
- [x] 任务分配包含任务描述/优先级/预期输出
- [x] 任务记录在成员任务队列中
- [x] 任务完成后成员通过 Git 提交工作成果并通知父 agent
- [x] 父 agent 对子 agent 工作成果评分后更新成员管理表
- [x] 任务跟踪可查询所有任务状态和关联 Git 提交记录

## 内置工具 — refresh
- [x] refresh 无参数时返回所有 MCP 工具列表
- [x] refresh `task_only: true` 时仅返回 set.mcp_tools 选中的工具
- [x] 每个工具返回包含名称、描述、参数 schema

## 内置工具 — mcp
- [ ] mcp help 返回所有 MCP 服务及工具列表
- [ ] 可查看各 MCP 工具的具体使用方法
- [ ] MCP 工具调用可通过 Python MCP SDK 执行

## 基础 MCP 工具集
- [x] read：可读取工作空间内文件，支持编码指定
- [x] write：可写入文件，自动创建父目录
- [x] edit：精确字符串替换，未找到/多处匹配时返回错误
- [ ] terminal：Docker 内 shell 执行（含 git 命令），返回 stdout/stderr/退出码，支持超时
- [ ] embed_search：向量嵌入搜索，返回相关片段和来源路径

## 记忆管理
- [x] 工作空间初始化时创建 `.self/memory.md`
- [x] 普通 LLM 上下文初始化时注入记忆到系统提示词
- [x] 任务结束后/上下文压缩前发送记忆更新提示
- [x] 无限上下文 LLM 不注入记忆

## 无限上下文 LLM 上下文一致性与持久化
- [x] 新输入前缀与上次输入完全一致时才追加
- [x] 前缀不一致时生产环境记录警告并拒绝发送
- [x] 测试环境前缀不一致时断言失败终止
- [x] 上下文跨任务持久保留
- [ ] 每次交互后异步持久化到 `.self/context_snapshot.json`
- [x] 崩溃后可从 snapshot 恢复完整上下文
- [ ] 恢复时验证前缀一致性
- [ ] 恢复失败时记录严重警告并通知前端

## 前端项目框架
- [x] `pubspec.yaml` 依赖兼容 Dart 2.19.6
- [ ] `lib/main.dart` 替换为完整应用入口（路由、主题、WebSocket 初始化）
- [x] 模板计数器代码已移除
- [x] 本地 JWT token 可正确存储和读取
- [x] 应用启动时根据登录状态路由

## 前端 — 微信登录页
- [x] 登录页展示微信二维码
- [x] 可轮询登录状态
- [x] 登录成功后保存 token 并跳转主界面

## 前端 — 三栏布局
- [x] 左栏（Agent 列表）、中栏（消息）、右栏（文件管理）三栏布局正确
- [x] 各栏宽度可拖拽调整
- [x] 窗口最小尺寸 1024x600

## 前端 — Agent 列表
- [x] 展示 agent 头像、名称、类型标识、最后消息预览、未读数
- [x] 普通 agent 与无限上下文 agent 有视觉区分
- [x] 类型判断由后端返回，前端仅展示
- [x] 点击 agent 切换中栏会话

## 前端 — 消息交互区
- [x] 用户消息右对齐，agent 消息左对齐
- [ ] 消息支持文本、图片、文件附件展示
- [x] 消息流式输出（实时显示）
- [x] 可通过 WebSocket 发送消息
- [ ] 可上传文件到消息（附件卡片展示，同步到文件管理）
- [x] 云端运行模式可切换

## 前端 — 文件管理
- [x] 展示顶部 agent 工作目录文件树（展开/折叠）
- [x] 显示文件名、大小、修改时间
- [ ] Git 历史查看（提交历史含子 agent push 记录、diff 查看、分支/合并状态）
- [x] 点击文件打开查看器
- [ ] 云端→本地同步可用，进度展示
- [ ] 本地→云端同步可用，进度展示

## 前端 — 文件查看器
- [ ] 支持 UTF-8 文本文件查看（语法高亮）
- [x] 支持 .md 原文件+预览（分屏/切换模式）
- [ ] 支持 .svg 原文件+预览
- [ ] 支持 .pdf 查看
- [ ] 支持 .docx/.doc/.odt/.rtf 查看
- [ ] 支持 .pptx 查看
- [ ] 支持 .xlsx/.xls 查看
- [x] 支持 .jpg/.png 图片查看
- [x] 一键复制按钮可将文件内容复制到剪贴板

## 前后端通信
- [ ] REST API 携带 JWT token 鉴权
- [ ] WebSocket 支持鉴权、心跳、重连
- [x] WebSocket 消息为 JSON 格式，含 `type` 字段
- [ ] agent 回复可流式推送到前端

## 集成测试
- [ ] 微信登录全流程通过
- [ ] agent 对话全流程通过（发送→回复→流式展示）
- [ ] 文件上传/下载/同步全流程通过
- [ ] 多 agent 团队协作场景通过（创建成员→分配任务→Git 提交→父 agent review→merge）
- [ ] 团队层级限制测试通过（Level 3 不可创建子团队）
- [x] 无限上下文 LLM 原子上下文操作测试通过
- [x] 无限上下文 LLM 前缀不一致拒绝测试通过
- [x] 无限上下文 LLM 跨任务上下文保留测试通过
- [x] 无限上下文 LLM 持久化与崩溃恢复测试通过

## Windows 7 兼容性
- [x] `windows/runner/runner.exe.manifest` 包含 Windows 7 supportedOS GUID
- [x] `flutter build windows --release` 可成功生成可执行文件
