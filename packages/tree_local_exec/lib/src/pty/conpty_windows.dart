/// Windows **ConPTY**（伪控制台）后端：`dart:ffi` 直调 `kernel32`。
///
/// ## 用法（Microsoft 的官方姿势，改代码前先读）
/// 1. 自己建**两条匿名管道**：
///    - `CreatePipe(&inRead, &inWrite)`：**我们写 `inWrite`**，ConPTY 从 `inRead` 读；
///    - `CreatePipe(&outRead, &outWrite)`：ConPTY 往 `outWrite` 写，**我们从 `outRead` 读**；
/// 2. `CreatePseudoConsole(size, inRead, outWrite, 0, &hPC)`；
/// 3. `CreateProcessW` 必须带 `EXTENDED_STARTUPINFO_PRESENT` + `STARTUPINFOEXW`，
///    并把 `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` 指向 `HPCON`；`bInheritHandles=FALSE`
///    （ConPTY 自己把控制台接给子进程，不需要继承我们的句柄）；
/// 4. `CreateProcessW` 成功后**立刻关掉我们这侧的 `inRead` / `outWrite`**（ConPTY 已复制
///    它要用的那一端）——不关的话读端永远等不到 EOF。
///
/// ## 必须知道的取舍
/// - **阻塞 `ReadFile` 放在自己的 isolate 里**：输出管道在子进程退出前不会 EOF，
///   在主 isolate 上读会把调用方（核心的事件循环）整个卡死。isolate 通过 `SendPort`
///   把字节块交回来；句柄以`整数地址`跨 isolate 传递（同一进程的句柄表是共享的）。
/// - **ConPTY 是 Win10 1809+ 的能力**：`CreatePseudoConsole` 等符号缺失时抛
///   [PtyUnsupportedException]（可读中文），**不崩**。
/// - **ConPTY 会重绘**：它内部维护屏幕缓冲，子进程输出经它"翻译"成 VT 序列再给我们
///   （这也是 cmd.exe 这种不会发 VT 的程序能在终端里正常显示的原因）。所以输出是
///   **终端语义的字节流**，不是子进程 stdout 的逐字节透传——要逐字节原样就别用 PTY。
/// - **本 SDK（Dart 3.13.4）的 `dart:ffi` 没有 `Utf16` 类型**（那是 `package:ffi` 的），
///   所以宽字符串一律用 `Pointer<Uint16>` + `LocalAlloc` 手写 UTF-16 缓冲；
///   本包依赖表里也没有 `ffi`，因此这里同样用 `kernel32` 自带的 `LocalAlloc/LocalFree`。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'pty_session.dart';

// ── Win32 常量 ───────────────────────────────────────────────────────────
const int _lmemFixed = 0x0000;

/// `LMEM_ZEROINIT`：`LocalAlloc` **默认不清零**（见 `_ConPtyApi.allocZeroed`）。
const int _lmemZeroInit = 0x0040;
const int _extendedStartupInfoPresent = 0x00080000;
const int _createUnicodeEnvironment = 0x00000400;
const int _procThreadAttributePseudoConsole = 0x00020016;

/// `STARTF_USESTDHANDLES`：**必须设**，且三个标准句柄都留 NULL（原因见 [startConPtySession]
/// 里那段注释——不设它，子进程会挂到调用方自己的控制台而不是伪控制台）。
const int _startfUseStdHandles = 0x00000100;
const int _stillActive = 259;

/// 同步读的块大小（ConPTY 一次最多给这么多字节）。
const int _readChunkBytes = 16 * 1024;

/// 退出码轮询间隔：`WaitForSingleObject` 会阻塞调用方 isolate，所以用非阻塞的
/// `GetExitCodeProcess` 轮询；30ms 对"终端里敲 exit 后界面多久更新"完全够用。
const Duration _exitPollInterval = Duration(milliseconds: 30);

// ── Win32 结构体 ─────────────────────────────────────────────────────────

/// `COORD`：X = 列，Y = 行（两个 SHORT）。
final class _Coord extends Struct {
  @Int16()
  external int x;

  @Int16()
  external int y;
}

/// `STARTUPINFOW`（只用到 `cb` 与 `lpAttributeList`，其余字段保持零）。
final class _StartupInfoW extends Struct {
  @Uint32()
  external int cb;

  external Pointer<Uint16> lpReserved;
  external Pointer<Uint16> lpDesktop;
  external Pointer<Uint16> lpTitle;

  @Uint32()
  external int dwX;

  @Uint32()
  external int dwY;

  @Uint32()
  external int dwXSize;

  @Uint32()
  external int dwYSize;

  @Uint32()
  external int dwXCountChars;

  @Uint32()
  external int dwYCountChars;

  @Uint32()
  external int dwFillAttribute;

  @Uint32()
  external int dwFlags;

  @Uint16()
  external int wShowWindow;

  @Uint16()
  external int cbReserved2;

  external Pointer<Uint8> lpReserved2;
  external Pointer<Void> hStdInput;
  external Pointer<Void> hStdOutput;
  external Pointer<Void> hStdError;
}

