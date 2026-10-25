import 'dart:io';

import 'package:test/test.dart';

/// **核心领域字段漂移门禁：只减不增（不是完成判据）**。
///
/// 背景：`tree_core` 的四个"通用层"目录（[scanFaces]：plugin / server / ws / store）
/// 里长期混着 `agent_id` / `team_id` / `session_id` / `mode_key` 这几个**具体产品
/// 领域**的字段字面量。继续增长意味着"插件通用宿主"重新被具体产品语义绑死，
/// 所以先钉一根**只卡上限**的钉子：把现状冻结成基线，之后只许往下走。
///
/// 口径：
/// - 扫描面 = [scanFaces] 下**全部 `.dart` 文件**。同目录的 README 是协议说明，
///   字段在那里是合法叙述，故意不扫（文档契约由 `docs_contract_test.dart` 管）。
/// - 计数 = 字段名作为**字面子串**在原文件里的出现次数（因此 `parent_agent_id` /
///   `subagent_id` 也会计入 `agent_id`；`agentId` 这类驼峰不计）。
/// - 粒度 = **文件 × 字段**；基线之外的新文件、或任一文件任一字段超过基线，都红。
/// - 减少永远通过（≤ 语义）；基线不要求跟着下降——但删代码时建议顺手收紧，
///   给后来者留更小的上限。
///
/// **这不是完成判据**：把领域字段彻底清出通用层是另一条独立的迁移工作，本门禁不衡量、
/// 也不要求它在本轮完成。它唯一的职责是"刹车"：下一次新增必须被人看见，并且必须有人
/// 显式改基线、在评审里说明为什么。
void main() {
  // `dart test` 的工作目录是包根（packages/tree_protocol）⇒ 上两级是仓库根。
  final String repoRoot = Directory.current.parent.parent.path;

  test('扫描面与基线规模自检（路径 / 过滤 / 基线失效必须显式失败）', () {
    final _ScanResult result = _scan(repoRoot);
    expect(
      result.filesScanned,
      greaterThan(20),
      reason: '只扫到 ${result.filesScanned} 个 .dart 文件：扫描面或过滤失效',
    );
    expect(result.hits, isNotEmpty, reason: '未扫描到任何领域字段：扫描或基线失效');
    expect(domainDriftBaseline, isNotEmpty, reason: '领域字段基线不能为空');

    final Map<String, int> baselineTotals = <String, int>{
      for (final String field in domainFields) field: 0,
    };
    domainDriftBaseline.forEach((String file, Map<String, int> perField) {
      expect(
        scanFaces.any((String face) => file.startsWith('$face/')),
        isTrue,
        reason: '基线条目不在扫描面内：$file',
      );
      expect(file.endsWith('.dart'), isTrue, reason: '基线条目必须是 .dart：$file');
      expect(perField, isNotEmpty, reason: '基线条目没有计数：$file');
      perField.forEach((String field, int count) {
        expect(domainFields, contains(field), reason: '基线出现未知字段 $field（$file）');
        expect(
          count,
          greaterThan(0),
          reason: '基线计数应为正数：$file [$field] = $count',
        );
        baselineTotals[field] = baselineTotals[field]! + count;
      });
    });
    expect(
      baselineTotals,
      domainDriftBaselineTotals,
      reason:
          'domainDriftBaseline 逐文件明细之和与 domainDriftBaselineTotals 不一致：'
          '$baselineTotals vs $domainDriftBaselineTotals',
    );
  });

  test('没有基线之外的新文件携带领域字段', () {
    final _ScanResult result = _scan(repoRoot);
    final List<String> fresh =
        result.counts.keys
            .where((String file) => !domainDriftBaseline.containsKey(file))
            .toList()
          ..sort();
    expect(
      fresh,
      isEmpty,
      reason: <String>[
        '只减不增：以下文件不在领域字段基线里，却出现了 agent_id/team_id/session_id/mode_key：',
        for (final String file in fresh) ...<String>[
          '  $file',
          for (final _Hit hit in result.hits.where(
            (_Hit hit) => hit.file == file,
          ))
            '    ${hit.location}  ${hit.clippedText}',
        ],
        '—— 通用层（plugin/server/ws/store）不该新增领域字段。确需新增时，先说明原因，',
        '再把文件与逐字段计数显式写进 domainDriftBaseline（并更新 domainDriftBaselineTotals）。',
      ].join('\n'),
    );
  });

  test('每文件每字段出现次数 ≤ 基线（只减不增）', () {
    final _ScanResult result = _scan(repoRoot);
    final List<String> violations = <String>[];
    result.counts.forEach((String file, Map<String, int> perField) {
      final Map<String, int> baseline =
          domainDriftBaseline[file] ?? const <String, int>{};
      perField.forEach((String field, int now) {
        final int allowed = baseline[field] ?? 0;
        if (now <= allowed) return;
        final Iterable<String> places = result.hits
            .where((_Hit hit) => hit.file == file && hit.field == field)
            .map((_Hit hit) => '      ${hit.location}  ${hit.clippedText}');
        violations.add(
          '  $file [$field] 现有 $now 处，基线只允许 $allowed 处（当前出现处如下，'
          '真正超出基线的部分必在其间；若确有新增，请先说明原因；'
          '若只是重构搬动，请同步收紧基线）：\n'
          '${places.join('\n')}',
        );
      });
    });
    expect(
      violations,
      isEmpty,
      reason: <String>[
        '领域字段在通用层里增加了——只减不增，基线是上限而不是目标：',
        ...violations,
        '',
        '注意：本门禁不是"清零"判据，只卡新增；把它当完成判据会误伤正常的删减。',
      ].join('\n'),
    );
  });

  test('领域字段总量 ≤ 基线总量（出现次数）', () {
    final _ScanResult result = _scan(repoRoot);
    final Map<String, int> now = <String, int>{
      for (final String field in domainFields) field: 0,
    };
    result.counts.forEach((String _, Map<String, int> perField) {
      perField.forEach((String field, int count) {
        now[field] = (now[field] ?? 0) + count;
      });
    });
    final List<String> over = <String>[];
    for (final String field in domainFields) {
      final int current = now[field] ?? 0;
      final int allowed = domainDriftBaselineTotals[field] ?? 0;
      if (current <= allowed) continue;
      over.add('  $field: $current > $allowed');
      over.addAll(
        result.hits
            .where((_Hit hit) => hit.field == field)
            .map((_Hit hit) => '      ${hit.location}  ${hit.clippedText}'),
      );
    }
    expect(
      over,
      isEmpty,
      reason: <String>[
        '领域字段总量超过基线（只减不增）：',
        ...over,
        '',
        '修改 domainDriftBaseline 的同时必须同步 domainDriftBaselineTotals。',
      ].join('\n'),
    );
  });
}

