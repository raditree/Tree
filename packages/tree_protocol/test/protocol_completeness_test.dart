import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 协议冻结的**完备性门禁**。
///
/// M7 删除 `server/` 后，原先"扫 Python 源码"的两条门禁换成**本仓库内**的等价断言：
/// 1. 前端/核心源码里出现的 `'type': 'x'` 字面量，要么是协议帧，要么在
///    [nonProtocolTypeLiterals] 登记并写明原因（否则协议无声漂移）；
/// 2. 核心必须**逐一处理**每一种上行帧常量（新增帧不能被 default 静默吞掉）；
/// 3. 前端调用点的 `/api/...` 路径必须都能在 [ApiPaths] 中找到声明（含用
///    `$query` 拼接查询串、`Uri.parse('$baseUrl/api/...')` 这类隐式写法）。
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
    final Map<String, Set<String>> used = _scanFrontendApiPaths(
      Directory('${repoRoot.path}/lib'),
    );
    expect(used, isNotEmpty, reason: '未扫描到任何 /api 路径字符串');

    final Set<String> declared = ApiPaths.all.map(_normalizePath).toSet();
    final List<String> undeclared = <String>[];
    used.forEach((String literal, Set<String> forms) {
      // 一个调用点可能同时给出"带查询串插值"与"只到路径"两种形态；
      // 只要其中一种命中声明即可（例如 `.../download$query`）。
      if (forms.any(declared.contains)) return;
      undeclared.add('$literal → ${forms.toList()..sort()}');
    });
    expect(
      undeclared..sort(),
      isEmpty,
      reason: '以下前端路径未在 ApiPaths 中声明：$undeclared',
    );
  });

  test('前端已不再引用账号体系路径（M1b 删除登录与账号设置）', () {
    final Map<String, Set<String>> used = _scanFrontendApiPaths(
      Directory('${repoRoot.path}/lib'),
    );
    final Set<String> accountPaths = <String>{
      for (final MapEntry<String, Set<String>> entry in used.entries)
        if (entry.key.contains('/api/auth')) ...entry.value,
    };
    expect(
      accountPaths,
      isEmpty,
      reason: 'desktop 分支已取消账号体系，前端不应再出现这些调用：$accountPaths',
    );
  });

  test('分帧常量只能来自协议包：前后端都不得重复定义或硬编码字面量', () {
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
    expect(WsInboundType.all.intersection(WsOutboundType.all), <String>{
      WsInboundType.heartbeat,
    }, reason: '上/下行除 heartbeat（双向保活）外不应重名');
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

/// 扫描前端 Dart 源码中的 `/api/...` 调用点。
///
/// 返回 字面量 → 归一化候选集合：
/// - 匹配"字符串字面量里出现 /api/"，而不是"以 /api/ 开头"——形如
///   `Uri.parse('$baseUrl/api/files/x/download')` 的调用点也必须被覆盖；
/// - 直接拼在字面量里的 `?query` 只取路径部分；
/// - 用 `$query` 拼接的写法会归一化成尾随 `<X>`，额外给出「去掉尾随 `<X>`」的形态，
///   由调用方判定其中任一命中声明即可。
Map<String, Set<String>> _scanFrontendApiPaths(Directory lib) {
  if (!lib.existsSync()) fail('lib 目录不存在：${lib.path}');
  final RegExp apiLiteral = RegExp(r"'([^']*/api/[^']*)'");
  final Map<String, Set<String>> found = <String, Set<String>>{};
  for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    for (final RegExpMatch m in apiLiteral.allMatches(
      entity.readAsStringSync(),
    )) {
      final String raw = m.group(1)!;
      final int index = raw.indexOf('/api/');
      if (index < 0) continue;
      String candidate = raw.substring(index);
      // 只认"像路径"的字面量：不含空格/反引号/星号，避免把文档注释里的散文
      // （例如 `/api/...` 的说明文字）误判成前端调用点。
      if (!RegExp(r'^/api/[A-Za-z0-9_{}$/.-]*$').hasMatch(candidate)) {
        continue;
      }
      final int query = candidate.indexOf('?');
      if (query >= 0) candidate = candidate.substring(0, query);
      final Set<String> forms = found.putIfAbsent(candidate, () => <String>{});
      final String normalized = _normalizePath(candidate);
      forms.add(normalized);
      if (normalized.endsWith('<X>')) {
        forms.add(normalized.substring(0, normalized.length - 3));
      }
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
