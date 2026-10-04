import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

import 'fake_ssh_transport.dart';

/// 「判失活 → 重连」这条路的单测（2026-10-05）。
///
/// 现场：SSH 链路心跳连续丢失 1325 拍（≈3h41m）而**再没恢复过**，远端实测可达，
/// 用户只能重启应用——根因是判失活之后**没有任何重建路径**。修法两层：
/// ① 判失活那一瞬间由 [SshLiveness.onStale] 通知传输层，起一个**后台重连循环**
///    （单飞 + 退避）；② 核心再加一条**显式**「重连」入口。
///
/// 真链路的建连没法在本机单测（没有 sshd、也不能凭空造 `SSHClient`），所以这里钉的是
/// **策略与接线**：节拍器（什么时候试、会不会叠第二个、关停后还试不试）用假 attempt /
/// 假 sleep 钉死；链路侧的可见面（`linkStale` / `reconnectLink`）用假传输钉死。
/// 真建连那几行由门控真机用例与手工核对兜住（边界如实写在 known-issues）。
void main() {
  group('SshReconnectPump：单飞 + 退避（策略）', () {
    test('retryNow：成功一次即计数 1，且不再有在途重建', () async {
      int calls = 0;
      final SshReconnectPump pump = SshReconnectPump(
        attempt: () async => calls++,
        sleep: (Duration _) async {},
        backoff: const <Duration>[Duration.zero],
      );
      await pump.retryNow();
      expect(calls, 1);
      expect(pump.attempts, 1);
      expect(pump.inFlight, isFalse);
      expect(pump.stopped, isFalse);
    });

    test('retryNow：失败原样抛给调用方（核心据此回可读原因）', () async {
      final SshReconnectPump pump = SshReconnectPump(
        attempt: () async => throw WorkspaceIoException('SSH 重连失败：主机不可达'),
        sleep: (Duration _) async {},
        backoff: const <Duration>[Duration.zero],
      );
      await expectLater(
        pump.retryNow(),
        throwsA(
          isA<WorkspaceIoException>().having(
            (WorkspaceIoException e) => e.message,
            'message',
            contains('主机不可达'),
          ),
        ),
      );
      expect(pump.attempts, 1);
      expect(pump.inFlight, isFalse, reason: '失败后必须放开单飞闸门，否则再也试不了');
    });

    test('单飞：后台循环与显式重连 / 用户连点，同一时刻只打一次', () async {
      final Completer<void> gate = Completer<void>();
      int calls = 0;
      final SshReconnectPump pump = SshReconnectPump(
        attempt: () {
          calls++;
          return gate.future;
        },
        sleep: (Duration _) async {},
        backoff: const <Duration>[Duration.zero],
        stillNeeded: () => true,
      );
      final Future<void> a = pump.retryNow();
      final Future<void> b = pump.retryNow();
      final Future<void> c = pump.retryNow();
      expect(calls, 1, reason: '在途时复用的必须是同一次重建');
      expect(pump.inFlight, isTrue);
      gate.complete();
      await Future.wait<void>(<Future<void>>[a, b, c]);
      expect(calls, 1);
      await a; // 三个 future 都指向同一次尝试
      expect(pump.attempts, 1);
    });

    test('后台循环：先失败按退避再试，成功即收工（并逐条报可读事件）', () async {
      final List<Duration> slept = <Duration>[];
      final List<String> events = <String>[];
      int calls = 0;
      final SshReconnectPump pump = SshReconnectPump(
        attempt: () async {
          calls++;
          if (calls < 3) throw WorkspaceIoException('第 $calls 次不通');
        },
        backoff: const <Duration>[
          Duration(milliseconds: 5),
          Duration(milliseconds: 10),
          Duration(seconds: 30),
        ],
        sleep: (Duration d) async => slept.add(d),
        stillNeeded: () => true,
        onEvent: events.add,
      );
      await pump.start();
      expect(calls, 3);
      expect(slept, <Duration>[
        const Duration(milliseconds: 5),
        const Duration(milliseconds: 10),
        const Duration(seconds: 30),
      ]);
      expect(
        events.where((String e) => e.contains('失败')).length,
        2,
        reason: '每次失败都要如实报一句（不许静默重试）',
      );
      expect(events.last, contains('成功'));
      expect(pump.running, isFalse, reason: '成功之后循环自己收口');
    });

    test('退避走完一直用最后一拍（它不是总时长上限）', () async {
      final List<Duration> slept = <Duration>[];
      late SshReconnectPump pump;
      int calls = 0;
      pump = SshReconnectPump(
        attempt: () async {
          calls++;
          if (calls >= 5) pump.stop();
          throw WorkspaceIoException('一直不通');
        },
        backoff: const <Duration>[
          Duration(milliseconds: 1),
          Duration(milliseconds: 2),
          Duration(milliseconds: 3),
        ],
        sleep: (Duration d) async => slept.add(d),
        stillNeeded: () => true,
      );
      await pump.start();
      expect(calls, 5);
      expect(
        slept,
        <Duration>[
          const Duration(milliseconds: 1),
          const Duration(milliseconds: 2),
          const Duration(milliseconds: 3),
          const Duration(milliseconds: 3),
          const Duration(milliseconds: 3),
        ],
        reason: '最后一拍封顶后一直用它（持续重试，不是"试几次就算了"）',
      );
    });

    test('start 幂等：同一条链路不会被叠出第二个循环', () async {
      final Completer<void> gate = Completer<void>();
      int calls = 0;
      final SshReconnectPump pump = SshReconnectPump(
        attempt: () {
          calls++;
          return gate.future;
        },
        sleep: (Duration _) async {},
        backoff: const <Duration>[Duration.zero],
        stillNeeded: () => true,
      );
      final Future<void> first = pump.start();
      final Future<void> second = pump.start();
      expect(identical(first, second), isTrue, reason: '同一个循环 future');
      expect(pump.running, isTrue);
      gate.complete();
      await first;
      expect(calls, 1, reason: '两次 start 只叠出一个循环、只打一次');
      expect(pump.running, isFalse);
    });

    test('stillNeeded=false：链路已经被别处救回来了，不必再试', () async {
      bool needed = false;
      int calls = 0;
      final SshReconnectPump pump = SshReconnectPump(
        attempt: () async => calls++,
        sleep: (Duration _) async {},
        backoff: const <Duration>[Duration.zero],
        stillNeeded: () => needed,
      );
      await pump.start();
      expect(calls, 0);
      needed = true;
      await pump.start();
      expect(calls, 1, reason: '条件恢复后仍可按需再起（不会永久卡死）');
    });

    test('stop：关停之后不再起循环，显式重连也直接拒绝', () async {
      int calls = 0;
      final SshReconnectPump pump = SshReconnectPump(
        attempt: () async => calls++,
        sleep: (Duration _) async {},
        backoff: const <Duration>[Duration.zero],
        stillNeeded: () => true,
      );
      pump.stop();
      expect(pump.stopped, isTrue);
      await pump.start();
      expect(calls, 0);
      await expectLater(pump.retryNow(), throwsA(isA<StateError>()));
      expect(calls, 0);
    });

    test('空退避列表也安全（退化成"立刻再试"）', () async {
      final List<Duration> slept = <Duration>[];
      int calls = 0;
      final SshReconnectPump pump = SshReconnectPump(
        attempt: () async {
          calls++;
          throw WorkspaceIoException('还不通');
        },
        backoff: const <Duration>[],
        sleep: (Duration d) async => slept.add(d),
        // 试两次就不再需要（避免用例里自己引用自己来停手）。
        stillNeeded: () => calls < 2,
      );
      await pump.start();
      expect(slept, <Duration>[Duration.zero, Duration.zero]);
      expect(calls, 2);
    });
  });

  group('链路重建的接线（SshWorkspaceIO ↔ SshTransport）', () {
    test('未失活：linkStale=false、linkMessage 为空、reconnect 透传到传输层', () async {
      final FakeSshTransport transport = FakeSshTransport();
      final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);
      expect(io.linkStale, isFalse);
      expect(io.linkMessage, '');

      await io.reconnectLink();
      expect(transport.reconnects, 1, reason: '显式入口必须真的打到传输层');
    });

    test('失活后重建：标记解除，操作重新可用', () async {
      final FakeSshTransport transport = FakeSshTransport();
      final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);
      for (int i = 0; i < SshLiveness.defaultMaxMisses; i++) {
        transport.liveness.recordMiss();
      }
      expect(io.linkStale, isTrue);
      expect(io.linkMessage, contains('心跳丢失'));
      expect(
        io.linkMessage,
        isNot(contains('自动恢复')),
        reason: '文案要说真话：旧连接不会自己恢复（2026-10-05 现场 1325 拍）',
      );
      await expectLater(
        io.readFile('.self/x.md'),
        throwsA(isA<SshLinkStaleException>()),
        reason: '重建之前，在途/新来的操作显式失败（不静默挂起）',
      );

      await io.reconnectLink();
      expect(io.linkStale, isFalse);
      transport.seed('/ws/.self/x.md', 'ok\n');
      final FileContent content = await io.readFile('.self/x.md');
      expect(content.text, contains('ok'));
    });

    test('本机后端不实现该能力（核心据此显式回可读错误，而不是假装成功）', () {
      final LocalWorkspaceIO local = LocalWorkspaceIO('.');
      expect(local is ReconnectableWorkspace, isFalse);
    });
  });
}
