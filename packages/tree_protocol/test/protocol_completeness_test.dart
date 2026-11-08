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

/// **尚未接线**的上行帧登记表。片 B 已把 6 条站点帧全部接到核心，故为空；
/// 这里必须与核心实际未处理的帧集合**逐一相等**：核心接线一条就删一条，
/// 否则「新增帧不得被 default 静默忽略」这条门禁会失真（与
/// `CoreServer.stubApiPaths` 的「空集合不许悄悄长回来」同口径）。
const Map<String, String> pendingCoreInbound = <String, String>{};

void main() {
  final Directory repoRoot = Directory('../..');
  final Directory uiRoot = _uiSourceRoot(repoRoot);
  final String uiRel = _relativeTo(repoRoot, uiRoot.path);

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
    // 常量名 = 值名的 camelCase（register_local_executor → registerLocalExecutor）
    final Set<String> unhandled = <String>{
      for (final String value in WsInboundType.all)
        if (!src.contains('WsInboundType.${_camel(value)}')) value,
    };
    expect(
      unhandled,
      pendingCoreInbound.keys.toSet(),
      reason:
          '核心未显式处理的上行帧必须与 pendingCoreInbound 逐一相等：'
          '实际未处理 ${unhandled.toList()..sort()}；'
          '登记为待接线 ${pendingCoreInbound.keys.toList()..sort()} —— '
          '接线后请从 pendingCoreInbound 删除该条（前端会发这些帧，'
          '静默忽略会造成"点了没反应"）',
    );
  });

  test('片 A 待接线帧的登记都写明了原因', () {
    pendingCoreInbound.forEach((String frame, String why) {
      expect(WsInboundType.all, contains(frame));
      expect(why.trim().length, greaterThan(1), reason: '$frame 的登记原因太空');
    });
  });

  test('前端使用的 /api 路径全部在 ApiPaths 中声明', () {
    final Map<String, Set<String>> used = _scanFrontendApiPaths(uiRoot);
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

  test('插件化新增路径已在 kept 内，且 /bootstrap 不属 /api 前缀', () {
    expect(
      ApiPaths.kept,
      containsAll(<String>[
        ApiPaths.meta,
        ApiPaths.bootstrap,
        ApiPaths.bootstrapSession,
      ]),
      reason: '发现面 / 引导壳是核心永久面，必须进契约全集',
    );
    expect(
      ApiPaths.bootstrap.startsWith('/api/'),
      isFalse,
      reason: '/bootstrap 是核心自有页面入口，不是 /api 命名空间',
    );
  });

  test('前端已不再引用账号体系路径（M1b 删除登录与账号设置）', () {
    final Map<String, Set<String>> used = _scanFrontendApiPaths(uiRoot);
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
      uiRel,
      'packages/tree_core/lib',
      'packages/tree_local_exec/lib',
      'packages/tree_core_cli/bin',
    ]) {
      final Directory dir = Directory('${repoRoot.path}/$tree');
      if (!dir.existsSync()) continue;
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // UI 自持契约（零依赖 D2）本身就是这些常量的定义处，不是"重复定义"；
        // 它和核心的漂移由黑盒一致性套件 + `/api/meta.ui_contract` 兜住。
        if (_isUiContract(entity.path)) continue;
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

  test('流式序号字段只能来自协议包（不得硬编码 seq 字面量）', () {
    // 流式增量帧的 seq 是 [WsStreamSeq] 管的跨端契约：核心产出、前端判重，两侧必须
    // 用同一个字段名与同一套"缺字段 = 未知"口径。任一侧改成别的写法（'seq' /
    // 'sequence' / 直接索引），去重会**静默失效**（退回 id 级判据、重复渲染正文），
    // 所以这里按文件登记"非流式帧的 seq 用法"，其余一律必须走 WsStreamSeq。
    final Map<String, String> registered = <String, String>{
      '$uiRel/io/websocket_service.dart': '大帧分片 frame_chunk 的分片序号（传输层）',
      '$uiRel/io/protocol_contract.dart':
          'UI 自持契约：WsStreamSeq.field 的 `seq` 字面量在这里定义（零依赖 D2）',
      'packages/tree_core/lib/src/ws/ws_hub.dart':
          '大帧分片 frame_chunk 的分片序号（传输层）',
      'packages/tree_core/lib/src/ws/inbound_frames.dart': '核心侧重组成大帧时读分片序号',
      'packages/tree_core/lib/src/plugin/station_instance.dart':
          '广播站公告板条目的单调序号（站点协议域，非流式帧）',
    };
    final RegExp literal = RegExp(r'''['"]seq['"]''');
    final List<String> offenders = <String>[];
    for (final String tree in <String>[uiRel, 'packages/tree_core/lib']) {
      final Directory dir = Directory('${repoRoot.path}/$tree');
      if (!dir.existsSync()) continue;
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (!literal.hasMatch(entity.readAsStringSync())) continue;
        final String relative = _relativeTo(repoRoot, entity.path);
        if (registered.containsKey(relative)) continue;
        offenders.add(relative);
      }
    }
    expect(
      offenders..sort(),
      isEmpty,
      reason:
          '以下文件硬编码了 seq 字面量：$offenders —— 流式帧请改用 '
          'WsStreamSeq.field / WsStreamSeq.of()；确属别的协议域（分帧 / 站点等）'
          '请在 registered 里登记并写明原因',
    );
  });

  test('委派契约：coreOwned 35 / delegated 55 / pendingHandoffRoutes 0', () {
    expect(ApiPaths.coreOwned.length, 35, reason: '核心永久面 35 条（平台 20 + 传输设置 11 + 引导壳 3 + 发现面 1）');
    expect(ApiPaths.delegated.length, 55, reason: '插件面 55 条（git 3 已删除；消息详情端点 +1）');
    expect(ApiPaths.pendingHandoffRoutes, isEmpty, reason: 'A5 已清空迁移债台账');
    expect(ApiPaths.contractRoutes.length, 90);
    expect(ApiPaths.kept.length, 70, reason: 'git 3 已删；UI 多窗口 +2；终端 REST +2；本地安装 +1；消息详情 +1；发布源设置 +2；store/logs/data-collection 8 条方法路由（5 条路径）已删');
    expect(ApiPaths.contractRoutes.length, ApiPaths.coreOwned.length + ApiPaths.delegated.length);
    expect(ApiPaths.coreOwned.intersection(ApiPaths.delegated), isEmpty);
    expect(ApiPaths.pendingHandoffRoutes.difference(ApiPaths.delegated), isEmpty);

    final RegExp keyShape = RegExp(r'^(GET|POST|PUT|PATCH|DELETE) /');
    for (final String route in ApiPaths.contractRoutes) {
      expect(keyShape.hasMatch(route), isTrue, reason: '契约键格式非法：$route');
      final String pattern = route.substring(route.indexOf(' ') + 1);
      expect(
        ApiPaths.kept,
        contains(pattern),
        reason: '$route 的路径不在 ApiPaths.kept 内（前端可调用面必须可声明）',
      );
    }
    expect(ApiPaths.routeKey('get', '/api/x'), 'GET /api/x');
  });

  test('委派命名空间规则：/api/ 前缀、保留前缀、段形状（L-28）', () {
    for (final String ok in <String>[
      '/api/tree.agent/hello',
      '/api/files/{workspaceId}/syncToLocal',
      '/api/agents/{agentId}/messages',
      '/api/sample/pdf_info',
      '/api/x',
    ]) {
      expect(
        ApiPaths.delegationPatternError(ok),
        isNull,
        reason: '$ok 应允许插件申报（L-28 去静态白名单）',
      );
    }
    for (final String bad in <String>[
      '/bootstrap',
      '/api',
      '/api/',
      '/api/plugin/snapshot',
      '/api/bootstrap/session',
      '/api/meta',
      '/api/logs/sources',
      '/api/store/ns',
      '/api/x/',
      '/api//x',
      '/api/x y',
      '/api/{bad-name}',
      '/api/中文',
    ]) {
      expect(
        ApiPaths.delegationPatternError(bad),
        isNotNull,
        reason: '$bad 应被命名空间规则拒收并给出可读原因',
      );
    }
    expect(
      ApiPaths.delegationKeyError('GET', ApiPaths.settingsFrameRate),
      contains('核心永久面'),
      reason: '与 coreOwned 同键必须拒收',
    );
    expect(
      ApiPaths.delegationKeyError('GET', ApiPaths.meta),
      contains('核心保留面'),
      reason: '保留前缀先于同键检查，同样必须拒收',
    );
    expect(
      ApiPaths.delegationKeyError('GET', '/api/tree.agent/state'),
      isNull,
      reason: '非核心路径可申报',
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

/// UI 源码根。迁移前住在桌面仓根 `lib/`，迁移后在插件仓
/// `plugins/tree.ui.default/lib/`（见 docs/pluginization/ui-source-migration-recon.md D7）。
///
/// 新路径存在就优先新路径（S2 起源码只在插件仓那份可改）；两处都没有就**直接失败**，
/// 不允许像旧写法那样静默跳过——「门禁变绿但没扫到界面」是最坏的失败方式。
/// **S3 删源时删掉回落分支，只留新路径。**
Directory _uiSourceRoot(Directory repoRoot) {
  final Directory migrated =
      Directory('${repoRoot.path}/plugins/tree.ui.default/lib');
  final Directory legacy = Directory('${repoRoot.path}/lib');
  final Directory root = migrated.existsSync() ? migrated : legacy;
  if (!root.existsSync()) {
    fail(
      'UI 源码目录不存在（找过 ${migrated.path}、${legacy.path}）：'
      '迁移没搬完或路径漂了——门禁不许静默降级',
    );
  }
  return root;
}

/// UI 自持契约文件（零依赖 D2）。它就是协议常量的**定义处**（手抄子集），
/// 因此不参与「前后端都不得重复定义」那两条扫描；漂移由黑盒套件兜住。
bool _isUiContract(String path) =>
    path.replaceAll('\\', '/').endsWith('/io/protocol_contract.dart');

/// 扫描本仓库源码（前端 + 各包）里的 `'type': 'x'` 字面量。
Set<String> _scanTypeLiterals(Directory repoRoot) {
  final String uiRel = _relativeTo(repoRoot, _uiSourceRoot(repoRoot).path);
  final RegExp literal = RegExp(r"'type'\s*:\s*'([a-z_][a-z0-9_]*)'");
  final Set<String> found = <String>{};
  for (final String tree in <String>[
    uiRel,
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

/// 相对仓库根、统一用 `/` 分隔的路径（登记表用；Windows 上 listSync 给的是 `\`）。
String _relativeTo(Directory repoRoot, String path) {
  String relative = path.replaceFirst(repoRoot.path, '').replaceAll('\\', '/');
  while (relative.startsWith('/')) {
    relative = relative.substring(1);
  }
  return relative;
}

/// `register_local_executor` → `registerLocalExecutor`；`ui.hello` → `uiHello`；
/// `station/subscribe` → `stationSubscribe`（分隔符不只下划线）。
String _camel(String raw) {
  final List<String> parts = raw.split(RegExp(r'[_.\/-]+'));
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
