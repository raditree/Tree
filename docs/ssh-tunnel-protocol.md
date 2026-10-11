# SSH 执行器「中转站」协议（core ⇄ ssh_executor 插件 ⇄ tree_agent）

> 面向**改这三段任一环的人**。改动本协议 = 同时改三层：核心（`tree_local_exec` 的
> `TunnelSshTransport` + `PluginBus`）、插件（`packages/tree_ssh_plugin`）、
> 目标机执行体（`packages/tree_agent`）。**常量以 `packages/tree_tunnel_protocol` 为唯一真源**
> （方法名 / 错误码 / 帧编解码 / 协议版本都在那里，三端共用，不允许各处手写字符串）。

## 0. 为什么有这份文档

今天 SSH 执行器是核心进程内的 `DartSshTransport`（dartssh2：一条连接 + SFTP 多通道 + 一次性 exec）。
它有两个固有短板：**SFTP/新通道一旦被服务端拒绝就整条链路哑掉**（见 `known-issues.md` 的链路级故障），
以及**远端后台任务靠本机轮询哨兵文件**（跨日长任务一断就丢对账）。

新模型把"执行"搬到一个**常驻在目标机上的进程**（`tree_agent`）里，核心只跟它说 JSON-RPC：

```
WorkspaceToolRunner.sshIoFactory（唯一解析点）
 │
 ├─ 有中转站（首选）：ssh_executor 插件在、启用、隧道可用
 │    核心 TunnelSshTransport ──stdio JSON-RPC──▶ ssh_executor 插件
 │                                                  │
 │                                                  └──一条常驻 SSH exec 通道（stdio JSON-RPC）──▶ tree_agent
 │                                                                                                  （真正干活）
 └─ 无中转站（回退）：插件缺失/未启用/起不来/隧道建不起来/退避耗尽
      DartSshTransport（dartssh2）——**原样保留**，一行不改
```

**三条红线（不许破）**：

1. **降级只发生在「有没有中转站」这一维**，且**永远明示**（日志 + 右栏）。
   判定口径统一为：
   - **「插件在、但这条隧道的建立/健康出问题」**（探测失败 / 推送失败 / 握手失败 / 插件进程崩 / 退避耗尽
     ⇒ `tunnel_down`）⇒ **回退内置 dartssh2**，并写明"中转站不可用，已回退内置 SSH"；
   - **「隧道在、某次操作失败」**⇒ **如实暴露错误**（不重放、不回退、不静默）；
   - **「隧道还没好」（重连退避未耗尽）不算这一维** ⇒ **不降级、不判死**：前台操作**等它回来**，
     后台任务**什么都不发**地继续等（见 §10）。
2. **绝不静默回退成 local**（那会把远端工作空间悄悄变成本机目录）。
3. **在途命令失败以显式错误收尾**（与 `SshLinkStaleException` 同一语义），**不自动重放**
   （防重复副作用：远端训练 / 构建 / 写文件都不允许被偷偷跑第二遍）。
   例外只有一处（2026-10-11 明确）：**插件明确回了"本次请求未执行"**（`tunnel_not_ready`）
   才允许**重发**——那不是重放（重放 = 已发出去过的再发一遍）。

## 1. 三层与三类消息

| 层 | 载体 | 帧 | 角色 |
|---|---|---|---|
| L1 核心 ⇄ 插件 | 进程 stdio（`PluginHost` 已实现） | 行分隔 JSON-RPC 2.0 | 核心是**客户端**，插件是**服务端**（沿用既有插件协议） |
| L2 插件 ⇄ tree_agent | **一条常驻 SSH exec 通道**的 stdin/stdout | 行分隔 JSON-RPC 2.0 | 双方对等；插件发**请求**，agent 回**响应**，agent 另发**通知** |

**行分隔**：一行一帧，`\n` 结尾，UTF-8，`\n` 不出现在 JSON 里（二进制一律 base64）。
单帧上限 `kMaxFrameBytes = 16 MiB`（超限 ⇒ `frame_too_large`，**丢弃并回答错误，不静默截断**）。

## 2. L1：核心 ⇄ ssh_executor 插件

除标准方法（`hello` / `ping` / `shutdown` / `tools/list`）外，新增 5 个方法（**核心 → 插件**）：

| 方法 | params | result |
|---|---|---|
| `tunnel.ensure` | `{config: {...}, agent: {...}}` | `{ok, conn_id, root, agent: {...}}` 或 `{ok:false, error, error_kind}` |
| `tunnel.request` | `{conn_id, method, params}` | `{ok, result, error?, error_kind?}`（把 L2 的一次请求/响应透传回来） |
| `tunnel.state` | `{conn_id?}`（缺省 = 全部） | `{ok, tunnels: [{conn_id, host, port, username, root, state, attempt, elapsed_ms, last_error, agent}]}` |
| `tunnel.reconnect` | `{conn_id}` | `{ok, state, error?}`（**重置退避并立即做一次尝试**，等这次尝试有结果才回包；`ok:false` 时核心保持失活态并如实报错——**绝不假装恢复了**） |
| `tunnel.close` | `{conn_id}` | `{ok}`（收掉该隧道；agent 进程**不杀**，其托管的后台任务照常跑） |

**`config`**（来自核心 `SshConfig`，与 `agents/<id>.yaml` 的 `ssh:` 段同构）：

