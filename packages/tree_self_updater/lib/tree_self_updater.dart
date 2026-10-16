/// 框架自迭代插件（`self_updater`）的对外 API。
///
/// 一句话：**把「热重启某个插件（包括重启我自己所在的插件）」做成一个 agent tool**，
/// 让 agent 能自行换一世而不断会话 —— 能力全在核心的执行站 `plugin.*` 命令里，
/// 本插件只是**转述者**（它不持有插件实例表、不判生死、也不碰快照池）。
///
/// 两层：
/// - **L1（核心 ⇄ 本插件）**：stdio 行分隔 JSON-RPC 2.0，核心是客户端，[SelfUpdaterLoop]
///   是服务端；工具经 `tools/list` **与**收集站 `plugin.tool.define` 双路申报（同一份
///   schema 常量），生命周期经 `suspend` + `plugin.stateDump` / `stateFetch` 续跑。
/// - **无 L2**：它不维护任何外部连接，所以没有隧道、没有台账、没有退避。
///
/// 为什么值得单开一个包而不是塞进核心内置工具：核心内置工具是"改核心才能加"的那一类，
/// 而这条能力的全部需求都在执行站点位表里已经有了（`system.execute.plugin`）。
library;

export 'src/plugin_methods.dart';
export 'src/self_updater_loop.dart';
export 'src/selftest.dart';
export 'src/tool_surface.dart';
