# terminal（集成终端 · Ctrl+J）

前端中栏底部的集成终端：真伪终端（PTY）会话，vim / top 这类全屏程序能跑，Ctrl+C 能打断。

| 文件 | 内容 |
| --- | --- |
| [pty_process.dart](pty_process.dart) | 伪终端会话的**最小接口** [PtyProcess] 与工厂签名 [PtyStarter]。平台实现（Windows ConPTY / POSIX pty）由 CLI 构造时注入：核心只依赖这个形状，就能独立编译与单测（注入假实现），换平台实现也不用动核心。 |
| [terminal_service.dart](terminal_service.dart) | 会话管理：`terminal_open/input/resize/close` 四条上行帧 → 起/写/改尺寸/收；把 PTY 的原始字节按 base64 回 **terminal_output**，进程退出回 **terminal_exit**，失败回可读的 **terminal_error**。 |

## 不变量（assertions）

1. **一个 terminal_id 一个进程，且只回给开它的那条连接**：终端是本机交互，不广播、不进消息库；同一个 id 重复 open 会**先收掉旧的**（前端重连场景），绝不静默叠出第二个 shell。
2. **输出是原始字节，不许解码**：PTY 输出含 ANSI 控制序列、非 UTF-8 字节与半截多字节字符，任何「先解码成 String」的做法都会改坏内容，所以按 base64 原样搬运（见 `TerminalFrame.bytes`），解码与渲染交给前端的 VT 解析器。
3. **失败一律可读，不假装成功**：核心没接线伪终端实现、找不到 agent、agent 配了 SSH、缺 terminal_id、起进程抛异常——五种情况都回 `terminal_error` + 中文 message，绝不让用户对着一个打不了字的终端猜。
4. **远端（SSH）agent 的交互终端不支持**：判据是「这个 agent 配了 SSH」（不是"远端后端接线了没有"）。SSH 通道只有一次性 exec，没有伪终端与流式会话；远端请用 agent 的 terminal 工具，或改用本地模式。
5. **不留下孤儿 shell**：连接断开（`closeForConnection`）、进程退出、核心关闭（`closeAll`）三条路径都会收掉伪终端；`close()` 幂等。
6. **协议常量只来自 tree_protocol**：四条上行 / 四条下行帧与字段名都在 [terminal.dart](../../../../tree_protocol/lib/src/terminal.dart)；完备性门禁要求核心**逐一显式处理**每种上行帧（不得被 default 静默忽略）。

## 测试

```bash
cd packages/tree_core
dart analyze lib test   # 必须零告警
dart test test/terminal_service_test.dart
```

`terminal_service_test.dart`（8 例）用**假 PTY**（注入 [PtyStarter]）覆盖：open 回 ready（cwd/shell/尺寸）、输出按 base64 原样过（含 ESC 序列）、input/resize 透传与越界夹取、进程退出回退出码并清理、close 幂等且不再转发、连接断开收掉全部会话、同 id 重复 open 先收旧、五条拒绝路径的可读文案。
