# tree_agent

**跑在目标机（Linux）上的执行体**：经 **stdio 行分隔 JSON-RPC 2.0** 被「中转站插件」
（插件仓 `plugins/ssh_executor`，2026-10-18 前在 `packages/tree_ssh_plugin`）调用，**真正执行**文件读写与命令。

它是 SSH 执行器新架构里"真正干活"的那一端（协议定稿见
[../../docs/ssh-tunnel-protocol.md](../../docs/ssh-tunnel-protocol.md)）：

```
核心 TunnelSshTransport ──stdio JSON-RPC──▶ ssh_executor 插件
                                              │
                                              └──一条常驻 SSH exec 通道（stdio JSON-RPC）──▶ tree_agent（本包）
```

## 职责

- **协议端点**：`agent.hello/ping/info`；`fs.*`（11 个）；`exec.*`（5 个）；`shell.*`（4 个）+ 通知
  `shell.data` / `shell.exit`。方法名与错误码**只从 `packages/tree_tunnel_protocol` 取**
  （`AgentMethods` / `TunnelErrorCodes` / `RpcCodes`），本包**不手写一个字符串、不手写一个数字**。
- **越界防护的 agent 侧那一半**（协议 §4）：核心侧（`WorkspaceIO.resolve`）已经拒绝了绝对路径 /
  盘符 / `..` 逃逸；这里是**另一条边界**（这条 stdio 握在谁手里，谁就能发任意绝对路径），所以
  每个路径参数都要再过一遍 [`normalizePosixPath`] + [`isWithinRoot`]。
- **后台任务的"跨日级稳定性"**：`setsid` + 日志直写工作空间 + 退出码落盘 + 台账原子落盘
  ⇒ agent 死、SSH 通道断、应用退出都不影响在跑的命令；重连后 `exec.list` 对账给出真相。
- **PTY**：用系统 `script` 起真终端给交互终端用；做不到的能力（改尺寸）**如实回** `supported:false`。

命令行：

```
tree_agent --root <abs> --token <t> [--state-dir <abs>] [--idle-timeout-ms 0] [--version]
```

- **日志一律 stderr**（带 `[tree_agent]` 前缀）；**stdout 只写协议帧**（一行一帧）。唯一例外是
  `--version`：那是独立模式（打印一行后立刻退出，不产生任何帧）。
- 缺省状态目录 = `$HOME/.tree/agent/state/<sha256(root) 前 16 hex>`（多工作空间互不串扰）。
- `--idle-timeout-ms` **缺省 0 = 永不**（仓库口径："没有静态总时长上限"）——但**由插件拉起的常驻 agent
  总是显式收到一个值**（`kAgentIdleTimeoutMs = 90s`）：插件在 `ready` 期间一直 `agent.ping`（20s 一拍），
  所以健康链路上永远到不了这个上限；而**物理断网**时对端 sshd 收不到 FIN、通道不会 EOF，
  agent 唯一的自救线索就是"这么久没有任何帧进来" ⇒ 到点**自己优雅退出**
  （用户 2026-10-11 口径："执行器应该自觉优雅结束"）。缺省 0 只给手工调试用。

## 内容

