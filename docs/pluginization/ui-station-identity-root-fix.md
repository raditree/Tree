# UI 站点身份「可晚到」与订阅回执（协议根治）

> 事故记录见 [known-issues.md](../known-issues.md) #49：UI 先把 `station/subscribe` 发出去、
> 后发 `ui.hello`，核心按「未绑定身份」拒收，订阅方又静默吞掉 error、不重试 ⇒ 界面永久
> 收不到 `msg_chunk` / `agent_status`，表现为「发消息没反应、状态恒 idle」。
> UI 侧已先做了顺序修复（插件仓 `42416e9`）；本文把**顺序依赖本身**从协议里删掉。

## 1. 问题不在“谁先发”，在契约

现状把连接身份（`ui.hello` 建立的 bond）写成**隐式前置条件**：

- `station/subscribe` 等五条上行帧必须先有 bond，否则被拒；
- 拒绝走通用 `error` 帧，**没有请求关联、没有稳定错误码**；
- 客户端只在“建连”这一个时刻发订阅，被拒后没有重试入口。

于是任何客户端只要发送顺序错了（哪怕只差一个同步调用），就会得到“永久 0 订阅 + 全静默”
这一最坏组合。只在客户端修顺序，等于把契约的正确性押在每个客户端的实现细节上。

## 2. 目标与不变量

1. **顺序无关**：`ui.hello` 可以晚到；身份建立前到达的站点请求不得丢失。
2. **失败可见**：每条站点请求都有回执（`station_ack`），失败带稳定 `code`，可重试。
3. **一连接一身份**：仍然不允许一条连接中途换 `plugin_id`（冲突即拒并断开）。
4. **UI 仍是纯消费者**：WS 上行白名单不变（`ui.hello` + 五条站点帧 + heartbeat）。
5. **只增不改**：新帧 `/ 新字段 / 新码值`；旧 UI 对新核心、新 UI 对旧核心都要能跑。

## 3. 协议改动

### 3.1 `ui.hello` 语义降级

- 从「一切业务帧的前置条件」改为「连接身份声明」：**任何时刻**可发，重连重发；
- 身份建立前到达的 `station/subscribe|unsubscribe|register|unregister|trigger`
  进入**连接级挂起队列**；
- `ui.hello` 成功后按**到达顺序**补放；补放期间客户端不必重发；
- 队列有界：默认 **64 条 / 10s**（核心可配）。溢出与超时都回 `station_ack(ok:false)`：
  - `identity_queue_overflow`：该条请求未受理（不静默丢弃）；
  - `identity_required`：TTL 到期仍未 hello，队列内每条各回一条，之后该连接的站点请求
    立即拒绝（fail-fast，不再排队）。

### 3.2 新增下行帧 `station_ack`

与 `station_delivery` 同为**平铺 snake_case**（下行历史帧口径）：

```jsonc
// 成功
{"type":"station_ack","request":"subscribe",
 "station_id":"plugin.tree.agent.broadcast.events","ok":true}

// 失败（带稳定错误码；message 只给可读解释，客户端按 code 决策）
{"type":"station_ack","request":"subscribe",
 "station_id":"plugin.tree.agent.broadcast.events","ok":false,
 "code":"station_not_found","message":"站点不存在：…（可用广播站见 /api/meta.stations）"}
```

- `request` ∈ `subscribe | unsubscribe | register | unregister | trigger`（裸名，与帧名
  `station/*` 分开：前者是动作标识，后者是方法名）；
- 每条站点请求**恰好一条**回执；成功也要回（客户端据此确认“语义已生效”，而不是只看
  是否出现 `reset`）；
- 通用 `error` 帧保留，但只承载**协议级**错误（`ui.hello` 被拒、未知上行帧、核心未启用
  插件系统）；站点请求的业务失败一律走 `station_ack`。

### 3.3 稳定错误码

| code | 含义 | 可否重试 |
| --- | --- | --- |
| `identity_required` | 超时未 `ui.hello`，挂起请求已丢弃 | 是（先连上身份） |
| `identity_queue_overflow` | 身份前挂起队列满，该条未受理 | 是（hello 后重发） |
| `identity_conflict` | 同连接换了 `plugin_id` / 与已绑定身份不符 | 否（断开连接） |
| `station_not_found` | 站点还不存在（插件未注册 / 未安装） | 是（退避重试） |
| `not_broadcast` | WS 侧只能订阅 / 注册广播站 | 否 |
| `scope_invalid` | scope 不是 `local` / `ssh` / 空通配 | 否 |
| `not_owner` | 触发 / 注销的不是自己注册的自建站 | 否 |
| `invalid_request` | 缺 `station_id` / `topic` 等必填字段 | 否 |
| `subscribe_rejected` | 站点侧拒绝（上限、配置等） | 视 message 而定 |
| `broadcast_rejected` | 广播被拒（scope 不可证明归属 / 站点被禁用） | 否 |

