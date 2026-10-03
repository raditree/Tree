import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_protocol/tree_protocol.dart';

import 'io/core_process_launcher.dart';

/// 应用版本（与 `pubspec.yaml` 的 `version:` **必须一致**）。
///
/// 为什么写成常量而不是运行时读：Dart 运行时拿不到 pubspec（读它要引第三方包，
/// 而为了显示一行版本号引依赖不划算），Release 目录里也没有 pubspec。
/// 代价是两处会漂移，所以 `test/version_info_test.dart` 直接读 pubspec 比对——
/// 漂移会让测试红，而不是让用户看到一个假版本号。
const String kAppVersion = '1.0.2';

/// 应用构建号（pubspec `version:` 的 `+` 后半段，同一处测试钉住）。
const String kAppBuildNumber = '1';

/// 客户端与核心之间的**接口契约版本**（见各 REST 注释里的「契约 vX.Y」）。
///
/// 它与 [kAppVersion] 是两件事：契约版本只在接口形状变化时动，应用版本每次发版都动。
const String kClientContractVersion = '1.3';

/// 一行里的一对"标签 / 值"（版本卡与复制块共用，保证两处内容一致）。
typedef InfoRow = ({String label, String value});

/// **版本与运行态信息**（设置页「版本信息」的数据源）。
///
/// 只从 [CoreProcessLauncher] 读**已经在内存里**的握手信息与产物路径——
/// 不新开 REST 端点、不落盘、不探活：这些值在应用启动握手时就已经拿到了，
/// 显示它是纯读取（顺手解决"我到底连的是哪个核心"这个真机上极难自证的问题）。
class VersionInfo {
  const VersionInfo({
    required this.coreVersion,
    required this.corePid,
    required this.corePort,
    required this.attached,
    required this.coreExecutablePath,
    required this.buildWarning,
  });

  /// 从启动器取当前运行态。
  factory VersionInfo.fromLauncher([CoreProcessLauncher? launcher]) {
    final CoreProcessLauncher l = launcher ?? CoreProcessLauncher.instance;
    final CoreHandshake? handshake = l.handshake;
    return VersionInfo(
      coreVersion: handshake?.version ?? '',
      corePid: handshake?.pid ?? 0,
      corePort: handshake?.port ?? 0,
      attached: l.isAttached,
      coreExecutablePath: l.coreExecutablePath ?? '',
      buildWarning: l.buildWarning,
    );
  }

  /// 核心版本（握手 `version` 字段；未握手为空串）。
  final String coreVersion;

  /// 核心进程 pid（附着模式 = 外部进程的 pid）。
  final int corePid;

  /// 核心监听端口（127.0.0.1 上的随机空闲端口）。
  final int corePort;

  /// 是否**附着**到一个已在运行的核心（而不是这次由应用拉起）。
  final bool attached;

  /// 本次实际使用的核心可执行文件路径（附着模式为空串）。
  final String coreExecutablePath;

  /// 「核心产物比界面旧」的诊断（启动时算好；null = 没有这个问题）。
  ///
  /// 真机上极难自证的坑：核心是独立进程，产物可能来自更早的构建，此时界面是新
  /// 功能、核心是旧行为。把它摆在版本卡上，用户就能自己看出"为什么新功能没生效"。
  final String? buildWarning;

  /// 应用版本行（含构建号）。
  String get appVersionText => '$kAppVersion+$kAppBuildNumber';

  /// 核心版本行（未握手时给出可读原因，而不是留空）。
  String get coreVersionText => coreVersion.isEmpty ? '未知（未完成握手）' : coreVersion;

  /// 核心进程行。
  String get coreProcessText {
    if (corePid <= 0) return '未知（未完成握手）';
    final String mode = attached ? '附着' : '本应用拉起';
    return 'pid $corePid · 端口 $corePort · $mode';
  }

  /// 展示用行（版本卡按这个顺序渲染；`null` 值 = 该行不显示）。
  List<InfoRow> get rows => <InfoRow>[
    (label: '应用版本', value: appVersionText),
    (label: '核心版本', value: coreVersionText),
    (label: '核心进程', value: coreProcessText),
    (label: '接口契约', value: 'v$kClientContractVersion'),
    if (coreExecutablePath.isNotEmpty)
      (label: '核心产物', value: coreExecutablePath),
  ];

  /// 复制/反馈用的整块文本（比卡片多一份环境信息，便于贴到 issue 里）。
  String toReportText() {
    final StringBuffer buffer = StringBuffer()
      ..writeln('Tree 桌面端 $appVersionText')
      ..writeln('核心版本：$coreVersionText')
      ..writeln('核心进程：$coreProcessText')
      ..writeln('接口契约：v$kClientContractVersion')
      ..writeln('平台：${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    if (coreExecutablePath.isNotEmpty) {
      buffer.writeln('核心产物：$coreExecutablePath');
    }
    if (buildWarning != null) {
      buffer.writeln('产物告警：$buildWarning');
    }
    return buffer.toString().trimRight();
  }
}

/// 打开**插件开发指南**（发行目录 `plugins/plugin-development.md` / 仓库 `docs/plugin-development.md`）。
///
/// **核心侧同一套候选顺序**在 `packages/tree_core/lib/src/plugin/plugin_guide.dart`
/// （它按同一顺序解析原件，再播种到 agent 工作空间 `.self/docs/plugin-development.md`）——
/// 两端不共享代码，改一处要同步另一处。
///
/// 为什么打开文件而不是在应用内重写一份：插件的协议面（RPC 清单、17 个点位、
/// `ui/manifest`、`plugins.yaml` 全字段、流式回填）**已经在指南里写全了**，再造一份
/// 应用内文档就是第二份真相源，必然与代码漂移。入口的职责只是"把人送到那份文档"。
class PluginDocs {
  PluginDocs._();

