# 执行站契约：命令表 · 回包信封 · 错误码 · 幂等（L-25）

> **状态**：2026-10-31 建立。§1~§3 是**现状逐字对照**（已全部读源码核实，未凭记忆补字段）；
> §4 是**已拍板的目标口径**（回包新增 `code` 字段）；§5~§7 是门禁设计、落地切法与待拍板项。
> 本文只覆盖**执行站**（`station/command` 这条路）。中转站/订阅面见
> [ssh-tunnel-protocol.md](ssh-tunnel-protocol.md)，写插件的通用协议面见
> [plugin-development.md](plugin-development.md)。
> **快照口径**：桌面仓 `c191e76`、插件仓 `85fa4f6` 的工作树。此后行号会漂，
> 定位以「文件 + 符号名」为准，行号只作辅助。
> **数据源**：`packages/tree_core/lib/src/plugin/{plugin_bus,station_instance,station_runtime}.dart`
> 与 `plugins/{local_executor,ssh_executor,tree.agent,files,_kit}` 的实际实现。

---

## 0. 先说结论

1. **执行站的回包信封从来没有在 `tree_protocol` 登记过**。`station/command` 的
   `{command, ok, mount_id, payload, error}` 五键是散在核心两侧的字面量，
   插件侧靠抄形状活着。这是不变量 7（协议常量只从 `tree_protocol` 取）在站点这一层的漏网之鱼。
2. **失败只有中文原因，没有机器码**。今天唯一的"错误码" `ssh_lease_unknown`
   是把码**拼在 message 前缀里**，消费方用 `'$error'.contains(...)` 判定
   （§3）。三个包各抄一份字面量，没有任何门禁保证它们说的是同一个词。
3. **两个执行站的命令表不等价**：本机 8 条、SSH 10 条，且 `details` / `append` /
   `rename` / 分块读四个能力只在 SSH 侧有（§2）。调用方 `tree.agent` 的窄接口
   `StationWorkspace`（`plugins/tree.agent/lib/src/workspace/station_command.dart:12-28`）
   只按**本机那一套**的能力形状定义，所以 SSH 的四个增强**目前用不上**——
   这不是 bug，但必须写明，否则下一个改 `file.list` 的人会把 `details` 当通用字段。
4. **租约有两套并行系统**，键名不同：核心侧 `lease_id` / `workspace_id`
   （由 `workspace/register` 通知登记）与插件侧 `ssh_lease_id`
   （由执行站命令 `ssh.lease.register` 登记）。混用一律 fail-closed（§1.3 前两行）。
5. **点位表里躺着 20 条"申报了、路由得到、执行必失败"的内置命令**，而且
   **有随包插件正踩在上面**：`compact` 的四条命令名（`llm.call` / `fs.read` /
   `tool.call` / `agent.compact`，`plugins/compact/compact_plugin.dart:62-65`）
   全部属于这 20 条，A5 之后每一条都只能拿到那句"已不在核心平台面"（§2.4）。
   这条比文档漂移严重，是 L-25 之外新发现的**功能回归**，需单独拍板（§7 Q-5）。
6. 目标（已拍板）：**信封新增第 6 键 `code`**，码表进 `tree_protocol` 单一来源，
   插件异常类带码，消费方按码分支。§4 给线格式与逐命令的幂等标注，§5 给门禁。

---

## 1. 回包信封现状

### 1.1 核心 → 插件（`station/command` 的应答）

形状在两条出口各写一遍（**同一个契约，两处字面量**）：

| 出口 | 位置 | 键 |
| --- | --- | --- |
| 租约命令直送执行器 | `plugin_bus.dart:5134-5140` | `command` / `ok` / `mount_id` / `payload` / `error` |
| 一般命令 | `plugin_bus.dart:5149-5155` | 同上，注释写着「结果原样回给插件（ok / payload / error 三件套）」 |

RPC 层错误**不走这个信封**：`command` 缺失、`arguments` 不是对象 ⇒
`PluginRequestException(PluginRpcErrorCode.invalidParams)`（`plugin_bus.dart:5040-5052`），
即 JSON-RPC 的 `error` 帧。调用方 `PluginChannel.command` 只看 `ok` / `error`
（`plugins/_kit/plugin_kit.dart:363-375`）。

### 1.2 内部三段（核心自己的类型，都只有 error、没有码）

| 类型 | 位置 | 字段 |
| --- | --- | --- |
| `StationReply` | `station_runtime.dart:176-206` | `payload` / `error` / `reason`；`fromJson` 宽容解析 `{ok,payload}` / `{error}` / 可选 `reason` |
| `StationCommandOutcome` | `station_runtime.dart:372-394` | `payload` / `error`；`.failed` / `.failedWith`（失败也带载荷，见 known-issues #31） |
| `StationCommandResult` | `station_runtime.dart:397-427` | `command` / `ok` / `mountId` / `payload` / `error` |

### 1.3 失败来源全清单（这就是 §4.2 码表要覆盖的面）

