import 'dart:convert';
import 'dart:io';

import '../../io/core_process_launcher.dart';

/// 核心日志文件的定位与读取（设置页「核心日志」卡片 + 查看弹窗的唯一实现）。
///
/// 为什么应用侧直接读文件而不新增 REST 端点：核心日志就是**本机文件**，而应用
/// （桌面形态）与核心**同机**运行；走 REST 要多开一条路由、过协议门禁，收益相同。
/// 数据根来自握手的可选字段 `data_root`（核心写入 `<数据根>/logs/core.log`）——
/// 拿不到时（老核心 / 附着模式）返回空串，调用方退回"没有日志入口"，**不猜路径**。
class CoreLogFiles {
  CoreLogFiles._();

  /// 默认查看行数（够看"压缩/插件最近发生了什么"，又不至于把弹窗塞爆）。
  static const int defaultLines = 200;

  /// 单次最多回读的字节数：日志单份上限 8 MiB，只为了看尾巴，没必要全读进来。
  static const int maxTailBytes = 512 * 1024;

  /// 核心日志文件路径；[override] 仅**测试注入**用。
  ///
  /// 返回空串 = 本次运行的日志入口不可用（核心没给数据根，或核心尚未启动）。
  static String resolveLogFile({String? override}) {
    final String injected = (override ?? '').trim();
    if (injected.isNotEmpty) return injected;
    return CoreProcessLauncher.instance.coreLogFile;
  }

  /// 日志目录（用于「打开日志目录」）。
  static String logDirOf(String logFile) => File(logFile).parent.path;

  /// 读日志**尾部**至多 [lines] 行；文件不存在返回 null（区别于"空文件"）。
  ///
  /// 读法与 [TreeStore] 的尾部读取同一口径：只读最后一段字节（[maxTailBytes]），
  /// 从中间开始时丢掉首个半行，再取最后 [lines] 行——日志文件可以有 8 MiB，
  /// 不该为了看尾巴把它整份读进内存。
  static Future<String?> readTail(
    String logFile, {
    int lines = defaultLines,
  }) async {
    final File file = File(logFile);
    if (!await file.exists()) return null;
    final int length = await file.length();
    if (length == 0) return '';
    final int start = length > maxTailBytes ? length - maxTailBytes : 0;
    final RandomAccessFile handle = await file.open();
    try {
      await handle.setPosition(start);
      final List<int> bytes = await handle.read(length - start);
      String text = utf8.decode(bytes, allowMalformed: true);
      if (start > 0) {
        final int firstBreak = text.indexOf('\n');
        text = firstBreak < 0 ? '' : text.substring(firstBreak + 1);
      }
      final List<String> all = const LineSplitter().convert(text);
      if (lines <= 0 || all.length <= lines) return all.join('\n');
      return all.sublist(all.length - lines).join('\n');
    } finally {
      await handle.close();
    }
  }

  /// 读不到时的可读原因（不弹空框）。
  static String missingReason(String logFile) =>
      '还没有核心日志文件：$logFile\n'
      '可能原因：核心刚启动还没写过一行；或日志目录被清理/移动过。\n'
      '核心进程的日志同时写在它的 stderr 上，落盘是副本。';
}
