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
- Git 仓库根目录在 `../../`（`E:/programs/Tree/flutter_application_tree/flutter_application_tree`），当前分支 `main`，存在未提交修改。
- 工具清单：内置工具（help/set/refresh/mcp/team/ask_user_question）+ MCP 12 个。
- 资源限制：CPU 2 核、内存 2G、磁盘 4G、可用 1G、单文件 100M、下载 900M。
- 预算：当前消耗极低（0%）。

**后续待办/提示**：
- 仓库内有未提交修改，如需协作注意 `git status` 变化，避免误提交他人/历史改动。

---

### 2025-08 · 任务：环境检查（第二次）

**任务目标**：
- 用户要求"检查环境"，进行全面的运行环境与项目状态检查。

**关键决策**：
- 先用 help/refresh/mcp(help) 确认工具清单，再通过终端实测系统信息、Git 状态与项目结构。
- 发现带引号/变量/复合命令的多命令终端调用不稳定，改用 **write 写 .sh 脚本 + bash 执行** 的可靠方式。

**遇到的问题及解决方案**：
1. **terminal 工具调用偶发失效**：部分命令返回 `exit_code: 1` 或空 stdout，且报"不是内部或外部命令"/`$'\bash\r'` 等——终端会在 bash 与 Windows cmd.exe 之间切换。
   - 解决方案：优先使用 `bash env_check.sh`（脚本文件）执行多命令检查；单条简单命令（echo test123）可直连成功。
2. **read 工具参数**：`read` 工具参数名是 `file_path`（非 path）。
3. **Flutter/Dart 版本检查失败**：`flutter --version` 等被 shell 转义/CRLF 干扰（`env: $'\bash\r'`），未能确认是否安装。
4. **中文乱码**：`git log`/`pubspec.yaml` 输出的中文显示为乱码（终端编码问题），但不影响代码逻辑判断。

**重要结论（环境快照 v2）**：
- 实际运行环境为 **WSL2**（Linux kernel 6.18.33.2-microsoft-standard-WSL2），路径形如 `/mnt/e/programs/Tree/...`。
- 工作目录：`/mnt/e/programs/Tree/flutter_application_tree/flutter_application_tree`。
- 项目为 **Tree —— LLM 驱动的 Agent 团队桌面效率工具**：Flutter 前端（lib/）+ Python 后端（server/，FastAPI）。
- 系统资源：CPU 16 核、内存 7.6Gi（可用 6.5Gi）、磁盘基本充足。
- 工具链：Python 3.14.4 ✅；Node 未安装 ❌；Flutter/Dart 未确认。
- Git：分支 `main`，最近提交 3e9c496；有大量未提交修改（android/ios 平台配置、.gitignore 等）。
- 预算：截至检查时消耗约 $0.0095（0.9%）。

**后续待办/提示**：
- 终端执行多命令应优先**写 .sh 脚本后 bash 执行**。

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
- 核心能力：账号体系（用户名/密码 + JWT）、Agent 层级团队（Level 0–3）、OpenAI 协议模型接入、上下文管理/压缩/持久化、上下文隔离、多格式文件查看器与双向同步、Git 历史/分支查看、沙箱安全。
- 后端结构：`server/main.py`（FastAPI 入口，端口 8000）、`server/api/routes.py`、`server/core/`、`server/tools/`、`server/mcp_tools/`、`server/configs/`。
- 启动：后端 `cd server && python main.py`；前端 `flutter pub get && flutter run -d windows`；镜像 docker build。

**后续待办/提示**：
- 用 team 查询成员状态时记得传 `target_member_id`。
- README.md 是了解 Tree 项目的最佳入口。

---

### 2025-08 · 任务：team 工具创建团队验证（第四次）

**任务目标**：
- 用户询问"team 工具不能创建团队吗？"，实测验证 team 工具能否创建成员并闭环。

**关键决策**：
- 先 list_models / list_members 确认可用模型与现有成员；再用 create_member 实际创建验证。
- 从 `server/configs/models/*.yaml` 读取准确模型名，避免用简写。

