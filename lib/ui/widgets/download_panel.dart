import 'package:flutter/material.dart';

import '../services/download_center.dart';
import '../services/file_reveal.dart';

/// 左侧活动栏「下载」面板（M8d）。
///
/// 列出全部下载任务（单文件走流式、文件夹是 tar.gz），**每条都标来源 team**：
/// 同一个列表里会混着不同 agent 工作空间的产物，不标来源就分不清是哪个 agent 下的。
///
/// 每行提供「打开文件所在位置」（M9 Q7）：文件夹任务保存的是 tar.gz，定位到的
/// 就是这个压缩包本身；产物已被移动/删除时给 SnackBar 提示而不是静默失败。
class DownloadPanel extends StatelessWidget {
  const DownloadPanel({super.key, this.onCollapse});

  /// 内容下方空白区点击折叠左栏（与 Agent / 插件面板一致）。
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final DownloadCenter center = DownloadCenter.instance;
    return AnimatedBuilder(
      animation: center,
      builder: (BuildContext context, _) {
        final List<DownloadTask> tasks = center.tasks;
        return Column(
          children: <Widget>[
            _buildHeader(context, center, tasks),
            Divider(
              height: 1,
              thickness: 1,
              color: Theme.of(context).dividerColor,
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: onCollapse,
                child: tasks.isEmpty
                    ? _buildEmpty(context)
                    : ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: tasks.length,
                        separatorBuilder: (BuildContext context, int index) =>
                            Divider(
                              height: 1,
                              thickness: 1,
                              color: Theme.of(context).dividerColor,
                            ),
                        itemBuilder: (BuildContext context, int index) =>
                            _buildRow(context, center, tasks[index]),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(
    BuildContext context,
    DownloadCenter center,
    List<DownloadTask> tasks,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int running = center.runningCount;
    return Container(
      height: 36,
      color: cs.surface,
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: <Widget>[
          Text(
            running > 0 ? '下载（$running 进行中）' : '下载',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const Spacer(),
          if (center.hasFinished)
            TextButton(
              onPressed: center.clearFinished,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(fontSize: 12),
              ),
              child: const Text('清空已完成'),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.download_outlined, size: 40, color: cs.outline),
          const SizedBox(height: 8),
          Text('还没有下载任务', style: TextStyle(fontSize: 13, color: cs.outline)),
          const SizedBox(height: 4),
          Text(
            '在文件面板右键文件/文件夹选「下载」',
            style: TextStyle(fontSize: 11, color: cs.outline),
          ),
        ],
      ),
    );
  }

  /// 打开文件所在位置（M9 Q7）。
  ///
  /// 文件夹任务的 [DownloadTask.savePath] 就是保存对话框选定的 tar.gz 完整路径，
  /// 因此这里原样交给 [FileReveal]——不做"取父目录/去掉扩展名"的处理。
  Future<void> _revealInFileManager(
    BuildContext context,
    DownloadTask task,
  ) async {
    // await 之前取好 messenger，避免异步间隙后再用 context
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? error = await FileReveal.reveal(task.savePath);
    if (error == null) return;
    messenger.showSnackBar(
      SnackBar(content: Text(error), duration: const Duration(seconds: 3)),
    );
  }

  Widget _buildRow(
    BuildContext context,
    DownloadCenter center,
    DownloadTask task,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color statusColor = switch (task.status) {
      DownloadStatus.running => cs.primary,
      DownloadStatus.done => const Color(0xFF10B981),
      DownloadStatus.failed => const Color(0xFFEF4444),
      DownloadStatus.cancelled => cs.outline,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                task.kind == DownloadKind.folder
                    ? Icons.folder_zip_outlined
                    : Icons.insert_drive_file_outlined,
                size: 18,
                color: statusColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: cs.onSurface),
                ),
              ),
              // 打开文件所在位置（M9 Q7）：运行中也留可用——单文件下载落盘
              // 中途路径就已存在，能直接看到进度产出的那个文件
              IconButton(
                tooltip: '打开文件所在位置',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: () => _revealInFileManager(context, task),
                icon: const Icon(Icons.folder_open),
              ),
              if (task.isRunning)
                IconButton(
                  tooltip: '取消',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => center.cancel(task),
                  icon: const Icon(Icons.close),
                )
              else
                IconButton(
                  tooltip: '移除',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => center.remove(task),
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
          if (task.isRunning) ...<Widget>[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: task.progress,
                minHeight: 3,
                backgroundColor: cs.surfaceContainerHighest,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Icon(Icons.groups_outlined, size: 12, color: cs.outline),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '来自 ${task.sourceLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.outline),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  task.statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, color: statusColor),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
