# 示例插件（examples/plugins）

本目录是**插件生态的参考实现**：一份纯标准库的 Python 插件 + 一份可直接粘贴的
`plugins.yaml`。它同时演示四件事：

| 演示 | 站 / 契约 | 在 `sample_plugin.py` 里的落点 |
|---|---|---|
| **收集站**：按站点 schema 申报工具定义，模型因此能调到 `plugin__<插件id>__echo` | `station/request`（收集站 → 插件） | `_handle_station_request` + `tool_definitions` |
| **广播 / 事件订阅**：收 `agent.tool_call`，按 (agent_id, session_id) 计数，**超过阈值就发停止信号** | 事件通知 + 执行站 `agent.stop` | `_on_event` / `_do_stop` |
| **执行站**：插件**主动**下命令（`fs.read` 读工作空间小文件） | `station/command`（插件 → 核心） | `fs_read` / `_do_startup` |
| **中转站**：订阅后**每次工具调用的前/后各来一次**——核心把完整 tool_call 报文交过来，插件决定改什么（甚至不改） | `station/subscribe` + `station/request`（kind=relay） | `subscribe_station` / `_handle_station_request` 的 relay 分支 |
| **自建站点**（`--self-station`）：插件自己建一个广播站并订阅它。站点全局唯一、**每个点位只有一个订阅者**，所以要按 team / agent 分流时，正解是插件自己建站分发（转发型订阅者） | `station/register` → `station/subscribe`（按 `station_id`） | `register_own_station` / `subscribe_station` |
| **插件布局 A**：声明左侧活动栏面板 + 右栏 Tab（声明式控件集，**不跑 JS**） | `ui/manifest` / `ui/update` 通知 → `plugin_ui_manifest` / `plugin_ui_update` 帧 | `declare_panel` / `update_panel` / `_on_ui_action` |
| **插件布局 B**：推一个 card 槽位帧到前端，显示当前计数与阈值（⚠ `ui.push` 只发 update 帧、**不建槽位**：该 `card` 槽位必须先在 `ui/manifest` 里声明，详见第 8 节） | `ui.push` → `plugin_ui_update` | `push_card` / `card_view` |

> 一句话语义：**核心不设工具轮次上限（Q8），限制交给插件做**——本插件就是那个
> "监视轮次、超限发 `agent.stop`"的参考实现（默认阈值 200 次）。

文件：
- `sample_plugin.py` —— 插件本体（**仅标准库**；协议细节与边界情况都写在文件头注释里）
- `README.md` —— 本文件（怎么配、怎么改阈值、怎么看日志、怎么验证）

---

## 1. 快速开始：plugins.yaml 片段（可直接粘贴）

配置文件位置：**`<数据根>/config/plugins.yaml`**（默认数据根见核心启动日志里的
「数据目录」；本机通常是 `C:\Users\<你>\.tree`）。

```yaml
enabled: true                     # 插件体系总开关
plugins:
  - id: sample                    # 插件 id（工具命名空间 = plugin__sample__<工具名>）
    name: 示例插件（Python）        # 展示名；插件 hello 自报的名字优先
    command: "D:/app/python/python.exe"   # Python 解释器（绝对路径，见第 3 节）
    args:                         # 传给插件的命令行（第 1 个是脚本绝对路径）
      - "E:/programs/Tree/desktop/examples/plugins/sample_plugin.py"
      - "--threshold"             # 阈值（也可用环境变量，见第 4 节）
      - "200"
      - "--agent-id"              # 执行站命令的目标 agent（fs.read 用）
      - "agt_1"
      - "--read-path"             # 要读的工作空间相对路径
      - "notes.txt"
      - "--card-interval"         # 卡片周期刷新秒数
      - "5"
    env:                          # 额外环境变量（与父进程环境合并）
      SAMPLE_PLUGIN_TOOL_ROUND_LIMIT: "200"
    enabled: true                 # 单个插件开关
    granularity: team             # 实例粒度：team / agent / session（订阅时声明的粒度）
    scope:                        # 作用域上限（四元组）：**空键 = 不限定该维度**
      team_id: team-1             # 作用域上限：空 = 作用于所有 team（就不必写这一行）
      mode_key: local             # local | ssh（**一般不用填**：运行期由核心按目标 agent 的工作面解析）
```

