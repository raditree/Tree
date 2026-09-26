import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  group('TreePaths.resolve 优先级', () {
    test('显式 override 最高优先（相对路径转绝对）', () {
      final TreePaths paths = TreePaths.resolve(
        override: 'custom-dir',
        environment: <String, String>{'TREE_HOME': r'C:\other'},
      );
      expect(paths.root, p.absolute('custom-dir'));
    });

    test('其次 TREE_HOME 环境变量', () {
      final TreePaths paths = TreePaths.resolve(
        environment: <String, String>{'TREE_HOME': p.join('x', 'tree-home')},
      );
      expect(paths.root, p.absolute(p.join('x', 'tree-home')));
    });

    test('否则用平台规范位置（Windows 取 %APPDATA%\\Tree）', () {
      final TreePaths paths = TreePaths.resolve(
        environment: <String, String>{
          if (Platform.isWindows)
            'APPDATA': r'C:\Users\someone\AppData\Roaming',
          if (!Platform.isWindows) 'HOME': '/home/someone',
        },
      );
      if (Platform.isWindows) {
        expect(paths.root, p.join(r'C:\Users\someone\AppData\Roaming', 'Tree'));
      } else {
        expect(paths.root, contains('someone'));
      }
    });

    test('环境变量为空串时回落到平台默认（不是空目录）', () {
      final TreePaths paths = TreePaths.resolve(
        environment: <String, String>{'TREE_HOME': '   '},
      );
      expect(paths.root, isNotEmpty);
      expect(p.isAbsolute(paths.root), isTrue);
    });
  });

  group('布局', () {
    late Directory tempDir;
    late TreePaths paths;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('tree_paths_test_');
      paths = TreePaths(tempDir.path);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('路径拼接与目录骨架', () async {
      expect(
        paths.settingsFile,
        p.join(tempDir.path, 'config', 'settings.yaml'),
      );
      expect(
        paths.modelFile('m1'),
        p.join(tempDir.path, 'config', 'models', 'm1.yaml'),
      );
      expect(
        paths.agentFile('agt_1'),
        p.join(tempDir.path, 'agents', 'agt_1.yaml'),
      );
      expect(
        paths.sessionMetaFile('agt_1', 'ses_1'),
        p.join(tempDir.path, 'data', 'agt_1', 'ses_1', 'session.json'),
      );
      expect(
        paths.messagesFile('agt_1', 'ses_1'),
        p.join(tempDir.path, 'data', 'agt_1', 'ses_1', 'messages.jsonl'),
      );
      expect(Directory(tempDir.path).listSync(), isEmpty);
      await paths.ensureLayout();
      expect(Directory(paths.modelsDir).existsSync(), isTrue);
      expect(Directory(paths.agentsDir).existsSync(), isTrue);
      expect(Directory(paths.sessionsDataDir).existsSync(), isTrue);
      // 幂等
      await paths.ensureLayout();
    });

    test('safeSegment 拒绝路径穿越与非法字符', () {
      expect(TreePaths.safeSegment('session_default'), 'session_default');
      expect(TreePaths.safeSegment(' agt_1 '), 'agt_1');
      for (final String bad in <String>[
        '',
        ' ',
        '.',
        '..',
        'a/b',
        r'a\b',
        'a:b',
        'a b',
        'a*',
      ]) {
        expect(
          () => TreePaths.safeSegment(bad),
          throwsA(isA<ArgumentError>()),
          reason: '应拒绝：$bad',
        );
      }
    });
  });
}
