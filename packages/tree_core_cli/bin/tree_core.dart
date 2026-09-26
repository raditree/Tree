import 'dart:io';

import 'package:tree_core/tree_core.dart';

/// 核心进程入口（M0b 骨架）。
///
/// 最终形态（M1 起）：启动本地回环 HTTP + WS 服务，随机端口 + 随机本地 token，
/// 由 Flutter 桌面端作为子进程拉起（见迁移方案 §4）。当前仅打印自描述，
/// 便于在打包链路（`dart compile exe`）中先跑通。
void main(List<String> args) {
  if (args.contains('--version') || args.contains('-v')) {
    stdout.writeln(TreeCore.version);
    return;
  }
  stdout.writeln(TreeCore.describe());
  stdout.writeln('status: skeleton (M0b) — 回环服务将在 M1 落地');
}