字段含义（与 `PluginConfig` 一一对应）：

| 字段 | 取值 | 说明 |
|---|---|---|
| `enabled`（顶层） | true / false | 插件体系总开关；false 时一个插件都不拉起 |
| `id` | 字符串，唯一 | 插件 id。**工具在模型眼里叫 `plugin__<id>__<工具名>`**（如 `plugin__sample__echo`） |
| `name` | 字符串 | 展示名；插件 `hello` 里自报的名字会覆盖它（面板显示自报的那个） |
| `command` | 可执行文件路径 | 启动命令。Python 插件填**解释器绝对路径**（不要写脚本） |
| `args` | 字符串数组 | 启动参数；第 1 项 = 插件脚本的**绝对路径**，其余是插件自己的参数 |
| `env` | 键值表 | 额外环境变量（与父进程环境合并），用于免改 args 调参 |
| `enabled`（单插件） | true / false | 单个插件开关（关掉后不启动、工具下线） |
| `granularity` | team / agent / session | **订阅时声明的粒度**（不再决定站点实例——站点全局各一个） |
| `scope.team_id` | 字符串 | **作用域上限**。**空 = 作用于所有 team**（订阅与事件都收全部 team；执行站命令按每条命令的 `agent_id` 解析真实归属，见第 6 节）。想只服务一个 team 就填它 |
| `scope.agent_id` | 字符串，可空 | 声明更细的粒度：只收该 agent 的事件 / 只在该 agent 的工作面下命令 |
| `scope.session_id` | 字符串，可空 | 再细一层（一般留空） |
| `scope.mode_key` | local / ssh，可空 | **空 = local 与 ssh 都收**（订阅侧）；填了就必须与真实值一致，冲突时报错。命令的 mode 一律由核心按目标 agent 的工作空间解析（声明只作上限校验），所以一般留空 |

**scope 的匹配口径**（事件派发与站点投递一致，不发明新语法）：
`scope` 里某个键**为空 = 不限定该维度**（不是"匹配空值"，而是"这一维不设条件"）；
非空则要求事件的同名字段**精确相等**。所以 `team_id: team-1` 的插件只收 team-1
的事件；`scope: {}` 的插件收全部 team 的事件与消息（**作用于所有 team**）。

**空字段的两套语义（最容易混的一点）**：

| 方向 | 空 team / 空 mode 的含义 |
|---|---|
| **订阅声明**（`plugins.yaml` 的 scope、`station/subscribe` 的 scope） | **不设条件（通配）**：空 team = 所有 team，空 mode = local / ssh 都收 |
| **消息信封**（中转 / 广播 / 收集的数据面） | **不可证明归属 ⇒ 拒绝投递**（fail-closed） |
| **执行站命令**（`fs.*` / `terminal.exec` / `agent.*`） | 挂载位置仍 fail-closed：必须能解析出目标 agent 的 team 与工作面，否则拒绝执行 |
| **前端推送**（`ui.push`） | 空 team 合法 = 推给**所有 team**（帧的 `team_id` 为空，前端在任何 team 下都呈现） |

### ⚠ 历史坑（已修）：没有 team 的机器上，订阅站点会失败

旧版核心要求"订阅站点必须声明 team"，于是 `scope: {}`（= 界面开关内置插件写出的默认
形态）会得到：

```
插件 sample 订阅站点缺少 team：请在请求里带 scope.team_id，
或在 plugins.yaml 声明 scope.team_id（站点隔离要求四元组，fail-closed）
```

**现在的口径（用户定稿）**：**为空默认作用于所有 team**——空 scope 是合法订阅声明，
落成一条四维全通配的订阅（`team_id` / `mode_key` 都为空），中转站 / 收集站 / 广播站
一律订得上，计数卡片也推得出去。所以：

- **不需要**为了订阅去声明 `scope.team_id`（想只服务某个 team 时才填）；
- 顶层 agent（`agents/<id>.yaml` 的 `team_id` 为空，自成一队）也不用做任何特殊处理；
- 反过来，**填了 `team_id` 就是作用域上限**：只收该 team 的事件与消息，跨 team 一律
  拒绝（声明不得被放大）。

