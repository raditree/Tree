import 'package:flutter/services.dart';

/// 终端的**输入法通道**：中文 / 日文这类要靠"组字"的输入，必须有一个活着的
/// [TextInputClient] 才收得到（真机现象：终端里打不出中文——只有键盘原文，没有 IME）。
///
/// 它只做两件事：
/// 1. 把平台交出来的**已定字**原样交给 [onText]（组字中的半截拼音**一个字节都不发**）；
/// 2. 把平台的值**原样回显**回去（文本、选区、组字区一个字都不改）。
///
/// **为什么不能改写平台侧的值**（用户 2026-10-03：「中文输入下模拟终端出 bug」——
/// 截图里提示符后面是 `…>nninini1hn。hni。hani。h已亻尔晗《尔台和2《尔晗nnin《`，
/// 拼音原文进了 shell）：Windows 引擎的 `TextInputModel` 是**整段文本**模型——
/// 它送来的值永远是"整段文本 + composingBase/Extent"（`text_input_plugin.cc` 的
/// `SendStateUpdate(*active_model_)`），**提交那一刻不发状态**，随后的"结束组字"事件
/// 发的是"整段文本 + composing 无效"（`ComposeEndHook`）。更关键的是
/// `TextInputModel.AddText`：**选区折叠时是"在光标处追加"，选区非折叠时才"替换选区"**
/// （`text_input_model.h` 原文：either appends after the cursor … or deletes the
/// selected text, replacing it with the given text）——IME 提交时正是靠"组字区被选中"
/// 来完成替换。旧实现把模型改成"只剩未转发的尾巴 + 把选区折到末尾 + 标组字区"，
/// 提交于是退化成**追加**：残留的拼音留在模型里，跟"提交结果"一起被整段送回来，
/// 而我们按 composing 无效把它当成已定字**整段转发** ⇒ 拼音进 shell。
/// 回显原样之后，模型与 IME 的认知一致，"选字 = 替换组字区"这条正常路径才成立。
///
/// **为什么不许回推 `setEditingState`**（2026-10-03 真机回归，引擎源码坐实）：
/// 平台每次状态回流都回推一次，等于每次都调引擎的 `TextInputModel::SetText(text)`
/// ——那个重载的签名是 `SetText(text, selection = TextRange(0), composing_range = TextRange(0))`
/// （`text_input_model.h`），默认的**折叠组字区**会让 `composing_ = !composing_range.collapsed()`
/// 变成 **false**；紧接着插件再调 `SetComposingRange(...)` 也救不回来——它开头就是
/// `if (!composing_) return false;`。组字态被抹掉之后，IME 下一轮的
/// `AddText`（`text_input_model.cc`：**只有 `composing_` 为真才"删掉当前组字文本再插入"**）
/// 就退化成**追加**：拼音不断堆在模型里，每一轮"."又把"。"追加进去，而我们按"只补差额"
/// 把多出来的部分当**新定字**发给 PTY ⇒ shell 里出现一长串拼音（用户截图
/// `E:\...>nninini…。hani。…`，且没有换行）。
///
/// 所以这里只做两件事：**读**（把已定字交给 [onText]）与**在 attach 时清一次模型**
/// （[attach] 里那一次 `setEditingState(empty)`：刚接上时模型里可能还留着上一次的残渣，
/// 清掉它才是干净起点）。**组字过程中的任何回推都是 bug**——`test/terminal_ime_input_test.dart`
/// 里有一条用例专门钉住"组字期间不许出现 TextInput.setEditingState"。
///
/// **为什么还要"只补差额"**：平台送来的永远是整段文本，就得自己记住"已经交给 PTY 多少"
/// （[_forwarded]），否则每次状态回流都会把老内容重复灌进 shell。
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

  /// 平台模型文本里**已经交给 PTY** 的前缀长度（UTF-16 编码单元，与
  /// [TextEditingValue.text] 同口径）。
  ///
  /// 平台每次送来的都是模型整段文本（见文头），所以只补"新定下来的那一段"。
  /// 文本收缩（用户退格删掉已定字——那一路由键盘发 `0x7f` 给 PTY，见 terminal_panel）
  /// 时游标跟着回退，免得下一次把老内容当成新内容再发一遍。
  int _forwarded = 0;

  /// 上一轮看到的**组字尾巴**（`composing` 覆盖的那一段正文）。
  ///
  /// 用来兜住真机现场那种"引擎把残留组字跟提交结果一起送回来"的形态：结束组字那一刻
  /// 送来的文本如果是"已转发前缀 + 残留组字 + 结果"，尾巴就会以刚记下的组字开头且更长，
  /// 剥掉它才只交结果（见 [updateEditingValue]）。
  String _preedit = '';

  bool get attached => _connection?.attached ?? false;

  /// 当前挂着的视图 id（排障 / 测试用）。
  int? get viewId => _viewId;

  /// 平台最后送来的值（**原样**，排障 / 测试用）。
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
    _forwarded = 0;
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
    _resetPlatformValue(TextEditingValue.empty);
  }

  /// 关掉连接（失焦 / 面板 dispose 时调）。
  void detach() {
    _connection?.close();
    _connection = null;
    _viewId = null;
    _value = TextEditingValue.empty;
    _forwarded = 0;
    _preedit = '';
  }

  /// 把"光标那一格在哪"报给平台：IME 的候选窗 / 组字窗按它定位。
  ///
  /// 不给的话 Windows 用**上一个可编辑控件的陈旧矩形**——真机现象：候选窗出现在终端
  /// 底部（那片区域正是被 Ctrl+J 顶掉的 composer），而光标其实在终端顶部。
  ///
  /// 口径与 `EditableText` 一致，且用的正是 Windows 认的那两条消息
  /// （`text_input_plugin.cc`：`TextInput.setEditableSizeAndTransform` 与
  /// `TextInput.setMarkedTextRect`；Dart 侧就是 [TextInputConnection.setEditableSizeAndTransform]
  /// 与 [TextInputConnection.setComposingRect]）：
  /// - [editableSize] = "可编辑框"尺寸（这里给整块终端屏幕区），[transform] = 它到根坐标系的变换；
  /// - [caretRect] = 组字/光标矩形，**在可编辑框自己的坐标系里**（这里给光标那一格）。
  void reportCaretGeometry({
    required Size editableSize,
    required Rect caretRect,
    required Matrix4 transform,
  }) {
    final TextInputConnection? connection = _connection;
    if (connection == null) return;
    connection.setEditableSizeAndTransform(editableSize, transform);
    connection.setComposingRect(caretRect);
  }

  /// **只**在 [attach] 时用一次：把平台侧模型清成空（干净起点）。
  ///
  /// 除此之外**任何**时候都不要调它（见文头"为什么不许回推"）。
  void _resetPlatformValue(TextEditingValue value) {
    _value = value;
    _connection?.setEditingState(value);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  /// 平台把"模型整段文本 + 选中的位置 + 正在组字的范围"交过来。
  ///
  /// 只交**已定字**：`composing` 有效时，它**之前**的那一段才算定了字（"ni"敲到一半
  /// 绝不能进 shell）；没有组字时整段都算已定字（提交后的整段回流走这条）。因为送来的
  /// 是整段文本，这里只补 [_forwarded] 之后**新**的那一截。
  @override
  void updateEditingValue(TextEditingValue value) {
    final String text = value.text;
    final TextRange composing = value.composing;
    final bool composingNow = composing.isValid && !composing.isCollapsed;
    if (composingNow) {
      final int committed = composing.start.clamp(0, text.length);
      if (committed > _forwarded && committed <= text.length) {
        final String newly = text.substring(_forwarded, committed);
        if (newly.isNotEmpty) onText(newly);
      }
      _forwarded = committed;
      _preedit = text.substring(committed, text.length);
    } else {
      String tail = text.length > _forwarded ? text.substring(_forwarded) : '';
      // 真机现场那种形态：结束组字时送回的文本是"前缀 + 残留组字 + 结果"。
      // 判据：尾巴以刚记下的组字开头、且**比它更长**（长度相等 = 用户直接定了原文，
      // 那正是要交出去的内容，不能剥）。
      if (_preedit.isNotEmpty &&
          tail.length > _preedit.length &&
          tail.startsWith(_preedit)) {
        tail = tail.substring(_preedit.length);
      }
      if (tail.isNotEmpty) onText(tail);
      _forwarded = text.length;
      _preedit = '';
    }
    // **绝不回推编辑状态**（见文头的"为什么不许 setEditingState"）。
    _value = value;
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
