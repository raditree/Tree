import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 协议冻结的**完备性门禁**。
///
/// M7 删除 `server/` 后，原先"扫 Python 源码"的两条门禁换成**本仓库内**的等价断言：
/// 1. 前端/核心源码里出现的 `'type': 'x'` 字面量，要么是协议帧，要么在
///    [nonProtocolTypeLiterals] 登记并写明原因（否则协议无声漂移）；
/// 2. 核心必须**逐一处理**每一种上行帧常量（新增帧不能被 default 静默吞掉）。
void main() {
  final Directory repoRoot = Directory('../..');

  test('源码里的 "type" 字面量全部是协议帧或在登记表中', () {
    final Set<String> scanned = _scanTypeLiterals(repoRoot);
    expect(scanned, isNotEmpty, reason: '未扫描到任何 type 字面量：路径或正则失效');

    final Set<String> covered = <String>{
      ...WsInboundType.all,
      ...WsOutboundType.all,
      ...CoreEventType.all,
      ...nonProtocolTypeLiterals.keys,
    };
    final Set<String> uncovered = scanned.difference(covered);
    expect(
      uncovered,
      isEmpty,
      reason:
          '以下 type 字面量既不是协议帧，也没在 nonProtocolTypeLiterals 登记：'
          '${uncovered.toList()..sort()} —— 请补充常量，或登记并写明原因',
    );
  });

  test('核心逐一处理每种上行帧（新增帧不得被 default 静默忽略）', () {
    final File core = File(
      '${repoRoot.path}/packages/tree_core/lib/src/server/core_server.dart',
    );
    expect(core.existsSync(), isTrue, reason: 'core_server.dart 不存在');
    final String src = core.readAsStringSync();
    final List<String> missing = <String>[];
    for (final String value in WsInboundType.all) {
      // 常量名 = 值名的 camelCase（register_local_executor → registerLocalExecutor）
      if (!src.contains('WsInboundType.${_camel(value)}')) missing.add(value);
    }
    expect(
      missing,
      isEmpty,
      reason: '核心未显式处理以下上行帧：$missing —— 前端会发它们，静默忽略会造成"点了没反应"',
    );
  });

  test('前端使用的 /api 路径全部在 ApiPaths 中声明', () {
    final Set<String> used = _scanFrontendApiPaths(
      Directory('${repoRoot.path}/lib'),
    );
    expect(used, isNotEmpty, reason: '未扫描到任何 /api 路径字符串');

    final Set<String> declared = ApiPaths.all.map(_normalizePath).toSet();
    final Set<String> undeclared = used.difference(declared);
    expect(
      undeclared,
      isEmpty,
      reason: '以下前端路径未在 ApiPaths 中声明：${undeclared.toList()..sort()}',
    );
  });

  test('前端已不再引用账号体系路径（M1b 删除登录与账号设置）', () {
    final Set<String> used = _scanFrontendApiPaths(
      Directory('${repoRoot.path}/lib'),
    );
    final Set<String> accountPaths = used
        .where((String p) => p.startsWith('/api/auth'))
        .toSet();
    expect(
      accountPaths,
      isEmpty,
      reason: 'desktop 分支已取消账号体系，前端不应再出现这些调用：$accountPaths',
    );
  });

  test('分帧常量只能来自协议包：前后端都不得重复定义或硬编码字面量', () {
    // 1) 不得定义 kWsFrame*（阈值/预算/TTL）
    final RegExp redefinition = RegExp(
      r'^\s*const\s+(?:int|Duration|String)\s+kWsFrame',
      multiLine: true,
    );
    final List<String> offenders = <String>[];
    final List<String> hardcoded = <String>[];
    final RegExp literal = RegExp(r"'(frame_begin|frame_chunk|frame_end)'");
    for (final String tree in <String>[
      'lib',
      'packages/tree_core/lib',
      'packages/tree_local_exec/lib',
      'packages/tree_core_cli/bin',
    ]) {
      final Directory dir = Directory('${repoRoot.path}/$tree');
      if (!dir.existsSync()) continue;
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String src = entity.readAsStringSync();
        if (redefinition.hasMatch(src)) offenders.add(entity.path);
        if (literal.hasMatch(src)) hardcoded.add(entity.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '分帧阈值/分片预算/TTL 与三件套类型名必须来自 tree_protocol，'
          '否则核心与前端阈值会再次漂移：$offenders',
    );
    expect(
      hardcoded,
      isEmpty,
      reason: '分帧三件套必须引用 WsOutboundType.*，不能硬编码字面量：$hardcoded',
    );
  });

  test('常量集合内部无重复且非空', () {
    for (final MapEntry<String, Set<String>> e in <String, Set<String>>{
      'WsInboundType': WsInboundType.all,
      'WsOutboundType': WsOutboundType.all,
      'CoreEventType': CoreEventType.all,
      'ApiPaths.kept': ApiPaths.kept,
      'ApiPaths.removedWithAccounts': ApiPaths.removedWithAccounts,
    }.entries) {
      expect(e.value, isNotEmpty, reason: '${e.key} 不应为空');
      for (final String v in e.value) {
        expect(v.trim(), isNotEmpty, reason: '${e.key} 含空字符串');
      }
    }
    // 上行/下行唯一允许的重名：heartbeat（双向保活，两侧都用同一字面量）。
    // 其余任何重名都意味着协议建模错误，必须在这里暴露。
    expect(WsInboundType.all.intersection(WsOutboundType.all), <String>{
      WsInboundType.heartbeat,
    }, reason: '上/下行除 heartbeat（双向保活）外不应重名');
    // 账号组必须真的被保留组排除
    expect(
      ApiPaths.kept.intersection(ApiPaths.removedWithAccounts),
      isEmpty,
      reason: '同一条路径不能既保留又删除',
    );
  });
}

/// 扫描本仓库源码（前端 + 各包）里的 `'type': 'x'` 字面量。
Set<String> _scanTypeLiterals(Directory repoRoot) {
  final RegExp literal = RegExp(r"'type'\s*:\s*'([a-z_][a-z0-9_]*)'");
  final Set<String> found = <String>{};
  for (final String tree in <String>[
    'lib',
    'packages/tree_core/lib',
    'packages/tree_local_exec/lib',
    'packages/tree_protocol/lib',
    'packages/tree_core_cli/bin',
  ]) {
    final Directory dir = Directory('${repoRoot.path}/$tree');
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.contains('non_protocol_literals')) continue;
      for (final RegExpMatch m in literal.allMatches(
        entity.readAsStringSync(),
      )) {
        found.add(m.group(1)!);
      }
    }
  }
  return found;
}

