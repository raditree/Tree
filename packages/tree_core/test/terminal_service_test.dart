import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/src/files/file_service.dart';
import 'package:tree_core/src/settings/ssh_config.dart';
import 'package:tree_core/src/store/memory_store.dart';
import 'package:tree_core/src/store/records.dart';
import 'package:tree_core/src/terminal/pty_process.dart';
import 'package:tree_core/src/terminal/terminal_service.dart';
import 'package:tree_core/src/ws/ws_hub.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 假伪终端：记录写入与尺寸，可手动灌输出、手动结束
class _FakePty implements PtyProcess {
  @override
  String get shell => 'fake-shell';

  final StreamController<List<int>> _out = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  final List<List<int>> writes = <List<int>>[];
  final List<(int, int)> resizes = <(int, int)>[];
  bool closed = false;

  @override
  Stream<List<int>> get output => _out.stream;

  @override
  Future<void> write(List<int> data) async => writes.add(data);

  @override
  Future<void> resize(int columns, int rows) async =>
      resizes.add((columns, rows));

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> close() async {
    if (closed) return; // 幂等
    closed = true;
    if (!_exit.isCompleted) _exit.complete(0);
    if (!_out.isClosed) await _out.close();
  }

  void emit(String text) {
    if (!_out.isClosed) _out.add(utf8.encode(text));
  }

  void finish(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }
}

/// 假 socket：只记录 send 出去的原始 JSON 文本（其余成员用 noSuchMethod 兜住）
class _FakeSocket implements WebSocket {
  final List<String> raw = <String>[];

  @override
  void add(dynamic data) {
    raw.add(data as String);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 从假 socket 里解出帧（等价于"对端看到了什么"）
class _Wire {
  _Wire(this._socket);

  final _FakeSocket _socket;

  List<Map<String, dynamic>> frames() => _socket.raw
      .map((String s) => jsonDecode(s) as Map<String, dynamic>)
      .toList();

  List<Map<String, dynamic>> of(String type) =>
      frames().where((Map<String, dynamic> f) => f['type'] == type).toList();

  Map<String, dynamic>? last(String type) {
    final List<Map<String, dynamic>> all = of(type);
    return all.isEmpty ? null : all.last;
  }
}

/// 等一小会儿，让流事件与 async 回调落地
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late Directory temp;
  late MemoryStore store;
  late CoreAgent agent;
  late FileService files;
  late List<_FakePty> created;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_terminal_');
    store = MemoryStore();
    agent = store.createAgent(name: '终端用例');
    agent.workspaceDir = temp.path;
    store.putAgent(agent);
    files = FileService(
      store: store,
      defaultWorkspaceDir: (String _) => temp.path,
    );
    created = <_FakePty>[];
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// 造一个带假连接的服务；[wirePty] false = 模拟「核心没接线伪终端实现」
  (TerminalService, WsConnection, _Wire) build({
    PtyStarter? starter,
    bool wirePty = true,
  }) {
    final _FakeSocket socket = _FakeSocket();
    final WsConnection connection = WsConnection(socket: socket);
    final TerminalService service = TerminalService(
      store: store,
      files: files,
      startPty: !wirePty
          ? null
          : starter ??
          ({
            required String command,
            required String workingDirectory,
            required int columns,
            required int rows,
          }) async {
            final _FakePty pty = _FakePty();
            created.add(pty);
            return pty;
          },
    );
    return (service, connection, _Wire(socket));
  }

  test('open：回 ready（cwd/shell/尺寸），输出按 base64 原样回', () async {
    final (TerminalService service, WsConnection connection, _Wire wire) = build();
    await service.open(connection, <String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.agentId: agent.id,
      TerminalFrame.columns: 100,
      TerminalFrame.rows: 30,
    });
    await settle();

    final Map<String, dynamic> ready = wire.last(WsOutboundType.terminalReady)!;
    expect(ready[TerminalFrame.terminalId], 't1');
    expect(ready[TerminalFrame.cwd], temp.path);
    expect(ready[TerminalFrame.shell], 'fake-shell');
    expect(ready[TerminalFrame.columns], 100);
    expect(ready[TerminalFrame.rows], 30);
    expect(service.activeCount, 1);

    // 原始字节（含 ESC 控制序列）必须原样过：base64 解出来要一模一样
    created.single.emit('\u001b[31m红\u001b[0m');
    await settle();
    final Map<String, dynamic> out = wire.last(WsOutboundType.terminalOutput)!;
    expect(
      utf8.decode(
        base64Decode(out[TerminalFrame.bytes] as String),
        allowMalformed: true,
      ),
      '\u001b[31m红\u001b[0m',
    );
  });

