# Tasks

> 门禁顺序（每批必跑）：`dart analyze` 无新增 error/warning → 对应包全量 `dart test` → `tree_protocol` 契约测试 → 涉及前端才 `flutter test`。
> 每批一个提交；批次内先增后删，保证每个提交都可编译、可回退。

- [ ] Task 1: 片 A —— 协议面（只增不删）
  - [ ] SubTask 1.1: `ApiPaths` 新增 `/api/meta`、`/bootstrap`、`/api/bootstrap/session` 并入 `kept`
  - [ ] SubTask 1.2: `ws_inbound` / `ws_outbound` 新增 `ui.hello`、`station/subscribe`、`station/unsubscribe`、`station/trigger`、`station/register`、`station/unregister`、`station_delivery`
  - [ ] SubTask 1.3: 新增 `station_ws.dart`（帧值对象、`state` 四态、topic 约定）与 `meta.dart`（`/api/meta` 回包）
  - [ ] SubTask 1.4: 更新路径覆盖度与帧防漂移用例（`coreOwned ∪ delegated == kept`）

- [ ] Task 2: 片 B —— 站点总线接 WS + `/api/meta`
  - [ ] SubTask 2.1: 抽出 `StationSubscriberChannel`，stdio 与 WS 两个实现
  - [ ] SubTask 2.2: `ui.hello` 绑定连接身份（`plugin_id` 以 `plugins.yaml` 声明为准），非 ui 条目拒连
  - [ ] SubTask 2.3: 订阅白名单（仅广播）+ `topics[]` 过滤 + 空 scope 通配
  - [ ] SubTask 2.4: `station_delivery` 投递与有界队列（`data` / `closed` / `lagged` / `reset`）
  - [ ] SubTask 2.5: `GET /api/meta` 聚合路由、站点、UI 连接、能力、`can_manage_plugins`
  - [ ] SubTask 2.6: 用例覆盖订阅、拒订、身份不符、下线、背压、多连接

- [ ] Task 3: 片 C —— REST 委派（18 条）
  - [ ] SubTask 3.1: 新增内置收集站 `system.collect.api.routes`（六件同时交付）
  - [ ] SubTask 3.2: `DelegatedRouter` 接入 `core_server` 查表顺序（router → delegated → stub → 404）
  - [ ] SubTask 3.3: 新增 `api/delegate` RPC，信封含 `workspace_dir` / `data_dir` / `agent_id` / `team_id`
  - [ ] SubTask 3.4: 错误映射（503 / 503 / 504 / 502）与归属冲突整条拒收
  - [ ] SubTask 3.5: `body_path` / `result_path` 大体积通道与临时文件清理、路径越界校验
  - [ ] SubTask 3.6: 在 `tree-plugins` 交付后迁移 git 3 / spec 2 / mcp 2 / files 11，并同批删除核心实现
  - [ ] SubTask 3.7: 用例覆盖三态、schema 非法、冲突、100MB 上传下载内存基线

- [ ] Task 4: 片 D —— `runtime: headless | ui` + 依赖闸门
  - [ ] SubTask 4.1: `runtime` 收敛为 `headless | ui`；插件语言与执行形态不计入分类（任意 `command`），核心不按语言分支、不维护语言白名单；旧值（`ui` 之外任意值，如 `python`/`binary`）映射为 `headless` 并提示升级
  - [ ] SubTask 4.2: 新增 `UiHost`（拉进程 + 注入 `TREE_CORE_URL`/`TREE_CORE_TOKEN`，不做 stdio 握手、不注册站点）
  - [ ] SubTask 4.3: `_startOne` 按 `runtime` 分叉（headless → `PluginHost`，ui → `UiHost`）；`tools/list` 缺失不得导致上线失败，且不写专用日志、不生成占位能力
  - [ ] SubTask 4.4: `requires.plugins` 解析、安装前展示、启用闸门（409 + `missing_dependencies`）、版本求交、环检测、只补不升
  - [ ] SubTask 4.5: 卸载被依赖项时提示并连带停用依赖方
  - [ ] SubTask 4.6: 用例覆盖多 UI 并存、独立卸载、全停用、崩溃、无工具插件、依赖四场景

- [ ] Task 5: 片 E —— 引导壳 + 品牌 + 删除旧协议
  - [ ] SubTask 5.1: token 作用域注册表（scope / expires / singleUse），bootstrap 会话仅放行插件端点
  - [ ] SubTask 5.2: `GET /bootstrap` 送磁盘 HTML；`POST /api/bootstrap/session` 票据兑换即作废
  - [ ] SubTask 5.3: 新增引导页（仅插件管理：列表/刷新/装/卸/启停/重启/状态，轮询 `/api/meta`）
  - [ ] SubTask 5.4: loader 降为非 Flutter 极小进程：拉起核心、按判据开浏览器、托盘重签票据
  - [ ] SubTask 5.5: `system.collect.ui.branding` 收集站 + loader 应用窗口/托盘图标与快捷方式 `IconLocation`，含全部闸门与回退（不改写 exe 资源）
  - [ ] SubTask 5.6: 删除 UI 面板协议全链路（协议文件、bridge、registry、view、slots、`main_page` 接线、`plugin_ui_action`）
  - [ ] SubTask 5.7: 更新 `docs/plugin-development.md`（控件集描述漂移、站点为唯一贡献面）
  - [ ] SubTask 5.8: 用例覆盖引导页三形态、票据复用、越权、品牌回退与闸门、旧协议零残留

- [ ] Task 6: 片 F —— 日志与存储 API
  - [ ] SubTask 6.1: `GET /api/logs/sources`、`GET /api/logs/{source}`（尾部读，不整块载入）、`DELETE /api/logs/{source}`（清空并轮转）
  - [ ] SubTask 6.2: `GET /api/store/{ns}`（列键分页）+ `GET/PUT/DELETE /api/store/{ns}/{key}`，按 `plugin_id` 隔离、`etag` 冲突 409、配额
  - [ ] SubTask 6.3: 用例覆盖跨命名空间 403、冲突 409、配额、二进制原样存取

- [ ] Task 7: 收尾
  - [ ] SubTask 7.1: 按 `ui-pluginization_acceptance.md` §12 跑 12 项回归基线
  - [ ] SubTask 7.2: 记录逐批验收结果与 P0/P1 清零证据
  - [ ] SubTask 7.3: 确认批次 G（agent 25 条 + 核心工具注册表移除）不在本次实施范围，核心路由与工具链路保持现状至独立 spec

# Task Dependencies

- Task 2 依赖 Task 1
- Task 3 依赖 Task 1、Task 2
- Task 4 依赖 Task 1、Task 2
- Task 5 依赖 Task 2、Task 4
- Task 6 与 Task 2–5 无依赖，可并行（但需与 Task 5 的端点清单合并提交顺序）
- Task 3 的 SubTask 3.6 依赖仓外 `tree-plugins` 插件交付；未交付前不得删除核心实现
- Task 7 依赖 Task 1–6
