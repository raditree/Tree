import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../../io/platform_support.dart';

/// 文件同步按钮组件
///
/// 提供两个按钮："同步到本地"（选择本地目录后下载工作空间文件）和
/// "上传到云端"（选择本地文件后上传到工作空间）。点击后通过 file_picker
/// 选择目标路径，然后调用对应 API 完成同步，同步过程通过对话框展示进度。
///
/// 当前后端同步接口暂未实现（返回 501），UI 会提示"功能开发中"。
class FileSyncButton extends StatelessWidget {
  /// 工作空间 ID
  final String workspaceId;

  /// 所属顶层 agent ID（后端三模式分派判定键：本地/SSH/云端）
  final String teamId;

  /// 上传成功后的回调（用于通知文件面板刷新）
  final VoidCallback? onUploaded;

  const FileSyncButton({
    super.key,
    required this.workspaceId,
    this.teamId = '',
    this.onUploaded,
  });

  /// 同步到本地
  ///
  /// 调用 file_picker 选择本地目录，然后调用 [ApiService.syncToLocal]
  /// 下载工作空间文件。同步期间展示进度对话框。
  /// 移动端不支持目录选择（file_picker.getDirectoryPath 仅桌面），直接提示。
  Future<void> _syncToLocal(BuildContext context) async {
    if (isMobile) {
      _showUnsupported(context);
      return;
    }
    // 选择本地目录
    final String? dirPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择本地保存目录',
    );
    if (dirPath == null) return; // 用户取消选择

    // ignore: use_build_context_synchronously
    if (!context.mounted) return;