| 文件 | 内容 |
| --- | --- |
| [lib/src/agent_config.dart](lib/src/agent_config.dart) | 命令行 → 配置（root / token / state-dir / idle-timeout）；缺省状态目录的**纯 Dart SHA-256**（零第三方依赖，能在 Windows 开发机上单测）；平台/架构探测 |
| [lib/src/path_guard.dart](lib/src/path_guard.dart) | **越界防护**：`PathGuard.check` / `checkDestructiveTarget`；POSIX 路径助手 `posixDirname` / `posixBasename` / `posixQuote` / `posixify` |
| [lib/src/fs_ops.dart](lib/src/fs_ops.dart) | `fs.read/write/stat/exists/list/listEntries/mkdir/rename/remove/delete/isDir`（协议 §3.2） |
| [lib/src/shell_launcher.dart](lib/src/shell_launcher.dart) | **"启动一个 shell 进程"的可注入接缝**：`ShellLauncher`（生产 `/bin/sh -c`；开发机单测走 `cmd.exe /c`） |
| [lib/src/proc_ledger.dart](lib/src/proc_ledger.dart) | 后台任务台账 `ProcsRecord` / `ProcLedger`（`<state>/procs.json` **原子写**、重启读回、对账）+ `AgentIdGen` |
| [lib/src/exec_ops.dart](lib/src/exec_ops.dart) | `exec.run`（前台，软超时不杀）+ `exec.spawn/list/query/kill`（后台，`setsid` + 退出码文件 + 台账）+ `buildLauncherScript` |
| [lib/src/shell_ops.dart](lib/src/shell_ops.dart) | `shell.open/write/resize/close`（`script -qec` 真 PTY）+ `shell.data` / `shell.exit` 通知 |
| [lib/src/agent_server.dart](lib/src/agent_server.dart) | **L2 服务端**：stdin 字节 → `LineFrameDecoder` → 分发 → stdout 帧；串行写队列；通知通道；idle timeout |
| [bin/tree_agent.dart](bin/tree_agent.dart) | 入口（stderr 日志 / stdout 帧 / `--version`） |

## 不变量（assertions）

1. **stdout 上只有协议帧**。一行一帧（`encodeFrame`），别的什么都不写 —— 任何一行杂音都会让插件那侧的
   `LineFrameDecoder` 报"非法 JSON 帧"。日志一律 stderr。`--version` 是**独立模式**（不进入服务循环、
   不产生任何帧），所以它写 stdout。
2. **帧的写出串行化**（单队列）：并发请求的响应**绝不会互相截断**。写失败只记日志（一条帧写不出去
   不该把整条通道搞哑）；单帧超 `kMaxFrameBytes` 时 `encodeFrame` 抛 `FrameTooLargeException`，
   上报为丢弃而不是发一条对端必拒的帧。
3. **坏帧不让通道哑**：非法 UTF-8 / 非法 JSON / 超限行由 `LineFrameDecoder` 报错并**继续读**；
   空行直接跳过；响应/通知（带 `method` 的）一律忽略不回收。
4. **越界防护（双保险的另一半）**：每个路径参数（`fs.*` 的 `path`、`fs.rename` 的 `from` 与 `to`、
   `exec.spawn` 的 `log_path`/`cwd`、`exec.run` 的 `cwd`、`shell.open` 的 `cwd`）都先
   `normalizePosixPath` 再 `isWithinRoot`，越界一律 `-32001 path_out_of_root`（消息带上那个路径）。
   **不解析符号链接**（与 SFTP 层同口径：按链接本身操作），因此"软链接指向 root 之外"读得到目标内容 ——
   这与今天 dartssh2/SFTP 的行为一致，不是本包引入的缺口。
5. **破坏性操作额外挡住工作空间根自身**（对协议的**加固**）：`isWithinRoot(root, root)` 为真，
   于是一条 `fs.remove{path:<root>, recursive:true}` 就能把整个工作空间删掉。`fs.remove` / `fs.delete` /
   `fs.rename` 的 `from` 因此拒绝 `path == root`（回 `-32001`，消息说明是"拒绝破坏性操作"）。
6. **`fs.read` 是"拉"模型、字节无损**：单次最多 `kReadChunkBytes` 原文，base64 过线；返回
   `{data, size, offset, eof}`，核心侧循环发 `fs.read{offset}` 直到 `eof`。分块拼接后与原文**逐字节相等**
   （这是 `readFile` 结尾换行保真等上层语义的前提）。
7. **`fs.list` 只列文件、相对 `path`、POSIX 分隔符**，只做遍历与深度/数量上限，**不内建排除表**
   （排除规则的唯一真源在核心 `SshWorkspaceIO`，不变量 4 —— 两边各写一份必然漂移）。
   `scanned` 是"遍历过的目录条目数"（诊断用）。