| # | 来源 | 位置 | 现在的原因文案（逐字节选） |
| --- | --- | --- | --- |
| 1 | 租约未登记 | `plugin_bus.dart:5076-5084` | `工作空间租约 X 未登记（先发 workspace/register，再下带 lease_id 的命令）` |
| 2 | 租约跨插件使用 | `plugin_bus.dart:5087-5095` | `工作空间租约 X 属于插件 P，不能跨插件使用（fail-closed）` |
| 3 | 未知命令 | `plugin_bus.dart:5118-5124` | `未知命令 C（可用命令：…）` |
| 4 | 站点被停用 | `station_instance.dart:991-995` | 站点自己的 `stationDisabledReason` |
| 5 | 隔离判定拒绝 | `station_instance.dart:998-1005` | `命令被拒（隔离）：…` |
| 6 | 命令不属于该点位 | `station_instance.dart:1006-1014` | `命令 C 不属于点位 X（本点位允许：…）` |
| 7 | 没有挂载位置 | `station_instance.dart:1023-1032` | `命令 C 暂无挂载位置（没有执行器接管…）` |
| 8 | 挂载插件未运行 | `plugin_bus.dart:2682-2685` | `插件 P 未运行，命令未执行` |
| 9 | 插件回了 error | `plugin_bus.dart:2713-2718` | 插件原文；没给原因 ⇒ `执行器插件 P 报失败但未给原因` |
| 10 | 插件回包非法 | `plugin_bus.dart:2704-2709` | `执行器插件 P 的回包缺少 payload 对象（command=C）` |
| 11 | 挂载 handler 抛异常 | `station_instance.dart:1070-1078` | `挂载位置 M 执行异常：…` |
| 12 | 执行器内部失败 | 插件侧（§3.1） | `ExecutorError` / `SshStationError` 的 message 原文 |

> 1/2/3 是**核心**产生的，9/12 是**插件**产生的，4~8/10/11 是**站点层**产生的。
> 目标码表必须三分（§4.2），因为"谁的错"决定调用方该重试、该重登记、还是该放弃。

---

## 2. 命令表逐条对照

### 2.1 声明面（`station/register` 的 `commands`）

| 本机 `local` | 申报处 | SSH `ssh_workspace` | 申报处 |
| --- | --- | --- | --- |
| `file.read` `file.write` `file.list` `file.grep` `file.delete` `file.mkdir` `file.writeBytes` `exec.command` | `plugins/local_executor/local_executor_plugin.dart:20-29`（8 条） | `ssh.lease.register` `ssh.file.read` `ssh.file.write` `ssh.file.list` `ssh.file.grep` `ssh.file.delete` `ssh.file.mkdir` `ssh.file.writeBytes` `ssh.file.rename` `ssh.exec.command` | `plugins/ssh_executor/lib/src/exec_station.dart:14-34`（10 条） |

**命令名必须带族前缀**的理由是硬的，写在 ssh 侧的申报注释里
（`exec_station.dart:16-22`）：核心 `station/command` **只按命令名全局查执行站**
（`StationPoints.ownerOfCommand`），同名会被核心以"已被其它插件执行站占用"拒绝
（`plugin_bus.dart:4176`）。所以不存在"两个执行站提供同名 `file.read`"这种形态。

**8 个旧名不是别名，是另一条死路**：本机执行器同时接受 `fs.read` / … / `fs.writeBytes`
与 `terminal.exec`（`plugins/local_executor/lib/src/executor.dart:27-50`）。
但它们**不是"没申报"**——恰恰相反，这 8 个名字都在核心的**内置点位表**里
（§2.4）。`_handleStationCommand` 的查表**先查内置点位**（`plugin_bus.dart:5101`），
`fs.read` 当场命中内置 fs 点位，拿到的是核心那个死挂载位置的回复
「命令 fs.read 已不在核心平台面…」，**根本走不到本机执行器**。
所以旧名今天只有一处真在用：本机执行器自己的 `--selftest`
（`local_executor_plugin.dart:266-336`，进程内直接 `executor.execute('fs.write', …)`，
不经核心路由）。口径：**外部调用方一律用申报名（`file.*` / `exec.command`）**；
旧名要么随 §2.4 一起处理，要么留着只服务自检——但**不能把它写成"历史兼容"**，
它一条也不兼容。

### 2.2 形状差异（同族命令，两侧不同）

| 能力 | 本机 | SSH | 出处 |
| --- | --- | --- | --- |
| `file.list` 返回 `details`（含 size/mtime 等结构化条目） | **无**：只回 `path` / `root` / `entries` / `count` / `truncated` | 有 `details` | `executor.dart:165-171` ↔ `exec_station.dart:540-567` |
| `file.writeBytes` 的 `append` | **无**（总是覆盖写） | 有：`append:true` = 分块写的后续块 | `executor.dart:206-228` ↔ `exec_station.dart:465-480` |
| `file.rename` | **无此命令** | 有（原子改名：源不存在 / 目标已存在都显式报错，绝不覆盖） | `kExecutorCommands` ↔ `exec_station.dart:196-197,487-494` |
| `file.read` 分块下载通道 `raw:true`（`base64`/`offset`/`size`/`eof`） | **无** | 有 | `executor.dart:84-119` ↔ `exec_station.dart:325-341` |
| 非 UTF-8 内容读取 ⇒ **内联 `base64`** | 有 | 有 | `executor.dart:92-98,117` ↔ `exec_station.dart:346-351,373` |
| 租约登记 | 走**核心**的 `workspace/register` 通知（`plugin_bus.dart:5067-5099`） | 走**执行站命令** `ssh.lease.register`（`exec_station.dart:180-181`） | 两套并行，键名不同 |

