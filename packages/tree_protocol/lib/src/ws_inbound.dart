import 'plugin_rpc_methods.dart';
import 'terminal.dart';

/// WebSocket **上行**消息类型（前端 → 核心进程）。
///
/// 对应 `server/ws/endpoints.py::register_ws` 的 `msg_type` 分发链，共 12 种。
/// 桌面分支中这些帧改走本地回环 WS（M1），类型与字段保持不变。
abstract final class WsInboundType {
  /// 心跳保活（前端每 10s 一次；必须小于核心判活窗口 I×N = 30s）。
  static const String heartbeat = 'heartbeat';

  /// 用户消息（顶层 agent 会话入口）。
  static const String userMessage = 'user_message';

  /// 停止当前 agent（含成员级联）。
  static const String stop = 'stop';

  /// 回答提问（ask_user_question 的应答）。
  static const String userAnswer = 'user_answer';

  /// 取消提问。
  static const String cancelQuestion = 'cancel_question';

  // 说明（M7c）：桌面端工具由**核心进程本机执行**，因此原先的
  // `register_*_executor`（注册前端执行能力）与 `tool_exec_response` /
  // `tool_exec_progress`（反向执行结果回报）整套上行帧已删除——它们描述的
  // "前端执行器"不存在了。插件宿主同理（核心自己拉起插件进程）。

  // 片 E：旧 UI 面板协议的动作上行已删除；前端不再有插件槽位，
  // 插件的功能扩展只走调用点 REST / 广播订阅。

  // ── 集成终端（Ctrl+J） ────────────────────────────────────────────────
  // 值复用 [TerminalInboundType.*]（**别名**，不重复字面量），见 terminal.dart。

  /// 开一个终端会话。
  static const String terminalOpen = TerminalInboundType.open;

  /// 键盘输入。
  static const String terminalInput = TerminalInboundType.input;

  /// 改窗口尺寸。
  static const String terminalResize = TerminalInboundType.resize;

  /// 结束会话。
  static const String terminalClose = TerminalInboundType.close;

  // ── UI 插件 · 站点（WS 侧，插件化新增）──────────────────────────────
  // **命名风格**：这六条按设计文档 §3.2 使用「点号 / 斜杠」形态，而不是本文件
  // 历史帧的 snake_case。原因是它们与插件 stdio RPC 的方法名**同名同义**
  // （`PluginRpcMethods.station*`），两侧共用一套叫法才能让 UI 与普通插件看到
  // 同一个协议面；改成 snake_case 等于换协议（旧客户端会静默不认）。
  // 其中五条 `station/*` 直接以 [PluginRpcMethods] 的常量为**别名**，不重复字面量。

  /// UI 连接自我声明：`{plugin_id, version, capabilities[]}`。
  static const String uiHello = 'ui.hello';

  /// 订阅站点（WS 侧只允许广播站，可选 `topics[]`）。
  static const String stationSubscribe = PluginRpcMethods.stationSubscribe;

  /// 退订站点。
  static const String stationUnsubscribe = PluginRpcMethods.stationUnsubscribe;

  /// UI 注册自建站（只允许广播类型）。
  static const String stationRegister = PluginRpcMethods.stationRegister;

  /// 注销自建站。
  static const String stationUnregister = PluginRpcMethods.stationUnregister;

  /// 向**自己注册的**自建广播站发布事件（不得触发收集站 / 执行站）。
  static const String stationTrigger = PluginRpcMethods.stationTrigger;

  // ── UI 插件 · 生命周期握手（热重启续跑，2026-11-26）──────────────────
  // 为什么这三个名字不带 `station/`：它们不是站点事务（没有订阅 / 回执码），
  // 而是**生命周期原语**在 WS 侧的那条传输——与 stdio 插件的 `suspend` /
  // `plugin.stateDump` / `plugin.stateFetch` 同义，只是 UI 不能下
  // `station/command`（UI 只做 API 消费者），所以换一条同样有明确目标与回执的路。
  //
  // 契约（`docs/pluginization/ui-hot-restart-recon.md` §4.2）：
  // 1. 只对**已完成 `ui.hello`** 的连接有效；
  // 2. `plugin.suspend` 只发给 `ui.hello.capabilities` 含 `ui.lifecycle` 的连接；
  // 3. 同 `(plugin_id, window_id)` 的**首条 ack 生效**，重复 ack 丢弃并记一行；
  // 4. 未声明能力的旧构建收不到 `plugin.suspend` ⇒ 核心按冷重启处理，不是错误。

  /// 挂起应答 + 本窗口的视图状态切片（UI → 核心）。
  ///
  /// 帧形状：`{type, data: {ok, dumped, window_id, plugin_id, bytes?, payload?, error?}}`。
  /// [payload] 对核心**不透明**（只校验是 JSON 对象与字节上限），核心不解释字段。
  static const String pluginSuspendAck = 'plugin.suspendAck';

  /// 全部上行类型（完备性测试与文档用）。
  static const Set<String> all = <String>{
    heartbeat,
    userMessage,
    stop,
    userAnswer,
    cancelQuestion,
    terminalOpen,
    terminalInput,
    terminalResize,
    terminalClose,
    uiHello,
    stationSubscribe,
    stationUnsubscribe,
    stationRegister,
    stationUnregister,
    stationTrigger,
    pluginSuspendAck,
  };
}
