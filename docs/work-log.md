# Work Log（过去式）

> 这里只记**已经做完的事**：结论 + 关键数字 + 提交号 + 原文档。
> 阶段把控与当前事项在 [project-status.md](project-status.md)；本文件不写待办。
> 约定：新的在上；一条一行；细节一律引原文档或提交，不在这里复述。
> 归档：超过 300 行时，把最老的一段移到 `docs/archive/work-log-<阶段>.md`。

---

## 2026-11-08

- **项目状态入口上线**：阶段模型（快速/稳定性/发版/维护/大版本）、待办总表、维护规则生效。
  提交 `4dc823b`、`9d1174d`；文档 [project-status.md](project-status.md)。
- **UI 移仓方案定稿**：语义（核心只认 `ui`/`headless`、接口由插件自注册）、零依赖（UI 自持
  `protocol_contract.dart`）、核心面 43→35（删 `store/*`、`logs/*`、`data-collection`）、
  S1–S9 分片与回滚。提交 `70d6c9c`、`bae779d`、`91ad646`；文档
  [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md)。
- **测试基线全绿**：根仓 909、tree_core 675、tree_protocol 68、tree_agent 89、
  tree_local_exec 295、tree_tunnel_protocol 15、tree_core_cli 4、tree_launcher 11；
  `dart analyze` 零新增。修好 cli 端到端三处历史失效断言（探活改用 `/api/meta`、
  子进程对象不再重建、目录骨架只断言核心自有目录、teardown 先杀进程）。提交 `d5ae71d`。
- **发消息/作答/停止改走 REST 委派端点**：A5 起核心不再处理 WS `user_message` / `stop` /
  `user_answer`；补 `error` 帧提示，新建会话回包 `session_id` 即切换。提交 `7d6d742`。
- **插件面板与磁盘状态对齐**：订阅 `plugin_config_changed`、重新可见时重拉清单；
  停用态只给「启用」；依赖按 `configs` 键读本机状态并支持一键补全；agent 列表启动期
  退避重试（计时器可取消）。提交 `18732e7`。
- **插件发布源与安装链修复**：发布源设置（令牌只回 `token_set`，保存即热应用）、
  下载阶段也按源顺序回退、配置写入统一审计并广播、`with_dependencies` 补齐缺失依赖、
  停用态 restart 先启用后过闸门。提交 `658e9e2`。
- **核心单实例 + 默认界面 + 发行布局**：`runtime/core.json` 实例发现、loader 优先附着、
  首启按同目录 `tree_ui.exe` 登记默认界面、打包链改名 `tree_ui.exe`、引导页种子带构建号。
  提交 `91eac9d`。

## 2026-11-02

- **会话存储 Sembast 化 + 中栏折叠 F1–F4**：显示/详细双 store（显示缓存上限 10000，
  详情点击即查）、有工具即折叠、全局仅一个折叠组展开、TC-COLLAPSE-01 零位移通过。
  提交 `2d2f9e8`、`70248b2`、`c6a6a0d`、`f9cc17a`；文档
  [conversation-sembast-and-collapse-recon.md](conversation-sembast-and-collapse-recon.md)。
