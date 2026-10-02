# tree_local_exec

**工作空间 IO 的两个实现**（本机 `dart:io` / SSH `dartssh2`）+ shell 语义 + 判活 + **伪终端（PTY）**。
内置工具只写一份，靠这里的接口屏蔽后端差异。

## 内容

| 文件 | 内容 |
| --- | --- |
| [lib/src/workspace_io.dart](lib/src/workspace_io.dart) | 接口：`WorkspaceIO`（read/write/edit/grep/list/exec/git）、`WorkspaceFiles`（文件面板：列目录 / 原始字节 / 流）、结果类型与路径异常 |
| [lib/src/local_workspace_io.dart](lib/src/local_workspace_io.dart) | 本机实现：进程树终止、非 UTF-8 输出标记（GBK 代码页尝试解码）、软超时交还活着的进程（`RunningLocalExec`） |
| [lib/src/ssh_workspace_io.dart](lib/src/ssh_workspace_io.dart) | SSH 实现：SFTP + exec，心跳判活，链路失活显式失败 |
| [lib/src/shell.dart](lib/src/shell.dart) | shell 参数：`-NonInteractive`、裸 `echo` 兼容翻译、逻辑运算符翻译（Windows/POSIX） |
| [lib/src/ssh_liveness.dart](lib/src/ssh_liveness.dart) | SSH 心跳台账（连续 N 拍丢失 ⇒ 判失活） |
| [lib/src/pty/pty_session.dart](lib/src/pty/pty_session.dart) | **伪终端会话**接口 `PtySession`（原始字节输出 / 键盘输入 / 改尺寸 / 退出码 / 幂等 `close`）+ 平台工厂 `startPtySession` |
| [lib/src/pty/conpty_windows.dart](lib/src/pty/conpty_windows.dart) | Windows 后端：ConPTY（`dart:ffi` 直调 kernel32；阻塞 `ReadFile` 放独立 isolate） |
| [lib/src/pty/pty_posix.dart](lib/src/pty/pty_posix.dart) | POSIX 后端：系统 `script`（改尺寸做不到，如实标注） |

## 不变量（assertions）

1. 只接受**工作空间相对路径**；`resolve` 拒绝绝对路径 / 盘符 / `..` 逃逸（`WorkspacePathException`）。
2. **没有静态任务超时**：本地判活 = 进程存活；SSH 判活 = 心跳。`exec(timeout:)` 是**本地软超时**，
   到点**不杀进程**，以 `LocalExecStillRunning` 交出活着的进程；SSH 侧忽略该参数。
3. 输出**字节不丢**：非 UTF-8 先尝试系统代码页；解不开时 latin1 兜底并标 `garbledOutput`。
4. 隐藏路径默认不扫（`.[!.]*`）；显式指向隐藏目录时按用户意图搜索。
5. 启动子进程时**禁用交互**（`-NonInteractive` + 关闭 stdin），否则等输入的命令会永久挂住
   （见 [../../docs/known-issues.md](../../docs/known-issues.md) #7）。
6. SSH 链路失活时**显式失败**（`SshLinkStaleException`），不静默挂起。
7. grep 的三个数字各管一件事，**别混**：`scannedFileCount` 是**计数**（读过内容且非二进制的文件数，
   不受任何上限影响）；`scannedFilePaths` 只留前 `GrepOutcome.maxScannedFilePaths`（= **20**）条抽样；
   `GrepQuery.maxResults`（默认 **200**，可由工具参数 `max_results` 覆盖）是**命中行数**上限，
   到顶即停止扫描——"只扫了几个文件"通常是它，而不是清单上限。
8. **PTY 输出是原始字节，且与一次性 `exec` 是两条路**：`PtySession.output` 交付**原始字节**
   （不解码、不清洗 ANSI——终端渲染归前端）；交互式命令（`vim` / `top` / 要 `Ctrl+C` 的程序）
   **只能**走它。拿不到 PTY 后端时**显式抛** `PtyUnsupportedException`，**不静默降级**成无 TTY 的
   `exec`——那会让交互式命令直接坏掉，比明确报错更难排查。
9. **PTY 的能力缺口如实报，不假装**：Windows 走 ConPTY（Win10 1809+；符号缺失给可读错误、不崩）；
   POSIX 走系统 `script`（没有 `script` 给可读错误；**改尺寸做不到**，只记日志不抛）。POSIX 分支
   本仓库未在真机验证（开发机是 Windows），只保证编译通过与参数形状。
10. **PTY 的句柄与生命周期纪律**：`close()` 幂等、已结束也不抛；关会话会收掉进程
    （`ClosePseudoConsole`，仍不退才 `TerminateProcess`）不留孤儿；读 isolate 的 `ReceivePort`
    **必须显式关**（否则 Dart VM 一直不退出）；ConPTY 的结构体必须**清零**分配——`LocalAlloc`
    不像 `calloc` 不清零，脏的 `STARTUPINFOW` 会让 `CreateProcessW` 在 `wcslen` 上访问违例崩掉。

## 测试

```bash
cd packages/tree_local_exec && dart test         # 本机 + shell 语义 + 越界 + 软超时 + 挂死防护 + 伪终端
dart analyze lib test

# 门控真机 SSH（本机无 sshd 时自动跳过）
$env:TREE_SSH_TEST_HOST='...'; $env:TREE_SSH_TEST_USER='...'; $env:TREE_SSH_TEST_KEY='...'
dart test
```

回归钉子：`exec_no_interactive_hang_test`（裸 `echo` 不再等输入）、`exec_soft_timeout_test`（软超时交还进程）、
`shell_translate_test`（裸 echo / 逻辑运算符翻译）、`pty_session_test`（真 PTY：banner → `echo` 回读 →
`resize` 不抛 → `close` 幂等且收掉进程 → `exit 3` 拿回 3 → ANSI/非 UTF-8 字节不被清洗也不崩 → 后端缺失给可读错误）。
