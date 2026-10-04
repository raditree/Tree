# tree_local_exec

**工作空间 IO 的两个实现**（本机 `dart:io` / SSH `dartssh2`）+ shell 语义 + 判活 + **伪终端（PTY）**。
内置工具只写一份，靠这里的接口屏蔽后端差异。

## 内容

| 文件 | 内容 |
| --- | --- |
| [lib/src/workspace_io.dart](lib/src/workspace_io.dart) | 接口：`WorkspaceIO`（read/write/edit/grep/list/exec/git）、`WorkspaceFiles`（文件面板：列目录 / 原始字节 / 流）、结果类型与路径异常 |
| [lib/src/background_exec.dart](lib/src/background_exec.dart) | 「**后台执行**」原语（terminal 的 `hook=true`）：`BackgroundExecHost`（起后台命令 / 追加写日志 / 读日志尾部 / 重启后接管）+ `BackgroundExecHandle`。本机与远端**同一套语义**，能力差异（杀不杀得掉、能不能接续）在实现里如实区分 |
| [lib/src/local_workspace_io.dart](lib/src/local_workspace_io.dart) | 本机实现：进程树终止、非 UTF-8 输出标记（GBK 代码页尝试解码）、软超时交还活着的进程（`RunningLocalExec`） |
| [lib/src/ssh_workspace_io.dart](lib/src/ssh_workspace_io.dart) | SSH 实现：SFTP + exec，心跳判活，链路失活显式失败；**软超时交还仍在运行的远端命令**（`RunningSshExec`）；文件面板的结构改动（mkdir / rename / remove）也在这一层，**全部走 SFTP**；另含交互终端的透传口 `openShell`（远端根在这一层解决） |
| [lib/src/git_output.dart](lib/src/git_output.dart) | git 的命令与输出解析（log / branch / **status**）：本地与 SSH **共用一份**，命令形状与解析规则不可能漂移 |
| [lib/src/ssh_shell_channel.dart](lib/src/ssh_shell_channel.dart) | **远端 shell 通道** `SshShellChannel`（交互终端用）：原始字节输出 / 键盘输入 / 改尺寸 / 退出码 / 幂等 `close`；dartssh2 实现在 [lib/src/dartssh_transport.dart](lib/src/dartssh_transport.dart) 的 `openShell`（`shell` 或 `exec + pty-req`） |
| [lib/src/shell.dart](lib/src/shell.dart) | shell 参数：`-NonInteractive`、裸 `echo` 兼容翻译、逻辑运算符翻译（Windows/POSIX） |
| [lib/src/ssh_liveness.dart](lib/src/ssh_liveness.dart) | SSH 心跳台账（连续 N 拍丢失 ⇒ 判失活；判失活的那一拍**通知传输层重建连接**） |
| [lib/src/ssh_reconnect.dart](lib/src/ssh_reconnect.dart) | **重连的节拍器** `SshReconnectPump`：单飞 + 退避 + 可停止（与 dartssh2 无关，所以能单测） |
| [lib/src/dartssh_transport.dart](lib/src/dartssh_transport.dart) | dartssh2 传输实现：连接 / SFTP / exec / 远端 shell 通道 / **心跳与自动重连**（`reconnect()` 单飞换会话） |
| [lib/src/windows_environment.dart](lib/src/windows_environment.dart) | **按登录口径重建环境变量**（注册表机器级 + 用户级；失败整体退回继承）——本地 exec / git / PTY / hook 共用 |
| [lib/src/ssh_login_shell.dart](lib/src/ssh_login_shell.dart) | **远端命令的登录外壳包装**（`bash -lc` → `sh -lc` → 原样发；可配可关）+ POSIX 单引号转义 |
| [lib/src/pty/pty_session.dart](lib/src/pty/pty_session.dart) | **伪终端会话**接口 `PtySession`（原始字节输出 / 键盘输入 / 改尺寸 / 退出码 / 幂等 `close`）+ 平台工厂 `startPtySession` |
| [lib/src/pty/conpty_windows.dart](lib/src/pty/conpty_windows.dart) | Windows 后端：ConPTY（`dart:ffi` 直调 kernel32；阻塞 `ReadFile` 放独立 isolate） |
| [lib/src/pty/pty_posix.dart](lib/src/pty/pty_posix.dart) | POSIX 后端：系统 `script`（改尺寸做不到，如实标注） |

