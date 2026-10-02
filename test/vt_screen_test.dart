import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/vt_screen.dart';

/// 把字符串编成 UTF-8 字节（喂给 VtScreen.write）
List<int> enc(String s) => utf8.encode(s);

/// 行文本；宽字符右半格（空串）用中点标出，方便断言
String rowText(VtScreen s, int row) =>
    s.lines[row].map((VtCell c) => c.text.isEmpty ? '·' : c.text).join();

/// 整屏文本
List<String> rowsText(VtScreen s) =>
    List<String>.generate(s.rows, (int i) => rowText(s, i));

void main() {
  group('① 纯文本 / 换行 / 回车', () {
    test('逐字写入并按 DECAWM 自动换行', () {
      final VtScreen s = VtScreen(columns: 5, rows: 3);
      s.write(enc('abcdefg'));
      expect(rowText(s, 0), 'abcde');
      expect(rowText(s, 1), 'fg   ');
      expect(s.cursorRow, 1);
      expect(s.cursorColumn, 2);
    });

    test('CR 回到行首并覆盖', () {
      final VtScreen s = VtScreen(columns: 6, rows: 2);
      s.write(enc('abc\rX'));
      expect(rowText(s, 0), 'Xbc   ');
      expect(s.cursorRow, 0);
      expect(s.cursorColumn, 1);
    });

    test('LF 只下移不回车（列保持）', () {
      final VtScreen s = VtScreen(columns: 6, rows: 3);
      s.write(enc('ab\ncd'));
      expect(rowText(s, 0), 'ab    ');
      expect(rowText(s, 1), '  cd  ');
      expect(s.cursorRow, 1);
      expect(s.cursorColumn, 4);
    });

    test('BS 退格 / TAB 到 8 的倍数 / BEL 不打印', () {
      final VtScreen s = VtScreen(columns: 12, rows: 2);
      s.write(enc('abc\bX'));
      expect(rowText(s, 0), 'abX         ');

      final VtScreen t = VtScreen(columns: 12, rows: 2);
      t.write(enc('a\x07b\tc'));
      expect(t.lines[0][0].text, 'a');
      expect(t.lines[0][1].text, 'b');
      expect(t.lines[0][8].text, 'c');
      expect(t.cursorColumn, 9);
    });

    test('行尾延迟换行：写满后光标停在最后一列，再写才换行', () {
      final VtScreen s = VtScreen(columns: 3, rows: 2);
      s.write(enc('abc'));
      expect(s.cursorColumn, 2);
      expect(s.cursorRow, 0);
      s.write(enc('d'));
      expect(rowText(s, 0), 'abc');
      expect(rowText(s, 1), 'd  ');
    });

    test('dirty 标记与 clearDirty', () {
      final VtScreen s = VtScreen(columns: 4, rows: 2);
      expect(s.dirty, isTrue);
      s.clearDirty();
      expect(s.dirty, isFalse);
      s.write(enc('a'));
      expect(s.dirty, isTrue);
      s.clearDirty();
      s.write(enc('\x1b[6n')); // 纯查询不该弄脏屏幕
      expect(s.dirty, isFalse);
      expect(s.takeResponses(), isNotEmpty);
    });
  });

  group('② SGR 属性', () {
    test('颜色 / 粗体 / 反显落到正确的 cell', () {
      final VtScreen s = VtScreen(columns: 8, rows: 1);
      s.write(enc('\x1b[1;31mA\x1b[0mB\x1b[7;44mC'));
      final VtAttr a = s.lines[0][0].attr;
      expect(a.bold, isTrue);
      expect(a.foreground, 1);
      expect(a.background, -1);
      expect(s.lines[0][1].attr, const VtAttr());
      final VtAttr c = s.lines[0][2].attr;
      expect(c.inverse, isTrue);
      expect(c.background, 4);
      expect(c.foreground, -1);
    });

    test('38;5 / 48;5 的 256 色与 38;2 真彩折算', () {
      final VtScreen s = VtScreen(columns: 8, rows: 1);
      s.write(enc('\x1b[38;5;196mX\x1b[48;5;21;39mY\x1b[38;2;255;0;0mZ'));
      expect(s.lines[0][0].attr.foreground, 196);
      expect(s.lines[0][1].attr.background, 21);
      expect(s.lines[0][1].attr.foreground, -1);
      expect(s.lines[0][2].attr.foreground, 196); // 纯红就近到 196
    });

    test('冒号形式的 38:2::r:g:b 也能吃下', () {
      final VtScreen s = VtScreen(columns: 4, rows: 1);
      s.write(enc('\x1b[38:5:196mX\x1b[48:2::0:255:0mY'));
      expect(s.lines[0][0].attr.foreground, 196);
      expect(s.lines[0][1].attr.background, 46); // 0,255,0 就近到 46
    });

    test('22/23/24/27/28/29 关闭属性，39/49 恢复默认色', () {
      final VtScreen s = VtScreen(columns: 12, rows: 1);
      s.write(enc('\x1b[1;2;3;4;7;8;9;31;44mA'));
      s.write(enc('\x1b[22;23;24;27;28;29;39;49mB'));
      final VtAttr a = s.lines[0][0].attr;
      expect(
          <bool>[
            a.bold,
            a.dim,
            a.italic,
            a.underline,
            a.inverse,
            a.hidden,
            a.strike
          ],
          <bool>[true, true, true, true, true, true, true]);
      expect(a.foreground, 1);
      expect(a.background, 4);
      expect(s.lines[0][1].attr, const VtAttr());
    });

    test('90-97 / 100-107 映射到 8-15', () {
      final VtScreen s = VtScreen(columns: 4, rows: 1);
      s.write(enc('\x1b[91;104mX'));
      expect(s.lines[0][0].attr.foreground, 9);
      expect(s.lines[0][0].attr.background, 12);
    });
  });

  group('③ CUP / ED / EL', () {
    test('CUP 定位、缺省值 1、越界夹回', () {
      final VtScreen s = VtScreen(columns: 6, rows: 4);
      s.write(enc('\x1b[3;4HX'));
      expect(s.lines[2][3].text, 'X');
      expect(s.cursorRow, 2);
      expect(s.cursorColumn, 4);
      s.write(enc('\x1b[H'));
      expect(s.cursorRow, 0);
      expect(s.cursorColumn, 0);
      s.write(enc('\x1b[10;90H'));
      expect(s.cursorRow, 3);
      expect(s.cursorColumn, 5);
    });

    test('ED 0 / 1 / 2', () {
      VtScreen fresh() {
        final VtScreen s = VtScreen(columns: 4, rows: 3);
        s.write(enc('abcd\x1b[2;1Hefgh\x1b[3;1Hijkl'));
        return s;
      }

      final VtScreen s0 = fresh();
      s0.write(enc('\x1b[2;3H\x1b[J'));
      expect(rowsText(s0), <String>['abcd', 'ef  ', '    ']);

      final VtScreen s1 = fresh();
      s1.write(enc('\x1b[2;3H\x1b[1J'));
      expect(rowsText(s1), <String>['    ', '   h', 'ijkl']);

      final VtScreen s2 = fresh();
      s2.write(enc('\x1b[2J'));
      expect(rowsText(s2), <String>['    ', '    ', '    ']);
      expect(s2.cursorRow, 2); // 清屏不动光标

      final VtScreen s3 = fresh();
      s3.write(enc('\x1b[3J'));
      expect(rowsText(s3), <String>['    ', '    ', '    ']);
    });

    test('EL 0 / 1 / 2', () {
      VtScreen fresh() {
        final VtScreen s = VtScreen(columns: 4, rows: 3);
        s.write(enc('abcd\x1b[2;1Hefgh\x1b[3;1Hijkl'));
        s.write(enc('\x1b[2;2H'));
        return s;
      }

      final VtScreen s0 = fresh();
      s0.write(enc('\x1b[0K'));
      expect(rowText(s0, 1), 'e   ');

      final VtScreen s1 = fresh();
      s1.write(enc('\x1b[1K'));
      // EL1 清「行首到光标（含）」：光标在第 1 列，所以清掉 0..1 两格
      expect(rowText(s1, 1), '  gh');

      final VtScreen s2 = fresh();
      s2.write(enc('\x1b[2K'));
      expect(rowText(s2, 1), '    ');
    });
  });

  group('④ 备用屏', () {
    test('?1049 进出：主屏内容与光标都保住', () {
      final VtScreen s = VtScreen(columns: 8, rows: 3);
      s.write(enc('main'));
      s.write(enc('\x1b[2;3H')); // 主屏光标停在 (1,2)
      expect(s.cursorRow, 1);
      expect(s.cursorColumn, 2);

      s.write(enc('\x1b[?1049h'));
      expect(s.alternateScreen, isTrue);
      expect(rowsText(s), <String>['        ', '        ', '        ']);
      expect(s.cursorRow, 0);
      expect(s.cursorColumn, 0);
      s.write(enc('alt'));
      expect(rowText(s, 0), 'alt     ');

      s.write(enc('\x1b[?1049l'));
      expect(s.alternateScreen, isFalse);
      expect(rowText(s, 0), 'main    '); // 主屏内容没丢
      expect(s.cursorRow, 1); // 光标恢复
      expect(s.cursorColumn, 2);

      // 再进一次：备用屏应是干净的，不残留上次的 alt
      s.write(enc('\x1b[?1049h'));
      expect(rowText(s, 0), '        ');
      s.write(enc('\x1b[?1049l'));
      expect(rowText(s, 0), 'main    ');
    });

    test('?47 / ?1047 也切备用屏；?25 控制光标可见性', () {
      final VtScreen s = VtScreen(columns: 4, rows: 2);
      s.write(enc('\x1b[?25l'));
      expect(s.cursorVisible, isFalse);
      s.write(enc('\x1b[?25h'));
      expect(s.cursorVisible, isTrue);

      s.write(enc('\x1b[?1047h'));
      expect(s.alternateScreen, isTrue);
      s.write(enc('\x1b[?1047l'));
      expect(s.alternateScreen, isFalse);

      s.write(enc('\x1b[?47h'));
      expect(s.alternateScreen, isTrue);
      s.write(enc('\x1b[?47l'));
      expect(s.alternateScreen, isFalse);
    });

    test('?7 / ?2004 / ?1 状态登记与生效', () {
      final VtScreen s = VtScreen(columns: 4, rows: 2);
      expect(s.bracketedPaste, isFalse);
      s.write(enc('\x1b[?2004h'));
      expect(s.bracketedPaste, isTrue);
      expect(s.privateModeEnabled(2004), isTrue);
      s.write(enc('\x1b[?1h\x1b[?7l'));
      expect(s.applicationCursorKeys, isTrue);
      expect(s.autoWrap, isFalse);

      s.write(enc('\x1b[?2004l\x1b[?1l\x1b[?7h'));
      expect(s.bracketedPaste, isFalse);
      expect(s.privateModeEnabled(2004), isFalse);
      expect(s.autoWrap, isTrue);

      // 关掉自动换行后，写满行只覆盖最后一格
      final VtScreen t = VtScreen(columns: 3, rows: 2);
      t.write(enc('\x1b[?7labcdef'));
      expect(rowText(t, 0), 'abf');
      expect(t.cursorRow, 0);
      expect(t.cursorColumn, 2);
    });
  });

  group('⑤ 跨块 UTF-8', () {
    test('中文字符的字节拆成两次 write 能接上', () {
      final VtScreen s = VtScreen(columns: 6, rows: 2);
      final List<int> zhong = enc('中');
      expect(zhong.length, 3);
      s.write(zhong.sublist(0, 1));
      expect(s.lines[0][0].text, ' '); // 还没成形，不能画半个
      s.write(zhong.sublist(1));
      expect(s.lines[0][0].text, '中');
      expect(s.lines[0][1].text, isEmpty);
      expect(s.cursorColumn, 2);
    });

    test('逐字节喂也能接上，转义序列也能跨块', () {
      final VtScreen t = VtScreen(columns: 4, rows: 1);
      for (final int b in enc('文')) {
        t.write(<int>[b]);
      }
      expect(t.lines[0][0].text, '文');

      final VtScreen u = VtScreen(columns: 6, rows: 1);
      u.write(<int>[0x1b]);
      u.write(enc('[31'));
      expect(u.lines[0][0].text, ' '); // 序列没走完，不能当文字画
      u.write(enc('mX'));
      expect(u.lines[0][0].text, 'X');
      expect(u.lines[0][0].attr.foreground, 1);
    });

    test('非法 UTF-8 退化成替换字符而不是抛异常', () {
      final VtScreen s = VtScreen(columns: 4, rows: 1);
      s.write(<int>[0xFF, 0xFE, 0x41]);
      expect(s.lines[0][0].text, '\uFFFD');
      expect(s.lines[0][1].text, '\uFFFD');
      expect(s.lines[0][2].text, 'A');
    });
  });

  group('⑥ 宽字符', () {
    test('CJK 占两格，右半格是空串', () {
      final VtScreen s = VtScreen(columns: 6, rows: 1);
      s.write(enc('中a'));
      expect(s.lines[0][0].text, '中');
      expect(s.lines[0][1].text, isEmpty);
      expect(s.lines[0][2].text, 'a');
      expect(s.cursorColumn, 3);
      expect(rowText(s, 0), '中·a   ');
    });

    test('行尾放不下的宽字符换到下一行', () {
      final VtScreen s = VtScreen(columns: 3, rows: 2);
      s.write(enc('ab中'));
      expect(rowText(s, 0), 'ab ');
      expect(rowText(s, 1), '中· ');
      expect(s.cursorRow, 1);
      expect(s.cursorColumn, 2);
    });

    test('emoji 也算宽字符', () {
      final VtScreen s = VtScreen(columns: 4, rows: 1);
      s.write(enc('😀x'));
      expect(s.lines[0][0].text, '😀');
      expect(s.lines[0][1].text, isEmpty);
      expect(s.lines[0][2].text, 'x');
    });
  });

  group('⑦ 未知序列安全跳过', () {
    test('不认识的 CSI / OSC / DCS 被跳过，后续文本正常', () {
      final VtScreen s = VtScreen(columns: 12, rows: 2);
      s.write(enc('\x1b[99;99;99zABC'));
      expect(rowText(s, 0), 'ABC         ');

      s.write(enc('\x1b]0;窗口标题\x07D'));
      expect(s.lines[0][3].text, 'D');

      s.write(enc('\x1bP1+q544e\x1b\\E'));
      expect(s.lines[0][4].text, 'E');

      s.write(enc('\x1b[?1234hF')); // 未知私有模式：只记状态
      expect(s.lines[0][5].text, 'F');
      expect(s.privateModeEnabled(1234), isTrue);

      s.write(enc('\x1b(BG')); // 字符集选择：吃掉一个字节
      expect(s.lines[0][6].text, 'G');

      expect(rowText(s, 0), 'ABCDEFG     ');
      expect(s.cursorRow, 0);
    });

    test('残缺的转义序列不会画到屏幕上', () {
      final VtScreen s = VtScreen(columns: 8, rows: 2);
      s.write(enc('A\x1b[1;2'));
      expect(rowText(s, 0), 'A       ');
      s.write(enc('H')); // 续上，成为 CUP 1;2 → 0-based (0,1)
      expect(s.cursorRow, 0);
      expect(s.cursorColumn, 1);
      expect(s.lines[0][0].text, 'A');

      final VtScreen t = VtScreen(columns: 4, rows: 1);
      t.write(<int>[0x41, 0x1b]);
      expect(rowText(t, 0), 'A   ');
    });
  });

  group('⑧ resize', () {
    test('缩小保留左上角、光标夹回范围内；放大补空格', () {
      final VtScreen s = VtScreen(columns: 6, rows: 2);
      s.write(enc('abcdef\x1b[2;1Hghijkl'));
      s.write(enc('\x1b[2;6H'));
      expect(s.cursorColumn, 5);
      expect(s.cursorRow, 1);

      s.resize(3, 1);
      expect(s.columns, 3);
      expect(s.rows, 1);
      expect(s.lines.length, 1);
      expect(s.lines[0].length, 3);
      expect(rowText(s, 0), 'abc');
      expect(s.cursorRow, 0);
      expect(s.cursorColumn, 2);

      s.resize(8, 3);
      expect(s.rows, 3);
      expect(s.lines[0].length, 8);
      expect(rowText(s, 0), 'abc     ');
      expect(s.cursorRow, 0);
      expect(s.cursorColumn, 2);
    });

    test('裁剪到半个宽字符时退化成空格', () {
      final VtScreen s = VtScreen(columns: 4, rows: 1);
      s.write(enc('中中'));
      expect(s.lines[0][2].text, '中');
      expect(s.lines[0][3].text, isEmpty);

      s.resize(3, 1);
      expect(s.lines[0][2].text, ' '); // 右半格被裁掉 → 左半格变空格
      expect(rowText(s, 0), '中· ');
    });

    test('缩到 1x1 也不炸，光标在范围内', () {
      final VtScreen s = VtScreen(columns: 10, rows: 5);
      s.write(enc('hello'));
      s.resize(1, 1);
      expect(s.lines.length, 1);
      expect(s.lines[0].length, 1);
      expect(s.cursorRow, 0);
      expect(s.cursorColumn, 0);
      s.write(enc('Z'));
      expect(rowText(s, 0), 'Z');
    });
  });

  group('⑨ DSR / DA 应答', () {
    test('DSR 6 / 5 与 DA1 / DA2 能从 takeResponses 取到', () {
      final VtScreen s = VtScreen(columns: 10, rows: 4);
      s.write(enc('\x1b[3;4H')); // 光标到 (2,3)
      s.write(enc('\x1b[6n'));
      expect(s.takeResponses(), utf8.encode('\x1b[3;4R'));
      expect(s.takeResponses(), isEmpty); // 取走后清空

      s.write(enc('\x1b[5n'));
      expect(s.takeResponses(), utf8.encode('\x1b[0n'));

      s.write(enc('\x1b[c'));
      expect(s.takeResponses(), utf8.encode('\x1b[?1;2c'));

      s.write(enc('\x1b[>c'));
      final List<int> da2 = s.takeResponses();
      expect(da2.length, greaterThan(3));
      expect(da2.sublist(0, 3), utf8.encode('\x1b[>'));

      // 多个应答按顺序排队
      s.write(enc('\x1b[6n\x1b[6n'));
      final List<int> both = s.takeResponses();
      final List<int> one = utf8.encode('\x1b[3;4R');
      expect(both.length, one.length * 2);
      expect(both.sublist(0, one.length), one);
      expect(both.sublist(one.length), one);
    });
  });

  group('⑩ 不抛异常', () {
    test('随机含 ESC 的字节流不崩，屏幕保持自洽', () {
      final Random rand = Random(20240607);
      final VtScreen s = VtScreen(columns: 40, rows: 12);
      final List<int> bytes = <int>[];
      for (int i = 0; i < 8000; i++) {
        final int r = rand.nextInt(100);
        if (r < 30) {
          bytes.add(0x1b);
          if (r < 12) {
            bytes.add(0x5b);
            bytes.add(0x30 + rand.nextInt(0x50));
          }
        } else if (r < 40) {
          bytes.add(0x9b); // 8 位 C1（未支持，也不能崩）
        } else {
          bytes.add(rand.nextInt(256));
        }
      }
      expect(() {
        int i = 0;
        while (i < bytes.length) {
          final int n = 1 + rand.nextInt(23);
          final int end = (i + n) > bytes.length ? bytes.length : i + n;
          s.write(bytes.sublist(i, end));
          i = end;
        }
        s.takeResponses();
        s.resize(7, 3);
        s.write(enc('尾巴'));
        s.takeResponses();
      }, returnsNormally);

      expect(s.lines.length, s.rows);
      for (int y = 0; y < s.rows; y++) {
        expect(s.lines[y].length, s.columns);
      }
      expect(s.cursorRow, inInclusiveRange(0, s.rows - 1));
      expect(s.cursorColumn, inInclusiveRange(0, s.columns - 1));
    });

    test('病态参数、半截序列、半截 UTF-8 都不崩', () {
      final VtScreen s = VtScreen(columns: 10, rows: 3);
      final List<String> nasty = <String>[
        '\x1b[999999999999999999999m',
        '\x1b[',
        '\x1b[;',
        '\x1b[?',
        '\x1b[0;0;0;0;0H',
        '\x1b[38;5m',
        '\x1b[48;2;1m',
        '\x1b[38;2;999;0;0m',
        '\x1b]0;没有终止符',
        '\x1bP',
        '\x1b(',
        '\x1b',
        '\x1b[1;2;3;4;5;6;7;8;9;10m',
        '\x1b[~~~m',
        '\x1b[2147483648m',
        '\x1b[3J\x1b[2J',
        '\x00\x01\x02\x7f',
      ];
      expect(() {
        for (final String n in nasty) {
          s.write(enc(n));
        }
        s.write(enc('\x1b\\')); // 从 OSC 状态里出来
        s.write(<int>[0xC2]); // 半截 UTF-8 挂在那儿
        s.write(<int>[0xA9]); // 补成 ©
      }, returnsNormally);

      for (int y = 0; y < s.rows; y++) {
        expect(s.lines[y].length, s.columns);
      }
      expect(rowsText(s).join().contains('©'), isTrue);
    });
  });

  group('⑪ 擦除/编辑与滚动区域', () {
    test('X / P / @ 在同一样内起效', () {
      VtScreen base() {
        final VtScreen s = VtScreen(columns: 6, rows: 2);
        s.write(enc('abcdef\x1b[1;2H'));
        return s;
      }

      final VtScreen sx = base();
      sx.write(enc('\x1b[3X'));
      expect(rowText(sx, 0), 'a   ef');

      final VtScreen sp = base();
      sp.write(enc('\x1b[2P'));
      expect(rowText(sp, 0), 'adef  ');

      final VtScreen si = base();
      si.write(enc('\x1b[2@'));
      expect(rowText(si, 0), 'a  bcd');
    });

    test('L / M 在光标行插入、删除', () {
      final VtScreen s = VtScreen(columns: 4, rows: 4);
      s.write(enc('aaaa\x1b[2;1Hbbbb\x1b[3;1Hcccc\x1b[4;1Hdddd'));
      expect(rowsText(s), <String>['aaaa', 'bbbb', 'cccc', 'dddd']);

      s.write(enc('\x1b[2;1H\x1b[1L'));
      expect(rowsText(s), <String>['aaaa', '    ', 'bbbb', 'cccc']);

      s.write(enc('\x1b[2;1H\x1b[1M'));
      expect(rowsText(s), <String>['aaaa', 'bbbb', 'cccc', '    ']);
    });

    test('滚动区域 r 限制 S/T 与 IND/RI', () {
      final VtScreen s = VtScreen(columns: 3, rows: 5);
      s.write(enc('1\r\n2\r\n3\r\n4\r\n5'));
      expect(rowsText(s), <String>['1  ', '2  ', '3  ', '4  ', '5  ']);

      s.write(enc('\x1b[2;4r')); // 区域 = 第 2..4 行
      expect(s.scrollTop, 1);
      expect(s.scrollBottom, 3);
      expect(s.cursorRow, 0); // 设区域后光标归位（原点模式关闭 → 屏幕左上）

      s.write(enc('\x1b[S')); // 区域内上滚一行
      expect(rowsText(s), <String>['1  ', '3  ', '4  ', '   ', '5  ']);

      s.write(enc('\x1b[T')); // 再下滚回来
      expect(rowsText(s), <String>['1  ', '   ', '3  ', '4  ', '5  ']);

      s.write(enc('\x1b[2;1H\x1bD')); // 区域顶行 IND：区域没到底，只下移光标
      expect(s.cursorRow, 2);
      expect(rowsText(s), <String>['1  ', '   ', '3  ', '4  ', '5  ']);

      s.write(enc('\x1b[2;1H\x1bM')); // 区域顶行 RI：区域内反向滚屏
      expect(rowsText(s), <String>['1  ', '   ', '   ', '3  ', '5  ']);

      s.write(enc('\x1b[4;1H\x1bD')); // 区域底行 IND：区域内上滚
      // 区域（第 2..4 行）原来是 ['   ', '   ', '3  ']，上滚后变 ['   ', '3  ', '   ']
      expect(rowsText(s), <String>['1  ', '   ', '3  ', '   ', '5  ']);
    });

    test('ESC 7 / ESC 8 与 CSI s / CSI u 保存恢复光标和属性', () {
      final VtScreen s = VtScreen(columns: 6, rows: 3);
      s.write(enc('\x1b[1;31m\x1b[2;2H\x1b7')); // 存：位置 (1,1) + 红粗体
      s.write(enc('\x1b[3;5H\x1b[0m'));
      s.write(enc('\x1b8')); // 恢复
      expect(s.cursorRow, 1);
      expect(s.cursorColumn, 1);
      s.write(enc('X'));
      expect(s.lines[1][1].attr.foreground, 1);
      expect(s.lines[1][1].attr.bold, isTrue);

      s.write(enc('\x1b[1;1H\x1b[s\x1b[3;3H\x1b[uY'));
      expect(s.lines[0][0].text, 'Y');
    });
  });

  group('⑫ 真实场景 smoke（vim 开场/收场）', () {
    test('进备用屏 → 画反显状态条/语法色 → 退出后主屏恢复', () {
      final VtScreen s = VtScreen(columns: 20, rows: 5);
      s.write(enc('shell 提\r\n')); // 主屏先有内容
      expect(s.lines[0][0].text, 's');

      // vim 开场序列：备用屏 + 应用键盘 + 隐藏光标 + 设标题 + 括号粘贴 + 清屏
      s.write(enc('\x1b[?1049h\x1b[?1h\x1b=\x1b[?2004h\x1b]0;vim\x07'));
      s.write(enc('\x1b[?25l\x1b[2J\x1b[H'));
      expect(s.alternateScreen, isTrue);
      expect(s.cursorVisible, isFalse);
      expect(s.applicationCursorKeys, isTrue);
      expect(s.bracketedPaste, isTrue);

      // 波浪线填充 + 第一行反显状态条（带 EL 清行尾）
      s.write(enc('\x1b[3;1H~\r\n~\r\n~'));
      s.write(enc('\x1b[1;1H\x1b[7m NORMAL \x1b[27m\x1b[K'));
      // 内容行：绿色粗体 hello，随后重置成默认属性的 world
      s.write(enc('\x1b[2;1H\x1b[1;32mhello\x1b[0m world'));
      // 最后一行反显的 vim 状态
      s.write(enc('\x1b[5;1H\x1b[7m-- INSERT --\x1b[0m\x1b[K'));

      expect(rowText(s, 0).startsWith(' NORMAL '), isTrue);
      expect(s.lines[0][1].attr.inverse, isTrue);
      expect(s.lines[0][9].attr.inverse, isFalse); // 27m 已关反显
      expect(rowText(s, 1).startsWith('hello world'), isTrue);
      expect(s.lines[1][0].attr.foreground, 2);
      expect(s.lines[1][0].attr.bold, isTrue);
      expect(s.lines[1][6].attr, const VtAttr()); // 重置后的 world 是默认属性
      expect(rowText(s, 2).startsWith('~'), isTrue);
      expect(rowText(s, 3).startsWith('~'), isTrue);
      expect(rowText(s, 4).startsWith('-- INSERT --'), isTrue);

      // vim 收场：恢复主屏与光标
      s.write(enc('\x1b[?2004l\x1b[?25h\x1b[?1049l'));
      expect(s.alternateScreen, isFalse);
      expect(s.cursorVisible, isTrue);
      expect(rowText(s, 0).startsWith('shell 提'), isTrue); // 主屏内容还在

      for (int y = 0; y < s.rows; y++) {
        expect(s.lines[y].length, s.columns);
      }
    });
  });
}
