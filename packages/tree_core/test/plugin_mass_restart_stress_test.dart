// 稳定性与压力（20261015-hot-restart 阶段 6，D6e）：**50 路并发**下的形状。
//
// 分两层，刻意放在一起（同一件事的两个侧面）：
// 1. **内存层（默认闸门就跑）**：快照池 / 重启暂存队列 / 站点在途等待这三处
//    「超限就拒」的结构，在 50 路并发下必须**有界、可数、失败可读**。这三处是热重启
//    风暴里真正会被堆满的地方——判活取消了时长硬上限（D8），所以并发形状**只能**靠
//    数量上界守住，没有别的东西守着。
// 2. **真链路（默认跳过）**：50 个真插件进程同时 hotRestart。放不进常规闸门的原因是
//    诚实的：一层就要 50 个 Dart VM（重启窗口里新旧两世并存 ⇒ 峰值翻倍），跑一次会把
//    机器压得很难看，而它验证的仍是第 1 层那三处结构的**接线**。开法（PowerShell）：
//    `$env:TREE_MASS_STRESS='1'; dart test test/plugin_mass_restart_stress_test.dart`
//    （`dart test` 的 CLI 没开 `--dart-define`，所以闸门读的是环境变量）
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/plugin_restart_buffer.dart';
import 'package:tree_core/src/plugin/plugin_state_pool.dart';
import 'package:tree_core/tree_core.dart';

/// 真链路那一层的开关：**默认不开**（理由见文件头）。环境变量而不是编译常量，
/// 因为 `dart test` 不提供 `--dart-define`。
final bool _massStress =
    (Platform.environment['TREE_MASS_STRESS'] ?? '') == '1';

