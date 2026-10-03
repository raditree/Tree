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

    test('类型分布：广播 4 / 执行 7 / 中转 6 / 收集 1', () {
      int count(StationKind kind) =>
          StationPoints.ofKind(kind).length;
      expect(count(StationKind.broadcast), 4);
      expect(count(StationKind.execute), 7);
      expect(count(StationKind.relay), 6);
      expect(count(StationKind.collect), 1);
      expect(StationPoints.all.length, 18);
    });

    test('退役 id 不在表里（它们只用于读侧迁移）', () {
      for (final String retired in StationHubIds.retired) {
        expect(StationPoints.byId(retired), isNull, reason: retired);
        expect(StationHubIds.all, isNot(contains(retired)));
      }
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
      expect(StationPoints.byId(StationHubIds.relayLlmHandle)!.suffix, 'llm.handle');
      expect(StationPoints.byId(StationHubIds.executeFs)!.suffix, 'fs');
      // 经典点位（system.broadcast）没有点位后缀：返回 id 本身
      expect(StationPoints.byId(StationHubIds.broadcast)!.suffix, StationHubIds.broadcast);
    });

    test('命令 → 点位：13 条命令，每条恰好属于一个执行站点位', () {
      final Set<String> commands = StationPoints.allCommands;
      expect(commands.length, 13, reason: '$commands');
      expect(
        commands,
        <String>{
          'fs.read',
          'fs.write',
          'fs.list',
          'fs.grep',
          'terminal.exec',
          'agent.message',
          'agent.stop',
          'agent.compact',
          'ui.push',
          'llm.call',
          'tool.call',
          'tool.close',
          'session.rename',
        },
      );
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
      // 留空：中转站 = 工具前 + 工具后两点位；广播站 = 通用主题
      expect(
        StationPoints.resolveAlias(kindWire: 'relay').map((StationPointSpec s) => s.id),
        <String>[StationHubIds.relayToolPre, StationHubIds.relayToolPost],
      );
      expect(
        StationPoints.resolveAlias(kindWire: 'broadcast').map((StationPointSpec s) => s.id),
        <String>[StationHubIds.broadcast],
      );
      // 别名 / 完整 id / 后缀三种写法都命中同一个点位
      for (final String key in <String>[
        'llm.handle',
        StationHubIds.relayLlmHandle,
        'llm.handle',
      ]) {
        expect(
          StationPoints.resolveAlias(kindWire: 'relay', point: key)
              .map((StationPointSpec s) => s.id)
              .toList(),
          <String>[StationHubIds.relayLlmHandle],
          reason: key,
        );
      }
      expect(
        StationPoints.resolveAlias(kindWire: 'broadcast', point: 'tool.post')
            .map((StationPointSpec s) => s.id),
        <String>[StationHubIds.broadcastToolPost],
      );
      // 执行站不可订阅 ⇒ 任何 point 都解析不出来
      expect(StationPoints.resolveAlias(kindWire: 'execute'), isEmpty);
      expect(
        StationPoints.resolveAlias(kindWire: 'execute', point: 'fs'),
        isEmpty,
      );
      // 不存在的点位 / 类型
      expect(StationPoints.resolveAlias(kindWire: 'relay', point: 'nope'), isEmpty);
      expect(StationPoints.resolveAlias(kindWire: 'bogus', point: 'tool.pre'), isEmpty);
    });

    test('别名提示按类型列出（可读错误里用）', () {
      final String text = StationPoints.describeAliases(StationKind.relay);
      expect(text, contains('llm.handle'));
      expect(text, contains(StationHubIds.relayToolPre));
    });
  });
}