```
{ host, port:int, username, password?, key_path?, key_passphrase?,
  root?,                         // 空 = 远端登录用户 HOME
  login_shell?: null|""|"<tpl>", // 同 SshConfig.loginShell 三态
  agents_dir?: "" }              // 缺省 ~/.tree/agent
```

**`agent`**（插件 bootstrap 用）：**版本、sha256、二进制名一律由插件自报**（它才是随包带二进制的那一端），
核心**不再声明**（2026-10-11 用户裁决 B：核心那句 `version` 从来就没被插件读到过——核心只发 `config`、
插件读 `request['agent']`，两边的键从来没对上）。请求里若仍带 `version` / `bytes_sha256` / `binary_name`
只当**可选覆盖**，且版本以插件为准（不一致时插件记一条日志）。
`~/.tree/agent/<version>/tree_agent` 里的 `<version>` 因此 = **插件编译时注入的 `kAgentVersion`**，
重推判据是 **sha256**（版本串只决定目录名）。

**`state` 取值**：`connecting` → `booting`（推送/拉起/握手）→ `ready` ⇄ `reconnecting` → `down`。
`down` = 退避耗尽（累计 30 min）或握手/版本不可调和 ⇒ 核心**视其为「无中转站」**（下一次 IO 解析走内置）；
`reconnecting` **不是** `down` —— 它只是"还没好"，核心等它回来（§10）。

**插件 → 核心通知**（沿用 stdio 通知通道，`method` 为新名，不进前端工具面）：

| 方法 | params | 用途 |
|---|---|---|
| `tunnel/event` | `{conn_id, kind, ...}`，`kind ∈ {state, shell.data, shell.exit, exit_hint}` | 状态跃迁（核心据此更新本地 `SshLiveness` 与 UI）；PTY 的数据面与退出面 |

> `tunnel.state` 是**权威的拉取面**（核心每 `heartbeat_interval` 拉一次，当作这条隧道的心跳证据）；
> `tunnel/event` 只是**及时性**补充。核心**不依赖**推送也能正确判活 —— 推送丢了不致命。

**为什么工具面不用站点体系**：执行器是一条**通道**，不是一个"点位"。
它没有 `team_id/agent_id/session_id/mode_key` 这层语义，也不会申报工具 ⇒ **不进 17 个点位**、
不受站点隔离矩阵约束。`plugins.yaml` 里这条的 `scope` 留空（与 sample 插件同形状）。

## 3. L2：插件 ⇄ tree_agent

### 3.1 握手与生命周期

| 方法 | params | result |
|---|---|---|
| `agent.hello` | `{protocol:int, token:string, agent_version:string}` | `{protocol, ok:true, agent_version, os, arch, home, root, pid}` |
| `agent.ping` | `{}` | `{ok:true, at_ms}` |
| `agent.info` | `{}` | `{home, root, os, arch, agent_version, pid, uptime_ms}` |

- `token` = 插件启动 agent 时用 `--token` 传的一次性握手凭据（**只走命令行，不进日志**；agent 用它
  校验"这一条通道是同一个启动方"，防止别的本机用户蹭上这个 stdio）。
- `protocol` 不匹配 ⇒ 回错误 `protocol_mismatch`（`-32008`）⇒ 插件报 `handshake_failed`（`tunnel_down` 类）⇒ 核心回退。
- **不需要额外心跳线程**：`agent.ping` / 任意成功 RPC 都算心跳；agent 另有 `--idle-timeout`（缺省 **0 = 永不**，
  显式关掉即进程退出），保持"没有静态总时长上限"的仓库口径。

### 3.2 文件原语（对应 `SshTransport` 的 12 个方法）

**路径参数一律是目标机绝对路径**，且必须落在 `--root` 之内（见 §4）。

| 方法 | params | result |
|---|---|---|
| `fs.read` | `{path, offset?:int=0, length?:int}` | `{data:base64, size, offset, eof:bool}`（一次读 **≤ 1 MiB** 原文；`length` 缺省 = 到结尾，仍按 1 MiB 分块） |
| `fs.write` | `{path, data:base64, mode:'write'\|'append'=write, flush?:bool}` | `{size}` |
| `fs.stat` | `{path}` | `{type:'file'\|'dir'\|'missing', size, mtime_ms?, mode?}` |
| `fs.exists` | `{path}` | `{exists:bool, is_dir:bool}` |
| `fs.list` | `{path, max_depth?:int=8, max_entries?:int=20000}` | `{files:[相对路径...], truncated:bool, scanned:int}`（**递归**，POSIX 分隔符，跳过 `.` 开头目录由**调用方**用 `max_depth`/排除规则决定 —— 见下注） |
| `fs.listEntries` | `{path, max_entries?:int=5000}` | `{entries:[{name, type:'file'\|'dir'\|'link'\|'other', size, mtime_ms?}]}`（**一层**） |
| `fs.mkdir` | `{path, recursive?:bool=false}` | `{}` |
| `fs.rename` | `{from, to}` | `{}` |
| `fs.remove` | `{path, recursive?:bool=false}` | `{}` |
| `fs.delete` | `{path}` | `{}`（文件；不存在**不报错**，与 `SshTransport.delete` 同口径） |
| `fs.isDir` | `{path}` | `{is_dir:bool}` |

