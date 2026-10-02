/// 文件内容 + 元信息（编辑要用它做「外部改动」检测：见 ApiService.saveFileContent 的 ifSize）。
///
/// 为什么单独一个类型：老的 `getFileContent` 只回字符串，把 `size` 与
/// `truncated`（大文件只回前一段）都丢了——编辑一旦不知道这两个，就会把
/// 「只读到一半的内容」当全文写回去，直接把文件毁掉。
class FileContentInfo {
  const FileContentInfo({
    required this.content,
    required this.size,
    this.truncated = false,
    this.path = '',
  });

  /// 文件内容（二进制/图片按既有口径 base64；这里只用纯文本那条路）
  final String content;

  /// 文件**真实**字节数（不是 [content] 的长度）
  final int size;

  /// 内容是否被截断（大文件只回前一段）——截断的内容**不允许编辑保存**
  final bool truncated;

  /// 工作空间相对路径（核心回显）
  final String path;

  /// 内容是否完整（不截断时才好编辑）
  bool get complete => !truncated;
}
