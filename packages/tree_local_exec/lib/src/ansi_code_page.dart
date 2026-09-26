import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// 非 UTF-8 输出实际走的解码路径。
///
/// 由 [PlatformTextDecoder] 产出，供工具层如实区分"已按系统代码页解开"与"真乱码"
/// （对应 `ExecOutcome.nonUtf8Output` / `ExecOutcome.garbledOutput`）。
enum TextDecoding {
  /// 严格合法 UTF-8（绝大多数情况）。
  utf8,

  /// 不是 UTF-8，但整段字节在**系统 ANSI 代码页**（Windows = CP_ACP）下完全合法，
  /// 已按该代码页解出可读文本：中文机器上就是 cmd 内建命令的 GBK/CP936 管道输出。
  systemCodePage,

  /// 前两者都解不开，只能用 latin1 逐字节兜底——**字节不丢**，但文本是真乱码。
  latin1Fallback,

  /// 容错解码：非法 UTF-8 字节用 U+FFFD 顶替（[PlatformTextDecoder.decodeTolerant]）。
  ///
  /// 只出现在「坏输入不能中断流程」的协议/配置读取上，**用户数据路径不用它**。
  utf8Malformed,
}

/// 一次解码的结果：文本 + 走的路径 + 原始字节数。
class DecodedText {
  const DecodedText({
    required this.text,
    required this.decoding,
    required this.byteLength,
  });

  /// 解码后的文本。
  final String text;

  /// 实际走的解码路径。
  final TextDecoding decoding;

  /// 输入字节数。
  ///
  /// [TextDecoding.latin1Fallback] 时恒有 `text.length == byteLength`（latin1 是逐字节
  /// 映射），调用方可以据此自检"兜底没有丢字节"。
  final int byteLength;

  /// 是否严格 UTF-8。
  bool get isUtf8 => decoding == TextDecoding.utf8;

  /// 是否真乱码（UTF-8 与系统代码页都解不开）。
  bool get isGarbled => decoding == TextDecoding.latin1Fallback;
}

/// 字节 → 文本的统一解码链：**严格 UTF-8 →（Windows）系统 ANSI 代码页 → latin1 兜底**。
///
/// 为什么需要中间那一级：Windows 上并非所有字节都是 UTF-8——cmd 内建命令（dir/echo/type）
/// 写管道用的是**系统 ANSI 代码页**（中文机器 = GBK/CP936，chcp 管不住管道），用户手上的
/// 文本文件、旧工具输出、hook 日志也常常是 GBK。此时严格 UTF-8 必然失败，若直接 latin1
/// 兜底，字节虽在、中文不可读；按系统代码页再解一次才能拿到正确文本。
/// （同步命令换 PowerShell 后输出已是 UTF-8，但 cmd 回退、hook 脚本、cmd /c 子进程
/// 与文件读取这几条路仍然需要这一级。）
///
/// 契约：**代码页这一级永不抛异常**。非 Windows、FFI 不可用、字节不是合法的代码页
/// 序列，都降级到 latin1（逐字节映射、不丢字节），并由 [DecodedText.decoding] 如实标注。
abstract final class PlatformTextDecoder {
  /// 按解码链解码 [bytes]（空字节串视为合法 UTF-8）。
  static DecodedText decode(List<int> bytes) {
    if (bytes.isEmpty) {
      return const DecodedText(
        text: '',
        decoding: TextDecoding.utf8,
        byteLength: 0,
      );
    }
    try {
      return DecodedText(
        text: utf8.decode(bytes),
        decoding: TextDecoding.utf8,
        byteLength: bytes.length,
      );
    } on FormatException {
      // 不是严格 UTF-8：往下试系统 ANSI 代码页（仅 Windows 可用）。
    }
    final String? byCodePage = AnsiCodePage.decode(bytes);
    if (byCodePage != null) {
      return DecodedText(
        text: byCodePage,
        decoding: TextDecoding.systemCodePage,
        byteLength: bytes.length,
      );
    }
    return DecodedText(
      text: latin1.decode(bytes),
      decoding: TextDecoding.latin1Fallback,
      byteLength: bytes.length,
    );
  }

  /// 只要文本的便捷入口（调用方不关心走了哪条路径时用）。
  static String decodeToString(List<int> bytes) => decode(bytes).text;