/// `STARTUPINFOEXW`：`STARTUPINFOW` + 属性表指针（ConPTY 就靠它传进去）。
final class _StartupInfoExW extends Struct {
  external _StartupInfoW startupInfo;
  external Pointer<Void> lpAttributeList;
}

/// `PROCESS_INFORMATION`。
final class _ProcessInformation extends Struct {
  external Pointer<Void> hProcess;
  external Pointer<Void> hThread;

  @Uint32()
  external int dwProcessId;

  @Uint32()
  external int dwThreadId;
}

// ── kernel32 入口的类型 ──────────────────────────────────────────────────

typedef _CreatePseudoConsoleNative = Int32 Function(
  _Coord size,
  Pointer<Void> hInput,
  Pointer<Void> hOutput,
  Uint32 flags,
  Pointer<Pointer<Void>> phPC,
);
typedef _CreatePseudoConsoleDart = int Function(
  _Coord size,
  Pointer<Void> hInput,
  Pointer<Void> hOutput,
  int flags,
  Pointer<Pointer<Void>> phPC,
);

typedef _ResizePseudoConsoleNative = Int32 Function(
  Pointer<Void> hPC,
  _Coord size,
);
typedef _ResizePseudoConsoleDart = int Function(Pointer<Void> hPC, _Coord size);

typedef _ClosePseudoConsoleNative = Void Function(Pointer<Void> hPC);
typedef _ClosePseudoConsoleDart = void Function(Pointer<Void> hPC);

typedef _CreatePipeNative = Int32 Function(
  Pointer<Pointer<Void>> hReadPipe,
  Pointer<Pointer<Void>> hWritePipe,
  Pointer<Void> pipeAttributes,
  Uint32 size,
);
typedef _CreatePipeDart = int Function(
  Pointer<Pointer<Void>> hReadPipe,
  Pointer<Pointer<Void>> hWritePipe,
  Pointer<Void> pipeAttributes,
  int size,
);

typedef _InitializeProcThreadAttributeListNative = Int32 Function(
  Pointer<Void> attributeList,
  Uint32 attributeCount,
  Uint32 flags,
  Pointer<UintPtr> size,
);
typedef _InitializeProcThreadAttributeListDart = int Function(
  Pointer<Void> attributeList,
  int attributeCount,
  int flags,
  Pointer<UintPtr> size,
);

typedef _UpdateProcThreadAttributeNative = Int32 Function(
  Pointer<Void> attributeList,
  Uint32 flags,
  UintPtr attribute,
  Pointer<Void> value,
  UintPtr size,
  Pointer<Void> previousValue,
  Pointer<UintPtr> returnSize,
);
typedef _UpdateProcThreadAttributeDart = int Function(
  Pointer<Void> attributeList,
  int flags,
  int attribute,
  Pointer<Void> value,
  int size,
  Pointer<Void> previousValue,
  Pointer<UintPtr> returnSize,
);

typedef _DeleteProcThreadAttributeListNative = Void Function(
  Pointer<Void> attributeList,
);
typedef _DeleteProcThreadAttributeListDart = void Function(
  Pointer<Void> attributeList,
);

typedef _CreateProcessWNative = Int32 Function(
  Pointer<Uint16> applicationName,
  Pointer<Uint16> commandLine,
  Pointer<Void> processAttributes,
  Pointer<Void> threadAttributes,
  Int32 inheritHandles,
  Uint32 creationFlags,
  Pointer<Void> environment,
  Pointer<Uint16> currentDirectory,
  Pointer<_StartupInfoExW> startupInfo,
  Pointer<_ProcessInformation> processInformation,
);
typedef _CreateProcessWDart = int Function(
  Pointer<Uint16> applicationName,
  Pointer<Uint16> commandLine,
  Pointer<Void> processAttributes,
  Pointer<Void> threadAttributes,
  int inheritHandles,
  int creationFlags,
  Pointer<Void> environment,
  Pointer<Uint16> currentDirectory,
  Pointer<_StartupInfoExW> startupInfo,
  Pointer<_ProcessInformation> processInformation,
);

typedef _ReadFileNative = Int32 Function(
  Pointer<Void> handle,
  Pointer<Uint8> buffer,
  Uint32 bytesToRead,
  Pointer<Uint32> bytesRead,
  Pointer<Void> overlapped,
);
typedef _ReadFileDart = int Function(
  Pointer<Void> handle,
  Pointer<Uint8> buffer,
  int bytesToRead,
  Pointer<Uint32> bytesRead,
  Pointer<Void> overlapped,
);

typedef _WriteFileNative = Int32 Function(
  Pointer<Void> handle,
  Pointer<Uint8> buffer,
  Uint32 bytesToWrite,
  Pointer<Uint32> bytesWritten,
  Pointer<Void> overlapped,
);
typedef _WriteFileDart = int Function(
  Pointer<Void> handle,
  Pointer<Uint8> buffer,
  int bytesToWrite,
  Pointer<Uint32> bytesWritten,
  Pointer<Void> overlapped,
);

