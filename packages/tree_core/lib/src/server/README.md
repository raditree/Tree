# server（回环 HTTP + WS 服务）

核心的对外门面：路由表、鉴权、响应编码、WS 连接活性。**只监听 127.0.0.1**、零第三方依赖（要能 `dart compile exe` 单文件分发）。

## 文件

| 文件 | 作用 |
| --- | --- |
| [core_server.dart](core_server.dart) | 路由注册 + WS 帧分发 + 鉴权；provider 接线（Spec 快照 / 团队工作目录 / 执行站挂载）与 `close()` 解绑 |
| [http_router.dart](http_router.dart) | 极简路由表：精确路径 + `{name}` 占位符 |
| [http_io.dart](http_io.dart) | UTF-8 JSON 响应助手 |
| [ws_liveness.dart](ws_liveness.dart) | 带发送活性与**待补发队列**的 WS 连接与注册表（`LivenessWsHub`） |

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

## 测试

```bash
cd packages/tree_core
dart test test/server_test.dart test/ws_send_liveness_test.dart test/plugin_hot_apply_test.dart \
          test/compact_api_test.dart test/agents_config_api_test.dart
```
