import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// 第三方 MCP 服务的 stdio 隧道：前端两个宿主执行器（本机 / 远端 SSH）共用的
/// 会话状态机。
///
/// 后端把一次 MCP 工具调用拆成 ``mcp_stdio_open`` / ``mcp_stdio_write`` /
/// ``mcp_stdio_read`` / ``mcp_stdio_close`` 四个 op 经反向 WS 下发，协议层
/// （initialize / tools/list / tools/call）全部由后端驱动，前端只做"字节搬运"：
/// 拉起服务进程 → 写 stdin → 按换行切分 stdout → 终止进程。
///
/// 两个宿主（LocalExecutorService 用 Dart 子进程、SshWorkspaceExecutor 用
/// SSH 会话）只有"管道"不同，行缓冲 / 挂起读取 / 退出感知的语义必须完全一致，
/// 因此统一放在本文件，避免两条实现出现行为漂移（如一边按行切分、一边按块
/// 回传会让后端无法重组 JSON-RPC 帧）。

/// 返回 stdio 字节缓冲中首个完整行（含结尾 ``\n``）的结束下标。
///
/// MCP 的 stdio 传输以换行分隔 JSON-RPC 报文：一次读取可能只拿到半行、也可能
/// 一次拿到多行，必须按 ``\n`` 切分——半行留在缓冲里等后续字节，完整行原样
/// （含 ``\n``）回传后端，后端据此重组帧。尚未出现完整行时返回 -1。
/// 纯函数，便于单测。
int mcpStdioLineEnd(List<int> buffer) {
  for (int i = 0; i < buffer.length; i++) {
    if (buffer[i] == 0x0A) return i;
  }
  return -1;
}

/// 一次 MCP stdio 隧道会话（跨 local / SSH 两种宿主的共享状态）。
///
/// 承载进程的生命周期由调用方负责（本机子进程 / SSH 会话），本类只维护：
/// stdout 行缓冲、stderr 尾部、挂起中的读取等待者、退出状态。
class McpStdioTunnelSession {
  McpStdioTunnelSession({
    required this.id,
    required this.teamId,
    required this._write,
    required this._kill,
  });

  /// 会话 id（后端按此 id 收发隧道报文）
  final String id;

  /// 归属 team（顶部 agent 被删除 / 清理时据此回收承载进程）
  final String teamId;

  /// 向承载进程 stdin 写字节（本机子进程 / SSH 会话 stdin）
  final void Function(Uint8List data) _write;

  /// 终止承载进程（本地 kill 子进程 / SSH kill + close 会话）
  final void Function() _kill;

  /// 已从 stdout 收到但尚未被后端取走的字节（可能含不完整行）
  final List<int> buffer = <int>[];

  /// stderr 最近若干字节：承载进程异常退出时随错误回传，便于定位启动失败原因
  final List<int> stderrTail = <int>[];

  /// 挂起中的读取等待者（有新数据或会话关闭时唤醒）
  Completer<void>? _waiter;

  /// 会话是否已结束（主动关闭或承载进程已退出）
  bool closed = false;

  /// 承载进程退出码（尚未退出 / 远端未上报时为 null）
  int? exitCode;

  /// stderr 保留上限（仅用于错误提示，无需全量）
  static const int _kStderrTailBytes = 4096;

  /// 订阅 stdout / stderr（各一次；两者都是单订阅流）。
  ///
  /// stdout 只累积字节不解析内容——切行由 [takeLine] 完成，避免在这里与
  /// "半行"状态纠缠；stderr 必须消费（写满管道会阻塞进程），仅保留尾部。
  void bindStreams(Stream<List<int>> stdout, Stream<List<int>> stderr) {
    stdout.listen(
      (List<int> chunk) {
        buffer.addAll(chunk);
        wakeReader();
      },
      onError: (Object _) {
        // 流异常按"不再有新数据"处理：由退出路径统一唤醒等待者
      },
    );
    stderr.listen(
      (List<int> chunk) {
        stderrTail.addAll(chunk);
        if (stderrTail.length > _kStderrTailBytes) {
          stderrTail.removeRange(0, stderrTail.length - _kStderrTailBytes);
        }
      },
      onError: (Object _) {},
    );
  }

  /// 把一帧报文写入承载进程 stdin（base64 解码后的原始字节）。
  void writeBytes(Uint8List data) => _write(data);

  /// 标记承载进程已退出（本机 exitCode 回调 / SSH 通道关闭）。
  ///
  /// 唤醒挂起中的读取请求，让后端立刻得知隧道中断，而不是把等待窗口耗完。
  void markExited([int? code]) {
    closed = true;
    if (code != null) exitCode = code;
    wakeReader();
  }

  /// 主动关闭：终止承载进程并唤醒挂起读取（幂等）。
  void dispose() {
    closed = true;
    _kill();
    wakeReader();
  }

  /// 取出首个完整行（含结尾 ``\n``）。
  ///
  /// [wait] 内没有整行时返回 null：调用方据此回传空串让后端续等（数分钟的
  /// tools/call 因此不会被单次等待窗口截断）。会话已结束且无残留行时同样返回
  /// null，调用方经 [closed] 判定为隧道中断。
  Future<List<int>?> takeLine(Duration wait) async {
    int end = mcpStdioLineEnd(buffer);
    if (end < 0 && !closed) {
      final Completer<void> waiter = Completer<void>();
      _waiter = waiter;
      try {
        await waiter.future.timeout(wait);
      } on TimeoutException {
        // 窗口内无整行：交给调用方回传空串续等
      } finally {
        if (identical(_waiter, waiter)) _waiter = null;
      }
      end = mcpStdioLineEnd(buffer);
    }
    if (end < 0) return null;
    // 完整行原样（含结尾 \n）回传：后端按 \n 重组帧，缺了分隔符会粘连下一行
    final List<int> line = buffer.sublist(0, end + 1);
    buffer.removeRange(0, end + 1);
    return line;
  }

  /// 唤醒挂起中的读取请求（幂等）。
  void wakeReader() {
    final Completer<void>? pending = _waiter;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  /// 构造"承载进程已退出"的可读错误（附退出码与 stderr 尾部，便于排查）。
  String exitedMessage() {
    final StringBuffer buf = StringBuffer('MCP 服务进程已退出');
    if (exitCode != null) {
      buf.write('（退出码 $exitCode）');
    }
    final String stderr = _decodeTail(stderrTail);
    if (stderr.isNotEmpty) {
      buf.write('；stderr: $stderr');
    }
    return buf.toString();
  }

  /// 解码 stderr 尾部：UTF-8 严格优先，失败回退 latin1 逐字节（不抛异常）。
  String _decodeTail(List<int> bytes) {
    if (bytes.isEmpty) return '';
    String text;
    try {
      text = const Utf8Decoder().convert(bytes);
    } catch (_) {
      text = const Latin1Decoder(allowInvalid: true).convert(bytes);
    }
    text = text.trim();
    if (text.length <= 500) return text;
    return text.substring(text.length - 500);
  }
}