  /// 容错解码：**绝不抛异常**，非法字节用 U+FFFD 顶替。
  ///
  /// 用在"坏输入不能把流程搞崩"的地方——settings.yaml / jsonl / meta 这类配置与元数据
  /// 文件、插件与 MCP 的 stdio 行：这些数据的契约就是 UTF-8，被手改坏时替换几个字符继续
  /// 跑，远好过整个启动过程或整条通道失败。调用方据 [DecodedText.decoding] ==
  /// [TextDecoding.utf8Malformed] 判断"发生过顶替"并记一条可见日志。
  ///
  /// **用户数据路径（read/edit/命令输出）不要用它**：那里必须如实区分 UTF-8 / 系统代码页 /
  /// 真乱码，否则会把乱码当正常文本写回用户文件。
  static DecodedText decodeTolerant(List<int> bytes) {
    if (bytes.isEmpty) {
      return const DecodedText(
        text: '',
        decoding: TextDecoding.utf8,
        byteLength: 0,
      );
    }
    try {
      return DecodedText(
        text: utf8.decode(bytes),
        decoding: TextDecoding.utf8,
        byteLength: bytes.length,
      );
    } on FormatException {
      // 非法 UTF-8：先按系统代码页试一次（Windows 上的日志/配置常常就是 GBK 写出来的），
      // 解不开再顶替。两条路都不抛。
    } catch (_) {
      // 非字节输入（越界整数等坏值）：也走下面的顶替路径，绝不抛
    }
    final String? byCodePage = AnsiCodePage.decode(bytes);
    if (byCodePage != null) {
      return DecodedText(
        text: byCodePage,
        decoding: TextDecoding.systemCodePage,
        byteLength: bytes.length,
      );
    }
    return DecodedText(
      // & 0xFF 保证"再坏的值也不会让 allowMalformed 抛异常"
      text: utf8.decode(
        bytes.map((int byte) => byte & 0xFF).toList(),
        allowMalformed: true,
      ),
      decoding: TextDecoding.utf8Malformed,
      byteLength: bytes.length,
    );
  }

  /// 用 [original] 当初的解码路径把 [text] 编回字节；编不回去时返回 null。
  ///
  /// 读-改-写（edit / 覆盖已有文件的 write）必须用它：非 UTF-8 文件要用**同一个代码页**
  /// 写回，否则就是把用户的 GBK 文件静默转成 UTF-8——那是破坏性转码。
  /// 返回 null 时调用方应当**显式拒绝**并给出可读原因，而不是退回 UTF-8 写下去。
  static List<int>? encodeLike(DecodedText original, String text) {
    switch (original.decoding) {
      case TextDecoding.utf8:
      case TextDecoding.utf8Malformed:
        return utf8.encode(text);
      case TextDecoding.systemCodePage:
        return AnsiCodePage.encode(text);
      case TextDecoding.latin1Fallback:
        // latin1 是逐字节映射：只有字符都落在 0..0xFF 内才编得回去（否则会丢信息）
        for (final int rune in text.runes) {
          if (rune > 0xFF) return null;
        }
        return latin1.encode(text);
    }
  }
}

/// Windows 系统 ANSI 代码页（CP_ACP = 0）解码：dart:ffi 调 kernel32 的
/// `MultiByteToWideChar`。
///
/// 关键取舍：
/// - **平台守卫**：只在 `Platform.isWindows` 为真时才 `DynamicLibrary.open('kernel32.dll')`；
///   其它平台根本不会发起这次加载（也不会走任何 FFI 调用），直接返回 null 交给 latin1。
/// - **只探测一次**：加载/查符号结果（含失败）缓存在 [_probed]/[_kernel32] 里，命令执行是
///   热路径，不能每条命令都重试 LoadLibrary。
/// - **整段严格**：用 `MB_ERR_INVALID_CHARS` 解码，只要有一个字节序列在该代码页下非法就
///   整段失败并返回 null。宁可退回 latin1（字节可还原），也不在这里用 '?' 顶替——那才是
///   真正的"悄悄丢字节"。
/// - **失败即降级**：任何异常（加载失败、符号缺失、分配失败、调用返回 0）都收敛成 null，
///   由 [PlatformTextDecoder] 落到 latin1 兜底，绝不把异常抛给工具调用。
/// - **AOT 兼容**：用的都是 dart:ffi 的常规 AOT 能力（DynamicLibrary.open + lookupFunction），
///   没有 entry point/反射依赖；FFI 不可用的构建里也只是走降级链。
abstract final class AnsiCodePage {
  /// 测试注入点：替换"按系统代码页解码"的实现。
  ///
  /// 返回 null 表示"代码页解码不可用/失败"，用于在任意平台上确定性地覆盖
  /// latin1 兜底路径；把它设成能返回文本的实现则可以模拟代码页解码成功。
  /// 生产代码不设置它（保持 null）。注意它是全局静态：测试里用完必须复原。
  static String? Function(List<int> bytes)? debugDecoderOverride;

  /// 本机系统 ANSI 代码页号（Windows 的 `GetACP()`；非 Windows / 不可用时为 null）。
  ///
  /// 诊断与测试用：中文机器上是 936（GBK/CP936）。不受 [debugDecoderOverride] 影响。
  static int? get systemCodePage => _api()?.codePage;

