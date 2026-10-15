# tree_ssh_plugin

SSH 执行器新架构里的**「中转站」**（`ssh_executor`，**binary 型内置插件**，由核心 spawn 的本机进程）。
2026-10-15 定位重写：中转站 =「处理拓展点位」，本插件**订阅内置点位 `ssh.execute`**，
核心把每次 SSH 操作投成一次 `station/request`（首选路径）；旧的 `tunnel.*` 方法 + `hello.capabilities`
**作为兼容层保留**（只服务订不上点位的旧核心）。它把"核心 ⇄ 目标机"的长链路收成两段：

```
核心 ──L1：站点路径 `station/request`（首选）或旧 `tunnel.*`（兼容）──▶ 本插件 ──一条常驻 SSH exec 通道（L2）──▶ tree_agent（目标机）
```

> 两条 L1 路径共用同一个 `TunnelManager` 台账与同一个 `TunnelSshTransport`，行为/失败分类/回退判据逐条一致。

## 职责（只做这四件事）

> 另有一个**只读的左栏面板**（`activity` 槽位，2026-10-11 加）：看每条隧道现在什么状态，
> 需要时手动「重连」或「关闭」。它是**观察面**不是第五件事——面板不持有任何状态，
> 每次刷新都从隧道台账现读（见「左栏面板」一节）。

1. **bootstrap**：用一次 SSH（`dartssh2`）连上目标机 → `uname -m` 探架构 → 把随包 `tree_agent`
   推送到 `~/.tree/agent/<version>/tree_agent`（`sha256sum` 对账，缺/不一致才推；base64 分块写 `.part`
   → 校验 → `chmod +x` → `mv -f`）→ 以一条 **exec 通道** 拉起它（`<agent> --root <root> --token <token>`）
   → `agent.hello` 握手。
2. **中转**：此后所有操作只走**这一条常驻通道**的 JSON-RPC —— 把核心的 L1 请求转成 L2 请求发给
   `tree_agent`，把响应/通知回传。**SFTP 不参与稳态**（它正是旧模型"服务端拒新通道 ⇒ 整条链路哑掉"的根因）。
3. **重连**：通道断/心跳丢 ⇒ 指数退避重连（重连即**重跑 bootstrap**，所以 agent 版本对账天然完成）；
   退避**累计时长上限 30 分钟**，耗尽 ⇒ 自标 `down`（核心据此回退内置 dartssh2）。
   `ready` 期间**定时 `agent.ping` 保活**（20s / 单次 10s 窗口 / 连丢 3 拍 ⇒ 拆掉重建）——
   "进程还在但不回帧"的卡死也由此换得掉（`tunnel.reconnect` 走同一探针，不再是 no-op）。
4. **双信号上报「有中转站」**：握手后主动 `station/subscribe` 订上 `ssh.execute` 点位（首选判据）；
   同时 `hello` 仍回 `capabilities: ["ssh-executor"]`（兼容判据，只报能力不订点位的旧核心据此走 `tunnel.*`）。
   核心侧两信号 **OR** ⇒ 热切换窗口两种启动顺序都稳定。

**它不做**：不做临终回退（插件崩了就等于"没有中转站"，核心下一次 IO 解析自然走内置 —— 插件不必知道内置存在）；
不做端口转发；不申报工具；不自动重放在途请求。（注：旧文档曾写"执行器是通道不是点位、不订阅任何点位"，
2026-10-15 迁移后已作废：本插件现在**订 `ssh.execute` 中转点位**，与工具改写同构。）

## 内容

