# 工作准则 (rule.md)

## 1. Windows 本地执行模式下的 terminal 使用
1. 工作区为 Windows 且底层是 cmd 时，pwd/ls 等 POSIX 命令 exit=1 无输出；使用 dir/type/cd /d 等 cmd 命令。
2. 定位文件用 dir /s /b <name>；看目录用 dir；看文件用 type；组合命令用 & 或 &&（注意可能 exit=1 但已执行）。
3. 复杂批量替换（尤其含中文/引号的源码）：写 python 脚本文件（UTF-8）再运行，避免 python -c 内联被 cmd 转义截断。
4. 长命令输出重定向到 .txt（UTF-8）后 read；保证脚本用 utf-8 编解码避免 GBK 乱码。

## 2. mcp 工具调用参数格式
5. mcp(action=call) 时：目标工具参数放在 arguments 对象中（如 {file_path, content}），tool_name 在 mcp 参数层提供；
   不嵌套 action/tool_name 进 arguments，也不把 file_path 等放 mcp 顶层，否则报错。
6. write 写入后立即 read 校验（文件可能有意外乱码/截断），必要时用 python repr 逐行核对。

## 3. 代码风格与任务纪律
7. Dart 2.19.6 兼容：不用新语法/新 API（如 records、pattern）；Flutter 3.7。
8. 抽纯函数便于测试：纯判定逻辑（如路径分类 isUnixLikePath / resolveShellForDir）独立成顶层函数。
9. 不修改既往未提交内容（Leader 已有改动/后端代码）；本次改动仅限 lib/services/local_executor_service.dart。
10. 按要求提交 conventional commit（如 fix(local-executor): ...），提交前 git diff 自查。
11. git commit 信息含引号/特殊字符时，改用 echo > _msg.txt 后 git commit -F _msg.txt，避免 cmd 转义截断。
12. 跨平台路径判定优先抽纯函数（isUnixLikePath 模式），并直接写单测（flutter test）验证；提交前置 lint 通过。
13. 记忆维护：任务完成后一并更新 .self/memory.md（变更/经验/结论），rule.md 沉淀可复用经验。
