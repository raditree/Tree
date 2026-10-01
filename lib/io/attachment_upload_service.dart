import 'dart:io';

import 'api_service.dart';

/// 把输入框里选中的**本机附件**上传到 agent 的工作空间。
///
/// 为什么放在前端、又为什么复用分片上传通道（`upload_init|chunk|complete`）：
/// - 附件是**UI 这台机器**上的文件，核心无从得知它们在哪（SSH 模式下工作空间还在
///   远端），因此"把字节送到工作空间"这一步只能由前端发起；
/// - 该通道已在文件面板里跑通，本地模式写本机目录、SSH 模式经 SFTP 写远端根，
///   落点统一在 `.input/{yyyymmdd}/`，前端拿回的是**工作空间相对路径**——这正是
///   核心要写进提示词、也是文件工具（read/write/...）接受的口径。
///
/// 上传失败不吞：抛异常给调用方（面板据此中止发送并保留草稿），错误文本直接用
/// 核心返回的 `detail`（例如"目标路径越出工作空间"）。
class AttachmentUploadService {
  AttachmentUploadService._();

  /// 逐个上传 [localPaths]，返回可直接交给核心的附件元数据列表。
  ///
  /// 每项形如 `{name, path, size, type}`：
  /// - `path`：**工作空间相对路径**（如 `.input/20261001/x.png`）；
  /// - `name`：原始文件名（服务端同名覆盖，与文件面板上传口径一致）；
  /// - `size`：本机文件字节数（供 UI 展示）；
  /// - `type`：扩展名（小写、不含点；无扩展名为空串。既不是 MIME 也不做白名单）。
  ///
  /// [onFile] 在每个文件开始上传前回调（当前第几个 / 共几个 / 文件名），供 UI
  /// 提示进度；顺序上传（不并发）以便错误落在具体文件上、也让进度单调。
  static Future<List<Map<String, dynamic>>> uploadAll(
    String workspaceId,
    List<String> localPaths, {
    String teamId = '',
    void Function(int index, int total, String name)? onFile,
  }) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (int i = 0; i < localPaths.length; i++) {
      final String local = localPaths[i];
      final String name = baseNameOf(local);
      onFile?.call(i + 1, localPaths.length, name);
      final String path = await ApiService.uploadFileChunked(
        workspaceId,
        local,
        name,
        teamId: teamId,
      );
      final String relative = path.trim();
      if (relative.isEmpty) {
        throw Exception('上传 $name 后核心未返回工作空间路径');
      }
      out.add(<String, dynamic>{
        'name': name,
        'path': relative,
        'size': await _sizeOf(local),
        'type': extensionOf(name),
      });
    }
    return out;
  }

  /// 取文件名（兼容 `/` 与 `\`；路径以分隔符结尾或为空时原样返回）。
  static String baseNameOf(String path) {
    final String replaced = path.replaceAll('\\', '/');
    final int idx = replaced.lastIndexOf('/');
    final String name = idx >= 0 ? replaced.substring(idx + 1) : replaced;
    return name.isEmpty ? replaced : name;
  }

  /// 取扩展名（小写、不含点；无扩展名返回空串）。
  static String extensionOf(String name) {
    final int dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// 本机文件大小；读不到（文件已被删除/无权限）时返回 0，不因此让上传失败。
  static Future<int> _sizeOf(String localPath) async {
    try {
      return await File(localPath).length();
    } catch (_) {
      return 0;
    }
  }
}