> 最后一行是本表里唯一"看着像差异、其实是两套系统"的项：本机命令带
> `lease_id` / `workspace_id` 由**核心**注入 `root`；SSH 命令带 `ssh_lease_id`
> 由**插件**自己查表（`exec_station.dart:282`）。给 SSH 命令塞 `lease_id`
> 会被核心按"租约未登记"拒（§1.3 第 1 行），反之亦然。
>
> 「非 UTF-8 一律内联 base64」与交接文档 §8 的硬约束（大文件只能走
> `body_path` / `result_path`）之间有张力：小二进制没事，整份二进制读走内联
> 就是把载荷塞进 JSON。**已列为待拍板**（§7 Q-3），本表只登记现状。

### 2.3 命名与文案不一致（用户看得见的那一层）

| 项 | 现状 | 出处 |
| --- | --- | --- |
| 本机错误文案用**旧前缀** | `fs.writeBytes 需要 base64…` / `fs.writeBytes 的 base64 非法` / `terminal.exec 需要 command` | `executor.dart:213,219,330` |
| SSH 错误文案用**申报名** | `ssh.file.writeBytes 需要 base64…` | `exec_station.dart:456,462` |
| 本机 `file.writeBytes` 的越界原因 | `缺少 path（工作空间内相对路径）` —— 与 `file.read` 共用同一条 | `executor.dart:70,208-209` |

影响：用户按 `/api/meta` 里的申报名（`file.writeBytes`）去搜原因里的
`fs.writeBytes`，搜不到。**这是纯文案债，改起来零风险**（§6 片 3）。

### 2.4 内置点位表里躺着 20 条**必然失败**的命令（本文件最大的发现）

A5（2026-10-25）起核心不再实现任何领域执行语义——这条口径写在
`execute_mounts.dart:40-49` 的类注释里，实现也照它做了：
`_handle` 只处理 `plugin.*` 与 `station.*` 两族，其余一律回
`命令 X 已不在核心平台面（A5 起由 local_executor / ssh_executor / tree.agent 等插件自建执行站承接）`
（`execute_mounts.dart:115-119`）。

**但点位申报表没跟着收**：`StationPoints.executes` 仍然申报着这些命令族
（`station_points.dart:232,269,287,300,315,326,338,415`）：

| 族 | 条数 | 命令 |
| --- | --- | --- |
| `fs.*` | 7 | read / write / list / grep / delete / mkdir / writeBytes |
| `terminal.*` | 4 | exec / listRuns / stopRun / log |
| `agent.*` | 3 | message / stop / compact |
| `llm.*` | 1 | call |
| `tool.*` | 2 | call / close |
| `session.*` | 1 | rename |
| `ssh.*` | 1 | reconnect |
| `usage.*` | 1 | query |
| **合计** | **20** | 全部**申报了、路由得到、执行必失败** |

而插件**不能接管**它们：`_checkExecuteCommands` 对
`StationPoints.allCommands` 里的名字直接回"命令 X 是核心内置命令，插件不得自建同名命令"
（`plugin_bus.dart`，紧接 `station/register` 的校验）。
`_handleStationCommand` 的分派又是**内置点位优先**（`plugin_bus.dart:5101-5110`），
所以这 20 条没有任何一条能落到执行器上。

连带的三处漂移，都是同一条缺口（"契约登记表与实现各处说一套"）的表现：

1. [plugin-development.md](plugin-development.md) §6.1 的命令清单**仍把这 20 条当可用命令写**，
   参数与回包形状照旧列出——插件作者照着写，每条都会拿到那句 A5 拒绝；
2. `plugin.*` 点位的 `readme` 里写着 `plugin.mount（把执行站命令挂到本插件）`
   （`station_points.dart:346`），但同一个 spec 的 `commands` 没有它
   （`station_points.dart:359-367`），核心也没有对应 handler（`plugin_bus.dart:2730-2784`
   只有 7 个 `case`）⇒ 调用它得到的是"未知命令"；
3. `_handleStationCommand` 的提示语举例 `'station/command 需要 command（执行站命令名，如 fs.read / tool.call）'`
   （`plugin_bus.dart:5043`）——举的正是两个死名字，而真正可用的是 `file.read` / `exec.command`。

**更要紧的是：这 20 条里有 4 条今天仍有真实调用方**（不是纸面漂移）：