/// 被扫描的四个核心"通用层"目录（相对仓库根）。
const List<String> scanFaces = <String>[
  'packages/tree_core/lib/src/plugin',
  'packages/tree_core/lib/src/server',
  'packages/tree_core/lib/src/ws',
  'packages/tree_core/lib/src/store',
];

/// 被盯住的四个领域字段。按**字面子串**计数（见文件头口径）。
const List<String> domainFields = <String>[
  'agent_id',
  'team_id',
  'session_id',
  'mode_key',
];

/// 领域字段基线（2026-10-25 在本仓 HEAD 上取到的精确快照）。
///
/// 文件（仓库相对路径，`/` 分隔）→ 字段 → 出现次数；只记录非零项，缺省 = 0。
/// **只减不增**：这里是上限，不是目标；清零由另一条独立迁移负责，不在本门禁的
/// 验收范围内。确需新增时，先确认它不是"通用层又绑死具体领域"，再改这里并说明原因。
const Map<String, Map<String, int>> domainDriftBaseline =
    <String, Map<String, int>>{
      'packages/tree_core/lib/src/plugin/agent_events.dart': <String, int>{
        'agent_id': 5,
        'team_id': 4,
        'session_id': 4,
      },
      'packages/tree_core/lib/src/plugin/execute_mounts.dart': <String, int>{
        'agent_id': 23,
        'team_id': 9,
        'session_id': 10,
        'mode_key': 11,
      },
      'packages/tree_core/lib/src/plugin/plugin_bus.dart': <String, int>{
        'agent_id': 27,
        'team_id': 23,
        'session_id': 22,
        'mode_key': 19,
      },
      'packages/tree_core/lib/src/plugin/plugin_config_store.dart':
          <String, int>{
            'agent_id': 2,
            'team_id': 2,
            'session_id': 2,
            'mode_key': 5,
          },
      'packages/tree_core/lib/src/plugin/plugin_host.dart': <String, int>{
        'agent_id': 2,
        'team_id': 2,
        'session_id': 2,
        'mode_key': 1,
      },
      'packages/tree_core/lib/src/plugin/station_ids.dart': <String, int>{
        'agent_id': 3,
        'team_id': 3,
        'session_id': 3,
      },
      'packages/tree_core/lib/src/plugin/station_instance.dart': <String, int>{
        'agent_id': 1,
        'team_id': 2,
        'session_id': 1,
        'mode_key': 1,
      },
      'packages/tree_core/lib/src/plugin/station_points.dart': <String, int>{
        'agent_id': 5,
        'team_id': 2,
        'session_id': 4,
      },
      'packages/tree_core/lib/src/plugin/station_scope.dart': <String, int>{
        'agent_id': 4,
        'team_id': 7,
        'session_id': 4,
        'mode_key': 15,
      },
      'packages/tree_core/lib/src/plugin/station_ws_bridge.dart': <String, int>{
        'team_id': 1,
        'mode_key': 2,
      },
      'packages/tree_core/lib/src/plugin/stations.dart': <String, int>{
        'mode_key': 1,
      },
      'packages/tree_core/lib/src/server/core_server.dart': <String, int>{
        'agent_id': 27,
        'team_id': 8,
        'session_id': 27,
        'mode_key': 3,
      },
      'packages/tree_core/lib/src/store/file_store.dart': <String, int>{
        'agent_id': 1,
        'session_id': 1,
      },
      'packages/tree_core/lib/src/store/records.dart': <String, int>{
        'agent_id': 15,
        'team_id': 4,
        'session_id': 8,
        'mode_key': 1,
      },
      'packages/tree_core/lib/src/store/tree_paths.dart': <String, int>{
        'agent_id': 4,
        'session_id': 2,
      },
    };

