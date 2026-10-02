# terminal（集成终端 · Ctrl+J）

前端中栏底部的集成终端：真伪终端（PTY）会话，vim / top 这类全屏程序能跑，Ctrl+C 能打断。
**本机与远端（SSH）都支持**：本机走平台 PTY（ConPTY / POSIX），远端走 SSH 会话通道 + `pty-req`。

| 文件 | 内容 |
| --- | --- |
| [pty_process.dart](pty_process.dart) | 伪终端会话的**最小接口** [PtyProcess] 与工厂签名 [PtyStarter]。平台实现（Windows ConPTY / POSIX pty）由 CLI 构造时注入：核心只依赖这个形状，就能独立编译与单测（注入假实现），换平台实现也不用动核心。 |
| [terminal_service.dart](terminal_service.dart) | 会话管理：`terminal_open/input/resize/close` 四条上行帧 → 起/写/改尺寸/收；把 PTY 的原始字节按 base64 回 **terminal_output**，进程退出回 **terminal_exit**，失败回可读的 **terminal_error**。两个注入点：本机 [PtyStarter]、远端 [SshPtyStarter]（判据是**有效 SSH**，见不变量 4）。 |
| [local_pty_starter.dart](local_pty_starter.dart) | 把 tree_local_exec 的**平台伪终端**（`PtySession`）接到 [PtyProcess]。 |
| [ssh_pty_adapter.dart](ssh_pty_adapter.dart) | 把 tree_local_exec 的**远端 shell 通道**（`SshShellChannel`，dartssh2 会话通道 + `pty-req`）接到 [PtyProcess]；通道来源 [SshShellOpener] 由 CLI 注入（它从缓存的 `SshWorkspaceIO` 取，**复用同一条 SSH 连接**）。远端根归 `SshWorkspaceIO`，核心不解析远端路径。 |

## 不变量（assertions）

1. **一个 terminal_id 一个进程，且只回给开它的那条连接**：终端是本机交互，不广播、不进消息库；同一个 id 重复 open 会**先收掉旧的**（前端重连场景），绝不静默叠出第二个 shell。
2. **输出是原始字节，不许解码**：PTY 输出含 ANSI 控制序列、非 UTF-8 字节与半截多字节字符，任何「先解码成 String」的做法都会改坏内容，所以按 base64 原样搬运（见 `TerminalFrame.bytes`），解码与渲染交给前端的 VT 解析器。
3. **失败一律可读，不假装成功**：核心没接线本机伪终端、没接线远端伪终端、找不到 agent、缺 terminal_id、起进程抛异常、远端 sshd 拒绝 `pty-req`——每一种都回 `terminal_error` + 中文 message，绝不让用户对着一个打不了字的终端猜；**也绝不退回另一条后端**（远端没接线时不许偷偷在本机起一个）。
4. **远端（SSH）支持，判据是「有效 SSH」**：`teamSshConfigFor(agent, store.agent) != null`（成员跟随团队 TOP 的 SSH，见 [team_workspace.dart](../team/team_workspace.dart)），**不是** `agent.sshConfig`——只看后者会把"SSH leader 的成员"误判成本机，在**本机**起一个终端（真实 bug，见 [docs/known-issues.md #12](../../../../../docs/known-issues.md)）。远端分支走注入的 SSH 会话通道 + `pty-req`（真 PTY，vim / top / Ctrl+C 都能跑），端点实现见 tree_local_exec 的 `SshShellChannel`。远端工作目录与远端根由 `SshWorkspaceIO` 解决，核心不解析、也不回传本机路径（远端分支的 `terminal_ready.cwd` 是空串）。边界：远端 sshd 必须允许 `shell` / `pty-req`（`PermitTTY no` 会回可读错误）；**远端分支没有真机验证过**，只有假通道单测（见 [docs/known-issues.md #12](../../../../../docs/known-issues.md)）。
5. **不留下孤儿 shell**：连接断开（`closeForConnection`）、进程退出、核心关闭（`closeAll`）三条路径都会收掉伪终端；`close()` 幂等。
6. **协议常量只来自 tree_protocol**：四条上行 / 四条下行帧与字段名都在 [terminal.dart](../../../../tree_protocol/lib/src/terminal.dart)；完备性门禁要求核心**逐一显式处理**每种上行帧（不得被 default 静默忽略）。

## 测试

```bash
cd packages/tree_core
dart analyze lib test   # 必须零告警
dart test test/terminal_service_test.dart
```

`terminal_service_test.dart`（13 例）用**假 PTY**（注入 [PtyStarter] / [SshPtyStarter]）覆盖：open 回 ready（cwd/shell/尺寸）、输出按 base64 原样过（含 ESC 序列）、input/resize 透传与越界夹取、进程退出回退出码并清理、close 幂等且不再转发、连接断开收掉全部会话、同 id 重复 open 先收旧、六条拒绝路径的可读文案；**远端分支**另有五例：SSH agent 走远端（起 SSH 通道、本机 `created` 为空、cwd 是空串、输入/输出/退出/关闭同样工作）、成员跟随 SSH leader 也走远端、跟随本机 TOP 的成员仍走本机（cwd = `files.rootFor`）、远端没接线回可读错误且不起本机 PTY、远端起会话失败回可读错误。真实 dartssh2 通道与真 sshd 不在本文件的覆盖范围内（假通道契约见 tree_local_exec 的 `ssh_shell_channel_test`）。
