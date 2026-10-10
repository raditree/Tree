# tree_ssh_plugin

SSH 执行器新架构里的**「中转站」**（`ssh_executor`，**binary 型内置插件**，由核心 spawn 的本机进程）。
它把"核心 ⇄ 目标机"的长链路收成两段：

```
核心 ──stdio 行分隔 JSON-RPC 2.0（L1）──▶ 本插件 ──一条常驻 SSH exec 通道（L2）──▶ tree_agent（目标机）
```

## 职责（只做这四件事）

1. **bootstrap**：用一次 SSH（`dartssh2`）连上目标机 → `uname -m` 探架构 → 把随包 `tree_agent`
   推送到 `~/.tree/agent/<version>/tree_agent`（`sha256sum` 对账，缺/不一致才推；base64 分块写 `.part`
   → 校验 → `chmod +x` → `mv -f`）→ 以一条 **exec 通道** 拉起它（`<agent> --root <root> --token <token>`）
   → `agent.hello` 握手。
2. **中转**：此后所有操作只走**这一条常驻通道**的 JSON-RPC —— 把核心的 L1 请求转成 L2 请求发给
   `tree_agent`，把响应/通知回传。**SFTP 不参与稳态**（它正是旧模型"服务端拒新通道 ⇒ 整条链路哑掉"的根因）。
3. **重连**：通道断/心跳丢 ⇒ 指数退避重连（重连即**重跑 bootstrap**，所以 agent 版本对账天然完成）；
   退避**累计时长上限 30 分钟**，耗尽 ⇒ 自标 `down`（核心据此回退内置 dartssh2）。
4. **申报能力**：`hello` 回 `capabilities: ["ssh-executor"]` —— 核心判断"有没有中转站"的**唯一判据**。

**它不做**：不做临终回退（插件崩了就等于"没有中转站"，核心下一次 IO 解析自然走内置 —— 插件不必知道内置存在）；
不做端口转发；不申报任何工具、不订阅任何点位（执行器是**通道**不是点位）；不自动重放在途请求。

## 内容

| 文件 | 内容 |
|---|---|
| `bin/tree_ssh_executor.dart` | 插件入口：stdin 读帧 → `PluginLoop`；stdout 写帧（每帧 flush）；日志一律 stderr |
| [lib/src/plugin_loop.dart](lib/src/plugin_loop.dart) | **L1 服务端**：`hello` / `ping` / `shutdown` / `tools/list` + 5 个 `tunnel.*`；请求**并发**处理（读循环不 await 业务）；未知方法回 `-32601` |
| [lib/src/tunnel_manager.dart](lib/src/tunnel_manager.dart) | 多隧道台账 `Map<conn_id, Tunnel>`；`tunnel.ensure` 按 `host\|port\|username\|root\|login_shell` **去重**；`tunnel.state` / `reconnect` / `close` |
| [lib/src/tunnel.dart](lib/src/tunnel.dart) | 单隧道状态机 `connecting → booting → ready ⇄ reconnecting → down`；退避（[Backoff] + 可注入 [TimerFactory]）；在途请求显式收口；PTY 通知转 `tunnel/event` |
| [lib/src/bootstrap.dart](lib/src/bootstrap.dart) | 六步 bootstrap（探架构/推送/chmod/拉起/握手）+ 六种 `error_kind`；`buildSpawnCommand` / `mapArch` / token |
| [lib/src/agent_client.dart](lib/src/agent_client.dart) | **L2 客户端**：请求响应配对、通知外转、坏帧不致哑、通道死 ⇒ 在途全部以 `AgentChannelClosed` 收口 |
| [lib/src/ssh_dialer.dart](lib/src/ssh_dialer.dart) | **可注入**的 SSH 面：`SshConnection` / `SshChannel` / `SshDialer` + dartssh2 实现（`DartSshDialer`） |
| [lib/src/login_shell.dart](lib/src/login_shell.dart) | 登录外壳：三态模板、`bash -lc`→`sh -lc`→原样发、POSIX 单引号转义、一次隧道只探一次 |
| [lib/src/backoff.dart](lib/src/backoff.dart) | 退避节奏 1s→2s→…→60s 封顶；累计上限 30 分钟（**上限是累计等待，不是单次超时**） |
| [lib/src/tunnel_config.dart](lib/src/tunnel_config.dart) | L1 `config` 解析（含 `login_shell` 三态、`agents_dir`）、去重键、`host:port/user` 安全标签 |
| [lib/src/agent_binary.dart](lib/src/agent_binary.dart) | 随包 `tree_agent` 的本机定位（`binary_path` / `TREE_AGENT_BINARY` / **与插件同级的 `agents/`**）与 sha 校验 |
| [lib/src/sha256.dart](lib/src/sha256.dart) | 最小 SHA-256（**不引 `crypto`**：本插件只允许 `dartssh2` + `tree_tunnel_protocol` 两个运行时依赖） |
| `test/` | 假远端 / 假 dialer / 假时钟 + 各层用例（见下） |