**没声明 `scope.team_id` 时会发生什么**（= 界面开关内置插件后的默认形态）：
**什么都不会被拒**——空 scope 是一条四维全通配的合法声明，启动时就能订上中转站、
推得出卡片、参与收集站申报：

| 能力 | 空 scope（`{}`）下的行为 |
|---|---|
| `station/subscribe`（中转站） | 订上（通配订阅：所有 team 的工具调用前后各一次） |
| `ui.push`（计数卡片） | 推得出（帧的 `team_id` 为空 ⇒ 前端在**任何 team** 下都呈现） |
| 收集站申报（`plugin.tool.define`） | 挂上收集站；有调用点团队上下文时按站点申报，否则工具走 `tools/list` 路径（两条路径产出同一张定义表） |
| `agent.tool_call` 计数 | 一直正常（与 team 声明无关） |

示例插件另有一层**防御性兜底**（对旧核心 / 被拒的订阅仍有效）：启动时订中转站失败就
`_relay_lazy_pending`，等第一个事件给出 `agent_id` 后在 worker 线程按身份补订，`ui.push`
也带上该身份。新核心里这条路径不会被触发——**空 scope 启动即成立**。

**开关方式**（已经做好了，不必手改文件）：前端**插件面板**里每个插件（内置与自定义
同一分组）各有自己的开关，改完立即热应用、失败时重启核心生效；面板同时显示实例状态
与心跳健康度。`plugins.yaml` 的 `enabled` 就是那个开关的落点，也可以直接手改文件。

---

## 2. 它注册了哪些工具

插件同时用**两条路径**申报工具，两边内容一致：

- **收集站路径**（有调用点团队上下文时走这条）：核心按站点 schema 发
  `station/request`，插件回 `{reply: {payload: {tools: [...]}}}`；
- **`tools/list` 路径**（插件上线时的即时申报，任何 scope 都走一遍）：回
  `{tools: [...]}`。

申报的三个工具（模型看到的名字带 `plugin__sample__` 前缀）：

| 工具 | 入参 | 作用 |
|---|---|---|
| `echo` | `{text}` | 回显：`plugin-echo: <text>`（最小可用工具） |
| `rounds` | `{}` | 返回 JSON：阈值、已计数次数、已发停止次数、最近一次工具耗时、各 (agent,session) 计数 |
| `read_probe` | `{path?}` | 现场演示"插件主动下命令"：经执行站 `fs.read` 读一个文件并回显前几行 |

---

## 3. Python 解释器路径怎么填

`command` 填**解释器**，脚本放 `args[0]`（与 MCP 的"本机直跑"风格一致）：

```powershell
# 找到本机 Python 的绝对路径（推荐绝对路径；避免 PATH 里的 Microsoft Store 别名）
where.exe python
# 例：D:\app\python\python.exe
```

- 要求 **Python 3.8+**，**只用标准库**（无需 pip 安装任何东西）；
- 路径里的反斜杠在 YAML 双引号里要写正斜杠（`D:/app/python/python.exe`）或转义
  （`"D:\\app\\python\\python.exe"`）；
- 写相对命令（如 `python`）也行，但依赖核心进程的 PATH 与工作目录，不推荐；
- 用 `.cmd` / `.bat` 包装脚本时，核心会自动加 shell（`runInShell`）。

**脚本可以被绝对路径启动**：`sample_plugin.py` 不依赖 cwd、不做相对导入，任何工作
目录下都能跑（打包发行时 `examples/plugins/` 会被整体复制到发行目录的
`plugins/`，届时把 `args[0]` 指向那份副本即可）。

---

## 4. 阈值怎么改

命令行参数与环境变量**等价**，命令行优先：