    // 展示进度对话框
    _showProgressDialog(
      context: context,
      title: '同步到本地',
      statusText: '正在同步文件到 $dirPath ...',
      task: () async {
        try {
          await ApiService.syncToLocal(workspaceId, dirPath);
          return '同步完成';
        } on Exception catch (e) {
          return e.toString().replaceFirst('Exception: ', '');
        }
      },
    );
  }

  /// 上传文件到云端（支持多选）
  ///
  /// 调用 file_picker 多选本地文件，然后调用 [ApiService.uploadToCloud]
  /// 批量上传到工作空间 `.input/yyyymmdd/` 目录。上传期间展示进度对话框。
  Future<void> _uploadFiles(BuildContext context) async {
    // 多选本地文件
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择要上传的文件（可多选）',
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return; // 用户取消选择

    final List<MapEntry<String, String>> files = <MapEntry<String, String>>[];
    for (final PlatformFile file in result.files) {
      if (file.path != null) {
        files.add(MapEntry<String, String>(file.path!, _basename(file.path!)));
      }
    }
    if (files.isEmpty) return;

    // ignore: use_build_context_synchronously
    if (!context.mounted) return;

    _showProgressDialog(
      context: context,
      title: '上传到云端',
      statusText: '正在上传 ${files.length} 个文件 ...',
      task: () async {
        try {
          final List<String> paths =
              await uploadWithChannelSelection(
            workspaceId,
            files,
            teamId: teamId,
          );
          // 上传成功，通知文件面板刷新文件列表
          onUploaded?.call();
          return '上传完成，已保存到：\n${paths.join('\n')}';
        } on Exception catch (e) {
          return e.toString().replaceFirst('Exception: ', '');
        }
      },
    );
  }

  /// 按文件大小选择上传通道（三模式一致 + 大文件分片）
  ///
  /// - 小文件（≤ [ApiService.chunkUploadThreshold]）：批量 multipart 单请求
  ///   通道（[ApiService.uploadToCloud]）；
  /// - 大文件：逐个走 init/chunk/complete 三段式分片通道
  ///   （[ApiService.uploadFileChunked]）。
  ///
  /// [teamId] 随请求透传，供后端按三模式分派（本地/SSH 模式委托前端执行器
  /// 落盘到本机目录 / 远端主机）。返回上传后的工作空间内路径列表。
  static Future<List<String>> uploadWithChannelSelection(
    String workspaceId,
    List<MapEntry<String, String>> files, {
    String teamId = '',
  }) async {
    final List<MapEntry<String, String>> small = <MapEntry<String, String>>[];
    final List<MapEntry<String, String>> large = <MapEntry<String, String>>[];
    for (final MapEntry<String, String> entry in files) {
      final int size = await File(entry.key).length();
      if (size > ApiService.chunkUploadThreshold) {
        large.add(entry);
      } else {
        small.add(entry);
      }
    }
    final List<String> paths = <String>[];
    if (small.isNotEmpty) {
      paths.addAll(
        await ApiService.uploadToCloud(workspaceId, small, teamId: teamId),
      );
    }
    for (final MapEntry<String, String> entry in large) {
      paths.add(
        await ApiService.uploadFileChunked(
          workspaceId,
          entry.key,
          entry.value,
          teamId: teamId,
        ),
      );
    }
    return paths;
  }

  /// 上传文件夹到云端
  ///
  /// 调用 file_picker 选择本地文件夹，递归收集其中所有文件，
  /// 以相对路径上传到工作空间 `.input/yyyymmdd/`，保留文件夹层级。
  /// 移动端不支持目录选择（file_picker.getDirectoryPath 仅桌面），直接提示。
  Future<void> _uploadFolder(BuildContext context) async {
    if (isMobile) {
      _showUnsupported(context);
      return;
    }
    // 选择本地文件夹
    final String? dirPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择要上传的文件夹',
    );
    if (dirPath == null) return; // 用户取消选择

    final Directory dir = Directory(dirPath);
    if (!dir.existsSync()) return;

    // 递归收集文件夹内所有文件（跳过隐藏文件与 .git）
    final List<MapEntry<String, String>> files = <MapEntry<String, String>>[];
    try {
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File) continue;
        final String path = entity.path;
        final String name = _basename(path);
        if (name.startsWith('.git') || name.startsWith('.')) continue;
        files.add(MapEntry<String, String>(path, _relativePath(dirPath, path)));
      }
    } on FileSystemException {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('读取文件夹失败，可能无访问权限')),
        );
      }
      return;
    }
    if (files.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件夹内没有可上传的文件')),
        );
      }
      return;
    }

    // ignore: use_build_context_synchronously
    if (!context.mounted) return;

    _showProgressDialog(
      context: context,
      title: '上传文件夹',
      statusText: '正在上传 ${files.length} 个文件 ...',
      task: () async {
        try {
          final List<String> paths =
              await ApiService.uploadToCloud(workspaceId, files);
          // 上传成功，通知文件面板刷新文件列表
          onUploaded?.call();
          return '上传完成，共 ${paths.length} 个文件';
        } on Exception catch (e) {
          return e.toString().replaceFirst('Exception: ', '');
        }
      },
    );
  }

  /// 从路径中提取文件名（兼容 / 与 \）
  String _basename(String path) {
    final String replaced = path.replaceAll('\\', '/');
    final int idx = replaced.lastIndexOf('/');
    return idx >= 0 ? replaced.substring(idx + 1) : replaced;
  }

  /// 计算文件相对 [baseDir] 的相对路径（跨平台分隔符统一为 /）
  String _relativePath(String baseDir, String path) {
    final String base = baseDir.replaceAll('\\', '/');
    final String p = path.replaceAll('\\', '/');
    final String rel = base.endsWith('/')
        ? p.substring(base.length)
        : p.substring(base.length + 1);
    return rel;
  }

  /// 展示进度对话框
  ///
  /// 执行异步任务 [task]，期间显示 CircularProgressIndicator 与 [statusText]，
  /// 任务完成后显示结果消息（成功或失败），1.5 秒后自动关闭对话框。
  void _showProgressDialog({
    required BuildContext context,
    required String title,
    required String statusText,
    required Future<String> Function() task,
  }) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return _SyncProgressDialog(
          title: title,
          statusText: statusText,
          task: task,
        );
      },
    );
  }

  /// 移动端提示功能不支持
  void _showUnsupported(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('移动端暂不支持该操作，请使用「上传文件」或到桌面端操作')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.sync, size: 18),
      tooltip: '文件同步',
      onSelected: (String value) {
        switch (value) {
          case 'download':
            _syncToLocal(context);
            break;
          case 'upload':
            _uploadFiles(context);
            break;
          case 'upload_folder':
            _uploadFolder(context);
            break;
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        // 目录选择（getDirectoryPath）仅桌面支持，移动端隐藏
        if (!isMobile)
          const PopupMenuItem<String>(
            value: 'download',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.download_outlined, size: 18),
              title: Text('同步到本地'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        const PopupMenuItem<String>(
          value: 'upload',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.upload_file_outlined, size: 18),
            title: Text('上传文件'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (!isMobile)
          const PopupMenuItem<String>(
            value: 'upload_folder',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.create_new_folder_outlined, size: 18),
              title: Text('上传文件夹'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
      ],
    );
  }
}

/// 同步进度对话框
///
/// 接收一个异步任务，执行期间显示加载动画与状态文字，
/// 任务完成后切换为结果展示（成功/失败信息），1.5 秒后自动关闭。
class _SyncProgressDialog extends StatefulWidget {
  /// 对话框标题
  final String title;

  /// 状态文字
  final String statusText;

  /// 异步任务，返回结果消息
  final Future<String> Function() task;

  const _SyncProgressDialog({
    required this.title,
    required this.statusText,
    required this.task,
  });

  @override
  State<_SyncProgressDialog> createState() => _SyncProgressDialogState();
}

class _SyncProgressDialogState extends State<_SyncProgressDialog> {
  /// 是否正在执行
  bool _isRunning = true;

  /// 结果消息
  String? _result;

  @override
  void initState() {
    super.initState();
    _runTask();
  }

  /// 执行异步任务
  Future<void> _runTask() async {
    final String result = await widget.task();
    if (mounted) {
      setState(() {
        _result = result;
        _isRunning = false;
      });
      // 1.5 秒后自动关闭对话框
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Row(
        children: [
          if (_isRunning)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              _result == '功能开发中' || _result?.contains('失败') == true
                  ? Icons.info_outline
                  : Icons.check_circle,
              size: 20,
              color: _result == '功能开发中' || _result?.contains('失败') == true
                  ? const Color(0xFFF59E0B)
                  : const Color(0xFF10B981),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _isRunning ? widget.statusText : (_result ?? ''),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