**遇到的问题及解决方案**：
1. **模型 ID 错误**：create_member 传 `deepseek-v4-flash` 报"模型不存在"。
   - 解决：读取 YAML 后其 `name: deepseek-v4-flash-0731`，用完整 name 后创建成功。
2. **query_status 需 target_member_id**：缺参会报错。

**重要结论（团队能力）**：
- **team 工具可以创建团队**：create_member 成功创建 `member_1787015857_ij3yml`。
- 完整团队闭环可用：create_member / list_members / query_member / send_message / assign_task / wait_for / send_file / 多维评分。
- 层级/规模上限：顶层 agent 最多 5 个、团队层级 2 层、每 agent 最多 7 个成员。
- 预算：本会话消耗约 $0.014（1.4%）。

**后续待办/提示**：
- 创建成员的 model 必须用 YAML 配置的准确 `name` 字段。

---

### 2025-08 · 任务：复盘——为何初次未主动创建团队（第五次）

**任务目标**：
- 用户追问"为什么一开始叫你构建团队时没有创建成员？是工具说明不清楚还是什么问题？"，复盘根因。

**关键决策**：
- 不找借口、把责任归到自己的行动：团队能力、创建方法已在系统提示中清晰披露，问题不在工具本身。
- 直接承认：我按字面狭义执行了"检查"=盘点+汇报，没有主动扩展语义为"把团队预建好"。

**遇到的问题及解决方案**：
1. **任务理解过于保守（核心问题）**：初始化/就绪场景下，本应主动把可执行的初始化动作（如建团）一并进行或提示，去止步于汇报现状。
   - 解决：建立主动补位准则——检查环境时若发现 team 能力可用、成员数为 0，应主动报告建议并询问。

**重要结论**：
- 工具说明没有问题，团队创建一次实测即成功；偏差在 Agent 主动性/意图理解。
- 改进项写入 rule.md（新增"主动性与意图拓展"原则）。
- 预算：本会话消耗约 $0.018（1.8%）。

**后续待办/提示**：
- 初始化/就绪场景下这一主动补上"团队建设建议 + 是否立即建团"询问。

---

### 2025-08 · 任务：正式搭建团队（第六次）

**任务目标**：
- 按用户"正式开始搭建团队"的指令，正式组建 Tree 项目开发团队。

**关键决策**：
- 先 ask_user_question 询问目标/成员构成/模型偏好（用户超时未答），基于项目实际自主决策：Tree = Flutter 前端 + Python 后端，按职责组建后端/前端/QA 三角色。
- 复用既有测试成员改造为测试/QA工程师。
- 新建后端工程师、前端工程师。

**遇到的问题及解决方案**：
1. **create_member 后 system_prompt 查询为空**：新成员查显示为空字符串。
   - 解决：用 update_member 分别补充完整 system_prompt，触发 rebirth。
2. **update_member 改名不完全生效**：仅传 member_name 报"未提供任何可更新的字段"；传 name+system_prompt 后名字仍旧名。
3. **can_lead_team 默认情况**：新成员默认 True，可按需分配。

**重要结论（团队编制 v1）**：
- 团队 3 名成员，全部 Level 1，模型 deepseek-v4-flash-0731，状态 idle：
  - 后端工程师 member_1787016828_x3clpa（server/）
  - 前端工程师 member_1787016828_7xql6q（lib/）
  - 测试/QA工程师 member_1787015857_ij3yml（server/tests，can_lead_team=False）
- 团队编制文档：docs/team_structure.md。
- 层级：Level 0（我）+ 3×Level 1；每级最多 7 人，尚余 4 名额。
- 预算：约 $0.017（1.7%）。

**后续待办/提示**：
- 协作流程：拆解 → assign_task（task_description + task_output）→ 成员开发并 Git 提交 → 汇报摘要 → QA 验收/打分。

---

### 2025-08 · 任务：修复 terminal 工具解析问题（第七次）

**任务目标**：
- 用户"先修你说的工具解析问题"——修复本地执行模式下 terminal 工具解析失败（cmd 报"不是内部或外部命令"）的问题。