| 文件 | 内容 |
|---|---|
| `bin/tree_ssh_executor.dart` | 插件入口：stdin 读帧 → `PluginLoop`；stdout 写帧（每帧 flush）；日志一律 stderr |
| [lib/src/plugin_loop.dart](lib/src/plugin_loop.dart) | **L1 服务端**：`hello` / `ping` / `shutdown` / `tools/list` + 5 个 `tunnel.*`；请求**并发**处理（读循环不 await 业务）；未知方法回 `-32601` |
| [lib/src/tunnel_manager.dart](lib/src/tunnel_manager.dart) | 多隧道台账 `Map<conn_id, Tunnel>`；`tunnel.ensure` 按 `host\|port\|username\|root\|login_shell` **去重**；`tunnel.state` / `reconnect` / `close`；`conn_id` 带**进程内随机前缀**（`conn-<rand4>-<seq>`，防插件重启后序号重来 ⇒ 旧请求打到新隧道） |
| [lib/src/tunnel.dart](lib/src/tunnel.dart) | 单隧道状态机 `connecting → booting → ready ⇄ reconnecting → down`；退避（[Backoff] + 可注入 [TimerFactory]）；在途请求显式收口；PTY 通知转 `tunnel/event`；**失败面分 `tunnel_not_ready` / `tunnel_down`**；保活与卡死强拆；重建前按 token 收上一世 agent |
| [lib/src/keepalive.dart](lib/src/keepalive.dart) | **成组常数**：ping 间隔 20s / 单次窗口 10s / 连丢 3 拍 ⇒ 重建；agent 静默上限 90s（spawn 时总是传给 agent）——改一个必须看另一个 |
| [lib/src/bootstrap.dart](lib/src/bootstrap.dart) | 六步 bootstrap（探架构/推送/chmod/拉起/握手）+ 六种 `error_kind`；`buildSpawnCommand`（含 `--root` 与 `--idle-timeout-ms`）/ `mapArch` / token |
| [lib/src/agent_client.dart](lib/src/agent_client.dart) | **L2 客户端**：请求响应配对、通知外转、坏帧不致哑、通道死 ⇒ 在途全部以 `AgentChannelClosed` 收口 |
| [lib/src/ssh_dialer.dart](lib/src/ssh_dialer.dart) | **可注入**的 SSH 面：`SshConnection` / `SshChannel` / `SshDialer` + dartssh2 实现（`DartSshDialer`） |
| [lib/src/login_shell.dart](lib/src/login_shell.dart) | 登录外壳：三态模板、`bash -lc`→`sh -lc`→原样发、POSIX 单引号转义、一次隧道只探一次 |
| [lib/src/backoff.dart](lib/src/backoff.dart) | 退避节奏 1s→2s→…→60s 封顶；累计上限 30 分钟（**上限是累计等待，不是单次超时**） |
| [lib/src/tunnel_config.dart](lib/src/tunnel_config.dart) | L1 `config` 解析（含 `login_shell` 三态、`agents_dir`）、去重键、`host:port/user` 安全标签 |
| [lib/src/agent_binary.dart](lib/src/agent_binary.dart) | 随包 `tree_agent` 的本机定位（`binary_path` / `TREE_AGENT_BINARY` / **与插件同级的 `agents/`**）与 sha 校验 |
| [lib/src/ui_panel.dart](lib/src/ui_panel.dart) | **左栏面板**（`activity` 槽位）：只读状态 + 两个动作（重连 / 关闭，关闭两段式）；视图只用受限控件集；刷新 300ms 节流 |
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
4. **上报「有中转站」的两信号缺一不可**：`hello.capabilities` 必须含 `ssh-executor`（兼容旧核心的判据），
   握手后还要主动 `station/subscribe` 订上 `ssh.execute`（新核心的首选判据）——核心侧两信号 **OR**，
   只报能力不订点位⇒旧 `tunnel.*` 路仍通，订上点位⇒首选站点投递。
5. **`tunnel.ensure` 的失败面必须分类**（`error_kind`）：`config_incomplete`（本机配置不全，**不回退**）、
   `arch_unsupported` / `handshake_failed`（不可调和 ⇒ 直接 `down`）、`agent_unreachable` / `push_failed` /
   `spawn_failed`（可重试 ⇒ 退避）。**每一步失败都不静默**（每一步都带可读原因）。
6. **在途请求不重放，但两种失败面必须分清**（2026-10-11 修，协议 §10）：
   - 通道**中途**断（`AgentChannelClosed`）⇒ `error_kind: tunnel_down`，文案**不承诺**"未执行"
     （远端有没有执行到我们无从得知）⇒ 核心如实失败、**不重发**；
   - 隧道**还没好**（`connecting` / `booting` / `reconnecting`）⇒ `error_kind: tunnel_not_ready`，
     这意味着**请求根本没转给 agent**（确定未执行）⇒ 核心会**等隧道回来再发一次**（那不是重放）。
   修复前两者都报 `tunnel_down` ⇒ 核心把"重连中"当判死，一次网络抖动就让后台 hook 立刻失败。
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
13. **spawn 必带静默上限**：`buildSpawnCommand` **总是**写 `--idle-timeout-ms 90000`
    （agent 的缺省 0 = 永不只给手工调试用）。理由：物理断网时对端 sshd 收不到 FIN、agent 收不到 EOF，
    它唯一的自救线索就是"这么久没有任何帧进来"；而插件一直在 ping ⇒ **健康链路上永远到不了这个上限**
    （`keepalive_test` 有钉子）。这条是用户 2026-10-11 点名要的"**执行器应该自觉优雅结束**"。
