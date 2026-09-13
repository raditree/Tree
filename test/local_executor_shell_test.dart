// 本地执行器 shell 选择逻辑单元测试（需求：可测的纯函数）。
// 运行方式（项目根目录）：
//   flutter test test/local_executor_shell_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/local_executor_service.dart';

void main() {
  group('isUnixLikePath', () {
    test('WSL 挂载路径 /mnt/... 判定为 Unix', () {
      expect(isUnixLikePath('/mnt/e/projects'), isTrue);
      expect(isUnixLikePath('/mnt/c/Users'), isTrue);
    });

    test('其他 Unix 风格路径判定为 Unix', () {
      expect(isUnixLikePath('/home/user'), isTrue);
      expect(isUnixLikePath('/usr/local/bin'), isTrue);
      expect(isUnixLikePath('/tmp/x'), isTrue);
      expect(isUnixLikePath('/var/lib'), isTrue);
    });

    test('WSL UNC 路径判定为 Unix/WSL', () {
      expect(isUnixLikePath('\\\\wsl\$\\Ubuntu\\home\\user'), isTrue);
      expect(isUnixLikePath('\\wsl.localhost\\Ubuntu\\home'), isTrue);
    });

    test('纯 Windows 盘符路径判定为非 Unix（保持 cmd）', () {
      expect(isUnixLikePath('C:\\projects\\tree'), isFalse);
      expect(isUnixLikePath('D:/projects/tree'), isFalse);
      expect(isUnixLikePath('e:\\abc'), isFalse);
    });

    test('空路径与非路径判定为非 Unix', () {
      expect(isUnixLikePath(''), isFalse);
      expect(isUnixLikePath('   '), isFalse);
    });
  });

  group('resolveShellForDir', () {
    test('Unix/WSL 目录 → bash', () {
      expect(resolveShellForDir('/mnt/e/dev'), 'bash');
    });

    test('Windows 目录 → cmd（向后兼容）', () {
      expect(resolveShellForDir('C:\\dev'), 'cmd');
    });

    test('空路径 → null', () {
      expect(resolveShellForDir(''), isNull);
    });
  });

  group('truncateGrepLine（grep 回传发送端截断）', () {
    test('未超长返回 null（调用方保留原文）', () {
      expect(truncateGrepLine('short line', 'short'), isNull);
      expect(truncateGrepLine('a' * kGrepMaxLineChars, 'a'), isNull);
    });

    test('超长行按命中点取窗口且长度不超上限', () {
      final String line = '${'x' * 5000}NEEDLE${'y' * 5000}';
      final String cut = truncateGrepLine(line, 'NEEDLE')!;
      expect(cut.length, lessThanOrEqualTo(kGrepMaxLineChars));
      expect(cut.contains('NEEDLE'), isTrue);
      expect(cut.startsWith('…'), isTrue);
      expect(cut.endsWith('…'), isTrue);
    });

    test('命中点靠行首时只保留尾部省略号', () {
      final String line = 'NEEDLE${'y' * 5000}';
      final String cut = truncateGrepLine(line, 'NEEDLE')!;
      expect(cut.startsWith('…'), isFalse);
      expect(cut.endsWith('…'), isTrue);
      expect(cut.contains('NEEDLE'), isTrue);
    });

    test('命中点靠行尾时只保留首部省略号', () {
      final String line = '${'x' * 5000}NEEDLE';
      final String cut = truncateGrepLine(line, 'NEEDLE')!;
      expect(cut.startsWith('…'), isTrue);
      expect(cut.endsWith('…'), isFalse);
      expect(cut.contains('NEEDLE'), isTrue);
    });

    test('带路径分隔符的 jsonl 单行也能被压到上限内', () {
      // 复现 server/data/*.jsonl 的超长单行（实测可达 782 万字符）
      final String line = '{"a":"${'z' * 8000000}","needle":1}';
      final String cut = truncateGrepLine(line, '"needle"')!;
      expect(cut.length, lessThanOrEqualTo(kGrepMaxLineChars));
      expect(cut.contains('"needle"'), isTrue);
    });

    test('ignore_case / regex 命中点定位', () {
      final String line = '${'x' * 3000}NeEdLe${'y' * 3000}';
      expect(
        truncateGrepLine(line, 'needle', ignoreCase: true)!.contains('NeEdLe'),
        isTrue,
      );
      expect(
        truncateGrepLine(line, r'Ne\w+Le', regex: true)!.contains('NeEdLe'),
        isTrue,
      );
    });

    test('命中点定位失败（正则非法）退化为行首窗口', () {
      final String line = '${'x' * 5000}NEEDLE';
      final String cut = truncateGrepLine(line, '(unclosed', regex: true)!;
      expect(cut.length, lessThanOrEqualTo(kGrepMaxLineChars));
      expect(cut.startsWith('…'), isFalse);
    });
  });
}