  /// 系统性指南文件名（**首选**）。
  static const String guideName = 'plugin-development.md';

  /// 简版说明文件名（指南缺失时的兜底；`examples/plugins/README.md` 是示例索引）。
  static const String readmeName = 'README.md';

  /// 候选文件名（**顺序即优先级**：系统性指南优先，简版说明兜底）。
  static const List<String> docNames = <String>[guideName, readmeName];

  /// 发行目录下的插件目录名（安装包与 Release 目录都是这个名字）。
  static const String bundledDirName = 'plugins';

  /// 仓库里的插件目录相对路径（开发态）。
  static const String repoDirName = 'examples/plugins';

  /// 仓库里的文档目录（开发态；`docs/plugin-development.md` 在这里）。
  static const String repoDocDirName = 'docs';

  /// 解析插件开发指南的**候选路径**（按优先级）。
  ///
  /// 顺序即优先级，且**只列可能存在的路径**——调用方按顺序取第一个存在的：
  /// 1. [overrideDir]：调用方显式指定（测试 / 将来加设置项）——两个文件名都认；
  /// 2. **应用目录**下的 `plugins/<name>`：发行版布局（安装包与 Tree.exe 同级
  ///    拷贝 `examples/plugins/` 的内容与 `docs/plugin-development.md`，
  ///    见 `tool/package_windows.dart`）——两个文件名都认；
  /// 3. 从可执行文件目录**逐级向上**找仓库布局：
  ///    - `docs/plugin-development.md`：**只认指南这个专有文件名**。泛化的
  ///      `README.md` 在任意祖先目录里都可能存在（实测：Flutter SDK 自带
  ///      `flutter/docs/README.md`），认它会把用户送到一份**无关文档**上；
  ///    - `examples/plugins/<name>`：两个文件名都认（仓库里的示例目录是专有路径）。
  ///
  /// `flutter run` 的产物在 `build/windows/x64/runner/Debug/`，仓库根在好几层之上；
  /// 逐级向上同时覆盖"树内任意深度启动"的情形（与核心找内置插件脚本同一思路）。
  static List<String> candidatePaths({
    String? overrideDir,
    String? executablePath,
  }) {
    final List<String> candidates = <String>[];
    void add(String dir, List<String> names) {
      for (final String name in names) {
        final String path = p.join(dir, name);
        if (!candidates.contains(path)) candidates.add(path);
      }
    }

    if (overrideDir != null && overrideDir.trim().isNotEmpty) {
      add(overrideDir.trim(), docNames);
    }
    final String exePath = executablePath ?? Platform.resolvedExecutable;
    final Directory appDir = File(exePath).parent;
    add(p.join(appDir.path, bundledDirName), docNames);
    Directory? dir = appDir;
    for (int depth = 0; depth < 8 && dir != null; depth++) {
      add(
        p.join(dir.path, p.joinAll(repoDocDirName.split('/'))),
        <String>[guideName],
      );
      add(
        p.join(dir.path, p.joinAll(repoDirName.split('/'))),
        docNames,
      );
      dir = dir.parent;
    }
    return candidates;
  }

  /// 解析出**实际存在**的插件开发说明路径；都不存在返回 null（调用方给可读提示）。
  static String? resolvePath({
    String? overrideDir,
    String? executablePath,
  }) {
    for (final String candidate
        in candidatePaths(overrideDir: overrideDir, executablePath: executablePath)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// 用系统默认程序打开插件开发指南；成功返回 null，失败返回可读中文原因。
  ///
  /// 与「用资源管理器定位文件」（`FileReveal`）是两件事：这里要**打开内容**
  /// （指南是给人读的），所以交给系统默认关联程序——用户拿什么看 markdown
  /// 由他自己决定，应用不挑编辑器。
  static Future<String?> openReadme({
    String? overrideDir,
    String? executablePath,
  }) async {
    final String? path = resolvePath(
      overrideDir: overrideDir,
      executablePath: executablePath,
    );
    if (path == null) {
      return '未找到插件开发指南（${docNames.join(' 或 ')}）。\n'
          '查找位置：应用目录下的 $bundledDirName/、仓库的 $repoDocDirName/ 与 '
          '$repoDirName/。\n'
          '发行版请确认安装完整（$bundledDirName 目录与主程序同级）；'
          '源码仓库请确认在仓库内运行。';
    }
    return openPath(path);
  }

  /// 用系统默认程序打开任意文件或目录（失败返回可读原因）。
  static Future<String?> openPath(String path) async {
    if (path.trim().isEmpty) return '路径为空，无法打开';
    final FileSystemEntityType type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) {
      return '路径不存在或已被移动：$path';
    }
    try {
      if (Platform.isWindows) {
        // 走 cmd 的 `start`：Windows 没有直接"用默认程序打开"的可执行文件
        // （explorer 只负责定位/开目录）。空标题参数是必需的——`start` 会把第一个
        // 带引号的参数当成窗口标题，省掉它时打开含空格路径会失败。
        await Process.run('cmd', <String>['/c', 'start', '', path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', <String>[path]);
      } else {
        await Process.run('xdg-open', <String>[path]);
      }
    } on ProcessException catch (e) {
      return '打开失败：${e.message}';
    }
    return null;
  }
}