## 不变量（assertions）

1. 只接受**工作空间相对路径**；`resolve` 拒绝绝对路径 / 盘符 / `..` 逃逸（`WorkspacePathException`）。
2. **没有静态任务超时**：本地判活 = 进程存活；SSH 判活 = 心跳。`exec(timeout:)` 是**两端同口径的软超时**
   ——到点**不杀进程、不重跑**：本地把仍活着的进程交出去（`LocalExecStillRunning`），
   SSH 交还 `RunningSshExec` 句柄（`SshExecStillRunning`，结束补写输出与退出码、链路失活如实失败）；
   `0` / 负值 = **永不软超时**。**软超时之后只允许显式关闭**（`close()` / 关闭句柄 / 上层 `tool.close`），
   **没有任何"到点自动杀"**——全仓同一条口径见 [../tree_core/lib/src/llm/README.md](../tree_core/lib/src/llm/README.md) 不变量 2。
   （2026-10-03 起 SSH 也兑现；此前 SSH 侧忽略它——现场事故见 [../../docs/known-issues.md](../../docs/known-issues.md)），
   到点**不杀进程、不重跑、不关通道**，把仍在跑的**命令**交出来：本地是 `LocalExecStillRunning`
   + `RunningLocalExec`（输出订阅还活着、进程杀得掉），SSH 是 `SshExecStillRunning` + `RunningSshExec`
   （远端进程不归本机管：退出码与完整输出要等它自己结束才回来）。`timeout <= 0`（含缺省 `Duration.zero`）
   = **永不软超时**（老行为）。硬超时（按时间杀）**不存在**。
3. 输出**字节不丢**：非 UTF-8 先尝试系统代码页；解不开时 latin1 兜底并标 `garbledOutput`。
4. 隐藏路径默认不扫（`.[!.]*`）；显式指向隐藏目录时按用户意图搜索。
5. 启动子进程时**禁用交互**（`-NonInteractive` + 关闭 stdin），否则等输入的命令会永久挂住
   （见 [../../docs/known-issues.md](../../docs/known-issues.md) #7）。
6. **SSH 链路失活 → 显式失败 + 重建连接**（2026-10-05 补；用户要求：「保持心跳失活判超时的断言，
   但判超时后重连 + 显式『重连』入口」）：
   - **判据不变**：连续 N 拍（默认 3）心跳窗口内没有回包 ⇒ 判失活；在途 / 新来的操作一律以
     `SshLinkStaleException` **显式失败**（既不静默，也不永久挂起）。判活**只看心跳**，不看任务跑了多久；
   - 判失活的那一拍（`SshLiveness.onStale`）立刻起一个**后台重连**（`SshReconnectPump`：单飞 + 退避
     `5s→10s→30s→60s`、之后每 60s 一次，直到成功 / `close()`）。为什么必须有它：一条已经断掉的 TCP
     连接**不会自己活回来**——现场 2026-10-05 连丢 **1325 拍**（≈3h41m）、远端实测可达，应用却再没恢复过，
     只能重启。重连**不阻塞任何调用方**（在途操作照旧立刻显式失败，重连只保证"之后能再用"）；
   - **"先建新、再换旧"**：建连成功之后才替换会话并清空丢失计数；失败抛可读 `WorkspaceIoException` 且
     **保持失活态**（绝不假装恢复了）；同一时刻最多一次在途重建（自动循环与显式入口复用同一次）；
   - **显式入口**与自动重连共用同一份实现：`ReconnectableWorkspace`（`linkStale` / `linkMessage` /
     `reconnectLink()`，核心侧 = `POST /api/agents/{agentId}/ssh/reconnect`，右栏文件错误块上的「重连」按钮），
     用户不想等退避时点它；
   - **不引入任何静态时长上限**：退避只是"两次尝试之间的节奏"，单次建连照旧不设超时，判死判据仍然只看心跳丢失。
   失活期间的**失败文案**如实说这件事（旧文案「心跳恢复后自动恢复」是误导，已改）。
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
11. **远端 shell 通道（真 PTY）与一次性 `exec` 是两条路**：`SshTransport.openShell` 走 dartssh2 的
    会话通道 + `pty-req`——`command` 为空 = 远端**登录 shell**，非空 = 远端登录 shell 以 `-c` 执行该
    命令（`ssh -t host '<cmd>'` 的行为，退出码是**命令**的；真实 API 的 `SSHClient.shell()` 没有
    command 参数，写进 PTY 只会拿到 shell 的退出码）。远端工作目录只由 `SshWorkspaceIO.openShell`
    用**自己的远端根**填，核心不参与、也绝不把本机路径发给远端。`exitCode` **一定收口**（远端退出 /
    对端关会话 / 链路断开 / 我们主动 close，拿不到退出状态给 **-1**）；`close()` **幂等**且**只关这一条
    通道**（绝不 `SSHClient.close()`：SFTP / exec / 文件面板与它共用连接）；输出是**原始字节**。
    边界：远端 sshd 必须允许 `shell` / `pty-req`（`PermitTTY no` 会被明确拒绝、回可读错误）；
    本仓库**只用假通道验证过**（本机没有可连的 sshd），详见 [../../docs/known-issues.md](../../docs/known-issues.md) #12。