/// `register_local_executor` → `registerLocalExecutor`。
String _camel(String snake) {
  final List<String> parts = snake.split('_');
  return parts.first +
      parts
          .skip(1)
          .map(
            (String p) =>
                p.isEmpty ? '' : '${p[0].toUpperCase()}${p.substring(1)}',
          )
          .join();
}

/// 扫描前端 Dart 源码中的 `'/api/...'` 字面量并按占位符归一化。
Set<String> _scanFrontendApiPaths(Directory lib) {
  if (!lib.existsSync()) fail('lib 目录不存在：${lib.path}');
  final RegExp apiLiteral = RegExp(r"'((?:/api/)[^']*)'");
  final Set<String> found = <String>{};
  for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    for (final RegExpMatch m in apiLiteral.allMatches(
      entity.readAsStringSync(),
    )) {
      found.add(_normalizePath(m.group(1)!));
    }
  }
  return found;
}

/// 把 Dart 插值（`$x` / `${...}`）与模板占位（`{x}`）统一成一个记号，
/// 使前端调用点与 ApiPaths 可逐条比对。
String _normalizePath(String path) {
  String s = path.replaceAll(RegExp(r'\$\{[^}]*\}'), '<X>');
  s = s.replaceAll(RegExp(r'\$[A-Za-z_][A-Za-z0-9_]*'), '<X>');
  s = s.replaceAll(RegExp(r'\{[^}]*\}'), '<X>');
  return s;
}
