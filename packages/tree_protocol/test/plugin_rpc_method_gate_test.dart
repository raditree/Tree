import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// **插件 ↔ 核心协议面的门禁**（20261015-hot-restart D10 的"刹车"那一半）。
///
/// 为什么光有 [PluginRpcMethods] 不够：常量表本身**不阻止**后人再写一个字面量——
/// 真正阻止它的是"扫源码、未登记即失败"。这与 `protocol_completeness_test.dart`
/// 对 `'type':` 与 `/api/...` 做的事完全同构（那个门禁早就存在，只是从来没扫
/// 过 `method`，所以插件协议成了不变量 7 的漏网之鱼）。
///
/// 三条断言各自防的事故：
/// 1. **登记完整性**：任何被扫描处出现的 method 字面量都必须已登记（协议名或
///    登记表 + 原因）——防"顺手加个新方法名没人知道"；
/// 2. **核心侧不许写字面量**：`plugin_host.dart` / `plugin_bus.dart` 里
///    `'method': '<字面量>'` 的命中数必须为 0——这两处是协议的**生产端**，
///    在生产端保留字面量就等于给漂移留门；
/// 3. **增量必须受控**：相对基线只允许多出登记过的新方法（本任务 = 只有 `suspend`），
///    且核心侧上行分派的数量不变（那 6 个 `case` 一字不改，D10 的 A 侧代价为零）。
void main() {
  final Directory repoRoot = Directory('../..');

  /// 被扫描的源码面（协议**两端**都要扫，只扫核心等于没门）。
  final List<String> scanFaces = <String>[
    'packages/tree_core/lib/src/plugin',
    'packages/tree_ssh_plugin/lib',
    'examples/plugins',
  ];

  /// method 字面量的四种出现形态：下行帧的 `'method': 'x'`、JSON 双引号形态
  /// （Python 插件侧）、`_request('x', …)` / `_notify('x')` 这类位置实参、
  /// 以及上行分派里带斜杠的 `case 'x/y':`。
  final List<RegExp> patterns = <RegExp>[
    RegExp(r"'method':\s*'([^']+)'"),
    RegExp(r'"method":\s*"([^"]+)"'),
    RegExp(r"_(?:request|notify|call)\w*\(\s*'([^']+)'\s*,"),
    RegExp(r"case\s*'([A-Za-z0-9_.\-]*/[A-Za-z0-9_.\-]*)'\s*:"),
  ];

  Map<String, List<String>> scanMethodLiterals() {
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
        if (!path.endsWith('.dart') && !path.endsWith('.py')) continue;
        scannedFiles++;
        final String src = entity.readAsStringSync();
        for (final RegExp pattern in patterns) {
          for (final RegExpMatch match in pattern.allMatches(src)) {
            final String literal = match.group(1)!;
            // REST 路径与文件路径不是 method（它们以 / 开头），排除掉免得误报。
            if (literal.startsWith('/')) continue;
            final String relative = path.substring(repoRoot.path.length + 1);
            found.putIfAbsent(literal, () => <String>[]).add(relative);
          }
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

  test('源码里出现的插件协议 method 字面量全部已登记', () {
    final Map<String, List<String>> found = scanMethodLiterals();
    expect(found, isNotEmpty, reason: '未扫描到任何 method 字面量：正则失效');

    final Set<String> covered = <String>{
      ...PluginRpcMethods.all,
      ...nonProtocolPluginMethodLiterals.keys,
    };
    final Set<String> uncovered = found.keys.toSet().difference(covered);
    expect(
      uncovered,
      isEmpty,
      reason:
          '以下 method 字面量既不在 PluginRpcMethods，也没在 '
          'nonProtocolPluginMethodLiterals 登记：'
          '${uncovered.toList()..sort()}\n'
          '出现处：${uncovered.map((String k) => '$k → ${found[k]}').join('; ')}\n'
          '—— 扩协议请进 tree_protocol 的 PluginRpcMethods（并同步基线计数），'
          '属于别的协议（如 tree_tunnel_protocol）请登记并写明原因',
    );
  });

  test('核心侧（协议生产端）不再出现 method 字面量', () {
    // 这两份文件是核心 → 插件帧的唯一生产处；这里保留字面量就等于把漂移写在源头。
    for (final String file in <String>[
      'plugin_host.dart',
      'plugin_bus.dart',
    ]) {
      final File source = File(
        '${repoRoot.path}/packages/tree_core/lib/src/plugin/$file',
      );
      expect(source.existsSync(), isTrue, reason: '$file 不存在');
      final List<String> offenders = RegExp(
        r"'method':\s*'[A-Za-z0-9_./-]+'",
      ).allMatches(source.readAsStringSync()).map((RegExpMatch m) => m.group(0)!).toList();
      expect(
        offenders,
        isEmpty,
        reason: '$file 仍有裸 method 字面量：$offenders —— 请改成 PluginRpcMethods.*',
      );
    }
  });

  test('本任务相对基线只新增 1 个 method：suspend（D10）', () {
    expect(
      PluginRpcMethods.addedSinceBaseline(),
      <String>{PluginRpcMethods.suspend},
      reason: '转储与取回必须走已有 station/command，不得新增 method（D10 = A+B 混合）',
    );
    expect(
      PluginRpcMethods.all.length,
      PluginRpcMethods.baselineBeforeHotRestart.length + 1,
      reason: 'all 只应比基线多一个 suspend',
    );
  });

  test('核心侧上行分派的method数量钉住（6 个 case 一字不改）', () {
    expect(
      PluginRpcMethods.pluginToCoreRequests,
      hasLength(6),
      reason:
          '插件 → 核心的请求面基线是 6 条（command/register/unregister/subscribe/'
          'unsubscribe/trigger）；新能力要落在这张面上时，用 station/command 的'
          '命令名表达，别加第 7 个 method',
    );
    // 真源检查：核心侧的分派确实只认这 6 条（防止"常量表加了、分派没加"或反之）。
    final File bus = File(
      '${repoRoot.path}/packages/tree_core/lib/src/plugin/plugin_bus.dart',
    );
    final String src = bus.readAsStringSync();
    final int cases = RegExp(
      r'case\s+PluginRpcMethods\.[A-Za-z]+\s*:',
    ).allMatches(src).length;
    expect(
      cases,
      PluginRpcMethods.pluginToCoreRequests.length,
      reason: '_handlePluginRequest 的分派条数与登记面不一致：$cases',
    );
  });

  test('登记表每项都写了原因，且原因不能是空话', () {
    nonProtocolPluginMethodLiterals.forEach((String key, String why) {
      expect(key, isNotEmpty);
      expect(
        why.trim().length,
        greaterThan(1),
        reason: '$key 的登记原因太空：登记必须写明"它属于哪个协议"',
      );
    });
  });

  test('三个方向集合不得重叠（all = 三者之和）', () {
    // 重叠会让 const 集合“静默吃掉”一个名字（两个方向共用一个条目），
    // 于是“方法属于哪一面”这个信息就丢了。`event` 的双向同名已在常量表里
    // **有意只列一次**，所以这里允许它只在 coreToPlugin 里出现。
    expect(
      PluginRpcMethods.all.length,
      PluginRpcMethods.coreToPlugin.length +
          PluginRpcMethods.pluginToCoreRequests.length +
          PluginRpcMethods.pluginToCoreNotifications.length,
      reason: '方向集合存在重叠：新加方法时请确认它只属于一面',
    );
    expect(
      PluginRpcMethods.coreToPlugin
          .intersection(PluginRpcMethods.pluginToCoreRequests),
      isEmpty,
    );
  });
}