| 调用方 | 发的命令 | 后果 |
| --- | --- | --- |
| `compact` 插件（内置插件条目之一，`builtin_plugins.dart:247`） | `llm.call` / `fs.read` / `tool.call` / `agent.compact`（`plugins/compact/compact_plugin.dart:62-65`，用在 583 / 813 / 967 / 998 四处） | 压缩插件的**总结调用、必读文件读取、todo 快照全部必失败** ⇒ 每条必读文件渲染成"读取失败 …已不在核心平台面"，总结失败 ⇒ 报「插件未接管，回退内置压缩」。**开关一开就是稳定失败**，不是偶发 |
| `tree.agent` 的 `reconnectSsh()`（`agent_runtime.dart:458-465`） | `ssh.reconnect` | 目前**无调用方**（UI 的重连按钮走 REST 委派 `ApiService.reconnectAgentSsh`），是一段会误导后来人的死代码 |
| `tree.agent` 的租约注入分支（`agent_runtime.dart:793-796`） | 对 `fs.*` / `terminal.exec` 也照注 `lease_id` | 活的路径（`station_workspace_io.dart:46-108`）发的是 `file.*`；这个分支只是在给死名字**继续发门票** |
| `sample` 插件的四条演示开关（`builtin_plugins.dart:230`） | `fs.read` / `llm.call` / `tool.call` / `session.rename` | 演示插件默认关闭，点开四个开关会拿到四句同一个拒绝——**照抄示例的第三方插件会照抄这四个死名字** |

> 这四行合起来说明一件事：**A5 撤实现的时候没有改点位表，也没改随包插件的调用名**。
> 所以 §7 Q-5 不是"要不要顺手清理"，而是"随包插件的一条功能什么时候补"。

> 上面三条**漂移**本身不需要改代码（第 3 条改一个字面量，第 1、2 条改文档），
> 但上表那**四行调用方**要：先定方向——这 20 条是从点位表**删掉**、把族名让给插件自建
> （compact 的四个名字一个都不用改，由真正实现了它们的插件认领），还是**保留现状**、
> 把所有调用方改到插件自建站的名字上。见 §7 Q-5。

---

## 3. 今天唯一的"错误码"是怎么活着的

### 3.1 生产端：码拼在 message 里

```
plugins/ssh_executor/lib/src/exec_station.dart:276
  '$kSshLeaseUnknownCode: 租约 $leaseId 未登记（插件进程可能重启过；…）'
plugins/ssh_executor/lib/src/terminal_sessions.dart:260   ← 同一句话的第二处
```

而异常类本身只有一个 message 字段：

| 类 | 位置 | 字段 |
| --- | --- | --- |
| `ExecutorError` | `plugins/local_executor/lib/src/executor.dart:8-13` | `message` |
| `SshStationError` | `plugins/ssh_executor/lib/src/exec_station.dart:51-58` | `message` |
| `FileRouteError` | `plugins/files/lib/src/errors.dart:6-20` | `status` + **`code`** + `message`（REST 面**已经有码**） |

插件回包时把 message 原样塞进信封：`{'reply': {'error': error.toString()}}`
（`plugins/local_executor/local_executor_plugin.dart:131-135`）。

### 3.2 消费端：字符串嗅探

```
plugins/tree.agent/lib/src/runtime/agent_runtime.dart:781   if (!'$error'.contains(kSshLeaseUnknownCode)) rethrow;
plugins/files/lib/src/remote_files.dart:118                 if (!'$error'.contains('ssh_lease_unknown')) rethrow;
```

字面量在三个包各抄一份：`exec_station.dart:83`、`agent_runtime.dart:81`、
`remote_files.dart:118`（这处连常量都没有）。ssh 侧的注释自己承认了它是契约
（`exec_station.dart:78-82`："这个前缀是**契约**…其它失败绝不重试"），
但**没有任何东西守着这个契约**：改文案 = 静默破坏"重登记后只重试一次"的语义。

`FileRouteError` 反过来证明码是有用的——REST 面早就带着 `status + code`，
只是它的 `FileRouteError.read(msg)` 把 message 同时塞进 `code`
（`errors.dart:10-11`，为了兼容旧 `_error(message, status)`），那是另一处要收的口径。

---

## 4. 目标契约（已拍板：回包新增 `code` 字段）

### 4.1 线格式

`station/command` 的应答固定六键：

```json
{"command": "file.read", "ok": false, "mount_id": "plugin.local_executor.execute.local",
 "payload": null, "error": "文件不存在：a.txt", "code": "file_not_found"}
```

规则（全部可门禁化）：

1. `code` 是 **snake_case 稳定字符串**，跨版本不改名；要改名就新增一个、旧的标 deprecated。
2. `ok == true` ⇒ `code` 必须是空串（不许"成功也带个码"，否则判据变成两套）。
3. `ok == false` ⇒ `code` 必须非空且**在登记表里**；`error` 继续带可读中文人话（两者不互替）。
4. 老插件不回 `code` ⇒ 核心补 `unknown`，**不改状态**（信封新增可选键不是破坏兼容，
   但缺码这件事必须可见：核心在 `code` 缺失时写一条日志，不许静默当成无码可判）。
5. `code` **不进** JSON-RPC 的 `error.code`（那是协议层的 `-32602` 那一族，两套语义混不得）。

### 4.2 码表（进 `packages/tree_protocol/lib/src/exec_station_error_codes.dart`，单一来源）

