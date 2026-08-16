import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/agent.dart';
import '../models/file_node.dart';
import 'auth_service.dart';

/// API 服务 - 封装后端 REST API 调用
///
/// 统一管理对后端（FastAPI）的 HTTP 请求，包括微信扫码登录、
/// 文件管理、Git 历史等接口。网络错误或非 200 状态码时抛出中文异常，
/// 便于在 UI 上直接展示。
class ApiService {
  /// 后端服务地址
  static String baseUrl = 'http://localhost:8000';

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
  }) async {
    final Map<String, dynamic> data =
        await _getJson('/api/files/$workspaceId', query: {
      if (path.isNotEmpty) 'path': path,
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
    String path,
  ) async {
    final Map<String, dynamic> data =
        await _getJson('/api/files/$workspaceId/content', query: {
      'path': path,
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
    String path,
  ) async {
    return _getJson('/api/files/$workspaceId/pdf_info', query: {
      'path': path,
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
  }) async {
    return _getJson('/api/files/$workspaceId/pdf_preview', query: {
      'path': path,
      'page': page.toString(),
      'scale': scale.toString(),
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
  }) async {
    final Map<String, dynamic> data =
        await _getJson('/api/workspaces/$workspaceId/git/log', query: {
      'limit': limit.toString(),
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
    String workspaceId,
  ) async {
    return _getJson('/api/workspaces/$workspaceId/git/branches');
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
    String filePath,
  ) async {
    final Uri uri = Uri.parse('$baseUrl/api/files/$workspaceId/download');
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
    String folderPath,
  ) async {
    final Uri uri =
        Uri.parse('$baseUrl/api/files/$workspaceId/download_folder');
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

  /// 拉取指定 agent 的对话历史
  ///
  /// 调用 `GET /api/conversations/{agent_id}`，返回
  /// `{"agent_id": "...", "messages": [...]}`。
  /// 网络异常或后端返回错误时抛出中文异常。
  static Future<List<Map<String, dynamic>>> getConversationHistory(
    String agentId,
  ) async {
    final Map<String, dynamic> data =
        await _getJson('/api/conversations/$agentId');
    final List<dynamic> messages = data['messages'] as List<dynamic>? ?? [];
    return messages
        .map((dynamic e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// 清空指定 agent 的对话历史
  ///
  /// 调用 `DELETE /api/conversations/{agent_id}`，返回
  /// `{"success": true, "deleted": N}`。
  /// 传 "all" 可清空当前用户所有 agent 的历史。
  /// 网络异常或后端返回错误时抛出中文异常。
  static Future<int> clearConversationHistory(String agentId) async {
    final Uri uri = Uri.parse('$baseUrl/api/conversations/$agentId');
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
  /// 调用 `GET /api/models`，返回 `{"models": [{"model_id", "name", "is_limitless_context"}]}`。
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

  /// 手动压缩 normal LLM 的上下文（compact 按钮触发）
  ///
  /// 调用 `POST /api/agents/{agentId}/compact`。返回是否实际压缩及压缩后
  /// 上下文大小；无限上下文 LLM 无操作（compressed=false）。
  static Future<Map<String, dynamic>> compactAgent(String agentId) async {
    final Uri uri = Uri.parse('$baseUrl/api/agents/$agentId/compact');
    try {
      final http.Response response = await http.post(
        uri,
        headers: _getHeaders(),
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

  /// 读取成员工作空间的活动日志
  static Future<String> getTeammateLog(String memberId, {int lines = 60}) async {
    final Map<String, dynamic> data = await _getJson(
      '/api/agents/$memberId/teammate/$memberId/log',
      query: {'lines': '$lines'},
    );
    return (data['log'] as String?) ?? '';
  }

  // ==================== 预算控制接口 ====================

  /// 设置顶层 agent 的预算金额（美元）
  ///
  /// 调用 `POST /api/budget/{agent_id}`，请求体为 `{"budget": 金额}`。
  static Future<Map<String, dynamic>> setBudget(
    String agentId,
    double budget,
  ) async {
    return _postJson('/api/budget/$agentId', body: {'budget': budget});
  }

  /// 获取顶层 agent 的预算状态
  ///
  /// 调用 `GET /api/budget/{agent_id}`，返回预算总额、已使用、剩余、百分比、token 分类用量。
  static Future<Map<String, dynamic>> getBudget(String agentId) async {
    return _getJson('/api/budget/$agentId');
  }

  /// 用户直接向团队成员发送消息
  static Future<Map<String, dynamic>> sendTeammateMessage(
    String leaderId,
    String memberId,
    String content,
  ) async {
    return _postJson(
      '/api/agents/$leaderId/teammate/$memberId/message',
      body: {'content': content},
    );
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
      throw Exception('请求失败（HTTP ${response.statusCode}）');
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
