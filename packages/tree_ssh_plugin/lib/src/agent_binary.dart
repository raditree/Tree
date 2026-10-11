import 'dart:io';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'sha256.dart';

/// 核心随 `tunnel.ensure` 下发的 agent 参数（协议 §2 的 `agent` 对象里的**可选覆盖**）。
///
/// **版本口径（2026-10-11 用户裁决 B）**：agent 版本**只由插件自报**（[kAgentVersion]，编译时注入）
/// —— 理由很硬：**只有插件知道它自己随包带的是哪个二进制**。核心那句 `version` 曾经"声明了却
/// 到不了插件"（核心只发 `config`、插件读 `request['agent']`，两边的键从来没对上），
/// 现在已经**明确不再声明**（核心侧 `TunnelConnectRequest` 删掉了那几个字段）。
/// 若请求里仍然带了版本且与插件自报不一致 ⇒ 记一条日志说明"以插件为准"，**不**照它改。
///
/// `bytes_sha256` / `binary_name` / `binary_path` 仍是**可选覆盖**（测试与显式指定用）；
/// 不传时由插件自己算 sha256、按架构推二进制名。
class AgentRequest {
  const AgentRequest({
    this.version = kAgentVersion,
    this.bytesSha256 = '',
    this.binaryName = '',
    this.binaryPath = '',
  });

  /// 从 L1 的 `agent` 对象解析（版本一律取插件自报的 [kAgentVersion]）。
  static AgentRequest parse(
    Object? raw, {
    void Function(String message)? log,
  }) {
    if (raw is! Map) return const AgentRequest();
    final Map<String, dynamic> map = raw.map(
      (dynamic k, dynamic v) => MapEntry('$k', v),
    );
    final String requested = (map['version'] ?? '').toString().trim();
    if (requested.isNotEmpty && requested != kAgentVersion) {
      log?.call(
        '请求声明的 agent 版本（$requested）与插件自报（$kAgentVersion）不一致：'
        '版本以**插件自报**为准（插件的随包二进制才是要推上去的那份）',
      );
    }
    return AgentRequest(
      version: kAgentVersion,
      bytesSha256: (map['bytes_sha256'] ?? map['bytesSha256'] ?? '')
          .toString()
          .trim()
          .toLowerCase(),
      binaryName: (map['binary_name'] ?? map['binaryName'] ?? '').toString().trim(),
      binaryPath: (map['binary_path'] ?? map['binaryPath'] ?? '').toString().trim(),
    );
  }

  /// 本插件随包 agent 的版本（决定目标机上的驻留目录 `~/.tree/agent/<version>/`）。
  final String version;

  /// 随包二进制的 sha256（显式覆盖；空 = 插件自己算）。
  final String bytesSha256;

  /// 随包二进制名（空 = `tree_agent-linux-<arch>`；可带 `{arch}` 占位）。
  final String binaryName;

  /// 本机绝对路径覆盖（插件补充约定，见 README）。
  final String binaryPath;

  /// 给定目标机架构，算出"应该用哪个文件名"。
  String binaryNameFor(String arch) {
    final String fallback = 'tree_agent-linux-$arch';
    if (binaryName.isEmpty) return fallback;
    return binaryName.replaceAll('{arch}', arch);
  }
}

/// 解析好的随包 agent 二进制（已在本机读入 + 算过 sha256）。
class AgentBinary {
  AgentBinary({
    required this.path,
    required this.name,
    required this.bytes,
  }) : sha256 = sha256Hex(bytes);

  /// 本机路径（日志用）。
  final String path;

  /// 目标机上的文件名（`tree_agent-linux-amd64` 那类）。
  final String name;

  /// 二进制字节（推送时按 256 KiB 分块 base64 送过去）。
  final List<int> bytes;

  /// 本机 sha256（与目标机 `sha256sum` 对账的**唯一判据**）。
  final String sha256;

  int get size => bytes.length;

  @override
  String toString() => 'AgentBinary($name, ${bytes.length} 字节, ${shortDigest(sha256)})';
}

/// 定位/校验随包 agent 失败（`error_kind` 直接进 `tunnel.ensure` 的失败面）。
class AgentBinaryException implements Exception {
  AgentBinaryException(this.kind, this.message);

  /// [TunnelErrorKinds] 之一（实际只用到 `push_failed`）。
  final String kind;
  final String message;

  @override
  String toString() => message;
}

/// `agent 参数 + 架构 → 本机二进制`。测试注入假实现，避免依赖真文件。
typedef AgentBinaryLoader = Future<AgentBinary> Function(
  AgentRequest request,
  String arch,
);

/// 生产实现：按候选目录找随包二进制，并做本地完整性校验。
///
/// 查找顺序（第一个命中即用）：
/// 1. `agent.binary_path`（核心显式指定）；
/// 2. 环境变量 `TREE_AGENT_BINARY`；
/// 3. [searchDirs]（默认第一条就是**与插件可执行文件同级的 `plugins/` 的上一级 + `agents/`**，
///    即发行包的 `<应用目录>/agents/`、开发态的 `<仓根>/build/agents/`）；
///
/// 找不到 / 空文件 / 与核心声明的 `bytes_sha256` 不一致 ⇒ [AgentBinaryException]
/// （`push_failed` —— 属于"回退内置"类：插件确实没法把 agent 送上去）。
class AgentBinaryResolver {
  AgentBinaryResolver({
    this.searchDirsOverride,
    Map<String, String>? environment,
  }) : _environment = environment ?? Platform.environment;

  /// 显式给定的候选目录（测试用；null = 按 [searchDirs] 的默认规则算）。
  final List<String>? searchDirsOverride;

