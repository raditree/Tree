import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/terminal_ime_input.dart';

/// 输入法通道的**纯逻辑**（真机现象：终端里打不出中文——没有活着的 TextInputClient，
/// IME 组出来的字根本到不了应用）。这里直接喂 `updateEditingValue`，不需要平台。
void main() {
  late List<String> forwarded;
  late TerminalTextInputClient client;

  setUp(() {
    forwarded = <String>[];
    client = TerminalTextInputClient(onText: forwarded.add);
  });

  test('定字：整段交出去，平台侧字段清空（不回显）', () {
    client.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    expect(forwarded, <String>['你好']);
    expect(client.value.text, isEmpty, reason: '我们不需要回显：屏幕由 VT 解析器说了算');
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
    expect(client.value.text, 'ni', reason: '组字尾巴留在平台侧继续组');
  });

  test('组字前半截已定字：只交已定字，尾巴继续组', () {
    client.updateEditingValue(
      const TextEditingValue(
        text: 'a你',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 1, end: 2),
      ),
    );
    expect(forwarded, <String>['a']);
    expect(client.value.text, '你');
  });

  test('删到空：什么都不交，状态也清空（退格由键盘那一路送给 PTY）', () {
    client.updateEditingValue(
      const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0)),
    );
    expect(forwarded, isEmpty);
    expect(client.value.text, isEmpty);
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
}
