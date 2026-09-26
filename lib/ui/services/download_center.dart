import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../io/api_service.dart';

/// 下载任务类型（M8d）。
enum DownloadKind { file, folder }

/// 下载任务状态。
enum DownloadStatus { running, done, failed, cancelled }

/// 一条下载任务。
///
/// **来源 team 是必填**：同一个列表里会混着不同 agent 工作空间的产物，
/// 不标来源用户根本分不清这个文件是从哪个 agent 下的。
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.kind,
    required this.name,
    required this.sourceTeam,
    required this.sourceTeamId,
    this.savePath = '',
    this.totalBytes = 0,
  });

  final String id;
  final DownloadKind kind;

  /// 文件名（目录下载是 `<名字>.tar.gz`）。
  final String name;

  /// 来源 team 的显示名（顶部 agent 名）；为空时界面上退回 [sourceTeamId]。
  final String sourceTeam;

  /// 来源 team 的 id（顶部 agent id）。
  final String sourceTeamId;

  /// 落盘路径（文件下载为用户选择的完整路径；文件夹为保存对话框返回的路径）。
  String savePath;

  /// 总字节数（-1 或 0 = 未知）。
  int totalBytes;

  /// 已传字节数。
  int transferred = 0;

  DownloadStatus status = DownloadStatus.running;

  /// 失败原因（可读中文）。
  String error = '';

  final DateTime startedAt = DateTime.now();
  DateTime? finishedAt;

  bool get isRunning => status == DownloadStatus.running;

  /// 来源标签（界面上显示的"来自哪个 team"）。
  String get sourceLabel => sourceTeam.isNotEmpty ? sourceTeam : sourceTeamId;

  /// 0~1；总长未知时为 null（界面上用不确定进度条）。
  double? get progress {
    if (totalBytes <= 0) return null;
    return (transferred / totalBytes).clamp(0.0, 1.0);
  }

  String get statusText {
    switch (status) {
      case DownloadStatus.running:
        return totalBytes > 0
            ? '${_mb(transferred)} / ${_mb(totalBytes)}'
            : '已接收 ${_mb(transferred)}';
      case DownloadStatus.done:
        return '完成（${_mb(transferred)}）';
      case DownloadStatus.failed:
        return '失败：$error';
      case DownloadStatus.cancelled:
        return '已取消';
    }
  }

  static String _mb(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}

/// 全局下载中心（M8d）：左侧活动栏「下载」面板的数据源。
///
/// 为什么放在 UI 侧而不是核心：下载是**前端发起、前端落盘**的动作（核心只把字节
/// 流回来），任务的生命周期与进度天然属于界面；核心不需要知道用户存到了哪。
class DownloadCenter extends ChangeNotifier {
  DownloadCenter._();

  /// 全局单例（UI 直接取用，与其它 *Service 一致）。
  static final DownloadCenter instance = DownloadCenter._();

  final List<DownloadTask> _tasks = <DownloadTask>[];
  int _seq = 0;

  /// 最新任务在前。
  List<DownloadTask> get tasks =>
      List<DownloadTask>.unmodifiable(_tasks.reversed.toList());

  int get runningCount => _tasks.where((DownloadTask t) => t.isRunning).length;

  bool get hasFinished => _tasks.any((DownloadTask t) => !t.isRunning);

  /// 新建一个任务（处于 running）。
  DownloadTask begin({
    required DownloadKind kind,
    required String name,
    required String sourceTeam,
    required String sourceTeamId,
    String savePath = '',
    int totalBytes = 0,
  }) {
    final DownloadTask task = DownloadTask(
      id: 'dl_${++_seq}',
      kind: kind,
      name: name,
      sourceTeam: sourceTeam,
      sourceTeamId: sourceTeamId,
      savePath: savePath,
      totalBytes: totalBytes,
    );
    _tasks.add(task);
    notifyListeners();
    return task;
  }

  void progress(DownloadTask task, int received, int total) {
    task.transferred = received;
    if (total > 0) task.totalBytes = total;
    notifyListeners();
  }

  void complete(DownloadTask task, {String? localPath, int? totalBytes}) {
    if (localPath != null && localPath.isNotEmpty) task.savePath = localPath;
    if (totalBytes != null && totalBytes > 0) task.totalBytes = totalBytes;
    if (task.totalBytes > 0) task.transferred = task.totalBytes;
    task.status = DownloadStatus.done;
    task.finishedAt = DateTime.now();
    notifyListeners();
  }

  void fail(DownloadTask task, String error) {
    task.status = DownloadStatus.failed;
    task.error = error;
    task.finishedAt = DateTime.now();
    notifyListeners();
  }

  /// 取消：置状态，传输循环下一块就会发现并把半成品删掉。
  void cancel(DownloadTask task) {
    if (!task.isRunning) return;
    task.status = DownloadStatus.cancelled;
    task.finishedAt = DateTime.now();
    notifyListeners();
  }

  void remove(DownloadTask task) {
    _tasks.remove(task);
    notifyListeners();
  }

  void clearFinished() {
    _tasks.removeWhere((DownloadTask t) => !t.isRunning);
    notifyListeners();
  }

  /// 文件下载的后台任务：拉流 → 落盘 → 更新任务状态（M8c 的流式下载）。
  ///
  /// 由调用方先选好保存目录再调；失败/取消都不抛给 UI（状态在任务里）。
  Future<void> startFileDownload({
    required String workspaceId,
    required String path,
    required String savePath,
    required String name,
    required String sourceTeam,
    required String sourceTeamId,
    String teamId = '',
  }) async {
    final DownloadTask task = begin(
      kind: DownloadKind.file,
      name: name,
      savePath: savePath,
      sourceTeam: sourceTeam,
      sourceTeamId: sourceTeamId,
    );
    try {
      await ApiService.downloadFileTo(
        workspaceId,
        path,
        savePath,
        teamId: teamId,
        onProgress: (int received, int total) =>
            progress(task, received, total),
        isCancelled: () => task.status == DownloadStatus.cancelled,
      );
      if (task.status == DownloadStatus.cancelled) return;
      complete(task, localPath: savePath);
    } on DownloadCancelledException {
      await _deletePartial(task);
    } on Exception catch (error) {
      if (task.status == DownloadStatus.cancelled) {
        await _deletePartial(task);
        return;
      }
      fail(task, error.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 取消后把半成品删掉，别让用户以为下完了。
  Future<void> _deletePartial(DownloadTask task) async {
    if (task.savePath.isEmpty) return;
    try {
      final File file = File(task.savePath);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉就算了：状态已经是「已取消」，不因为清理失败再报错
    }
  }
}