void main() {
  const int n = 50;

  /// 真链路那一层的并发规模：**默认跟闸门一样是 50**，验收时顶到要求的量级。
  ///
  /// 要钉的那句话是「**100+ keep 类插件同时热重启时核心进程不崩**」：常规闸门不该
  /// 跑 100 个 Dart VM（峰值两世并存⇒ 翻倍），但那个数必须随时能跑。
  /// 开法（PowerShell）：`$env:TREE_MASS_STRESS='1'; $env:TREE_MASS_STRESS_N='100'`。
  final int massN =
      int.tryParse(Platform.environment['TREE_MASS_STRESS_N'] ?? '') ?? n;

  StationRequest request(int seq, String team) => StationRequest(
    requestId: 'req-$seq',
    stationId: StationHubIds.relayLlmHandle,
    kind: StationKind.relay,
    scope: StationScope(teamId: team, modeKey: StationModeKey.local),
    payload: <String, dynamic>{'seq': seq},
  );

  group('内存层：50 路并发下三处有界结构都不越界、都不静默', () {
    test('快照池：50 路并发 put 全部收敛在上限内，越界的部分按 LRU 丢最旧并计数', () async {
      final PluginStatePool pool = PluginStatePool(
        maxEntryBytes: 4 << 10,
        maxTotalBytes: 20 << 10,
        maxEntries: 16,
      );
      final List<String> dumpIds = <String>[];
      await Future.wait<void>(<Future<void>>[
        for (int i = 0; i < n; i++)
          Future<void>(() {
            final PluginStatePutResult put = pool.put(
              pluginId: 'p$i',
              generation: 1,
              // 每条 ~200 字节：50 条远超总上限 20 KiB ⇒ 必然触发按字节淘汰
              payload: <String, dynamic>{'i': i, 'blob': 'x' * 200},
              scope: StationScope(
                teamId: 'team-$i',
                modeKey: StationModeKey.local,
              ),
            );
            expect(put.accepted, isTrue, reason: put.error);
            dumpIds.add(put.dumpId!);
          }),
      ]);

      expect(dumpIds, hasLength(n), reason: '50 次都写成功了（淘汰是事后收，不是当场拒）');
      expect(pool.length, lessThanOrEqualTo(16), reason: '条目数绝不越上限');
      expect(pool.totalBytes, lessThanOrEqualTo(20 << 10), reason: '字节数绝不越上限');
      expect(pool.putCount, n);
      expect(
        pool.droppedCount,
        greaterThan(0),
        reason: '超限必然丢过一些最旧的；不计数就等于悄悄丢',
      );
      // 留下的那几条仍可取回（取回口径与水位不是一回事：水位只报数）
      final String last = dumpIds.last;
      final int idx = int.parse(last.split('#').first.replaceFirst('p', ''));
      expect(
        pool.take(
          pluginId: 'p$idx',
          generation: 1,
          scope: StationScope(
            teamId: 'team-$idx',
            modeKey: StationModeKey.local,
          ),
        ),
        isNotNull,
        reason: '最新写入的那一条绝不该被淘汰',
      );
    });

    test('重启暂存队列：同一插件 50 路并发只收 32 条，其余**当场**回可读失败（不排队）', () async {
      final PluginRestartBuffer buffer = PluginRestartBuffer(
        maxPerPlugin: 32,
        maxTotalBytes: 1 << 20,
      );
      // 故意不把 50 个 future 一次 await 完：在队那 32 条**本来就该一直挂着**（直到
      // ready 重放或 abandon），先 await 它们就是在测“会不会死等”。这里只验
      // “溢出的那些当场就有结论”，剩下的等重放后统一结账。
      final List<StationReply> settledEarly = <StationReply>[];
      final List<Future<StationReply>> futures = <Future<StationReply>>[
        for (int i = 0; i < n; i++)
          buffer.push(
            'alpha',
            request(i, 'team-1'),
            (StationRequest r) async =>
                StationReply.ok(<String, dynamic>{'echo': r.payload}),
          )..then((StationReply reply) {
            if (reply.isFailed) settledEarly.add(reply);
          }),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(buffer.lengthOf('alpha'), 32, reason: '在队数绝不越过每插件上限');
      expect(buffer.overflowCount, n - 32);
      expect(
        settledEarly,
        hasLength(n - 32),
        reason: '超限的那 18 条当场就得有结论（排队只是把无界改成延后）',
      );
      for (final StationReply r in settledEarly) {
        expect(
          r.error,
          allOf(contains('已满'), contains('不再等待'), contains('fail-open')),
          reason: '溢出必须说清“这次不再等、按 fail-open 走”，否则调用方以为还在排',
        );
      }

      // 队列里的 32 条在 ready 后按 FIFO 全部结清（重放用新一世的投递闭包）
      final List<int> replayed = <int>[];
      await buffer.replay(
        'alpha',
        deliver: (StationRequest r) async {
          replayed.add((r.payload! as Map<String, dynamic>)['seq'] as int);
          return StationReply.ok(<String, dynamic>{
            'seq': (r.payload! as Map<String, dynamic>)['seq'],
          });
        },
      );
      expect(replayed, hasLength(32));
      expect(
        replayed,
        List<int>.generate(32, (int i) => i),
        reason: 'FIFO：入队顺序就是重放顺序（乱序会让插件侧的上下文错位）',
      );
      expect(buffer.lengthOf('alpha'), 0);
      expect(buffer.replayedCount, 32);
      // 50 条全部结账（不留挂着的 future）：重放 32 + 当场拒 18
      final List<StationReply> all = await Future.wait<StationReply>(futures);
      expect(all.where((StationReply r) => !r.isFailed), hasLength(32));
      expect(all.where((StationReply r) => r.isFailed), hasLength(n - 32));
    });

    test('站点在途等待：慢订阅者堆到上限后新请求立即背压，回包数不越界', () async {
      final StationHub hub = StationHub(
        storePath: p.join(
          Directory.systemTemp.createTempSync('tree_mass_wait_').path,
          'stations.yaml',
        ),
      );
      hub.ensureBuiltinStations();
      final RelayStation relay =
          hub.station(StationHubIds.relayLlmHandle)! as RelayStation;
      relay.maxWaitsInFlight = 8;
      final Gate opener = Gate();
      hub.subscribe(
        relay.id,
        StationSubscriber(
          pluginId: 'slow',
          scope: StationScope(teamId: 'team-1', modeKey: StationModeKey.local),
          subscribedAt: 1,
        ),
        (StationRequest request) async {
          await opener.future;
          return StationReply.ok(<String, dynamic>{});
        },
      );
      final StationSubscriber sub = relay.subscribers.single;

      final List<Future<StationReply>> inFlight = <Future<StationReply>>[
        for (int i = 0; i < n; i++)
          relay.awaitReply(subscriber: sub, request: request(i, 'team-1')),
      ];
      // 前 8 条挂在慢订阅者上，其余 42 条**当场**就是结论（不等闸门）：闸门一开
      // 全部结账，背压那几条的数量与计数都不能变。
      opener.complete();
      final List<StationReply> all = await Future.wait<StationReply>(inFlight);

      expect(relay.waitsInFlight, 0, reason: '全部结账后不留挂账');
      expect(
        all.where((StationReply r) => r.isFailed).length,
        n - 8,
        reason: '超限的都要显式拒（背压），不许无限堆下去',
      );
      expect(relay.counters.describe()['overload_skipped'], n - 8);
      final Map<String, dynamic> described = relay.describe();
      expect(
        (described['gauges'] as Map<String, dynamic>)['waits_limit'],
        8,
        reason: '上限也是水位的一部分（面板要分得清边缘与正常）',
      );
    });
  });

  // ── 真链路：50（可用 TREE_MASS_STRESS_N 顶高）个插件进程同时热重启 ────────
  test(
    '真链路：$massN 个插件同时 hotRestart 全部换世成功且互不牵连',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync(
        'tree_mass_restart_',
      );
      final String script = p.join(
        Directory.current.path,
        'test',
        'fixtures',
        'suspendable_plugin.dart',
      );
      expect(File(script).existsSync(), isTrue, reason: '假插件脚本必须存在');
      final File config = File(p.join(temp.path, 'config', 'plugins.yaml'));
      config.createSync(recursive: true);
      // 路里的反斜杠必须全部换成 `/`：YAML 双引号串里 `\p` 是非法转义，整份配置
      // 会解不出来（那时 50 家一家都起不了，症状看起来倒像“并发把核心弄挂了”）。
      String slash(String path) => path.replaceAll('\\', '/');
      final String root = slash(temp.path);
      config.writeAsStringSync(
        <String>[
          'enabled: true',
          'plugins:',
          for (int i = 0; i < massN; i++) ...<String>[
            '  - id: mass$i',
            '    name: 压力插件 $i',
            '    command: "${slash(Platform.resolvedExecutable)}"',
            '    args: ["${slash(script)}", "--id", "mass$i", "--event-log", "$root/mass$i.events.jsonl"]',
            '    enabled: true',
            '    granularity: team',
            '    suspension: keep',
            '    scope: {team_id: team-1}',
          ],
          '',
        ].join('\n'),
      );
      final List<String> logs = <String>[];
      final PluginBus bus = PluginBus(
        configFile: config.path,
        coreVersion: 'test',
        heartbeatInterval: const Duration(seconds: 30),
        log: logs.add,
      );
      // 池与队列的上限保持保守缺省：这一条要看的正是"真风暴撞上小上限"会怎样
      await bus.start();
      addTearDown(() async {
        await bus.close();
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });

      expect(
        bus.instances(),
        hasLength(massN),
        reason: '$massN 家都要先起来（起不来看核心日志：${logs.join('\n')}）',
      );
      final List<String> ids = <String>[
        for (int i = 0; i < massN; i++) 'mass$i',
      ];
      final List<PluginHotRestartResult> results =
          await Future.wait<PluginHotRestartResult>(
            <Future<PluginHotRestartResult>>[
              for (final String id in ids) bus.hotRestart(id),
            ],
          );

      final List<String> failed = <String>[
        for (int i = 0; i < massN; i++)
          if (!results[i].ok) '${ids[i]}: ${results[i].reason}',
      ];
      expect(failed, isEmpty, reason: '一个都不许掉（互不牵连是阶段 1 就钉住的口径）');
      for (final String id in ids) {
        expect(bus.generationOf(id), 2, reason: id);
      }
      // 风暴过后的水位：池与队列都收回在上限内（不是"跑完就漏"）
      expect(bus.statePool.length, lessThanOrEqualTo(bus.statePool.maxEntries));
      expect(
        bus.statePool.totalBytes,
        lessThanOrEqualTo(bus.statePool.maxTotalBytes),
      );
      expect(
        bus.restartBuffer.totalBytes,
        lessThanOrEqualTo(bus.restartBufferMaxTotalBytes),
      );
      // 本进程（总线就跑在核心侧同一个隔离区里）的热重启风暴后 RSS：上限给得很宽，
      // 它的目的不是卡住优化，而是让「崩」与「吃内存」在失败时能当场分得开。
      final int rssMb = (ProcessInfo.currentRss / (1024 * 1024)).round();
      expect(
        rssMb,
        lessThan(4096),
        reason: '$massN 路热重启后核心侧 RSS ${rssMb}MB（峰值靠外部采样记录）',
      );
    },
    timeout: const Timeout(Duration(minutes: 12)),
    skip: _massStress ? false : '$massN 个真插件进程（峰值两世并存）不该进常规闸门；开法见文件头注释',
  );
}

/// 手动放行的闸门（用来制造"迟迟不回包"的慢订阅者）。
class Gate {
  final Completer<void> _completer = Completer<void>();

  Future<void> get future => _completer.future;

  void complete() => _completer.complete();
}
