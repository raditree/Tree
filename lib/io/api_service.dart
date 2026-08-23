import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../ui/models/agent.dart';
import '../ui/models/file_node.dart';
import '../ui/models/session.dart';
import 'auth_service.dart';

/// API 服务 - 封装后端 REST API 调用
///
/// 统一管理对后端（FastAPI）的 HTTP 请求，包括微信扫码登录、
/// 文件管理、Git 历史等接口。网络错误或非 200 状态码时抛出中文异常，
/// 便于在 UI 上直接展示。
class ApiService {
  /// 后端服务地址
  static String baseUrl = 'http://localhost:8000';

  /// 平台默认后端主机名
  ///
  /// - Android 模拟器通过 ``10.0.2.2`` 访问宿主机（localhost 指模拟器自身）
  /// - 其余平台（Windows / Linux / macOS / Web）默认 ``localhost``
  /// 用户在后端配置页自定义 IP+端口后不再使用此默认值。
  static String defaultBackendHost() {
    if (!kIsWeb && Platform.isAndroid) return '10.0.2.2';
    return 'localhost';
  }

  /// 当前 JWT token（登录后设置，用于鉴权请求）
  static String? _token;

  /// 认证失败回调（token 过期/无效时触发，用于跳转登录页）
  static void Function()? onAuthError;

  /// 设置全局 JWT token
  ///
  /// 登录成功或应用启动恢复登录态时调用，后续所有需要鉴权的请求
  /// 会自动携带 `Authorization: Bearer <token>` 头。
  static void setToken(String? token) {
    _token = token;
  }

