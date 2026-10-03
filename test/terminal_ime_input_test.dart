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
/// - 我们**不改写**平台侧的值（旧实现在这里截断文本 + 把选区折到末尾 + 标组字区）：
///   引擎 `TextInputModel.AddText` 在"选区折叠"时是**追加**而不是替换组字区
///   （`text_input_model.h` 原文：either appends after the cursor … or deletes the
///   selected text），于是残留的拼音会被"提交结果"一起带回框架，而我们当成已定字
///   整段转发 ⇒ 拼音进 shell。**回显必须原样**，模型与 IME 的认知才一致。
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

  testWidgets('原样回显：平台侧模型一个字都不许被改写（改了拼音就会漏）',
      (WidgetTester tester) async {
    capturePlatform(tester);
    client.attach(viewId: 0);
    platformCalls.clear();

    const TextEditingValue value = TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    client.updateEditingValue(value);

    final Map<String, dynamic> args = lastEditingState(tester);
    expect(args['text'], 'ni', reason: '文本不许被截断');
    expect(args['selectionBase'], 2);
    expect(args['selectionExtent'], 2,
        reason: '选区不许被强制折叠或搬家（引擎的 AddText 靠它决定"追加还是替换组字区"）');
    expect(args['composingBase'], 0);
    expect(args['composingExtent'], 2, reason: '组字区不许被改写');
    expect(forwarded, isEmpty);

    // 已定字 + 组字尾巴：旧实现会把文本截成只剩尾巴（'你'），引擎于是失去"替换组字区"
    // 的能力（AddText 在选区折叠时是追加）——这里钉住"整段原样回显"。
    client.updateEditingValue(
      const TextEditingValue(
        text: 'a你',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 1, end: 2),
      ),
    );
    final Map<String, dynamic> args2 = lastEditingState(tester);
    expect(args2['text'], 'a你', reason: '文本不许被截断成"只剩组字尾巴"');
    expect(args2['composingBase'], 1);
    expect(args2['composingExtent'], 2);
    expect(args2['selectionBase'], 2);
    expect(forwarded, <String>['a']);
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