typedef _GetExitCodeProcessNative = Int32 Function(
  Pointer<Void> handle,
  Pointer<Uint32> exitCode,
);
typedef _GetExitCodeProcessDart = int Function(
  Pointer<Void> handle,
  Pointer<Uint32> exitCode,
);

typedef _TerminateProcessNative = Int32 Function(
  Pointer<Void> handle,
  Uint32 exitCode,
);
typedef _TerminateProcessDart = int Function(Pointer<Void> handle, int exitCode);

typedef _CloseHandleNative = Int32 Function(Pointer<Void> handle);
typedef _CloseHandleDart = int Function(Pointer<Void> handle);

typedef _LocalAllocNative = Pointer<Void> Function(Uint32 flags, UintPtr bytes);
typedef _LocalAllocDart = Pointer<Void> Function(int flags, int bytes);

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> memory);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void> memory);

typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

/// kernel32 里 ConPTY 需要的全部入口。
///
/// 解析失败（库不存在 / 符号缺失 = Win10 1809 之前的系统）由调用方翻成可读错误。
final class _ConPtyApi {
  _ConPtyApi(DynamicLibrary library, this.libraryName)
    : createPseudoConsole = library
          .lookupFunction<
            _CreatePseudoConsoleNative,
            _CreatePseudoConsoleDart
          >('CreatePseudoConsole'),
      resizePseudoConsole = library
          .lookupFunction<
            _ResizePseudoConsoleNative,
            _ResizePseudoConsoleDart
          >('ResizePseudoConsole'),
      closePseudoConsole = library
          .lookupFunction<
            _ClosePseudoConsoleNative,
            _ClosePseudoConsoleDart
          >('ClosePseudoConsole'),
      createPipe = library
          .lookupFunction<_CreatePipeNative, _CreatePipeDart>('CreatePipe'),
      initializeProcThreadAttributeList = library
          .lookupFunction<
            _InitializeProcThreadAttributeListNative,
            _InitializeProcThreadAttributeListDart
          >('InitializeProcThreadAttributeList'),
      updateProcThreadAttribute = library
          .lookupFunction<
            _UpdateProcThreadAttributeNative,
            _UpdateProcThreadAttributeDart
          >('UpdateProcThreadAttribute'),
      deleteProcThreadAttributeList = library
          .lookupFunction<
            _DeleteProcThreadAttributeListNative,
            _DeleteProcThreadAttributeListDart
          >('DeleteProcThreadAttributeList'),
      createProcess = library
          .lookupFunction<_CreateProcessWNative, _CreateProcessWDart>(
            'CreateProcessW',
          ),
      readFile = library
          .lookupFunction<_ReadFileNative, _ReadFileDart>('ReadFile'),
      writeFile = library
          .lookupFunction<_WriteFileNative, _WriteFileDart>('WriteFile'),
      getExitCodeProcess = library
          .lookupFunction<
            _GetExitCodeProcessNative,
            _GetExitCodeProcessDart
          >('GetExitCodeProcess'),
      terminateProcess = library
          .lookupFunction<_TerminateProcessNative, _TerminateProcessDart>(
            'TerminateProcess',
          ),
      closeHandle = library
          .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle'),
      localAlloc = library
          .lookupFunction<_LocalAllocNative, _LocalAllocDart>('LocalAlloc'),
      localFree = library
          .lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree'),
      getLastError = library
          .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
            'GetLastError',
          );

  /// 默认解析的库（ConPTY 在 kernel32 里）。
  static const String defaultLibrary = 'kernel32.dll';

  /// 按库名缓存（`DynamicLibrary.open` 不能每条会话都重做）。
  static final Map<String, _ConPtyApi> _cache = <String, _ConPtyApi>{};

  /// 解析 [libraryName]；缺库/缺符号都**抛出**（调用方转成可读错误）。
  static _ConPtyApi open(String libraryName) {
    final _ConPtyApi? cached = _cache[libraryName];
    if (cached != null) return cached;
    final _ConPtyApi api = _ConPtyApi(
      DynamicLibrary.open(libraryName),
      libraryName,
    );
    _cache[libraryName] = api;
    return api;
  }

  /// 解析失败返回 null（读取 isolate 用：它自己再解析一次，失败要能如实回报）。
  static _ConPtyApi? tryOpen(String libraryName) {
    try {
      return open(libraryName);
    } on Object {
      return null;
    }
  }

  final String libraryName;

  final _CreatePseudoConsoleDart createPseudoConsole;
  final _ResizePseudoConsoleDart resizePseudoConsole;
  final _ClosePseudoConsoleDart closePseudoConsole;
  final _CreatePipeDart createPipe;
  final _InitializeProcThreadAttributeListDart initializeProcThreadAttributeList;
  final _UpdateProcThreadAttributeDart updateProcThreadAttribute;
  final _DeleteProcThreadAttributeListDart deleteProcThreadAttributeList;
  final _CreateProcessWDart createProcess;
  final _ReadFileDart readFile;
  final _WriteFileDart writeFile;
  final _GetExitCodeProcessDart getExitCodeProcess;
  final _TerminateProcessDart terminateProcess;
  final _CloseHandleDart closeHandle;
  final _LocalAllocDart localAlloc;
  final _LocalFreeDart localFree;
  final _GetLastErrorDart getLastError;

  /// 分配一块原生内存（`LocalAlloc` 的 LMEM_FIXED：返回值就是可用指针）。
  ///
  /// **不清零**：只给"马上会被自己写满"的缓冲用（UTF-16 字符串、读写缓冲）。
  Pointer<Uint8> alloc(int bytes) => localAlloc(_lmemFixed, bytes).cast<Uint8>();

  /// 分配一块**清零**的原生内存（结构体 / 属性表 / 句柄出参槽一律用它）。
  ///
  /// 为什么必须有：`LocalAlloc` 不像 `calloc`，它**不清零**。`STARTUPINFOW` 里
  /// `lpDesktop` / `lpTitle` / `dwFlags` 若留着垃圾值，`CreateProcessW` 会拿垃圾指针去
  /// `wcslen` —— 实测就是在这个位置访问违例崩掉的（首次调用侥幸拿到新页（零），
  /// 第二次拿到复用页（有垃圾）就崩；这种"偶发崩溃"必须归零，不能碰运气）。
  Pointer<Uint8> allocZeroed(int bytes) =>
      localAlloc(_lmemFixed | _lmemZeroInit, bytes).cast<Uint8>();

  /// 分配一块 UTF-16（含结尾 NUL）缓冲——本 SDK 没有 `Pointer<Utf16`。
  Pointer<Uint16> allocUtf16(String text) {
    final List<int> units = text.codeUnits;
    final Pointer<Uint16> buffer = alloc(
      (units.length + 1) * 2,
    ).cast<Uint16>();
    if (buffer == nullptr) return buffer;
    final Uint16List view = buffer.asTypedList(units.length + 1);
    view.setRange(0, units.length, units);
    view[units.length] = 0;
    return buffer;
  }

  /// 释放 [memory]（null 是安全的）。
  void free(Pointer<Void> memory) {
    if (memory != nullptr) localFree(memory);
  }

  /// 上一次 Win32 调用的错误码（错误文案里带上它，排障不用猜）。
  int lastError() => getLastError();

  /// 分配一个 `COORD`（`Struct` 不能用普通构造器实例化，只能落到原生内存上）。
  Pointer<_Coord> allocCoord(int columns, int rows) {
    final Pointer<_Coord> slot = allocZeroed(sizeOf<_Coord>()).cast<_Coord>();
    slot.ref.x = columns;
    slot.ref.y = rows;
    return slot;
  }

  /// 取 [handle] 的退出码；仍在跑时返回 [_stillActive]。
  int exitCodeOf(Pointer<Void> handle, Pointer<Uint32> slot) {
    slot.value = 0;
    if (getExitCodeProcess(handle, slot) == 0) return _stillActive;
    return slot.value;
  }
}

