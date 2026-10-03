# server（回环 HTTP + WS 服务）

核心的对外门面：路由表、鉴权、响应编码、WS 连接活性。**只监听 127.0.0.1**、零第三方依赖（要能 `dart compile exe` 单文件分发）。

## 文件

| 文件 | 作用 |
| --- | --- |
| [core_server.dart](core_server.dart) | 路由注册 + WS 帧分发 + 鉴权；provider 接线（Spec 快照 / 团队工作目录 / 执行站挂载）与 `close()` 解绑 |
| [http_router.dart](http_router.dart) | 极简路由表：精确路径 + `{name}` 占位符 |
| [http_io.dart](http_io.dart) | UTF-8 JSON 响应助手 |
| [ws_liveness.dart](ws_liveness.dart) | 带发送活性与**待补发队列**的 WS 连接与注册表（`LivenessWsHub`） |
| [boot_warmup.dart](boot_warmup.dart) | 启动期外设预热：**并行 + 有界 + 绝不抛**（`warmUpPeripherals`，只在握手之后跑） |

## 不变量（assertions）

1. **只监听回环**；端口由内核分配；一次性随机 token 仅经 **stdout 握手行**交给父进程、**不落盘**——同机其它进程无法假冒。
2. **覆盖度不变量**：协议包 `ApiPaths.kept` 里每一条路径，要么已在路由表实现，要么显式登记在 `stubApiPaths` 并以 **501** 明确拒绝——**不存在"前端会调、核心静默 404"的灰区**（由 [test/server_test.dart](../../../test/server_test.dart) 强制）。
3. **零第三方依赖**：不为路由引 shelf，需求只是"精确路径 + 占位符"匹配。
4. 路由 `{name}` 的取值已由 `Uri.pathSegments` 解码，处理器**不再二次解码**（否则含 `%` 的 id 会被误解）。
5. 响应必须**自己 UTF-8 编码**：`dart:io` 默认 latin-1 会毁掉中文，而前端强制按 UTF-8 解 `bodyBytes`。
6. **WS 发送不做静态超时**：`send` 就是"写出去"，不等确认、无 TTL；收到任意入站帧（前端每 30s 一次的 heartbeat 就是最典型的一拍）即续期；连续 N 拍什么都没收到判失活。
7. **判失活后不静默丢帧**：帧转入该连接的**待补发队列**，心跳恢复或前端重连后补发；队列有上限，超出时**计数丢弃**（可见的丢弃，不是静默丢弃）。
8. **没有连接时不累计丢失**（没人在听 ≠ 心跳丢了），但**已有的失活标记保留**：最后一个前端连接断开即把链路记为失活，断开期间广播的帧因此进队列而不是消失；而从未有过连接的场景（headless CLI）永远不会判失活，不会卡住消息派发。
9. 前端心跳节奏是 30s ⇒ WS 判活窗口默认取 30s × 3 = 90s，而**不是** 10s × 3 = 30s——后者与前端心跳等长，边界抖动会把"在线但空闲"误判失活。前端心跳改成 10s 后，这里换回全局默认口径即可。
10. **热应用如实回报**：插件配置已落盘但本次热应用失败 ⇒ `hot_applied: false` +「配置已保存，但本次热应用失败，重启核心后生效」+ 具体原因；清单读不出来（YAML 被手改坏）时运行实例**保持原样**，不因为一个拼写错误把在跑的插件全停掉。做成接缝（`PluginHotApplier`）是为了将来换实现时 REST 层与前端一个字都不用改，且测试能确定性地覆盖失败路径。
11. provider 接线与解绑成对：`close()` 里解绑团队工作目录 provider，并 `store.flush()`。
12. **`DELETE /api/agents/{id}` 有两道闸门，不通过就什么都不动**（[test/agent_delete_api_test.dart](../../../test/agent_delete_api_test.dart) 强制）：
    ① **有下级成员必须显式 `?cascade=1`**，否则 409 + `cascade_required`（列出下级）——直接删中间层 leader
    会留下「删不掉、停不了、广播够不着、却还能干活」的孤儿成员（见 [../team/README.md](../team/README.md) 不变量 12）；
    ② **任一相关会话正在运行就拒绝**（409 + `running`），提示先停止并等它空闲——`stop` 抢不动正在执行的工具
    （本地执行活着就永不超时），所以这里**不等待、不轮询**；删掉正在写的 agent 正是残留的来源（继续写共享工作目录、
    回一条来自幽灵成员的消息、`data/<id>` 被写回来）。通过后的顺序：停（作废排队任务 + 收尾在途提问）→
    `store.flush()` 排水 → 清提问记录 → 叶→根删 → 回填 TOP 的 `team_member_count` → 再排水。
    409 的响应体同时带 `detail`（通用错误文案口径）与结构化字段。
