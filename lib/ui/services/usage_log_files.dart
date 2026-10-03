import 'dart:convert';
import 'dart:io';

import '../../io/core_process_launcher.dart';
import '../widgets/usage_calls_panel.dart';

/// 逐调用用量账本 `usage.jsonl` 的定位与读取
/// （会话用量面板「本轮调用列表」的唯一读取实现）。
///
/// 为什么应用侧直接读文件而不新增 REST 端点：账本本来就是**本机文件**
/// （`<数据根>/data/<agent_id>/<session_id>/usage.jsonl`，见核心侧
/// `TreePaths.usageFile`），而桌面形态下应用与核心**同机**运行；走 REST 要多开
/// 一条路由、过一遍协议门禁，读数却完全相同。这与核心日志入口
/// （`core_log_files.dart`）是**同一个范式**：数据根来自握手的可选字段
/// （`CoreProcessLauncher.instance.coreDataRoot`），拿不到就退回"没有入口"，
/// **不猜** `%APPDATA%\Tree` 之类的替代路径。
///
/// 与 `CoreLogFiles` 的差别只有三处：路径要拼 agent / session 两段、
/// 每行是 JSON（不是纯文本）、默认只看最近 50 次调用（面板的粒度是"几次调用"而不是"几百行日志"）。
///
/// **绝不抛异常**：这是"看一眼花了多少"的旁路读数，读不到就该给一句人话，
/// 而不是把面板拖红。
class UsageLogFiles {
  UsageLogFiles._();

  /// 默认读最近多少次调用（够看"刚才那几轮花了多少"，又不至于把面板塞爆）。
  static const int defaultLines = 50;

  /// 单次最多回读的字节数：账本只追加、长会话会到几 MB，而这里只要看尾巴。
  static const int maxTailBytes = 256 * 1024;

  /// 拿不到数据根时的可读原因（核心未启动 / 老核心没带该字段 / 附着模式）。
  static const String reasonNoDataRoot =
      '拿不到核心数据根（核心未启动 / 老核心没带这个字段）——'
      '没有 usage.jsonl 的入口，也不猜一个数据根路径。';

  /// id 不合法时的可读原因（agentId / sessionId 来自 UI 或 HTTP，必须先校验）。
  static const String reasonUnsafeIds =
      'agentId / sessionId 不合法（只允许 [A-Za-z0-9_.-]，且不能是 . 或 ..）——'
      '拒绝拼接路径，也不去读任何文件。';

  /// 某会话的用量账本路径：`<数据根>/data/<agentId>/<sessionId>/usage.jsonl`。
  ///
  /// 返回**空串** = 入口不可用，两种情况（都不去读文件）：
  /// 1. [agentId] / [sessionId] 不合法——来自 UI/HTTP 的分段必须先过安全校验
  ///    （口径与核心侧 `TreePaths.safeSegment` 一致），否则 `../` 能读到数据根之外；
  /// 2. 握手没给数据根（老核心 / 附着模式 / 核心还没起来）。
  ///
  /// [override] 仅**测试注入**用：给了就原样返回（连数据根都不看），
  /// 但**id 校验在它之前**——非法 id 即便带了 override 也拿不到路径。
  static String resolveUsageFile({
    required String agentId,
    required String sessionId,
    String? override,
  }) {
    final String? agent = _safeSegment(agentId);
    final String? session = _safeSegment(sessionId);
    if (agent == null || session == null) return '';
    final String injected = (override ?? '').trim();
    if (injected.isNotEmpty) return injected;
    final String root = CoreProcessLauncher.instance.coreDataRoot.trim();
    if (root.isEmpty) return '';
    final String base = _stripTrailingSeparators(root);
    final String sep = Platform.pathSeparator;
    return '$base${sep}data$sep$agent$sep$session${sep}usage.jsonl';
  }