> **`fs.list` 与工具层排除规则**：`SshTransport.listFiles(maxDepth:)` 的调用方（grep / 工具层）
> 自己按"默认不扫隐藏路径、排除 node_modules 等"过滤（不变量 4）。协议层**只做遍历与深度上限**，
> 不内建排除表 —— 排除规则的唯一真源留在核心（`SshWorkspaceIO`），否则两边必然漂移。

**分块读写是"拉"模型**：核心 `readStream` 循环发 `fs.read{offset}` 直到 `eof`；
`writeStream` 循环发 `fs.write{mode:'append'}`。**没有推送式数据面**（除 PTY，见 §3.5）——
拉模型天然有背压，且一条请求一条响应，重连后不需要"续流"状态机。

### 3.3 前台命令

| 方法 | params | result |
|---|---|---|
| `exec.run` | `{command, cwd?, timeout_ms?:int=0, stdin_b64?:string}` | `{exit_code, stdout:base64, stderr:base64, truncated:bool}` |

- **登录外壳（`bash -lc` → `sh -lc` → 原样发）由插件完成**，不在 agent 里：
  插件握有 SSH 通道，用 `command -v bash` 探一次并**按隧道缓存**（语义与
  `tree_local_exec/lib/src/ssh_login_shell.dart` 完全一致，含 POSIX 单引号转义）。
  agent 收到的 `command` 是**最终字符串**，用 `/bin/sh -c <command>` 执行。
- `timeout_ms` 是**目标机侧的软窗口**（0 = 永不，缺省 0）。超时**不杀进程**：返回已获得的输出 +
  `timed_out:true`（agent 侧仍把输出落盘到 `~/.tree/agent/state/<key>/run/<id>.out`），
  由核心决定是否 `exec.spawn` 接管 —— **全仓同一条口径：没有"到点自动杀"**。
- `stdout`/`stderr` 用 base64（**字节不丢**；非 UTF-8 解码归核心的 `SshWorkspaceIO`，不在这里做）。
- agent 侧**禁用交互输入**（`stdin` 关掉，除非显式给 `stdin_b64`）——否则等输入的命令会永久挂住
  （`tree_local_exec` 不变量 5）。

### 3.4 后台命令（agent 托管 —— 本次升级的核心目标）

| 方法 | params | result |
|---|---|---|
| `exec.spawn` | `{command, log_path, cwd?, label?}` | `{id, pid, pgid, log_path, started_at_ms}` |
| `exec.list` | `{}` | `{procs:[{id, pid, pgid, command, log_path, cwd, started_at_ms, state, exit_code?}]}` |
| `exec.query` | `{id}` | `{proc:{...}}` |
| `exec.kill` | `{id, signal?:'TERM'\|'KILL'=TERM}` | `{killed:bool}`（拿不到 pid ⇒ `killed:false`，**不假装**） |

`state ∈ {running, exited, gone}`：
- `exited` = 退出码文件在；
- `gone` = 进程没了、退出码文件也没有 ⇒ 核心映射成 `BackgroundExecHandle.goneExitCode`（可辨，不当正常退出）。

**为什么这样就不怕断线（用户点名的"跨日级稳定性"）**：

1. **进程与通道解耦**：agent 用 `setsid` 起命令（自成会话/进程组，`pgid == pid`），
   命令的 stdout/stderr 直接重定向到 `log_path`，**不经 SSH 通道** ⇒ 通道断、核心崩、应用退出都不影响它。
2. **退出码落盘**：agent 写一个 launcher 脚本，末尾 `printf '%s' $? > <state>/exit/<id>`；
   退出码文件是**唯一判据**，不靠"本机轮询 + 猜进程死活"。
3. **台账落盘**：`~/.tree/agent/state/<key>/procs.json`（原子写）记录每个 id 的
   `{id, pid, pgid, command, log_path, cwd, started_at_ms}`。**agent 自己重启后**读回它，
   用 `kill -0 <pid>` 重新对账 ⇒ `exec.list` 永远给得出真相，不依赖任何内存态。
4. **`log_path` 是工作空间内路径**（核心指定）：`BackgroundExecHost.readTail(relativePath)` 与文件面板
   都按工作空间相对路径读它，因此日志必须落在 `--root` 之内（**这是对设计文档的一处修正**：
   原文写 `~/.tree/agent/out/<id>`，那会让 `readTail` / 文件面板 / `TerminalHooks` 全部读不到）。

`<key>` = `sha256(root)` 前 16 个 hex（同一台机器上多工作空间互不串扰）。

### 3.5 交互终端（PTY）

| 方法 | params | result |
|---|---|---|
| `shell.open` | `{command?, cwd?, columns, rows, term?='xterm-256color'}` | `{shell_id, pty:true}` 或错误 `pty_unsupported`（`-32006`） |
| `shell.write` | `{shell_id, data:base64}` | `{}` |
| `shell.resize` | `{shell_id, columns, rows}` | `{supported:false}`（见下） |
| `shell.close` | `{shell_id}` | `{}`（幂等） |

**agent → 插件通知**：`{method:'shell.data', params:{shell_id, data:base64}}`、
`{method:'shell.exit', params:{shell_id, exit_code}}`。

- PTY 用 `script -qec <command> /dev/null`（util-linux）包裹；`command` 空 = 登录 shell（`$SHELL` 或 `/bin/sh`）。
- **目标机没有 `script`** ⇒ `shell.open` 回 `pty_unsupported` ⇒ 插件透传 ⇒ 核心
  `openShell` **抛 `PtyUnsupportedException`**。**绝不静默降级成无 TTY 的 exec**
  （`tree_local_exec` 不变量 8：那会让 vim/top/Ctrl+C 直接坏掉，比明确报错更难查）。
