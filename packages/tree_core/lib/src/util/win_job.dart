import 'dart:ffi';
import 'dart:io';

/// Windows Job Object 的最小封装：把**每一个**插件进程放进同一个作业里。
///
/// 为什么需要它：Windows 上 `Process.kill()` 只杀直接子进程，核心一旦崩溃 / 被
/// `taskkill /F`，插件（以及 `local_executor` 起的 shell 孙进程）会留在系统里，
/// 重启核心后堆出第二套。把插件进程 `AssignProcessToJobObject` 进一个带
/// `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的作业后，作业句柄随核心进程一起被系统
/// 关闭，作业里的进程（含之后 fork 的子进程）由内核统一终止——**无任何豁免**。
///
/// 边界：
/// - 只放插件进程；核心自己绝不加入（否则关句柄等于自杀）；
/// - 赋值发生在 `Process.start` 之后：极短的窗口里若插件已 fork 出子进程，那批
///   子进程不在作业内（现有插件都在启动后才起子进程，可忽略）；
/// - 非 Windows / 创建失败 / Assign 失败一律降级为空操作，不阻断插件启动。
const int kJobObjectExtendedLimitInformation = 9;
const int kJobObjectLimitKillOnJobClose = 0x00002000;

const int _processTerminate = 0x0001;
const int _processSetQuota = 0x0100;

/// 自检用：`JOBOBJECT_EXTENDED_LIMIT_INFORMATION` 的字节数（x64 应为 144）。
int get winJobExtendedLimitInfoSize => sizeOf<_JobExtendedLimitInformation>();

/// 核心进程的插件作业（懒创建；非 Windows 为 null）。
final WinJobObject? pluginJob = WinJobObject.create();

/// 把一个刚拉起的插件进程放进 [pluginJob]；失败只记一句，不影响启动。
void assignPluginProcessToJob(
  int pid, {
  void Function(String message)? log,
}) {
  final WinJobObject? job = pluginJob;
  if (job == null) return;
  if (!job.assign(pid)) {
    log?.call('插件进程 $pid 未加入 Job Object（按旧方式管理，核心异常退出时可能残留）');
  }
}

final class WinJobObject {
  WinJobObject._(this._api, this._handle);

  final _KernelApi _api;
  final Pointer<Void> _handle;
  bool _closed = false;

  /// 新建一个带 `KILL_ON_JOB_CLOSE` 的作业；生产用全局 [pluginJob]，测试可自建。
  static WinJobObject? create() {
    if (!Platform.isWindows) return null;
    final _KernelApi api;
    try {
      api = _KernelApi.open();
    } catch (_) {
      return null;
    }
    final Pointer<Void> handle = api.createJobObject(nullptr, nullptr);
    if (handle == nullptr) return null;
    final int size = sizeOf<_JobExtendedLimitInformation>();
    final Pointer<Void> limits = api.localAlloc(
      0x0040, // LMEM_ZEROINIT（配合 LMEM_FIXED）：整个结构先清零
      size,
    );
    if (limits == nullptr) {
      api.closeHandle(handle);
      return null;
    }
    try {
      // 只设一个限制位：作业里最后一个句柄关闭时，内核自动终止作业内进程。
      limits.cast<_JobExtendedLimitInformation>().ref.basicLimitInformation
              .limitFlags =
          kJobObjectLimitKillOnJobClose;
      final int ok = api.setInformationJobObject(
        handle,
        kJobObjectExtendedLimitInformation,
        limits,
        size,
      );
      if (ok == 0) {
        api.closeHandle(handle);
        return null;
      }
    } finally {
      api.localFree(limits);
    }
    return WinJobObject._(api, handle);
  }

  /// 按 pid 把进程加入作业（Dart 的 `Process` 不给原生句柄，只能重新 Open）。
  ///
  /// 权限按 MSDN：`PROCESS_SET_QUOTA | PROCESS_TERMINATE`。进程已经退出 /
  /// 权限不足 / 处于不允许嵌套的作业里 ⇒ 返回 false，由调用方决定怎么记日志。
  bool assign(int pid) {
    if (_closed || _handle == nullptr || pid <= 0) return false;
    final Pointer<Void> process = _api.openProcess(
      _processSetQuota | _processTerminate,
      0,
      pid,
    );
    if (process == nullptr) return false;
    try {
      return _api.assignProcessToJobObject(_handle, process) != 0;
    } finally {
      _api.closeHandle(process);
    }
  }