14. **重建前收掉上一世 agent（零误杀）**：`_reapPreviousAgent` 在 dial 之后、bootstrap 之前跑一条
    `/proc/<pid>/cmdline` **必须含该次启动的一次性 token** 的守卫命令才 `kill`；读不到 / 核对不上 ⇒
    **不杀**（只记日志）。为什么不按"同 root 的 agent 都杀"：两台机器连同一主机的同一登录用户同一 root
    是合法场景，那样会互杀。这条是"目标机上执行器不累积"的双保险（主保险是 13 的静默自杀）。
15. **左栏面板只读、且不出现凭据**（2026-10-11 加）：视图的**唯一数据源**是隧道台账
    （`TunnelManager.tunnels` / `Tunnel.stateJson()` / `Tunnel.installPath`）——
    `password` / `key_passphrase` / 握手 token 从来不在那些字段里，面板也不许自己去找它们
    （`tunnel_ui_panel_test` 有一条"视图 JSON 不含凭据"的钉子）。
16. **面板刷新走 `ui/update`，不借 `tunnel/event`**：`tunnel/event` 是核心与插件之间的**内部数据面**
    （核心明确不把它降级成 `plugin_event`），拿它刷面板不会生效；面板状态变化由 `_sendEvent` 就地触发
    `TunnelUiPanel.refresh()`（300ms 节流合并）。面板动作的**判据在 `params['event']` 上**
    （`{"method":"event","params":{"event":"plugin_ui_action"}}`）——写成 `method == 'plugin_ui_action'`
    永远不命中且不报错（`docs/plugin-development.md` §10 常见坑 ⑥，用例里有一条钉子）。

## 与协议文档的补充决定（本插件侧）

1. **版本与二进制由插件自报**（2026-10-11 用户裁决 B，协议 §2/§6/§10.5）：核心**不再声明**
   agent 版本/sha256/二进制名（`TunnelConnectRequest` 里那几个字段已删），因为核心只发 `config`、
   插件读 `request['agent']`——两边从来没对上，声明的值也从来没被用上。
   现在**版本 = 插件编译期注入的 `kAgentVersion`**（`tool/build_ssh_plugin.dart` 用
   `-DkAgentVersion=<pubspec 版本>` 注入，与 `tool/build_agent.dart` 同一规则），
   sha256 由插件本机算；请求里若带 `version` 只用来对账并记一条日志。
   二进制的查找顺序：`agent.binary_path` → 环境变量 `TREE_AGENT_BINARY` → **与插件可执行文件同级的
   `plugins/` 的上一级 + `agents/`**（发行包 = `<应用目录>/agents/`；开发态 = `<仓根>/build/agents/`，
   正是 `tool/build_agent.dart` 的落点）→ 向上找仓根 → cwd 兜底 → `<目录>/assets/`；
   `binary_name` 支持 `{arch}` 占位，缺省 `tree_agent-linux-<arch>`。
   **升版本号必须重跑两个构建脚本**，`tool/package_windows.dart` 出包时会校验产物里的版本串（不一致直接拒绝）。
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

## 左栏面板（`activity` 槽位，2026-10-11 加）

用户原话是"该插件好像没有 UI 面板"——**插件侧原本一行 UI 都没申报**（`hello` 只有能力，没有槽位），
所以界面上完全没有这个执行器的面：只能靠核心日志里的 `[core:tunnel]` 看它在不在干活。
现在补一个**只读 + 两个动作**的左栏面板（前端与核心那套声明式槽位机制本来就有，本轮没改它们）。

- **槽位**：`slot_key = ssh_executor.activity.1`（固定常量：一个插件条目 = 一个进程实例）、
  `slot = activity`（活动栏图标项 + 左栏整页，同一个槽位两处呈现）、`icon = link`、`order = 30`；
  槽位条目**不带** `plugin_id` / `team_id` —— 归属由核心按实例 id 与 `plugins.yaml` 的 `scope.team_id`
  兜底，空归属 = **任何 team 下都可见**（本插件条目 `scope: {}`）。
- **声明一次就够**：`PluginLoop.run()` 起手发一条 `ui/manifest`（带初始视图）；之后靠 `ui/update` 刷新。
  前端后连 / 重连 / 插件比前端先就绪这三种时序由核心的 `PluginUiCache` + 补放兜住
  （`docs/known-issues.md` 记过这条是怎么修的），插件不必自己重发。
