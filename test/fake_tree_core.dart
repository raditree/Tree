import 'dart:convert';
import 'dart:io';

/// 假核心：只实现文件面板（目录树 / git 状态 / 新建 / 改名 / 删除）用得上的端点。
///
/// 为什么真起一个本机 HttpServer（与 test/file_editor_test.dart 同一套路）：ApiService
/// 是静态的、直连核心，只有让它真发一次请求，才能验证"打到的是哪个端点、路径与 body
/// 是什么"——这正是不一致时最先坏掉的地方。
class FakeTreeCore {
  FakeTreeCore._(this._http);

  final HttpServer _http;

  /// 目录列举：相对路径（'' = 根）→ 条目（没登记过的路径给空目录）
  final Map<String, List<Map<String, dynamic>>> dirs =
      <String, List<Map<String, dynamic>>>{};

  /// 这些目录的列举请求回 404 + detail（钉"加载失败"那一行）
  final Set<String> failingDirs = <String>{};

  /// 根列举是否被核心截断（truncated 标记）
  bool truncatedRoot = false;

  /// git 状态响应（默认"不是仓库" ⇒ 完全不着色）
  Map<String, dynamic> gitStatus = <String, dynamic>{
    'is_repo': false,
    'entries': <dynamic>[],
  };

  /// git 状态端点的状态码（404 = 核心还没这个端点：UI 必须静默不着色）
  int gitStatusStatus = 200;

  /// 收到的请求（方法 + 路径 + 查询串 + body）
  final List<
    ({String method, String path, String query, Map<String, dynamic> body})
  >
  calls =
      <({String method, String path, String query, Map<String, dynamic> body})>[];

  /// 三个写端点的脚本化响应（默认 200 + success）
  int mkdirStatus = 200;
  String mkdirDetail = '';
  int renameStatus = 200;
  String renameDetail = '';
  int deleteStatus = 200;
  String deleteDetail = '';

  /// PUT content（新建文件 / 保存）收到的写入
  final List<({String path, String content})> writes =
      <({String path, String content})>[];

  /// GET content 的返回（查看器用）
  String content = 'hello';
  int contentSize = 5;
  bool contentTruncated = false;

  static Future<FakeTreeCore> start() async {
    final HttpServer http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final FakeTreeCore core = FakeTreeCore._(http);
    http.listen(core._handle);
    return core;
  }

  String get baseUrl => 'http://127.0.0.1:${_http.port}';

  Future<void> close() => _http.close(force: true);

  // ── 条目工厂（测试里拼目录内容用） ──

  static Map<String, dynamic> dir(String path, String name) =>
      <String, dynamic>{
        'name': name,
        'path': path,
        'type': 'dir',
        'size': 0,
        'modified': '2026-10-02T11:31:00',
      };

  static Map<String, dynamic> file(
    String path,
    String name, {
    int size = 10,
    String modified = '2026-10-02T11:31:00',
  }) => <String, dynamic>{
    'name': name,
    'path': path,
    'type': 'file',
    'size': size,
    'modified': modified,
  };

  /// 某次请求是否发生过（方法 + 路径后缀 + 可选查询串）
  bool called(
    String method,
    String pathSuffix, {
    String? queryContains,
  }) => calls.any(
    (({String method, String path, String query, Map<String, dynamic> body}) c) =>
        c.method == method &&
        c.path.endsWith(pathSuffix) &&
        (queryContains == null || c.query.contains(queryContains)),
  );

  /// git 状态被拉了几次（钉"一帧一次请求就够"）
  int get gitStatusRequests => calls
      .where(
        (({String method, String path, String query, Map<String, dynamic> body}) c) =>
            c.method == 'GET' && c.path.endsWith('/git-status'),
      )
      .length;

