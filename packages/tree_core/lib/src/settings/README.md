# settings（设置、模型池与 SSH 配置）

用户配置的读写：全局设置、逐模型配置、per-agent 的 SSH 段。三条都是"用户可直接手改"的入口。

## 文件

| 文件 | 作用 |
| --- | --- |
| [core_settings.dart](core_settings.dart) | 设置集合与 `CoreModelConfig`（含心跳参数与跨字段约束） |
| [file_settings_sink.dart](file_settings_sink.dart) | 落盘实现：`config/settings.yaml` + `config/models/<id>.yaml` |
| [ssh_config.dart](ssh_config.dart) | `agents/<id>.yaml` 的 `ssh:` 段解析与脱敏 |

## 不变量（assertions）

1. **api_key 永不回显**：`CoreModelConfig.toApiJson` 剥掉密钥并把 `base_url` 脱敏成"协议 + 主机"（与既有后端一致，避免密钥经 UI / 日志泄漏）；`PATCH` 时空的 `base_url` / `api_key` 表示**保留原值**。
2. **手改友好**：读取用宽容转换（手写 `"true"` / `1` 也生效）；**未知键原样保留**在 `extra` 并写回——用户自己加的配置项不会被界面操作悄悄抹掉。
3. 模型文件里 **api_key 是明文**：桌面单用户形态下用户必须能直接看到并替换自己的密钥，靠操作系统用户目录权限保护；`dart:io` 不提供跨平台 chmod，因此**不以"600 权限"承诺安全性**。
4. 写入是 **write-behind**（每文件串行），`flush()` 等待落盘。
5. **心跳参数的跨字段约束**：窗口 I × N 必须**严格大于**前端固定的 10s WS 心跳（`minLivenessWindowSeconds`）；`setLiveness` 在写入时强制满足，采用**夹取而不拒绝**，并把原因写进 `livenessNotice`（拒绝会让调用方拿到一个"设了但没生效"的静默失败）。
6. 各心跳消费者（WS 判活 / 插件宿主 / MCP 客户端 / SSH 链路）**默认**从这里取值——避免四处各写一个窗口，又各自判活。
7. `SshConfig.redacted` 只暴露"谁连哪台机器"，**永不带密钥**：日志、错误文案、自检输出一律用它。`parse` 宽容读手写 YAML（端口可写字符串、`key_path` 支持 `~`），但**必填项缺失返回 null**，由调用方给出可读错误。

## 测试

```bash
cd packages/tree_core
dart test test/settings_test.dart test/file_settings_sink_test.dart test/ssh_config_test.dart \
          test/heartbeat_settings_test.dart
```