- **刷新时机**：`_sendEvent` 收到 `kind: state` 的隧道状态跃迁时 `refresh()`（**300ms 节流合并**，
  连续跃迁只发一帧）；`tunnel.ensure` / `tunnel.reconnect` / `tunnel.close` 三个请求处理后
  `refresh(force: true)`。PTY 的 `shell.data` / `shell.exit` **不刷面板**（与面板无关）。
- **内容**：概览（共几条 / 几条就绪）+ 每条隧道一块（`host:port/user`、`conn_id`、`state`、尝试次数、
  已连秒数、`root`、agent 版本与目标机安装路径、最近一次失败原因）+ 每条的 `[重连]`/`[关闭]` + 底部 `[刷新]`。
  没有隧道时给指路文案（"核心第一次用 SSH 工作空间时会建一条"），不是空白。
- **关闭是两段式**（受限控件集没有确认弹窗）：第一次点只把按钮变成 `[确认关闭]`（`danger`）+ `[取消]`，
  **20s 不用自动过期**回到 `[关闭]`（避免"点一次就走开、回头又点一下"变成误关）；第二次点才真
  `tunnel.close`。面板里写明后果：**在跑的后台任务不受影响**（目标机 `setsid` + 落盘退出码/台账），
  但正在进行的远端前台操作会中断，核心下次用这个工作空间会重建。
- **动作分派**：只看 `action_id`（`refresh` / `reconnect` / `close` / `cancel_close`）+
  `payload['conn_id']`；未知动作 / 缺 `conn_id` 只记日志，**不抛、不崩**。
- **动作结果必须看得见**（2026-10-11 用户真机反馈）：每次动作的**结果 / 失败**都渲染成视图里的一行
  （`lastActionNote`）——"重连未成功：隧道不存在（这条隧道可能已被关闭…）"、
  "已关闭 conn-x。核心仍持有这条连接，会在**下次使用这个工作空间时**判死并重建…"、
  "「确认关闭」已过期"都走它。第一版只把结果写 stderr，界面上什么都看不到 ⇒ 用户会说"点了没反应"。
- **上限**：一次最多列 8 条隧道（超出给一行"还有 N 条未显示"）——核心桥对单槽位视图有 64 KiB 上限。

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
- `tunnel_keepalive_test`：**断连完整性四条**——① 失败面分类（重连中 ⇒ `tunnel_not_ready`，
  判死/已关闭 ⇒ `tunnel_down`，且 `tunnel_not_ready` **不在** `fallbackKinds` 里）；
  ② spawn **总是**带 `--idle-timeout-ms`，且静默上限 > ping 间隔；
  ③ 保活（健康通道永不重建 / 连丢 3 拍 ⇒ 拆掉重建 / `reconnect` 对卡死通道**真的**重建 /
  健康时仍是 no-op）；④ 重建前按一次性 token 收上一世 agent（且**守卫命令形状**没有"无条件 kill"）；
- `plugin_loop_test`：L1 分发（含未知方法 `-32601`）、去重（同 key 复用 `conn_id`）、错误分类、`shutdown`/stdin 关闭退出、
  慢 `ensure` 不堵 `ping`；
- `tunnel_ui_panel_test`：**左栏面板 16 条**——`ui/manifest` 只发一条且槽位/键/空归属正确、视图只用受限控件集、
  无隧道时有指路文案、有隧道时列出 label/state/agent 版本/安装路径/两个按钮、**视图不出现任何凭据**、
  300ms 节流（窗口内合并 / `force` 绕过）、重连（健康通道 no-op / 断了的通道真重建）、
  关闭**两段式**（第一下不真关 / 第二下才关 / 取消 / 20s 过期）、未知动作与缺 `conn_id` 的 fail-open、
  以及 `PluginLoop` 接线三条（起手声明、状态跃迁自动刷、`params['event']` 判据钉子）；
- `executor_process_test`：**真起插件进程**说 L1（stdout 无杂质 / 日志走 stderr / 一次塞多帧也逐条回 / 退出码 0）。

**未覆盖**：真机 SSH（本机没有可连的 sshd，仓库也还没有 `tree_agent` 二进制）。因此
"命令形状"与"状态机"被钉住了，但"真 sshd 上的语义"要靠门控真机测试（后续任务）验证。