  final Map<String, String> _environment;

  /// 供 [AgentBinaryLoader] 位置使用：`AgentBinaryResolver().call`。
  Future<AgentBinary> call(AgentRequest request, String arch) async {
    final String name = request.binaryNameFor(arch);
    final String? explicit = request.binaryPath.isNotEmpty
        ? request.binaryPath
        : _environment['TREE_AGENT_BINARY'];
    final List<String> candidates = <String>[
      if (explicit != null && explicit.isNotEmpty) explicit,
      for (final String dir in searchDirs()) _join(dir, name),
    ];

    String? found;
    for (final String candidate in candidates) {
      final File file = File(_expandHome(candidate));
      if (file.existsSync() && file.lengthSync() > 0) {
        found = file.path;
        break;
      }
    }
    if (found == null) {
      throw AgentBinaryException(
        TunnelErrorKinds.pushFailed,
        '找不到随包 agent 二进制「$name」（找过：${candidates.join('、')}）',
      );
    }

    final List<int> bytes;
    try {
      bytes = File(found).readAsBytesSync();
    } catch (error) {
      throw AgentBinaryException(
        TunnelErrorKinds.pushFailed,
        '读取随包 agent 二进制失败：$found（$error）',
      );
    }
    if (bytes.isEmpty) {
      throw AgentBinaryException(
        TunnelErrorKinds.pushFailed,
        '随包 agent 二进制是空文件：$found',
      );
    }

    final AgentBinary binary = AgentBinary(path: found, name: name, bytes: bytes);
    final String declared = request.bytesSha256;
    if (declared.isNotEmpty && declared != binary.sha256) {
      throw AgentBinaryException(
        TunnelErrorKinds.pushFailed,
        '随包 agent 二进制与核心声明的 sha256 不一致：'
        '${binary.path} 实际 ${shortDigest(binary.sha256)}，声明 ${shortDigest(declared)}',
      );
    }
    return binary;
  }

  /// 候选目录（可注入，供测试钉住顺序）。
  ///
  /// 与核心侧的**约定**对齐（`builtin_plugins.dart` 的 `scriptRoots` 与
  /// `tool/package_windows.dart` 的注释都写着「`agents/` 与 `plugins/` 同级是插件的查找约定」）：
  ///
  /// 1. 插件可执行文件**所在目录的上一级**下的 `agents/` —— 发行包是 `<应用目录>/agents/`
  ///    （插件在 `<应用目录>/plugins/tree_ssh_executor[.exe]`）；开发态是 `<仓根>/build/agents/`
  ///    （插件在 `<仓根>/build/plugins/`，正是 `tool/build_ssh_plugin.dart` / `build_agent.dart` 的落点）。
  /// 2. 插件可执行文件**同级**的 `agents/`（把两个二进制放同一个目录的简易部署也认）。
  /// 3. 从插件目录向上找**仓根**（含 `packages/tree_ssh_plugin` 的那一层）：`<仓根>/build/agents`
  ///    与 `<仓根>/agents`（`dart run bin/tree_ssh_executor.dart` 这种形态也找得到）。
  /// 4. 当前工作目录的 `agents/` / `build/agents/`（兜底）。
  /// 5. `<目录>/assets/`（兼容"把 agent 塞进插件自己的 assets/"这种打包方式）。
  List<String> searchDirs() {
    final List<String>? injected = searchDirsOverride;
    if (injected != null) return injected;

    final List<String> dirs = <String>[];
    void add(String path) {
      if (path.isEmpty || dirs.contains(path)) return;
      dirs.add(path);
    }

    final List<String> bases = <String>[
      Platform.resolvedExecutable,
      Platform.script.toFilePath(),
    ];
    for (final String base in bases) {
      final String dir = _dirOf(base);
      final String parent = _parentOf(dir);
      add(_join(parent, 'agents'));
      add(_join(parent, 'assets'));
      add(_join(dir, 'agents'));
      add(_join(dir, 'assets'));
    }

    final String? repo = _findRepoRoot(_dirOf(Platform.resolvedExecutable)) ??
        _findRepoRoot(Directory.current.path);
    if (repo != null) {
      add(_join(_join(repo, 'build'), 'agents'));
      add(_join(repo, 'agents'));
    }

    final String cwd = Directory.current.path;
    add(_join(_join(cwd, 'build'), 'agents'));
    add(_join(cwd, 'agents'));
    add(_join(cwd, 'assets'));
    return dirs;
  }

  /// 从 [start] 向上找**仓根**（含 `packages/tree_ssh_plugin` 的那一层）；找不到返回 null。
  ///
  /// 与核心侧 `BuiltinPlugins.specRoots` 的 `repoRoot` 同一手法（那里找 `packages/tree_core`）：
  /// 发行包里根本没有这一层 ⇒ 返回 null，不影响上面的 1/2 条。
  static String? _findRepoRoot(String start) {
    Directory dir = Directory(start);
    for (int depth = 0; depth < 8; depth++) {
      if (Directory(_join(_join(dir.path, 'packages'), 'tree_ssh_plugin')).existsSync()) {
        return dir.path;
      }
      final Directory parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  static String _dirOf(String path) => File(path).parent.path;

  static String _parentOf(String dir) => File(dir).parent.path;

  static String _join(String dir, String name) {
    if (dir.isEmpty) return name;
    final String separator = dir.contains('\\') && !dir.contains('/') ? '\\' : '/';
    return dir.endsWith(separator) ? '$dir$name' : '$dir$separator$name';
  }

  static String _expandHome(String path) {
    if (!path.startsWith('~')) return path;
    final String home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return path;
    return '$home${path.substring(1)}';
  }
}
