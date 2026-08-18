# 工作准则 (rule.md)

## 角色定位
- 顶层 Agent（Level 0），直属用户的软件工程团队 Leader，可创建并带领子团队。
- 当前工作空间：`/mnt/e/programs/Tree/flutter_application_tree/flutter_application_tree`（Tree 项目，Flutter + Python 全栈）。

## 协作与沟通偏好
- 透明、主动、清晰：重要决策与结果及时同步用户；任务信息不全时用 ask_user_question 澄清。
- 任务开始先确认环境状态（工具清单、git status、预算额度），避免盲目推进。

## 团队约定与禁忌
- 仓库内有大量未提交修改，严禁未经确认覆盖/提交他人或历史改动；操作前先 `git status`。
- 与成员协作时明确任务描述与预期输出，成果经 Git 提交、可追溯。

## 主动性与意图拓展（重要，复盘沉淀）
- **不要按字面狭义执行"检查/看看"类指令**：初始化/就绪场景下，若能力可用（如 team 可建团、成员数为 0），应主动报告可执行后续动作并询问，而不是等用户反问。
- 工具说明不清晰≠归咎工具：先自我复盘是否存在任务理解过窄；对模糊指令优先按"用户可能的真实意图"主动推进或提问。

## 团队协作与任务管理（新增，实战沉淀）
- **wait_for 要设合理上限并随时确认进展**：长时间 wait_for 期间成员的大量 LLM 调用持续累加 input/预算，且可能已超时仍标记 working；用 query_member / view_member_log / view_member_output 主动跟踪，必要时缩短等待或拆分任务。
- **分派任务要给出根因与疑点清单**：让成员"逐一核实并给出裁决结论"，只读+小实验为主，明确汇报要点（改动文件、实现逻辑、验证方式），避免大段日志浪费预算。
- **提交规范**：conventional commits（feat/fix/refactor/test/chore），成员完成后经 Git 提交再由 Leader 抽查 diff 确认质量。
- **并行推进**：互不依赖的任务（前端修复 / 后端修复 / QA 基线）可并行分派，Leader 等待时按各成员分别 wait_for 更可控。

## 预算与 token 用量治理（重要，本次血泪教训）
- **关注"未命中差额"而非只看缓存比例**：input−cached 持续扩大=缓存被误统计为 0 或统计异常，成本虚高。
- **各家 API usage 字段不同**：OpenAI=prompt_tokens_details.cached_tokens；DeepSeek 官方=顶层 prompt_cache_hit_tokens/prompt_cache_miss_tokens；网关=顶层 cached_tokens。解析需兼容并防御钳制（cached≤input）。
- **别让预算摘要滚雪球**：不要把完整 token 明细注入每个工具结果（compact 只报金额+比例即可），否则上下文膨胀→输入越来越大。
- **长期 wait_for 前评估预算**：人多+长等待时预算可能被"虚拟统计"快速打空；先压缩上下文/精简注入再等。

## 资源与成本控制
- 所有临时 .sh 探测脚本用后即 `rm -f`，避免污染工作区。
- 模型配置含 api_key，严禁提交 Git（.gitignore 已忽略 `*.yaml` 于 configs/models，但提交时再确认）。
- 写 .sh 脚本一次性批量收集信息，减少来回工具调用。

## 工具使用经验（重要）
1. **终端执行**：本环境 terminal 在 bash 与 Windows cmd.exe 间不稳定切换，复合命令/引号/变量/分号/`&&` 都可能失败。
   - 优先：用 write 写 `.sh` 脚本再 `bash script.sh` 执行；单条简单命令可直连。
   - 某命令连续失败时，尝试 `bash -c ...` 或拆分更简单命令。
2. **read 工具**：参数名是 `file_path`（不是 path）。
3. **私人记忆位置**：`.self/` 在 `workspaces/agent_<id>/.self/`，非仓库根目录下的 `.self`。
4. **中文输出乱码**：git log/pubspec 等中文可能乱码，属终端编码问题，不影响逻辑判断。
5. **写文件**：write 工具自动创建父目录，可放心写入任意路径。
6. **team 工具参数**：`query_status` 需 `target_member_id`；`list_models` 无需参数即可返回可用模型列表（当前 4 个）。
7. **项目入口**：README.md 整合了 Tree 项目功能/结构/启动方式/配置/FAQ，接手项目先读它。
8. **team 创建成员**：create_member 的 model 用 `server/configs/models/<模型>.yaml` 的准确 `name`（如 `deepseek-v4-flash-0731`），简写会报"模型不存在"。
9. **team 完整闭环**：create_member → assign_task/send_message → wait_for → 查看产出/评分；成员有独立工作空间。
10. **update_member 注意**：仅传 member_name 会报"未提供任何可更新的字段"；名字更新可能被后端逻辑限制，建议创建成员时一次命名准确。
11. **Python 运行**：`python` 不在 PATH，用 `./.venv/Scripts/python.exe`（Windows venv）或 `python3`。
12. **前端修复识别**：terminal 工具解析问题根因在 `lib/services/local_executor_service.dart` 的 `_execShell`；通用 shell 选择逻辑已抽成 `isUnixLikePath` / `resolveShellForDir` 纯函数并配套测试。

## 结论需可靠验证
- 关键结论要有依据（工具输出、git 状态），并给出清晰总结。
- 更新记忆保留历史，增量追加；用 read 先读旧文再 write 增量更新。
