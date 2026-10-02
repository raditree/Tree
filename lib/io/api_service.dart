import 'dart:convert';
import 'dart:io' show Directory, File, IOSink, Platform, RandomAccessFile;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../ui/models/agent.dart';
import '../ui/models/file_node.dart';
import '../ui/models/session.dart';

/// 流式下载被调用方取消（M8d 下载列表的「取消」按钮）。
///
/// 单独一个类型，是为了让调用方能把「用户取消」和「真失败」分开：取消是正常
/// 结果（把半成品删掉、状态置为已取消），不该弹错误。
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => '已取消';
}

/// API 服务 - 封装对**本机核心进程**的 REST 调用。
///
/// desktop 分支已取消后端与账号体系：`baseUrl` 指向核心进程在本机回环上
/// 监听的随机端口（由 [CoreProcessLauncher] 通过握手下发），并且每个请求都
/// 必须携带核心下发的一次性本地 token。协议形状（路径/字段/状态码）与既有
/// 后端保持一致，因此上层 UI 无需改动。
class ApiService {
  /// 核心进程基址（形如 `http://127.0.0.1:54321`）。
  ///
  /// 由 main() 在启动核心后写入；未启动时该值无意义。
  static String baseUrl = 'http://127.0.0.1:0';

  /// 当前本地 token（核心进程每次启动重新生成）
  static String? _token;

  /// 当前本地 token（供 WebSocket 与执行器服务复用）。
  static String? get token => _token;

  /// 设置全局本地 token
  ///
  /// 应用启动拿到核心握手后调用一次，之后所有请求自动携带
  /// `Authorization: Bearer <token>` 头。
  static void setToken(String? token) {
    _token = token;
  }

  /// 构造请求头
  ///
  /// 核心进程要求全部 `/api/*` 请求携带本地 token；未设置 token 时请求会
  /// 被核心以 401 拒绝（这是编程错误，正常情况下启动流程已设置好）。
  static Map<String, String> _getHeaders() {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (_token != null) {
      headers['Authorization'] = 'Bearer $_token';
    }
    return headers;
  }

  /// 从响应中提取核心进程返回的错误信息（detail 字段）
  static String _errorFromBody(http.Response response) {
    try {
      final Map<String, dynamic> data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final String? detail = data['detail'] as String?;
      if (detail != null && detail.isNotEmpty) return detail;
    } catch (_) {
      // 忽略解析失败，使用默认错误信息
    }
    return '请求失败（HTTP ${response.statusCode}）';
  }

  // ==================== 文件管理相关接口 ====================

