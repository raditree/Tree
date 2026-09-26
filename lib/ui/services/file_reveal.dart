import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// 在系统文件管理器里**定位**一个文件（M9 Q7）。
///
/// 为什么单独抽出来而不塞进下载面板：定位是通用动作（文件面板/查看器以后也会
/// 用），语义固定为"选中条目本身"——不是打开它，也不是打开它所在的目录
/// （文件夹下载的产物是 tar.gz，要定位的就是这个压缩包）。
class FileReveal {
  FileReveal._();

  /// 定位 [path]；成功返回 null，失败返回可直接展示的中文原因。
  ///
  /// 为什么不在这里弹提示：本函数没有 BuildContext，且只有调用方知道该用哪种
  /// 呈现（下载面板用 SnackBar）。
  static Future<String?> reveal(String path) async {
    if (path.isEmpty) {
      return '该任务还没有保存路径（尚未选择保存位置）';
    }
    if (kIsWeb) {
      return '网页端无法打开本地文件管理器';
    }
    // 先判断存在性：explorer 对不存在的路径不会有任何反馈，直接调用会表现为
    // "点了没反应"，必须由我们给出可见提示。
    final FileSystemEntityType type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) {
      return '文件不存在或已被移动：$path';
    }
    if (Platform.isWindows) {
      // /select, 与路径必须**分成两个参数**传：explorer 的命令行解析以逗号为
      // 分隔符，拼成一整串会被当成单个参数而打不开文件管理器。
      // explorer.exe 即使成功也返回退出码 1，因此这里不看退出码，只兜启动异常。
      try {
        await Process.run('explorer', <String>['/select,', path]);
      } on ProcessException catch (e) {
        return '打开资源管理器失败：${e.message}';
      }
      return null;
    }
    if (Platform.isMacOS) {
      // 访达的等价能力：open -R 选中该文件
      try {
        await Process.run('open', <String>['-R', path]);
      } on ProcessException catch (e) {
        return '打开访达失败：${e.message}';
      }
      return null;
    }
    return '当前平台暂不支持定位文件，请手动打开：$path';
  }
}