## 不变量（assertions）

1. **stdout 只有协议帧**，日志一律 stderr（`bin` 里唯一的 stdout 写点是 `frameBytes`；`test/executor_process_test.dart` 用真进程钉住）。
   **每帧后不 `flush()`**：`stdout.flush()` 会把底层 sink 标成 "bound"，同一批到达的多帧（读循环一次 `add`
   里解出好几条请求）再 `add` 时就会抛 `Bad state: StreamSink is bound to a stream`（编译成 exe + 管道 stdin 时实测必现，
   已由"一次塞多帧"用例钉住）；Dart 的 stdout 本身不做行缓冲，`add` 即写。
2. **读循环不 await 业务**：每个请求在独立 Future 里处理，`ping` 永远立即回（否则一次慢 `tunnel.ensure` 就会让核心判 degraded）。
3. **方法名/错误码/帧编解码只来自 `tree_tunnel_protocol`**：插件里不出现第二份 `"fs.read"` / `-32002` 之类的字面量
   （标准插件方法 `hello`/`ping`/`tools/list`/`shutdown` 不在那个包里，因此在 `plugin_loop.dart` 里定义一次常量）。
4. **`hello.capabilities` 必须含 `ssh-executor`**：这是核心"有没有中转站"的唯一判据。
5. **`tunnel.ensure` 的失败面必须分类**（`error_kind`）：`config_incomplete`（本机配置不全，**不回退**）、
   `arch_unsupported` / `handshake_failed`（不可调和 ⇒ 直接 `down`）、`agent_unreachable` / `push_failed` /
   `spawn_failed`（可重试 ⇒ 退避）。**每一步失败都不静默**（每一步都带可读原因）。
6. **在途请求不重放**：通道断时全部以可读错误收尾（`error_kind: tunnel_down`），远端命令可能有副作用，
   "偷偷跑第二遍"是禁止的。
7. **`tunnel.state` 是权威的判活面**，`tunnel/event`（`kind: state|shell.data|shell.exit`）只是**及时性补充**：
   推送丢了不致命，核心拉 `state` 永远拿得到真相。
8. **凭据永不外泄**：`password` / `key_passphrase` / `agent --token` 不进任何日志、不进 `tunnel.state` / `tunnel/event`；
   日志里的 SSH 目标一律是 `host:port/user`（`TunnelConfig.label`），异常文本再过一道 `sanitizeSecrets`。
9. **登录外壳只包 `exec.run`**（agent 收到的是**最终字符串**）；`exec.spawn` 保持"内层只依赖 POSIX `sh -c`"
   的既有口径（`tree_local_exec` 不变量 16），不套壳。
10. **bootstrap 推送是原子的**：写 `<agent>.part` → `sha256sum` 校验 → `chmod +x` → `mv -f` 到正式路径；
    中途失败不会留下"半个可执行文件被当成 agent"。
11. **`close()` 幂等**：关通道 + 关连接；agent 由这条通道拉起（协议 §8：通道断 = agent 退），
    插件**没有**额外 `kill` 它，也不碰它托管的后台任务（`setsid` + 落盘退出码）。
12. **测试不碰真网络**：SSH 面全部通过 `SshDialer` / `SshConnection` / `SshChannel` 注入假实现；
    退避用可注入的 `TimerFactory`（**不在测试里真等 30 分钟**）。

## 与协议文档的补充决定（本插件侧）

