# 工作准则 (rule.md)

## 1. Windows 本地执行模式下的 terminal 使用准则
1. **默认 shell 可能异常**：工作区为 Windows 时，pwd/ls 等 POSIX 命令会 exit_code=1 且无输出；优先使用 `shell: "cmd"` + Windows 命令（dir/type/cd）。
2. **cwd 参数不可靠**：terminal 的 cwd 常不生效（实际在 workspace 根执行）。需要定位文件时用 `cd /d <绝对路径> && <命令>` 组合，或直接用绝对路径。
3. **venv python 用绝对路径**：Windows 下默认 `python` 可能指向系统级解释器（如 D:\app\python），必须用 `<repo>\server\.venv\Scripts\python.exe` 显式调用。
4. **组合命令/输出解析不可靠**：`&&`/`&` 组合常报 exit_code=1 但实际已执行；长输出优先重定向到 .txt 后读取（注意 Windows 下可能为 GBK 编码，read 失败时改用 cmd `type`）。

## 2. 测试执行准则
5. **区分脚本式冒烟与 pytest 用例**：`smoke_*_test.py` 按文档用 `python xxx.py` 直接运行；pytest 默认只收集符合 test_*.py 的文件。跑测试前先确认 venv 是否装了 pytest，缺则按需 `pip install pytest`。
6. **基线测试纪律**：只测不改被测代码；测试临时文件（日志/重定向）用后即删，不提交 Git；汇报时只给要点，大段日志不入消息。

## 3. 工具使用注意
7. **read 工具参数名是 `file_path`**（不是 path），否则报「file_path 不能为空」。
8. **有 before/after 对照需求时**（如修复验证），记录修复前基线（含故障现象），作为后续回归对照。
