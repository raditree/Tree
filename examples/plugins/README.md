# 示例插件（examples/plugins）

本目录是**插件生态的参考实现**：一份纯标准库的 Python 插件 + 一份可直接粘贴的
`plugins.yaml`。它同时演示四件事：

| 演示 | 站 / 契约 | 在 `sample_plugin.py` 里的落点 |
|---|---|---|
| **收集站**：按站点 schema 申报工具定义，模型因此能调到 `plugin__<插件id>__echo` | `station/request`（收集站 → 插件） | `_handle_station_request` + `tool_definitions` |
| **广播 / 事件订阅**：收 `agent.tool_call`，按 (agent_id, session_id) 计数，**超过阈值就发停止信号** | 事件通知 + 执行站 `agent.stop` | `_on_event` / `_do_stop` |
| **执行站**：插件**主动**下命令（`fs.read` 读工作空间小文件） | `station/command`（插件 → 核心） | `fs_read` / `_do_startup` |
| **插件布局**：推一个 card 槽位帧到前端，显示当前计数与阈值 | `ui.push` → `plugin_ui_update` | `push_card` / `card_view` |

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
    granularity: team             # 实例粒度：team / agent / session（展示口径）
    scope:                        # 站点四元组：**空 = 通配，非空 = 精确匹配**
      team_id: team-1
      mode_key: local             # local | ssh（声明兜底；运行期以目标 agent 的工作面为准）
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
| `granularity` | team / agent / session | 实例粒度（前端展示与订阅身份的默认口径） |
| `scope.team_id` | 字符串 | **作用域上限（插件归属团队）**。为空 = 不限团队、可服务多队（执行站命令按每条命令的 `agent_id` 解析真实归属，见第 6 节） |
| `scope.agent_id` | 字符串，可空 | 声明更细的粒度：只收该 agent 的事件 / 只在该 agent 的工作面下命令 |
| `scope.session_id` | 字符串，可空 | 再细一层（一般留空） |
| `scope.mode_key` | local / ssh，可空 | 工作面声明（缺省 local）；运行期由核心按目标 agent 的 SSH 配置解析 |

**scope 的匹配口径**（事件派发与站点投递一致，不发明新语法）：
`scope` 里某个键**为空即通配**；非空则要求事件的同名字段**精确相等**。
所以 `team_id: team-1` 的插件只收 team-1 的事件；`scope: {}` 的插件收全部事件。

**开关方式**：当前手工改 `plugins.yaml`（改完重启核心生效）。将来可在**前端插件面板
一键开/关**（内置插件与自定义插件同一分组，面板里能看到实例状态与健康度）；
`enabled` 字段就是那个开关的落点，语义不会再变。

---

## 2. 它注册了哪些工具

插件同时用**两条路径**申报工具，两边内容一致：

- **收集站路径**（声明了 `scope.team_id` 时走这条）：核心按站点 schema 发
  `station/request`，插件回 `{reply: {payload: {tools: [...]}}}`；
- **`tools/list` 路径**（没声明 team 的老插件走这条）：回 `{tools: [...]}`。

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
2. **工具表出现该工具**：收集站 `plugin.tool.define@<team>@<mode>` 的计数里
   `requests / responded` 各 +1（说明插件按 schema 申报成功）。随后让模型调用
   `plugin__sample__echo`（例如："请调用 plugin__sample__echo 回显 hi"），
   结果应为 `plugin-echo: hi`；`plugin__sample__rounds` 返回当前统计。
3. **计数卡片更新**：消息流里出现槽位卡片「示例插件 · 工具轮次监视」，含阈值、
   已计数次数、进度条与 (agent, session) 计数表；每 `--card-interval` 秒刷新一次，
   工具调用密集时按 1s 节流刷新。
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

- **单实例 + 每条消息带身份**：`plugins.yaml` 的 `scope` 是作用域**上限**。不声明
  `team_id` 的插件可以服务任意 team —— 但每条 `station/command` 都要带 `agent_id`，
  核心按该 agent 的**真实归属**解析 team / mode，并在选站前做 fail-closed 校验
  （agent 不存在 / 归属解析不出 / 请求里带的 `team_id` 与真实归属不一致 ⇒ `-32001`，
  错误信息里能看到原因）。声明了 `team_id` 的插件仍只能在自己 team 内活动。
- **没声明 `scope.team_id` 的插件不进站点订阅体系**：核心退回 `tools/list` 申报工具
  （工具仍可用），也不收按 team 过滤的事件；但**执行站命令仍可用**（见上一条）。
  不带 `agent_id` 的团队级命令（`ui.push`）需要带 `team_id` 或在声明里给 team。
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
