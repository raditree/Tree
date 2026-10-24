# 核心收束与 UI 插件化 Spec

> 配套设计事实来源：[docs/pluginization/ui-pluginization.md](../../docs/pluginization/ui-pluginization.md)、[ui-pluginization_detailed.md](../../docs/pluginization/ui-pluginization_detailed.md)、[ui-pluginization_acceptance.md](../../docs/pluginization/ui-pluginization_acceptance.md)、[agent_pluginization.md](../../docs/pluginization/agent_pluginization.md)。实施时若与设计文档冲突，先改文档再改代码。

## Why

当前核心同时承担「插件平台」与「agent 领域」两类职责，Flutter 界面与核心强绑定，无法替换或卸载。把 UI 与领域能力外移后，核心退化为插件型超级应用的调度内核，新增界面或功能不再需要核心发版。

## What Changes

- 插件分类改为 `runtime: headless | ui` 两档；插件语言与执行形态不再是清单分类维度（python、原生可执行体、npx、其他解释器/包管理器均只是举例），统一由既有 `command` + `args` 承载
- 站点总线向 WS 客户端开放：订阅广播站、接收 `station_delivery`；发布仍限自建站
- REST 委派注册表：插件申报 `{method, pattern}`，核心在未命中路由时转发（18 条领域端点可搬走）
- 新增 `GET /api/meta` 作为唯一发现面（聚合已委派路由、可订站点、UI 连接与能力）
- 新增日志 API 3 条、数据存储 API 4 条
- 新增不可卸载的极小 loader 与 HTML 引导壳（`/bootstrap` + 一次性票据兑换）
- 插件清单新增 `requires.plugins` 与 `runtime: ui`；启用前做依赖闸门
- 新增内置收集站 `system.collect.api.routes` 与 `system.collect.ui.branding`
- **BREAKING**：删除旧 UI 面板协议（`plugin_ui_*` 帧、`PluginUiBridge`、前端槽位体系）
- **BREAKING**：`tools/list` 不再是插件上线的硬要求，且核心不为此新增任何接口、占位能力或专用日志；工具注册表的整体移除归入 agent 插件化 spec

## Impact

- 影响规格：插件清单与生命周期、站点协议、HTTP 路由、WS 协议、前端渲染入口
- 影响代码：`packages/tree_protocol`、`packages/tree_core`、`lib/`（前端）、`tool/package_windows.dart`、`docs/plugin-development.md`
- 仓外依赖：`tree-plugins` 仓交付 git / spec / mcp / files / tree.agent 插件
- 不在本次范围：agent 25 条端点的实际迁移（批次 G，需 agent 插件先交付，另开 spec）

## ADDED Requirements

### Requirement: UI 插件类型

系统 SHALL 支持 `runtime: "ui"` 的插件条目，与 `runtime: "headless"` 条目共用分发、落盘、启停、热重启、卸载管道。

#### Scenario: 多个 UI 并存
- **WHEN** 两个 `runtime: ui` 条目同时启用
- **THEN** 两个进程各自拉活并连上 WS，`/api/meta.ui` 返回两条记录，互不影响

#### Scenario: 卸载运行中的 UI
- **WHEN** 用户卸载正在运行的 UI 插件
- **THEN** 进程先退出、文件随后可删除，其他插件不受影响

#### Scenario: 未实现 tools/list 不阻断上线
- **WHEN** 插件未实现 `tools/list`
- **THEN** 插件仍正常上线；核心不为其生成占位能力、不写专用日志（工具注册表属 agent 领域，见 REMOVED Requirements）

### Requirement: 站点 WS 订阅

系统 SHALL 允许已 `ui.hello` 的 WS 连接订阅**广播站**，并以 `station_delivery` 投递。

#### Scenario: 订阅并接收
- **WHEN** UI 订阅某自建广播站，插件随后发布事件
- **THEN** UI 收到 `state:"data"` 的投递，携带 `topic` 与 `origin_plugin_id`

#### Scenario: 权限白名单
- **WHEN** UI 尝试订阅中转站、执行站或收集站
- **THEN** 三类均返回可读拒绝，不建立订阅

#### Scenario: 站点下线
- **WHEN** 插件下线或其站点注销
- **THEN** 订阅者收到 `state:"closed"` 与原因

#### Scenario: 背压
- **WHEN** 单连接队列溢出
- **THEN** 核心发送 `state:"lagged"` 并附 `from_seq`，不静默丢帧

### Requirement: 发现面

系统 SHALL 提供 `GET /api/meta`，返回 `core_version`、`api_version`、已委派路由、可订阅站点、当前 UI 连接及能力、`can_manage_plugins`。

#### Scenario: 插件扩展 UI 可用面
- **WHEN** 插件申报新路由或注册自建广播站后 UI 重新读取 `/api/meta`
- **THEN** 返回集合相应增长，核心不存在第二份静态清单

### Requirement: REST 委派

系统 SHALL 在核心未命中已实现路由与桩路由后，按插件申报的归属表转发请求。

#### Scenario: 正常委派
- **WHEN** 请求命中已申报路由且归属插件在位
- **THEN** 核心转发并原样返回状态码与响应体

