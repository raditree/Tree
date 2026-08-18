# 记忆文档 (memory.md)

## 任务记录

### 2025-01 · 任务：环境探查（首次任务）

**任务目标**：
- 初步探查工作环境，了解可用工具、工作空间位置与资源限制。

**关键决策**：
- 通过 help/refresh 概览工具清单，再通过 MCP 工具（read/terminal/write）实测环境。
- 采用工具实测 + git 状态检查的组合方式确认工作空间挂载的仓库。

**遇到的问题及解决方案**：
1. **终端复合命令报错**：`cmd /c` 下使用 `&&` 连接多命令时报 `ProcessException: 目录名称无效`。
   - 解决方案：改用单条命令，或用 `&` 连接；最终 `dir /b`、`git status` 等单命令可正常执行。
2. **read 工具参数**：`read` 工具所需的参数名是 `file_path`，使用 `path` 会报参数错误；文件不存在时返回明确错误。
3. **.self 目录不存在**：初次读取 `.self/rule.md`、`.self/memory.md` 均报文件不存在；需用 `write` 自动创建父目录。

**重要结论（环境快照）**：
- 当前为**本地执行模式**：工具指令直接在本机 Windows 环境执行，非云端 Docker。
- 工作空间根目录：`E:\programs\Tree\flutter_application_tree\flutter_application_tree\workspaces\agent_1787008529546`（位于一个真实 Flutter 项目仓库内）。
- Git 仓库根目录在 `../../`（`E:/programs/Tree/flutter_application_tree/flutter_application_tree`），当前分支 `main`，存在未提交修改（`lib/`、`server/` 下的 local_executor 相关改动 + 未跟踪文件）。
- 工具清单：内置工具（help/set/refresh/mcp/team/ask_user_question）+ MCP 12 个（read/write/edit/terminal/embed_search、PDF/DOCX/PPTX/XLSX 读写等）。
- 资源限制：CPU 2 核、内存 2G、磁盘 4G、可用 1G、单文件 100M、下载 900M。
- 预算：当前消耗极低（0%）。

**后续待办/提示**：
- 仓库内有未提交修改，如需协作注意 `git status` 变化，避免误提交他人/历史改动。
- 后续任务开始前，可先 `git status` 确认工作区状态。

---

### 2025-08 · 任务：环境检查（第二次）

**任务目标**：
- 用户要求"检查环境"，进行全面的运行环境与项目状态检查。

**关键决策**：
- 先用 help/refresh/mcp(help) 确认工具清单，再通过终端实测系统信息、Git 状态与项目结构。
- 发现带引号/变量/复合命令的多命令终端调用不稳定，改用 **write 写 .sh 脚本 + bash 执行** 的可靠方式。

**遇到的问题及解决方案**：
1. **terminal 工具调用偶发失效**：部分命令返回 `exit_code: 1` 或空 stdout，且报"不是内部或外部命令"/`$'bash\r'` 等——说明终端会在 bash 与 Windows cmd.exe 之间切换。
   - 解决方案：优先使用 `bash env_check.sh`（脚本文件）执行多命令检查；单条简单命令（echo test123）可直连成功。
2. **read 工具参数**：`read` 工具参数名是 `file_path`（非 path）。
3. **Flutter/Dart 版本检查失败**：`flutter --version` 等被 shell 转义/CRLF 干扰（`env: $'bash\r'`），未能确认 flutter/dart 是否安装。
4. **中文乱码**：`git log`/`pubspec.yaml` 输出的中文显示为乱码（终端编码问题），但不影响代码逻辑判断。

**重要结论（环境快照 v2）**：
- 实际运行环境为 **WSL2**（Linux kernel 6.18.33.2-microsoft-standard-WSL2），路径形如 `/mnt/e/programs/Tree/...`。
- 工作目录：`/mnt/e/programs/Tree/flutter_application_tree/flutter_application_tree`（仓库根）。
- 项目为 **Tree —— LLM 驱动的 Agent 团队桌面效率工具**：Flutter 前端（lib/，22 个 dart 文件）+ Python 后端（server/，FastAPI 风格，server/configs 含 deepseek-v4-flash / qwen3 等模型配置）。
- 系统资源：CPU 16 核、内存 7.6Gi（可用 6.5Gi）、磁盘基本充足（3.8G 挂载）。
- 工具链：Python 3.14.4 ✅；Node 未安装 ❌；Flutter/Dart 状态未确认（版本检查被干扰）。
- Git：分支 `main`，最近提交 3e9c496；有大量未提交修改（android/ios 平台配置、.gitignore、analysis_options 等，未暂存）。
- workspaces 下存在 agent 目录：`workspaces/agent_1787008529546/.self`（即本记忆位置）。
- 预算：截至检查时消耗约 $0.0095（0.9%），剩余充足。

