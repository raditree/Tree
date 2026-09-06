# SSH IO 工具链性能与稳定性评估 Spec

## Why

SSH IO 工具链（后端 `SSHWorkspaceIO` → 反向 WebSocket 委托 → 前端 dartssh2 执行）在
高负载场景下的鲁棒性尚未经过系统化验证。当前架构关键事实：

- SSH 连接由**前端（Flutter + dartssh2）按 top_agent_id 懒建立并缓存**（[ssh_connection_manager.dart](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/lib/io/ssh_connection_manager.dart) 的 `_clients` map，无显式容量上限）。
- 后端经 [local_executor.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/io_/local_executor.py) 的 `request()` 阻塞配对 `tool_exec_request` / `tool_exec_response`（`concurrent.futures.Future`，120s 超时、冷启动 15s 探测、连续 2 次超时自动停用）。
- WebSocket 连接按 user 管理，每用户可多连接（[ws_manager.py](file:///e:/programs/Tree/flutter_application_tree/flutter_application_tree/server/ws/ws_manager.py)）。

**审查边界（分层）：** 工具链分三层——①上游库（dartssh2 / paramiko）为**黑盒依赖**，协议与传输稳定性不属审查范围（我们无法修改，压测库本身无意义）；②前端薄包装（`SshConnectionManager` / `SshExecutorService` / `SshWorkspaceExecutor`，约 700 行自研代码）只做**逻辑正确性验证**（建连竞态、归属过滤、清理路径），不做大规模压测；③**后端委托链是审查重心**——`local_executor.py` 请求/响应配对生命周期、`ws_manager.py` 连接管理、`ws/endpoints.py` 注册路由、`mode_resolver.py` 互斥判定。

初步走查已发现的后端风险点（待专项验证）：
- `unregister`/`unregister_ssh` 按 `f"{user_id}:"` 前缀失效 pending，注销一个 top agent 会连带失败同用户**所有** agent 的进行中请求（跨 agent 误伤）。
- `_last_ok` / `_consecutive_timeouts` 为用户级粒度且 local/SSH 共用，一个 agent 超时会污染另一个 agent 的冷启动探测与自动停用判定。
- `_run_async` 兜底每次新建单线程池，高并发下有线程创建风暴风险。
- `WebSocketManager.send_message` 逐连接串行 `await`，单个慢连接拖慢同用户全部投递，无背压控制。
- 前端包装层 `connect()` 无 in-flight 合并，并发首次建连同一 agent 会产生重复连接并泄漏至 transport 失活。

需要全面评估其在 **300+ 并发连接**、**7×24 耐久运行（万级工具调用）**、**多 agent 资源竞争**
（同 top agent 下多 teammates）等极端条件下的稳定性，专项排查连接池耗尽、内存泄漏、
异常处理、资源释放、死锁/竞态五类风险点，产出实测数据、问题分析与优化建议。

## What Changes

- 新增**后端委托链静态审计**：以清单方式逐项审查 pending 生命周期、失效影响面、计数粒度、线程池使用、WS 投递路径、注册/注销竞态、hook 路径。
- 新增基于 paramiko 的**嵌入式 SSH 测试服务器**（127.0.0.1:2222，支持 exec/SFTP、并发限制与故障注入）。
- 新增**统一指标采集模块**：连接建立/释放时间、延迟分位（p50/p95/p99）、吞吐量、错误率、进程 RSS、CPU%、网络收发字节，JSONL 落盘。
- 新增**后端转发层压测脚本**：300+ 并发 WS 模拟前端连接 + 并发工具调用驱动（真实走 `request()` → WS → 模拟前端 → SSH 执行链路）。
- 新增**前端包装层逻辑验证**（dartssh2 视为黑盒上游依赖，不做库级压测）：建连竞态/去重、归属过滤、清理与重建路径的小规模正确性用例。
- 新增**多 agent/teammates 资源竞争测试**：同 top agent 多 teammates 并发 exec/SFTP，校验路径映射隔离与无死锁/竞态。
- 新增**异常注入与风险点专项测试**：WS 断连、SSH 服务器被杀、响应超时风暴、无响应前端、跨 agent 注销误伤，检查 `_pending`/`_clients` 是否泄漏、自动停用是否生效、资源是否及时释放。
- 新增**耐久性压测脚本**（面向 7×24 设计、可长跑，周期采样指标；执行期内运行代表性时长作为实测数据来源，完整 7×24 提供方法论）。
- 输出**详细测试报告** `docs/test_report_ssh_io_toolchain.md`：环境配置、用例设计、实测数据、问题分析、优化建议。
- 对测试发现的**阻塞性/高危问题**实施修复并复测（如发现；仅限威胁稳定性关键项）。

## Impact

- Affected specs: 新增「SSH IO 工具链压测与稳定性评估」能力；不改动既有产品行为（评估优先）。
- Affected code:
  - 测试资产（新增）：`server/tests/ssh_perf/`（SSH 测试服务器、指标采集、压测/竞争/异常/耐久脚本）、`test/`（Dart 侧包装层逻辑用例）。
  - 审计资产（新增）：`server/tests/ssh_perf/audit_checklist.md`（后端委托链走查清单与结论）。
  - 文档（新增）：`docs/test_report_ssh_io_toolchain.md`。
  - 产品代码（按发现修复）：`server/io_/local_executor.py`、`server/ws/ws_manager.py`、`lib/io/ssh_connection_manager.dart` 等。

## ADDED Requirements

### Requirement: 后端委托链静态审计（审查重心）

以走查清单方式逐项审查后端委托链逻辑正确性，每项给出 结论 + 代码依据 + 影响面。

#### Scenario: 审计清单逐项结论
- **WHEN** 按清单审查 `local_executor.py`（pending 插入/弹出/兜底清理路径、失效影响面、`_last_ok`/`_consecutive_timeouts` 粒度、`_run_async` 线程池、hook 注册/取消路径）、`ws_manager.py`（连接增删、死连接清理、串行投递背压）、`ws/endpoints.py`（注册/注销/响应路由竞态）、`mode_resolver.py`（互斥判定）
- **THEN** 每项得出 通过/缺陷 结论；缺陷项附复现场景与严重程度，并纳入 Task 动态验证

### Requirement: 前端包装层逻辑验证（黑盒上游库）

dartssh2 为黑盒上游依赖，不压测库本身；仅验证自研包装层（约 700 行）的逻辑正确性。

#### Scenario: 包装层竞态与生命周期
- **WHEN** 以小规模并发用例驱动 `SshConnectionManager.connect()`（同 agent 并发首次建连）、归属过滤（`top_agent_id` 不匹配时放行）、`cleanup`/`disable` 清理路径、transport 失活重建路径
- **THEN** 无重复连接泄漏、无跨 agent 误接管、清理后无残留客户端；用例纳入 `test/`（Dart 侧）

### Requirement: 嵌入式 SSH 测试服务器

提供可控、可注入故障的 SSH 测试目标，供压测脚本（Python paramiko 客户端与 Dart dartssh2 客户端）连接。

#### Scenario: 正常监听与执行
- **WHEN** 启动 `ssh_test_server.py`
- **THEN** 监听 127.0.0.1:2222，支持密码认证、exec 命令（返回 stdout/stderr/exit_code）与 SFTP 文件操作（open/read/write/mkdir/stat/listdir），并可通过 `--max-connections` 限制并发连接数

#### Scenario: 故障注入
- **WHEN** 测试脚本发起注入指令（限速、延迟、主动断连、停止服务）
- **THEN** 服务器按指令执行，用于验证工具链在远端异常下的降级与恢复行为

### Requirement: 300+ 并发连接压力测试

模拟 300+ 并发连接请求，验证连接池资源、并发配对与错误率。

#### Scenario: 并发连接与并发工具调用
- **WHEN** 300+ 个模拟前端（每用户 1 条 WS + 1 个 SSH 执行器）同时连接并持续发起工具调用
- **THEN** 记录连接建立/释放时间、吞吐量、错误率；全部请求在超时窗口内得到结果，无悬挂、无崩溃

#### Scenario: 高并发下连接池资源检查
- **WHEN** 压测进行中及结束后检查
- **THEN** 后端 `_pending` 未来对象无残留、`WebSocketManager.connections` 与模拟前端数一致、SSH 服务器并发连接数不超上限且随释放回收

### Requirement: 7×24 耐久性测试

在持续运行环境下处理万级工具调用，验证长期稳定性与资源趋势。

#### Scenario: 持续混合负载运行
- **WHEN** 耐久脚本按既定 QPS 混合（read/write/exec/grep/git）连续运行（面向 7×24，执行期内运行代表性时长）
- **THEN** 每周期记录指标；内存 RSS 与连接/配对残留量不随运行时间线性增长（无泄漏）、错误率保持稳定、无死锁

### Requirement: 多 agent 资源竞争测试

同 top agent 下多 teammates 并发操作同一 SSH 会话时的竞态资源处理。

#### Scenario: 同会话多通道并发
- **WHEN** 同一 top agent 的 K 个 teammates 并发执行 exec 与 SFTP（含并发 `mkdir` 同目录）
- **THEN** 全部并发操作完成且结果正确；路径映射正确（top→`remote_base_dir`，成员→`remote_base_dir/workspaces/{workspace_id}`）；无死锁、无跨工作空间串扰、无 SFTP 句柄泄漏

### Requirement: 风险点专项检查

针对五类风险点（连接池耗尽/内存泄漏/异常处理/资源释放/死锁竞态）给出明确结论（是否存在、严重程度、复现步骤）。

#### Scenario: 五类风险点逐一验证
- **WHEN** 执行专项用例（超时风暴、无响应前端、杀 SSH 服务器、WS 断连、重复注册/注销、**跨 agent 注销误伤**、关闭不释放等）
- **THEN** 每类风险点得出 通过/不通过 结论，不通过项记录复现与影响面

### Requirement: 性能指标采集

统一采集并落盘关键性能指标。

#### Scenario: 指标记录与汇总
- **WHEN** 各压测场景运行期间及结束后
- **THEN** 输出 JSONL 原始数据与汇总统计（连接建立/释放时间、吞吐、错误率、延迟分位、内存趋势、CPU、网络收发），指标口径在报告中说明

### Requirement: 测试报告

提供可复现、可审计的完整测试报告。

#### Scenario: 报告产出
- **WHEN** 全部测试执行与分析完成
- **THEN** `docs/test_report_ssh_io_toolchain.md` 包含：测试环境配置、测试用例设计、实测数据（含图表/表格）、问题分析（含五类风险点结论）、优化建议

### Requirement: 关键问题修复（条件性）

对威胁稳定性的关键问题实施最小化修复并复测。

#### Scenario: 修复与复测
- **WHEN** 测试发现阻塞性/高危问题（如配对泄漏、资源未释放、死锁）
- **THEN** 实施最小范围修复；修复后重跑对应用例验证通过，并在报告中记录修复前后对比

## MODIFIED Requirements

（无）

## REMOVED Requirements

（无）
