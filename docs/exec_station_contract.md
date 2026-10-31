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
| Q-1 | 本机要不要补齐 SSH 的四个增强（`details` / `append` / `rename` / `raw` 分块读） | 补齐（调用方一套代码打天下）／不补（本机走 `result_path`，另开一条 L 项） |
| Q-2 | 两套租约系统（核心 `workspace/register` vs 插件 `ssh.lease.register`）要不要统一 | 统一成核心侧／保持两套只统一码（推荐：后者，动租约归属是大改） |
| Q-3 | 非 UTF-8 读取的**内联 base64**（§2.2 末行）与交接文档 §8「大文件不许塞进 JSON」的张力 | 加尺寸上限＋超限改走 `result_path`／维持现状并写明上限 |
| Q-4 | `FileRouteError.read` 把 message 塞进 `code` 的旧口径（REST 面） | 一并收成 `{status, code, message}` 三件齐／REST 面另开片 |
| Q-5 | **20 条内置命令的定位**：它们既是 §2.4 那张"必然失败"的表，也是 §2.1 那 8 个"假别名"的根源，还是 compact 四条命令失败的原因——**先定方向才谈得上清** | **A（推荐）删点位表 + 让名**：领域族从 `StationPoints.executes` 摘掉，`_checkExecuteCommands` 的内置名拦截随之失去对象，族名由真正实现了它们的插件认领（`llm.*`/`tool.*`/`agent.*`/`session.rename` ⇒ tree.agent，`fs.*`/`terminal.*` ⇒ local_executor）。compact 的四个名字**零改动**即复活。代价：已落盘的内置执行站实例仍带旧白名单，需要一次"点位表是唯一来源"的对账（`stations.load()` 恢复的实例要按新表收敛）。<br>**B 保留现状 + 改调用方**：这 20 条继续躺着，compact / sample / tree.agent 全部改用插件自建站的名字，文档把"这些名字必失败"写清楚。代价最小，但功能缺口仍在，且 `/api/meta` 会一直对外申报一批点不动的命令 |
