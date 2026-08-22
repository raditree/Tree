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
}