**关键决策**：
- 定位到前端 `lib/services/local_executor_service.dart`：`_execShell` 按 `Platform.isWindows` 一律 `cmd /c`，但用户目录是 WSL2 挂载（`/mnt/e/...`），cmd 解析不了 Unix 命令。
- 分派给前端工程师 member_1787016828_7xql6q 修复；QA 工程师做基线测试摸底。

**遇到的问题及解决方案**：
1. **wait_for 超时高消耗**：wait_for(600s) 期间预算摘要快速上涨，暴露出"用量统计滚雪球"问题（详见第八次记录）。
2. **终端不稳定**：多命令/引号/`&&` 间歇无效，坚持用写脚本 `bash xxx.sh` 方式规避。

**重要结论（修复完成）**：
- 提交 `78750e9 fix(local-executor): adapt shell selection for WSL/Unix working dirs`。
- 新增 `isUnixLikePath()`（识别 /mnt/、\wsl、/usr/、/home/ 等）、`resolveShellForDir()`（Unix→bash，Windows→cmd（向后兼容））。
- Unix 目录 `bash -lc "cd <dir> && <command>"`，bash 不可用时回退 `wsl.exe --cd`。
- 配套测试 `test/local_executor_shell_test.dart`（纯函数，10 个断言）。
- **教训**：wait_for 不能盲目等长时间，随时查看成员输出/日志确认进展，控制资源。

**后续待办/提示**：
- 前端修复已验证（提交已存在）；dart 测试需 flutter test 环境才能最终确认。

---

### 2025-08 · 任务：用量统计 input token 增长异常调查与修复（第八次）

**任务目标**：
- 用户指出"修用量统计（你没发现 input token 涨得比 cache token 还快吗？）"——解决 wait_for 期间 input 快速增长、成本虚高的问题。

**关键决策**：
- 初步定位为多处疑点：缓存字段解析不全 / usage 重复记账 / 预算摘要滚雪球 / 团队成员共享 tracker。
- 分派给后端工程师 member_1787016828_x3clpa 逐一核实并修复，重点兼容 DeepSeek 官方 usage 格式。
- 同步分析真实预算曲线：input 从 235K→3.03M→18M，cached 同步涨但 input−cached 差额持续扩大，印证记账异常。

**遇到的问题及解决方案**：
1. **问题一把手**：`DeepSeek 官方` 返回的 usage 顶层字段是 `prompt_cache_hit_tokens`/`prompt_cache_miss_tokens`，而非 OpenAI 的 `prompt_tokens_details.cached_tokens`；原代码只认后者 → 缓存命中一直按 0 计费（全价 input）。
2. **问题二**：`预算摘要` 每个工具结果都注入完整 token 明细，上下文膨胀 → 输入滚雪球。
3. **问题三**：同一响应重复 usage chunk 可能翻倍记录。

**重要结论（修复+测试）**：
- 后端 `545f4e` 已提交：`fix(llm,budget): 兼容 DeepSeek usage 缓存字段 & 避免预算摘要滚雪球`。
- 新增 `extract_usage_counts()` 兼容三种口径（OpenAI / DeepSeek prompt_cache_hit/miss / 网关顶层 cached_tokens），带防御性校验（cached ≤ input）。
- 预算摘要改 compact（只报金额+比例），不再反复注入完整明细。
- 重复 usage chunk 只记录一次。
- 新增 `server/tests/test_usage_parse.py`（8 个用例）：我亲自用 `./.venv/Scripts/python.exe -m pytest tests/test_usage_parse.py` 验证 **8 passed**。
- **关键教训**：预算/用量统计要关注"未命中差额"而非只看比例；`include_usage`、`prompt_cache_hit_tokens` 等各家网关字段差异要主动兼容。

**验证**：
- pytest：8 passed（1.58s）✅；前端 shell 纯函数测试已提交待 flutter 环境确认。
- 预算：本会话已消耗至 65%+（虚拟统计滚雪球所致，修复后新会话应恢复）。

**后续待办/提示**：
- 用法修正后验证真实效果：用户新发消息（触发 reset）后再观察 input/cache 比例是否正常。
- 若需要，可再让 QA 结合 mock 复测 usage 解析函数。