- `shell.resize` **做不到**（`script` 不暴露 TIOCSWINSZ）⇒ 回 `supported:false` 且**不抛**
  （与 POSIX PTY 后端同口径，不变量 9）；核心记日志。
- 输出是**原始字节**（base64 过线，解码后不清洗 ANSI）。
- `shell.exit` **一定收口**：远端退出 / 对端关会话 / agent 关会话 / 插件主动 close，
  拿不到退出状态给 **-1**；`close()` 幂等且**只关这一条**（不牵连隧道）。
- **重连会丢掉所有 shell 会话**（agent 是重拉起来的）：在途 `SshShellChannel` 以
  `SshLinkStaleException` 收尾，**不自动重开**（PTY 是有状态交互，偷偷重开等于把用户的 vim 换成新 shell）。

## 4. 越界防护（双保险）

1. **核心侧**（既有，不改）：`WorkspaceIO.resolve` 拒绝绝对路径 / 盘符 / `..` 逃逸。
2. **agent 侧**（新增）：每个 `path` 参数先 `posix.normalize`，再把 `root` 也 normalize，
   要求 `path == root || path.startsWith('$root/')`，否则回 `path_out_of_root`（`-32001`）。
   - `fs.rename` 的 `from` / `to` **两个**都查；
   - agent **不解析符号链接**（与 SFTP 层同口径：按链接本身操作），因此"软链接指向 root 之外"
     读得到目标内容 —— 这与今天 dartssh2/SFTP 的行为**一致**，不是本次引入的缺口。

## 5. 错误码

JSON-RPC 标准：`-32700` 解析错 / `-32600` 非法请求 / `-32601` 方法不存在 / `-32602` 参数非法 /
`-32603` 内部错。

本协议专用（`code` 用 JSON-RPC 的 `error.code`）：

| code | name | 含义 |
|---|---|---|
| `-32001` | `path_out_of_root` | 路径逃出 `--root` |
| `-32002` | `not_found` | 路径不存在 |
| `-32003` | `already_exists` | 目标已存在（`mkdir` / `rename`） |
| `-32004` | `not_empty` | 目录非空且 `recursive=false` |
| `-32005` | `parent_missing` | 父目录不存在 |
| `-32006` | `pty_unsupported` | 目标机无 `script`（或 PTY 起不来） |
| `-32007` | `handshake_failed` | `agent.hello` 校验失败（token / 协议） |
| `-32008` | `protocol_mismatch` | 协议版本不匹配 |
| `-32009` | `permission_denied` | 目标机拒绝（EACCES） |
| `-32010` | `exec_failed` | 命令起不来 |
| `-32011` | `frame_too_large` | 单帧超 16 MiB |
| `-32012` | `busy` | 同一 id 已在跑 / 资源冲突 |

**插件 → 核心的 `tunnel.ensure` 失败面**（`error_kind`，核心据此决定"回退 vs 暴露"）：

| error_kind | 核心行为 |
|---|---|
| `agent_unreachable` / `push_failed` / `spawn_failed` / `handshake_failed` / `arch_unsupported` | **回退内置** + 明示 |
| `config_incomplete` | **不回退**：配置本身不完整，回退也一样连不上 ⇒ 如实报错 |
| `tunnel_down`（隧道已判死 / 已关闭 / 通道断在请求中途） | **回退内置** + 明示；**这一次请求如实失败、不重发**（中途断无法断言有没有执行到） |
| `tunnel_not_ready`（`connecting` / `booting` / `reconnecting`，2026-10-11 新增） | **不回退、不判死**：本次请求**确定未执行** ⇒ 核心**等隧道回到 `ready` 再发一次**（§10） |

> 判死的**唯一来源**是心跳快照里的 `state == down`，以及"插件进程已不可用"（核心实时查 `PluginBus`）。
> **请求级失败一律不判死**——把判死绑在一次请求失败上，就是 2026-10-11 那个
> "一次网络抖动 ⇒ 后台 hook 立刻失败 + 提前回退内置"的 bug。

## 6. 版本协商

- **L1**（核心 ⇄ 插件）：沿用既有插件 `hello` 的 `protocol: 1`；能力由
  `hello.capabilities` 里的 **`ssh-executor`** 声明 —— 这是核心"有没有中转站"的**唯一判据**
  （结合 `PluginBus` 现有的 enabled / running / degraded 状态）。
- **L2**（插件 ⇄ agent）：`kAgentProtocolVersion = 1`。
  插件随包携带**自己那一版**的 agent 二进制（版本由插件编译期注入，见下）；目标机上
  `~/.tree/agent/<插件自报版本>/tree_agent` 的 sha256 与随包二进制不一致（或缺失）⇒ 重新推送。
  `agent.hello` 回 `protocol != 1` ⇒ 插件报 `handshake_failed` ⇒ 核心回退（并在日志里写清
  "agent 协议 1 不匹配：目标是 N —— 请升级随包 agent"）。
