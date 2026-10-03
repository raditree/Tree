import 'package:flutter/services.dart';

/// 终端的**输入法通道**：中文 / 日文这类要靠"组字"的输入，必须有一个活着的
/// [TextInputClient] 才收得到（真机现象：终端里打不出中文——只有键盘原文，没有 IME）。
///
/// 它只做一件事：把平台交出来的**已定字**原样交给 [onText]，并让平台侧字段
/// **始终保持空**（不需要回显——屏幕上画什么由 VT 解析器说了算）。
///
/// **为什么不用隐藏的 `TextField`**（那样代码更少）：焦点链上 `EditableText` 自己的
/// 按键处理（回车换行、退格删字、方向键移动光标）跑在**我们的 Focus 之前**，会把控制键
/// 吃掉——而终端要的是"除了文字，其它键一律原样送 PTY"。独立 attach 一个 client 则与
/// 焦点链无关：**文字走这条路、控制键走 [Focus.onKeyEvent]**，两条路互不打架。
///
/// **两条路为什么不会重复输入**（读 Flutter 引擎源码得出的结论，不是推测）：
/// `shell/platform/windows/keyboard_manager.cc` 的 `HandleOnKeyResult` 里，
/// **键事件被判 handled 就不再派发文字**（"only dispatch OnText if the key down
/// event is not handled"）。所以终端对可打印字符一律 `KeyEventResult.ignored`
/// （见 terminal_panel 的 _translateKey）——平台于是把 WM_CHAR 交给 `TextHook`，
/// 由这条输入法通道交给我们；反过来，一旦我们在键盘那一路 handled，文字就再也
/// 到不了这里。**这就是为什么 attach 必须成功**（见 [attach] 的 viewId）。
class TerminalTextInputClient with TextInputClient {
  TerminalTextInputClient({required this.onText});

  /// 收到一段**已定字**（组字完成，或直接键入的字符）时回调。
  final void Function(String text) onText;

  TextInputConnection? _connection;
  TextEditingValue _value = TextEditingValue.empty;
  int? _viewId;

  bool get attached => _connection?.attached ?? false;

  /// 当前挂着的视图 id（排障 / 测试用）。
  int? get viewId => _viewId;

  /// 当前平台侧的值（我们只留"正在组字的尾巴"，其余一律清空）。
  TextEditingValue get value => _value;

  /// 打开连接（终端拿到焦点时调；同一个视图下重复调用是幂等的）。
  ///
  /// **[viewId] 不能省**：Windows 端 `TextInput.setClient` 会校验它，缺了就直接
  /// 回一个错误（引擎源码 `shell/platform/windows/text_input_plugin.cc`：
  /// 「Could not set client, view ID is null.」），于是平台侧的 `active_model_`
  /// **一直是空的**——键盘交出来的文字被 `TextHook` 静默丢掉。真机现象就是
  /// **终端里中英文一个字都打不出来**（用户 2026-10-04）。Flutter 自己的
  /// `EditableText` 也得给（`viewId: View.of(context).viewId`）。
  void attach({required int viewId}) {
    if (attached && _viewId == viewId) return;
    detach();
    _viewId = viewId;
    _connection = TextInput.attach(
      this,
      TextInputConfiguration(
        viewId: viewId,
        inputType: TextInputType.text,
        inputAction: TextInputAction.none,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      ),
    )..show();
    _setValue(TextEditingValue.empty);
  }

  /// 关掉连接（失焦 / 面板 dispose 时调）。
  void detach() {
    _connection?.close();
    _connection = null;
    _viewId = null;
    _value = TextEditingValue.empty;
  }

  void _setValue(TextEditingValue value) {
    _value = value;
    _connection?.setEditingState(value);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  /// 平台把"现在这段文字 + 选中的位置 + 正在组字的范围"交过来。
  ///
  /// 组字中（`composing` 是有效且非空的范围）时**只交已定字**——拼音敲到一半的
  /// "ni" 绝不能进 shell；组字尾巴留在平台侧继续组，定字后再整段交出去。
  @override
  void updateEditingValue(TextEditingValue value) {
    final String text = value.text;
    if (text.isEmpty) {
      _setValue(TextEditingValue.empty);
      return;
    }
    final TextRange composing = value.composing;
    final bool composingNow = composing.isValid && !composing.isCollapsed;
    final String committed = composingNow
        ? text.substring(0, composing.start.clamp(0, text.length))
        : text;
    if (committed.isNotEmpty) onText(committed);
    final String rest = text.substring(committed.length);
    _setValue(
      rest.isEmpty
          ? TextEditingValue.empty
          : TextEditingValue(
              text: rest,
              selection: TextSelection.collapsed(offset: rest.length),
              composing: TextRange(start: 0, end: rest.length),
            ),
    );
  }

  /// 回车 / 换行这类动作**不在这里处理**：它们由键盘那一路（[Focus.onKeyEvent]）
  /// 送给 PTY，这里再来一次就成了双回车。
  ///
  /// 另外：配置里没开 delta 模型（`enableDeltaModel: false`），所以也不会走
  /// `DeltaTextInputClient` 那条 delta 通道。
  @override
  void performAction(TextInputAction action) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _connection = null;
  }
}
