import 'package:flutter/material.dart';

import '../../app_version.dart';
import '../services/core_log_files.dart';
import 'core_log_viewer_dialog.dart';

/// 设置页「核心日志」卡片：把"核心到底干了什么"从"只能猜"变成"能打开能看"。
///
/// 为什么要有这个入口（2026-10-03）：核心是**独立进程**，它的日志原先只写 stderr，
/// 而发布版没有父进程转发（`flutter run` 才看得到）⇒ 用户遇到"压缩没生效 / 插件
/// 没接管 / 用量对不上"时零取证手段。核心现在已经把 stderr **双写**到
/// `<数据根>/logs/core.log`（见 `packages/tree_core/lib/src/util/core_log_sink.dart`），
/// 本卡片负责把那条路指给用户：**打开日志目录** + **看最近 N 行**。
///
/// 数据根来自握手的可选字段 `data_root`：拿不到（老核心 / 附着模式）时**不猜路径**，
/// 直接把"为什么没有入口"写在卡片上（按钮禁用而不是报错）。
class CoreLogCard extends StatelessWidget {
  const CoreLogCard({super.key, this.logFile});

  /// 日志文件路径（**测试注入用**；null = 从核心启动器读当前运行态）。
  final String? logFile;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String path = CoreLogFiles.resolveLogFile(override: logFile);
    final bool available = path.isNotEmpty;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '核心日志',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              '核心进程（对话 / 压缩 / 插件 / MCP / SSH 的日志）同时写在它的 stderr 与'
              '数据根下的 core.log，按 8 MiB × 5 份轮转。'
              '发布版看不到 stderr，出问题时从这里的落盘副本取证。',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                FilledButton.icon(
                  key: const Key('core-log-tail'),
                  onPressed: available ? () => _showTail(context, path) : null,
                  icon: const Icon(Icons.receipt_long_outlined, size: 16),
                  label: Text('查看最近 ${CoreLogFiles.defaultLines} 行'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const Key('core-log-open-dir'),
                  onPressed: available ? () => _openLogDir(context, path) : null,
                  icon: const Icon(Icons.folder_open_outlined, size: 16),
                  label: const Text('打开日志目录'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              available
                  ? path
                  : '当前核心没有提供数据根（老版本核心，或应用附着在外部核心上）：'
                        '日志只在核心进程的 stderr 里，应用侧无法代读。',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTail(BuildContext context, String path) => showCoreLogDialog(
    context,
    logFile: path,
  );

  Future<void> _openLogDir(BuildContext context, String path) async {
    final String? error = await PluginDocs.openPath(
      CoreLogFiles.logDirOf(path),
    );
    if (!context.mounted || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error), duration: const Duration(seconds: 4)),
    );
  }
}
