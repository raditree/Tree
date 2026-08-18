# 记忆文件 (memory.md)

## 最近一次任务：修复本地执行器 shell 选择问题（Windows + WSL）

### 任务目标
- 修复 lib/services/local_executor_service.dart 中 _execShell 的 shell 选择：Windows 下若工作目录为
  WSL/Unix 路径（/mnt/e/...、\wsl$...、/home/...），cmd /c 无法执行 pwd/ls/grep/rm 等命令
  （真实复现：pwd 失败、echo $PWD 输出字面量 $PWD）。
- 为 Unix/WSL 目录选择 bash 执行；纯 Windows 目录保持 cmd /c 向后兼容；bash 不可用时明确报错。

### 执行环境
- 本地执行模式（Windows cmd），工作区根 E:\programs\Tree\flutter_application_tree\flutter_application_tree。
- Flutter 3.7.12 / Dart 2.19.6（Windows x64）；python 3.12.3 可用（D:\app\python\python.exe）。
- 目标文件：lib/services/local_executor_service.dart。
- 仓库已有未提交改动（main_page.dart / local_executor_service.dart / server/main.py），为 Leader 既有内容，勿动。

### 变更记录（全部落地并已提交）
1. 新增纯函数 bool isUnixLikePath(String path)：含 Windows 盘符 ^[A-Za-z]: 则 false；
   以 / 开头无盘符则 true；含 /mnt/、/wsl、/usr/、/home/、/tmp/ 特征则 true。
2. 新增纯函数 String? resolveShellForDir(String path)：Unix -> 'bash'，Windows -> 'cmd'，空 -> null。
3. _execShell 改造：isUnixLikePath(workDir) 为真时走 _runUnixShellInDir
   （bash -lc "cd <dir> && <cmd>" 优先；bash 不可用回退 wsl.exe --cd <dir> bash -lc <cmd>；
   均不可用返回『bash 不可用，请检查 WSL』明确错误——不静默返回空）；否则保持 cmd /c 向后兼容。
4. _runProcess 扩展：新增可选 workingDirectory 参数；缺省时若 wsDir 为 Unix/WSL 路径
   则不传 Process.run workingDirectory（Windows API 不认该路径），由 bash 内嵌 cd 进入；
   纯 Windows 路径仍传 wsDir.path。新增辅助方法 _isShellMissing（识别 'not found'/
   'cannot run program'/'不是内部或外部命令'等，判断 shell 缺失而非命令失败）。
5. 单元测试：新增 test/local_executor_shell_test.dart（flutter_test），flutter test 全部通过（8/8）；
   dart analyze lib+test 无问题。
6. Git 提交：78750e9「fix(local-executor): adapt shell selection for WSL/Unix working dirs」
   （2 files, +166/-5）。已向 Leader 汇报摘要。

### 遇到的问题及解决方案
1. 首次 edit 插入出现乱码（第 30 行 tab+}、33-35 行 t/ 开头前缀）——用 python 脚本按 repr 精确修复。
2. MCP 终端是 cmd（非 bash）：pwd/ls 会 exit 1 无输出；用 dir/type/echo 探测。
3. python -c 内联带引号命令在 cmd 中易被截断/exit 1 —— 改用 write 写 .py 脚本再 python xxx.py 执行。
4. mcp write/terminal 正确参数格式：tool_name 在 mcp 参数层、目标参数在 arguments 层；
   误放顶层会报「action=call 时必须提供 tool_name」。
5. Windows 下 terminal 长输出建议重定向 .txt 后 read（read 工具参数名是 file_path）。
6. git commit 带中文/引号信息时用 -F 从文件读取（避免 cmd 引号转义/截断）。

### 重要结论
- 根因明确：用 Platform.isWindows 无法区分 WSL 挂载目录；需额外用路径特征判定。
- 纯函数抽离（isUnitLikePath/resolveShellForDir）便于 dart test 直接测。
- 任务已完成并提交，验证方法：dart analyze + flutter test（8/8 通过）。

---
（更新于：2026 任务完成，WSL shell 选择修复已提交 + 验证通过）
