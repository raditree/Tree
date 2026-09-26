import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 真机 SSH 文件面板集成（M7g）：门控运行。
///
/// 环境变量（缺 TREE_SSH_TEST_HOST 就跳过，与 ssh_integration_test.dart 同风格）：
///   TREE_SSH_TEST_HOST  主机
///   TREE_SSH_TEST_USER  用户名（默认 open）
///   TREE_SSH_TEST_KEY   私钥路径（默认 ~/.ssh/id_ed25519）
///   TREE_SSH_TEST_ROOT  远端根目录（默认 /mnt/space）
///
/// 注意两点口径：
/// 1. 文件面板的「工作空间根」= 该 agent 的 SSH root（与工具层一致），
///    agent.workspaceDir 对 SSH 不参与解析；因此本次产物统一放在 root/dir/ 下。
/// 2. 上传落点在工作空间根的 .input/ 下（不在 dir 里），收尾要单独清。
void main() {
  final String host = Platform.environment['TREE_SSH_TEST_HOST'] ?? '';

  test('真机：远端工作空间 list/content/upload/download/sync/archive 全链路', () async {
    if (host.isEmpty) {
      markTestSkipped('未设置 TREE_SSH_TEST_HOST，跳过真机 SSH 文件面板测试');
      return;
    }
    final String home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    final String user = Platform.environment['TREE_SSH_TEST_USER'] ?? 'open';
    final String keyPath =
        Platform.environment['TREE_SSH_TEST_KEY'] ?? '$home/.ssh/id_ed25519';
    final String root =
        Platform.environment['TREE_SSH_TEST_ROOT'] ?? '/mnt/space';

    final DartSshTransport transport = await DartSshTransport.connect(
      host: host,
      port: 22,
      username: user,
      keyPath: keyPath,
    );
    final String remoteRoot = await resolveRemoteRoot(transport, root);
    final String dir = 'tree_m7g_${DateTime.now().millisecondsSinceEpoch}';
    // 把该 agent 的 SSH root 指到本次运行的目录：文件面板的"工作空间根"就是它。
    // 这样 syncToLocal 只搬本次测试的文件，不会去遍历整个 /mnt/space。
    final SshWorkspaceIO io = SshWorkspaceIO('$remoteRoot/$dir', transport);
    final MemoryStore store = MemoryStore();
    final CoreAgent agent = store.createAgent(name: '真机远端', modelId: 'demo');
    agent.sshConfig = SshConfig(
      host: host,
      username: user,
      keyPath: keyPath,
      root: '$root/$dir',
    );
    agent.workspaceDir = '$remoteRoot/$dir';
    store.putAgent(agent);

    final CoreServer server = await CoreServer.start(
      store: store,
      fileService: FileService(
        store: store,
        defaultWorkspaceDir: (String _) => '$remoteRoot/$dir',
        remoteFilesFor: (String _) async => io,
      ),
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    final HttpClient http = HttpClient();
    final String base = server.handshake.httpBaseUrl;
    final Directory localOut = Directory.systemTemp.createTempSync(
      'tree_ssh_it_',
    );
    String uploadedRel = '';

    Future<(int, List<int>)> call(
      String method,
      String path, {
      Map<String, dynamic>? body,
    }) async {
      final HttpClientRequest request = await http.openUrl(
        method,
        Uri.parse('$base$path'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${server.token}',
      );
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final HttpClientResponse response = await request.close();
      final List<int> bytes = await response.fold<List<int>>(
        <int>[],
        (List<int> acc, List<int> chunk) => acc..addAll(chunk),
      );
      return (response.statusCode, bytes);
    }

    Map<String, dynamic> asJson(List<int> bytes) =>
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

    addTearDown(() async {
      try {
        await transport.run('rm -rf "$remoteRoot/$dir"');
        if (uploadedRel.isNotEmpty) {
          await transport.run('rm -f "$remoteRoot/$uploadedRel"');
          final String parent = uploadedRel.substring(
            0,
            uploadedRel.lastIndexOf('/'),
          );
          await transport.run(
            'rmdir --ignore-fail-on-non-empty "$remoteRoot/$parent"',
          );
        }
      } catch (_) {
        // 清理尽力而为，不影响断言结论
      }
      await server.close();
      await transport.close();
      http.close(force: true);
      if (localOut.existsSync()) localOut.deleteSync(recursive: true);
    });

    // ① 先用工作空间 IO 在远端铺两个文件（顺带验证 SFTP 写 + 建父目录）
    await io.writeBytes('$dir/seed/a.txt', utf8.encode('远端内容 A\n'));
    await io.writeBytes('$dir/seed/sub/b.md', utf8.encode('# B\n'));
    final String ws = agent.workspaceId;
    // 工作空间根已指向本次目录，因此 REST 里的 path 都是相对它的

    // ② 列目录（真 SFTP listdir：大小/时间来自远端 stat）
    final (int listStatus, List<int> listBytes) = await call(
      'GET',
      '/api/files/$ws?path=$dir/seed',
    );
    expect(listStatus, 200, reason: utf8.decode(listBytes));
    final List<dynamic> files = asJson(listBytes)['files'] as List<dynamic>;
    final List<String> names = files
        .map((dynamic e) => (e as Map<String, dynamic>)['name'] as String)
        .toList();
    expect(names, containsAll(<String>['a.txt', 'sub']));
    final Map<String, dynamic> first = files.firstWhere(
      (dynamic e) => (e as Map<String, dynamic>)['name'] == 'a.txt',
    ) as Map<String, dynamic>;
    expect(first['size'], greaterThan(0));
    expect(first['modified'], isNotEmpty, reason: '真机 stat 应给出修改时间');
    print('真机 list: $names（a.txt=${first['size']} 字节）');

    // ③ 读内容
    final (int contentStatus, List<int> contentBytes) = await call(
      'GET',
      '/api/files/$ws/content?path=$dir/seed/a.txt',
    );
    expect(contentStatus, 200);
    expect(asJson(contentBytes)['content'], '远端内容 A\n');

    // ④ 单文件下载
    final (int downloadStatus, List<int> downloadBytes) = await call(
      'POST',
      '/api/files/$ws/download',
      body: <String, dynamic>{'path': '$dir/seed/a.txt'},
    );
    expect(downloadStatus, 200);
    expect(utf8.decode(downloadBytes), '远端内容 A\n');

    // ⑤ 分片上传（本地暂存 → complete 一次 SFTP 写）
    final List<int> payload = List<int>.generate(5000, (int i) => i % 256);
    final (int initStatus, List<int> initBytes) = await call(
      'POST',
      '/api/files/$ws/upload_init',
      body: <String, dynamic>{
        'file_name': '上传.bin',
        'rel_path': 'in',
        'total_size': payload.length,
      },
    );
    expect(initStatus, 200, reason: utf8.decode(initBytes));
    final String uploadId = asJson(initBytes)['upload_id'] as String;
    final int chunkSize =
        (asJson(initBytes)['chunk_size'] as num?)?.toInt() ?? 4 * 1024 * 1024;
    int index = 0;
    for (int sent = 0; sent < payload.length; sent += chunkSize) {
      final int end = (sent + chunkSize > payload.length)
          ? payload.length
          : sent + chunkSize;
      final (int chunkStatus, List<int> chunkBytes) = await call(
        'POST',
        '/api/files/$ws/upload_chunk',
        body: <String, dynamic>{
          'upload_id': uploadId,
          'index': index++,
          'data': base64Encode(payload.sublist(sent, end)),
        },
      );
      expect(chunkStatus, 200, reason: utf8.decode(chunkBytes));
    }
    final (int doneStatus, List<int> doneBytes) = await call(
      'POST',
      '/api/files/$ws/upload_complete',
      body: <String, dynamic>{'upload_id': uploadId, 'total_chunks': index},
    );
    expect(doneStatus, 200, reason: utf8.decode(doneBytes));
    uploadedRel = asJson(doneBytes)['path'] as String;
    expect(uploadedRel, startsWith('.input/'));
    expect(await io.readBytes(uploadedRel), payload, reason: '远端落盘的字节必须一致');
    print('真机 upload: $uploadedRel（${payload.length} 字节）');

    // ⑥ 目录打包（拉回本地再 tar.gz）
    final (int folderStatus, List<int> folderBytes) = await call(
      'POST',
      '/api/files/$ws/download_folder',
      body: <String, dynamic>{'path': '$dir/seed'},
    );
    expect(folderStatus, 200);
    final String listing = utf8.decode(
      gzip.decode(folderBytes),
      allowMalformed: true,
    );
    expect(listing, contains('$dir/seed/a.txt'));
    expect(listing, contains('$dir/seed/sub/b.md'));
    print('真机 download_folder: ${folderBytes.length} 字节 tar.gz');

    // ⑦ 同步到本地
    final (int syncStatus, List<int> syncBytes) = await call(
      'POST',
      '/api/files/$ws/syncToLocal',
      body: <String, dynamic>{'local_path': localOut.path},
    );
    expect(syncStatus, 200, reason: utf8.decode(syncBytes));
    final Map<String, dynamic> sync = asJson(syncBytes);
    expect(sync['files'], greaterThanOrEqualTo(3));
    expect(
      File('${localOut.path}/$dir/seed/a.txt').readAsStringSync(),
      '远端内容 A\n',
    );
    print('真机 syncToLocal: ${sync['files']} 个文件 / ${sync['bytes']} 字节');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
