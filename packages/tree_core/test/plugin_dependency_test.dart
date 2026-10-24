import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 片 D：`requires.plugins` 的解析、语义版本区间与「启用前依赖闸门」的纯计算。
///
/// 这里不碰进程 / 磁盘；HTTP 层与 `PluginBus._startOne` 用的是**同一份**判定。
void main() {
  PluginDependency dep(
    String id, {
    String version = '',
    bool optional = false,
  }) => PluginDependency(id: id, version: version, optional: optional);

  PluginDependencyInput input(
    String id, {
    String version = '',
    List<PluginDependency> dependencies = const <PluginDependency>[],
    bool enabled = true,
  }) => PluginDependencyInput(
    id: id,
    version: version,
    dependencies: dependencies,
    enabled: enabled,
  );

  group('requires.plugins 解析', () {
    test('合法形状：id / version / optional 原样保留', () {
      final PluginDependencyParseResult parsed = parsePluginDependencies(
        <String, dynamic>{
          'plugins': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'base', 'version': '>=1.0 <2.0'},
            <String, dynamic>{'id': 'extra', 'optional': true},
          ],
        },
      );
      expect(parsed.error, isNull);
      expect(parsed.dependencies, hasLength(2));
      expect(parsed.dependencies[0].id, 'base');
      expect(parsed.dependencies[0].version, '>=1.0 <2.0');
      expect(parsed.dependencies[0].optional, isFalse);
      expect(parsed.dependencies[1].optional, isTrue);
    });

    test('形状 / id / 版本区间 / optional 不合法都给可读原因（不抛）', () {
      final List<Object?> bad = <Object?>[
        'oops',
        <String, dynamic>{'plugins': 'oops'},
        <String, dynamic>{
          'plugins': <Object?>['oops'],
        },
        <String, dynamic>{
          'plugins': <Map<String, dynamic>>[<String, dynamic>{}],
        },
        <String, dynamic>{
          'plugins': <Map<String, dynamic>>[
            <String, dynamic>{'id': '../escape'},
          ],
        },
        <String, dynamic>{
          'plugins': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'base', 'version': 'not-a-version'},
          ],
        },
        <String, dynamic>{
          'plugins': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'base', 'optional': 'yes'},
          ],
        },
      ];
      for (final Object? raw in bad) {
        final PluginDependencyParseResult parsed = parsePluginDependencies(raw);
        expect(parsed.error, isNotNull, reason: '$raw');
      }
      expect(parsePluginDependencies(null).error, isNull, reason: '没有依赖合法');
    });
  });

  group('语义版本与区间', () {
    test('预发布版小于同版本正式版；v 前缀 / 缺省段可解析', () {
      final SemanticVersion beta = SemanticVersion.tryParse('v1.2.3-beta.2')!;
      final SemanticVersion stable = SemanticVersion.tryParse('1.2.3')!;
      expect(beta.compareTo(stable), lessThan(0));
      expect(SemanticVersion.tryParse('1')!.toString(), '1.0.0');
      expect(SemanticVersion.tryParse('1.2')!.toString(), '1.2.0');
      expect(SemanticVersion.tryParse('nope'), isNull);
    });

    test('区间：满足 / 求交 / 无交集', () {
      final PluginVersionConstraint range =
          PluginVersionConstraint.tryParse('>=1.0 <2.0')!;
      expect(range.satisfies('1.0.0'), isTrue);
      expect(range.satisfies('1.9.9'), isTrue);
      expect(range.satisfies('2.0.0'), isFalse);
      expect(range.satisfies('0.9.0'), isFalse);

      final PluginVersionConstraint inner =
          PluginVersionConstraint.tryParse('>=1.5 <1.8')!;
      expect(range.intersect(inner).satisfies('1.6.0'), isTrue);
      expect(range.intersect(inner).satisfies('1.9.0'), isFalse);

      final PluginVersionConstraint upper =
          PluginVersionConstraint.tryParse('>=2.0')!;
      expect(range.intersect(upper).range.isEmpty, isTrue);
    });

    test('^ / ~ 与精确版本', () {
      expect(PluginVersionConstraint.tryParse('^1.2.0')!.satisfies('1.9.0'), isTrue);
      expect(PluginVersionConstraint.tryParse('^1.2.0')!.satisfies('2.0.0'), isFalse);
      expect(PluginVersionConstraint.tryParse('~1.2.0')!.satisfies('1.2.9'), isTrue);
      expect(PluginVersionConstraint.tryParse('~1.2.0')!.satisfies('1.3.0'), isFalse);
      expect(PluginVersionConstraint.tryParse('1.2.0')!.satisfies('1.2.0'), isTrue);
      expect(PluginVersionConstraint.tryParse('1.2.0')!.satisfies('1.2.1'), isFalse);
    });
  });

  group('启用前依赖闸门', () {
    test('缺依赖 ⇒ 失败，进程不得启动（installed:false）', () {
      final PluginDependencyReport report = evaluatePluginDependencies(
        target: input(
          'app',
          version: '1.0.0',
          dependencies: <PluginDependency>[dep('base', version: '>=1.0 <2.0')],
        ),
        installed: const <PluginDependencyInput>[],
      );
      expect(report.ok, isFalse);
      expect(report.error, contains('缺少依赖 base'));
      final PluginDependencyIssue issue = report.issues.single;
      expect(issue.id, 'base');
      expect(issue.installed, isFalse);
      expect(issue.actual, '');
      expect(issue.by, <String>['app']);
      expect(report.toJson()['ok'], isFalse);
      expect(
        (report.toJson()['missing_dependencies'] as List<dynamic>).single,
        containsPair('id', 'base'),
      );
    });

    test('已安装但版本不符 ⇒ 失败（installed:true + actual）', () {
      final PluginDependencyReport report = evaluatePluginDependencies(
        target: input(
          'app',
          dependencies: <PluginDependency>[dep('base', version: '>=1.0 <2.0')],
        ),
        installed: <PluginDependencyInput>[
          input('base', version: '0.9.0'),
        ],
      );
      expect(report.ok, isFalse);
      expect(report.error, contains('0.9.0'));
      expect(report.issues.single.installed, isTrue);
      expect(report.issues.single.actual, '0.9.0');
    });

    test('多方要求的区间无交集 ⇒ 失败并列出双方（不擅自择一）', () {
      final PluginDependencyReport report = evaluatePluginDependencies(
        target: input(
          'app',
          dependencies: <PluginDependency>[dep('base', version: '>=2.0')],
        ),
        installed: <PluginDependencyInput>[
          input('base', version: '2.1.0'),
          input(
            'other',
            dependencies: <PluginDependency>[dep('base', version: '<2.0')],
          ),
        ],
      );
      expect(report.ok, isFalse);
      expect(report.error, contains('无交集'));
      final PluginDependencyIssue issue = report.issues.single;
      expect(issue.id, 'base');
      expect(issue.by, containsAll(<String>['app', 'other']));
      expect(issue.required, contains('>=2.0'));
      expect(issue.required, contains('<2.0'));
    });

    test('依赖成环 ⇒ 失败并给出环路', () {
      final PluginDependencyReport report = evaluatePluginDependencies(
        target: input(
          'a',
          dependencies: <PluginDependency>[dep('b')],
        ),
        installed: <PluginDependencyInput>[
          input('b', dependencies: <PluginDependency>[dep('a')]),
        ],
      );
      expect(report.ok, isFalse);
      expect(report.error, contains('依赖成环'));
      expect(report.error, contains('→'));
    });

    test('optional 依赖缺失不阻止启用；满足的非可选依赖放行', () {
      expect(
        evaluatePluginDependencies(
          target: input(
            'app',
            dependencies: <PluginDependency>[
              dep('base', version: '>=1.0', optional: true),
            ],
          ),
          installed: const <PluginDependencyInput>[],
        ).ok,
        isTrue,
      );
      expect(
        evaluatePluginDependencies(
          target: input(
            'app',
            dependencies: <PluginDependency>[dep('base', version: '>=1.0')],
          ),
          installed: <PluginDependencyInput>[
            input('base', version: '1.2.0'),
          ],
        ).ok,
        isTrue,
      );
    });

    test('依赖未记录版本但要求非任意区间 ⇒ 失败（不假定满足）', () {
      final PluginDependencyReport report = evaluatePluginDependencies(
        target: input(
          'app',
          dependencies: <PluginDependency>[dep('base', version: '>=1.0')],
        ),
        installed: <PluginDependencyInput>[input('base')],
      );
      expect(report.ok, isFalse);
      expect(report.error, contains('未记录版本'));
    });
  });
}