  /// 代码页解码在本机是否真的可用（探测结果，不受 [debugDecoderOverride] 影响）。
  static bool get isAvailable => _api() != null;

  /// 按系统 ANSI 代码页解码；不可用或整段字节不合法时返回 null。
  static String? decode(List<int> bytes) {
    if (bytes.isEmpty) return '';
    final String? Function(List<int> bytes)? override = debugDecoderOverride;
    if (override != null) {
      try {
        return override(bytes);
      } catch (_) {
        // 注入实现自己炸了也当成"不可用"，别污染主解码链
        return null;
      }
    }
    final _Kernel32? api = _api();
    if (api == null) return null;
    try {
      return api.decodeSystemCodePage(bytes);
    } catch (_) {
      // FFI 层任何意外都不上抛：解码链还有 latin1 兜底，工具调用不该因此失败。
      return null;
    }
  }

  /// 按系统 ANSI 代码页把 [text] 编回字节；不可用或**有字符编不回去**时返回 null。
  ///
  /// 与 [decode] 对称，供"非 UTF-8 文件按原编码写回"用（edit/覆盖写）。用
  /// WideCharToMultiByte(CP_ACP, 0, …, lpUsedDefaultChar)：只要有一个字符在该代码页下
  /// 表示不了，usedDefaultChar 就会被置位，我们据此**如实失败**（返回 null），
  /// 绝不写 '?' 顶替——那才是真的破坏用户文件。
  static List<int>? encode(String text) {
    if (text.isEmpty) return const <int>[];
    final _Kernel32? api = _api();
    if (api == null) return null;
    try {
      return api.encodeSystemCodePage(text);
    } catch (_) {
      // 同 decode：FFI 层的任何意外都不上抛，由调用方决定"拒绝还是换编码"
      return null;
    }
  }

  static bool _probed = false;
  static _Kernel32? _kernel32;

  static _Kernel32? _api() {
    if (_probed) return _kernel32;
    _probed = true;
    // 平台守卫放在最前面：非 Windows 不加载也不调用任何 kernel32 符号。
    if (!Platform.isWindows) return null;
    try {
      _kernel32 = _Kernel32(DynamicLibrary.open('kernel32.dll'));
    } catch (_) {
      _kernel32 = null;
    }
    return _kernel32;
  }
}

typedef _MultiByteToWideCharNative = Int32 Function(
  Uint32 codePage,
  Uint32 flags,
  Pointer<Uint8> multiByte,
  Int32 multiByteLength,
  Pointer<Uint16> wideChar,
  Int32 wideCharLength,
);
typedef _MultiByteToWideCharDart = int Function(
  int codePage,
  int flags,
  Pointer<Uint8> multiByte,
  int multiByteLength,
  Pointer<Uint16> wideChar,
  int wideCharLength,
);
typedef _WideCharToMultiByteNative = Int32 Function(
  Uint32 codePage,
  Uint32 flags,
  Pointer<Uint16> wideChar,
  Int32 wideCharLength,
  Pointer<Uint8> multiByte,
  Int32 multiByteLength,
  Pointer<Uint8> defaultChar,
  Pointer<Int32> usedDefaultChar,
);
typedef _WideCharToMultiByteDart = int Function(
  int codePage,
  int flags,
  Pointer<Uint16> wideChar,
  int wideCharLength,
  Pointer<Uint8> multiByte,
  int multiByteLength,
  Pointer<Uint8> defaultChar,
  Pointer<Int32> usedDefaultChar,
);
typedef _GetAcpNative = Uint32 Function();
typedef _GetAcpDart = int Function();
typedef _LocalAllocNative = Pointer<Void> Function(Uint32 flags, UintPtr bytes);
typedef _LocalAllocDart = Pointer<Void> Function(int flags, int bytes);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> memory);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void> memory);

/// kernel32 里解码要用到的入口。
///
/// 为什么用 LocalAlloc/LocalFree 而不是 `package:ffi` 的 `calloc`：本包依赖表里没有
/// `ffi`（只有 path/dartssh2），为一个解码引入新依赖要动 pubspec/lock；kernel32 自带
/// 分配器足够用，也少一个平台差异点。
///
/// 为什么用 `Pointer<Uint16>.asTypedList` 取回字符串：本 SDK（Dart 3.13.4）的 `dart:ffi`
/// 里并没有 `Utf16` 类型（`Pointer<Utf16>` 属于 `package:ffi`），而 `Uint16List` 视图
/// **就是** UTF-16 代码单元视图，还能按"实际写入长度"取——不依赖 NUL 终止，文本里本来
/// 就含 NUL 也不会截断。
final class _Kernel32 {
  /// CP_ACP：系统 ANSI 代码页（不是控制台代码页，chcp 改不了它）。
  static const int _cpAcp = 0;