错误码常量进协议包（`StationErrorCodes`）；核心内部既有码（`no_station` /
`invalid_scope`）在出站处映射到上表，不让两套词表同时暴露。

### 3.4 契约版本

`uiContractVersion` / `/api/meta.ui_contract`：`1.0` → **`1.1`**。
UI 自持契约 `protocol_contract.dart` 同步新增帧 / 值对象 / 码表；黑盒一致性套件把
“先订阅后 hello 仍能订阅成功 + 回执形状”钉成字面量。

## 4. 核心侧行为（`StationWsBridge`）

1. 连接级状态（`_UiConnectionState`）在**首条站点帧**到达时就创建（bond 可空）；
2. `bond == null` 时只入队，不执行；`ui.hello` 成功后绑定 → 取出队列按序执行 → 清空；
3. 队列计时器：首条入队启动，hello 成功 / 连接关闭 / 到期即取消；
4. `station_ack` 的产出点就是五个 handler 的每个出口（成功 / 每个失败分支）；
5. `onConnectionClosed` 释放队列与计时器（不泄漏 Timer）；
6. 订阅成功仍先回 `station_ack(ok)`，再发既有 `station_delivery(state=reset)`——
   `reset` 的水位语义不变，只是不再是“唯一的成功信号”。

## 5. UI 侧行为（`StationClient`）

1. `handleFrame` 新增 `station_ack`：按 `request` 只处理 `subscribe`；
2. `ok`：取消该站重试、清掉对应离线提示；
3. `ok:false` 且 `code` 可重试（`station_not_found` / `identity_required` /
   `identity_queue_overflow` / `subscribe_rejected`）：按 `1s / 2s / 4s / 8s / 16s`
   退避重发该站订阅（≤5 次，站点已退订 / 连接已换即放弃）；
4. `closed`：保留站点在“想要的订阅集合”里，插件恢复后按同一退避策略重订；
   拿不到 ack 的旧核心（无回执）保持现状：不重试，只显示横幅；
5. 任一 `data` / `reset` 投递到达即视为通道恢复：清离线提示、清重试计数。

## 6. 兼容矩阵

| 组合 | 行为 |
| --- | --- |
| 新核心 + 旧 UI（先订阅后 hello） | 订阅被挂起 → hello 到达补放 ⇒ **无需重发 UI 即恢复** |
| 新核心 + 新 UI | hello 先行 + 回执确认；失败退避重试 |
| 旧核心 + 新 UI | 新 UI 仍 hello 先行（已修）；无 `station_ack` ⇒ 不重试，行为同今天 |
| 旧核心 + 旧 UI | 与事故前一致（本篇不改善） |

## 7. 切片与门禁

| 片 | 内容 | 测试 |
| --- | --- | --- |
| P1 | 协议包：`station_ack`、`StationAck`、`StationErrorCodes`、契约 1.1 | 协议包全量 + 完备性 |
| P2 | 核心桥：挂起队列（TTL / 上限 / 清理）+ 按序补放 + 五条请求回执 + 码值映射 | `ui_station_ws_test` 新增 4 条、既有拒绝断言改回执 |
| P3 | UI：ack 处理 + 退避重订 + `closed` 恢复 + 横幅清理 | `station_client_test` 新增 3 条 |
| P4 | 文档：`plugin-development.md` §7.2、`plugin-platform.md` 不变量、`known-issues` #49 根治记录、`work-log` | 文档契约门禁 |

门禁顺序沿用项目约定：`dart analyze`（受影响包 0 问题）→ 受影响包全量测试 →
`tree_protocol` 访问控制 / 完备性 → UI 改动跑 `flutter analyze` + 全量 `flutter test`。

## 8. 风险与边界

- **队列内存**：有界（64 条）+ TTL（10s）+ 连接关闭即清；token 鉴权的本机回环连接，
  不构成新的 DoS 面。
- **重试风暴**：UI 侧指数退避 + 次数上限；`closed` 后的重订只在“该站仍在想要的集合”时做。
- **不改变**：`closed` 仍是“该订阅通道终止”的语义（站点实例消失 / 归属插件下线）；
  “是否重新订阅”是客户端策略，核心不替客户端恢复。
- **不做**：连接 URL 携带身份、每帧自证身份（两者都引入第二个身份来源；本篇用
  “服务端挂起”把顺序依赖直接删掉，客户端零改动即可被救回）。
