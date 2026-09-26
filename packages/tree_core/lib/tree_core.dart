/// Tree 桌面端核心进程（M0b 骨架）。
///
/// 设计约束（见 desktop 迁移方案 §5）：
/// - **纯 Dart**：不依赖 Flutter，可用 `dart compile exe` 独立分发；
/// - **单进程单事件循环**：原 server 的"生成器 + to_thread + 线程安全队列"
///   改为 `Stream` + `await`；
/// - 面向 Flutter UI 暴露**本地回环 HTTP + WS**（协议见 tree_protocol），
///   使 lib/ui 无需改动。
///
/// 后续里程碑在此逐步落地：store（M2）/ llm（M3）/ tool（M4）/ agent（M5）/
/// plugin+mcp（M6）。
library;

import 'package:tree_protocol/tree_protocol.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 核心版本与骨架自描述（M0b 占位，供 CLI 与测试断言）。
abstract final class TreeCore {
  /// 核心包版本。
  static const String version = '0.1.0';

  /// 协议里保留的 REST 路径数量（骨架自检用）。
  static int get keptApiPathCount => ApiPaths.kept.length;

  /// 本机执行原语可用性（M4 前仅报告实现分组数）。
  static String describe() => 'tree_core $version '
      '(apiPaths=${ApiPaths.kept.length}, '
      'inbound=${WsInboundType.all.length}, '
      'outbound=${WsOutboundType.all.length}, '
      'execBackends=${TreeLocalExec.backendCount})';
}