  Future<void> _handle(HttpRequest request) async {
    final String raw = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> body = raw.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    calls.add((
      method: request.method,
      path: Uri.decodeComponent(request.uri.path),
      query: request.uri.query,
      body: body,
    ));

    Map<String, dynamic> payload = <String, dynamic>{'success': true};
    int status = 200;
    final String path = request.uri.path;
    if (request.method == 'GET') {
      if (path.endsWith('/git-status')) {
        if (gitStatusStatus != 200) {
          status = gitStatusStatus;
          payload = <String, dynamic>{'detail': 'git 状态不可用'};
        } else {
          payload = gitStatus;
        }
      } else if (path.endsWith('/content')) {
        payload = <String, dynamic>{
          'content': content,
          'path': request.uri.queryParameters['path'] ?? '',
          'size': contentSize,
          if (contentTruncated) 'truncated': true,
        };
      } else {
        final String dirPath = request.uri.queryParameters['path'] ?? '';
        if (failingDirs.contains(dirPath)) {
          status = 404;
          payload = <String, dynamic>{'detail': '目录不存在：$dirPath'};
        } else {
          payload = <String, dynamic>{
            'files': dirs[dirPath] ?? <Map<String, dynamic>>[],
            'path': dirPath,
            if (truncatedRoot && dirPath.isEmpty) 'truncated': true,
          };
        }
      }
    } else if (request.method == 'PUT') {
      final String target = request.uri.queryParameters['path'] ?? '';
      writes.add((
        path: target,
        content: (body['content'] as String?) ?? '',
      ));
      // 真核心的 writeFile 会把文件写出来：这里也落成一条条目，界面重拉才看得到
      if (target.isNotEmpty) {
        _removeEntry(target);
        _ensureDir(_parent(target)).add(
          file(target, _name(target), size: 0),
        );
      }
      payload = <String, dynamic>{
        'success': true,
        'size': ((body['content'] as String?) ?? '').length,
      };
    } else if (request.method == 'POST') {
      if (path.endsWith('/mkdir')) {
        if (mkdirStatus != 200) {
          status = mkdirStatus;
          payload = <String, dynamic>{'detail': mkdirDetail};
        } else {
          final String target = (body['path'] as String?) ?? '';
          _ensureDir(target);
          payload = <String, dynamic>{'success': true, 'path': target};
        }
      } else if (path.endsWith('/rename')) {
        if (renameStatus != 200) {
          status = renameStatus;
          payload = <String, dynamic>{'detail': renameDetail};
        } else {
          final String from = (body['from'] as String?) ?? '';
          final String to = (body['to'] as String?) ?? '';
          if (_exists(to)) {
            status = 409;
            payload = <String, dynamic>{'detail': '目标已存在：$to'};
          } else {
            _removeEntry(from);
            if (dirs.containsKey(from)) {
              final List<Map<String, dynamic>> children =
                  dirs.remove(from) ?? <Map<String, dynamic>>[];
              dirs[to] = children;
              _ensureDir(_parent(to)).add(dir(to, _name(to)));
            } else {
              _ensureDir(_parent(to)).add(file(to, _name(to)));
            }
            payload = <String, dynamic>{'success': true, 'from': from, 'to': to};
          }
        }
      }
    } else if (request.method == 'DELETE') {
      if (deleteStatus != 200) {
        status = deleteStatus;
        payload = <String, dynamic>{'detail': deleteDetail};
      } else {
        final String target = request.uri.queryParameters['path'] ?? '';
        if (!_exists(target)) {
          status = 404;
          payload = <String, dynamic>{'detail': '路径不存在：$target'};
        } else {
          _removeEntry(target);
          dirs.removeWhere(
            (String key, _) => key == target || key.startsWith('$target/'),
          );
          payload = <String, dynamic>{'success': true, 'path': target};
        }
      }
    }

    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }

  List<Map<String, dynamic>> _ensureDir(String path) =>
      dirs.putIfAbsent(path, () => <Map<String, dynamic>>[]);

  void _removeEntry(String path) {
    dirs[_parent(path)]?.removeWhere(
      (Map<String, dynamic> entry) => entry['name'] == _name(path),
    );
  }

  bool _exists(String path) {
    if (path.isEmpty) return true;
    if (dirs.containsKey(path)) return true;
    return (dirs[_parent(path)] ?? <Map<String, dynamic>>[]).any(
      (Map<String, dynamic> entry) => entry['name'] == _name(path),
    );
  }

  static String _parent(String path) {
    final int at = path.lastIndexOf('/');
    return at < 0 ? '' : path.substring(0, at);
  }

  static String _name(String path) {
    final int at = path.lastIndexOf('/');
    return at < 0 ? path : path.substring(at + 1);
  }
}
