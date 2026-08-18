# 工作准则 (rule.md)

## 后端工程（server/）
1. 改动提交前先跑 `pytest server/tests -q`，确认无回归；`py_compile` 校验语法。
2. 提交只用 `git add` 自己改动的文件，绝不带上 Leader/前端/其他成员的未提交改动（lib/、server/main.py、workspaces/* 常为他人进行中工作）。
3. 提交消息用 conventional commit 格式，如 `fix(llm,budget): ...`。
4. 涉及 api_key：只做最小探针且脚本内临时读取密钥，绝不把密钥写入 git/回报文本。

## 终端与脚本
- 本地执行模式终端在 cmd.exe 与 WSL bash 间切换，多命令/引号/变量不稳定。
- 多步操作优先 `write` 写 .py/.sh 脚本再执行；git 中文 commit 走 `subprocess`（encoding='utf-8'）执行。
- 用完的临时脚本/tmp 文件及时清理，避免污染 git status。

## usage / 预算相关
- usage 缓存字段兼容顺序：`prompt_tokens_details.cached_tokens` → 顶层 `prompt_cache_hit_tokens`（或 miss 反推）→ 顶层 `cached_tokens`；异常值 clamp(0, prompt_tokens)。
- 工具结果注入预算摘要一律用 `compact=True`（只给剩余金额+比例），避免上下文滚雪球。
- 修改预算/用量统计后，务必保持 OpenAI + DeepSeek + 网关三种格式都兼容，并补单元测试。