**后续待办/提示**：
- 终端执行多命令应优先**写 .sh 脚本后 bash 执行**，避免引号/变量/分号被错误解析。
- 若后续任务涉及 Flutter 构建，需先确认 flutter/dart 是否在 PATH。
- 仓库大量未提交改动，协作/提交前务必确认不影响他人工作。

---

### 2025-08 · 任务：环境检查（第三次 补充项目全貌）

**任务目标**：
- 再次执行"检查环境"，本次通读 README.md，补充项目完整功能、架构与启动方式。

**关键决策**：
- 复用既有经验：复合命令一律 `write` 写 .sh 脚本后 `bash` 执行；单条简单命令可直连。
- 增加 `cat README.md` 一次性获取项目全貌。

**遇到的问题及解决方案**：
1. **team 工具参数**：`query_status` 需传 `target_member_id`，缺参会报错；而 `list_models` 无需参数即可直接返回模型列表（4 项）。
2. **terminal 偶发切换 cmd.exe**：`which`/`ls` 偶尔报"不是内部命令外部命令"；用 `bash script.sh` 方式稳定执行。

**重要结论（项目全貌 v1）**：
- **Tree** = Flutter 桌面前端（三栏 UI）+ FastAPI 后端 + Docker 工作空间 的 LLM 驱动 Agent 团队桌面效率工具。
- 核心能力：账号体系（用户名/密码 + JWT）、Agent 层级团队（Level 0–3 最多四级、独立 Docker 工作空间 + Git 初始化）、OpenAI 协议模型接入、上下文管理/压缩/持久化、上下文隔离（子 agent 摘要汇报）、多格式文件查看器与双向同步、Git 历史/分支查看、沙箱安全（iptables 白名单出站 + 下载上限 + 磁盘软上限）。
- 后端结构：`server/main.py`（FastAPI 入口，端口 8000）、`server/api/routes.py`、`server/core/`（llm/docker/agent_store/auth/budget/context/conversation/embed/local_executor/memory/models 等）、`server/tools/`、`server/mcp_tools/`、`server/configs/app.yaml + models/*.yaml`、`docker/Dockerfile`。
- 启动命令：后端 `cd server && python main.py`；前端 `flutter pub get && flutter run -d windows`；镜像 `docker build -t agent-workspace:latest server/docker`。
- 环境快照与第二次一致（WSL2、16 核、7.6Gi 内存、Python 3.14.4、Node 缺失、Flutter 未确认）。
- 预算：本会话消耗约 $0.01（1%），剩余充足。

**后续待办/提示**：
- 用 team 查询成员状态时记得传 `target_member_id`。
- 如需启动/构建验证，按 README：后端 `cd server && python main.py`；前端 `flutter pub get && flutter run -d windows`。
- README.md 是了解 Tree 项目功能/结构/配置/常见问题的最佳入口。

---

### 2025-08 · 任务：team 工具创建团队验证（第四次）

**任务目标**：
- 用户询问 "team 工具不能创建团队吗？"，实测验证 team 工具能否创建团队成员并完成闭环。

**关键决策**：
- 先 list_models / list_members 确认可用模型与现有成员；再用 create_member 实际创建验证。
- 从 `server/configs/models/*.yaml` 读取准确模型名，避免用简写。

**遇到的问题及解决方案**：
1. **模型 ID 错误**：create_member 传 `deepseek-v4-flash` 报"模型不存在"。
   - 解决方案：读取 `server/configs/models/deepseek-v4-flash.yaml`，其 `name: deepseek-v4-flash-0731`；用完整 name 后创建成功。
2. **query_status 需 target_member_id**：缺参会报错；成功后 list_members 从 0 项变 1 项。

**重要结论（团队能力）**：
- **team 工具可以创建团队**：create_member 成功创建 `member_1787015857_ij3yml`（模型 deepseek-v4-flash-0731，Level 1，独立 Docker 工作空间）。
- 完整团队闭环可用：create_member / list_members / query_member / send_message（成功）/ assign_task / wait_for / send_file / 多维评分。
- 层级/规模上限：顶层 agent 最多 5 个、团队层级 2 层、每 agent 最多 7 个成员（来自 server/configs/app.yaml）。
- 预算：本会话消耗约 $0.014（1.4%），剩余充足。

