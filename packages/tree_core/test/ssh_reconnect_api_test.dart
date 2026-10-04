// 显式「重连」端点（2026-10-05）：SSH 心跳判失活之后的**手动**恢复入口。
//
// 现场：一条已经断掉的 TCP 连接不会自己活回来——心跳连丢 1325 拍（≈3h41m）、远端实测
// 可达，应用却再没恢复过，用户只能重启。修法两条：传输层判失活那一瞬间起**后台重连**
// （退避），核心再给一个**显式**入口（右栏文件错误块上的「重连」按钮）。
//
// 这里钉住端点的四条结局与"真的打到了链路层"：200（已重建、stale 复位）/ 400（该 agent
// 不是 SSH——用错入口）/ 404（没有这个 agent）/ 500（重建失败，detail 可读）；
// 另有一条 501（工具执行器没接入，不静默 404）。判活判据不变：重连不是新的判活依据。
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 假的"可重连远端"：真 [LocalWorkspaceIO] 的语义 + [ReconnectableWorkspace] 能力。
///
/// 用真本机 IO 当底座是为了让这条用例只关心"重连入口"，不必造一整套远端文件语义；
/// 而"能力要能穿过 `PrivateWorkspaceIO`"这一点照旧被覆盖——runner 拿到的永远是那个
/// `.self` 分栏装饰器，不是这个对象本身。
class _FakeRemoteIo extends LocalWorkspaceIO implements ReconnectableWorkspace {
  _FakeRemoteIo(super.root);

  /// 当前是否"已判失活"（用例自己摆）。
  bool stale = false;

  /// 被调用重连的次数（显式入口必须真的打到这一层）。
  int reconnects = 0;

  /// 非空 = 重连失败并抛这个原因（用例摆成"远端不可达"）。
  String? failWith;

  @override
  bool get linkStale => stale;

  @override
  String get linkMessage =>
      stale ? 'SSH 链路失活：连续 3 次心跳丢失（用例假链路）' : '';

  @override
  Future<void> reconnectLink() async {
    reconnects++;
    final String? failure = failWith;
    if (failure != null) throw WorkspaceIoException(failure);
    stale = false;
  }
}

void main() {
  late MemoryStore store;
  late CoreAgent agent;
  late _FakeRemoteIo remote;
  late Directory temp;
  late CoreServer server;
  final HttpClient http = HttpClient();

  Future<void> start({
    bool ssh = true,
    bool wireRunner = true,
    bool sshConfigIncomplete = false,
  }) async {
    store = MemoryStore();
    agent = store.createAgent(name: '远端用例', modelId: 'demo');
    if (ssh) {
      agent.sshConfig = sshConfigIncomplete
          ? const SshConfig(host: 'remote.example.com', port: 22, username: '')
          : const SshConfig(
              host: 'remote.example.com',
              port: 22,
              username: 'open',
              keyPath: '/home/open/.ssh/id_ed25519',
            );
    }
    store.putAgent(agent);
    temp = Directory.systemTemp.createTempSync('tree_ssh_reconnect_');
    remote = _FakeRemoteIo(temp.path)..stale = true;
    // 与生产同一形状：runner 的 io 解析 → PrivateWorkspaceIO(agentId) 包一层。
    final WorkspaceToolRunner runner = WorkspaceToolRunner(
      resolveWorkspaceDir: (String _) => temp.path,
      resolveSshConfig: (String id) => store.agent(id)?.sshConfig,
      sshIoFactory: (SshConfig _) async => remote,
    );
    server = await CoreServer.start(
      store: store,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: wireRunner
          ? LlmAgentEngine(
              resolveModel: (String _) => null,
              toolRunner: runner,
            )
          : ScriptedAgent(chunkDelay: Duration.zero),
    );
  }

  tearDown(() async {
    await server.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<({int status, Map<String, dynamic> json})> reconnect(String agentId) async {
    final HttpClientRequest request = await http.postUrl(
      Uri.parse('${server.handshake.httpBaseUrl}${ApiPaths.agentSshReconnect.replaceFirst('{agentId}', agentId)}'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${server.token}',
    );
    final HttpClientResponse response = await request.close();
    final String text = await response.transform(utf8.decoder).join();
    return (
      status: response.statusCode,
      json: text.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  test('SSH agent 判失活 ⇒ 200：真的重连到了链路层，stale 复位', () async {
    await start();
    final ({int status, Map<String, dynamic> json}) res = await reconnect(agent.id);
    expect(res.status, 200);
    expect(res.json['ok'], isTrue);
    expect(res.json['agent_id'], agent.id);
    expect(res.json['stale'], isFalse);
    expect(remote.reconnects, 1, reason: '显式入口必须打到链路层（穿过 PrivateWorkspaceIO）');
    expect(remote.stale, isFalse);
  });

  test('未失活也能重连（换个连接继续用）', () async {
    await start();
    remote.stale = false;
    final ({int status, Map<String, dynamic> json}) res = await reconnect(agent.id);
    expect(res.status, 200);
    expect(remote.reconnects, 1);
  });

  test('本机 agent ⇒ 400 + 可读原因（用错入口，不该报 500 吓人）', () async {
    await start(ssh: false);
    final ({int status, Map<String, dynamic> json}) res = await reconnect(agent.id);
    expect(res.status, 400);
    expect('${res.json['detail']}', contains('SSH'));
    expect(remote.reconnects, 0);
  });

  test('SSH 配置不完整 ⇒ 400 / 500 的可读原因，不静默成功', () async {
    await start(sshConfigIncomplete: true);
    final ({int status, Map<String, dynamic> json}) res = await reconnect(agent.id);
    expect(res.status, anyOf(400, 500));
    expect('${res.json['detail']}', isNotEmpty);
    expect(remote.reconnects, 0);
  });

  test('agent 不存在 ⇒ 404', () async {
    await start();
    final ({int status, Map<String, dynamic> json}) res = await reconnect('agt_不存在');
    expect(res.status, 404);
    expect('${res.json['detail']}', contains('不存在'));
  });

  test('重连失败 ⇒ 500 + 可读原因（不是静默成功，也不是 200）', () async {
    await start();
    remote.failWith = 'SSH 重连失败：主机不可达（remote.example.com:22）';
    final ({int status, Map<String, dynamic> json}) res = await reconnect(agent.id);
    expect(res.status, 500);
    expect('${res.json['detail']}', contains('主机不可达'));
    expect(remote.reconnects, 1);
    expect(remote.stale, isTrue, reason: '失败之后必须保持失活态，不许假装恢复了');
  });

  test('工具执行器未接入 ⇒ 501（显式拒绝，不静默 404）', () async {
    await start(wireRunner: false);
    final ({int status, Map<String, dynamic> json}) res = await reconnect(agent.id);
    expect(res.status, 501);
    expect('${res.json['detail']}', contains('工具执行器'));
  });
}