- **版本号来源**：`tree_tunnel_protocol` 里的 `kAgentProtocolVersion` +
  `kAgentVersion`。`kAgentVersion` **只由两个构建脚本注入**：`tool/build_ssh_plugin.dart`（插件自报它）
  与 `tool/build_agent.dart`（agent 自报它）——**核心不参与**（2026-10-11 起，见 §10.5）。
  两个脚本都取 `pubspec.yaml` 的版本（`+` 之前那部分），因此**升版本号必须重跑它们**；
  `tool/package_windows.dart` 出包时会**校验**产物里的版本串与当前版本一致，不一致直接拒绝出包
  （那次教训：1.0.3+2 的包里塞着 1.0.2 编的插件与 agent，目标机上因此出现 `~/.tree/agent/1.0.2/`）。

## 7. 一张时序图（首次用于某主机）

```
核心                      插件                         目标机
 │ tunnel.ensure(config)   │
 ├────────────────────────▶│ ssh connect (dartssh2)
 │                         ├────────────────────────────▶ sshd
 │                         │ uname -m / command -v bash
 │                         ├────────────────────────────▶
 │                         │ stat ~/.tree/agent/<v>/tree_agent ; sha256
 │                         ├────────────────────────────▶
 │                         │ [缺失/不一致] 分块 base64 写文件 + chmod +x
 │                         ├────────────────────────────▶
 │                         │ client.execute("tree_agent --root .. --token ..")
 │                         ├────────────────────────────▶ (常驻通道)
 │                         │ agent.hello {protocol:1, token}
 │                         ├────────────────────────────▶
 │                         │◀───── {ok, os, arch, home, root}
 │◀── {ok, conn_id, root} ─┤
 │ tunnel.request{fs.read} │
 ├────────────────────────▶│ ── fs.read ──▶ agent ── ▶ 文件
 │◀── {ok, result} ────────┤◀──────────────
```

## 8. 已知边界（如实记录）

- 目标机需要 **POSIX**（`/bin/sh`、`chmod`、`setsid`、`kill`、`sha256sum` 或 agent 自带校验）；
  **Linux 是唯一承诺的目标**（本方案随包只发 linux amd64 / arm64）。
- `script`（util-linux）缺失 ⇒ 没有交互终端（`PtyUnsupportedException`），**不影响**其它能力。
- 隧道**不做端口转发**、不代理任意 TCP —— 它只服务工作空间 IO 这一件事。
- **agent 进程本身不随 SSH 通道存活**（它由通道拉起）⇒ 通道断 = agent 退；但 **agent 托管的后台任务不受影响**
  （`setsid` + 落盘退出码 + 落盘台账），重连后 `exec.list` 对账。
  插件拉起 agent 时**总是显式传 `--idle-timeout-ms`（90s）**：物理断网时对端 sshd 收不到 FIN、
  agent 收不到 EOF，它靠"这么久没有任何帧进来"**自己优雅退出**（见 §10.3）；缺省 0 = 永不只给手工调试用。
- **旧版本的驻留目录不会自动清理**：`~/.tree/agent/<旧版本>/` 会留着（新版本写新目录）。
  它是只读遗留物，不影响运行；要清就手工 `rm -rf ~/.tree/agent/<旧版本>`（后台任务的状态目录在
  `~/.tree/agent/state/`，**与版本目录无关**，别一起删）。

## 9. 实施补充（三端落地时的最终口径；与上文表格冲突处**以本节为准**）

1. **`tunnel.request` 的失败面分两类字段**：agent 的**业务错误**走 `error_code` / `error_data`
   （核心翻成 `RpcException` → `WorkspaceIoException` 或结果码，例如 `-32003 already_exists` 要能喂给文件面板的
   `WorkspaceMutationStatus`）；**链路类**失败走 `error_kind`（核心据此决定"回退 vs 如实暴露"）。
   `tunnel.ensure` 的失败面用 `error_kind`（见 §5 表）。
2. **`exec.run` 的内联输出上限**：每路（stdout / stderr）**4 MiB**，超出 `truncated:true`，
   **完整输出续写** `<state>/run/<id>.out`（一条响应 = 一帧，`kMaxFrameBytes` = 16 MiB，两条流 base64 后留有余量）。
   **软超时时 `exit_code = -1`** + `timed_out: true` —— 那时确实没有退出码，**不编一个**。
3. **`exec.spawn` 的 launcher 在 `cd` 失败时也写退出码 `127`**（原方案只 `exit` 不写 ⇒ 只能对账成 `gone`，丢掉真相）。
4. **破坏性操作拒绝工作空间根自身**：`fs.remove` / `fs.delete` / `fs.rename` 的 `from` 指向 `--root` 时回
   `-32001`（`isWithinRoot(root, root)` 为真，否则一条 RPC 就能删掉整个工作空间）。
5. **`agent.hello` 不是门禁**：其余方法不要求先握手。这一条 stdio 由插件独占拉起，`token` 只做
   "这一条通道是同一个启动方"的一次性校验（防同机别的用户蹭上）。
6. **推送分块 = 64 KiB 原文**（base64 ≈ 87 KiB 命令）。上限**不是** `ARG_MAX`，而是 **SSH 信道请求报文**：
   `exec` 的 command 是一个报文，塞太大会被对端当协议错误**直接断连**。
   **实测**（`packages/tree_ssh_plugin/tool/probe_command_len.dart`，2026-10-10，WSL 的 OpenSSH sshd）：
   base64 载荷 131072 / 174764 / **218456** 字节 OK，**262144 字节起失败**
   （`SSHStateError(SSH connection closed)`）。取 64 KiB 留 3 倍余量；
   回归钉子见 `packages/tree_ssh_plugin/test/bootstrap_test.dart` 的「推送块必须留在实测上限之下」。
