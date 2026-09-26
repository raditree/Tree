import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 落盘原语：原子快照写与追加写。
///
/// 这两件事是"崩溃后文件仍可读"的全部保证来源：
/// - [writeStringAtomic]：写 `<path>.tmp` → flush → 改名覆盖。任何时刻磁盘上
///   的正式文件要么是旧内容、要么是新内容，**不会是半截**（改名在同一卷上
///   是元数据操作）。
/// - [appendLine]：单次 `writeString` 追加完整一行。进程被硬杀时最多丢掉
///   尚未 flush 的最后一行，已写入的行不受影响；读取侧对损坏行做容错跳过。
abstract final class AtomicFile {
  /// 原子写入文本（自动创建父目录）。
  ///
  /// Windows 上改名覆盖既有文件的行为需要兜底：先试 `rename`，失败则删除
  /// 目标再改名（Dart 的 `File.rename` 在部分平台对已存在目标会失败）。
  static Future<void> writeStringAtomic(String path, String content) async {
    final File target = File(path);
    await target.parent.create(recursive: true);
    final String tempPath = '$path.tmp';
    final File temp = File(tempPath);
    final RandomAccessFile handle = await temp.open(mode: FileMode.write);
    try {
      await handle.writeString(content);
      await handle.flush();
    } finally {
      await handle.close();
    }
    try {
      await temp.rename(path);
    } on FileSystemException {
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(path);
    }
  }

  /// [writeStringAtomic] 的同步版本（小文件 + 同步读 API 的场景，如会话待办）。
  ///
  /// 为什么同步：待办只有几十字节、写入频率是"用户级别"的交互，而读取入口同时
  /// 被 HTTP 处理器与工具调用使用（两者都是同步接口）。用同步写换来"写完即可读"
  /// 的确定语义，比引入 write-behind + flush 更简单也更少出错。
  static void writeStringAtomicSync(String path, String content) {
    final File target = File(path);
    target.parent.createSync(recursive: true);
    final String tempPath = '$path.tmp';
    final File temp = File(tempPath);
    temp.writeAsStringSync(content, flush: true);
    try {
      temp.renameSync(path);
    } on FileSystemException {
      if (target.existsSync()) target.deleteSync();
      temp.renameSync(path);
    }
  }

  /// 追加一行（自动补 `\n` 并创建父目录）。
  static Future<void> appendLine(String path, String line) async {
    final File file = File(path);
    await file.parent.create(recursive: true);
    final RandomAccessFile handle = await file.open(mode: FileMode.append);
    try {
      await handle.writeString(line.endsWith('\n') ? line : '$line\n');
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  /// 读取文本；文件不存在返回 null（区别于"空文件"）。
  static Future<String?> readStringOrNull(String path) async {
    final File file = File(path);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  /// 读取文件**尾部**至多 [maxBytes] 字节（用于"最后一条消息预览"这类
  /// 只需要结尾的场景，避免为预览把 2.9 MB 的整份 jsonl 读进内存）。
  ///
  /// 返回内容可能以半行开头（截断即整行丢弃，由调用方按行解析时自然处理）。
  static Future<String?> readTailOrNull(String path, int maxBytes) async {
    final File file = File(path);
    if (!await file.exists()) return null;
    final int length = await file.length();
    if (length == 0) return '';
    final int start = length > maxBytes ? length - maxBytes : 0;
    final RandomAccessFile handle = await file.open();
    try {
      await handle.setPosition(start);
      final List<int> bytes = await handle.read(length - start);
      String text = utf8.decode(bytes, allowMalformed: true);
      // 从中间开始时丢掉首个半行
      if (start > 0) {
        final int firstBreak = text.indexOf('\n');
        text = firstBreak < 0 ? '' : text.substring(firstBreak + 1);
      }
      return text;
    } finally {
      await handle.close();
    }
  }

  /// 同步读取文本；文件不存在返回 null。
  ///
  /// 存储层的读接口（`messages()` / `lastTextMessage()`）是同步的，故必须提供
  /// 同步版本：这些读取只发生在首次装载某个会话时（之后走内存缓存）。
  static String? readStringOrNullSync(String path) {
    final File file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  }

  /// 同步读取文件尾部至多 [maxBytes] 字节（见 [readTailOrNull]）。
  static String? readTailOrNullSync(String path, int maxBytes) {
    final File file = File(path);
    if (!file.existsSync()) return null;
    final int length = file.lengthSync();
    if (length == 0) return '';
    final int start = length > maxBytes ? length - maxBytes : 0;
    final RandomAccessFile handle = file.openSync();
    try {
      handle.setPositionSync(start);
      final List<int> bytes = handle.readSync(length - start);
      String text = utf8.decode(bytes, allowMalformed: true);
      if (start > 0) {
        final int firstBreak = text.indexOf('\n');
        text = firstBreak < 0 ? '' : text.substring(firstBreak + 1);
      }
      return text;
    } finally {
      handle.closeSync();
    }
  }

  /// 把 jsonl 文本解析为记录列表，**容忍损坏行**（崩溃时可能出现的半行）。
  ///
  /// 返回解析出的记录与跳过行数；调用方决定如何记录被跳过的行数。
  static JsonlReadResult decodeJsonl(String text) {
    final List<Map<String, dynamic>> records = <Map<String, dynamic>>[];
    int skipped = 0;
    for (final String raw in const LineSplitter().convert(text)) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      try {
        final Object? decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          records.add(decoded);
        } else {
          skipped++;
        }
      } catch (_) {
        skipped++;
      }
    }
    return JsonlReadResult(records, skipped);
  }
}

/// [AtomicFile.decodeJsonl] 的结果。
class JsonlReadResult {
  const JsonlReadResult(this.records, this.skipped);

  /// 解析成功的记录（保持文件顺序）。
  final List<Map<String, dynamic>> records;

  /// 无法解析而被跳过的行数（> 0 说明曾发生崩溃或手工改坏）。
  final int skipped;
}
