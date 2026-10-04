# util（跨模块小工具）

没有业务语义、却被多个模块共同依赖的五件事：**token 口径、id、时间编解码、心跳活性台账、核心日志出口**。

## 文件

| 文件 | 作用 |
| --- | --- |
| [tokens.dart](tokens.dart) | **全局唯一的 token 估算口径**：`ceil(字符数 / token_scale)` 与默认比例 |
| [token.dart](token.dart) | 回环 HTTP / WS 的一次性 token 生成与校验 |
| [ids.dart](ids.dart) | id 生成 `<prefix>_<epoch_ms>_<rand6>_<seq>` |
| [json_time.dart](json_time.dart) | 毫秒 ↔ ISO-8601（两种写法都收） |
| [liveness.dart](liveness.dart) | 通用心跳台账 `LivenessTracker` + `LivenessLostException` |
| [core_log_sink.dart](core_log_sink.dart) | 核心日志出口 `CoreLogSink`：stderr + `<数据根>/logs/core.log` 双写、**落盘行带时间戳与 pid**、按大小轮转、失败降级 |

## 不变量（assertions）

1. **token 口径只有这一处**：上下文进度、压缩阈值、工具结果门控、工具参数计量全部走 [tokens.dart](tokens.dart)。口径一旦分叉，就会出现"进度条说没超、端点却报超限"这种没法排查的现象。
2. token 是**逐模型标量** `token_scale`（存 `models/<id>.yaml`），能被端点回传的真实 `prompt_tokens` 持续校准；**不再**按 CJK / ASCII 细分——那两个系数是拍出来的、与端点分词器无关。默认 2.0 刻意偏保守：低估会让人以为还装得下，直到端点直接 400。
3. **取消静态时间超时**（M9 规约 1.1）：判据只有**心跳丢失**，窗口 = I × N（默认 10s × 3）。`staleWindow` 是"多久没有心跳"，**不是**"总共跑了多久"——心跳还在，跑多久都算活着。
4. `LivenessTracker` **只记心跳 / 记丢失 / 唤醒在途操作**：不主动中断、不关连接、不知道如何重连；恢复（`recordBeat` / `reset`）后失活标记自动清除。
5. `LivenessLostException` 的文案必须**同时**含「心跳丢失」与「链路失活」——日志、UI 与测试都靠这两句话识别，不依赖具体实现。
6. id 不用 UUID 包：核心进程零第三方依赖，便于 `dart compile exe` 产单文件。
7. 回环 token 32 字节熵、base64url 无填充，**只经 stdout 握手行**交给父进程：不落盘、不复用。
8. **核心日志只有一个出口**（[core_log_sink.dart](core_log_sink.dart)）：新日志一律 `coreLog.forPrefix('core:xxx')`，
   不要自己 `stderr.writeln`（那条永远不落盘）；出口本身**永不抛异常、永不阻塞调用方**——磁盘满、目录只读、
   stderr 已关闭都不得影响核心功能（失败只提示一次并降级为纯 stderr）。**落盘行带行首时间戳**：
   `<ISO8601 带时区> pid=<pid> <原行>`（例 `2026-10-05T07:24:31.123+08:00 pid=4242 [core:tool] …`）——
   同一数据根可能同时有"App 拉起的核心"与"开发期自起的核心"在写，`pid` 用来归因；**时间戳用来对时**
   （曾经因为文件行只有 pid、没有时间，排查一次 SSH 链路失活只能靠会话消息的时间戳反推）。
   时间戳**只加在文件行上**：stderr 那份逐字保持原样（`flutter run` / `--verbose` 照旧，按 stderr 断言的测试也不受影响）。

## 测试

```bash
cd packages/tree_core
dart test test/tokens_test.dart test/liveness_tracker_test.dart test/util_test.dart test/token_pacer_test.dart
dart test test/core_log_sink_test.dart     # 日志出口：双写 / 轮转 / 失败降级
```
