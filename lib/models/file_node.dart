/// 文件节点数据模型
///
/// 描述工作空间中的一个文件或目录，包含名称、大小、类型、修改时间
/// 与相对工作空间根目录的路径。`type` 为 "dir" 表示目录，
/// "file" 表示普通文件。提供格式化大小、目录判断等便捷 getter。
class FileNode {
  /// 名称（不含路径）
  final String name;

  /// 大小（字节数，目录通常为 0）
  final int size;

  /// 类型："file" 或 "dir"
  final String type;

  /// 修改时间（后端返回的字符串，通常为 ISO 格式）
  final String modified;

  /// 相对工作空间根目录的路径
  final String path;

  FileNode({
    required this.name,
    required this.size,
    required this.type,
    required this.modified,
    required this.path,
  });

  /// 是否为目录
  bool get isDirectory => type == 'dir';

  /// 格式化大小显示
  ///
  /// - 小于 1 KB：显示字节数（如 "512 B"）
  /// - 小于 1 MB：显示 KB（如 "1.2 KB"）
  /// - 小于 1 GB：显示 MB（如 "3.4 MB"）
  /// - 大于等于 1 GB：显示 GB
  /// 目录统一返回 "-"。
  String get formattedSize {
    if (isDirectory) return '-';
    const int kb = 1024;
    const int mb = kb * 1024;
    const int gb = mb * 1024;
    if (size >= gb) return '${(size / gb).toStringAsFixed(1)} GB';
    if (size >= mb) return '${(size / mb).toStringAsFixed(1)} MB';
    if (size >= kb) return '${(size / kb).toStringAsFixed(1)} KB';
    return '$size B';
  }

  /// 从 JSON 构造 FileNode 实例
  ///
  /// 兼容后端返回的字段命名（snake_case / camelCase），
  /// 缺失字段使用安全默认值，避免解析异常。
  factory FileNode.fromJson(Map<String, dynamic> json) {
    return FileNode(
      name: json['name'] as String? ?? '',
      size: _parseInt(json['size']),
      type: json['type'] as String? ?? 'file',
      modified: json['modified'] as String? ??
          json['modified_at'] as String? ??
          json['mtime'] as String? ??
          '',
      path: json['path'] as String? ?? '',
    );
  }

  /// 解析整数字段，兼容字符串形式
  static int _parseInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    if (value is double) return value.toInt();
    return 0;
  }
}
