/// 集成终端（Ctrl+J）的 WS 帧。
///
/// 为什么走**已有的那条 WS**而不是新开一个端点：终端是交互式流，需要与心跳、
/// 重连、大帧分片共用同一套传输（新开一条就得再实现一遍重连与保活）。
///
/// 为什么输出用 base64 原始字节：终端输出是**字节流**——ANSI 控制序列、
/// 非 UTF-8 字节（中文代码页）、半截的多字节字符都会出现。JSON 里只能用字符串
/// 传，任何「先解码成 String」的做法都会把控制序列或半个字符改坏，所以按
/// base64 原样搬运，解码与渲染交给前端的 VT 解析器。
abstract final class TerminalFrame {
  /// 会话 id（**前端生成**，随 [TerminalInboundType.open] 带上；核心按它路由）。
  static const String terminalId = 'terminal_id';

  /// agent id：决定在哪个工作区里起 shell（成员跟随 leader，与文件面板同口径）。
  static const String agentId = 'agent_id';

  /// 要执行的命令（空 = 平台默认 shell）
  static const String command = 'command';

  /// 工作目录（核心回显实际使用的工作区根）
  static const String cwd = 'cwd';

  /// 实际起的 shell（核心回显，界面显示用）
  static const String shell = 'shell';

  /// 终端宽度（列）/ 高度（行）
  static const String columns = 'columns';
  static const String rows = 'rows';

  /// 终端输出：**base64 编码的原始字节**
  static const String bytes = 'bytes';

  /// 进程退出码
  static const String exitCode = 'exit_code';

  /// 可读错误文案（terminal_error 帧）
  static const String message = 'message';
}

/// 终端上行帧（前端 → 核心）。[WsInboundType] 里有同名字面量的别名。
abstract final class TerminalInboundType {
  /// 开一个终端会话（带 terminal_id 与 agent_id，可选 command / columns / rows）
  static const String open = 'terminal_open';

  /// 键盘输入（带 terminal_id 与 base64 的 bytes）
  static const String input = 'terminal_input';

  /// 改窗口尺寸（带 terminal_id、columns、rows）
  static const String resize = 'terminal_resize';

  /// 结束会话（带 terminal_id；核心关掉 PTY 并清理）
  static const String close = 'terminal_close';

  static const Set<String> all = <String>{open, input, resize, close};
}

/// 终端下行帧（核心 → 前端）。
abstract final class TerminalOutboundType {
  /// 会话就绪（回 terminal_id + cwd + shell，界面据此显示提示行）
  static const String ready = 'terminal_ready';

  /// 终端输出（terminal_id + base64 的 bytes）
  static const String output = 'terminal_output';

  /// 进程退出（terminal_id + exit_code；之后核心不再发该会话的输出）
  static const String exit = 'terminal_exit';

  /// 出错（terminal_id + message：起不来 / 远端没有可用 IO / PTY 不可用…）
  static const String error = 'terminal_error';

  static const Set<String> all = <String>{ready, output, exit, error};
}