/// 把列/行夹进 `SHORT` 能表达的范围（`COORD` 是 int16；0 或负值会让终端显示错乱）。
int _clampSize(int value, int fallback) {
  if (value < 1) return fallback;
  return value > 32767 ? 32767 : value;
}

/// 起一个 ConPTY 会话。
///
/// [kernel32Library] 只给测试/诊断换（默认 `kernel32.dll`，见 `ptyDebugKernel32Library`）。
Future<PtySession> startConPtySession({
  String command = '',
  required String workingDirectory,
  int columns = 80,
  int rows = 24,
  Map<String, String>? environment,
  void Function(String message)? log,
  String kernel32Library = _ConPtyApi.defaultLibrary,
}) async {
  if (!Platform.isWindows) {
    throw PtyUnsupportedException(
      'ConPTY 后端只能在 Windows 上使用（当前平台：${Platform.operatingSystem}）',
    );
  }
  final int cols = _clampSize(columns, 80);
  final int rowsCount = _clampSize(rows, 24);
  final String commandLine = command.trim().isEmpty ? 'cmd.exe' : command.trim();

  final _ConPtyApi api;
  try {
    api = _ConPtyApi.open(kernel32Library);
  } on Object catch (error) {
    throw PtyUnsupportedException(
      '本机没有可用的 ConPTY API（需要 Windows 10 1809 及以上）：'
      '从 $kernel32Library 解析 CreatePseudoConsole / ResizePseudoConsole / '
      'ClosePseudoConsole 失败（$error）。请改用一次性命令执行，或升级系统。',
    );
  }

  try {
    await Directory(workingDirectory).create(recursive: true);
  } on Object catch (error) {
    throw PtySessionException('工作目录不可用（$workingDirectory）：$error');
  }

  // 出参槽：CreatePipe ×2 的 4 个 HANDLE + HPCON。一次分配、一次释放。
  final Pointer<Pointer<Void>> slots = api
      .allocZeroed(sizeOf<Pointer<Void>>() * 5)
      .cast<Pointer<Void>>();
  final Pointer<Pointer<Void>> inReadSlot = slots;
  final Pointer<Pointer<Void>> inWriteSlot = slots + 1;
  final Pointer<Pointer<Void>> outReadSlot = slots + 2;
  final Pointer<Pointer<Void>> outWriteSlot = slots + 3;
  final Pointer<Pointer<Void>> hpcSlot = slots + 4;
  final Pointer<UintPtr> sizeSlot = api
      .allocZeroed(sizeOf<UintPtr>())
      .cast<UintPtr>();

  Pointer<Uint16> commandLineBuffer = nullptr;
  Pointer<Uint16> cwdBuffer = nullptr;
  Pointer<Uint16> envBuffer = nullptr;
  Pointer<_Coord> coordSlot = nullptr;
  Pointer<_StartupInfoExW> startupInfo = nullptr;
  Pointer<_ProcessInformation> processInfo = nullptr;
  Pointer<Void> attributeList = nullptr;
  Pointer<Void> pseudoConsole = nullptr;
  Pointer<Void> processHandle = nullptr;
  Pointer<Void> threadHandle = nullptr;
  bool handedOver = false;
  try {
    if (api.createPipe(inReadSlot, inWriteSlot, nullptr, 0) == 0) {
      throw PtySessionException('CreatePipe 失败（Win32 错误 ${api.lastError()}）');
    }
    if (api.createPipe(outReadSlot, outWriteSlot, nullptr, 0) == 0) {
      throw PtySessionException('CreatePipe 失败（Win32 错误 ${api.lastError()}）');
    }

    coordSlot = api.allocCoord(cols, rowsCount);
    final int createResult = api.createPseudoConsole(
      coordSlot.ref,
      inReadSlot.value,
      outWriteSlot.value,
      0,
      hpcSlot,
    );
    api.free(coordSlot.cast<Void>());
    coordSlot = nullptr;
    if (createResult < 0) {
      throw PtyUnsupportedException(
        'CreatePseudoConsole 失败（HRESULT '
        '0x${createResult.toUnsigned(32).toRadixString(16)}）：'
        '本机可能不支持 ConPTY（需要 Windows 10 1809 及以上）',
      );
    }
    pseudoConsole = hpcSlot.value;

    // 属性表：第一次调用只问大小（返回 0 + ERROR_INSUFFICIENT_BUFFER），按回传大小分配。
    sizeSlot.value = 0;
    api.initializeProcThreadAttributeList(nullptr, 1, 0, sizeSlot);
    if (sizeSlot.value <= 0) {
      throw PtySessionException(
        'InitializeProcThreadAttributeList 未给出属性表大小'
        '（Win32 错误 ${api.lastError()}）',
      );
    }
    attributeList = api.allocZeroed(sizeSlot.value).cast<Void>();
    if (api.initializeProcThreadAttributeList(attributeList, 1, 0, sizeSlot) ==
        0) {
      throw PtySessionException(
        'InitializeProcThreadAttributeList 失败（Win32 错误 ${api.lastError()}）',
      );
    }
    // **踩坑点（这条错了会以 0xC0000142 STATUS_DLL_INIT_FAILED 收场）**：
    // PSEUDOCONSOLE 这个属性要把 HPCON **本身**当 lpValue 传，而不是传 &HPCON。
    // 传 &HPCON（虽然符合 UpdateProcThreadAttribute 通用文档里「lpValue 是值的指针」）
    // 实测会让子进程拿不到控制台、立刻以 STATUS_DLL_INIT_FAILED 退出；
    // 这与 Microsoft 官方 ConPTY 示例一致（示例直接把 hPC 传进去）。
    if (api.updateProcThreadAttribute(
          attributeList,
          0,
          _procThreadAttributePseudoConsole,
          pseudoConsole,
          sizeOf<Pointer<Void>>(),
          nullptr,
          nullptr,
        ) ==
        0) {
      throw PtySessionException(
        'UpdateProcThreadAttribute(PSEUDOCONSOLE) 失败'
        '（Win32 错误 ${api.lastError()}）',
      );
    }

    startupInfo = api
        .allocZeroed(sizeOf<_StartupInfoExW>())
        .cast<_StartupInfoExW>();
    processInfo = api
        .allocZeroed(sizeOf<_ProcessInformation>())
        .cast<_ProcessInformation>();
    startupInfo.ref.startupInfo.cb = sizeOf<_StartupInfoExW>();
    startupInfo.ref.lpAttributeList = attributeList;
    // **踩坑点（不设它子进程会挂到调用方自己的控制台）**：
    // ConPTY 的客户端进程必须「没有可继承的标准句柄」，否则 CreateProcessW 会让它挂到
    // **调用方**已有的控制台上（伪控制台属性等于白设）：实测表现为 cmd.exe 把横幅打到
    // 宿主控制台、随即以退出码 0 结束，而伪控制台那头只收到一串开关模式的空序列。
    // 官方文档的示例里没有这一条，但 node-pty（microsoft/node-pty 的 src/win/conpty.cc）
    // 在实测中必须这么写：dwFlags |= STARTF_USESTDHANDLES 且 hStd* 三个都留 NULL。
    startupInfo.ref.startupInfo.dwFlags = _startfUseStdHandles;

    commandLineBuffer = api.allocUtf16(commandLine);
    cwdBuffer = api.allocUtf16(Directory(workingDirectory).absolute.path);
    if (environment != null) {
      envBuffer = api.allocUtf16(_environmentBlock(environment));
    }
    if (commandLineBuffer == nullptr ||
        cwdBuffer == nullptr ||
        (environment != null && envBuffer == nullptr)) {
      throw PtySessionException('分配 CreateProcessW 参数缓冲失败（原生内存不足）');
    }

    final int creationFlags =
        _extendedStartupInfoPresent |
        (envBuffer == nullptr ? 0 : _createUnicodeEnvironment);
    final int created = api.createProcess(
      nullptr,
      commandLineBuffer,
      nullptr,
      nullptr,
      0,
      creationFlags,
      envBuffer.cast<Void>(),
      cwdBuffer,
      startupInfo,
      processInfo,
    );
    if (created == 0) {
      throw PtySessionException(
        'CreateProcessW 失败（Win32 错误 ${api.lastError()}）：$commandLine',
      );
    }
    processHandle = processInfo.ref.hProcess;
    threadHandle = processInfo.ref.hThread;
    log?.call(
      '[pty] ConPTY 已起进程 pid=${processInfo.ref.dwProcessId} '
      '（$commandLine，${cols}x$rowsCount）',
    );

    // ConPTY 复制了自己要用的那一端：我们这侧的 inRead / outWrite 必须关掉，
    // 否则读端等不到 EOF（子进程退出后我们仍握着写端的副本）。
    api.closeHandle(inReadSlot.value);
    inReadSlot.value = nullptr;
    api.closeHandle(outWriteSlot.value);
    outWriteSlot.value = nullptr;
    api.closeHandle(threadHandle);
    threadHandle = nullptr;
    api.deleteProcThreadAttributeList(attributeList);
    attributeList = nullptr;

    final _ConPtySession session = _ConPtySession(
      api: api,
      commandLine: commandLine,
      inputWrite: inWriteSlot.value,
      outputRead: outReadSlot.value,
      process: processHandle,
      pseudoConsole: pseudoConsole,
      log: log,
    );
    inWriteSlot.value = nullptr;
    outReadSlot.value = nullptr;
    processHandle = nullptr;
    pseudoConsole = nullptr;
    handedOver = true;
    session.start();
    return session;
  } finally {
    api.free(commandLineBuffer.cast<Void>());
    api.free(cwdBuffer.cast<Void>());
    api.free(envBuffer.cast<Void>());
    api.free(coordSlot.cast<Void>());
    api.free(startupInfo.cast<Void>());
    api.free(processInfo.cast<Void>());
    api.free(slots.cast<Void>());
    api.free(sizeSlot.cast<Void>());
    if (!handedOver) {
      // 失败路径：把已经建出来的东西全关掉，一个句柄都不留（也不留孤儿进程）。
      for (final Pointer<Pointer<Void>> slot in <Pointer<Pointer<Void>>>[
        inReadSlot,
        inWriteSlot,
        outReadSlot,
        outWriteSlot,
      ]) {
        if (slot.value != nullptr) {
          api.closeHandle(slot.value);
          slot.value = nullptr;
        }
      }
      if (threadHandle != nullptr) api.closeHandle(threadHandle);
      if (processHandle != nullptr) api.closeHandle(processHandle);
      if (attributeList != nullptr) {
        api.deleteProcThreadAttributeList(attributeList);
      }
      if (pseudoConsole != nullptr) api.closePseudoConsole(pseudoConsole);
    }
  }
}

