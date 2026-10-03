import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_local_exec/src/windows_environment.dart';

/// 按登录口径重建环境变量的纯逻辑（用户 2026-10-03：「Tree 的 terminal 和我直接在本机使用的
/// terminal 在行为上有分歧」）。这里把 `reg.exe query` 的输出、合并规则、展开与回退全钉住——
/// 真注册表不参与，避免测试依赖机器状态。
void main() {
  group('解析 reg query 输出', () {
    test('认得出 REG_SZ / REG_EXPAND_SZ，空值也算存在', () {
      final Map<String, RegEnvValue> env = parseRegQueryEnv(
        'HKEY_CURRENT_USER\\Environment\r\n'
        '    Path    REG_EXPAND_SZ    C:\\Users\\me\\bin;%USERPROFILE%\\go\\bin\r\n'
        '\r\n'
        '    TEMP    REG_SZ\r\n'
        '    Foo     REG_SZ    a b c\r\n',
      );
      expect(env['Path']!.expand, isTrue);
      expect(env['Path']!.value, r'C:\Users\me\bin;%USERPROFILE%\go\bin');
      expect(env['TEMP']!.value, isEmpty);
      expect(env['TEMP']!.expand, isFalse);
      expect(env['Foo']!.value, 'a b c', reason: '数据里的空格不能吃掉');
    });

    test('认不出的行跳过（注册表工具加噪声不该掀掉整套环境）', () {
      final Map<String, RegEnvValue> env = parseRegQueryEnv(
        'HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment\r\n'
        '    Path    REG_EXPAND_SZ    C:\\Windows\\system32\r\n'
        'some noise line\r\n'
        '    NotAType    SOMETHING    x\r\n'
        '    \r\n',
      );
      expect(env.keys, <String>['Path']);
      expect(env['Path']!.value, r'C:\Windows\system32');
    });
  });

  group('按登录口径合成', () {
    Map<String, RegEnvValue> reg(Map<String, String> values, {bool expand = true}) =>
        values.map(
          (String key, String value) =>
              MapEntry<String, RegEnvValue>(key, RegEnvValue(value, expand: expand)),
        );

    test('Path = 机器级在前 + 用户级在后（与系统一致）', () {
      final Map<String, String> env = composeLoginEnvironment(
        machine: reg(<String, String>{'Path': r'C:\Windows\system32'}),
        user: reg(<String, String>{'Path': r'C:\Users\me\bin'}),
        inherited: <String, String>{'Path': r'D:\stale'},
      );
      expect(env['Path'], r'C:\Windows\system32;C:\Users\me\bin');
      expect(
        env.keys.where((String k) => k.toLowerCase() == 'path'),
        hasLength(1),
        reason: '大小写变体不能留两份（Path/PATH 同时在会各平台表现不一）',
      );
    });

    test('用户级只写了空串 ⇒ 沿用机器级那一份（不是清空）', () {
      final Map<String, String> env = composeLoginEnvironment(
        machine: reg(<String, String>{'Path': r'C:\Windows'}),
        user: reg(<String, String>{'Path': ''}),
        inherited: <String, String>{},
      );
      expect(env['Path'], r'C:\Windows');
    });

    test('其余同名变量：用户级覆盖机器级', () {
      final Map<String, String> env = composeLoginEnvironment(
        machine: reg(<String, String>{'TEMP': r'C:\Windows\Temp', 'JAVA_HOME': r'C:\jdk17'}),
        user: reg(<String, String>{'TEMP': r'C:\Users\me\Temp'}),
        inherited: <String, String>{},
      );
      expect(env['TEMP'], r'C:\Users\me\Temp');
      expect(env['JAVA_HOME'], r'C:\jdk17', reason: '用户级没定义就沿用机器级');
    });

    test('注册表没有的继承变量原样保留（运行环境注入的 TREE_* 不该被抹掉）', () {
      final Map<String, String> env = composeLoginEnvironment(
        machine: reg(<String, String>{'Path': r'C:\Windows'}),
        user: reg(<String, String>{}),
        inherited: <String, String>{
          'TREE_HOME': r'E:\tree-home',
          'PATH': r'C:\injected;C:\Windows',
        },
      );
      expect(env['TREE_HOME'], r'E:\tree-home');
      expect(
        env['Path'],
        r'C:\Windows',
        reason: 'Path 以注册表为准（注入的那份不算数），并且不留 PATH 大小写重复项',
      );
      expect(env.keys.where((String k) => k.toLowerCase() == 'path'), hasLength(1));
    });

    test('REG_EXPAND_SZ 展开 %NAME%（含套嵌与认不出的名字）', () {
      final Map<String, String> env = composeLoginEnvironment(
        machine: reg(<String, String>{
          'SystemRoot': r'C:\Windows',
          'USERPROFILE': r'C:\Users\me',
          'Path': r'%SystemRoot%\system32;%NOPE%\x',
        }),
        user: reg(<String, String>{'Path': r'%USERPROFILE%\bin'}),
        inherited: <String, String>{},
      );
      expect(env['Path'], r'C:\Windows\system32;%NOPE%\x;C:\Users\me\bin');
    });

    test('展开也能用继承来的值（注册表里没有 SystemRoot 时不留 %SystemRoot% 字面量）', () {
      final Map<String, String> env = composeLoginEnvironment(
        machine: reg(<String, String>{'Path': r'%SystemRoot%\system32'}),
        user: reg(<String, String>{}),
        inherited: <String, String>{'SystemRoot': r'C:\Windows'},
      );
      expect(env['Path'], r'C:\Windows\system32');
      expect(env['SystemRoot'], r'C:\Windows');
    });

    test('变量环不会死循环（两轮封顶）', () {
      final Map<String, String> env = composeLoginEnvironment(
        machine: reg(<String, String>{'A': '%B%', 'B': '%A%'}),
        user: reg(<String, String>{}),
        inherited: <String, String>{},
      );
      expect(env['A'], isNotNull);
      expect(env['B'], isNotNull);
    });
  });

  group('取真值（注入的 reg 查询）', () {
    test('两次查询都成功 ⇒ 返回重建后的环境', () async {
      final Map<String, String> env = await loginEnvironment(
        inherited: <String, String>{'TREE_HOME': r'E:\tree', 'Path': r'D:\stale'},
        query: (String key) async => key == kMachineEnvironmentKey
            ? '    Path    REG_EXPAND_SZ    C:\\Windows\\system32\r\n'
                '    SystemRoot    REG_SZ    C:\\Windows\r\n'
            : '    Path    REG_EXPAND_SZ    C:\\Users\\me\\bin\r\n',
      );
      expect(env['Path'], r'C:\Windows\system32;C:\Users\me\bin');
      expect(env['TREE_HOME'], r'E:\tree');
      expect(env['SystemRoot'], r'C:\Windows');
    });

    test('任一次查询拿不到 ⇒ 整体退回继承（并把原因交出来）', () async {
      final List<String> logs = <String>[];
      final Map<String, String> env = await loginEnvironment(
        inherited: <String, String>{'Path': r'D:\stale'},
        query: (String key) async =>
            key == kMachineEnvironmentKey ? null : '    Path    REG_SZ    x\r\n',
        log: logs.add,
      );
      expect(env['Path'], r'D:\stale');
      expect(logs, isNotEmpty, reason: '回退必须留痕（红线 3：不留静默失败）');
    });

    test('查询抛错 ⇒ 整体退回继承', () async {
      final Map<String, String> env = await loginEnvironment(
        inherited: <String, String>{'Path': r'D:\stale'},
        query: (String key) async => throw StateError('boom'),
      );
      expect(env['Path'], r'D:\stale');
    });

    test('平台口径：非 Windows 直接返回继承值；Windows 上合成', () async {
      final Map<String, String> env = await loginEnvironment(
        inherited: <String, String>{'PATH': '/usr/bin'},
        // 机器级与用户级都给同一份（Path = 机器级;"+"用户级）
        query: (String key) async => '    Path    REG_SZ    C:\\x\r\n',
      );
      if (Platform.isWindows) {
        expect(env['Path'], r'C:\x;C:\x');
      } else {
        expect(env['PATH'], '/usr/bin');
      }
    });
  });
}