12. **远端结构改动（`makeDirectory` / `rename` / `remove`）走 SFTP，不起 shell**：`SshTransport` 上新增的
    四个方法由 dartssh2 的 `SftpClient.mkdir` / `rename` / `remove` / `rmdir` / `stat` 实现，因此没有引号 /
    转义 / 远端有没有 coreutils 这些问题。递归删除是**自底向上的 SFTP 遍历**（`listdir` + `remove`），
    按**链接本身**删、不跟着符号链接删穿。**重命名绝不覆盖**：SFTP 的 `posix-rename@openssh.com` 扩展
    本身就是覆盖语义，所以 `SshWorkspaceIO` 先自检目标是否存在再调 rename；父目录用 `stat`（O(1)）判，
    不为了判类型把整层目录列一遍。结果码是 `WorkspaceMutationStatus`（见 [lib/src/workspace_io.dart](lib/src/workspace_io.dart)）：
    `alreadyExists` / `notFound` / `parentMissing` / `notEmpty`（**不抛异常表达业务语义**，上层才能映射 409 / 404 / 400）。
13. **git 状态与 git 日志共用同一套命令与解析**：`GitOutput.statusArgs` / `parseStatus`（`--porcelain=v1 -z`）
    本地与远端都引用它；两侧都**不抛异常**，只回退出码 + 空列表（非仓库 ⇒ 面板空态，不是 400）。