  /// 获取工作空间指定路径下的文件列表
  ///
  /// 调用 `GET /api/files/{workspace_id}?path=xxx`，返回
  /// `{"files": [{"name", "size", "type", "modified"}]}`。
  /// [path] 为空时获取根目录列表。网络异常或后端返回错误时抛出中文异常。
  static Future<List<FileNode>> getFiles(
    String workspaceId, {
    String path = '',
    String teamId = '',
  }) async {
    final Map<String, dynamic> data = await _getJson(
      '/api/files/$workspaceId',
      query: {
        if (path.isNotEmpty) 'path': path,
        if (teamId.isNotEmpty) 'team_id': teamId,
      },
    );
    final List<dynamic> files = data['files'] as List<dynamic>? ?? [];
    return files
        .map((dynamic e) => FileNode.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取文件内容
  ///
  /// 调用 `GET /api/files/{workspace_id}/content?path=xxx`，返回
  /// `{"content", "path", "size"}`。网络异常或后端返回错误时抛出中文异常。
  static Future<String> getFileContent(
    String workspaceId,
    String path, {
    String teamId = '',
  }) async {
    final Map<String, dynamic> data = await _getJson(
      '/api/files/$workspaceId/content',
      query: {'path': path, if (teamId.isNotEmpty) 'team_id': teamId},
    );
    return data['content'] as String? ?? '';
  }

  /// 获取 PDF 文件信息（总页数、标题、作者）
  ///
  /// 调用 `GET /api/files/{workspace_id}/pdf_info?path=xxx`，返回
  /// `{"total_pages": N, "title": "...", "author": "..."}`。
  /// 网络异常或核心进程返回错误时抛出中文异常。
  static Future<Map<String, dynamic>> getPdfInfo(
    String workspaceId,
    String path, {
    String teamId = '',
  }) async {
    return _getJson(
      '/api/files/$workspaceId/pdf_info',
      query: {'path': path, if (teamId.isNotEmpty) 'team_id': teamId},
    );
  }

  // ==================== Git 相关接口 ====================

  /// 获取 Git 提交历史
  ///
  /// 调用 `GET /api/workspaces/{workspace_id}/git/log?limit=50`，返回
  /// `{"commits": [...]}`，每条提交包含 hash、message、date 等字段。
  /// 网络异常或核心进程返回错误时抛出中文异常。
  static Future<List<Map<String, dynamic>>> getGitLog(
    String workspaceId, {
    int limit = 50,
    String teamId = '',
  }) async {
    final Map<String, dynamic> data = await _getJson(
      '/api/workspaces/$workspaceId/git/log',
      query: {
        'limit': limit.toString(),
        if (teamId.isNotEmpty) 'team_id': teamId,
      },
    );
    final List<dynamic> commits = data['commits'] as List<dynamic>? ?? [];
    return commits
        .map(
          (dynamic e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
        )
        .toList();
  }

  /// 获取 Git 分支列表
  ///
  /// 调用 `GET /api/workspaces/{workspace_id}/git/branches`，返回
  /// `{"branches": [...], "current": "..."}`。
  /// 网络异常或核心进程返回错误时抛出中文异常。
  static Future<Map<String, dynamic>> getGitBranches(
    String workspaceId, {
    String teamId = '',
  }) async {
    return _getJson(
      '/api/workspaces/$workspaceId/git/branches',
      query: {if (teamId.isNotEmpty) 'team_id': teamId},
    );
  }

  // ==================== 文件同步相关接口 ====================

  /// 同步工作空间文件到本地目录
  ///
  /// 调用 `POST /api/files/{workspace_id}/syncToLocal`，请求体为
  /// `{"local_path": "...", "path": "..."}`。核心进程与前端同机，所以核心
  /// **直接复制**（保留相对层级、覆盖同名文件、排除 `.git`），不再走旧后端那套
  /// "容器内打包 → base64 → 前端解包"。
  ///
  /// [path] 是要同步的工作空间相对子树（空 = 整棵根）。文件面板是逐层懒加载的，
  /// 调用方应传**当前所在目录**，避免在巨大工作空间上拉起整棵树（M8b）。
  /// 返回 `{"success": true, "local_path": ..., "path": ..., "files": N,
  /// "bytes": N}`，供界面显示复制了多少个文件。
  static Future<Map<String, dynamic>> syncToLocal(
    String workspaceId,
    String localPath, {
    String path = '',
  }) async {
    return _postJson(
      '/api/files/$workspaceId/syncToLocal',
      body: {'local_path': localPath, if (path.isNotEmpty) 'path': path},
    );
  }

  /// **流式**下载单个文件到本地路径（M8c/M8d）：边收边写，内存占用与文件大小无关。
  ///
  /// 与 [downloadFile] 的区别：那个把整个文件读进内存再交给保存对话框，只适合小
  /// 文件；这里用 `http.Client.send` 拿到字节流，逐块写进 [savePath]。核心侧
  /// （`/download`）也已经是流式响应，所以整条链路都不设单文件大小上限。
  ///
  /// [onProgress] 回传 (已收字节, 总字节)；总长未知时为 -1。[isCancelled] 返回 true
  /// 时抛 [DownloadCancelledException]（半成品由调用方清理）。
  static Future<void> downloadFileTo(
    String workspaceId,
    String filePath,
    String savePath, {
    String teamId = '',
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final String query = teamId.isNotEmpty
        ? '?team_id=${Uri.encodeQueryComponent(teamId)}'
        : '';
    final Uri uri = Uri.parse('$baseUrl/api/files/$workspaceId/download$query');
    final http.Client client = http.Client();
    IOSink? sink;
    try {
      final http.Request request = http.Request('POST', uri)
        ..headers.addAll(_getHeaders())
        ..body = jsonEncode(<String, dynamic>{'path': filePath});
      final http.StreamedResponse response = await client.send(request);
      if (response.statusCode == 401) {
        throw Exception('核心进程拒绝了本次请求（本地 token 无效）');
      }
      if (response.statusCode != 200) {
        final String body = await response.stream.bytesToString();
        throw Exception(_errorFromText(body, response.statusCode));
      }
      final File file = File(savePath);
      await file.parent.create(recursive: true);
      sink = file.openWrite();
      int received = 0;
      final int total = response.contentLength ?? -1;
      await for (final List<int> chunk in response.stream) {
        if (isCancelled?.call() ?? false) {
          throw const DownloadCancelledException();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
      sink = null;
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // 清理路径上的异常不再往上冒：真实原因已经由上面的 throw 决定
        }
      }
      client.close();
    }
  }

  /// 从错误响应体里取 `detail`（流式响应没有 `http.Response` 可用）。
  static String _errorFromText(String body, [int statusCode = 0]) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final String? detail = decoded['detail'] as String?;
        if (detail != null && detail.isNotEmpty) return detail;
      }
    } catch (_) {
      // 解析失败就用兜底文案
    }
    return statusCode > 0 ? '请求失败（HTTP $statusCode）' : '请求失败';
  }

  /// 下载到系统临时目录并返回文件路径（PDF 预览用）。
  ///
  /// 为什么返回路径而不是字节：pdfrx 的 `PdfViewer.file` 能按文件做渐进加载，
  /// 几百 MB 的 PDF 不必先整个读进内存。调用方负责在关闭预览后删除父目录。
  static Future<String> downloadFileToTemp(
    String workspaceId,
    String filePath, {
    String teamId = '',
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final Directory dir = await Directory.systemTemp.createTemp('tree_dl_');
    final String name = filePath.split('/').last;
    final String path = '${dir.path}${Platform.pathSeparator}$name';
    await downloadFileTo(
      workspaceId,
      filePath,
      path,
      teamId: teamId,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    return path;
  }

  /// 下载文件夹（打包为 tar.gz）
  ///
  /// 调用 `POST /api/files/{workspace_id}/download_folder`，请求体为
  /// `{"path": "..."}`，返回 tar.gz 压缩包的字节数组。
  /// 目录不存在或网络异常时抛出异常。
  static Future<Uint8List> downloadFolder(
    String workspaceId,
    String folderPath, {
    String teamId = '',
  }) async {
    final String query = teamId.isNotEmpty
        ? '?team_id=${Uri.encodeQueryComponent(teamId)}'
        : '';
    final Uri uri = Uri.parse(
      '$baseUrl/api/files/$workspaceId/download_folder$query',
    );
    try {
      final http.Response response = await http.post(
        uri,
        headers: _getHeaders(),
        body: jsonEncode({'path': folderPath}),
      );
      if (response.statusCode == 401) {
        // 本地 token 无效（核心重启会换 token）：正常流程不应出现
        throw Exception('核心进程拒绝了本次请求（本地 token 无效）');
      }
      if (response.statusCode != 200) {
        throw Exception(_errorFromBody(response));
      }
      return response.bodyBytes;
    } catch (e) {
      if (e is Exception) {
        rethrow;
      }
      throw Exception('核心进程不可达，请重启应用');
    }
  }

  /// 上传本地文件到工作空间（init/chunk/complete 三段式分片）
  ///
  /// 契约（字段名与核心处理器一致）：
  /// `POST .../upload_init`（`{file_name, rel_path, total_size}` →
  /// `{upload_id, chunk_size}`）、`POST .../upload_chunk`
  /// （`{upload_id, index, data: base64}` → `{received, index}`）、
  /// `POST .../upload_complete`（`{upload_id, total_chunks}` →
  /// `{success, path, size}`）。
  ///
  /// **所有大小的文件都走这一条通道**：核心把分片顺序追加到系统临时文件，最后
  /// 整体落到 `.input/{yyyymmdd}/`，因此 multipart 那条"小文件捷径"已在 M7d-3
  /// 删除（多一条路径就多一份契约要维护，而分片通道对小文件同样够快）。
  /// [relPath] 是保留层级的相对路径（`a/b.txt`），[onProgress] 回传
  /// (已传字节, 总字节)。返回工作空间内保存路径（如
  /// `.input/20260906/a/b.txt`）。
  static Future<String> uploadFileChunked(
    String workspaceId,
    String filePath,
    String relPath, {
    String teamId = '',
    void Function(int sent, int total)? onProgress,
  }) async {
    final Map<String, String> query = <String, String>{
      if (teamId.isNotEmpty) 'team_id': teamId,
    };
    final File file = File(filePath);
    final int total = await file.length();

    // ① init：建立分片会话，服务端定标 chunk_size
    final Map<String, dynamic> initData = await _postJson(
      '/api/files/$workspaceId/upload_init',
      query: query,
      body: <String, dynamic>{
        'file_name': relPath.split('/').last,
        'rel_path': relPath.contains('/')
            ? relPath.substring(0, relPath.lastIndexOf('/'))
            : '',
        'total_size': total,
      },
    );
    final String uploadId = initData['upload_id'] as String? ?? '';
    final int chunkSize =
        (initData['chunk_size'] as num?)?.toInt() ?? 4 * 1024 * 1024;
    if (uploadId.isEmpty) {
      throw Exception('上传失败：初始化分片会话未返回 upload_id');
    }

    // ② chunk：按分片逐个上传（base64）
    final RandomAccessFile raf = await file.open();
    int index = 0;
    int sent = 0;
    try {
      while (sent < total) {
        final Uint8List chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) break;
        await _postJson(
          '/api/files/$workspaceId/upload_chunk',
          query: query,
          body: <String, dynamic>{
            'upload_id': uploadId,
            'index': index,
            'data': base64Encode(chunk),
          },
        );
        index++;
        sent += chunk.length;
        onProgress?.call(sent, total);
      }
    } finally {
      await raf.close();
    }

    // ③ complete：组装文件
    final Map<String, dynamic> done = await _postJson(
      '/api/files/$workspaceId/upload_complete',
      query: query,
      body: <String, dynamic>{'upload_id': uploadId, 'total_chunks': index},
    );
    if (done['success'] != true) {
      throw Exception('上传失败：${done['detail'] ?? done['path'] ?? '未知错误'}');
    }
    return done['path'] as String? ?? '';
  }

  /// 拉取指定 agent/会话的对话历史
  ///
  /// 调用 `GET /api/conversations/{agent_id}?session_id=xxx`，返回
  /// `{"agent_id": "...", "session_id": "...", "messages": [...]}`。
  /// [sessionId] 缺省为默认会话；传 `"all"` 时返回该 agent 全部会话的消息。
  /// 网络异常或核心进程返回错误时抛出中文异常。
  static Future<List<Map<String, dynamic>>> getConversationHistory(
    String agentId, {
    String sessionId = 'session_default',
  }) async {
    final Map<String, dynamic> data = await _getJson(
      '/api/conversations/$agentId',
      query: {'session_id': sessionId},
    );
    final List<dynamic> messages = data['messages'] as List<dynamic>? ?? [];
    return messages
        .map(
          (dynamic e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
        )
        .toList();
  }

  /// 清空指定 agent/会话的对话历史
  ///
  /// 调用 `DELETE /api/conversations/{agent_id}?session_id=xxx`，返回
  /// `{"success": true, "deleted": N}`。
  /// 传 "all" 可清空当前用户所有 agent 的历史；[sessionId] 为空时清空该
  /// agent 全部会话。
  /// 网络异常或核心进程返回错误时抛出中文异常。
  static Future<int> clearConversationHistory(
    String agentId, {
    String? sessionId,
  }) async {
    final String query = (sessionId != null && sessionId.isNotEmpty)
        ? '?session_id=${Uri.encodeQueryComponent(sessionId)}'
        : '';
    final Uri uri = Uri.parse('$baseUrl/api/conversations/$agentId$query');
    try {
      final http.Response response = await http.delete(
        uri,
        headers: _getHeaders(),
      );
      if (response.statusCode != 200) {
        throw Exception('清空对话失败（HTTP ${response.statusCode}）');
      }
      final Map<String, dynamic> data = _parseJson(response.body);
      return (data['deleted'] as int?) ?? 0;
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('核心进程不可达，请重启应用');
    }
  }

  // ==================== Agent 与模型池接口 ====================

  /// 获取模型池中的具体模型列表
  ///
  /// 调用 `GET /api/models`，返回 `{"models": [{"model_id", "name", "max_seqlen"}]}`。
  static Future<List<Map<String, dynamic>>> getModels() async {
    final Map<String, dynamic> data = await _getJson('/api/models');
    final List<dynamic> models = data['models'] as List<dynamic>? ?? [];
    return models
        .map(
          (dynamic e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
        )
        .toList();
  }

  /// 获取当前用户的 agent 列表
  ///
  /// 调用 `GET /api/agents`，返回 `{"agents": [...]}`。
  static Future<List<Agent>> getAgents() async {
    final Map<String, dynamic> data = await _getJson('/api/agents');
    final List<dynamic> agents = data['agents'] as List<dynamic>? ?? [];
    return agents
        .map((dynamic e) => Agent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 创建一个 agent 并持久化到后端
  ///
  /// 调用 `POST /api/agents`，请求体为
  /// `{"name", "model_id", "system_prompt", "team_member_count"?,
  ///  "max_level"?, "max_members_per_level"?}`。
  /// 成功后返回后端生成的完整 Agent 对象（含真实 id）。
  ///
  /// 团队配置（maxLevel / maxMembersPerLevel）在创建 TOP 时一次性设定，
  /// 创建后不可修改（成员只增不减）；teamMemberCount 为初始预建成员数
  /// （不填则按每层成员上限全量预建，P4 建队）。
  static Future<Agent> createAgent({
    required String name,
    required String modelId,
    String systemPrompt = '',
    int? teamMemberCount,
    int? maxLevel,
    int? maxMembersPerLevel,
  }) async {
    final Map<String, dynamic> data = await _postJson(
      '/api/agents',
      body: {
        'name': name,
        'model_id': modelId,
        'system_prompt': systemPrompt,
        if (teamMemberCount != null && teamMemberCount > 0)
          'team_member_count': teamMemberCount,
        if (maxLevel != null && maxLevel > 0) 'max_level': maxLevel,
        if (maxMembersPerLevel != null && maxMembersPerLevel > 0)
          'max_members_per_level': maxMembersPerLevel,
      },
    );
    return Agent.fromJson(data['agent'] as Map<String, dynamic>);
  }

  /// 删除一个 agent（连同其对话历史）
  ///
  /// 调用 `DELETE /api/agents/{id}`。
  static Future<void> deleteAgent(String agentId) async {
    final Uri uri = Uri.parse('$baseUrl/api/agents/$agentId');
    try {
      final http.Response response = await http.delete(
        uri,
        headers: _getHeaders(),
      );
      if (response.statusCode != 200) {
        throw Exception('删除失败（HTTP ${response.statusCode}）');
      }
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('核心进程不可达，请重启应用');
    }
  }

  /// 修改 agent 的模型、系统提示词或模型参数覆盖（右栏「模型信息」页使用）
  ///
  /// 调用 `PATCH /api/agents/{id}`，只传需要修改的字段。
  ///
  /// 模型参数覆盖语义（与后端 `UpdateAgentRequest` 对齐）：
  /// - 传 `null` = **不修改**（保留库中原值）；
  /// - [clearOverrides] 为 true = 一次性清除全部覆盖，回退模型默认值。
  /// 因此单个字段无法"单独清空"，需要清空时用 [clearOverrides] 整体重置。
  static Future<Map<String, dynamic>> updateAgent(
    String agentId, {
    String? modelId,
    String? systemPrompt,
    String? reasoningEffort,
    int? maxSeqlen,
    int? maxOutputTokens,
    double? compressThreshold,
    bool? thinking,
    bool clearThinking = false,
    bool clearOverrides = false,
    String? workspaceDir,
    Map<String, dynamic>? ssh,
    bool clearSsh = false,
  }) async {
    return _patchJson(
      '/api/agents/$agentId',
      body: {
        if (modelId != null && modelId.isNotEmpty) 'model_id': modelId,
        'system_prompt': ?systemPrompt,
        if (reasoningEffort != null && reasoningEffort.isNotEmpty)
          'reasoning_effort': reasoningEffort,
        'max_seqlen': ?maxSeqlen,
        'max_output_tokens': ?maxOutputTokens,
        'compress_threshold': ?compressThreshold,
        // 三态覆盖：下 true/false = 覆盖；[clearThinking] = 显式清除（回退模型默认）。
        // 不能只靠 'thinking': ?thinking —— null 会被省略，等于"不修改"。
        if (clearThinking) 'thinking': null,
        'thinking': ?thinking,
        if (clearOverrides) 'clear_model_overrides': true,
        'workspace_dir': ?workspaceDir,
        'ssh': ?ssh,
        if (clearSsh) 'ssh': null,
      },
    );
  }

  /// 获取单个 agent 的完整配置（含 SSH 的非机密字段与工作目录）。
  ///
  /// 调用 `GET /api/agents/{id}`，返回 `{"agent": {...}, "ssh": {...}?}`。
  /// 说明：桌面端「运行模式」不再由前端执行器承载，而是这份配置（核心据此决定
  /// 工具在哪跑）。
  static Future<Map<String, dynamic>> getAgent(String agentId) async {
    return _getJson('/api/agents/$agentId');
  }

  /// 获取 agent 的可用模型池与当前模型信息（右栏「模型信息」页使用）
  ///
  /// 调用 `GET /api/agents/{id}/models-info`，返回
  /// `{"models": [{"model_id","name","max_seqlen","thinking","if_vision","base_url"}], "current": {...}}`。
  /// 网络异常或核心进程返回错误时抛出中文异常。
  static Future<Map<String, dynamic>> getAgentModelsInfo(String agentId) async {
    return _getJson('/api/agents/$agentId/models-info');
  }

  // ==================== 自定义模型管理（设置页） ====================

  /// 新增自定义模型
  ///
  /// 调用 `POST /api/models`，写入 `~/.tree/config/models/<model_id>.yaml`。
  /// 后端返回 `{success, model}`，`model` 内**不含** api_key。
  static Future<Map<String, dynamic>> createModel(
    Map<String, dynamic> payload,
  ) async {
    return _postJson('/api/models', body: payload);
  }

  /// 更新自定义模型
  ///
  /// 调用 `PATCH /api/models/{model_id}`。`api_key` 留空 = 不修改（保留原密钥）。
  static Future<Map<String, dynamic>> updateModel(
    String modelId,
    Map<String, dynamic> payload,
  ) async {
    return _patchJson(
      '/api/models/${Uri.encodeComponent(modelId)}',
      body: payload,
    );
  }

  /// 删除自定义模型
  ///
  /// 调用 `DELETE /api/models/{model_id}`。返回体含 `bound_agents`，供提示
  /// "仍有 agent 绑定该模型"。
  static Future<Map<String, dynamic>> deleteModel(String modelId) async {
    return _deleteJson('/api/models/${Uri.encodeComponent(modelId)}');
  }

  // ==================== 流式帧率（token 获取 + 推送刷新，均常开） ====================

  /// 查询推送刷新帧率设置
  ///
  /// 调用 `GET /api/settings/frame-rate`，返回 `{frame_rate, min, max}`。
  /// 该帧率把同一轮回复内的流式增量攒帧后合并下发（常开，无开关）。
  static Future<Map<String, dynamic>> getFrameRate() async {
    return _getJson('/api/settings/frame-rate');
  }

  /// 设置推送刷新帧率（帧/秒，越界由后端夹到 20~1000）
  ///
  /// 调用 `POST /api/settings/frame-rate`，管流式增量的合并下发频率。
  static Future<int> setFrameRate(int frameRate) async {
    final Map<String, dynamic> data = await _postJson(
      '/api/settings/frame-rate',
      body: <String, dynamic>{'frame_rate': frameRate},
    );
    return (data['frame_rate'] as num?)?.toInt() ?? frameRate;
  }

  /// 查询 token 获取帧率设置
  ///
  /// 调用 `GET /api/settings/token-rate`，返回 `{token_rate, min, max}`。
  /// 该帧率控制从 LLM 流逐 token 取回复的节奏（常开，无开关）。
  static Future<Map<String, dynamic>> getTokenRate() async {
    return _getJson('/api/settings/token-rate');
  }

  /// 设置 token 获取帧率（帧/秒，越界由后端夹到 20~1000）
  ///
  /// 调用 `POST /api/settings/token-rate`。
  static Future<int> setTokenRate(int tokenRate) async {
    final Map<String, dynamic> data = await _postJson(
      '/api/settings/token-rate',
      body: <String, dynamic>{'token_rate': tokenRate},
    );
    return (data['token_rate'] as num?)?.toInt() ?? tokenRate;
  }

  // ==================== 心跳判活参数（M9 1.1：I × N） ====================

  /// 查询心跳判活参数（心跳间隔 I 秒 + 丢失阈值 N 次）
  ///
  /// 调用 `GET /api/settings/heartbeat-interval`，返回：
  /// `{heartbeat_interval, missed_heartbeat_limit, min, max, window_seconds,
  /// min_window_seconds, live_interval_seconds, live_miss_limit}`；
  /// 真发生夹取时多一个 `notice`（可直接显示给用户的原因）。
  ///
  /// 两个参数是一体的（判活窗口 = I×N），所以两个端点的响应同形状——前端只读
  /// 这一个就够；写也一样（见 [setHeartbeatLivenessSettings]）。
  static Future<Map<String, dynamic>> getHeartbeatLivenessSettings() async {
    return _getJson('/api/settings/heartbeat-interval');
  }

  /// 写入心跳判活参数（两个字段可一起给；没给的字段保持原值）
  ///
  /// 调用 `PATCH /api/settings/heartbeat-interval`（核心的另一个端点
  /// `/api/settings/missed-heartbeat-limit` 与它同形状、同语义，供只改 N 的调用方
  /// 使用）。用 PATCH 是因为语义是**部分更新**（只改请求体里出现的字段），与帧率
  /// 那两个 POST 端点的"整体覆盖"不同。
  ///
  /// 后端夹取（不报错，永远返回生效值）：① 各自夹到绝对区间；② 判活窗口 I×N
  /// 必须**严格大于**前端固定的 10s WS 心跳（见 lib/io/websocket_service.dart 的
  /// 心跳定时器，本页不可调），不足时抬高 I。调用方应当把响应里的 `notice`
  /// （若有）显示给用户——那是"为什么我填的值没生效"的唯一可读解释。
  static Future<Map<String, dynamic>> setHeartbeatLivenessSettings({
    int? heartbeatIntervalSeconds,
    int? missedHeartbeatLimit,
  }) async {
    return _patchJson(
      '/api/settings/heartbeat-interval',
      body: <String, dynamic>{
        'heartbeat_interval': ?heartbeatIntervalSeconds,
        'missed_heartbeat_limit': ?missedHeartbeatLimit,
      },
    );
  }

  // ==================== 插件体系接口（右栏「插件」页） ====================

  /// 获取插件体系只读快照（右栏「插件」面板数据源）
  ///
  /// 调用 `GET /api/plugin/snapshot`（可选 `team_id` 过滤；user 由 token 归属）。
  /// 返回结构见契约 v1.3 §15.1（instances / stations / watchdog / config）；
  /// 总开关关闭时后端仍返回 200 + `enabled: false`（空集）。
  /// 前端对响应做宽容解析（缺字段/未知字段容忍），此处不做校验。
  /// 网络异常或核心进程返回错误时抛出中文异常。
  static Future<Map<String, dynamic>> getPluginSnapshot({
    String? teamId,
  }) async {
    return _getJson(
      '/api/plugin/snapshot',
      query: <String, String>{
        if (teamId != null && teamId.isNotEmpty) 'team_id': teamId,
      },
    );
  }

  /// 读取插件清单（**持久态**）与每条的运行态：GET /api/plugin/configs
  ///
  /// 返回 {path, enabled, configs, runtime}：
  /// - configs 是 plugins.yaml 里真实写着的条目（含 env / scope / builtin 标记），
  ///   编辑弹窗的回填就以它为准；
  /// - runtime 按 id 给运行态（running / health / reason / error / known）。
  ///
  /// 与 [getPluginSnapshot] 的分工：快照给**运行态**（实例 / 站点 / 心跳健康度），
  /// 这里给"文件里到底写了什么"。刚保存的开关状态**以这里为准**——插件总线的配置
  /// 是启动时读一次进内存的，运行期不重读，所以快照会滞后到下次重启核心。
  static Future<Map<String, dynamic>> getPluginConfigs() async {
    return _getJson('/api/plugin/configs');
  }

  /// 新增一个自定义插件：POST /api/plugin/configs
  ///
  /// 返回值里的 notice **必须**显示给用户：热应用现在走总线对账（applyConfigs），
  /// 正常情况下写入即生效；只有对账失败（启动失败、YAML 读不动等）才会是
  /// 「配置已保存，但本次热应用失败，重启核心后生效」——不显示就等于骗用户
  /// "已经生效了"。
  static Future<Map<String, dynamic>> createPluginConfig({
    required String id,
    required String name,
    required String command,
    List<String> args = const <String>[],
    Map<String, String> env = const <String, String>{},
    String granularity = 'team',
    Map<String, String> scope = const <String, String>{},
    bool enabled = true,
  }) async {
    return _postJson(
      '/api/plugin/configs',
      body: <String, dynamic>{
        'id': id,
        'name': name,
        'command': command,
        'args': args,
        'env': env,
        'enabled': enabled,
        'granularity': granularity,
        'scope': scope,
      },
    );
  }

  /// 局部更新一个插件（开关、编辑都走这里）：PATCH /api/plugin/configs/{id}
  ///
  /// [patch] 只放要改的字段（例如开关只发一个 enabled）。
  static Future<Map<String, dynamic>> updatePluginConfig(
    String id,
    Map<String, dynamic> patch,
  ) async {
    // 先编码再拼串：id 允许的字符集由核心校验，但 URL 里仍要转义（防御式）
    final String encoded = Uri.encodeComponent(id);
    return _patchJson('/api/plugin/configs/$encoded', body: patch);
  }

  /// 删除一个自定义插件：DELETE /api/plugin/configs/{id}
  static Future<Map<String, dynamic>> deletePluginConfig(String id) async {
    final String encoded = Uri.encodeComponent(id);
    return _deleteJson('/api/plugin/configs/$encoded');
  }

  /// 显式重启一个插件实例：POST /api/plugin/configs/{id}/restart
  ///
  /// 这是唯一真正作用到运行中总线上的操作（心跳 degraded 之后手动恢复用）。
  static Future<Map<String, dynamic>> restartPluginConfig(String id) async {
    final String encoded = Uri.encodeComponent(id);
    return _postJson('/api/plugin/configs/$encoded/restart');
  }

  /// 内置插件目录：GET /api/plugin/builtins
  ///
  /// 返回 {path, builtins: [...]}，每项含 id / 名称 / 说明 / 默认粒度与 scope /
  /// 启用态 / 落盘条目（config，未启用过为 null）/ 运行时解析结果（resolution）。
  /// [refresh] = 强制核心重探运行时（用户刚装好 Python 时用）。
  static Future<Map<String, dynamic>> getPluginBuiltins({
    bool refresh = false,
  }) async {
    return _getJson(
      '/api/plugin/builtins',
      query: <String, String>{if (refresh) 'refresh': '1'},
    );
  }

  /// 打开 / 关闭一个内置插件（**每项各自一个开关**，没有批量开关）
  ///
  /// - 打开：POST /api/plugin/builtins/{id}/enable —— 核心解析运行时与脚本，
  ///   写成一条普通插件配置（带 builtin 标记）再热启动；运行时 / 脚本缺失时
  ///   核心回**可读 400**（如「未检测到 Python，请先安装或改用自定义命令」）；
  /// - 关闭：POST /api/plugin/builtins/{id}/disable —— 条目置 enabled:false 并保留
  ///   （面板显示「已停用」而不是让它消失）。
  static Future<Map<String, dynamic>> setBuiltinPluginEnabled(
    String id, {
    required bool enabled,
  }) async {
    final String encoded = Uri.encodeComponent(id);
    return _postJson(
      '/api/plugin/builtins/$encoded/${enabled ? 'enable' : 'disable'}',
    );
  }

  // ==================== MCP 服务管理接口（右栏 MCP 配置页） ====================

  /// 列出已注册的 MCP 服务
  ///
  /// 调用 `GET /api/mcp/services`，返回 `{"services": [{"name","command","args","builtin","enabled"}]}`。
  /// 网络异常或核心进程返回错误时抛出中文异常。
  static Future<List<Map<String, dynamic>>> getMcpServices() async {
    final Map<String, dynamic> data = await _getJson('/api/mcp/services');
    final List<dynamic> services = data['services'] as List<dynamic>? ?? [];
    return services
        .map(
          (dynamic e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
        )
        .toList();
  }

  /// 注册一个 MCP 服务（stdio 子进程 / Streamable HTTP 单端点）
  ///
  /// 调用 `POST /api/mcp/services`。`transport` 取 ``stdio``（缺省，兼容旧行为）或 ``http``：
  /// - `stdio`：`command` / `args` / `env` 生效（本机子进程，逐行 JSON-RPC）；
  /// - `http`：`url` / `headers` 生效（Streamable HTTP 单端点；`headers` 用于 `Authorization`
  ///   之类的鉴权，与 `env` 同为 KEY=VALUE 文本编辑）。
  ///
  /// `scope` 取 ``""``/``server``/``local``/``ssh``，空串表示按当前会话模式自动落点。
  /// 网络异常或核心进程返回错误时抛出中文异常。
  static Future<Map<String, dynamic>> registerMcpService({
    required String name,
    String transport = 'stdio',
    String command = '',
    List<String> args = const [],
    String url = '',
    Map<String, String> headers = const <String, String>{},
    String scope = '',
    Map<String, String> env = const <String, String>{},
  }) async {
    return _postJson(
      '/api/mcp/services',
      body: {
        'name': name,
        'transport': transport,
        'command': command,
        'args': args,
        'url': url,
        'headers': headers,
        'scope': scope,
        'env': env,
      },
    );
  }

  /// 删除一个 MCP 服务
  ///
  /// 调用 `DELETE /api/mcp/services/{name}`。
  /// 网络异常或核心进程返回错误时抛出中文异常。
  static Future<void> deleteMcpService(String name) async {
    final Uri uri = Uri.parse(
      '$baseUrl/api/mcp/services/${Uri.encodeComponent(name)}',
    );
    try {
      final http.Response response = await http.delete(
        uri,
        headers: _getHeaders(),
      );
      if (response.statusCode != 200) {
        throw Exception(_errorFromBody(response));
      }
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('核心进程不可达，请重启应用');
    }
  }

  /// 手动压缩 normal LLM 的上下文（compact 按钮触发）
  ///
  /// 调用 `POST /api/agents/{agentId}/compact`（请求体带 session_id）。
  /// 返回是否实际压缩及压缩后上下文大小；无限上下文 LLM 无操作
  /// （compressed=false）。
  static Future<Map<String, dynamic>> compactAgent(
    String agentId, {
    String sessionId = 'session_default',
  }) async {
    final Uri uri = Uri.parse('$baseUrl/api/agents/$agentId/compact');
    try {
      final http.Response response = await http.post(
        uri,
        headers: _getHeaders(),
        body: jsonEncode({'session_id': sessionId}),
      );
      if (response.statusCode != 200) {
        throw Exception('压缩失败（HTTP ${response.statusCode}）');
      }
      return jsonDecode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('核心进程不可达，请重启应用');
    }
  }

  // ==================== 多会话管理接口（P2） ====================

  /// 列出指定 agent 的全部会话
  ///
  /// 调用 `GET /api/agents/{agentId}/sessions`，返回
  /// `{"agent_id": "...", "sessions": [...]}`。
  static Future<List<ChatSession>> getSessions(String agentId) async {
    final Map<String, dynamic> data = await _getJson(
      '/api/agents/$agentId/sessions',
    );
    final List<dynamic> sessions = data['sessions'] as List<dynamic>? ?? [];
    return sessions
        .map((dynamic e) => ChatSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 新建一个会话（可选 title）
  ///
  /// 调用 `POST /api/agents/{agentId}/sessions`，返回 `{"session": {...}}`。
  static Future<ChatSession> createSession(
    String agentId, {
    String title = '',
    String? sessionId,
  }) async {
    final Map<String, dynamic> data = await _postJson(
      '/api/agents/$agentId/sessions',
      body: {
        'title': title,
        if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      },
    );
    return ChatSession.fromJson(data['session'] as Map<String, dynamic>);
  }

  /// 查询单个会话详情（元数据 + 对话历史）
  ///
  /// 调用 `GET /api/agents/{agentId}/sessions/{sessionId}`，返回
  /// `{"session": {...}}`。
  static Future<Map<String, dynamic>> getSessionDetail(
    String agentId,
    String sessionId,
  ) async {
    return _getJson('/api/agents/$agentId/sessions/$sessionId');
  }

  /// 重命名会话标题
  ///
  /// 调用 `PATCH /api/agents/{agentId}/sessions/{sessionId}`，
  /// 请求体为 `{"title": "..."}`。
  static Future<void> renameSession(
    String agentId,
    String sessionId,
    String title,
  ) async {
    await _patchJson(
      '/api/agents/$agentId/sessions/$sessionId',
      body: {'title': title},
    );
  }

  /// 删除会话（元数据 + 消息 + 上下文）
  ///
  /// 调用 `DELETE /api/agents/{agentId}/sessions/{sessionId}`。
  static Future<void> deleteSession(String agentId, String sessionId) async {
    final Uri uri = Uri.parse(
      '$baseUrl/api/agents/$agentId/sessions/$sessionId',
    );
    try {
      final http.Response response = await http.delete(
        uri,
        headers: _getHeaders(),
      );
      if (response.statusCode != 200) {
        throw Exception('删除会话失败（HTTP ${response.statusCode}）');
      }
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('核心进程不可达，请重启应用');
    }
  }

  /// 设置会话选中的 Spec（多选挂 hook，P4-spec 使用）
  ///
  /// 调用 `POST /api/agents/{agentId}/sessions/{sessionId}/specs`，
  /// 请求体为 `{"spec_ids": [...]}`。
  static Future<List<String>> setSessionSpecs(
    String agentId,
    String sessionId,
    List<String> specIds,
  ) async {
    final Map<String, dynamic> data = await _postJson(
      '/api/agents/$agentId/sessions/$sessionId/specs',
      body: {'spec_ids': specIds},
    );
    final List<dynamic> raw = data['selected_spec_ids'] as List<dynamic>? ?? [];
    return raw.map((dynamic e) => e.toString()).toList();
  }

  /// 拉取某 agent 的 Spec 索引列表 + 会话已选 Spec（P4-spec）
  ///
  /// 调用 `GET /api/agents/{agentId}/specs?session_id=xxx`，返回
  /// `{"specs": [...], "selected_spec_ids": [...]}`。
  static Future<Map<String, dynamic>> listAgentSpecs(
    String agentId, {
    String sessionId = '',
  }) async {
    return _getJson(
      '/api/agents/$agentId/specs',
      query: {if (sessionId.isNotEmpty) 'session_id': sessionId},
    );
  }

  /// 获取单个 Spec 详情（元数据 + 全文）
  ///
  /// 调用 `GET /api/agents/{agentId}/specs/{specId}`，返回
  /// `{"meta": {...}, "content": "markdown..."}`。
  static Future<Map<String, dynamic>> getSpecDetail(
    String agentId,
    String specId,
  ) async {
    return _getJson('/api/agents/$agentId/specs/$specId');
  }

  /// 拉取某 agent 的团队成员拓扑（teammates 工作进度窗口）
  ///
  /// 返回体含 `members` 与 `pending_member_count`（等待用户处理的成员数，
  /// 未分配模型 / 待审核）。只取成员列表的兼容入口见 [getTeammates]。
  static Future<Map<String, dynamic>> getTeammatesPayload(
    String agentId,
  ) async {
    return _getJson('/api/agents/$agentId/teammates');
  }

  /// 拉取某 agent 的团队成员列表（兼容入口：只要 `members`）
  static Future<List<Map<String, dynamic>>> getTeammates(String agentId) async {
    final Map<String, dynamic> data = await getTeammatesPayload(agentId);
    final List<dynamic>? members = data['members'] as List<dynamic>?;
    return members
            ?.map(
              (dynamic e) =>
                  (e as Map<String, dynamic>).cast<String, dynamic>(),
            )
            .toList() ??
        <Map<String, dynamic>>[];
  }

  /// 为用户分配成员模型 / 审核成员 / 调整成员级模型参数
  ///
  /// 调用 `PATCH /api/agents/{leaderId}/teammate/{memberId}`。
  /// 各参数为 null 表示不改该项；`modelId` 传空串 = 清空模型
  /// （成员退回未分配状态，无法工作）。
  ///
  /// [sessionId] 为当前会话 id：审核通过后后端补投的成员初始化消息按该会话
  /// 归集（不传则落到默认会话，成员进度不会出现在当前 teammates 窗口）。
  ///
  /// [overrides] 支持四个键：`reasoning_effort` / `max_seqlen` /
  /// `max_output_tokens` / `compress_threshold`；**值为 null 表示清除该项覆盖**
  /// （回退 TOP 设置），键缺省表示不修改。只提交用户改过的键即可。
  static Future<Map<String, dynamic>> updateTeammate(
    String leaderId,
    String memberId, {
    String? modelId,
    String? reviewStatus,
    Map<String, Object?>? overrides,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{};
    if (modelId != null) body['model_id'] = modelId;
    if (reviewStatus != null) body['review_status'] = reviewStatus;
    if (overrides != null) {
      overrides.forEach((String key, Object? value) {
        body[key] = value;
      });
    }
    return _patchJson('/api/agents/$leaderId/teammate/$memberId', body: body);
  }

  /// 按 user_id + agent_id + session_id 查询该 agent 当前会话的追加 todos
  static Future<List<Map<String, dynamic>>> getAgentTodos(
    String agentId, {
    String sessionId = 'session_default',
  }) async {
    final Map<String, dynamic> data = await _getJson(
      '/api/agents/$agentId/todos',
      query: {'session_id': sessionId},
    );
    final List<dynamic>? todos = data['todos'] as List<dynamic>?;
    return todos
            ?.map(
              (dynamic e) =>
                  (e as Map<String, dynamic>).cast<String, dynamic>(),
            )
            .toList() ??
        <Map<String, dynamic>>[];
  }

  /// 读取成员工作空间的活动日志
  ///
  /// 注意：成员进度详情页的「日志」Tab 已移除（用户侧更需要的是赋模型入口），
  /// 成员日志现由 leader agent 直接 read/grep 共享工作目录。本方法保留供排查
  /// 问题与后续复用，当前无 UI 调用方。
  static Future<String> getTeammateLog(
    String memberId, {
    int lines = 60,
  }) async {
    final Map<String, dynamic> data = await _getJson(
      '/api/agents/$memberId/teammate/$memberId/log',
      query: {'lines': '$lines'},
    );
    return (data['log'] as String?) ?? '';
  }

  /// 用户直接向团队成员发送消息
  static Future<Map<String, dynamic>> sendTeammateMessage(
    String leaderId,
    String memberId,
    String content, {
    String? sessionId,
  }) async {
    return _postJson(
      '/api/agents/$leaderId/teammate/$memberId/message',
      body: {
        'content': content,
        // 会话隔离：携带当前会话 id，避免成员消息串入默认会话
        if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      },
    );
  }

  /// 列出当前用户的提问（可选按会话过滤），供右侧「问题回复」页使用。
  ///
  /// ``sessionId`` 为空时返回全部提问（含各 agent 与成员提问）。
  static Future<List<Map<String, dynamic>>> getQuestions({
    String? sessionId,
  }) async {
    final Map<String, dynamic> data = await _getJson(
      '/api/questions',
      query: (sessionId != null && sessionId.isNotEmpty)
          ? {'session_id': sessionId}
          : null,
    );
    final List<dynamic>? questions = data['questions'] as List<dynamic>?;
    return questions
            ?.map(
              (dynamic e) =>
                  (e as Map<String, dynamic>).cast<String, dynamic>(),
            )
            .toList() ??
        <Map<String, dynamic>>[];
  }

  /// 回答某条待答提问（REST 入口，与 WS user_answer 等价）。
  static Future<void> answerQuestion(String qid, String answer) async {
    await _postJson('/api/questions/$qid/answer', body: {'answer': answer});
  }

  /// 一键重置 agent 工作空间里的系统提示词 / Spec。
  ///
  /// 调用 `POST /api/agents/{id}/reset`，请求体 `{"target": "system_prompt"|"spec"|"all"}`。
  /// 核心会先备份现有文件为 `.bak.<n>`，再写回默认内容；工作空间不可用时回可读错误。
  static Future<Map<String, dynamic>> resetAgentWorkspace(
    String agentId, {
    String target = 'all',
  }) async {
    return _postJson('/api/agents/$agentId/reset', body: {'target': target});
  }

  /// 设置消息切入模式
  ///
  /// `direct=true` 直接切入：新消息一次性全部切入当前上下文，几乎同时到达的
  /// 消息一起处理；`false` 串行排队（默认）。调用
  /// `POST /api/settings/message-cutin`，请求体为 `{"mode": "direct"/"queue"}`。
  static Future<void> setMessageCutinDirect(bool direct) async {
    await _postJson(
      '/api/settings/message-cutin',
      body: {'mode': direct ? 'direct' : 'queue'},
    );
  }

  /// 查询消息切入模式：true=直接切入，false=串行排队
  ///
  /// 调用 `GET /api/settings/message-cutin`，返回 `{"mode": "queue"|"direct"}`。
  static Future<bool> getMessageCutinDirect() async {
    final Map<String, dynamic> data = await _getJson(
      '/api/settings/message-cutin',
    );
    return (data['mode'] as String?) == 'direct';
  }

  // ==================== 内部工具方法 ====================

  /// 发送 GET 请求并解析 JSON 响应
  ///
  /// [path] 为接口路径（以 / 开头），[query] 为查询参数。
  /// 非 200 状态码或 501 时抛出对应中文异常。
  static Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final Uri uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    try {
      final http.Response response = await http.get(
        uri,
        headers: _getHeaders(),
      );
      return _handleResponse(response);
    } catch (e) {
      if (e is Exception) {
        rethrow;
      }
      throw Exception('核心进程不可达，请重启应用');
    }
  }

  /// 发送 POST 请求并解析 JSON 响应
  ///
  /// [path] 为接口路径（以 / 开头），[body] 为请求体，[query] 为可选查询参数
  /// （如 team_id 等三模式判定键）。
  /// 非 200 状态码或 501 时抛出对应中文异常。
  static Future<Map<String, dynamic>> _postJson(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final Uri uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    try {
      final http.Response response = await http.post(
        uri,
        headers: _getHeaders(),
        body: body != null ? jsonEncode(body) : null,
      );
      return _handleResponse(response);
    } catch (e) {
      if (e is Exception) {
        rethrow;
      }
      throw Exception('核心进程不可达，请重启应用');
    }
  }

  /// 发送 PATCH 请求并解析 JSON 响应
  ///
  /// [path] 为接口路径（以 / 开头），[body] 为请求体。
  /// 非 200 状态码时抛出对应中文异常。
  static Future<Map<String, dynamic>> _patchJson(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final Uri uri = Uri.parse('$baseUrl$path');
    try {
      final http.Response response = await http.patch(
        uri,
        headers: _getHeaders(),
        body: body != null ? jsonEncode(body) : null,
      );
      return _handleResponse(response);
    } catch (e) {
      if (e is Exception) {
        rethrow;
      }
      throw Exception('核心进程不可达，请重启应用');
    }
  }

  /// 发送 DELETE 请求并解析 JSON 响应
  ///
  /// [path] 为接口路径（以 / 开头）。复用 [_handleResponse] 的状态码处理
  /// （401 清 token 跳登录、非 200 抛中文异常），避免各处手写重复逻辑。
  static Future<Map<String, dynamic>> _deleteJson(String path) async {
    final Uri uri = Uri.parse('$baseUrl$path');
    try {
      final http.Response response = await http.delete(
        uri,
        headers: _getHeaders(),
      );
      return _handleResponse(response);
    } catch (e) {
      if (e is Exception) {
        rethrow;
      }
      throw Exception('核心进程不可达，请重启应用');
    }
  }

  /// 统一处理响应状态码
  ///
  /// - 401：本地 token 无效（核心进程重启会换 token）
  /// - 501：该能力尚未在核心进程实现（迁移期里程碑的显式标记）
  /// - 非 200：抛出 HTTP 状态码异常
  /// - 200：解析 JSON 响应体（强制 UTF-8 解码，避免中文乱码）
  static Map<String, dynamic> _handleResponse(http.Response response) {
    if (response.statusCode == 401) {
      // 桌面分支没有账号体系：401 只可能是本地 token 不对（例如应用连上了
      // 上一轮遗留的核心实例）。**不清 token、不跳登录页**，只报错。
      throw Exception('核心进程拒绝了本次请求（本地 token 无效）');
    }
    if (response.statusCode == 501) {
      throw Exception('功能开发中');
    }
    if (response.statusCode != 200) {
      throw Exception(_errorFromBody(response));
    }
    // 核心进程的 Content-Type 为 application/json（无 charset），
    // http 包默认按 latin-1 解码导致中文乱码，这里强制 UTF-8。
    final String body = utf8.decode(response.bodyBytes);
    return _parseJson(body);
  }

  /// 解析响应体为 JSON Map
  ///
  /// 响应体非合法 JSON 时抛出中文异常。
  static Map<String, dynamic> _parseJson(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      throw Exception('解析核心进程响应失败');
    }
  }
}