8. **业务语义用显式预检表达，不靠 errno**：`fs.mkdir` 非递归时先判父目录（⇒ `-32005 parent_missing`）
   与目标（⇒ `-32003 already_exists`）；`fs.rename` 先判源（⇒ `-32002 not_found`）与目标
   （⇒ `-32003`，**绝不覆盖**）；`fs.remove` 目录非空且 `recursive=false` ⇒ `-32004 not_empty`。
   `FileSystemException` 的 errno 映射只是兜底（同时认 POSIX 与 Windows 的码）。
9. **递归删除自底向上、按链接本身删**：`Directory.list(followLinks: false)` 遍历，符号链接当叶子
   （`File(path).delete()` 删链接本身），**不跟着符号链接删穿**（不变量 12 的另一端）。
   `fs.list` 同理：链接**目录**不穿（防环），链接**文件**算文件。
10. **`exec.run` 没有"到点自动杀"**（全仓同一条口径）：`timeout_ms > 0` 到点**不杀进程、不重跑、
    不关通道**，返回**已经拿到的输出** + `timed_out:true`（此时 `exit_code` 拿不到 ⇒ **-1**），
    并把**完整输出**继续落盘 `<state>/run/<id>.out`；`timeout_ms <= 0`（含缺省）= **永不软超时**。
11. **启动子进程必须禁交互**（不变量 5）：`exec.run` 无论有没有 `stdin_b64` 都**立刻关掉子进程 stdin**
    （给了就先把字节打进去再关）—— 否则等输入的命令会永久挂住。
12. **`exec.run` 的输出是原始字节**：`stdout` / `stderr` 一律 base64，从不解码、从不做 UTF-8 清洗
    （非 UTF-8 归核心的 `SshWorkspaceIO` 处理）。内联部分每条流最多 `kExecRunMaxStreamBytes`（4 MiB），
    超出置 `truncated:true` 并把**完整**输出续写文件（不是"只剩截断后的一半"）。
13. **`exec.run` 缺省 `cwd` = 工作空间根**，与本地后端 `Process.start(..., workingDirectory: root)`
    同口径；`cwd` 不存在 ⇒ `-32010 exec_failed`（命令起不来）。
14. **后台执行 = 一等原语，与通道解耦**（协议 §3.4，`setsid` 是必需的）：
    - **立即返回**：agent 写一个 launcher 脚本，再用
      `setsid /bin/sh "<script>" </dev/null >/dev/null 2>&1 & echo $!` 起它并拿 pid
      （`setsid` ⇒ 自成会话/进程组，`pgid == pid`）；`&` 与 `echo $!` 在**同一条 sh** 里 ⇒ 包装 sh
      立刻退出、我们立刻拿到 pid（旧形状 `{ … } & echo $!` 会握到命令结束）。
    - **日志直写工作空间**：`log_path` 由调用方给（**工作空间内**路径，受越界检查）——
      **不用** `~/.tree/agent/out/`，否则 `readTail` / 文件面板 / `TerminalHooks` 全都读不到。
    - **退出码文件是唯一判据**：`printf '%s' $? > <state>/exit/<id>`；**`cd` 失败的那一支也写 127**
      （协议原文 `cd … || exit 127` 会**不写** ⇒ 只能对账成 `gone`，丢掉真相）。
    - **台账落盘**：`<state>/procs.json`（先写 `.tmp` 再 `rename`，**原子**）；**agent 自己重启后读回它**
      ⇒ `exec.list` 永远给得出真相，不依赖任何内存态。
    - **对账**：退出码文件在 ⇒ `exited` + `exit_code`；否则 `kill -0 <pid>` 活着 ⇒ `running`；
      否则 ⇒ `gone`（**`exit_code` 不填/不猜** —— 核心映射成 `BackgroundExecHandle.goneExitCode`）。
    - **`exec.kill` 尽力而为**：`kill -s <SIG> -- -<pgid>` 杀**整个进程组**；拿不到 pid/pgid ⇒
      `{killed:false}`，**不假装**。
