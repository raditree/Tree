import 'dart:ffi';
import 'dart:io';

/// Tree 桌面端统一的应用标识（AppUserModelID）。
///
/// 为什么需要它：核心、界面插件与各插件进程原本都没有显式 AUMID，Windows 只能
/// 按 exe 名 / 窗口去猜，结果是任务栏给每个 `tree_ui.exe` 窗口一个独立按钮、
/// 任务管理器里也各成一栏。给**整条进程链**设同一个 id，Windows 才把它们认成
/// 同一个应用（见 Microsoft「Application User Model IDs」）。
///
/// 命名遵循 `CompanyName.ProductName.SubProduct`：不含空格、不超过 128 字符；
/// 升级不改名（改名在任务栏看来就是换了一个应用）。
const String kAppUserModelId = 'Tree.Desktop';

/// 注入给插件进程的环境变量名：插件在自己的启动例程里据此设置 AUMID。
///
/// AUMID 是**进程内** API（`SetCurrentProcessExplicitAppUserModelID`），父进程
/// 不能替子进程设置；核心只能把同一份 id 交下去，由每个进程自己应用。
const String kAppUserModelIdEnv = 'TREE_APP_USER_MODEL_ID';

typedef _SetAumidNative = Int32 Function(Pointer<Uint16>);
typedef _SetAumidDart = int Function(Pointer<Uint16>);
typedef _GetAumidNative = Int32 Function(Pointer<Pointer<Uint16>>);
typedef _GetAumidDart = int Function(Pointer<Pointer<Uint16>>);
typedef _LocalAllocNative = Pointer<Void> Function(Uint32, UintPtr);
typedef _LocalAllocDart = Pointer<Void> Function(int, int);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);
typedef _CoTaskMemFreeNative = Void Function(Pointer<Void>);
typedef _CoTaskMemFreeDart = void Function(Pointer<Void>);

/// 给**当前进程**设置显式 AUMID（仅 Windows；其它平台空操作）。
///
/// 必须在进程启动早期、第一扇窗口出现之前调用。失败一律吞掉：AUMID 只影响
/// 任务栏 / 通知的归组口径，绝不能因为一次 FFI 调用挡住进程启动。
void applyAppUserModelId([String id = kAppUserModelId]) {
  if (!Platform.isWindows || id.trim().isEmpty) return;
  try {
    final _SetAumidDart set = DynamicLibrary.open('shell32.dll')
        .lookupFunction<_SetAumidNative, _SetAumidDart>(
          'SetCurrentProcessExplicitAppUserModelID',
        );
    final _KernelHeap heap = _KernelHeap.open();
    final Pointer<Uint16> buffer = heap
        .alloc((id.codeUnits.length + 1) * 2)
        .cast<Uint16>();
    if (buffer == nullptr) return;
    try {
      buffer.asTypedList(id.codeUnits.length).setAll(0, id.codeUnits);
      (buffer + id.codeUnits.length).value = 0; // NUL 终止
      set(buffer);
    } finally {
      heap.free(buffer.cast<Void>());
    }
  } catch (_) {
    // 见函数注释：展示口径，失败不影响功能。
  }
}

/// 读回当前进程的显式 AUMID（'' = 没设 / 非 Windows）。
///
/// 只用于自检与诊断：系统兜底算出来的 AUMID 是取不到的（官方口径），能读到的
/// 只有自己显式设过的那一份。
String currentAppUserModelId() {
  if (!Platform.isWindows) return '';
  try {
    final _GetAumidDart get = DynamicLibrary.open('shell32.dll')
        .lookupFunction<_GetAumidNative, _GetAumidDart>(
          'GetCurrentProcessExplicitAppUserModelID',
        );
    final _CoTaskMemFreeDart freeTask = DynamicLibrary.open(
      'ole32.dll',
    ).lookupFunction<_CoTaskMemFreeNative, _CoTaskMemFreeDart>('CoTaskMemFree');
    final _KernelHeap heap = _KernelHeap.open();
    final Pointer<Pointer<Uint16>> slot = heap
        .alloc(sizeOf<Pointer<Void>>())
        .cast<Pointer<Uint16>>();
    if (slot == nullptr) return '';
    try {
      slot.value = nullptr;
      if (get(slot) != 0) return '';
      final Pointer<Uint16> text = slot.value;
      if (text == nullptr) return '';
      final List<int> units = <int>[];
      for (int i = 0; (text + i).value != 0; i++) {
        units.add((text + i).value);
      }
      freeTask(text.cast<Void>());
      return String.fromCharCodes(units);
    } finally {
      heap.free(slot.cast<Void>());
    }
  } catch (_) {
    return '';
  }
}

/// kernel32 的本地堆：只为一次 UTF-16 缓冲而引入 `package:ffi` 不划算
/// （与 `tree_local_exec` 的 ANSI 编解码同一取舍）。
final class _KernelHeap {
  _KernelHeap._(DynamicLibrary library)
    : _localAlloc = library.lookupFunction<_LocalAllocNative, _LocalAllocDart>(
        'LocalAlloc',
      ),
      _localFree = library.lookupFunction<_LocalFreeNative, _LocalFreeDart>(
        'LocalFree',
      );

  factory _KernelHeap.open() =>
      _KernelHeap._(DynamicLibrary.open('kernel32.dll'));

  /// LMEM_FIXED：返回值就是可用内存指针。
  static const int _lmemFixed = 0x0000;

  final _LocalAllocDart _localAlloc;
  final _LocalFreeDart _localFree;

  Pointer<Void> alloc(int bytes) => _localAlloc(_lmemFixed, bytes);

  void free(Pointer<Void> memory) => _localFree(memory);
}