7. **agent 二进制的查找位置**：`<插件可执行文件所在目录的上一级>/agents/tree_agent-linux-<arch>`
   （发行 = `<应用目录>/agents/`，开发 = `<仓根>/build/agents/`，正是 `tool/build_agent.dart` 的落点），
   再退 `agent.binary_path` → 环境变量 `TREE_AGENT_BINARY` → 仓根 → cwd。
8. **`hello.plugin_id` = `kSshExecutorPluginId`（`ssh_executor`）**，与核心的内置目录 / 面板开关 / 播种同源。
9. **`tree_agent` 的 POSIX 专属行为在 Windows 开发机上 `skip`**（`script` / `setsid` / `kill -0` / 符号链接语义，
   共 19 条，带可读理由），因此**真机验证靠两条门控**：
   `packages/tree_ssh_plugin` 与 `tool/tunnel_e2e.dart`（真 sshd + 真二进制，未设 `TREE_SSH_TEST_HOST` 时跳过）。
10. **拉起 agent 时 `--root` 一定带、且一定是绝对路径**（实测教训，2026-10-10）：
    `--root` 既是 agent 的**越界防护基线**，也是 `exec.run` 里 `cd` 的目标。给空 / 相对路径 / `~` 都不行 ——
    agent 会以「缺少 --root」直接退出、通道随即关闭，插件只能报 `handshake_failed`。
    所以插件侧先 `resolveRemoteRoot(config.root, $HOME)`（空 / `~` / 相对 ⇒ 相对远端 `$HOME`，绝对 ⇒ 归一化），
    **再 `mkdir -p <root>`**（目录不存在的话，之后每一条 `cd <root> && …` 都会失败）。
11. **插件自带一个只读左栏面板**（`activity` 槽位，2026-10-11 加；机制全部复用既有声明式槽位，
    核心与前端都没改）：
    - `slot_key = ssh_executor.activity.1`（固定常量：一个插件条目 = 一个进程实例）、`slot = activity`、
      `icon = link`、`order = 30`；槽位条目**不带** `plugin_id` / `team_id`（归属由核心按实例 id 与
      `plugins.yaml` 的 `scope.team_id` 兜底；本条目 `scope: {}` ⇒ **任何 team 下都可见**）。
    - `ui/manifest` **只发一次**（`PluginLoop.run()` 起手），之后走 `ui/update`；前端后连 / 重连 /
      插件先就绪这三种时序由核心的 `PluginUiCache` + 补放兜住，插件不自己重发。
    - 视图**只用受限控件集**（`column` / `text` / `actions`）；**只读**，数据全部来自隧道台账
      （`TunnelManager.tunnels` / `Tunnel.stateJson()` / `Tunnel.installPath`）——**不出现任何凭据**。
    - 两个动作经 `plugin_ui_action` 回插件：`reconnect`（健康通道上是 no-op，断了才真重建）与
      `close`（**两段式**：第一下只进确认态、20s 过期、第二下才 `tunnel.close`）；
      **判据在 `params['event']` 上**（`{"method":"event","params":{"event":"plugin_ui_action", …}}`），
      不是 `method` —— 写错就是"点了没反应"且不报错（`docs/plugin-development.md` §10 常见坑 ⑥）。
    - **刷新不借 `tunnel/event`**：那是核心与插件之间的内部数据面（§9.1 的失败面/事件面），
      核心明确不把它降级成 `plugin_event`；面板靠状态跃迁就地 `refresh()`（300ms 节流合并）。

## 10. 断连完整性（2026-10-11 定稿；用户真机反馈后的修复口径）

起因：用户在生产机（`open@open`）用**物理断网**模拟抖动，看到两个症状——
**① 一断网就立刻收到 hook 失败**（而该等到退避耗尽）；**② 恢复网络后目标机上又多出一个执行器进程**。
两个都查实为真 bug，根因与修法如下（都是**三层一起**的口径）。

### 10.1 「还没好」≠「已判死」（这三条一起才成立）

1. **插件**：隧道在 `connecting` / `booting` / `reconnecting` 时，`tunnel.request` 回
   **`error_kind = tunnel_not_ready`**（不再是 `tunnel_down`），并附 `tunnel_state` / `attempt`；
   `down` / 已关闭 / 通道断在请求中途 ⇒ 仍回 `tunnel_down`。
2. **核心**：**判死只来自两处** —— 心跳快照 `state == down`、以及"**这条会话绑定的那个插件实例**
   已不可用"（`TunnelSession.boundHostAlive` ‖ `pluginAvailable`，后者实时查 `PluginBus`）。
   **请求级失败一律不判死**，所以旧插件（还在报 `tunnel_down`）也不会再造成"一次抖动就回退内置"。
   ⚠ 判据必须是"**我绑的那个实例**还在不在"，写成"当前有没有插件"会漏掉"插件重启换了进程"
   这一整类（见 §10.8）。
3. **前台请求等它回来**：收到 `tunnel_not_ready` ⇒ 不判死、不失败，**轮询 `tunnel.state`**；
   回到 `ready` 就**重发那一次请求**（确定未执行 ⇒ 不是重放）；看到 `down` 才以
   `SshLinkStaleException` 如实失败。兜底预算 `_maxReadyWait = 30 min`（防"反复 ready/不 ready 抖动"
   把一次调用挂成永恒）。