15. **PTY 拿不到后端必须显式失败**（不变量 8）：`shell.open` 用 `script -qec <command> /dev/null`
    （util-linux）包裹；`command` 空 = 登录 shell（`$SHELL` → `/bin/sh`）；**目标机没有 `script`
    ⇒ `-32006 pty_unsupported`**，**绝不**静默降级成无 TTY 的 `exec`。
16. **PTY 的能力缺口如实报**（不变量 9）：`shell.resize` 恒回 `{supported:false}` 且**不抛**
    （`script` 不暴露 TIOCSWINSZ，pty 主设备 fd 在它自己进程里）；`shell.exit` **一定收口**
    （远端退出 / 主动 close / 拿不到状态，一律给数字，兜底 **-1**）且**只发一次**；
    `shell.close` **幂等**且**只关这一条**（不牵连别的会话）；输出是**原始字节**（base64 过线，
    解码后不清洗 ANSI）。
17. **`agent.hello` 是一次性握手**：`token` 不符 ⇒ `-32007 handshake_failed`（这条 stdio 只能是同一个
    启动方的）；`protocol != kAgentProtocolVersion` ⇒ `-32008 protocol_mismatch`（插件据此报
    `handshake_failed` ⇒ 核心回退内置 dartssh2）。
18. **零第三方运行时依赖**：只用 `dart:io` / `dart:convert` / `dart:typed_data` / `dart:async` /
    `dart:math`（目标机二进制越小越静态越好）——连 `package:path` 都不用（POSIX 路径规则手写一份最小
    实现，见 `path_guard.dart`），`sha256` 也自带一份（见 `agent_config.dart`）。
19. **`stdin` EOF = agent 退出**（协议 §8）：agent 进程本身不随 SSH 通道存活（它由通道拉起），
    但**它托管的后台任务不受影响**（不变量 14）。退出前把 shell 会话全部收口、把写队列排空。
20. **`--idle-timeout-ms` 到点也退出 = "执行器自觉优雅结束"**（2026-10-11 用户点名）：
    agent 只要收到**任何一帧**就重置这个计时，而插件在 `ready` 期间一直 `agent.ping`
    ⇒ 健康链路上**永远到不了**；**物理断网**时对端 sshd 收不到 FIN、通道给不出 EOF，
    这条就是它唯一的自救线索（缺省级 0 = 永不给手工调试用）。退出同样先收口 shell、排空写队列，
    后台任务照旧不受影响；新 agent 起来后从落盘台账认领（不变量 14）。

## 与协议文档的偏差 / 补充决定

实现时有几处协议未定或需要加固的地方，这里如实记账（改动面只在 `packages/tree_agent`）：

