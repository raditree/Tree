/// Tree 桌面端协议常量（冻结现状 server 的 REST/WS 契约）。
///
/// 本包是 desktop 分支迁移期的**单一事实来源**：tree_core（Dart 独立进程）、
/// Flutter UI（lib/）与迁移期扫描测试三方共用同一组常量，避免字符串散落。
///
/// 迁移完成后（M7 删除 server/）本包仍保留，但完备性测试中的
/// "对照 Python 源码" 部分应替换为前端侧断言。
library;

export 'src/api_paths.dart';
export 'src/core_event.dart';
export 'src/core_handshake.dart';
export 'src/non_protocol_literals.dart';
export 'src/ws_frame.dart';
export 'src/ws_inbound.dart';
export 'src/ws_outbound.dart';