#### Scenario: 失败可读
- **WHEN** 归属插件未安装 / 已停用 / 超时 / 回包非法
- **THEN** 分别返回 503 / 503 / 504 / 502，`reason` 说明具体原因（**不得 404**）

#### Scenario: 归属冲突
- **WHEN** 两家插件申报同一 `method+pattern`
- **THEN** 该条整条拒收并记录原因，不按启动顺序择一

#### Scenario: 大体积传输
- **WHEN** 上传或下载超过阈值
- **THEN** 走 `body_path` / `result_path`，核心内存不整块驻留，结束后清理临时文件

### Requirement: 引导壳

系统 SHALL 在无「能管插件的存活 UI 连接」时进入引导模式，提供仅含插件管理能力的 HTML 页面。

#### Scenario: 全部 UI 卸载
- **WHEN** 所有 UI 插件被卸载或停用后启动
- **THEN** loader 存活并打开 `/bootstrap?t=<票据>`

#### Scenario: 仅剩无管理能力的 UI
- **WHEN** 只有未声明 `plugin.manage` 的 UI 连接（如悬浮球）
- **THEN** 仍打开引导页

#### Scenario: 能力条目被停用
- **WHEN** 存在声明了 `plugin.manage` 的条目但未启用
- **THEN** 仍打开引导页；静态声明与历史声明不作为判据

#### Scenario: 票据一次性
- **WHEN** 同一票据被再次使用
- **THEN** 返回 401 可读原因；会话 token 仅放行插件端点且有有效期

### Requirement: 日志与存储 API

系统 SHALL 提供日志源枚举 / 尾部读取 / 清空，以及按 `plugin_id` 隔离的键值存储（`etag` 乐观锁、配额）。

#### Scenario: 命名空间隔离
- **WHEN** 插件访问非自身 `plugin_id` 的命名空间
- **THEN** 返回 403，且不泄露该命名空间是否存在

### Requirement: 插件依赖

系统 SHALL 解析 `requires.plugins` 并在启用前做闸门，支持手动与自动补齐。

#### Scenario: 缺依赖拒绝启用
- **WHEN** 非 optional 依赖未安装或版本不符
- **THEN** 返回 409 与结构化 `missing_dependencies`，进程不启动

#### Scenario: 自动安装只补不升
- **WHEN** 用户选择自动安装依赖
- **THEN** 仅补齐缺失项，不升级既有插件；版本区间取交集，无交集或成环时可读失败

#### Scenario: 卸载连带
- **WHEN** 卸载被依赖的插件并确认
- **THEN** 依赖方被停用而非卸载

### Requirement: 品牌申报

系统 SHALL 通过 `system.collect.ui.branding` 收集 UI 插件申报的图标，最后到达者生效。

#### Scenario: 生效与回退
- **WHEN** 第二个 UI 连上并申报图标
- **THEN** 图标切换到后者；后者卸载后回退到前者；全部撤回回默认

#### Scenario: 闸门
- **WHEN** 图标超过体积、尺寸不足、路径在插件目录外或为 URL
- **THEN** 拒收并可读原因，不用旧图兜底

## MODIFIED Requirements

### Requirement: WS 协议

服务端下行新增 `station_delivery`；客户端上行新增 `ui.hello`、`station/subscribe`、`station/unsubscribe`；`station/trigger` 对 UI 仅允许自有自建广播站。

### Requirement: 插件清单

清单 `runtime` 取值收敛为 `headless | ui` 两档；**插件语言与执行形态完全无关**——python、原生可执行体、npx、其他解释器或包管理器都只是举例，统一由 `command` + `args` 承载，核心不按语言分支、也不维护语言白名单。同时新增可选 `requires.plugins`；未知字段保持保留。

#### Scenario: 旧清单兼容
- **WHEN** 清单 `runtime` 写的是 `ui` 之外的任意旧值（如 `python` / `binary`）
- **THEN** 一律按 `headless` 解释并提示"清单待升级"，不阻断安装与启动

#### Scenario: 任意语言插件
- **WHEN** 清单以 `command` 指向任意解释器、原生可执行体、包管理器或自定义启动器（如 `npx ...`、`python x.py`、`my_plugin.exe`）
- **THEN** 核心一律按 headless 插件启动，不做语言区分，也不要求清单声明语言

## REMOVED Requirements

### Requirement: 工具注册表（核心内建）

**Reason**：工具是 agent 领域的表达，不属于「插件平台 + 日志 + 存储」三类核心能力。核心只应提供站点与委派，不应认识「工具」这一概念。
**Migration**：由 agent 插件化 spec 负责——插件把可被 agent 使用的能力暴露为执行站 / 收集站，agent 插件经 `station/trigger` 调用；核心侧 `tools/list`、`tools/call`、工具表与 `plugin_tool` 随之删除。本次范围仅保证「未申报工具的插件不因此上线失败」，不新增任何工具相关接口或日志。

### Requirement: UI 面板协议

**Reason**：与站点体系重复，且把 UI 表达限制在白名单控件集内。
**Migration**：插件改为发布自建广播站；UI 改为订阅广播站 + 调用委派端点。`tree-plugins` 仓的 `ssh_executor` 面板在同批次迁移。
