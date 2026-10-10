import 'dart:io';

/// 测试用的临时"工作空间根"。
///
/// 路径一律转成**正斜杠**字符串（`dart:io` 在 Windows 上也接受正斜杠）——
/// 这样同一批用例能在 Windows 开发机与目标机 Linux 上跑同一套断言。
Directory createTempRoot(String label) =>
    Directory.systemTemp.createTempSync('tree_agent_${label}_');

String toPosix(String path) => path.replaceAll('\\', '/');

/// 测试收尾：递归删掉临时根（**只删我们自建的临时目录**）。
void removeTempRoot(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } on FileSystemException {
    // 收尾失败不该让测试红（多为 Windows 上的句柄延迟释放）
  }
}

/// 写一个文件（自动建父目录）。
void writeFile(String path, List<int> bytes) {
  final File file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}
