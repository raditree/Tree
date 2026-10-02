import 'package:flutter/foundation.dart';

import 'code_highlight.dart';

/// 一个文件的**共享编辑缓冲**（VS Code 的 TextDocument 口径：一个文件一份文档）。
///
/// 同一个路径在两个窗格里打开时，两边共用**同一个** [EditorBuffer]：
/// 同一个 [controller] + 一份 [dirty] / [saving] / [loadedSize] ——
/// 一边打字另一边立刻可见，谁保存都只写一次盘，因此不存在"两份缓冲互相覆盖"。
/// （旧口径是"同文件双开 ⇒ 非活动窗格强制只读"，被这条推翻，见 lib/README.md 不变量 13。）
///
/// **归属**：由文件面板持有（与窗格路径一一对应），没有窗格再引用它时才 [dispose]
/// （控制器随之回收）。[FileViewer] 没有外部传入 buffer 时自己 new 一份并自己释放，
/// 既有调用方与测试零改动。
///
/// 每个 setter 只在值**真的变化**时 [notifyListeners]：一次按键会走一遍 dirty 的赋值，
/// 值没变就不该让另一个窗格重建。
class EditorBuffer extends ChangeNotifier {
  CodeEditingController? _controller;
  bool _dirty = false;
  bool _saving = false;
  int _loadedSize = 0;
  String _readOnlyReason = '';
  bool _disposed = false;

  /// 编辑器控制器（可编辑、且加载完成时才有）。带高亮，见 code_highlight.dart。
  ///
  /// **只建一次**：同一个文件在第二个窗格里打开时复用它（另一个窗格可能已经在编辑），
  /// 绝不能用刚读回来的磁盘内容重建或清掉。
  CodeEditingController? get controller => _controller;
  set controller(CodeEditingController? value) {
    if (identical(_controller, value)) return;
    _controller = value;
    _bump();
  }

  /// 是否有未保存的改动（两个窗格共享：任一边改了，两边都是未保存态）
  bool get dirty => _dirty;
  set dirty(bool value) {
    if (_dirty == value) return;
    _dirty = value;
    _bump();
  }

  /// 是否正在保存（共享，挡住重复提交：一次保存 = 一次 HTTP + 一次落盘）
  bool get saving => _saving;
  set saving(bool value) {
    if (_saving == value) return;
    _saving = value;
    _bump();
  }

  /// 加载时文件的**真实**字节数：保存时作为 if_size 做外部改动检测（共享）
  int get loadedSize => _loadedSize;
  set loadedSize(int value) {
    if (_loadedSize == value) return;
    _loadedSize = value;
    _bump();
  }

  /// 这份**文档自身**为什么不能编辑（空串 = 可编辑）。
  ///
  /// 只放"图片 / PDF / Office、被截断、含 NUL 的二进制"这类跟着文件走的理由；
  /// 外部传入的 readOnly（[FileViewer.readOnly]）是**每个视图**自己的事，不写进来。
  String get readOnlyReason => _readOnlyReason;
  set readOnlyReason(String value) {
    if (_readOnlyReason == value) return;
    _readOnlyReason = value;
    _bump();
  }

  /// 值真的变了才通知；已经释放的缓冲静默（在途的保存 / 加载回调可能在窗格都关了
  /// 之后才跑完，那时 notifyListeners 会撞上"dispose 之后又被使用"）。
  void _bump() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final CodeEditingController? controller = _controller;
    _controller = null;
    controller?.dispose();
    super.dispose();
  }
}