| 参数 | 环境变量 | 默认 | 说明 |
|---|---|---|---|
| `--threshold N` | `SAMPLE_PLUGIN_TOOL_ROUND_LIMIT` | `200` | **(agent, session) 的工具调用次数超过 N 次**即发 `agent.stop` |
| `--agent-id ID` | `SAMPLE_PLUGIN_AGENT_ID` | 空 | 执行站命令的目标 agent（空则用事件里见过的第一个 agent） |
| `--read-path PATH` | `SAMPLE_PLUGIN_READ_PATH` | `README.md` | 启动自检要读的**工作空间相对路径** |
| `--team-id TEAM` | `SAMPLE_PLUGIN_TEAM_ID` | 空 | **仅用于日志/卡片文案**；执行站命令的作用域按每条命令的 `agent_id` 解析 |
| `--slot-key KEY` | `SAMPLE_PLUGIN_SLOT_KEY` | `sample.card.tool_rounds` | 前端卡片槽位键（全局唯一） |
| `--card-interval SEC` | `SAMPLE_PLUGIN_CARD_INTERVAL` | `5` | 卡片周期刷新秒数（有事件时另按 1s 节流刷新） |
| `--stop-cascade` | `SAMPLE_PLUGIN_STOP_CASCADE=1` | 关 | `agent.stop` 是否级联停整棵团队树（默认只停该 agent 的当前生成） |
| `--no-relay` | — | **默认订阅** | 不订阅中转站。默认订阅后，**每次工具调用的前/后各来一次** `station/request`（kind=relay）；本插件 pre 阶段给参数加 `_relay_seen` 标记、post 阶段给结果追加一行统计（演示"改不改由插件决定"）。空 scope 下启动即订上（通配）；只有当核心**拒绝**这次订阅时（旧核心 / 被占用），才推迟到第一个事件之后按 `agent_id` 补订 |
| `--no-panel` | — | **默认声明** | 不声明插件面板槽位。默认会发 `ui/manifest` 声明一个 **activity**（左侧活动栏面板）与一个 **panel**（右栏 Tab）槽位；按钮 `refresh` / `push_card` 经 `plugin_ui_action` 回到 `_on_ui_action` |
| `--no-fs-demo` | — | 关 | 不做启动时的 `fs.read` 自检 |

快速试验建议把阈值压到 **3**：`args: [..., "--threshold", "3"]`，这样几次工具调用就能
看到停止链路。

**触发后的行为**：发一次 `agent.stop` → **该 (agent, session) 计数清零** → 打一条
可见日志（`⚠ 工具轮次超限 … 计数已重置`）。清零是为了避免"每一次后续调用都再发一次
停止信号"（反复停）。

---

## 5. 日志在哪

插件的 stdout 是**协议通道**（只走 JSON-RPC 一帧一行），所以：

1. **stderr = 插件日志**：核心把插件进程的 stderr 收进宿主（`PluginHost.stderrTail`，
   排障用；当前**不落盘、也不进前端**）。想看实时日志，可以临时把 `command` 换成
   包装脚本（`python ... 2>> plugin.log`）。
2. **`log` 通知 = 前端可见**：插件另把关键结论用无 id 的 `log` 通知发回核心，核心
   转成 `plugin_event` WS 帧（插件面板/事件流可见）。本插件只在**关键节点**发通知
   （就绪、超限、`agent.stop` 结论、`fs.read` 结果、卡片推送失败），不会刷屏。
3. **卡片槽位**：消息流里的 card 卡片本身就是"它在工作"的可见证据。

---

## 6. 怎么验证（人工步骤）

前置：核心已按第 1 节配好 `plugins.yaml` 并**重启**；核心侧需已把 agent 事件接到
插件总线上（主控在 `core_server` 里的一行接线：
`conversation.agentEvents.sink = pluginBus.dispatchAgentEvent;`）——没接的话第 4 步收不到
`agent.tool_call`，其余步骤照常。

1. **面板出现实例**：打开前端插件面板（或 `GET /api/plugin/snapshot`，带
   `Authorization: Bearer <token>`），`instances` 里应有
   `plugin_id=sample / status=registered / health=ok`，名字是插件自报的
   "示例插件（Python）"。心跳由核心 `ping` 驱动，本插件固定回 `{ok: true}`。