  test('input / resize：原样写进伪终端，尺寸越界被夹住', () async {
    final (TerminalService service, WsConnection connection, _Wire wire) = build();
    await service.open(connection, <String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.agentId: agent.id,
    });
    await settle();

    await service.input(<String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.bytes: base64Encode(utf8.encode('ls -la\r')),
    });
    await service.resize(<String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.columns: 9999,
      TerminalFrame.rows: 1,
    });
    await settle();

    expect(utf8.decode(created.single.writes.single), 'ls -la\r');
    expect(created.single.resizes.single, (500, 5), reason: '列夹到 500、行夹到 5');
    // 未知 terminal_id 不许抛
    await service.input(<String, dynamic>{
      TerminalFrame.terminalId: 'nope',
      TerminalFrame.bytes: base64Encode(<int>[1]),
    });
  });

  test('进程退出：回 terminal_exit 与退出码，并清掉会话', () async {
    final (TerminalService service, WsConnection connection, _Wire wire) = build();
    await service.open(connection, <String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.agentId: agent.id,
    });
    await settle();

    created.single.finish(3);
    await settle();

    final Map<String, dynamic> exit = wire.last(WsOutboundType.terminalExit)!;
    expect(exit[TerminalFrame.terminalId], 't1');
    expect(exit[TerminalFrame.exitCode], 3);
    expect(service.activeCount, 0);
    expect(created.single.closed, isTrue, reason: '退出后要收掉伪终端');
  });

  test('close：幂等，且不再转发输出', () async {
    final (TerminalService service, WsConnection connection, _Wire wire) = build();
    await service.open(connection, <String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.agentId: agent.id,
    });
    await settle();
    await service.close('t1');
    await service.close('t1');
    await settle();

    final int before = wire.of(WsOutboundType.terminalOutput).length;
    created.single.emit('关掉之后不该再发');
    await settle();
    expect(wire.of(WsOutboundType.terminalOutput).length, before);
    expect(service.activeCount, 0);
  });

  test('连接断开：把它开的终端全收掉（不留孤儿 shell）', () async {
    final (TerminalService service, WsConnection connection, _Wire wire) = build();
    await service.open(connection, <String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.agentId: agent.id,
    });
    await service.open(connection, <String, dynamic>{
      TerminalFrame.terminalId: 't2',
      TerminalFrame.agentId: agent.id,
    });
    await settle();
    expect(service.activeCount, 2);

    await service.closeForConnection(connection.id);
    await settle();

    expect(service.activeCount, 0);
    expect(created.every((_FakePty p) => p.closed), isTrue);
    expect(wire.of(WsOutboundType.terminalExit), isEmpty,
        reason: '主动收掉不算"进程退出"，不回退出码');
  });

  test('同一个 terminal_id 重复 open：先收掉旧的，不叠进程', () async {
    final (TerminalService service, WsConnection connection, _Wire wire) = build();
    await service.open(connection, <String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.agentId: agent.id,
    });
    await settle();
    await service.open(connection, <String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.agentId: agent.id,
    });
    await settle();

    expect(service.activeCount, 1);
    expect(created, hasLength(2));
    expect(created.first.closed, isTrue, reason: '旧的必须被收掉');
  });

  test('拒绝路径都给可读 terminal_error：没接线 / 未知 agent / 远端 / 缺 id', () async {
    // 1) 核心没接线伪终端
    final (TerminalService unwired, WsConnection c1, _Wire w1) =
        build(wirePty: false);
    await unwired.open(c1, <String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.agentId: agent.id,
    });
    await settle();
    expect(
      w1.last(WsOutboundType.terminalError)![TerminalFrame.message],
      contains('没有接线伪终端实现'),
    );

    // 2) 未知 agent
    final (TerminalService service, WsConnection c2, _Wire w2) = build();
    await service.open(c2, <String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.agentId: '不存在',
    });
    await settle();
    expect(
      w2.last(WsOutboundType.terminalError)![TerminalFrame.message],
      contains('找不到 agent'),
    );

    // 3) 远端（SSH）agent：明确说"暂不支持"
    final CoreAgent remote = store.createAgent(name: '远端');
    remote.sshConfig = const SshConfig(host: 'h', username: 'u', password: 'p');
    store.putAgent(remote);
    final (TerminalService s3, WsConnection c3, _Wire w3) = build();
    await s3.open(c3, <String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.agentId: remote.id,
    });
    await settle();
    expect(
      w3.last(WsOutboundType.terminalError)![TerminalFrame.message],
      contains('交互终端暂不支持'),
    );

    // 4) 缺 terminal_id
    final (TerminalService s4, WsConnection c4, _Wire w4) = build();
    await s4.open(c4, <String, dynamic>{TerminalFrame.agentId: agent.id});
    await settle();
    expect(
      w4.last(WsOutboundType.terminalError)![TerminalFrame.message],
      contains('缺少 terminal_id'),
    );
  });

  test('起进程失败：把它变成可读 terminal_error，不把异常抛给调用方', () async {
    final (TerminalService service, WsConnection connection, _Wire wire) = build(
      starter: ({
        required String command,
        required String workingDirectory,
        required int columns,
        required int rows,
      }) async {
        throw StateError('ConPTY 不可用');
      },
    );
    await service.open(connection, <String, dynamic>{
      TerminalFrame.terminalId: 't1',
      TerminalFrame.agentId: agent.id,
    });
    await settle();

    expect(service.activeCount, 0);
    expect(
      wire.last(WsOutboundType.terminalError)![TerminalFrame.message],
      contains('ConPTY 不可用'),
    );
  });
}