1. **`agent` 参数从哪拿二进制**：协议只说 `{version, bytes_sha256, binary_name?}`，而核心当前
   （`plugin_tunnel_link.dart`）**只发 `config`**，不发 `agent` ⇒ 插件按**自己的编译期常量**
   （`kAgentVersion` / 本机算出的 sha256）干活。二进制的查找顺序：`agent.binary_path` →
   环境变量 `TREE_AGENT_BINARY` → **与插件可执行文件同级的 `plugins/` 的上一级 + `agents/`**
   （发行包 = `<应用目录>/agents/`；开发态 = `<仓根>/build/agents/`；这正是
   `tool/build_ssh_plugin.dart` 与 `tool/build_agent.dart` 的落点，与
   `builtin_plugins.dart` / `tool/package_windows.dart` 里写的「`agents/` 与 `plugins/` 同级是插件的查找约定」一致）
   → 向上找仓根 → cwd 兜底 → `<目录>/assets/`。`binary_name` 支持 `{arch}` 占位，
   缺省 `tree_agent-linux-<arch>`。**注意**：`tool/build_ssh_plugin.dart` 目前编译插件时
   **没有** `-DkAgentVersion=<版本>`，所以插件侧的 `kAgentVersion` 还是 `0.0.0-dev`
   （目标机驻留目录因此会带这个串）；重推判据是 sha256，功能不受影响，但两端的版本串会对不上
   （插件会在日志里明说这件事）。修那一处属于 `tool/`（不在本包范围内）。
2. **`tunnel.request` 的失败面补 `error_code` / `error_data`**：协议表里只有 `error` / `error_kind`，但核心
   （`plugin_tunnel_link.dart`）要把 `not_found` / `parent_missing` 映射成业务语义 ⇒ agent 的业务错误
   按核心的读法透传 `error_code` / `error_data`，且**不带** `error_kind`（只有链路级失败才带
   `error_kind: tunnel_down` ⇒ 核心据此区分"回退"还是"如实暴露"）。
3. **未知 `conn_id` 的口径**：`tunnel.state` 回 `{ok:true, tunnels:[]}`（核心据此知道"这条没了"）；
   `tunnel.close` 幂等回 `{ok:true}`；`tunnel.reconnect` 回 `{ok:false, error}`（不装）。
4. **`down` 之后的再次 `ensure`**：清零退避、重新给一轮机会（用户可能已经修好了目标机/网络）。
5. **不做额外心跳线程**（协议 §3.1 明说不必要）：通道死亡靠 `channel.exitCode/stdout` 关闭、请求写读失败、
   以及 dartssh2 自带 keepAlive 三处收敛；`tunnel.state` 才是权威面。
6. **本机私钥问题归 `config_incomplete`**：`SshConfigException`（私钥文件不存在 / 无法解析）不映射成
   `agent_unreachable`——回退内置也一样连不上，如实报配置问题才对。

## 测试

```bash
cd packages/tree_ssh_plugin
dart pub get
dart analyze lib bin test      # 必须 0 issue
dart test
```

> 本机 PATH 上的 `dart` 是 2.19.6，不够用（本包要求 `sdk: ^3.13.0`）。
> 开发机上用 `D:\app\flutter-sdk-3.47.5\flutter\bin\dart.bat`（Dart 3.13.4）跑上面三条命令。

覆盖点：

- `sha256_test`：标准向量（期望值由独立实现 .NET SHA256 产出）；
- `backoff_test`：1s→2s→…→60s 节奏、累计 30 分钟上限、`reset`；
- `login_shell_test`：三态模板、`bash`→`sh`→原样发的回退、单引号转义、缓存、非法模板跳过；
- `bootstrap_test`：**命令形状**（`uname -m` / `sha256sum` 对账 / 分块 base64 推送 / `chmod +x && mv -f` /
  拉起命令行）、分块数与 `.part` 原子落地、跳过推送（sha 一致）、六种失败分类、token 不进日志；
- `agent_client_test`：请求响应配对、通知、坏帧不致哑、agent 反向请求回 `-32601`、通道死收口；
- `tunnel_test`：状态机跃迁、退避节奏与耗尽 ⇒ `down`、不可调和 ⇒ 直接 `down`、通道断 ⇒ 在途显式失败且**不重放**、
  显式重连清退避、`exec.run` 的登录外壳包裹、PTY 通知转发、`stateJson` 不含凭据；
- `plugin_loop_test`：L1 分发（含未知方法 `-32601`）、去重（同 key 复用 `conn_id`）、错误分类、`shutdown`/stdin 关闭退出、
  慢 `ensure` 不堵 `ping`；
- `executor_process_test`：**真起插件进程**说 L1（stdout 无杂质 / 日志走 stderr / 一次塞多帧也逐条回 / 退出码 0）。

**未覆盖**：真机 SSH（本机没有可连的 sshd，仓库也还没有 `tree_agent` 二进制）。因此
"命令形状"与"状态机"被钉住了，但"真 sshd 上的语义"要靠门控真机测试（后续任务）验证。
