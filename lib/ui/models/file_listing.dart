import 'file_node.dart';

/// 一次目录列举的结果：条目 + **是否被核心截断**。
///
/// 为什么单独一个类型而不是给 [FileNode] 加字段：截断是"这一次列举"的属性，
/// 不是某个条目的属性（见 packages/tree_core 的 `FileService.list`：
/// 条目数达到 `maxListEntries`（默认 2000）时回 `truncated: true`）。
/// 为什么不改 [FileNode] 的既有调用方（`ApiService.getFiles`）：那是公共签名，
/// 所以另开一个 `getFilesWithMeta`（见 lib/io/api_service.dart）。
class FileListing {
  const FileListing({required this.nodes, this.truncated = false});

  /// 空列举（核心还没回数据时的安全默认值）
  static const FileListing empty = FileListing(nodes: <FileNode>[]);

  /// 目录下的条目（核心已按"目录在前 + 名称排序"排好，前端仍会再排一次保险）
  final List<FileNode> nodes;

  /// 只回了前 `maxListEntries` 条 ⇒ 界面要给"仅显示前 N 项"的提示，
  /// 而不是假装这就是全部内容
  final bool truncated;

  int get length => nodes.length;

  bool get isEmpty => nodes.isEmpty;
}