/// 快照总量（= 上面逐文件明细之和）。
///
/// 单独写出来是为了让"当前值"一眼可读，并由上方的自检测试交叉核对，防止明细被改错。
const Map<String, int> domainDriftBaselineTotals = <String, int>{
  'agent_id': 119,
  'team_id': 67,
  'session_id': 90,
  'mode_key': 59,
};

/// 一次字段命中（文件 + 行号 + 字段 + 该行原文）。
class _Hit {
  _Hit({
    required this.file,
    required this.line,
    required this.field,
    required this.text,
  });

  final String file;
  final int line;
  final String field;
  final String text;

  String get location => '$file:$line';

  String get clippedText =>
      text.length <= 180 ? text : '${text.substring(0, 180)}…';
}

class _ScanResult {
  _ScanResult({
    required this.filesScanned,
    required this.hits,
    required this.counts,
  });

  final int filesScanned;
  final List<_Hit> hits;

  /// 文件 → 字段 → 出现次数（只含命中过的文件/字段）。
  final Map<String, Map<String, int>> counts;
}

_ScanResult _scan(String repoRoot) {
  final List<_Hit> hits = <_Hit>[];
  int filesScanned = 0;
  for (final String face in scanFaces) {
    final Directory dir = Directory('$repoRoot/$face');
    expect(
      dir.existsSync(),
      isTrue,
      reason: '扫描面不存在：$face —— 目录被移动时门禁必须显式失败，不能静默通过',
    );
    final List<File> files =
        dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((File file) => file.path.endsWith('.dart'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    for (final File file in files) {
      filesScanned++;
      final String relative = file.path
          .substring(repoRoot.length + 1)
          .replaceAll('\\', '/');
      final List<String> lines = file.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        for (final String field in domainFields) {
          final int count = field.allMatches(lines[i]).length;
          for (int n = 0; n < count; n++) {
            hits.add(
              _Hit(
                file: relative,
                line: i + 1,
                field: field,
                text: lines[i].trim(),
              ),
            );
          }
        }
      }
    }
  }
  final Map<String, Map<String, int>> counts = <String, Map<String, int>>{};
  for (final _Hit hit in hits) {
    final Map<String, int> perField = counts.putIfAbsent(
      hit.file,
      () => <String, int>{},
    );
    perField[hit.field] = (perField[hit.field] ?? 0) + 1;
  }
  return _ScanResult(filesScanned: filesScanned, hits: hits, counts: counts);
}