| 分区 | 码 | 出处（§1.3 的哪一行） | 调用方该做什么 |
| --- | --- | --- | --- |
| 核心 | `lease_unknown` | 1 | 先 `workspace/register` 再重发 |
| 核心 | `lease_foreign` | 2 | 别跨插件借租约，报错即可 |
| 核心 | `command_unknown` | 3 | 看 `error` 里的可用命令表，改命令名 |
| 站点 | `station_disabled` | 4 | 等启用或换挂载 |
| 站点 | `scope_denied` | 5 | 身份/隔离不对，**不重试** |
| 站点 | `command_not_on_station` | 6 | 命令名与点位不匹配 |
| 站点 | `no_mount` | 7 | 执行器没接管：装配或启动插件 |
| 挂载 | `plugin_offline` | 8 | 按生命周期分化：crash/uninstalled ⇒ 503 不是 404 |
| 挂载 | `bad_reply` | 10 | 插件回包非法，报插件 bug |
| 挂载 | `mount_exception` | 11 | 挂载位置抛异常 |
| 插件 | `invalid_arguments` | 12 | 参数缺失/越界（`path` 越出根、缺 `pattern` 等） |
| 插件 | `file_not_found` | 12 | 路径不存在（read/list/delete/rename 的 missing） |
| 插件 | `not_a_file` | 12 | 目标是目录，不能读 |
| 插件 | `dir_not_empty` | 12 | 删除需要 `recursive:true` |
| 插件 | `target_exists` | 12 | rename 目标已存在 ⇒ 绝不覆盖 |
| 插件 | `bad_base64` | 12 | base64 非法 |
| 插件 | `lease_unknown`（复用） | 12 | 即 `ssh_lease_unknown`：重登记后**只重试一次** |
| 插件 | `backend_unreachable` | 12 | 隧道/远端 agent 不可用（`建立 SSH 隧道失败…`） |
| 兜底 | `unknown` | 任何没给码的失败 | 只能当"可读原因、不可编程分支"处理 |

> 命名规则：`<对象>_<状态>`，不带族前缀（`file_` / `ssh_` 不带）。
> **例外**是 `lease_unknown`：两侧共用同一个码是对的——"租约不在"这件事
> 本来就由"谁持有租约表"决定，语义同、来源异，`mount_id` 已经指出是谁。
> `ssh_lease_unknown` 这个名字**不迁移**：它是插件仓的字面量常量，
> 改成 `lease_unknown` 需要同时动三个包，属于 §6 片 2 的内容（一次改完，不留兼容分支）。

### 4.3 传递链改造点（八环，逐点必须动，少一环码就断）

| 环 | 文件 | 要加什么 |
| --- | --- | --- |
| 1 | `plugins/*/` 执行器异常类（`ExecutorError` / `SshStationError`） | `code` 字段（构造必带，禁空） |
| 2 | `local_executor_plugin.dart:131-135`、ssh 侧同形处 | 回包 `{'reply': {'error':…, 'code':…}}` |
| 3 | `station_runtime.dart:176-206` `StationReply` | `code` 字段 + `fromJson` 读 `raw['code']` |
| 4 | `station_runtime.dart:372-394` `StationCommandOutcome` | `failed(error, code)` / `failedWith(error, payload, code)` |
| 5 | `plugin_bus.dart:2682-2719` `_forwardStationCommand` | 把 `reply.code` / 核心自己的码递进 outcome |
| 6 | `station_instance.dart:985-1078` `ExecuteStation.execute` | 六处 `StationCommandResult` 各带一个码 |
| 7 | `station_runtime.dart:397-427` + `plugin_bus.dart:5134-5155` | `StationCommandResult.code` 写进出站信封 |
| 8 | `plugins/_kit/plugin_kit.dart:341-378` `CmdFailureException` | 带 `code`，消费方按 `e.code` 分支（替掉 `contains`） |

环 2 与环 8 之间是**插件仓**，环 3~7 在**桌面仓**：所以这一条链必须
**先合桌面仓（能收能回），再合插件仓（开始带码）**，顺序反过来只会让码在中间掉一层。

### 4.4 逐命令幂等标注（重试前必看）

| 命令 | 幂等 | 依据 |
| --- | --- | --- |
| `file.read` / `file.list` / `file.grep` | 是 | 只读 |
| `file.write` | 是 | 覆盖写，同参重放同结果（`executor.dart:121-133`） |
| `file.writeBytes` | 本机：是（总是覆盖）<br>SSH：`append:false` 是，**`append:true` 否** | `executor.dart:223` ↔ `exec_station.dart:466-473`：重放一个 append 块 = 重复追加字节 |
| `file.mkdir` | 是（本机已存在仍回 `created:true`） | `executor.dart:200-203` |
| `file.delete` | **否**（不存在 ⇒ 报错） | `executor.dart:179-180` ↔ `exec_station.dart:783` |
| `file.rename`（SSH 独有） | **否**（目标已存在 ⇒ 报错；重放第二次源已不在） | `exec_station.dart:487-494` |
| `exec.command` | **否**（起进程就是副作用；软超时会转后台并给 `task_id`） | `executor.dart:331-361` |
| `exec.command` 的 `hook_action=status` | 是 | `executor.dart:323` |
| `exec.command` 的 `hook_action=cancel` | 是（已停则原样回状态） | `executor.dart:318-321` |
| `ssh.lease.register` | 是（同 `lease_id` 覆盖登记） | `exec_station.dart` `_registerLease`：`_leases[leaseId] = …` |

**为什么这张表必须存在**：`lease_unknown` 的重登记重试（`agent_runtime.dart:781`）
今天只作用于"租约不在"，但一旦有人把"按码重试"推广成通用策略，
`append:true` / `file.delete` / `exec.command` 三条会被重放出**重复字节、
误报缺失、重复起进程**。§4.5 的不变量就是把这张表钉住。

