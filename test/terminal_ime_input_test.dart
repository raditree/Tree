import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/terminal_ime_input.dart';

/// 输入法通道的**纯逻辑**（真机现象：中文输入把拼音漏进 shell —— 用户 2026-10-03
/// 截图里提示符后面就是 `…>nninini1hn。hni。hani。h…`，Windows OCR 读出来的原文）。
///
/// 契约（引擎源码依据见下，取本机 SDK 对应引擎版本 `af7e796e…`）：
/// - 平台每次送来的都是 **TextInputModel 的整段文本** + `composingBase/Extent`
///   （`SendStateUpdate(*active_model_)`；提交那一刻不发，`ComposeEndHook` 发的是
///   "整段文本 + composing 无效"）⇒ **只补差额**才不会把老内容重复灌进 shell；
/// - 我们**绝不回推** `setEditingState`（唯一一次是 attach 时把模型清空）：回推会走引擎
///   `TextInputModel::SetText(text)` 的**默认参数**路径（`composing_range = TextRange(0)`），
///   把 `composing_` 打成 false；紧接着的 `SetComposingRange` 因 `if (!composing_) return false;`
///   也救不回来。组字态一没，`AddText`（只有 `composing_` 为真才"删掉组字文本再插入"）
///   就从"替换组字区"退化成"追加"——拼音越堆越多，被我们当"新定字"转发 ⇒ 拼音进 shell
///   （用户 2026-10-03 真机回归，与 #15 同一症状）。
void main() {
  late List<String> forwarded;
  late TerminalTextInputClient client;
  late List<MethodCall> platformCalls;

  setUp(() {
    forwarded = <String>[];
    client = TerminalTextInputClient(onText: forwarded.add);
  });

  /// 记下"平台侧收到了什么"：`TextInput.setEditingState` 的参数就是引擎写进
  /// `TextInputModel` 的东西（`text_input_plugin.cc` 的 `kSetEditingStateMethod` 分支）。
  void capturePlatform(WidgetTester tester) {
    platformCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (MethodCall call) async {
        platformCalls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.textInput, null);
    });
  }

  /// 平台侧收到过几次 `TextInput.setEditingState`（= 我们改写了引擎的模型几次）。
  int editingStateCalls() => platformCalls
      .where((MethodCall c) => c.method == 'TextInput.setEditingState')
      .length;

  Map<String, dynamic> lastEditingState(WidgetTester tester) {
    final MethodCall call = platformCalls.lastWhere(
      (MethodCall c) => c.method == 'TextInput.setEditingState',
    );
    return (call.arguments as Map<dynamic, dynamic>).cast<String, dynamic>();
  }

  test('定字：整段交出去', () {
    client.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    expect(forwarded, <String>['你好']);
  });

  test('组字中：一个字都不交（拼音"ni"不能进 shell）', () {
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    expect(forwarded, isEmpty);
  });

  test('组字前半截已定字：只交已定字', () {
    client.updateEditingValue(
      const TextEditingValue(
        text: 'a你',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 1, end: 2),
      ),
    );
    expect(forwarded, <String>['a']);
  });

  test('删到空：什么都不交', () {
    client.updateEditingValue(
      const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      ),
    );
    expect(forwarded, isEmpty);
  });

  test('没 attach 时也能安全喂值（`setEditingState` 只在有连接时发）', () {
    expect(client.attached, isFalse);
    client.updateEditingValue(
      const TextEditingValue(
        text: 'x',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    expect(forwarded, <String>['x']);
    client.detach();
    expect(client.attached, isFalse);
  });

  test('平台重发整段（模型里已经有交出去的内容）：只补差额，不重复发', () {
    const TextEditingValue first = TextEditingValue(
      text: 'ls',
      selection: TextSelection.collapsed(offset: 2),
    );
    client.updateEditingValue(first);
    client.updateEditingValue(first); // 平台把同一段再送一次
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ls-a',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    expect(forwarded, <String>['ls', '-a'], reason: '整段回流只该补差额');
  });

  test('收缩（退格删掉已定字）：不重发、也不吐回老内容，游标跟着回退', () {
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ab',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    client.updateEditingValue(
      const TextEditingValue(
        text: 'a',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ac',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    expect(forwarded, <String>['ab', 'c'],
        reason: '退格由键盘那一路发 0x7f 给 PTY；这里只该把新打的 c 交出去');
  });

  test('detach 后重置游标：重新 attach 不会因为游标残留而吞字', () {
    client.updateEditingValue(
      const TextEditingValue(
        text: 'x',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    client.detach();
    client.updateEditingValue(
      const TextEditingValue(
        text: 'y',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    expect(forwarded, <String>['x', 'y']);
  });

  testWidgets('引擎把"残留组字 + 提交结果"整段送回来：只发新定字（真机 bug 的钉子）',
      (WidgetTester tester) async {
    capturePlatform(tester);
    client.attach(viewId: 0);

    // 组字中：模型文本就是拼音，composing 覆盖它
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    expect(forwarded, isEmpty);

    // 提交：ComposeEndHook 送来的是**模型整段文本**（拼音还在里头）+ composing 无效
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ni你',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    expect(
      forwarded,
      <String>['你'],
      reason: '组字尾巴不是已定字：漏出去就是真机截图里提示符后面那一串拼音',
    );
  });

  test('正常提交（引擎把组字区替换成结果）：只交结果', () {
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    client.updateEditingValue(
      const TextEditingValue(
        text: '你',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    expect(forwarded, <String>['你']);
  });

  test('直接定原文（结果就是组字本身）：长度相等 ⇒ 照交，不能当残留剥掉', () {
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    expect(forwarded, <String>['ni'], reason: '用户按回车定的就是"ni"这三个字母');
  });

  test('追加形态 + 结果与组字相同：剥掉残留、只交一份', () {
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    client.updateEditingValue(
      const TextEditingValue(
        text: 'nini',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    expect(forwarded, <String>['ni'], reason: '前缀 + 残留 + 结果，只该交结果那一份');
  });

  test('连着两轮组字：第二轮照样只交结果（进位游标不串）', () {
    // 第一轮：组字 → 追加形态提交
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ni你',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    // 第二轮：在"ni你"后面继续组字
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ni你hao',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 3, end: 6),
      ),
    );
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ni你hao好',
        selection: TextSelection.collapsed(offset: 7),
      ),
    );
    expect(forwarded, <String>['你', '好']);
  });

  testWidgets('组字期间**不许**回推 setEditingState（回推会让引擎的组字态失效）',
      (WidgetTester tester) async {
    capturePlatform(tester);
    client.attach(viewId: 0);
    platformCalls.clear();

    // ① 组字中：拼音一个字都不进 shell，也不许回推状态
    client.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    expect(forwarded, isEmpty, reason: '组字中的拼音绝不能进 shell');
    expect(
      editingStateCalls(),
      0,
      reason: '回推 → 引擎 SetText(text) 的默认参数把 composing_ 打成 false ⇒ '
          'IME 的"替换组字区"退化成"追加" ⇒ 拼音累积后被当成新定字发出去（真机回归）',
    );

    // ② 已定字 + 组字尾巴：只交已定字，仍然不回推
    client.updateEditingValue(
      const TextEditingValue(
        text: 'a你',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 1, end: 2),
      ),
    );
    expect(forwarded, <String>['a']);
    expect(editingStateCalls(), 0);

    // ③ 提交（composing 无效）：只交结果，仍然不回推
    client.updateEditingValue(
      const TextEditingValue(
        text: 'a你',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    expect(forwarded, <String>['a', '你']);
    expect(editingStateCalls(), 0);
  });

  testWidgets('attach 只发一次"清空"（干净起点），此后不再碰平台侧模型',
      (WidgetTester tester) async {
    capturePlatform(tester);
    client.attach(viewId: 0);
    expect(editingStateCalls(), 1, reason: '接上时把模型清空一次');
    final Map<String, dynamic> args = lastEditingState(tester);
    expect(args['text'], '', reason: '起点是空的：MP 的状态残渣不许留给下一次输入');

    // 同一个视图重复 attach 是幂等的（不该再发一次）
    client.attach(viewId: 0);
    expect(editingStateCalls(), 1);
  });

  testWidgets('value 暴露的是平台侧原值（排障用）', (WidgetTester tester) async {
    capturePlatform(tester);
    client.attach(viewId: 0);
    const TextEditingValue value = TextEditingValue(
      text: 'hao',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 0, end: 3),
    );
    client.updateEditingValue(value);
    expect(client.value.text, 'hao');
    expect(client.currentTextEditingValue?.text, 'hao');
  });
}