| # | 点 | 决定 | 为什么 |
| --- | --- | --- | --- |
| 1 | `exec.run` 到点后的 `exit_code` | **-1**（未知），另给 `timed_out:true` | 协议只写了"返回已获得的输出 + timed_out"；此时确实没有退出码，不能编 |
| 2 | `exec.run` 内联输出上限 | 每流 **4 MiB**（`kExecRunMaxStreamBytes`），超出 `truncated:true` + 全量落盘 | 一条响应就是一帧，单帧上限 `kMaxFrameBytes`=16 MiB；两条流各 4 MiB ⇒ base64 后 ≈10.7 MiB，留有余量 |
| 3 | `exec.spawn` launcher 脚本里 `cd` 失败 | **也写退出码 127**（协议原文 `cd … \|\| exit 127` 不写） | 否则对账只能落到 `gone`，丢掉 127 这个真相 |
| 4 | 破坏性操作对 root 自身 | **拒绝**（回 `-32001`，见不变量 5） | 一次 RPC 删掉整个工作空间的路必须堵死 |
| 5 | `fs.stat` 路径不存在 | 返回 `{type:'missing', size:0}`（**不抛**） | 协议 §3.2 的结果形状就是这么写的；核心 `_statOf` 两条路都收 |
| 6 | `agent.hello` 是否作为其他方法的门禁 | **不设门禁** | 这条 stdio 是插件独占拉起的，token 只做"同一个启动方"的一次性校验；门禁对正常流程无收益 |
| 7 | `--version` 的输出通道 | 写 **stdout**（独立模式） | 与命令行惯例一致；该模式不产生任何帧，不与"stdout 只写协议帧"冲突 |
| 8 | `shell.open` 的 `script` 参数 | **`-qec`**（按协议 §3.5 / 任务口径） | `tree_local_exec` 的 POSIX PTY 后端用的是 `-qefc`（多一个 `-f`）；两者都带 `-e`（回传子命令退出码），语义一致 |
| 9 | 落盘文件的 stdout/stderr 先后 | "开始落盘"接缝处**近似**（先补历史缓冲、再按到达顺序续写） | stdout / stderr 本来是两条独立管道，逐字节交织不可得 |
| 10 | `fs.list` 的 `scanned` | = 遍历过的**目录条目数** | 协议没定义；给一个对诊断有用、可复现的数 |

## 测试

```bash
cd packages/tree_agent
dart pub get
dart analyze lib bin test      # 0 issue
dart test                      # 全绿（POSIX 专属用例在 Windows 上带理由 skip）

# 交叉编译目标机产物（Linux）：
dart compile exe --target-os=linux --target-arch=x64 bin/tree_agent.dart -o .self/tree_agent-linux-x64
```

**Windows 开发机可跑**（本套用例就是这么跑的）：
`agent_config`（SHA-256 已知向量、CLI 解析、缺省状态目录）、`path_guard`（越界 / 前缀兄弟目录 /
`..` 逃逸 / 破坏性目标）、`fs_ops`（分块读的字节无损、write/append、stat/exists/isDir、递归 list 的
深度与上限、listEntries、mkdir / rename / remove / delete 的结果码、**每个方法的越界拒绝**）、
`proc_ledger`（原子写、重启读回、对账三分支、坏退出码文件不猜）、`exec_ops`（退出码 / stdout / stderr、
**缺省关 stdin 不挂**、软超时**到点不杀**、**超过内联上限 ⇒ truncated + 完整输出落盘**）、
`shell_ops`（`resize` 恒 `{supported:false}` 不抛、`close` 幂等、cwd 预检、**没有 `script` ⇒ -32006**）、
`agent_server`（hello 的 token / protocol 分支、ping/info、未知方法 `-32601`、非法 params `-32602`、
坏帧不哑通道、**stdout 上每一段都是合法 JSON-RPC 帧**、stdin EOF / idle-timeout 的生命周期）。

**POSIX 专属（Windows 上带理由 skip，M7 用交叉编译出的 Linux 二进制在 WSL/Docker 真跑）**：
`fs_ops_posix`（递归删除**按链接本身删、不删穿**；`fs.list` 不穿链接目录；`listEntries` 报 `link`）、
`exec_ops_posix`（缺省 cwd = root 的 `pwd` 印证、`stdin_b64`、stdout **原始字节**（`printf '\377\376\001'`）、
软超时后**进程仍在跑**且完整输出落盘、`read` 拿到 EOF 不挂）、
`exec_spawn_posix`（**立即返回**、`pgid == pid`、日志落 `log_path`、退出码文件、
`running → kill` 整个进程组、`exec.list` 对账、**agent 重启后读回台账**、`log_path`/`cwd` 越界拒绝、
launcher 脚本落盘形状）、
`shell_ops_posix`（`script -qec` 真 PTY：`shell.data` 原始字节、**exit 收口到命令的退出码**、
`shell.write` 回显、`close` 主动关也收口、`resize` 回 `{supported:false}`；**没有 `script` 则 skip**）。
