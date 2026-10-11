/// agent 保活 / 静默退出的**成组常数**。
///
/// 这三个数与 `kAgentIdleTimeoutMs` 必须成组理解（改一个就得看另一个）：
///
/// - 插件在隧道 `ready` 期间**一直**按 [kAgentPingInterval] 发 `agent.ping`；
/// - 单次 ping 的响应窗口是 [kAgentPingTimeout]，连续 [kAgentPingMissLimit] 拍没响应
///   就认定"通道已死"（agent 卡死 / 链路黑洞）⇒ 拆掉重建（**后台任务不受影响**，
///   它们在目标机 `setsid` 独立跑、退出码与台账都落在目标机磁盘上）；
/// - agent 侧按 spawn 时传的 `--idle-timeout-ms`（见 [kAgentIdleTimeoutMs]）做**静默自杀**。
library;

/// 插件发 `agent.ping` 的间隔。
const Duration kAgentPingInterval = Duration(seconds: 20);

/// 单次 `agent.ping` 的响应窗口（超过就当这一拍没响应）。
const Duration kAgentPingTimeout = Duration(seconds: 10);

/// 连续多少拍无响应 ⇒ 认定通道已死，拆掉重建。
const int kAgentPingMissLimit = 3;

/// 目标机 agent 的**静默上限**（spawn 命令里总是显式传 `--idle-timeout-ms`）。
///
/// 为什么必须大于 [kAgentPingInterval]：agent 只要收到**任何一帧**就重置自己的静默计时，
/// 而插件在 `ready` 期间一直 ping ⇒ **健康链路上的 agent 永远到不了这个上限**
/// （这条有单测钉住，见 `test/tunnel_keepalive_test.dart`）。
///
/// 为什么需要它：**物理断网**时对端 sshd 收不到 FIN，那条会话与 agent 的 stdin 管道都还在
/// ⇒ agent 收不到 EOF、会一直挂在 read 上（老实现就是这样，`--idle-timeout-ms` 缺省 0 = 永不），
/// 于是"重连后目标机上多出一个旧执行器"，反复抖动还会累积。
/// 用户 2026-10-11 的口径是"**执行器应该自觉优雅结束**"——它唯一的线索就是
/// "这么久没有任何帧进来"，到点自己退出；新执行器照旧从落盘台账认领并接管全部后台任务。
///
/// 取 90s ≈ 4×ping 间隔 + 余量：容忍连续两拍丢包，同时把孤儿 agent 的寿命压到分钟以内
/// （对比 sshd 的 TCP 超时是分钟到十几分钟）。
const int kAgentIdleTimeoutMs = 90000;
