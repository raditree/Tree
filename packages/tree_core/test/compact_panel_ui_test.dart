import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// **compact 插件的左栏面板：核心侧契约**（真 Python 插件 + 真插件总线）。
///
/// 为什么单独钉这一条：面板是"受限控件集的 JSON"，而核心对它的校验**全是静默的**——
/// 槽位超过 16 条、单个视图超过 64 KB、槽位类型写错、视图解析失败，一律只在核心日志里
/// 留一句可读原因（**插件侧看不到任何报错**），界面上表现为"左栏里没有这一页"。
/// 这里的断言就是那几条上限的正面口径：**插件真实声明的那一帧必须被桥放行**，
/// 且形状可解析、控件全在受限集内。
///
/// 覆盖：
/// 1. `ui/manifest` 只声明 **1 条 `activity` 槽位**（= 活动栏图标 + 左栏整页）：
///    slot_key 稳定、标题/图标非空（图标必须是前端白名单里的名字）；
/// 2. 视图能解析成**受限控件集**（无 webview / 无未知控件），里面有「立即压缩一次」
///    按钮（`compact_now`）与"最近 N 次"表格，并带得出空态文案；
/// 3. 同一份视图走 `ui/update`（整块替换）同样过桥、无拒绝原因，且声明体积远低于 64 KB。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_compact_panel_');
  });

  tearDown(() async {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        // Windows 上文件句柄可能还没释放，稍后重试
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  /// 真插件脚本（测试 cwd = packages/tree_core ⇒ 上两级才是仓根）。
  String compactScript() => p.normalize(
    p.join(
      Directory.current.path,
      '..',
      '..',
      'examples',
      'plugins',
      'compact_plugin.py',
    ),
  );

  String slash(String path) => path.replaceAll(Platform.pathSeparator, '/');

  bool pythonAvailable() {
    final String command = Platform.isWindows ? 'python' : 'python3';
    try {
      return Process.runSync(command, <String>['--version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 深度遍历视图（含容器 children），按顺序收集所有节点。
  List<PluginUiNode> walk(PluginUiView view) {
    final List<PluginUiNode> out = <PluginUiNode>[];
    void visit(PluginUiNode node) {
      out.add(node);
      for (final PluginUiNode child in node.children) {
        visit(child);
      }
    }

    for (final PluginUiNode node in view.nodes) {
      visit(node);
    }
    return out;
  }

  test('真插件声明一条 activity 槽位：过桥 + 受限控件集 + 按钮形状', () async {
    final String script = compactScript();
    if (!File(script).existsSync() || !pythonAvailable()) {
      markTestSkipped('没有 python 或示例插件不在预期路径：$script');
      return;
    }

    final File config = File(p.join(temp.path, 'config', 'plugins.yaml'));
    config.createSync(recursive: true);
    // `scope: {}` = 内置插件在界面上开关后的默认形态（空 = 作用于所有 team）：
    // 那一形态下面板就该出现，不需要用户先改配置。
    config.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: compact\n'
      '    name: 上下文压缩\n'
      '    command: "${Platform.isWindows ? 'python' : 'python3'}"\n'
      '    args: ["${slash(script)}"]\n'
      '    granularity: team\n'
      '    scope: {}\n',
    );
    final List<String> coreLogs = <String>[];
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
    final PluginBus bus = PluginBus(
      configFile: config.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      log: coreLogs.add,
      broadcast: frames.add,
    );
    addTearDown(bus.close);
    await bus.start();

    // 等插件启动 + 握手 + 申报（真进程，最多 20s）
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (frames.any(
        (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.manifest,
      )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final Map<String, dynamic>? manifestFrame = frames
        .where(
          (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.manifest,
        )
        .firstOrNull;
    expect(
      manifestFrame,
      isNotNull,
      reason:
          '插件的 ui/manifest 必须被桥放行（被拒时核心只记日志：$coreLogs）；'
          '插件 stderr：'
          '${bus.instances().map((({String pluginId, PluginHost host}) i) => '${i.pluginId}: ${i.host.stderrTail}').join(' /// ')}',
    );

    final PluginUiManifest manifest = PluginUiManifest.fromFrame(
      manifestFrame!,
    )!;
    expect(manifest.pluginId, 'compact');
    expect(
      manifest.teamId,
      isEmpty,
      reason: 'scope: {} ⇒ 帧级 team 为空 = 前端在任何 team 下都呈现',
    );
    expect(
      manifest.slots,
      hasLength(1),
      reason: '只声明一条槽位：左栏面板（activity 槽位 = 活动栏图标 + 左栏整页）',
    );

    final PluginUiSlot slot = manifest.slots.single;
    expect(slot.kind, PluginUiSlotKind.activity);
    expect(slot.slotKey, 'compact.activity.1');
    expect(slot.title, isNotEmpty);
    expect(
      slot.icon,
      'chart',
      reason: '图标必须是前端白名单里的名字（lib/ui/widgets/plugin_ui_slots.dart），'
          '否则回退成扩展图标——白名单在 lib/ 里，核心侧测试引用不到，所以钉字面量',
    );

    // ① 视图：能解析成受限控件集，没有任何未知控件
    final List<PluginUiNode> nodes = walk(slot.view);
    expect(nodes, isNotEmpty, reason: '面板必须有内容（空视图等于没声明）');
    expect(
      nodes.map((PluginUiNode n) => n.type).toSet(),
      everyElement(isIn(PluginUiViewType.all)),
      reason: '受限控件集：未知类型前端只渲染「不支持的控件」占位（等于坏了）',
    );
    expect(
      slot.view.nodes.single.type,
      PluginUiViewType.column,
      reason: '顶层是 column 容器（一页内容）',
    );

    // ② 动作按钮：面板的"立即压缩一次"必须是一个真按钮（action_id 是回传的判据）
    final Iterable<PluginUiNode> actions = nodes.where(
      (PluginUiNode n) => n.type == PluginUiViewType.actions,
    );
    final List<String> actionIds = <String>[
      for (final PluginUiNode node in actions)
        for (final Object? button in node.listOrEmpty('buttons'))
          if (button is Map) (button['action_id'] ?? '').toString(),
    ];
    expect(
      actionIds,
      contains('compact_now'),
      reason: '「立即压缩一次」按钮（核心侧走执行站 agent.compact）',
    );
    expect(
      actionIds,
      contains('refresh'),
      reason: '刷新按钮：插件只推 ui/update，也便于用户手动拉一次',
    );

    // ③ 最近 N 次的表格：列名固定（来源 / 覆盖条数 / 耗时 / 原因都要有落点）
    final Iterable<PluginUiNode> tables = nodes.where(
      (PluginUiNode n) => n.type == PluginUiViewType.table,
    );
    expect(tables, isNotEmpty, reason: '最近 N 次压缩要有个表格兜住');
    final List<Object?> columns = tables.first.listOrEmpty('columns');
    expect(columns.length, 5);
    expect(columns.map((Object? c) => c.toString()), <String>[
      '时间',
      '来源',
      '覆盖条数',
      '耗时',
      '降级 / 未接管原因',
    ]);
    // 空态：没记录时也要说清"怎么办"，而不是一张空表
    expect(
      nodes.map((PluginUiNode n) => n.str('text')).join('|'),
      contains('立即压缩一次'),
      reason: '空态文案要指路（点按钮 / 等自动压缩）',
    );

    // ④ 体积：声明体远低于核心 64 KB 上限（超限 = 整帧被拒，面板永远不出现）
    final int bytes = utf8.encode(jsonEncode(slot.toJson())).length;
    expect(
      bytes,
      lessThan(64 * 1024),
      reason: 'PluginUiBridge.defaultMaxViewBytes = 64 KB，超了整帧被拒',
    );

    // ⑤ `ui/update` 走同一个视图：整块替换也要过桥，且没有可读拒绝原因
    final List<String> rejected = <String>[];
    final Map<String, dynamic>? updateFrame = PluginUiBridge().frameFor(
      pluginId: 'compact',
      declaredTeamId: '',
      method: PluginUiBridge.methodUpdate,
      params: <String, dynamic>{
        'slot_key': slot.slotKey,
        'view': slot.view.toJson(),
      },
      onRejected: rejected.add,
    );
    expect(rejected, isEmpty, reason: '面板视图不该触发任何拒绝：$rejected');
    expect(updateFrame, isNotNull);
    expect(updateFrame!['type'], PluginUiFrameType.update);
    expect(
      (updateFrame['data'] as Map<String, dynamic>)['slot_key'],
      'compact.activity.1',
      reason: 'ui/update 按 slot_key 定位：写错就是"推了但看不到"',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));
}
