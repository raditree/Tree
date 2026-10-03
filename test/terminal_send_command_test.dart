import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/terminal_send_command.dart';

/// 终端 `#TSend` 约定：解析（用户能写什么）与按键拦截（什么时候吞、什么时候补发）。
///
/// 这条约定的风险全在"吞/补发"上：吞错一个字节，shell 就少收到一个字符；补发错一次，
/// 屏幕上就会多出一段用户没打的命令。所以逐条钉住。
void main() {
  group('解析：用户能写什么', () {
    test('引号包起来的正文', () {
      final TerminalSendCommand? command =
          parseTerminalSend('#TSend "创建一名成员，负责插件开发"');
      expect(command, isNotNull);
      expect(command!.text, '创建一名成员，负责插件开发');
      expect(command.filePaths, isEmpty);
      expect(command.isEmpty, isFalse);
    });

    test('没有引号的正文（整行都是话）', () {
      expect(parseTerminalSend('#TSend 帮我看下这个报错')!.text, '帮我看下这个报错');
    });

    test('@路径 = 附件（正文可以为空）', () {
      final TerminalSendCommand command =
          parseTerminalSend('#TSend @C:\\work\\a.md')!;
      expect(command.text, '');
      expect(command.filePaths, <String>[r'C:\work\a.md']);
    });

    test('正文 + 附件混着写；带空格的路径用 @"…"', () {
      final TerminalSendCommand command =
          parseTerminalSend('#TSend "看这个" @"C:\\my docs\\a.md" @b.txt')!;
      expect(command.text, '看这个');
      expect(command.filePaths, <String>[r'C:\my docs\a.md', 'b.txt']);
    });

    test('前后空白无所谓；#TSend 单独一行 = 空指令（调用方要报错而不是静默）', () {
      expect(parseTerminalSend('   #TSend "a"   ')!.text, 'a');
      final TerminalSendCommand command = parseTerminalSend('#TSend')!;
      expect(command.isEmpty, isTrue);
    });

    test('不是指令的一律返回 null（普通命令照常给 shell）', () {
      expect(parseTerminalSend('echo hi'), isNull);
      expect(parseTerminalSend('#TSendx "a"'), isNull);
      expect(parseTerminalSend('#Send "a"'), isNull);
      expect(parseTerminalSend(''), isNull);
    });
  });

  group('按键拦截：什么时候吞、什么时候补发', () {
    List<int>? feed(TerminalSendInterceptor interceptor, String text) {
      List<int>? last;
      for (final String char in text.split('')) {
        last = interceptor.accept(char);
      }
      return last;
    }

    test('打 #TSend "hi" 全程不发 shell，Enter 交给指令', () {
      final TerminalSendInterceptor interceptor = TerminalSendInterceptor();
      expect(feed(interceptor, '#TSend "hi"'), isNull, reason: '整行都扣在本地');
      expect(interceptor.pending, '#TSend "hi"');
      final TerminalSendCommand? command = interceptor.commit();
      expect(command!.text, 'hi');
      expect(interceptor.pending, isEmpty, reason: 'commit 后缓存要清空');
    });

    test('打着打着发现不是指令：把缓存连同这一下一起补发（等于没拦过）', () {
      final TerminalSendInterceptor interceptor = TerminalSendInterceptor();
      expect(interceptor.accept('#'), isNull);
      expect(interceptor.accept('T'), isNull);
      expect(interceptor.accept('x'), utf8Bytes('#Tx'));
      expect(interceptor.pending, isEmpty);
    });

    test('#TSendx 不是指令：前缀扣住，x 一到就整串还给 shell', () {
      final TerminalSendInterceptor interceptor = TerminalSendInterceptor();
      feed(interceptor, '#TSend');
      expect(interceptor.accept('x'), utf8Bytes('#TSendx'));
    });

    test('退格只吃本地缓存（那些字符从没进过 shell）', () {
      final TerminalSendInterceptor interceptor = TerminalSendInterceptor();
      feed(interceptor, '#TS');
      expect(interceptor.backspace(), isTrue);
      expect(interceptor.pending, '#T');
      expect(interceptor.backspace(), isTrue);
      expect(interceptor.pending, '#');
      expect(interceptor.backspace(), isTrue);
      expect(interceptor.pending, isEmpty);
      expect(interceptor.backspace(), isFalse, reason: '没缓存就交给 shell 自己处理');
    });

    test('方向键 / Ctrl+C 这类按键前，缓存要先原样交还 shell', () {
      final TerminalSendInterceptor interceptor = TerminalSendInterceptor();
      feed(interceptor, '#TS');
      expect(interceptor.release(), utf8Bytes('#TS'));
      expect(interceptor.release(), isEmpty, reason: '交还一次就清空');
    });

    test('半截指令按 Enter：commit 返回 null，调用方补发缓存 + 回车', () {
      final TerminalSendInterceptor interceptor = TerminalSendInterceptor();
      feed(interceptor, '#TS');
      expect(interceptor.commit(), isNull);
      expect(interceptor.release(), utf8Bytes('#TS'));
    });

    test('指令确认后的参数段照样扣在本地（含空格）', () {
      final TerminalSendInterceptor interceptor = TerminalSendInterceptor();
      feed(interceptor, '#TSend @a.txt');
      expect(interceptor.pending, '#TSend @a.txt');
      expect(interceptor.commit()!.filePaths, <String>['a.txt']);
    });
  });
}

List<int> utf8Bytes(String text) => utf8.encode(text);