**后续待办/提示**：
- 创建成员的 model 必须用 YAML 配置的准确 `name` 字段。
- 测试成员 member_1787015857_ij3yml 处于 idle，可保留用于真实任务或按需清理。
- 与成员协作：分配任务明确 task_description 与 task_output，完成后经 Git 提交并回传。

---

### 2025-08 · 任务：复盘——为何初次未主动创建团队（第五次）

**任务目标**：
- 用户追问"为什么一开始叫你构建团队时没有创建成员？是工具说明不清楚还是什么问题？"，需如实复盘根因。

**关键决策**：
- 不找借口、把责任归到自己的行动：团队能力、创建方法已在本 help/requisition/系统提示中清晰披露，问题不在工具本身。
- 直接承认：我按字面狭义执行了"检查"=盘点+汇报，没有主动扩展语义为"把团队预建好"。

**遇到的问题及解决方案**：
1. **任务理解过于保守（核心问题）**：在初始化/就绪类指令下，本应主动把可执行的初始化动作（如建团）一并完成或至少提示，去止步于汇报现状。
   - 解决方案：建立主动补位准则——检查环境时若发现 team 能力可用、成员数为 0，应主动报告建议并询问。

**重要结论**：
- 工具说明没有问题，团队创建一次实测即成功；偏差在 Agent 的主动性/意图理解。
- 改进点写入 rule.md（新增"主动性与意图拓展"准则）。
- 预算：本会话消耗约 $0.018（1.8%），剩余充足。

**后续待办/提示**：
- 初始化/就绪场景下这一主动补上"团队建设建议 + 是否立即建团"询问。
- 若用户正式建团，可用既有模型建立多个成员（上限 7 人、层级 2 层）。

---

### 2025-08 · 任务：正式搭建团队（第六次）

**任务目标**：
- 按用户"正式开始搭建团队"的指令，正式组建 Tree 项目的开发团队。

**关键决策**：
- 先 ask_user_question 询问目标/成员构成/模型偏好/测试成员处置（用户超时未答），基于项目实际自主决策：Tree = Flutter 前端 + Python 后端，按职责组建后端/前端/QA 三角色。
- 复用既有测试成员改造为测试/QA工程师（避免浪费名额）。
- 新建两名成员：后端工程师、前端工程师。

**遇到的问题及解决方案**：
1. **create_member 的 system_prompt 传参后查询显示为空**：新成员创建后 query_member 显示 system_prompt 为空字符串。
   - 解决方案：用 update_member 分别补充完整 system_prompt（职责/目录/Git 规范/汇报要求），触发 rebirth。
2. **update_member 改名不完全生效**：仅传 member_name 报"未提供任何可更新的字段"；传 name+system_prompt 后名字仍显示旧名（system_prompt 生效）。猜测后端对名字更新逻辑有限制。
3. **can_lead_team 默认情况**：新成员 can_lead_team 默认 True（可带队），测试成员更新后为 False；按实际需求分配。

**重要结论（当前团队编制 v1）**：
- 团队 3 名成员，全部 Level 1，模型 deepseek-v4-flash-0731，状态 idle：
  - 后端工程师 member_1787016828_x3clpa（负责 server/ Python/FastAPI）
  - 前端工程师 member_1787016828_7xql6q（负责 lib/ Dart 开发）
  - 测试/QA工程师 member_1787015857_ij3yml（负责 server/tests 测试，can_lead_team=False）
- 团队编制文档写入 docs/team_structure.md（角色/成员ID/职责/协作规范）。
- 层级：Level 0（我）+ 3×Level 1；每级最多 7 人，尚余 4 名额；层级深度已 2 层。
- 预算：本会话累计消耗约 $0.017（1.7%），剩余充足。

**后续待办/提示**：
- 团队已就绪，等待 Leader：分派任务（修复/验证/开发）。
- 协作流程：Leader 拆解任务 → assign_task（task_description + task_output）→ 成员开发并 Git 提交 → 汇报摘要 → QA 验收/打分。
- 每个成员有独立工作空间（workspaces/member_<id>/，含自己的 .self/）。
- 记忆文档位置：workspaces/agent_1787008529546/.self/（非仓库根）。