4. **后台任务（agent 托管）**：断连期间**什么都不发**（我们真的不知道远端死活），按 30s 慢探等待，
   **只有判死**才以失联收尾并投递**一次**提醒（文案：可能目标主机关闭、不要大量重试、不要直接重跑）。
   这一条 2026-10-11 早些时候已落（核心侧），本次修的是它**根本走不到**——因为传输层提前判死了。

### 10.2 判死之后才回退

`FallbackableWorkspace.tunnelDown` 仍然驱动 `WorkspaceToolRunner._ioFor` 撤换 IO 缓存并回退内置，
但**它只会在真判死时为真**（上面 10.1 的第 2 条），因此"降级只发生在有没有中转站这一维"这条红线
在时间轴上也成立：**抖一下不回退，耗尽才回退**。

### 10.3 执行器自己察觉断连并优雅退出

- 插件在 `ready` 期间**按 20s 定时 `agent.ping`**（单次 10s 响应窗口），连续 **3** 拍无响应 ⇒
  认定通道已死（agent 卡死 / 链路黑洞）⇒ 拆掉重建（`tunnel.reconnect` 也走同一探针，
  因此"ready 但卡死"不再是 no-op 空转）。
- 插件 spawn 时**总是传 `--idle-timeout-ms 90000`**：agent 只要收到任何一帧就重置这个计时，
  而插件一直在 ping ⇒ **健康链路上永远到不了**；物理断网时它靠"90s 没有任何帧进来"**自己优雅退出**
  （关掉会话、退出码 0），不再干等 sshd 的 TCP 超时。用户口径原话："**执行器应该自觉优雅结束**"。
- 后台任务由 `setsid` 独立跑、退出码与台账都在目标机磁盘上 ⇒ agent 换代对它零影响；
  **新 agent 起来后从 `procs.json` 认领**（§3.4），所以"重连后那个后台任务照样能回来"。

### 10.4 重建前收掉上一世 agent（双保险，零误杀）

`Tunnel` 记着上一世 agent 的 `pid` + 启动时那次性 `token`；下一次 `_attempt()` 在建连之后、拉起之前
先跑一条守卫命令：`/proc/<pid>/cmdline` 里**必须含那个 token**（32 位 hex，每次启动都换）才 `kill`；
读不到 / 核对不上 ⇒ **不杀**，只记日志。宁可留一个（它会在 90s 内自己退），也绝不误杀别人的进程
或**另一台机器**连到同一主机的 agent。

### 10.5 版本口径与出包校验

- **核心不再声明 agent 版本**（`TunnelConnectRequest` 删掉了 `agentVersion` / `agentSha256` /
  `agentBinaryName`）：只有插件知道它随包带的是哪个二进制 ⇒ 版本**只由插件自报**。
- **出包校验**：`tool/package_windows.dart` 复制 `build/plugins`、`build/agents` 之前会扫产物里的
  版本串，与 `pubspec.yaml` 的版本（`+` 之前）不一致就**拒绝出包**并提示先跑哪条构建命令。

### 10.6 核心启动竞态：插件还没起来时**别急着回退内置**（2026-10-11 用户真机）

现象（用户机器日志，两行只差 **53ms**）：

```
09:35:00.081 pid=22556 [core:tool]   无 SSH 中转站（中转站插件「SSH 执行器中转站」未在运行（尚未启动））⇒ 使用内置 dartssh2
09:35:00.134 pid=22556 [core:plugin] 插件 ssh_executor 就绪
```

插件是**异步**拉起的，而 SSH 解析可能在插件就绪**之前**发生；更糟的是那次解析一旦回退内置，
这条 IO 会被 `WorkspaceToolRunner._ios` **缓存住**、插件就绪后也不会自己回切 ⇒
**整场都跑在内置 dartssh2 上，中转站等于白装**（用户那一跑就是这样，一条 `[core:tunnel]` 都没有）。

修法两件（都在核心侧，插件协议不变）：

1. **有界等待**：`PluginBus.sshExecutorLookupWaitingForStart(timeout: 1s, interval: 100ms)` ——
   `sshIoFactory` 在"条目启用、但实例还没起来 / 还没申报能力"时最多等 1s 再定这条 SSH 走哪条路。
   **只对这一种原因等**：条目停用 / 启动失败（`_errors` 里有原因）/ 通道断了 ⇒ 立即回退。
2. **一次性撤换**：`_ioFor` 发现"缓存里是内置后端（非 `FallbackableWorkspace`）而插件已经就绪"时，
   丢掉缓存重解析（每个 agent **只试一次**，避免插件在但隧道建不起来时每次解析都去撞 dial）。

### 10.7 内置 dartssh2 路径：失败文案照旧，但**台账留着、链路恢复后接回**（用户 2026-10-11）

用户明确：内置路径**不引入等待与上界**（"失活即失败"照旧，文案不变），只要求
"**重连后该 hook 要回来**"。做法（不动两端口径，只补一条接回通道）：

- `TerminalHooks._fail`（链路失活 / 判死那种收尾）改成 `_settle(task, keepLedger: true)`：
  **不删台账**（本机任务本来就没有台账条目）⇒ 远端进程可能还在跑，台账是唯一凭据；
