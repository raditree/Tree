import 'dart:io';

import 'package:path/path.dart' as p;

/// `~/.tree` 数据根的路径解析与布局定义。
///
/// 布局（M2 起，全部是**人类可直接阅读与手改**的文本文件）：
/// ```
/// <root>/
/// ├── config/
/// │   ├── settings.yaml          # 全局设置（帧率/主动延迟/消息切入/数据收集…）
/// │   └── models/<model_id>.yaml # 每个模型一个文件（含明文 api_key）
/// ├── agents/<agent_id>.yaml     # 每个顶部 agent 一个文件（含 system_prompt）
/// └── data/<agent_id>/<session_id>/
///     ├── session.json           # 会话元数据（原子快照：写临时文件再改名）
///     └── messages.jsonl         # 消息追加日志（一行一条，崩溃最多丢最后一行）
/// ```
///
/// 为什么不是"每会话一个大 JSON"：单个会话实测已达 2433 条消息 / 2.9 MB，
/// 全量重写会让每次追加都变成 O(n) 写放大并放大崩溃损坏面；jsonl 追加天然
/// 只影响一行，配合 session.json 的原子快照即可保证元数据不会半写。
///
/// 根目录解析顺序：显式 override（CLI `--data-dir`）→ `TREE_HOME` 环境变量
/// → 各平台规范位置（Windows `%APPDATA%\Tree`；macOS
/// `~/Library/Application Support/Tree`；Linux `$XDG_DATA_HOME/tree` 或
/// `~/.local/share/tree`）→ `~/.tree` 兜底。
class TreePaths {
  TreePaths(this.root);

  /// 数据根目录（绝对路径）。
  final String root;

  /// 解析数据根目录（[environment] 仅测试注入用）。
  static TreePaths resolve({
    String? override,
    Map<String, String>? environment,
  }) {
    final Map<String, String> env = environment ?? Platform.environment;
    final String explicit = (override ?? '').trim();
    if (explicit.isNotEmpty) return TreePaths(p.absolute(explicit));
    final String treeHome = (env['TREE_HOME'] ?? '').trim();
    if (treeHome.isNotEmpty) return TreePaths(p.absolute(treeHome));
    return TreePaths(_platformDefault(env));
  }

  static String _platformDefault(Map<String, String> env) {
    if (Platform.isWindows) {
      final String appData = (env['APPDATA'] ?? '').trim();
      if (appData.isNotEmpty) return p.join(appData, 'Tree');
      final String profile = (env['USERPROFILE'] ?? '').trim();
      if (profile.isNotEmpty) return p.join(profile, '.tree');
      return p.join(Directory.systemTemp.path, 'Tree');
    }
    final String home = (env['HOME'] ?? '').trim();
    if (Platform.isMacOS) {
      return home.isEmpty
          ? p.join(Directory.systemTemp.path, 'Tree')
          : p.join(home, 'Library', 'Application Support', 'Tree');
    }
    final String xdg = (env['XDG_DATA_HOME'] ?? '').trim();
    if (xdg.isNotEmpty) return p.join(xdg, 'tree');
    return home.isEmpty
        ? p.join(Directory.systemTemp.path, 'tree')
        : p.join(home, '.local', 'share', 'tree');
  }

  /// 配置目录。
  String get configDir => p.join(root, 'config');

  /// 模型配置目录。
  String get modelsDir => p.join(configDir, 'models');

  /// agent 配置目录。
  String get agentsDir => p.join(root, 'agents');

  /// 会话数据目录（每个 agent 一个子目录）。
  String get sessionsDataDir => p.join(root, 'data');

  /// 全局设置文件。
  String get settingsFile => p.join(configDir, 'settings.yaml');

  /// 内置 Spec 模板目录（首次启动由核心写入，用户可查看与手改副本）。
  String get builtinSpecsDir => p.join(root, 'spec', 'builtin');

  /// 全部提问的原子快照（跨会话，右侧「问题回复」页用）。
  ///
  /// 为什么不像消息那样按会话拆文件：提问是**跨会话**查询的队列（`GET /api/questions`），
  /// 且单条很小；集中一个文件才能一次原子覆盖、不必扫描目录。会话内的提问卡片
  /// 另有消息日志承载（`kind = ask_user_question`）。
  String get questionsFile => p.join(sessionsDataDir, 'questions.json');

  /// 单个模型配置文件。
  String modelFile(String modelId) =>
      p.join(modelsDir, '${safeSegment(modelId)}.yaml');

  /// 单个 agent 配置文件。
  String agentFile(String agentId) =>
      p.join(agentsDir, '${safeSegment(agentId)}.yaml');

  /// 某 agent 的会话数据目录。
  String agentDataDir(String agentId) =>
      p.join(sessionsDataDir, safeSegment(agentId));

  /// 某会话的目录。
  String sessionDir(String agentId, String sessionId) =>
      p.join(agentDataDir(agentId), safeSegment(sessionId));

  /// 会话元数据（原子快照）。
  String sessionMetaFile(String agentId, String sessionId) =>
      p.join(sessionDir(agentId, sessionId), 'session.json');

  /// 会话消息追加日志。
  String messagesFile(String agentId, String sessionId) =>
      p.join(sessionDir(agentId, sessionId), 'messages.jsonl');

  /// agent 的**默认工作空间目录**（`<root>/workspaces/<agent_id>`）。
  ///
  /// 仅当 agent 配置里 `workspace_dir` 为空时使用；用户可以在
  /// `agents/<id>.yaml` 里直接改成自己的项目目录。
  String defaultWorkspaceDir(String agentId) =>
      p.join(root, 'workspaces', safeSegment(agentId));

  /// 创建全部必需目录（幂等）。
  Future<void> ensureLayout() async {
    for (final String dir in <String>[
      root,
      configDir,
      modelsDir,
      agentsDir,
      sessionsDataDir,
    ]) {
      await Directory(dir).create(recursive: true);
    }
  }

  /// [ensureLayout] 的同步版本（测试与"启动即建骨架"的同步路径用）。
  void ensureLayoutSync() {
    for (final String dir in <String>[
      root,
      configDir,
      modelsDir,
      agentsDir,
      sessionsDataDir,
    ]) {
      Directory(dir).createSync(recursive: true);
    }
  }

  /// 校验单个路径分段是否安全（防路径穿越）。
  ///
  /// 只允许 `[A-Za-z0-9_.-]`，并拒绝 `.` / `..` 与空串。核心自己生成的 id
  /// 天然满足；来自 HTTP/WS 的 id 必须先过这里，否则 `../` 能写出数据根之外。
  static String safeSegment(String raw) {
    final String value = raw.trim();
    if (value.isEmpty) {
      throw ArgumentError.value(raw, 'segment', '路径分段不能为空');
    }
    if (value == '.' || value == '..') {
      throw ArgumentError.value(raw, 'segment', '路径分段不能是 . 或 ..');
    }
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value)) {
      throw ArgumentError.value(
        raw,
        'segment',
        '路径分段只允许 [A-Za-z0-9_.-]（防路径穿越）',
      );
    }
    return value;
  }
}