/// 拼一个 `CREATE_UNICODE_ENVIRONMENT` 要的宽字符环境块：
/// `KEY=VALUE\0…\0`（结尾双 NUL），在父进程环境之上**叠加/覆盖** [environment]。
String _environmentBlock(Map<String, String> environment) {
  final Map<String, String> merged = <String, String>{
    ...Platform.environment,
    ...environment,
  };
  final List<String> entries = <String>[
    for (final MapEntry<String, String> entry in merged.entries)
      if (entry.key.isNotEmpty && !entry.key.contains('='))
        '${entry.key}=${entry.value}',
  ]..sort();
  return '${entries.join('\u0000')}\u0000';
}

/// 一个 ConPTY 会话。
///
/// 生命周期（谁负责关什么）：
/// - **建会话的人**（[startConPtySession]）把 `inWrite` / `outRead` / 进程句柄 / HPCON
///   交给本类，之后**只由本类**关——失败路径的清理在构造函数之前就做完了；
/// - 进程自己退出（[GetExitCodeProcess] 不再是 `STILL_ACTIVE`）⇒ 关伪终端与输入写端，
///   读 isolate 因此拿到 EOF 自然收工；
/// - [close] 幂等：重复调用什么都不做，已经结束也不抛（接口契约）。
class _ConPtySession implements PtySession {
  _ConPtySession({
    required this.api,
    required this.commandLine,
    required this.inputWrite,
    required this.outputRead,
    required this.process,
    required this.pseudoConsole,
    this.log,
  });

