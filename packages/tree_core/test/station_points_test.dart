// 点位表（`station_points.dart`）的自洽性测试。
//
// 点位是**数据**不是行为：加一个点位只该改那张表 + `StationHubIds` 一个常量。
// 这个文件因此把"表本身对不对"钉死——订阅寻址、命令路由、面板展示全都建立在它之上，
// 表错了会以很难查的方式扩散（例如某个点位没有别名、两条命令挂到同一个点位）。
//
// 运行方式（packages/tree_core）：
//   dart test test/station_points_test.dart
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  group('点位表自洽性', () {
    test('id 集合与 StationHubIds.all 完全一致（新增点位必须两边都加）', () {
      final Set<String> tableIds = StationPoints.all
          .map((StationPointSpec s) => s.id)
          .toSet();
      expect(tableIds, StationHubIds.all);
      expect(
        StationPoints.all.length,
        StationHubIds.all.length,
        reason: '表里不得有重复 id（重复会让 byId 只命中第一条）',
      );
    });

    test('类型分布：广播 10 / 执行 2 / 中转 12 / 收集 4', () {
      int count(StationKind kind) => StationPoints.ofKind(kind).length;
      expect(count(StationKind.broadcast), 10);
      expect(count(StationKind.execute), 2);
      expect(count(StationKind.relay), 12);
      expect(count(StationKind.collect), 4);
      expect(StationPoints.all.length, 28);
    });

    test('退役 id 不在表里（它们只用于读侧迁移与落盘对账）', () {
      for (final String retired in StationHubIds.retired) {
        expect(StationPoints.byId(retired), isNull, reason: retired);
        expect(StationHubIds.all, isNot(contains(retired)));
      }
      // #43 让出去的八个领域点位必须**逐个**钉在退役集合里：漏一个就会在下次
      // 有人「顺手加回一个内置执行站」时没人拦（表里加回去的话这条会先炸）。
      expect(StationHubIds.retiredExecutePoints, <String>[
        'system.execute.fs',
        'system.execute.terminal',
        'system.execute.agent',
        'system.execute.llm',
        'system.execute.tool',
        'system.execute.session',
        'system.execute.ssh',
        'system.execute.usage',
      ]);
    });

    test('说明与中文名都不为空（面板与日志直接展示它们）', () {
      for (final StationPointSpec spec in StationPoints.all) {
        expect(spec.label.trim(), isNotEmpty, reason: spec.id);
        expect(spec.description.trim(), isNotEmpty, reason: spec.id);
      }
    });

    test('同类型内别名唯一（别名是插件侧的稳定寻址入口）', () {
      for (final StationKind kind in StationKind.values) {
        final List<String> aliases = StationPoints.ofKind(kind)
            .map((StationPointSpec s) => s.alias)
            .where((String a) => a.isNotEmpty)
            .toList();
        expect(
          aliases.toSet().length,
          aliases.length,
          reason: '${kind.label} 的别名重复：$aliases',
        );
      }
    });

    test('点位名（去掉 system.<类型>. 前缀）在**类型内**唯一且非空', () {
      // 跨类型可以重名（中转站的 tool.pre 与广播站的 tool.pre 是两个点位）：
      // 寻址永远是「类型 + 点位」，所以唯一性只需在类型内成立。
      for (final StationKind kind in StationKind.values) {
        final List<String> suffixes = StationPoints.ofKind(kind)
            .map((StationPointSpec s) => s.suffix)
            .toList();
        expect(
          suffixes.where((String s) => s.trim().isEmpty),
          isEmpty,
          reason: kind.label,
        );
        expect(
          suffixes.toSet().length,
          suffixes.length,
          reason: '${kind.label} 的点位名重复：$suffixes',
        );
      }
      expect(
        StationPoints.byId(StationHubIds.relayLlmHandle)!.suffix,
        'llm.handle',
      );
      expect(StationPoints.byId(StationHubIds.executePlugin)!.suffix, 'plugin');
      // 经典点位（system.broadcast）没有点位后缀：返回 id 本身
      expect(
        StationPoints.byId(StationHubIds.broadcast)!.suffix,
        StationHubIds.broadcast,
      );
    });

    test('命令 → 点位：9 条平台面命令，每条恰好属于一个执行站点位', () {
      final Set<String> commands = StationPoints.allCommands;
      expect(commands.length, 9, reason: '$commands');
      expect(commands, <String>{
        // 插件族（20261015-hot-restart 阶段 1）
        'plugin.list',
        'plugin.restart',
        'plugin.suspend',
        'plugin.state',
        'plugin.toolCall',
        'plugin.stateDump',
        'plugin.stateFetch',
        // 站点族（20261015-hot-restart 阶段 6：只看不动的控制面）
        'station.list',
        'station.state',
      });
      for (final String command in commands) {
        final StationPointSpec? owner = StationPoints.ownerOfCommand(command);
        expect(owner, isNotNull, reason: command);
        expect(owner!.kind, StationKind.execute, reason: command);
        expect(owner.commands, contains(command));
        // 恰好一次：全表里只有这一个点位声明了它
        final int declared = StationPoints.all
            .where((StationPointSpec s) => s.commands.contains(command))
            .length;
        expect(declared, 1, reason: '$command 被 $declared 个点位声明');
      }
      expect(StationPoints.ownerOfCommand('not.a.command'), isNull);
      expect(StationPoints.ownerOfCommand(''), isNull);
      // 让出去的领域命令名**不在表里**（#43）：它们是插件自建执行站的命令，
      // 表里再出现就等于核心重新假装自己会执行（ownerOfCommand 会把命令抢走）。
      for (final String letGo in <String>[
        'fs.read',
        'terminal.exec',
        'agent.compact',
        'llm.call',
        'tool.call',
        'session.rename',
        'ssh.reconnect',
        'usage.query',
      ]) {
        expect(StationPoints.ownerOfCommand(letGo), isNull, reason: letGo);
      }
    });

    // 这条就是本该在 #43 之前就存在的门禁：**点位表是承诺，挂载位置是兑现**。
    // 只往表里加命令、核心那侧没有实现，命令就变成「路由得到、执行必失败」，
    // 而插件又被内置名拦截抢不到这个名字——两边都动不了，坏掉的是随包插件。
    test('门禁：表里每条命令都得被 ExecuteStationMounts 认下（有实现才许申报）', () {
      for (final String command in StationPoints.allCommands) {
        expect(
          ExecuteStationMounts.handles(command),
          isTrue,
          reason: '$command 在点位表里，但核心执行站挂载位置没有它的前缀实现',
        );
      }
      expect(ExecuteStationMounts.implementedPrefixes, <String>[
        'plugin.',
        'station.',
      ]);
    });

    test('只有执行站点位带命令（其它类型恒为空）', () {
      for (final StationPointSpec spec in StationPoints.all) {
        if (spec.kind == StationKind.execute) {
          expect(spec.commands, isNotEmpty, reason: spec.id);
        } else {
          expect(spec.commands, isEmpty, reason: spec.id);
        }
      }
    });

    test('订阅别名解析：类型 + 点位 / 完整 id / 后缀 / 留空', () {
      // 留空：中转站 = 工具前 + 工具后两点位（**不含 ssh.execute**：它需要显式订）
      expect(
        StationPoints.resolveAlias(kindWire: 'relay')
            .map((StationPointSpec s) => s.id),
        <String>[StationHubIds.relayToolPre, StationHubIds.relayToolPost],
      );
      expect(
        StationPoints.resolveAlias(kindWire: 'broadcast')
            .map((StationPointSpec s) => s.id),
        <String>[StationHubIds.broadcast],
      );
      // 别名 / 完整 id / 后缀三种写法都命中同一个点位
      for (final String key in <String>[
        'llm.handle',
        StationHubIds.relayLlmHandle,
        'llm.handle',
      ]) {
        expect(
          StationPoints.resolveAlias(
            kindWire: 'relay',
            point: key,
          ).map((StationPointSpec s) => s.id).toList(),
          <String>[StationHubIds.relayLlmHandle],
          reason: key,
        );
      }
      expect(
        StationPoints.resolveAlias(
          kindWire: 'broadcast',
          point: 'tool.post',
        ).map((StationPointSpec s) => s.id),
        <String>[StationHubIds.broadcastToolPost],
      );
      // ssh.execute：新「处理拓展点位」必须显式订才命中（别名 / 完整 id / 后缀三种写法）
      for (final String key in <String>[
        'ssh.execute',
        StationHubIds.relaySshExecute,
        'ssh.execute',
      ]) {
        expect(
          StationPoints.resolveAlias(
            kindWire: 'relay',
            point: key,
          ).map((StationPointSpec s) => s.id).toList(),
          <String>[StationHubIds.relaySshExecute],
          reason: key,
        );
      }
      // 留空解析绝不含 ssh.execute（老插件 `station: 'relay'` 不会误吞 SSH 执行）
      expect(
        StationPoints.resolveAlias(kindWire: 'relay')
            .map((StationPointSpec s) => s.id),
        isNot(contains(StationHubIds.relaySshExecute)),
      );
      // 执行站不可订阅 ⇒ 任何 point 都解析不出来
      expect(StationPoints.resolveAlias(kindWire: 'execute'), isEmpty);
      expect(
        StationPoints.resolveAlias(kindWire: 'execute', point: 'plugin'),
        isEmpty,
      );
      // 不存在的点位 / 类型
      expect(
        StationPoints.resolveAlias(kindWire: 'relay', point: 'nope'),
        isEmpty,
      );
      expect(
        StationPoints.resolveAlias(kindWire: 'bogus', point: 'tool.pre'),
        isEmpty,
      );
    });

    test('别名提示按类型列出（可读错误里用）', () {
      final String text = StationPoints.describeAliases(StationKind.relay);
      expect(text, contains('llm.handle'));
      expect(text, contains(StationHubIds.relayToolPre));
      expect(text, contains('ssh.execute'), reason: '新点位要出现在可读错误里');
    });
  });
}