14. **本地进程的环境按"登录口径"重建，不是继承 core**（[lib/src/windows_environment.dart](lib/src/windows_environment.dart)，
    **用户断言 2026-10-03**：「Tree 的 terminal 和我直接在本机使用的 terminal 在行为上有分歧」）：
    机器级 `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment` + 用户级 `HKCU\Environment`；
    `Path` 按"机器级 + `;` + 用户级"拼，其余同名用户级覆盖机器级；`REG_EXPAND_SZ` 按合成后的表展开
    （**查找表带上继承值**，否则会留一串没展开的 `%SystemRoot%`）；**注册表里没有的继承变量原样保留**
    （运行环境注入的 `TREE_*` / 工具链条目不该被抹掉）；**任何一步失败整体退回继承**并留日志。
    接线四处、同进程只算一次：本地 `exec`、`git`、本地 PTY（核心的 `LocalPtyStarter`）、后台 hook 脚本。
    理由：纯继承会让 agent 的 shell **少**用户在系统里配的 PATH 项（实测少 `C:\Program Files\GitHub CLI\`）、
    **多**启动方注入的项（实测多 `…\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__8wekyb3d8bbwe`，
    连带把 shell 选成了 MSIX 打包版 pwsh）。非 Windows 直接返回继承值。
15. **SSH 远端命令默认套一层登录外壳**（[lib/src/ssh_login_shell.dart](lib/src/ssh_login_shell.dart)，
    **用户断言 2026-10-03**：「SSH 下也有类似情况（上次我有 nvcc，另一个 agent 没有）」）：
    `SshTransport.run` 走的是 **exec 通道 = 非登录 shell**，看不到 `/etc/profile`、`~/.profile`
    里的 PATH ⇒ 默认包成 `bash -lc '<cmd>'`；`bash` 不在退 `sh -lc`，都探测失败就**原样发**
    （与旧行为一致）并留日志；一次连接**只探测一次**并缓存。模板可用 agent yaml 的 `ssh.login_shell`
    替换（必须带 `{cmd}` 占位）或写空串**关掉**；模板非法（缺占位）只跳过那一档，不让命令失败。
    命令一律 **POSIX 单引号转义**（`'` → `'\''`，`$` / 反引号 / 换行都当字面量）。
    远端**交互终端**（`openShell`）本来就是登录 shell，不受影响。`resolveRemoteRoot` 因此改用
    **带标记**的 `printf __TREE_HOME__%s "$HOME"`：profile 往 stdout 打欢迎语也照样取得准。
16. **「后台执行」是一等原语，两端同一套语义、能力差异如实**（[lib/src/background_exec.dart](lib/src/background_exec.dart)，
    **用户要求 2026-10-04**：「`hook=true` 那条路看不到我远端工作空间的文件……你应该修好它」）：
    - `BackgroundExecHost.startBackground` 起后台命令、`appendLog` 追加写、`readTail` 读尾部、
      `attachBackground` **重新接管**（**不重跑、不新起**）；
    - **本机**：脚本文件 + shell 重定向直写日志（`>>` + `2>&1`），进程句柄在手 ⇒ 退出码实时、
      `cancel` 杀整棵进程树、关停杀树；
    - **远端（SSH）**：`mkdir -p` + `cd <root>` + `( setsid nohup sh -c '<cmd> ; printf %s $? > <哨兵>' > <日志> 2>&1 < /dev/null & echo $! )`
      ⇒ 命令起在**远端**、日志落**远端工作空间**、退出码写进**哨兵文件**（本机按 **3s** 轮询：
      `if [ -f 哨兵 ]; then cat 哨兵; elif kill -0 <pid>; then RUNNING; else GONE; fi`）；
      **`startBackground` 必须立刻返回**（`hook=true` 不许退化成同步调用）：`&` 与 `echo $!` 都写在
      **子壳**里 ⇒ 子壳立刻退出、SSH 通道立刻 EOF ⇒ `run` 立刻返回（pid 仍回到 stdout）；`setsid` 让命令
      自成**进程组**（pgid == pid）⇒ `cancel` 的 `kill -TERM -<pid>` 落在正确进程组。旧形状
      `{ … ; } & echo $!` 会让承载组的子壳一直握着通道、**阻塞到命令结束**（2026-10-04 真机实测
      `sleep 25` 阻塞 25.09s，见 [../../docs/known-issues.md](../../docs/known-issues.md) #23）；
      远端进程**不归本机管**：`cancel` 尽力（拿不到 pid ⇒ 返回 false，**不假装**）、**关停不杀**
      （关应用不该杀掉远端训练）；进程消失但没留哨兵 ⇒ [BackgroundExecHandle.goneExitCode]（可辨，不当正常退出）；
      链路判失活 ⇒ `exitCode` 以 `SshLinkStaleException` 结束；
    - 内层命令只依赖 **POSIX**（`sh -c`）：远端不一定有 bash（登录外壳是探测 + 回退出来的），
      代价是"后台命令跑在 `sh -c` 里、与同步执行的登录外壳（`bash -lc`）在 bash 专有语法上有差异"（如实记录）。
17. **`readFile` 的 `text` 保留结尾换行**（[lib/src/workspace_io.dart](lib/src/workspace_io.dart) 的
    `sliceFileLines`，**用户要求 2026-10-04**：「readFile().text 的结尾换行语义」= 保真）：
    `text` 是**文件内容**，不是"行拼接"——选区覆盖**末行**、且原文以换行结尾时把那个换行**补回来**，
    `write → read` 才保真；只取中段（没覆盖末行）时**不补**，不凭空多出一个空行。
    规则只有这一处、本机与远端共用（`LineSplitter` 会吃掉结尾换行：`'a\nb\n'` ⇒ `['a','b']`，直接
    `join('\n')` 就丢了它；各写一遍必然漂移）。`totalLines` 是**行数**，与是否保留结尾换行无关。
    文件面板 / 编辑器走的是**原始字节**（`FileService._contentJson` + `writeContent`），不受这条影响。

## 测试

```bash
cd packages/tree_local_exec && dart test         # 本机 + shell 语义 + 越界 + 软超时 + 挂死防护 + 伪终端
dart analyze lib test

