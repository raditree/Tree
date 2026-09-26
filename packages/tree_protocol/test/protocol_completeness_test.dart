import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 协议冻结的**完备性门禁**：迁移期以 server 源码与前端调用点为基准，
/// 确保没有"server 发了但核心不认识"或"前端调了但未声明"的漂移。
///
/// M7 删除 server/ 后，第一组测试改用前端事件断言替代。
void main() {
  final Directory repoRoot = Directory('../..');

  test('server 侧 type 字面量（下行帧 + 上行分发）全部被协议常量覆盖', () {
    final Set<String> scanned = _scanServerLiterals(repoRoot);
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
          '以下 server 侧 type 字面量未纳入协议常量：'
          '${uncovered.toList()..sort()} —— 请补充常量，'
          '或在 nonProtocolTypeLiterals 中登记并写明原因',
    );
  });

  test('分帧三件套与 server 的 _FRAME_* 常量一致', () {
    final File src = File('${repoRoot.path}/server/ws/ws_manager.py');
    expect(src.existsSync(), isTrue, reason: 'ws_manager.py 不存在：${src.path}');

    final RegExp frameConst = RegExp(r'_FRAME_[A-Z_]+\s*=\s*"([a-z_]+)"');
    final Set<String> serverFrames = frameConst
        .allMatches(src.readAsStringSync())
        .map((RegExpMatch m) => m.group(1)!)
        .toSet();
    expect(serverFrames, isNotEmpty, reason: '未在 ws_manager.py 找到 _FRAME_* 常量');
    expect(serverFrames, WsOutboundType.frameChunking);
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
      reason:
          '以下前端路径未在 ApiPaths 中声明：'
          '${undeclared.toList()..sort()}',
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

  test('前端不再重复定义分帧常量（必须引用协议包）', () {
    final Directory lib = Directory('${repoRoot.path}/lib');
    // 只匹配"定义"（const <类型> kWsFrame...），不匹配引用
    final RegExp redefinition = RegExp(
      r'^\s*const\s+(?:int|Duration|String)\s+kWsFrame',
      multiLine: true,
    );
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (redefinition.hasMatch(entity.readAsStringSync())) {
        offenders.add(entity.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '分帧阈值/分片预算/TTL 与三件套类型名必须来自 tree_protocol，'
          '否则核心与前端阈值会再次漂移：$offenders',
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

/// 扫描 server 源码：`"type": "x"`（下行帧/噪声）与 `msg_type == "x"`（上行分发）。
Set<String> _scanServerLiterals(Directory repoRoot) {
  final Directory server = Directory('${repoRoot.path}/server');
  if (!server.existsSync()) {
    fail('server 目录不存在：${server.path}');
  }
  final RegExp typeLiteral = RegExp(r'"type"\s*:\s*"([a-z_][a-z0-9_]*)"');
  final RegExp dispatchLiteral = RegExp(
    r'msg_type\s*==\s*"([a-z_][a-z0-9_]*)"',
  );
  final Set<String> found = <String>{};

  for (final FileSystemEntity entity in server.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.py')) continue;
    final String p = entity.path.replaceAll('\\', '/');
    if (p.contains('__pycache__') ||
        p.contains('.venv') ||
        p.contains('/tests/')) {
      continue;
    }
    final String src = entity.readAsStringSync();
    for (final RegExp re in <RegExp>[typeLiteral, dispatchLiteral]) {
      for (final RegExpMatch m in re.allMatches(src)) {
        found.add(m.group(1)!);
      }
    }
  }
  return found;
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