### 4.5 不变量（assertions）

1. 执行站回包信封的六个键名只在 `tree_protocol` 出现一次，两侧从常量取。
2. `ok:false` 必有码，且码必在登记表里；`ok:true` 的码必为空串。
3. **非幂等命令**（§4.4 标"否"的行）的码**不许**触发任何自动重试；
   重试策略只允许写在"按码白名单"里（今天唯一一条：`lease_unknown` ⇒ 重登记 + 重试一次）。
4. 核心不解释任何命令语义：码只**传递**，不**改写**（插件给的码原样出站；
   核心只在产生自己那批码时负责）。
5. `payload` 的字段形状由挂载位置决定，核心不校验也不补键；`details` 这类
   单侧能力**不许**被写成"所有执行站都有"（§2.2 是唯一的口径出处）。

---

## 5. 门禁设计（新增 `exec_station_error_code_gate_test.dart`）

照 `plugin_rpc_method_gate_test.dart` 的形状做（它已经被验证能挡住字面量漂移）：

1. **登记完整性**：扫 `packages/tree_core/lib/src/plugin/` + `plugins/`，
   凡出现 `'code': '<字面量>'` 或 `ExecStationErrorCodes.<X>` 的取值，
   必须在 §4.2 的码表里；未登记即失败。扫描面对不存在的目录**显式失败**
   （不留占位路径，理由同那条门禁的注释）。
2. **核心侧不许写字面量**：`plugin_bus.dart` / `station_instance.dart` /
   `station_runtime.dart` 里回给插件的 `code` 只能来自 `tree_protocol` 常量，
   命中数必须为 0。
3. **信封键名单一来源**：`station/command` 应答的六个键名必须全部来自
   `tree_protocol` 的常量表；两处出口（`plugin_bus.dart:5134` 与 `5149`）
   构造的键集合必须完全相同——防"一条出口少写一个键"。
4. **插件异常类必须带码**：扫 `plugins/*/lib/**`，凡 `implements Exception`
   且被执行站命令路径使用的类，其构造函数必须有 code 形参（防 §3.1 那种
   "只有一个 message"的形态再生）。
5. **消费端不许再 `contains`**：`'$error'.contains('ssh_lease_unknown')`
   这类字符串嗅探在片 2 之后命中数必须为 0（这是这条链改完的验收线）。

---

## 6. 落地切法（每片都能单独过门禁）

| 片 | 内容 | 仓库 | 门禁 |
| --- | --- | --- | --- |
| 1 | 本文 + `docs/README.md` 索引行 + `plugin-development.md` 的执行站小节指过来 | 桌面 | `docs_contract_test` |
| 2 | `tree_protocol`：信封键名 + 码表 + `CmdFailureException` 带码（kit 在插件仓，环 8 放片 4） | 桌面 | 新增码表单测 |
| 3 | 核心六处/两处出口全部带码；§2.3 的文案前缀 `fs.*` / `terminal.exec` 统一成申报名 | 桌面 | 片 1 的门禁 + `plugin_close_no_hard_timeout` 等既有站点用例 |
| 4 | 插件仓：两个执行器的异常类带码、回包递码、`ssh_lease_unknown → lease_unknown`、三个包的消费端改按码分支 | 插件 | 同上（扫插件仓） |
| 5 | 逐命令幂等测试（§4.4 每行一条断言）+ `file.list` 的 `details` / `append` 要不要本机补齐的结论 | 两仓 | 新用例 |

片 1 是文档，可以单独合；片 2~3 必须连着合（否则核心先上线会因为没有码源而空转）；
片 4 上线前，核心的 `unknown` 兜底就是唯一的码来源，这是刻意的（不换顺序、不留兼容分支）。

---

## 7. 待拍板