2. **工具表出现该工具**：收集站 `plugin.tool.define`（**全局唯一**，不再带
   `@<team>@<mode>` 后缀；团队归属看 `subscribers_by_team`）的计数里
   `requests / responded` 各 +1（说明插件按 schema 申报成功）。随后让模型调用
   `plugin__sample__echo`（例如："请调用 plugin__sample__echo 回显 hi"），
   结果应为 `plugin-echo: hi`；`plugin__sample__rounds` 返回当前统计。
3. **计数卡片更新**：消息流里出现槽位卡片「示例插件 · 工具轮次监视」，含阈值、
   已计数次数、进度条与 (agent, session) 计数表；每 `--card-interval` 秒刷新一次，
   工具调用密集时按 1s 节流刷新。左栏活动面板与右栏 Tab 同步刷新（三处数据同源）。
   ⚠ 卡片槽位（`--slot-key`，默认 `sample.card.tool_rounds`）**必须先在
   `ui/manifest` 里申报**：`ui.push` 只发 update 帧、不建槽位，没申报过的 slot_key
   会被前端静默忽略——卡片永远不出现，且**没有任何报错**（第 8 节）。
4. **超阈值后被停止**：把阈值改成 3（第 4 节），让 agent 连续做几次工具调用：
   - 插件 stderr：`⚠ 工具轮次超限：agent=… session=… 本任务已调用 4 次 > 阈值 3 ⇒
     经执行站发 agent.stop，计数已重置`；
   - 前端 `plugin_event`：同一条 `log` 通知，以及
     `agent.stop（第 1 次）：ok=True mount_id=core.execute.agent.stop`；
   - 会话里出现「已停止本轮生成。」，该 agent 回到 idle。
5. **执行站演示**：启动日志里有
   `fs.read 成功（启动自检）：agent=… path=notes.txt total_lines=…`；失败时会给出
   **可读原因**（例如 agent 不存在 / 跨 team / 工作空间未接线），绝不静默。

### 离线自测（不依赖核心，30 秒）

想确认脚本本身没坏，可以直接喂它一行 `hello`，看 stdout 是否只有 JSON-RPC、
日志是否只在 stderr（把这条 `hello` 写进文件再用 `type` 管道喂进去，**不要**用
PowerShell 的字符串管道——PS 5.1 会带 BOM，插件会把那一行判成"非 JSON 行"跳过）：

```powershell
Set-Content -Path "$env:TEMP\hello.jsonl" -Encoding ascii `
  -Value '{"jsonrpc":"2.0","id":1,"method":"hello","params":{"plugin_id":"sample"}}'