  /// 读最近 [lines] 行（账本顺序：早 → 晚；返回值保持**文件顺序**，面板按它渲染）。
  ///
  /// [lines] `<= 0` 时退化为 [defaultLines]（调用方传 0/-1 是"没设"，不是"不要"）。
  ///
  /// 容错口径（**绝不抛异常**）：
  /// - 入口不可用（id 非法 / 拿不到数据根）⇒ `ok=false` + [reasonNoDataRoot] /
  ///   [reasonUnsafeIds]，`usageFile` 为空串；
  /// - 文件不存在 ⇒ `ok=false` + [missingReason]（"还没跑过 LLM 调用"）；
  /// - 空文件 ⇒ `ok=true`、空列表（"跑过但还没记上"是正常状态，不是错误）；
  /// - 坏行（非法 JSON / 不是对象 / 缺 `at` 或缺 `source`）⇒ 跳过并计入
  ///   `skippedLines`，**其余照读**（崩溃或手改坏一行不该让整块读数消失）；
  ///   空行不算坏行（尾部换行、手改留白都不该被记成"坏"）；
  /// - 任何 IO 异常 ⇒ 捕获 ⇒ `ok=false` + 可读原因。
  static Future<UsageHistoryRead> readRecent({
    required String agentId,
    required String sessionId,
    int lines = defaultLines,
    String? override,
  }) async {
    final int want = lines <= 0 ? defaultLines : lines;
    final String usageFile = resolveUsageFile(
      agentId: agentId,
      sessionId: sessionId,
      override: override,
    );
    if (usageFile.isEmpty) {
      final bool unsafe =
          _safeSegment(agentId) == null || _safeSegment(sessionId) == null;
      return UsageHistoryRead(
        calls: const <UsageCallView>[],
        skippedLines: 0,
        usageFile: '',
        reason: unsafe ? reasonUnsafeIds : reasonNoDataRoot,
      );
    }
    try {
      final File file = File(usageFile);
      if (!await file.exists()) {
        return UsageHistoryRead(
          calls: const <UsageCallView>[],
          skippedLines: 0,
          usageFile: usageFile,
          reason: missingReason(usageFile),
        );
      }
      final List<String> rawLines = await _readTailLines(file, want);
      final List<UsageCallView> calls = <UsageCallView>[];
      int skipped = 0;
      for (final String raw in rawLines) {
        final String line = raw.trim();
        // 空行不是坏行：账本尾部换行、手改留白都可能产生空行。
        if (line.isEmpty) continue;
        final Map<String, dynamic>? parsed = _parseLine(line);
        if (parsed == null) {
          skipped++;
          continue;
        }
        calls.add(UsageCallView.fromUsage(parsed));
      }
      return UsageHistoryRead(
        calls: calls,
        skippedLines: skipped,
        usageFile: usageFile,
        reason: '',
      );
    } catch (error) {
      return UsageHistoryRead(
        calls: const <UsageCallView>[],
        skippedLines: 0,
        usageFile: usageFile,
        reason: _ioFailureReason(usageFile, error),
      );
    }
  }

  /// 读不到时的可读原因（不弹空框）：一句话 + 可能原因。
  static String missingReason(String usageFile) =>
      '还没有 usage.jsonl：$usageFile\n'
      '可能原因：这个会话还没跑过 LLM 调用（账本是按需创建的）；'
      '或者数据目录被清理/移动过。\n'
      '用量是遥测：删掉它不影响对话本身。';

  // ---- 内部实现 ----

