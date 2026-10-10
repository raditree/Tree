# tree_tunnel_protocol

SSH 执行器「中转站」协议的**共享定义**：方法名、错误码、帧编解码、版本常量。

## 为什么单独一个包

这套协议有**三个**实现端：

| 端 | 包 | 角色 |
|---|---|---|
| 核心传输层 | `tree_local_exec` 的 `TunnelSshTransport` | 把 `SshTransport` 的 16 个方法映射成 L1 请求 |
| 中转站 | `tree_ssh_plugin` | 一条常驻 SSH 通道，把 L1 请求转发成 L2 请求 |
| 目标机执行体 | `tree_agent` | 真正干活的那个（在目标机 Linux 上跑） |

三端各自手写方法名字符串必然漂移，而这类漂移**只在真机上才暴露**（单测各写各的都能过）。
所以常量与帧编解码只放这一处。

## 内容

| 文件 | 内容 |
|---|---|
| [lib/src/constants.dart](lib/src/constants.dart) | `kTunnelProtocolVersion` / `kAgentProtocolVersion` / `kAgentVersion`（`--define` 注入）/ 方法名（`TunnelMethods` / `AgentMethods`）/ 错误码（`TunnelErrorCodes`）/ 状态（`TunnelStates` / `BackgroundStates`）/ 失败分类（`TunnelErrorKinds`）/ `normalizePosixPath` / `isWithinRoot` |
| [lib/src/frame.dart](lib/src/frame.dart) | `encodeFrame`（行分隔 JSON + 16 MiB 上限）、`LineFrameDecoder`（增量解码：分片 / 多帧 / `\r` / 坏帧只报错 / 超长行丢弃） |
| [lib/src/rpc.dart](lib/src/rpc.dart) | `rpcRequest` / `rpcNotification` / `rpcResult` / `rpcErrorResult` / `rpcUnwrap` / `RpcException` / `RpcIds` / `describeRpcCode` / `shouldFallbackForErrorKind` |

## 不变量（assertions）

1. **零运行时依赖、不依赖 Flutter、不做任何 IO** —— 只允许"常量 + 纯函数"。
   理由：它要进目标机二进制（体积）与中转站（启动时间），且必须能在 Windows 开发机上单测。
2. **路径归一化手写、不引 `package:path`**：`normalizePosixPath` 必须与 `p.posix.normalize`
   在关键用例上一致（有测试钉住），但**不受宿主平台影响**——测试跑在 Windows、生产跑在 Linux，
   两侧行为必须逐字一致。
3. **帧层不含 RPC 语义**：`LineFrameDecoder` 只把字节流切成 JSON 对象；请求/响应/通知的判别
   与错误处理在 `rpc.dart` 与各端自己那里。
4. **坏帧不许把通道搞哑**：非法 UTF-8 / 非法 JSON / 非对象 / 超长行 —— 一律"报错 + 丢弃该帧 +
   读循环继续"（唯一例外是超长行必须丢到下一个换行，否则会把半个 JSON 当两帧）。

## 测试

```bash
cd packages/tree_tunnel_protocol && dart test
dart analyze lib test
```