| # | 问题 | 选项 |
| --- | --- | --- |
| Q-1 | 本机要不要补齐 SSH 的四个增强（`details` / `append` / `rename` / `raw` 分块读） | **已拍板 → §8**：四条全补，本机与 SSH 的 payload 键集必须相同 |
| Q-2 | 两套租约系统（核心 `workspace/register` vs 插件 `ssh.lease.register`）要不要统一 | **已拍板 → §8**：统一到**插件侧**（`local.lease.register`），核心撤掉租约簿记与 `root` 注入；随之必须搬走「租约只能登记方自己用」那道 fail-closed |
| Q-3 | 非 UTF-8 读取的**内联 base64**（§2.2 末行）与交接文档 §8「大文件不许塞进 JSON」的张力 | 加尺寸上限＋超限改走 `result_path`／维持现状并写明上限（**未拍板**） |
| Q-4 | `FileRouteError.read` 把 message 塞进 `code` 的旧口径（REST 面） | 一并收成 `{status, code, message}` 三件齐／REST 面另开片（**未拍板**） |
| Q-4b | 本机 REST 面把 `StateError` 一律映射成 **404**（`local_executor_plugin.dart:197-198`），而 SSH 侧同类"租约/会话不存在或已存在"是 **409**（`terminal_sessions.dart:117,259,271`） | **已拍板 → §8**：本机收成 409（404 在不变量里是"插件没装"的语义，不能兼作资源冲突） |
| Q-5 | **20 条内置命令的定位**：它们既是 §2.4 那张"必然失败"的表，也是 §2.1 那 8 个"假别名"的根源，还是 compact 四条命令失败的原因——**先定方向才谈得上清** | **已拍板：走 A（删点位表 + 让名）**，2026-10-31。领域八族从 `StationPoints.executes` 整体摘掉，族名让给真正的实现方（`llm.*` / `tool.*` / `agent.*` / `session.*` / `usage.*` ⇒ tree.agent，`fs.*` / `terminal.*` ⇒ 由要做的人带着实现申报，本期不保留假可用）。让名同时必须撤 `_checkExecuteCommands` 的 `tool.` / `agent.` 前缀禁令，否则插件认不进来 |
| Q-6 | 两个执行器的命令名要不要对称 | **已拍板 → §8**：本机改 `local.file.*` / `local.exec.command`，与 `ssh.*` 同后缀；限定词直接取 `StationModeKey` 的两个值 |
| Q-7 | **片 4 只换到了 tree.agent 一家**：`compact` 的四条命令（`llm.call` / `fs.read` / `tool.call` / `agent.compact`）与 `sample` 的四条演示开关，在片 1 让名之后**仍然没有任何承接方**，且不能靠换名解决——① `llm.* / tool.* / agent.*` 是 Q-5 A 里点名"让给 tree.agent"的族，但 tree.agent 今天没申报也没实现它们；② `fs.read → local.file.read` 换口需要一条 `local_lease_id`，而"agent → 工作空间目录"的解析只有 tree.agent（`_workspaceDirOf`）与 files（自己读 `agents/*.yaml`）各有一份，compact 再抄一份就是第三份漂移源 | **未拍板**，三条路：**(a)** tree.agent 在 `agent_tools` 站上申报并实现 `llm.call` / `tool.call` / `agent.compact` + 一条工作空间读命令，compact 改调它（领域命令回到唯一实现方，代价是 tree.agent 的站变大）；**(b)** compact 自己读 `agents/*.yaml` 解析目录并登记本机租约（改动只在 compact，但把同一份解析逻辑复制第三遍）；**(c)** 承认压缩的"必读文件"属于核心侧，撤掉这条 IO 依赖，只回摘要（改动最小，功能面收窄）。**建议 (a)**：与 Q-5 A 的"让名给真正的实现方"同一条线，不再新增重复解析 |

---

## 8. 已拍板的统一口径（2026-10-31 补，覆盖 §2.1 / §2.2 / Q-1 / Q-2 / Q-4b / Q-5）

三条决定，都落在"两个执行器行为对称 + 核心不认识具体执行器"这条线上。

### 8.1 命令名对称：限定词取 `StationModeKey`

目标命令表**两边各 10 条，后缀逐字相同**，只换限定词：

| 操作 | 本机（改后） | SSH（今天已是） |
| --- | --- | --- |
| 租约登记 | `local.lease.register` | `ssh.lease.register` |
| 读 / 写 / 列 / 检索 / 删 / 建目录 / 写字节 / 改名 | `local.file.read` `…write` `…list` `…grep` `…delete` `…mkdir` `…writeBytes` `…rename` | `ssh.file.*` 同名八条 |
| 执行命令 | `local.exec.command` | `ssh.exec.command` |

限定词不是新造词：`local` / `ssh` 正是 `StationScope.modeKey` 的两个取值
（`station_scope.dart:32-44`，`StationModeKey.all = {local, ssh}`）。所以
"选哪个命令名"与"目标 agent 是哪个模式"是同一个词的两次使用，`/api/meta` 里
不再出现"一侧带限定词、一侧不带"的半吊子形状。

连带撤销：`executor.dart:26-53` 的 8 个 `fs.*` 分支（§2.1 那条"假别名"）与
`agent_runtime.dart:61-76` 那张逐条映射表 ⇒ 换成一条规则"前缀 `local.` 换 `ssh.`"，
参数键同步（`local_lease_id` ↔ `ssh_lease_id`）。

### 8.2 能力差抹平（本机补齐四条）

本机补 `file.list` 的 `details`、`file.rename`、`writeBytes` 的 `append`、`file.read`
的 `raw` 分块通道。补齐的理由不是"本机也想要这功能"，而是**只有键集相同，§5 那条
"同一操作两侧形状对齐"的门禁才写得出来**；否则门禁只能对两侧各写一份、各绿各的。

### 8.3 租约统一到插件侧，fail-closed 跟着搬过去

本机改成像 SSH 那样由执行器自己登记（`local.lease.register`），核心撤掉
`_workspaces` 表、`root` 注入与 `workspace/register` 这条 RPC。

**必须一起搬的是这一条**：核心今天替本机看着"租约只能登记方自己用"
（`plugin_bus.dart:5087-5095`，不一致就 fail-closed 拒）。改成插件侧之后，这个判断只剩
一个落点——而依据是在路上的：核心把执行站命令转给执行器插件时，`meta` 里带着
`source_plugin_id`（`plugin_bus.dart:2698`）。所以口径写死成两条：

1. 两个执行器登记租约时**记下登记方的 `source_plugin_id`**；每条命令进来先比对，
   不一致 ⇒ 拒并给码（新增码 `lease_denied`）；