  final _ConPtyApi api;
  final String commandLine;
  final void Function(String message)? log;

  Pointer<Void> inputWrite;
  Pointer<Void> outputRead;
  Pointer<Void> process;
  Pointer<Void> pseudoConsole;
  Pointer<Uint32> exitSlot = nullptr;

  final StreamController<List<int>> outputController =
      StreamController<List<int>>();
  final Completer<int> exitCompleter = Completer<int>();
  final Completer<void> readerDone = Completer<void>();

  Timer? exitTimer;
  Isolate? readerIsolate;

  /// 读 isolate 的消息端口：**必须显式关**——开着的 ReceivePort 会让 Dart VM
  /// 认为还有待处理事件，`dart run` / 测试进程就一直不退出。
  ReceivePort? readerPort;
  bool closed = false;
  bool exited = false;
  bool outputClosed = false;

  @override
  String get shell => commandLine;

  @override
  Stream<List<int>> get output => outputController.stream;

  @override
  Future<int> get exitCode => exitCompleter.future;

  /// 起轮询 + 读 isolate（由 [startConPtySession] 在交接完成后调用）。
  void start() {
    exitSlot = api.alloc(sizeOf<Uint32>()).cast<Uint32>();
    exitTimer = Timer.periodic(_exitPollInterval, (Timer _) => _pollExit());
    _spawnReader();
  }