  /// 立即终止作业内所有进程（正常退出走优雅停插件，这里是兜底）。
  bool terminate() {
    if (_closed || _handle == nullptr) return false;
    return _api.terminateJobObject(_handle, 1) != 0;
  }

  /// 关句柄；`KILL_ON_JOB_CLOSE` 生效（测试与显式收尾用，生产里交给进程退出）。
  void close() {
    if (_closed || _handle == nullptr) return;
    _closed = true;
    _api.closeHandle(_handle);
  }
}

// ── kernel32 绑定（只在 Windows 上 open；结构布局与 MSDN 逐字段对齐）─────────

final class _JobBasicLimitInformation extends Struct {
  @Int64() external int perProcessUserTimeLimit;
  @Int64() external int perJobUserTimeLimit;
  @Uint32() external int limitFlags;
  @UintPtr() external int minimumWorkingSetSize;
  @UintPtr() external int maximumWorkingSetSize;
  @Uint32() external int activeProcessLimit;
  @UintPtr() external int affinity;
  @Uint32() external int priorityClass;
  @Uint32() external int schedulingClass;
}

final class _IoCounters extends Struct {
  @Uint64() external int readOperationCount;
  @Uint64() external int writeOperationCount;
  @Uint64() external int otherOperationCount;
  @Uint64() external int readTransferCount;
  @Uint64() external int writeTransferCount;
  @Uint64() external int otherTransferCount;
}

final class _JobExtendedLimitInformation extends Struct {
  external _JobBasicLimitInformation basicLimitInformation;
  external _IoCounters ioInfo;
  @UintPtr() external int processMemoryLimit;
  @UintPtr() external int jobMemoryLimit;
  @UintPtr() external int peakProcessMemoryUsed;
  @UintPtr() external int peakJobMemoryUsed;
}

typedef _CreateJobObjectNative =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _CreateJobObjectDart =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _SetInformationJobObjectNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32);
typedef _SetInformationJobObjectDart =
    int Function(Pointer<Void>, int, Pointer<Void>, int);
typedef _AssignProcessToJobObjectNative =
    Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _AssignProcessToJobObjectDart =
    int Function(Pointer<Void>, Pointer<Void>);
typedef _TerminateJobObjectNative = Int32 Function(Pointer<Void>, Uint32);
typedef _TerminateJobObjectDart = int Function(Pointer<Void>, int);
typedef _OpenProcessNative = Pointer<Void> Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = Pointer<Void> Function(int, int, int);
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandleDart = int Function(Pointer<Void>);
typedef _LocalAllocNative = Pointer<Void> Function(Uint32, UintPtr);
typedef _LocalAllocDart = Pointer<Void> Function(int, int);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

final class _KernelApi {
  _KernelApi._(DynamicLibrary library)
    : createJobObject = library.lookupFunction<
        _CreateJobObjectNative,
        _CreateJobObjectDart
      >('CreateJobObjectW'),
      setInformationJobObject = library.lookupFunction<
        _SetInformationJobObjectNative,
        _SetInformationJobObjectDart
      >('SetInformationJobObject'),
      assignProcessToJobObject = library.lookupFunction<
        _AssignProcessToJobObjectNative,
        _AssignProcessToJobObjectDart
      >('AssignProcessToJobObject'),
      terminateJobObject = library.lookupFunction<
        _TerminateJobObjectNative,
        _TerminateJobObjectDart
      >('TerminateJobObject'),
      openProcess = library.lookupFunction<_OpenProcessNative, _OpenProcessDart>(
        'OpenProcess',
      ),
      closeHandle = library.lookupFunction<_CloseHandleNative, _CloseHandleDart>(
        'CloseHandle',
      ),
      localAlloc = library.lookupFunction<_LocalAllocNative, _LocalAllocDart>(
        'LocalAlloc',
      ),
      localFree = library.lookupFunction<_LocalFreeNative, _LocalFreeDart>(
        'LocalFree',
      );

  factory _KernelApi.open() =>
      _KernelApi._(DynamicLibrary.open('kernel32.dll'));

  final _CreateJobObjectDart createJobObject;
  final _SetInformationJobObjectDart setInformationJobObject;
  final _AssignProcessToJobObjectDart assignProcessToJobObject;
  final _TerminateJobObjectDart terminateJobObject;
  final _OpenProcessDart openProcess;
  final _CloseHandleDart closeHandle;
  final _LocalAllocDart localAlloc;
  final _LocalFreeDart localFree;
}