2. `root` 只能由插件按租约自己查出来；arguments 里出现的 `root` / `workspace_root`
   一律忽略（核心 `sanitizeStationArguments` 那道剥离保留，`plugin_bus.dart:5028-5032`）。

⚠ **SSH 侧今天其实没做第 1 条**（`exec_station.dart:282` 只按 `ssh_lease_id` 查自己的表，
不看是谁在问）。这不是新加的要求，是本来就缺的一半——不补上，"两侧行为一致"这句话
在安全这一栏是空的，而且比核心侧那套更容易被猜出句柄的插件滥用。

### 8.4 切片顺序（取代 §6 里"先码后形状"的排法）

| 片 | 内容 | 仓 | 依赖 |
| --- | --- | --- | --- |
| 1 | 点位表删八族（Q-5 A）+ 撤 `tool.` / `agent.` 前缀禁令 + 落盘空壳对账 + §5 门禁 + 文档口径 | 桌面 | 无 |
| 2 | 执行器改名（§8.1）+ 四条能力补齐（§8.2）+ `local.lease.register` + 两侧补 `source_plugin_id` 比对（§8.3） | 插件 | 片 1 先合（否则名字被内置点位表挡着） |
| 3 | 撤协议面 `workspace/register` 与核心租约簿记（§8.3） | 桌面 | **片 2 已上线**，两片之间不能发版断档 |
| 4 | 调用方换口：tree.agent / compact / sample + 清 `reconnectSsh` 死代码 | 插件 | 片 2 |
| 5+ | 已拍板的 `code` 字段链路（§4），码表新增 `lease_denied` | 两仓 | 片 1 |

**落地状态（2026-10-31）**：

- **片 1 已合（桌面仓）**：`StationPoints.executes` 现在只有 `plugin` / `station` 两个
  点位（内置点位 36 → 28，执行站命令 29 → 9）；`StationHubIds` 里八个领域点位常量删除、
  id 进 `retiredExecutePoints`；`_checkExecuteCommands` 撤掉 `tool.` / `agent.` 前缀禁令
  （`plugin.` / `station.` 保留）；`StationHub.load` 新增落盘对账（内置实例的 id 不在点位
  表里 ⇒ 读侧丢掉并写回一次，幂等）；门禁两处——`station_points_test` 的「表里每条命令
  都得被 `ExecuteStationMounts.handles` 认下」＋ `plugin_hot_restart_station_test` 的
  「按全表核对挂载位置」；`plugin-development.md` §3.1 / §4 / §5.6 / §6.1 / §11 与
  `agent_pluginization.md` 的过渡期说明同步收口。
- **片 1 留下一条已知不一致**：`builtin_plugins.dart:230` 的示例插件描述仍在讲
  `fs.read / llm.call / tool.call / session.rename` 四个演示开关——那四条命令在片 2 换名
  之前确实没有承接方。文字随片 2 一起改（改在核心侧，改早了会与还没动的插件产物更不符）。
  → 已随片 4 一并改掉（见下）。
- **片 2 已合（插件仓 `fb496e0`，2026-10-31）**：`local_executor` 认领
  `local.file.*` / `local.exec.command` / `local.lease.register`（10 条，与 `ssh.*` 逐字
  对称），补齐 §8.2 四条能力差（`read{raw,offset,length}` / `writeBytes{append}` /
  `list.details` / `file.rename`），并落地 §8.3 两条：`root` 只来自插件自己那张租约表
  （自检里注入假 `root` 证明它不生效）、登记方比对 `meta.source_plugin_id`（不一致 ⇒
  新码 `lease_denied`，**两侧都补了**——SSH 侧原来缺的那一半不再是纸面一致）。
  顺带收掉 §4b：本机 REST 面的 `StateError` 由 404 改 409。
- **片 4 已合（插件仓 `7313ae7`，2026-10-31）**：tree.agent 的 16 项逐条映射表换成
  一条规则「前缀 `local.` 换 `ssh.`」（`fs.*` 那半边是 §2.1 的假别名，随之消失）；
  本机租约改由 `local.lease.register` 登记、命令带 `local_lease_id`，
  `local_lease_unknown` 与 `ssh_lease_unknown` 共用「重登记 + 只重试一次」那一条判据；
  不再向核心 notify `workspace/register`（协议面本身留给片 3）；SSH 命令参数不再带
  `root`；`reconnectSsh` 不再下发无挂载的 `ssh.reconnect`，改为「丢弃缓存句柄 +
  重新 `ssh.lease.register`」（`down` ⇒ 清零退避重建，健康 ⇒ 复用）。
  桌面侧同步收了 `nonProtocolPluginMethodLiterals` 的六个命令名字面量与
  `builtin_plugins.dart:230` 的演示文案。
- **片 3 / 片 5 未开始**；**#43 仍未收口**：compact 与 sample 的命令换口卡在 §7 Q-7
  （那四条名字到今天没有承接方，不是回归，是 A 的另一半没做）。片 2 落地前领域命令
  在真机上报「暂无挂载位置」，落地后 `local.*` / `ssh.*` 两族是**能打通**的，
  只有 `llm.* / tool.* / agent.* / session.*` 还悬着。
