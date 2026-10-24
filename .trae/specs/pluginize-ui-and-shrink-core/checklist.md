# Checklist

## 协议与站点

- [x] 新增路径与帧全部落在 `tree_protocol`；路径覆盖度用例满足 `implemented ∪ stubs == kept`（stub 空），`ApiPaths.delegated` 18 条全部 ⊆ `kept`（实现代码里没有 `coreOwned` 概念）
- [x] 删除或改名任一核心路径、改编任一帧名时契约测试变红（新 7 个站点帧的线名由 `station_ws_test` 钉死；旧帧由完备性用例覆盖）
- [x] `ui.hello` 身份以 `plugins.yaml` 声明为准，未声明为 `runtime: ui` 的连接被拒
- [x] 空 scope 订阅收全量；`topics[]` 过滤生效
- [x] 订阅中转 / 执行 / 收集站均被可读拒绝
- [x] 插件下线时订阅者收到 `state:"closed"` 及原因
- [x] 队列溢出发出 `state:"lagged"` 且附 `from_seq`，无静默丢帧
- [x] `station_delivery` 携带 `topic` 与 `origin_plugin_id`；UI 发布他人站被拒

## 委派

- [x] 18 条端点已划入 `ApiPaths.delegated` 委派白名单；核心实现按 SubTask 3.6 暂留，待 `tree-plugins` 交付后同批删除
- [x] 归属插件停用 / 下线 ⇒ 503，超时 504，回包非法 502，原因可读；未申报或归属已销账的路径仍回 404（"未安装不得 404"的 C-2 与运行期归属模型冲突，见验收报告）
- [x] 归属冲突整条拒收，不按启动顺序择一
- [x] 委派信封含 `workspace_dir` / `data_dir` / `agent_id` / `team_id`
- [x] 100MB 上传与下载走 `body_path` / `result_path`：信封不含内联体、文件字节精确、分块流式回写、结束清理（同进程测试无法可靠采样 RSS，以结构断言替代，理由写在用例头）
- [x] 插件返回越界 `result_path` 被拒收

## 插件类型与依赖

- [x] `runtime` 分类只有 `headless | ui` 两档，`PluginRuntime.parse` 不按语言枚举白名单；新清单与运行期均无语言分支（`plugin_downloader` 的 `runtime: python` 解释器探测只服务于旧清单兼容，不参与分类）
- [x] 旧清单中 `ui` 之外的取值归一化为 `headless + legacy` 并在快照暴露 `runtime_legacy`；旧值本身不阻断安装（legacy `python` 缺解释器时按既有工程约定给出可读原因并拒绝写入注定起不来的配置）
- [x] `runtime: ui` 条目共用既有安装 / 卸载 / 启停 / 热重启管道
- [x] 两个 UI 并存、独立卸载、全停用时核心仍健康
- [x] `UiHost` 不发 `tools/list`、不注册站点、不进入状态池
- [x] 未实现 `tools/list` 的插件仍正常上线，且核心未因此新增工具相关接口、占位能力或专用日志
- [x] 缺依赖时启用返回 409 与结构化 `missing_dependencies`，进程未启动
- [x] 自动安装仅补齐缺失，不升级既有插件
- [x] 版本区间无交集、依赖成环时均可读失败并列出原因
- [x] 卸载被依赖项后依赖方被停用而非卸载

## 引导壳与品牌

- [x] 零 UI 连接、仅有无法管插件的 UI、能力条目被停用，三种形态均打开引导页
- [x] 静态声明 `plugin.manage` 不抑制引导页
- [x] 票据二次使用返回 401；引导会话 token 仅放行插件端点且有有效期
- [x] 引导页装回 UI 后能自动拉起并通过 `/api/meta` 提示可关闭（核心侧安装即热启用；页面每 3s 轮询 meta）
- [x] 图标申报最后到达者生效，撤回后回退上一条，全部撤回回默认
- [x] 图标闸门（体积、尺寸、目录逃逸、URL）全部拒收并可读
- [x] 图标文件被删除后回默认并记日志，不出现破图
- [x] 应用品牌不改写 exe：核心只读图标并记账，loader 仅更新 `Tree.lnk` 的 `IconLocation`（无品牌/非 ico 时清空回默认）；窗口/托盘图标由 UI 插件自己应用

## 日志与存储

- [x] 日志三端点可用，尾部读取不整块载入
- [x] 存储跨命名空间返回 403 且不泄露存在性
- [x] `etag` 冲突返回 409；配额超限可读失败
- [x] 存入任意二进制/JSON 可原样取回，核心不解析值

## 删除与回归

- [x] 代码与随包资源（`lib/` / `test/` / `packages/` / `tool/` / `assets/`）无 `plugin_ui_manifest` / `plugin_ui_action` / `PluginUiRegistry` / `PluginUiView` / `plugin_ui_view` 残留引用（历史 docs 保留记述）
- [x] `docs/plugin-development.md` 控件集描述已修正，并写明「站点是唯一贡献面」
- [x] 12 项回归基线：10 项有自动化单元/契约/widget 覆盖且全绿；真实 PTY（ConPTY/SSH）与 OS 多窗口两项在本环境无法自动验证，已在验收报告标注为人工项
- [x] 批次 G 明确不在本次范围，核心 agent 路由保持现状且已记录为独立 spec
- [x] 六批各一个独立提交（`ab8d5cb`/`a5f626a`/`711cd7b`/`816646a`/`a23a0b8`/`e85b7e2`），工作区干净；回退单位即单条 `git revert <sha>`（未做实际演练）