- `SshLiveness` 加与 `onStale` 对称的 **`onRecovered`**（失活 → 活，或重连成功的 `reset()` 时各触发一次）；
  `ReconnectableWorkspace` 暴露 `linkLiveness` ⇒ 核心 `WorkspaceToolRunner._installLinkRecoveredHook`
  在链路重建那一刻调 `TerminalHooks.restorePending(ioFor:…, agentId:…)`（新增按 agent 过滤）把任务认领回来；
- 认领 = **对账**：`attachBackground` 按哨兵文件（内置路径）/ 落盘台账（托管路径）继续判，拿到
  **真实**退出码后再投一次完成提醒（第一次那条已写明"可能仍在跑、不要重跑"），然后才删台账。
  不会无限重复：真相一旦可判（`exited` / `gone`），认领即收尾并清台账。

### 10.8 判死口径精确化：插件**重启换了实例**也算判死（2026-10-11 用户真机）

用户用完左栏面板后报："手动关闭隧道后就无法重连了，甚至重启 SSH 插件后还没用"。两层原因，
第二层是**传输层的判据写窄了**：

- **面板侧**（次因）：`close` 之后插件把那条隧道从台账移除 ⇒ 面板那一行（连同【重连】按钮）
  一起消失；而动作失败**只写 stderr**、界面上毫无反馈 ⇒ 表现就是"点了没反应"。
  修法：动作的**结果 / 失败一律渲染成一行**（`TunnelUiPanel.lastActionNote`），关闭成功后明确写
  "核心下次使用这个工作空间时会重建"。
- **传输层（主因）**：`_PluginTunnelSession` 把 `PluginHost` **固化在构造期**，而判死闸门写的是
  "**当前**有没有可用插件"（`pluginAvailable`）。插件停用又启用会换一个进程实例 ⇒ 新实例在跑
  ⇒ 查询为真 ⇒ **不判死** ⇒ `FallbackableWorkspace.tunnelDown` 永远 false ⇒
  `WorkspaceToolRunner._ioFor` 永不撤换缓存 ⇒ 这条绑着**已关闭旧实例**的 IO 永久坏：
  真机日志每 10 秒一条 `隧道 conn-1 心跳失败：插件 ssh_executor 的输出流已关闭`，而且**回不来**。

**定稿口径**（用户 2026-10-11 认可）：判死 = **这条会话赖以工作的那个中转站实例已不可再用**。

| 情形 | 判死？ |
|---|---|
| 插件自标 `down`（退避耗尽 / 不可调和） | ✅ |
| **绑定的那个实例**不可用（通道断 / 进程退出 / 能力丢失，`boundHostAlive == false`） | ✅ |
| 插件整体不在（`pluginAvailable == false`，兜底） | ✅ |
| 隧道 `connecting` / `booting` / `reconnecting`（`host` 活着） | ❌ 等它回来 |
| 单次请求失败 / 通道断在请求中途 | ❌ 如实失败、不重放 |
| 网络抖动导致 `snapshot` 超时，但 `host` 活着 | ❌ 等它回来 |

判死之后走的仍是 §10.2 那条路：撤换 IO 缓存 ⇒ **下一次解析**该工作空间时重建
（插件可用 ⇒ 走中转站新建一条隧道；不可用 ⇒ 回退内置 dartssh2 并明示）。**不是自动重连**。

**判死即静默收尾**：判死那一拍会**停掉心跳**、并把活性台账**立刻**置失活（在途操作随之以
`SshLinkStaleException` 如实失败）。否则这条已判死的会话每 10 秒还会拉一次状态、打一行
`心跳失败`——真机 2026-10-11 就是这样把日志刷了几百行，反而掩盖了判死那一条。

**判死必须真的能被核心看到（透传链）**：`WorkspaceToolRunner._ioFor` 的撤换判据读的是
**外层装饰器**的 `tunnelDown`，它必须一路透传：`PrivateWorkspaceIO`（`tree_core`）
→ `SshWorkspaceIO`（`tree_local_exec`）→ `TunnelSshTransport`（真正置标志的人）。
`SshWorkspaceIO` 一度**没有**实现 `FallbackableWorkspace` ⇒ `tunnelDown` 恒为 false ⇒
"判死 ⇒ 撤换缓存 ⇒ 下次解析重建"这条路对 SSH 工作空间成了**死代码** ⇒ 判死之后核心一直握着
那条死链路（用户 2026-10-11 原话："总不能手动关一次就不能用了"）。三层现在都实现该接口，
`ssh_workspace_io_test` 有一条钉子钉住这一环。

**判死文案如实**：插件自标 `down`（真·退避耗尽 / 不可调和）与"插件已不再持有这条 `conn_id`"
（隧道被收掉 / 面板关闭 / 插件换了实例）都会让心跳快照成 `down`。文案按 `last_error` 有内容与否
分开写 —— 不再一律硬拼"（退避耗尽）"。

**顺带加固 `conn_id`**：插件侧 `conn_id` 现在带**进程内随机前缀**（`conn-<rand4>-<seq>`）。
理由：它本来是进程内序号，插件重启后从 `conn-1` 重来；核心侧若还留着旧会话（绑的是旧实例），
拿旧 `conn_id` 去新实例问状态，就可能**命中新实例的另一条隧道**（root 可能不同）⇒ 静默跨 root
（踩 §0 红线）。判死修好后旧会话很快会被停用，随机前缀让它**不可能发生**，而不是"很快收敛"。
