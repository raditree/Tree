import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// **执行站错误码链的门禁**（`docs/exec_station_contract.md` §5）。
///
/// 这条链最容易漂的地方不是"没加码"，而是**码表与源码各自长**：
/// 核心写一个没登记的码（调用方永远分支不到）、插件回一个只在插件仓存在的码
/// （核心兜底成 `unknown`，等于白加）、信封两条出口少写一个键（`code` 时有时无）。
/// 所以门禁扫的是**源码字面量**，而不是只检查常量表"看起来有没有"。
///
/// 本节只覆盖桌面仓能自证的三条（§5 第 1~3 条）；第 4~5 条（插件异常类带码、
/// 消费端不许 `contains`）依赖插件仓改造，随插件仓落地后追加。
void main() {
  final Directory repoRoot = Directory('../..');

  // ── 扫描面 ──────────────────────────────────────────────────────────

  /// 契约 §5 第 1 条的扫描面：核心插件运行层 + 整个插件仓。
  ///
    /// 插件仓是**码的真正产地**（执行器写的码在这里），只扫核心等于只验一半。
  /// 目录不存在时**显式失败**：扫描面被移动/改名时门禁不能静默通过。
  final List<String> scanFaces = <String>[
    'packages/tree_core/lib/src/plugin',
    'plugins',
  ];

  /// 码的两种出现形态：字符串字面量 `'code': 'x'`，以及常量引用
  /// `ExecStationErrorCodes.x`（后者连"名字对不对"也要验）。
  final RegExp quotedCode = RegExp(r"'code':\s*'([^']+)'");
  final RegExp quotedCodeJson = RegExp(r'"code":\s*"([^"]+)"');
  final RegExp constantReference = RegExp(
    r'ExecStationErrorCodes\.([A-Za-z][A-Za-z0-9]*)',
  );

  /// 成员名 → 线上值。**必须逐项写全**：新增一个常量而忘了进这张表，
  /// 门禁会以"未登记成员"失败——这正是我们要的"加码必须过评审"。
  const Map<String, String> memberValues = <String, String>{
    'none': ExecStationErrorCodes.none,
    'commandUnknown': ExecStationErrorCodes.commandUnknown,
    'stationDisabled': ExecStationErrorCodes.stationDisabled,
    'scopeDenied': ExecStationErrorCodes.scopeDenied,
    'commandNotOnStation': ExecStationErrorCodes.commandNotOnStation,
    'noMount': ExecStationErrorCodes.noMount,
    'pluginOffline': ExecStationErrorCodes.pluginOffline,
    'badReply': ExecStationErrorCodes.badReply,
    'mountException': ExecStationErrorCodes.mountException,
    'invalidArguments': ExecStationErrorCodes.invalidArguments,
    'fileNotFound': ExecStationErrorCodes.fileNotFound,
    'notAFile': ExecStationErrorCodes.notAFile,
    'dirNotEmpty': ExecStationErrorCodes.dirNotEmpty,
    'targetExists': ExecStationErrorCodes.targetExists,
    'badBase64': ExecStationErrorCodes.badBase64,
    'leaseUnknown': ExecStationErrorCodes.leaseUnknown,
    'leaseDenied': ExecStationErrorCodes.leaseDenied,
    'backendUnreachable': ExecStationErrorCodes.backendUnreachable,
    'unknown': ExecStationErrorCodes.unknown,
  };

  /// 信封键名成员 → 线上键名（理由同 [memberValues]）。
  const Map<String, String> envelopeKeyValues = <String, String>{
    'command': ExecStationEnvelopeKeys.command,
    'ok': ExecStationEnvelopeKeys.ok,
    'mountId': ExecStationEnvelopeKeys.mountId,
    'payload': ExecStationEnvelopeKeys.payload,
    'error': ExecStationEnvelopeKeys.error,
    'code': ExecStationEnvelopeKeys.code,
  };

  /// 同一个类上**不是码**的成员：登记表、查表方法与补码方法。
  ///
  /// 常量引用的正则区分不开"取码"与"调方法"，所以把它们显式列出来——新增方法
  /// 要进这里，新增码要进 [memberValues]，两边都不许"顺手写一个"。
  const Set<String> nonCodeMembers = <String>{'all', 'isKnown', 'settle'};

  /// 收集被扫描源码里的码写法：返回值 = 码/成员名 → 出现处。
  Map<String, List<String>> scanCodeUsage() {
    final Map<String, List<String>> found = <String, List<String>>{};
    int scannedFiles = 0;
    for (final String face in scanFaces) {
      final Directory dir = Directory('${repoRoot.path}/$face');
      expect(
        dir.existsSync(),
        isTrue,
        reason: '扫描面不存在：$face —— 目录被移动时门禁必须显式失败，不能静默通过',
      );
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File) continue;
        final String path = entity.path;
        final String normalized = path.replaceAll('\\', '/');
        // 独立插件仓带着自己的 `.git`，历史文件不该进门禁。
        if (normalized.contains('/.git/')) continue;
        if (!path.endsWith('.dart')) continue;
        scannedFiles++;
        final String src = entity.readAsStringSync();
        final String relative = path.substring(repoRoot.path.length + 1);
        for (final RegExp pattern in <RegExp>[quotedCode, quotedCodeJson]) {
          for (final RegExpMatch match in pattern.allMatches(src)) {
            final String code = match.group(1)!;
            found.putIfAbsent(code, () => <String>[]).add(relative);
          }
        }
        for (final RegExpMatch match in constantReference.allMatches(src)) {
          final String member = match.group(1)!;
          found.putIfAbsent('::$member', () => <String>[]).add(relative);
        }
      }
    }
    expect(
      scannedFiles,
      greaterThan(20),
      reason: '只扫到 $scannedFiles 个文件：路径或过滤失效',
    );
    return found;
  }

  // ── 第 1 条：登记完整性 ─────────────────────────────────────────────

  test('源码里的错误码字面量与常量引用全部已登记', () {
    final Map<String, List<String>> found = scanCodeUsage();
    expect(found, isNotEmpty, reason: '未扫描到任何码写法：正则失效');

    final List<String> offenders = <String>[];
    found.forEach((String key, List<String> where) {
      if (key.startsWith('::')) {
        final String member = key.substring(2);
        if (nonCodeMembers.contains(member)) return;
        if (!memberValues.containsKey(member)) {
          offenders.add('ExecStationErrorCodes.$member（未登记成员）→ $where');
          return;
        }
        // 常量本身已在 [memberValues] 里登记，值必然在码表里（下一条用例钉住）。
        return;
      }
      if (!ExecStationErrorCodes.all.contains(key)) {
        offenders.add("'code': '$key'（不在码表）→ $where");
      }
    });
    expect(
      offenders,
      isEmpty,
      reason:
          '以下码写法没进 ExecStationErrorCodes（契约 §4.2）：${offenders.join('; ')}\n'
          '—— 新增码请先进 tree_protocol 的码表（并写清"谁产生、是否可重试"），'
          '插件仓的码由执行器自己写、也必须是同一张表里的值',
    );
  });

  test('码表与成员登记表双向一致（加常量必须同步门禁）', () {
    expect(
      memberValues['none'],
      ExecStationErrorCodes.none,
      reason: '成功码必须是空串（§4.1：ok:true ⇒ code 为空）',
    );
    expect(
      memberValues.values.where((String v) => v.isNotEmpty).toSet(),
      ExecStationErrorCodes.all,
      reason:
          'memberValues 与 ExecStationErrorCodes.all 不一致：'
          '新增/删除常量时要同步本文件的 memberValues（它是成员名 → 线上的唯一映射）',
    );
    for (final MapEntry<String, String> entry in memberValues.entries) {
      // `none` 就是空串（成功码），不参与 snake_case 断言。
      if (entry.key == 'none') continue;
      expect(
        entry.value,
        matches(RegExp(r'[a-z][a-z0-9_]*')),
        reason: '${entry.key} 不是 snake_case：${entry.value}',
      );
    }
  });

  // ── 第 2 条：核心侧不许写码字面量 ───────────────────────────────────

  test('核心侧不回码字面量（只能从 ExecStationErrorCodes 取）', () {
    for (final String file in <String>[
      'plugin_bus.dart',
      'station_instance.dart',
      'station_runtime.dart',
    ]) {
      final File source = File(
        '${repoRoot.path}/packages/tree_core/lib/src/plugin/$file',
      );
      expect(source.existsSync(), isTrue, reason: '$file 不存在');
      final String src = source.readAsStringSync();
      final List<String> offenders = <String>[
        ...quotedCode.allMatches(src).map((RegExpMatch m) => m.group(0)!),
        ...quotedCodeJson.allMatches(src).map((RegExpMatch m) => m.group(0)!),
      ];
      expect(
        offenders,
        isEmpty,
        reason: '$file 仍有码字面量：$offenders —— 请改成 ExecStationErrorCodes.*',
      );
    }
  });

  // ── 第 3 条：信封键名单一来源 ───────────────────────────────────────

  test('信封六键来自 tree_protocol 常量，且两条出口键集合相同', () {
    // 线上键名本身也要钉住：常量改名会改变 wire 契约。
    expect(
      ExecStationEnvelopeKeys.all,
      <String>{'command', 'ok', 'mount_id', 'payload', 'error', 'code'},
      reason: '信封键名变了就是协议变更（契约 §4.1 六键固定）',
    );

    final File bus = File(
      '${repoRoot.path}/packages/tree_core/lib/src/plugin/plugin_bus.dart',
    );
    expect(bus.existsSync(), isTrue, reason: 'plugin_bus.dart 不存在');
    final String src = bus.readAsStringSync();

    // 只取"station/command 的应答信封"：以 ExecStationEnvelopeKeys.command 为标记，
    // 用非贪婪匹配到最近的 `};`（这两处信封都是扁平 map）。
    final RegExp envelopeBlock = RegExp(
      r'return <String, dynamic>{([\s\S]*?)\n\s*};',
    );
    final RegExp keyToken = RegExp(
      r"ExecStationEnvelopeKeys\.([A-Za-z][A-Za-z0-9]*):|'([a-z][a-z0-9_]*)':",
    );
    final List<Set<String>> keySets = <Set<String>>[];
    final List<String> rawKeys = <String>[];
    for (final RegExpMatch block in envelopeBlock.allMatches(src)) {
      final String body = block.group(1)!;
      if (!body.contains('ExecStationEnvelopeKeys.command')) continue;
      final Set<String> keys = <String>{};
      for (final RegExpMatch token in keyToken.allMatches(body)) {
        final String? member = token.group(1);
        if (member != null) {
          final String? wire = envelopeKeyValues[member];
          expect(
            wire,
            isNotNull,
            reason: '信封里出现未登记的键常量：ExecStationEnvelopeKeys.$member',
          );
          keys.add(wire!);
        } else {
          rawKeys.add(token.group(2)!);
          keys.add(token.group(2)!);
        }
      }
      keySets.add(keys);
    }

    expect(
      keySets,
      hasLength(2),
      reason:
          'station/command 应答应有两条出口（未知命令早退 + 执行站结果），'
          '实际找到 ${keySets.length} 条——新增出口请同时更新契约 §4.1 与门禁',
    );
    expect(
      rawKeys,
      isEmpty,
      reason: "信封键名不能写字面量：$rawKeys —— 请改成 ExecStationEnvelopeKeys.*",
    );
    expect(
      keySets[0],
      keySets[1],
      reason: '两条出口的键集合必须完全相同（防"一条少写一个 code"）',
    );
    expect(
      keySets[0],
      ExecStationEnvelopeKeys.all,
      reason: '信封键集合与 ExecStationEnvelopeKeys.all 不一致：${keySets[0]}',
    );
  });
}