cmd /c "type %TEMP%\hello.jsonl | D:\app\python\python.exe E:\programs\Tree\desktop\examples\plugins\sample_plugin.py"
```

预期输出（stdout 只有这一行；启动日志、`fs.read` 失败原因等全在 stderr）：

```json
{"jsonrpc": "2.0", "id": 1, "result": {"plugin_id": "sample", "name": "示例插件（Python）", "capabilities": ["tools", "events", "stations"]}}
```

---

## 7. 注意事项（都是踩过的坑）

- **单实例 + 每条消息带身份**：`plugins.yaml` 的 `scope` 是作用域**上限**。空 scope
  的插件可服务任意 team（= 作用于所有 team），但每条 `station/command` 都要带
  `agent_id`，核心按该 agent 的**真实归属**解析 team / mode，并在选站前做 fail-closed
  校验（agent 不存在 / 归属解析不出 / 请求里带的 `team_id` 与真实归属不一致 ⇒ `-32001`，
  错误信息里能看到原因）。声明了 `team_id` 的插件只能在自己 team 内活动。
- **空 scope = 通配（作用于所有 team）**：`station/subscribe` 不再要求声明 team——
  空 team 收所有 team 的消息、空 `mode_key` 收 local 与 ssh；`ui.push` 的帧带空
  `team_id`，前端在任何 team 下都呈现。**只有消息信封**（中转 / 广播 / 收集的数据面）
  和**执行类命令的落地**（`fs.*` / `terminal.exec` / `agent.*` 解析不出目标 agent 的
  team 与工作面）仍然 fail-closed。
- **stdout 只允许 JSON-RPC**：日志走 stderr；本插件把 stdout/stderr 都按 UTF-8 字节
  写，避免 Windows 上 Python 默认 ANSI 代码页（cp936）把中文写成非法 UTF-8。
- **插件主动请求必须带 `method` + `id`**：核心按"有没有 method"区分「响应」与
  「请求」；通知（无 id）会被转成前端 `plugin_event`。
- **`station/request` 回包形状**：`{reply: {payload: {...}}}`；不要回带 `scope`
  （回带了就必须与请求四元组精确相等，否则整条回包被判跨 scope 拒绝）。
- **收集站 schema 是严格校验**：payload 根对象只允许 schema 声明的键（工具定义列表
  放在唯一的 `tools` 键下）。
- **插件里不要在读循环内同步等核心回包**：`sample_plugin.py` 把每个入站请求放到
  独立线程处理，并用后台 worker 发 `station/command`，就是为了避免"等回包时读循环
  被占住"的死锁（Dart 版假插件靠单线程事件循环天然避开这一点）。
- **核心对插件请求没有静态超时**（plan §1.1：判活靠心跳）：插件不该自己给"任务总
  时长"设上限；本示例里那个 30s 只是让日志别永久挂住的兜底。
- **核心退出时插件自行退出**：核心关闭会关掉插件的 stdin，脚本读到 EOF 即退出
  （不用额外的关闭协议；`shutdown` 通知也会退出）。

---

## 8. 协议速查（RPC 与站点）

插件与核心之间只有 **stdio JSON-RPC 一帧一行**（`stdout` 是协议通道，日志走 `stderr`）。
按"有没有 `id`"区分**请求/响应**与**通知**：通知（无 `id`）被转成前端 `plugin_event`，
`ui/manifest` / `ui/update` 两个约定 method 例外（见下）。

### 核心 → 插件（请求，插件必须**且只能**回一条响应）

| method | 入参 | 回参 |
|---|---|---|
| `hello` | `{plugin_id, ...}` | `{plugin_id, name, capabilities}`（`capabilities` 例：`["tools","events","stations"]`） |
| `tools/list` | — | `{tools: [{name, description, parameters, ...}]}`（未声明 team 的插件走这条） |
| `tools/call` | `{name, arguments, agent_id?, session_id?}` | 工具结果；`agent_id` / `session_id` 是**调用点身份**，单实例插件据此做归属判断 |
| `station/request` | 见下 | `{reply: {payload: {...}}}` |
| `ping` | — | 任意合法响应（核心只判"这一拍有没有回"，不看内容）——插件连续多拍不回会被标 `degraded`，**不是停用** |

`station/request` 的两种用途（同一个 method，按 `kind` 分）：

- **收集站**（`kind=collect`）：核心按站点 schema 发请求，插件回**工具定义清单**。
  收集站 `plugin.tool.define` 的 schema 形状 = `{tools: [{tool_name, description,
  parameters, execution}, ...]}`（payload 根对象只允许 schema 声明的键）——一次申报
  自己的全部工具，**每条**都覆盖「名称 / 描述 / 参数 schema / 执行方式」四项；
- **中转站**（`kind=relay`）：**每次工具调用前/后各一次**，核心把完整 tool_call
  报文交过来，插件**决定改什么、或什么都不改**——回填支持 string / 对象 / 数组
  （整体替换）；不接 / 无订阅者 / 不回 / 回包非法一律 **fail-open 放行原始报文**。

### 插件 → 核心（请求，五个方法）

| method | 入参 | 回参 |
|---|---|---|
| `station/command` | `{command, arguments, team_id?, agent_id?, session_id?}` | `{ok, ...}` 或 `{ok: false, error}` |
| `station/subscribe` | `{station: relay\|broadcast \| station_id, scope?, replace?}` | `{ok, station_id, kind, scope, replaced, error}` |
| `station/unsubscribe` | `{station \| station_id}` | `{ok, station_id, kind, removed, error}` |
| `station/register` | `{kind, name, schema?, description?, max_subscriptions?}` | `{ok, station_id, kind, error}` |
| `station/unregister` | `{station_id}` 或 `{kind, name}` | `{ok, station_id, removed_subscriptions, error, notice?}` |

**业务规则拒绝是"结果"不是"协议错误"**：站点被占 / schema 为空 / 越权注销一律回
`ok: false` + 可读 `error`（插件必须能读懂）；只有参数形状错才抛 JSON-RPC 错误。

执行站首命令集（`station/command` 的 `command` 取值，白名单）：

| command | 作用 |
|---|---|
| `fs.read` / `fs.write` / `fs.list` / `fs.grep` | 在目标 agent 的工作空间里操作文件 |
| `terminal.exec` | 跑一条命令（软超时走 hook，不是静态超时） |
| `agent.message` / `agent.stop` / `agent.compact` | 给 agent 发消息 / 停当前生成 / 触发压缩 |
| `ui.push` | 推一个 **card** 槽位帧到前端（`{slot_key, view}`；`view` 为 null = 注销） |

### 自建站点（`station/register`）的四条硬规则

1. **id 由核心拼**：`plugin.<你的插件id>.<kind>.<name>`——插件不能自选 id，
   "我的站点只能是我的"靠这个前缀结构性保证（越权注销会被拒）；
2. **`name` 只允许 `[A-Za-z0-9_-]`**：`.` 会让归属前缀产生歧义（插件 `a` 建
   `b.relay.x` 就能顶掉插件 `a.b` 的站点）；
3. **执行站不能自建**（它由插件主动下命令，没有订阅消费方）；**收集站必须带非空
   `schema`**（输入格式由站点定义）；
4. **同名重复注册 = 幂等回既有站点**（插件重启后会再注册一遍，不能报错、更不能覆盖
   已积累的订阅与计数）；**插件下线不会自动注销自建站**——站点是持久化资源，
   不想要了要显式 `station/unregister`。

### 站点体系的四条语义（M9 §3）

- **四类站：广播 / 执行 / 中转 / 收集**，每类**全局只有一个实例**（不再按 team /
  mode 复制），id 是类型常量：`system.broadcast` / `system.execute` /
  `system.relay` / `plugin.tool.define`；
- **team / agent / session / mode 是"每次交互携带的信封"**，不是站点维度：单实例
  插件在每条消息上带身份，核心按目标 agent 的真实归属解析并做 fail-closed 校验；
- **每个点位只能有一个订阅者**（中转站尤其）：先到先得，接管要显式 `replace: true`。
  要按 team / agent 分开处理，正解是**自己建站再分发**（转发型订阅者）——见
  `--self-station` 的演示；
- **收集站由核心代订阅**：装了插件就刷新工具表，插件不自己订收集站。

### 插件面板（Q12 声明式布局）

**不做 webview / 不执行插件 JS**：视图只能是受限控件集的 JSON（`text` / `list` /
`table` / `form` / `progress` / `actions` 与 `row` / `column` 容器），未知控件前端
渲染成「不支持的控件」占位。

| 通知 method | 转成的 WS 帧 | 语义 |
|---|---|---|
| `ui/manifest` | `plugin_ui_manifest` | **完整声明**该插件的全部槽位（`[{slot_key, slot, title?, icon?, order?, view}]`；`slot` ∈ `activity` / `panel` / `status` / `card`） |
| `ui/update` | `plugin_ui_update` | 按 `slot_key` **整块替换**某槽位视图（`view: null` = 注销） |

- `plugin_id` / `team_id` **一律由核心按实例与 `plugins.yaml` 声明填充**，插件自述的
  这两个字段不被采信（防越权）；槽位数（默认 16）与单槽位视图体积（64KB）有上限，
  非法声明**整帧拒绝**并记可读原因；
- **槽位的 `team_id` 为空 = 不限定归属**（任何 team 下都呈现），非空 = 只呈现给该 team；
- **`ui.push` 只发 update 帧、不创建槽位**：前端只在 `ui/manifest` 里建立槽位，
  对不存在的槽位 `applyUpdate` 会**故意忽略**（防越权旁路）。所以想推 card 卡片，
  必须先在 `ui/manifest` 里声明那个 `card` 槽位；
- **面板补发**：声明只在插件启动时发一次，所以核心会缓存每个插件最后一个生效的
  UI 帧，前端刷新 / 重连 / 启动晚于插件时由核心**只补发给那条新连接**——插件不需要
  （也不应该）用定时器反复重发声明。