  /// 构造请求头
  ///
  /// 默认携带 `Content-Type: application/json`，若已设置 token 则追加
  /// `Authorization` 头。公开接口（二维码、登录状态查询）不使用此方法。
  static Map<String, String> _getHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_token != null) {
      headers['Authorization'] = 'Bearer $_token';
    }
    return headers;
  }

  /// 获取微信扫码登录二维码
  ///
  /// 调用 `GET /api/auth/wechat/qrcode`，返回 `{"url": "...", "state": "..."}`。
  /// 网络异常或后端返回错误时抛出中文异常。
  @Deprecated('已由账号密码登录替代（checklist 1）')
  static Future<Map<String, dynamic>> getQrCode() async {
    final Uri uri = Uri.parse('$baseUrl/api/auth/wechat/qrcode');
    try {
      final http.Response response = await http.get(uri);
      if (response.statusCode != 200) {
        throw Exception('获取二维码失败（HTTP ${response.statusCode}）');
      }
      return _parseJson(response.body);
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('网络请求失败，请检查后端服务是否启动');
    }
  }

  /// 查询微信扫码登录状态
  ///
  /// 调用 `GET /api/auth/wechat/status?state=xxx`，返回
  /// `{"status": "pending"}` 或
  /// `{"status": "success", "token": "...", "user": {...}}`。
  /// 网络异常或后端返回错误时抛出中文异常。
  @Deprecated('已由账号密码登录替代（checklist 1）')
  static Future<Map<String, dynamic>> checkLoginStatus(String state) async {
    final Uri uri = Uri.parse(
      '$baseUrl/api/auth/wechat/status?state=$state',
    );
    try {
      final http.Response response = await http.get(uri);
      if (response.statusCode != 200) {
        throw Exception('查询登录状态失败（HTTP ${response.statusCode}）');
      }
      return _parseJson(response.body);
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('网络请求失败，请检查后端服务是否启动');
    }
  }

  /// 开发模式模拟微信扫码登录
  ///
  /// 调用 `GET /api/auth/wechat/callback?code=mock_code&state=xxx`，
  /// 后端在开发模式下返回模拟用户数据与 JWT token。
  /// 网络异常或后端返回错误时抛出中文异常。
  @Deprecated('已由账号密码登录替代（checklist 1）')
  static Future<Map<String, dynamic>> mockWechatLogin(String state) async {
    final Uri uri = Uri.parse(
      '$baseUrl/api/auth/wechat/callback?code=mock_code&state=$state',
    );
    try {
      final http.Response response = await http.get(uri);
      if (response.statusCode != 200) {
        throw Exception('模拟登录失败（HTTP ${response.statusCode}）');
      }
      return _parseJson(response.body);
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('网络请求失败，请检查后端服务是否启动');
    }
  }

  /// 账号密码注册
  ///
  /// 调用 `POST /api/auth/register`，请求体为
  /// `{"username", "password", "nickname"}`，返回 `{"token", "user"}`。
  /// 用户名冲突或校验失败时抛出中文异常。
  static Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    String nickname = '',
  }) async {
    final http.Response response = await http.post(
      Uri.parse('$baseUrl/api/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
        'nickname': nickname,
      }),
    );
    if (response.statusCode != 200) {
      throw Exception(_errorFromBody(response));
    }
    return _parseJson(utf8.decode(response.bodyBytes));
  }

  /// 账号密码登录
  ///
  /// 调用 `POST /api/auth/login`，请求体为 `{"username", "password"}`，
  /// 返回 `{"token", "user"}`。用户名或密码错误时抛出中文异常。
  static Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    final http.Response response = await http.post(
      Uri.parse('$baseUrl/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    if (response.statusCode != 200) {
      throw Exception(_errorFromBody(response));
    }
    return _parseJson(utf8.decode(response.bodyBytes));
  }

  /// 查询账号注销状态
  ///
  /// 调用 `GET /api/auth/account/status`，返回
  /// `{"status": "active"|"pending_delete"|"deleting", ...}`。
  static Future<Map<String, dynamic>> getAccountStatus() async {
    return _getJson('/api/auth/account/status');
  }

  /// 请求注销账号（进入十日倒计时）
  ///
  /// 调用 `POST /api/auth/account/delete-request`。
  static Future<Map<String, dynamic>> requestAccountDelete() async {
    return _postJson('/api/auth/account/delete-request');
  }

  /// 取消注销账号
  ///
  /// 调用 `POST /api/auth/account/delete-cancel`。
  static Future<Map<String, dynamic>> cancelAccountDelete() async {
    return _postJson('/api/auth/account/delete-cancel');
  }

  /// 从响应中提取后端返回的错误信息（detail 字段）
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
    String topAgentId = '',
  }) async {
    final Map<String, dynamic> data =
        await _getJson('/api/files/$workspaceId', query: {
      if (path.isNotEmpty) 'path': path,
      if (topAgentId.isNotEmpty) 'top_agent_id': topAgentId,
    });
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
    String topAgentId = '',
  }) async {
    final Map<String, dynamic> data =
        await _getJson('/api/files/$workspaceId/content', query: {
      'path': path,
      if (topAgentId.isNotEmpty) 'top_agent_id': topAgentId,
    });
    return data['content'] as String? ?? '';
  }

  /// 获取 PDF 文件信息（总页数、标题、作者）
  ///
  /// 调用 `GET /api/files/{workspace_id}/pdf_info?path=xxx`，返回
  /// `{"total_pages": N, "title": "...", "author": "..."}`。
  /// 网络异常或后端返回错误时抛出中文异常。
  static Future<Map<String, dynamic>> getPdfInfo(
    String workspaceId,
    String path, {
    String topAgentId = '',
  }) async {
    return _getJson('/api/files/$workspaceId/pdf_info', query: {
      'path': path,
      if (topAgentId.isNotEmpty) 'top_agent_id': topAgentId,
    });
  }

  /// 获取 PDF 指定页的预览图片
  ///
  /// 调用 `GET /api/files/{workspace_id}/pdf_preview?path=xxx&page=N&scale=S`，
  /// 返回 `{"image": "base64...", "page": N, "total_pages": M, "width": W, "height": H}`。
  /// [page] 从 1 开始，[scale] 控制分辨率（默认 2.0）。
  /// 网络异常或后端返回错误时抛出中文异常。
  static Future<Map<String, dynamic>> getPdfPreview(
    String workspaceId,
    String path, {
    int page = 1,
    double scale = 2.0,
    String topAgentId = '',
  }) async {
    return _getJson('/api/files/$workspaceId/pdf_preview', query: {
      'path': path,
      'page': page.toString(),
      'scale': scale.toString(),
      if (topAgentId.isNotEmpty) 'top_agent_id': topAgentId,
    });
  }

  // ==================== Git 相关接口 ====================

  /// 获取 Git 提交历史
  ///
  /// 调用 `GET /api/workspaces/{workspace_id}/git/log?limit=50`，返回
  /// `{"commits": [...]}`，每条提交包含 hash、message、date 等字段。
  /// 网络异常或后端返回错误时抛出中文异常。
  static Future<List<Map<String, dynamic>>> getGitLog(
    String workspaceId, {
    int limit = 50,
    String topAgentId = '',
  }) async {
    final Map<String, dynamic> data =
        await _getJson('/api/workspaces/$workspaceId/git/log', query: {
      'limit': limit.toString(),
      if (topAgentId.isNotEmpty) 'top_agent_id': topAgentId,
    });
    final List<dynamic> commits = data['commits'] as List<dynamic>? ?? [];
    return commits
        .map((dynamic e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// 获取 Git 分支列表
  ///
  /// 调用 `GET /api/workspaces/{workspace_id}/git/branches`，返回
  /// `{"branches": [...], "current": "..."}`。
  /// 网络异常或后端返回错误时抛出中文异常。
  static Future<Map<String, dynamic>> getGitBranches(
    String workspaceId, {
    String topAgentId = '',
  }) async {
    return _getJson('/api/workspaces/$workspaceId/git/branches', query: {
      if (topAgentId.isNotEmpty) 'top_agent_id': topAgentId,
    });
  }

  // ==================== 文件同步相关接口 ====================

  /// 同步工作空间文件到本地目录
  ///
  /// 调用 `POST /api/files/{workspace_id}/syncToLocal`，请求体为
  /// `{"local_path": "..."}`。后端在容器内 tar 打包所有文件（排除 .git），
  /// base64 编码后传回服务端解包到指定本地目录。
  static Future<void> syncToLocal(
    String workspaceId,
    String localPath,
  ) async {
    await _postJson('/api/files/$workspaceId/syncToLocal', body: {
      'local_path': localPath,
    });
  }

  /// 下载单个文件
  ///
  /// 调用 `POST /api/files/{workspace_id}/download`，请求体为
  /// `{"path": "..."}`，返回文件内容的字节数组。
  /// 文件不存在或网络异常时抛出异常。
  static Future<Uint8List> downloadFile(
    String workspaceId,
    String filePath, {
    String topAgentId = '',
  }) async {
    final String query =
        topAgentId.isNotEmpty ? '?top_agent_id=${Uri.encodeQueryComponent(topAgentId)}' : '';
    final Uri uri = Uri.parse(
        '$baseUrl/api/files/$workspaceId/download$query');
    try {
      final http.Response response = await http.post(
        uri,
        headers: _getHeaders(),
        body: jsonEncode({'path': filePath}),
      );
      if (response.statusCode == 401) {
        _token = null;
        onAuthError?.call();
        throw Exception('登录已过期，请重新登录');
      }
      if (response.statusCode != 200) {
        throw Exception(_errorFromBody(response));
      }
      return response.bodyBytes;
    } catch (e) {
      if (e is Exception) {
        rethrow;
      }
      throw Exception('网络请求失败，请检查后端服务是否启动');
    }
  }

  /// 下载文件夹（打包为 tar.gz）
  ///
  /// 调用 `POST /api/files/{workspace_id}/download_folder`，请求体为
  /// `{"path": "..."}`，返回 tar.gz 压缩包的字节数组。
  /// 目录不存在或网络异常时抛出异常。
  static Future<Uint8List> downloadFolder(
    String workspaceId,
    String folderPath, {
    String topAgentId = '',
  }) async {
    final String query =
        topAgentId.isNotEmpty ? '?top_agent_id=${Uri.encodeQueryComponent(topAgentId)}' : '';
    final Uri uri =
        Uri.parse('$baseUrl/api/files/$workspaceId/download_folder$query');
    try {
      final http.Response response = await http.post(
        uri,
        headers: _getHeaders(),
        body: jsonEncode({'path': folderPath}),
      );
      if (response.statusCode == 401) {
        _token = null;
        onAuthError?.call();
        throw Exception('登录已过期，请重新登录');
      }
      if (response.statusCode != 200) {
        throw Exception(_errorFromBody(response));
      }
      return response.bodyBytes;
    } catch (e) {
      if (e is Exception) {
        rethrow;
      }
      throw Exception('网络请求失败，请检查后端服务是否启动');
    }
  }

  /// 上传本地文件到工作空间
  ///
  /// 调用 `POST /api/files/{workspace_id}/upload`，以 multipart/form-data 方式
  /// 批量上传。[files] 为 (本地路径, 相对路径) 列表，相对路径用于保留文件夹层级，
  /// 后端统一保存到 `.input/yyyymmdd/` 目录。返回上传后的工作空间内路径列表。
  /// 非 200 状态码时抛出中文异常。
  static Future<List<String>> uploadToCloud(
    String workspaceId,
    List<MapEntry<String, String>> files,
  ) async {
    final Uri uri = Uri.parse('$baseUrl/api/files/$workspaceId/upload');
    final http.MultipartRequest request = http.MultipartRequest('POST', uri);
    for (final MapEntry<String, String> entry in files) {
      // 字段名必须与后端 FastAPI 参数一致：files / rel_paths
      request.files.add(await http.MultipartFile.fromPath('files', entry.key));
      request.fields['rel_paths'] = entry.value;
    }
    if (_token != null) {
      request.headers['Authorization'] = 'Bearer $_token';
    }
    try {
      final http.StreamedResponse response = await request.send();
      if (response.statusCode != 200) {
        final String body = utf8.decode(await response.stream.toBytes());
        throw Exception('上传失败: $body');
      }
      final Map<String, dynamic> data = _parseJson(
        utf8.decode(await response.stream.toBytes()),
      );
      final List<dynamic> paths = data['paths'] as List<dynamic>? ?? [];
      return paths.map((dynamic p) => p.toString()).toList();
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('网络请求失败，请检查后端服务是否启动');
    }
  }

  /// 拉取指定 agent/会话的对话历史
  ///
  /// 调用 `GET /api/conversations/{agent_id}?session_id=xxx`，返回
  /// `{"agent_id": "...", "session_id": "...", "messages": [...]}`。
  /// [sessionId] 缺省为默认会话；传 `"all"` 时返回该 agent 全部会话的消息。
  /// 网络异常或后端返回错误时抛出中文异常。
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
        .map((dynamic e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// 清空指定 agent/会话的对话历史
  ///
  /// 调用 `DELETE /api/conversations/{agent_id}?session_id=xxx`，返回
  /// `{"success": true, "deleted": N}`。
  /// 传 "all" 可清空当前用户所有 agent 的历史；[sessionId] 为空时清空该
  /// agent 全部会话。
  /// 网络异常或后端返回错误时抛出中文异常。
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
      throw Exception('网络请求失败，请检查后端服务是否启动');
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
        .map((dynamic e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
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
  /// 调用 `POST /api/agents`，请求体为 `{"name", "model_id", "system_prompt"}`。
  /// 成功后返回后端生成的完整 Agent 对象（含真实 id）。
  static Future<Agent> createAgent({
    required String name,
    required String modelId,
    String systemPrompt = '',
  }) async {
    final Map<String, dynamic> data = await _postJson('/api/agents', body: {
      'name': name,
      'model_id': modelId,
      'system_prompt': systemPrompt,
    });
    return Agent.fromJson(data['agent'] as Map<String, dynamic>);
  }

  /// 删除一个 agent（连同其对话历史）
  ///
  /// 调用 `DELETE /api/agents/{id}`。
  static Future<void> deleteAgent(String agentId) async {
    final Uri uri = Uri.parse('$baseUrl/api/agents/$agentId');
    try {
      final http.Response response =
          await http.delete(uri, headers: _getHeaders());
      if (response.statusCode != 200) {
        throw Exception('删除失败（HTTP ${response.statusCode}）');
      }
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('网络请求失败，请检查后端服务是否启动');
    }
  }

  /// 修改 agent 的模型或系统提示词（右栏「模型信息」页使用）
  ///
  /// 调用 `PATCH /api/agents/{id}`，请求体为 `{"model_id"?, "system_prompt"?}`，
  /// 只传需要修改的字段。网络异常或后端返回错误时抛出中文异常。
  static Future<Map<String, dynamic>> updateAgent(
    String agentId, {
    String? modelId,
    String? systemPrompt,
  }) async {
    return _patchJson('/api/agents/$agentId', body: {
      if (modelId != null && modelId.isNotEmpty) 'model_id': modelId,
      if (systemPrompt != null) 'system_prompt': systemPrompt,
    });
  }

  /// 获取 agent 的可用模型池与当前模型信息（右栏「模型信息」页使用）
  ///
  /// 调用 `GET /api/agents/{id}/models-info`，返回
  /// `{"models": [{"model_id","name","max_seqlen","thinking","if_vision","base_url"}], "current": {...}}`。
  /// 网络异常或后端返回错误时抛出中文异常。
  static Future<Map<String, dynamic>> getAgentModelsInfo(String agentId) async {
    return _getJson('/api/agents/$agentId/models-info');
  }

  // ==================== MCP 服务管理接口（右栏 MCP 配置页） ====================

  /// 列出已注册的 MCP 服务
  ///
  /// 调用 `GET /api/mcp/services`，返回 `{"services": [{"name","command","args","builtin","enabled"}]}`。
  /// 网络异常或后端返回错误时抛出中文异常。
  static Future<List<Map<String, dynamic>>> getMcpServices() async {
    final Map<String, dynamic> data = await _getJson('/api/mcp/services');
    final List<dynamic> services = data['services'] as List<dynamic>? ?? [];
    return services
        .map((dynamic e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// 注册一个 MCP 服务（stdio 外接）
  ///
  /// 调用 `POST /api/mcp/services`，请求体为 `{"name","command","args"}`。
  /// 网络异常或后端返回错误时抛出中文异常。
  static Future<Map<String, dynamic>> registerMcpService({
    required String name,
    required String command,
    List<String> args = const [],
  }) async {
    return _postJson('/api/mcp/services', body: {
      'name': name,
      'command': command,
      'args': args,
    });
  }

  /// 删除一个 MCP 服务
  ///
  /// 调用 `DELETE /api/mcp/services/{name}`。
  /// 网络异常或后端返回错误时抛出中文异常。
  static Future<void> deleteMcpService(String name) async {
    final Uri uri = Uri.parse(
      '$baseUrl/api/mcp/services/${Uri.encodeComponent(name)}',
    );
    try {
      final http.Response response =
          await http.delete(uri, headers: _getHeaders());
      if (response.statusCode != 200) {
        throw Exception(_errorFromBody(response));
      }
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('网络请求失败，请检查后端服务是否启动');
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
      throw Exception('网络请求失败，请检查后端服务是否启动');
    }
  }

  // ==================== 多会话管理接口（P2） ====================

  /// 列出指定 agent 的全部会话
  ///
  /// 调用 `GET /api/agents/{agentId}/sessions`，返回
  /// `{"agent_id": "...", "sessions": [...]}`。
  static Future<List<ChatSession>> getSessions(String agentId) async {
    final Map<String, dynamic> data =
        await _getJson('/api/agents/$agentId/sessions');
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
    final Uri uri =
        Uri.parse('$baseUrl/api/agents/$agentId/sessions/$sessionId');
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
      throw Exception('网络请求失败，请检查后端服务是否启动');
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
    return _getJson('/api/agents/$agentId/specs', query: {
      if (sessionId.isNotEmpty) 'session_id': sessionId,
    });
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
  static Future<List<Map<String, dynamic>>> getTeammates(
      String agentId) async {
    final Map<String, dynamic> data =
        await _getJson('/api/agents/$agentId/teammates');
    final List<dynamic>? members = data['members'] as List<dynamic>?;
    return members
            ?.map((dynamic e) => (e as Map<String, dynamic>).cast<String, dynamic>())
            .toList() ??
        <Map<String, dynamic>>[];
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
            ?.map((dynamic e) => (e as Map<String, dynamic>).cast<String, dynamic>())
            .toList() ??
        <Map<String, dynamic>>[];
  }

  /// 读取成员工作空间的活动日志
  static Future<String> getTeammateLog(String memberId, {int lines = 60}) async {
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
        if (sessionId != null && sessionId.isNotEmpty)
          'session_id': sessionId,
      },
    );
  }

  /// 列出当前用户的提问（可选按会话过滤），供右侧「问题回复」页使用。
  ///
  /// ``sessionId`` 为空时返回全部提问（含各 agent 与成员提问）。
  static Future<List<Map<String, dynamic>>> getQuestions(
      {String? sessionId}) async {
    final Map<String, dynamic> data = await _getJson(
      '/api/questions',
      query: (sessionId != null && sessionId.isNotEmpty)
          ? {'session_id': sessionId}
          : null,
    );
    final List<dynamic>? questions = data['questions'] as List<dynamic>?;
    return questions
            ?.map((dynamic e) => (e as Map<String, dynamic>).cast<String, dynamic>())
            .toList() ??
        <Map<String, dynamic>>[];
  }

  /// 回答某条待答提问（REST 入口，与 WS user_answer 等价）。
  static Future<void> answerQuestion(String qid, String answer) async {
    await _postJson(
      '/api/questions/$qid/answer',
      body: {'answer': answer},
    );
  }

  /// 修改密码
  ///
  /// 调用 `POST /api/auth/change-password`，请求体为 `{"old_password": "...", "new_password": "..."}`。
  static Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    await _postJson('/api/auth/change-password', body: {
      'old_password': oldPassword,
      'new_password': newPassword,
    });
  }

  /// 设置数据收集开关
  ///
  /// 调用 `POST /api/settings/data-collection`，请求体为 `{"enabled": true/false}`。
  static Future<void> setDataCollection(bool enabled) async {
    await _postJson('/api/settings/data-collection', body: {
      'enabled': enabled,
    });
  }

  /// 设置主动延迟开关
  ///
  /// 开启后限制单个 agent 的 LLM API 调用频率（平均 6 次/分钟），
  /// 适合交互式开发。调用 `POST /api/settings/rate-limit`，请求体
  /// 为 `{"enabled": true/false}`。
  static Future<void> setRateLimit(bool enabled) async {
    await _postJson('/api/settings/rate-limit', body: {
      'enabled': enabled,
    });
  }

  /// 查询主动延迟开关状态
  ///
  /// 调用 `GET /api/settings/rate-limit`，返回 `{"enabled": bool, ...}`。
  /// 查询失败时抛出中文异常（由调用方决定是否忽略）。
  static Future<bool> getRateLimit() async {
    final Map<String, dynamic> data = await _getJson('/api/settings/rate-limit');
    return (data['enabled'] as bool?) ?? false;
  }

  /// 登出：撤销当前 token（后端侧）
  ///
  /// 调用 `POST /api/auth/logout`。本地清理由调用方（AuthService）负责。
  static Future<void> logout() async {
    try {
      final http.Response response = await http.post(
        Uri.parse('$baseUrl/api/auth/logout'),
        headers: _getHeaders(),
      );
      if (response.statusCode != 200) {
        throw Exception('登出失败（HTTP ${response.statusCode}）');
      }
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('网络请求失败，请检查后端服务是否启动');
    }
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
      final http.Response response = await http.get(uri, headers: _getHeaders());
      return _handleResponse(response);
    } catch (e) {
      if (e is Exception) {
        rethrow;
      }
      throw Exception('网络请求失败，请检查后端服务是否启动');
    }
  }

  /// 发送 POST 请求并解析 JSON 响应
  ///
  /// [path] 为接口路径（以 / 开头），[body] 为请求体。
  /// 非 200 状态码或 501 时抛出对应中文异常。
  static Future<Map<String, dynamic>> _postJson(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final Uri uri = Uri.parse('$baseUrl$path');
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
      throw Exception('网络请求失败，请检查后端服务是否启动');
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
      throw Exception('网络请求失败，请检查后端服务是否启动');
    }
  }

  /// 统一处理响应状态码
  ///
  /// - 401：token 过期或无效，清除 token 并触发跳转登录页
  /// - 501：抛出"功能开发中"异常
  /// - 非 200：抛出 HTTP 状态码异常
  /// - 200：解析 JSON 响应体（强制 UTF-8 解码，避免中文乱码）
  static Map<String, dynamic> _handleResponse(http.Response response) {
    if (response.statusCode == 401) {
      // token 过期或无效，清除本地凭证并跳转登录页
      unawaited(AuthService().clearToken());
      setToken(null);
      onAuthError?.call();
      throw Exception('登录已过期，请重新登录');
    }
    if (response.statusCode == 501) {
      throw Exception('功能开发中');
    }
    if (response.statusCode != 200) {
      throw Exception(_errorFromBody(response));
    }
    // 后端 Content-Type 为 application/json（无 charset），
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
      throw Exception('解析后端响应失败');
    }
  }
}