# 门控真机 SSH（本机无 sshd 时自动跳过）
$env:TREE_SSH_TEST_HOST='...'; $env:TREE_SSH_TEST_USER='...'; $env:TREE_SSH_TEST_KEY='...'
dart test
```

M11 新增钉子：`git_output_test` 的 `parseStatus` 组（`-z`、空格 / 中文 / 引号路径、重命名、混合暂存、
未跟踪、被忽略、非法输入、截断）；`local_workspace_io_test` / `ssh_workspace_io_test` 的「文件面板结构改动」组
（新建 / 重命名 / 删除的结果码与真实行为）；`git` 组里的 `gitStatus` 用例（真仓库 M/U/A/D + 非仓库空态）。

回归钉子：`exec_no_interactive_hang_test`（裸 `echo` 不再等输入）、`exec_soft_timeout_test`（本地软超时交还进程）、
`ssh_reconnect_test`（**判失活 → 重连**：节拍器单飞 / 退避走完一直用最后一拍 / 关停后不再试、
`SshLiveness.onStale` 只在跨阈值那一拍通知一次、`ReconnectableWorkspace` 的可见面——本机后端**不**实现它），
`background_exec_test`（**后台执行原语**：本机起/写日志/读尾部/杀树/越界拒绝；远端用假 transport 钉
`( setsid nohup … & echo $! )` 命令形状、哨兵轮询（含 `GONE`）、`attachBackground` **不重跑命令**、`cancel` 拿不到 pid 时如实 false）、
`local_workspace_io_test` / `ssh_workspace_io_test` 的「结尾换行保真」组（**不变量 17**：`'a\nb\n'` 原样读回、
只取中段不凭空补）、
`ssh_exec_soft_timeout_test`（**SSH 软超时**：到点交出仍在运行的远端命令、`0`/缺省 = 永不、到点后心跳仍判活）、
`shell_translate_test`（裸 echo / 逻辑运算符翻译）、`windows_environment_test`（**按登录口径重建**：`reg query`
输出解析、`Path` 机器级+用户级、用户级覆盖、注册表缺项时保留继承值、`%VAR%` 展开与变量环、任一步失败整体退回）、
`ssh_login_shell_test`（**登录外壳**：单引号穿壳、模板渲染与非法模板跳过、bash → sh → 原样发的回退、关得掉、结论缓存）、
`ssh_workspace_io_test` 里的 `resolveRemoteRoot`（**带标记**取 `$HOME`，profile 噪声免疫）、
`pty_session_test`（真 PTY：banner → `echo` 回读 →
`resize` 不抛 → `close` 幂等且收掉进程 → `exit 3` 拿回 3 → ANSI/非 UTF-8 字节不被清洗也不崩 → 后端缺失给可读错误）、
`ssh_shell_channel_test`（**远端 shell 通道的契约**，用假通道：[ssh_workspace_io_test.dart](test/ssh_workspace_io_test.dart)
里的假传输 + [test/fake_ssh_shell_channel.dart](test/fake_ssh_shell_channel.dart)：透传尺寸与**远端根**、原始字节不受清洗、
写入 / resize、`close` 幂等、`exitCode` 一定收口（含主动 close 给 -1）、**close 不关整条连接**、链路失活显式失败）。
`ssh_integration_test`（**门控真机**：连上 + SFTP 读写改 + exec + 清理（探针落在**自建目录**、grep **限定该目录**
——否则全根 grep 在真实共享工作空间上 2 分钟都扫不完、`matches.single` 也不成立）、软超时交还远端命令、
**`startBackground` 立即返回**（返回耗时与命令时长无关：命令跑 8s 而返回 < 4s；返回时命令仍在跑，
随后拿得到退出码与产物））、
真链路的 SSH 会话通道没有在本仓库验证过（本机无 sshd），只保证编译通过与参数形状有据可依——见
[../../docs/known-issues.md](../../docs/known-issues.md) #12。
