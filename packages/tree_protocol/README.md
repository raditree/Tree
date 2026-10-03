# tree_protocol

**协议单一真源**：WS 帧类型、REST 路径、进程握手、插件 UI 帧、流式序号。核心与前端都只引用这里，
不写字面量。纯 Dart、无依赖。

## 内容

| 文件 | 内容 |
| --- | --- |
| [lib/src/api_paths.dart](lib/src/api_paths.dart) | 全部 REST 路径常量 + 完备性清单（`all`） |
| [lib/src/ws_inbound.dart](lib/src/ws_inbound.dart) · [ws_outbound.dart](lib/src/ws_outbound.dart) | WS 上行 / 下行帧类型 |
| [lib/src/ws_stream_seq.dart](lib/src/ws_stream_seq.dart) | 流式增量的单调序号与封口水位（断线重播去重） |
| [lib/src/core_handshake.dart](lib/src/core_handshake.dart) | 父进程 ↔ 核心的单行 JSON 握手（`{port, token, pid, version, data_root?}`）解析 |
| [lib/src/plugin_ui.dart](lib/src/plugin_ui.dart) | 插件 UI 槽位 / 动作帧（4.1 card 槽位复用） |

## 不变量（assertions）

1. 协议常量**只在这里定义**；核心与前端不得出现同样的字符串字面量。
2. 新增 REST 路径必须同时加进完备性清单，否则门禁测试失败。
3. 帧类型集合无重复、非空；改名等于破坏兼容（前端与插件都依赖它）。
4. 握手必须是**单行 JSON**，且父进程解析时允许核心先输出普通日志行（解析失败不能视为致命）。
   可选字段（如 `data_root`）必须**向后兼容**：老核心不给 ⇒ 空串默认值，老前端收到多余键必须不报错。
5. 流式序号单调递增；`msg_end` 前必须封口（水位语义见 `WsStreamSeq`）。

## 测试

```bash
cd packages/tree_protocol && dart test     # 完备性与常量集合门禁
dart analyze lib test
```