  @override
  Future<void> write(List<int> data) async {
    if (closed) throw PtySessionException('会话已关闭，无法写入');
    if (data.isEmpty) return;
    final int length = data.length;
    final Pointer<Uint8> buffer = api.alloc(length);
    if (buffer == nullptr) {
      throw PtySessionException('分配写入缓冲失败（$length 字节）');
    }
    try {
      buffer.asTypedList(length).setAll(0, data);
      final Pointer<Uint32> written = api
          .alloc(sizeOf<Uint32>())
          .cast<Uint32>();
      try {
        written.value = 0;
        if (api.writeFile(inputWrite, buffer, length, written, nullptr) == 0) {
          throw PtySessionException(
            '写入伪终端失败（Win32 错误 ${api.lastError()}）',
          );
        }
      } finally {
        api.free(written.cast<Void>());
      }
    } finally {
      api.free(buffer.cast<Void>());
    }
  }

  @override
  Future<void> resize(int columns, int rows) async {
    final int cols = _clampSize(columns, 80);
    final int rowsCount = _clampSize(rows, 24);
    if (closed || pseudoConsole == nullptr) return;
    final Pointer<_Coord> coord = api.allocCoord(cols, rowsCount);
    final int result;
    try {
      result = api.resizePseudoConsole(pseudoConsole, coord.ref);
    } finally {
      api.free(coord.cast<Void>());
    }
    if (result < 0) {
      // 尺寸变化高频且可被下一次覆盖：只记日志，不抛（接口也不给调用方处理路径）。
      log?.call(
        '[pty] 调整伪终端尺寸失败（HRESULT '
        '0x${result.toUnsigned(32).toRadixString(16)}）：已忽略',
      );
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;

    // ① 关输入写端：子进程从伪终端读到 EOF。
    inputWrite = _closeHandle(inputWrite);
    // ② 关伪终端：输出写端随之关闭，读 isolate 拿到 EOF 自然收工。
    _releasePseudoConsole();
    // ③ 进程还活着就给它一点时间自己退出；仍不退出才终止（关掉终端标签不留孤儿 cmd.exe）。
    if (!exited) {
      await _waitExited(const Duration(milliseconds: 500));
    }
    if (!exited && process != nullptr) {
      api.terminateProcess(process, 1);
      await _waitExited(const Duration(milliseconds: 500));
    }
    if (!exited) {
      // 极端情况（句柄异常 / 终止也拿不到退出码）：按已终止收尾，别让 exitCode 永久悬着。
      _finish(1);
    }

    // ④ 读 isolate：正常已在 EOF 时退出；等不到就主动 kill（阻塞在原生 ReadFile 上的
    //    isolate 只能这样收，句柄关闭后它本来也会立刻返回）。
    if (!readerDone.isCompleted) {
      try {
        await readerDone.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        log?.call('[pty] 读取 isolate 未在 2s 内退出，已强制结束');
      }
    }
    readerIsolate?.kill(priority: Isolate.immediate);
    readerIsolate = null;

    // ⑤ 句柄与流收尾。
    outputRead = _closeHandle(outputRead);
    exitTimer?.cancel();
    exitTimer = null;
    if (exitSlot != nullptr) {
      api.free(exitSlot.cast<Void>());
      exitSlot = nullptr;
    }
    _closeOutput();
    if (!exitCompleter.isCompleted) exitCompleter.complete(0);
  }

  /// 等进程退出（已退出立即返回）。
  Future<void> _waitExited(Duration timeout) async {
    if (exited) return;
    try {
      await exitCompleter.future.timeout(timeout);
    } on TimeoutException {
      // 超时是正常分支：由调用方决定要不要终止
    }
  }

  void _pollExit() {
    if (exited || process == nullptr || exitSlot == nullptr) return;
    final int code = api.exitCodeOf(process, exitSlot);
    if (code == _stillActive) return;
    _finish(code);
  }

  /// 进程结束后的收尾（幂等）。
  void _finish(int code) {
    if (exited) return;
    exited = true;
    log?.call('[pty] 子进程已结束：退出码 $code');
    exitTimer?.cancel();
    exitTimer = null;
    if (!exitCompleter.isCompleted) exitCompleter.complete(code);
    // 进程结束 ⇒ 关伪终端与输入写端：ConPTY 的写端随之关闭，读 isolate 拿到 EOF。
    _releasePseudoConsole();
    inputWrite = _closeHandle(inputWrite);
    process = _closeHandle(process);
  }

  void _releasePseudoConsole() {
    if (pseudoConsole == nullptr) return;
    api.closePseudoConsole(pseudoConsole);
    pseudoConsole = nullptr;
  }

  Pointer<Void> _closeHandle(Pointer<Void> handle) {
    if (handle == nullptr) return nullptr;
    api.closeHandle(handle);
    return nullptr;
  }

  /// 起读取 isolate：阻塞 `ReadFile` 不能放在调用方 isolate 上。
  void _spawnReader() {
    final ReceivePort port = ReceivePort();
    readerPort = port;
    port.listen(_onReaderMessage);
    unawaited(_startReader(port));
  }

  Future<void> _startReader(ReceivePort port) async {
    try {
      readerIsolate = await Isolate.spawn<List<Object?>>(_ptyReadLoop, <Object?>[
        port.sendPort,
        outputRead.address,
        api.libraryName,
      ]);
    } on Object catch (error) {
      log?.call('[pty] 读取 isolate 启动失败：$error');
      _closeOutput();
    }
  }

  void _onReaderMessage(Object? message) {
    if (message is! List<Object?>) return;
    final Object? kind = message.first;
    if (kind == 'data') {
      final Object? payload = message[1];
      if (payload is List<int> && !outputController.isClosed) {
        outputController.add(payload);
      }
      return;
    }
    if (kind == 'error') {
      log?.call('[pty] 伪终端读取失败：${message[1]}');
    }
    _closeOutput();
  }

  void _closeOutput() {
    if (outputClosed) return;
    outputClosed = true;
    if (!readerDone.isCompleted) readerDone.complete();
    // 不 await：没有监听者时 close() 的 future 永远不会完成，close() 不能被它挂住。
    unawaited(outputController.close());
    // 读完就把端口关掉：留着的 ReceivePort 会拖住整个 Dart VM 不退出。
    readerPort?.close();
    readerPort = null;
  }
}

/// 读取 isolate 的主循环：阻塞 `ReadFile` → 把字节块通过 `SendPort` 交回主 isolate。
///
/// 为什么句柄能用整数地址跨 isolate 传：**同一进程内句柄表是共享的**，
/// 句柄值（`Pointer.address`）只是这张表里的一个索引。
void _ptyReadLoop(List<Object?> args) {
  final SendPort port = args[0] as SendPort;
  final int handleAddress = args[1] as int;
  final String libraryName = args[2] as String;

  final _ConPtyApi? api = _ConPtyApi.tryOpen(libraryName);
  if (api == null) {
    port.send(<Object?>['error', '无法从 $libraryName 解析 ReadFile']);
    return;
  }
  final Pointer<Uint8> buffer = api.alloc(_readChunkBytes);
  final Pointer<Uint32> readSlot = api.alloc(sizeOf<Uint32>()).cast<Uint32>();
  if (buffer == nullptr || readSlot == nullptr) {
    port.send(<Object?>['error', '分配读取缓冲失败']);
    return;
  }
  final Pointer<Void> handle = Pointer<Void>.fromAddress(handleAddress);
  try {
    while (true) {
      readSlot.value = 0;
      if (api.readFile(handle, buffer, _readChunkBytes, readSlot, nullptr) == 0) {
        // 写端全关（子进程退出/ClosePseudoConsole 之后）：正常收工
        port.send(<Object?>['eof', api.lastError()]);
        return;
      }
      final int count = readSlot.value;
      if (count <= 0) continue;
      port.send(<Object?>[
        'data',
        Uint8List.fromList(buffer.asTypedList(count)),
      ]);
    }
  } finally {
    api.free(buffer.cast<Void>());
    api.free(readSlot.cast<Void>());
  }
}