13. **外设预热不排在握手之前**（[boot_warmup.dart](boot_warmup.dart) + `tree_core_cli/bin/tree_core.dart`，
    [test/boot_warmup_test.dart](../../../test/boot_warmup_test.dart) 与
    `packages/tree_core_cli/test/cli_serve_test.dart` 强制）：MCP 首次连接（**没有超时参数**）与插件启动
    （**逐家串行**、每家 20s）都只在**握手之后**预热——并行（总时长取最大而非求和）、有界（预算 3s，
    超预算立即返回且未结束的任务继续在后台跑）、绝不抛（单家失败只记日志）。
    理由：握手是界面判"核心可用"的**唯一**依据，被外设拖住时用户看到的是「核心进程未能启动
    （等待核心进程握手超时 25s）」（见 [docs/known-issues.md](../../../../../docs/known-issues.md) #13）。
    模型那一轮由 `LlmAgentEngine.awaitReady` 有界等一次预热，所以不会"悄悄少掉插件/MCP 工具"。
    每一段都往 stderr 打 `[core:boot]` 分段耗时——"启动慢"因此是可归因的数字，不是感觉。

14. **会话历史接口按"全局下标"寻址**（[core_server.dart](core_server.dart) 的 `_conversationHistory`，
    [test/conversation_history_paging_test.dart](../../../test/conversation_history_paging_test.dart) 强制；前端口径见
    [lib/README.md](../../../../../lib/README.md) 不变量 19）：不传参数 = 老行为（整份）；`limit=N` = **末尾** N 条；
    `before=<id>` = 只要更早的（游标 = 消息 id）；**`from=<下标>` = 从第几条起**（前端窗口"滑到哪加载哪"）；
    **`at=<id>` = 含这条消息的那一段**（定位一条早被窗口淘汰的消息）。任何一条路径都回 **`offset` = 这一页第一条的
    全局下标**——窗口据此把这一页放进槽位表，"滑块的全局长度口径"也来自同一套下标；`total` 如实给全量条数；
    单页上限 **2000** 条（防一次手滑拼出巨型 JSON）；`before` / `at` 找不到游标时**退回末尾一段**，
    **绝不静默返回整份**（"最坏情况传几 MB" 与"悄悄多传"都是要避免的）。

15. **临时员工名册接口：只读、按会话**（[core_server.dart](core_server.dart) 的 `_agentSubagents`，
    [test/subagents_api_test.dart](../../../test/subagents_api_test.dart) 强制）：
    `GET /api/agents/{agentId}/subagents?session_id=`（缺省会话同邻居口径）回 `{agent_id, session_id,
    total, subagents:[{id, name, owner_agent_id, session_id, parent_id, level, scope, run_count,
    created_at, updated_at}]}`——数据源就是那份落盘名册（`TreeStore.subagents` ⇒ `subagents.json`），
    **不含** `agent` 运行配置快照。**跨会话不保留**照旧：只回该 `(agentId, sessionId)`，删会话即随之消失，
    不新增任何跨会话存储；agent 不存在 ⇒ 404 + 可读原因。

## 测试

```bash
cd packages/tree_core
dart test test/server_test.dart test/ws_send_liveness_test.dart test/plugin_hot_apply_test.dart \
          test/subagents_api_test.dart \
          test/compact_api_test.dart test/agents_config_api_test.dart test/agent_delete_api_test.dart
```