  /// 路径分段安全校验：口径同核心侧 `TreePaths.safeSegment`
  /// （只允许 `[A-Za-z0-9_.-]`，拒绝空串 / `.` / `..`）。
  ///
  /// 与核心的差别只有"不抛"：核心侧抛 `ArgumentError` 是编程错误，
  /// 而这里的分段来自 UI/HTTP，非法只是"这一条请求不可服务"，返回 null 即可。
  static String? _safeSegment(String raw) {
    final String value = raw.trim();
    if (value.isEmpty) return null;
    if (value == '.' || value == '..') return null;
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value)) return null;
    return value;
  }

  /// 去掉数据根尾部的分隔符（`C:\x\` / `/x/`），避免拼出 `//data`。
  static String _stripTrailingSeparators(String root) {
    String base = root;
    while (base.length > 1 && (base.endsWith('/') || base.endsWith('\\'))) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  /// 读文件**尾部**至多 [lines] 行（文件不存在由调用方先行判定）。
  ///
  /// 读法与 `CoreLogFiles.readTail` 同一口径：只读最后 [maxTailBytes] 字节；
  /// 从中间开始时丢掉首个半行（截断点落在 JSON 中间会解不出，必须丢）；
  /// 再取最后 [lines] 行。用 `allowMalformed: true`：被切断的多字节字符
  /// 不该让整块读数失败。
  static Future<List<String>> _readTailLines(File file, int lines) async {
    final int length = await file.length();
    if (length == 0) return const <String>[];
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
      if (all.length <= lines) return all;
      return all.sublist(all.length - lines);
    } finally {
      await handle.close();
    }
  }

  /// 解析一行账本；坏行返回 null（由调用方跳过并计数），永不抛异常。
  ///
  /// "坏"的判据（契约的 8 个键里最少要认得出来）：不是 JSON / 不是对象 /
  /// `at` 或缺 `source` 不是非空字符串。`source` 的取值不做枚举校验——
  /// 未知来源原样传下去（UI 有 default 分支显示原文），比丢掉整行有用。
  static Map<String, dynamic>? _parseLine(String line) {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final Map<String, dynamic> map = <String, dynamic>{};
    decoded.forEach((Object? key, Object? value) {
      if (key != null) map[key.toString()] = value;
    });
    if (!_nonEmptyString(map['at'])) return null;
    if (!_nonEmptyString(map['source'])) return null;
    return map;
  }

  static bool _nonEmptyString(Object? value) =>
      value is String && value.trim().isNotEmpty;

  static String _ioFailureReason(String usageFile, Object error) =>
      '读取 usage.jsonl 失败：$usageFile\n'
      '原因：$error\n'
      '可能原因：文件正被核心写入且被独占（Windows）、权限不足，'
      '或数据目录已被卸载/移动。';
}

/// [UsageLogFiles.readRecent] 的结果：读到的调用 + 读的过程本身的状态。
///
/// 为什么把"路径、跳过几行、为什么读不到"一起返回：面板需要的恰恰是后者——
/// 只给一个空列表，界面就只能显示"暂无调用记录"，而真实原因可能是
/// "这个会话没跑过 LLM"、"核心没给数据根"、"agentId 不合法"三种完全不同的处置。
class UsageHistoryRead {
  const UsageHistoryRead({
    required this.calls,
    required this.skippedLines,
    required this.usageFile,
    required this.reason,
  });

  /// 解析出的逐调用用量，**文件顺序：早 → 晚**（面板按这个顺序渲染）。
  final List<UsageCallView> calls;

  /// 坏行数（非法 JSON / 不是对象 / 缺 `at` 或 `source`）；
  /// `> 0` 说明账本曾被崩溃截断，或被人手改坏过。空行不计入。
  final int skippedLines;

  /// 解析出的路径；空串 = 入口不可用（还没拼出路径，也就没读过任何文件）。
  final String usageFile;

  /// 空串 = 正常；非空 = 可读原因（入口不可用 / 还没有这个文件 / IO 失败）。
  final String reason;

  /// 这次读取是否正常（`false` 时看 [reason]，别把"读不到"显示成"没调用过"）。
  bool get ok => reason.isEmpty;

  /// 没有任何一条调用（正常状态之一：会话还没跑过 LLM 调用）。
  bool get isEmpty => calls.isEmpty;
}