  /// MB_ERR_INVALID_CHARS：遇到非法序列就让整次调用失败（返回 0）。
  static const int _mbErrInvalidChars = 0x00000008;

  /// LocalAlloc 的 LMEM_FIXED：返回值就是可用的内存指针。
  static const int _lmemFixed = 0x0000;

  _Kernel32(DynamicLibrary library)
    : _multiByteToWideChar = library
          .lookupFunction<_MultiByteToWideCharNative, _MultiByteToWideCharDart>(
            'MultiByteToWideChar',
          ),
      _wideCharToMultiByte = library
          .lookupFunction<_WideCharToMultiByteNative, _WideCharToMultiByteDart>(
            'WideCharToMultiByte',
          ),
      _getAcp = library.lookupFunction<_GetAcpNative, _GetAcpDart>('GetACP'),
      _localAlloc = library.lookupFunction<_LocalAllocNative, _LocalAllocDart>(
        'LocalAlloc',
      ),
      _localFree = library.lookupFunction<_LocalFreeNative, _LocalFreeDart>(
        'LocalFree',
      );

  final _MultiByteToWideCharDart _multiByteToWideChar;
  final _WideCharToMultiByteDart _wideCharToMultiByte;
  final _GetAcpDart _getAcp;
  final _LocalAllocDart _localAlloc;
  final _LocalFreeDart _localFree;

  int get codePage => _getAcp();

  /// 严格按 CP_ACP 编码 [text]（要求非空）；有字符编不回去或任何一步失败时返回 null。
  ///
  /// [String.codeUnits] 就是 UTF-16 代码单元序列，正好是 WideCharToMultiByte 的输入；
  /// 用完必须把原生缓冲显式释放（Dart 的 GC 不管这块）。
  List<int>? encodeSystemCodePage(String text) {
    final List<int> units = text.codeUnits;
    final Pointer<Uint16> input = _localAlloc(
      _lmemFixed,
      units.length * 2,
    ).cast<Uint16>();
    if (input == nullptr) return null;
    Pointer<Void> output = nullptr;
    Pointer<Int32> usedDefault = nullptr;
    try {
      input.asTypedList(units.length).setAll(0, units);
      usedDefault = _localAlloc(_lmemFixed, 4).cast<Int32>();
      if (usedDefault == nullptr) return null;
      usedDefault.value = 0;
      final int length = _wideCharToMultiByte(
        _cpAcp,
        0,
        input,
        units.length,
        nullptr,
        0,
        nullptr,
        nullptr,
      );
      if (length <= 0) return null;
      output = _localAlloc(_lmemFixed, length);
      if (output == nullptr) return null;
      final int written = _wideCharToMultiByte(
        _cpAcp,
        0,
        input,
        units.length,
        output.cast<Uint8>(),
        length,
        nullptr,
        usedDefault,
      );
      if (written != length) return null;
      // 有字符编不回去（会被写成 '?'）→ 如实失败
      if (usedDefault.value != 0) return null;
      // 原生内存必须在 free 之前拷出来：asTypedList 只是视图
      return List<int>.of(output.cast<Uint8>().asTypedList(written));
    } finally {
      _localFree(input.cast<Void>());
      if (output != nullptr) _localFree(output);
      if (usedDefault != nullptr) _localFree(usedDefault.cast<Void>());
    }
  }

  /// 严格按 CP_ACP 解码 [bytes]（要求非空）；不合法或任何一步失败时返回 null。
  String? decodeSystemCodePage(List<int> bytes) {
    // 只有 0..255 才是字节；越界值说明调用方给错了东西，按"解不开"处理。
    for (final int byte in bytes) {
      if (byte < 0 || byte > 0xFF) return null;
    }
    final Pointer<Uint8> input = _localAlloc(
      _lmemFixed,
      bytes.length,
    ).cast<Uint8>();
    if (input == nullptr) return null;
    Pointer<Void> output = nullptr;
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      // 第一趟只问长度（cchWideChar = 0）：非法序列在这里就会被 MB_ERR_INVALID_CHARS 拦下。
      final int wideLength = _multiByteToWideChar(
        _cpAcp,
        _mbErrInvalidChars,
        input,
        bytes.length,
        nullptr,
        0,
      );
      if (wideLength <= 0) return null;
      output = _localAlloc(_lmemFixed, wideLength * 2);
      if (output == nullptr) return null;
      final int written = _multiByteToWideChar(
        _cpAcp,
        _mbErrInvalidChars,
        input,
        bytes.length,
        output.cast<Uint16>(),
        wideLength,
      );
      if (written != wideLength) return null;
      return String.fromCharCodes(output.cast<Uint16>().asTypedList(written));
    } finally {
      // 分配的原生内存必须显式释放（Dart 的 GC 不管这块）
      _localFree(input.cast<Void>());
      if (output != nullptr) _localFree(output);
    }
  }
}
