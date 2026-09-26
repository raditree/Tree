import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_protocol/tree_protocol.dart';

/// Windows 打包脚本（M7f）：把 Flutter 应用与核心进程打成**能直接解压运行**的便携包。
///
/// 为什么需要脚本：发行版布局有两处硬约束，手敲很容易漏——
/// 1. tree_core.exe 必须与 tree.exe **同目录**（CoreProcessLauncher 的第 2 条
///    解析规则就是"应用同目录"）；
/// 2. 核心必须用**与构建应用同一个 SDK** 编译（混用 SDK 会出现 AOT 产物与
///    Flutter 引擎不匹配的怪问题）。
///
/// 用法（在仓库根目录执行）：
///   flutter-sdk\bin\cache\dart-sdk\bin\dart.exe run tool/package_windows.dart ^
///       --flutter flutter-sdk\bin\flutter.bat
///
/// 选项：
///   --flutter path     flutter.bat 路径（未给则读 FLUTTER_ROOT 环境变量）
///   --skip-build         跳过 flutter build windows --release（用已有产物）
///   --release-dir dir  直接指定已构建的 Release 目录（隐含 --skip-build）
///   --out dir          产物目录（默认 dist）
///   --version x.y.z    版本号（默认取 pubspec.yaml 里 + 之前的部分）
///   --iscc path          Inno Setup 的 ISCC.exe（默认自动探测 PATH 与常见安装目录）
///   --installer          额外编译 Inno Setup 安装包
///   --no-zip             只准备便携目录，不压缩
///   --skip-verify        跳过"启动打包好的核心读握手"自检
Future<void> main(List<String> args) async {
  try {
    await _package(args);
  } on _UsageError catch (usage) {
    if (usage.message.isNotEmpty) stderr.writeln(usage.message);
    await stderr.flush();
    await stdout.flush();
    exit(usage.code);
  } catch (error, stack) {
    await _fail('打包失败：$error\n$stack', 1);
  }
}

Future<void> _package(List<String> args) async {
  final _Options options = _Options.parse(args);
  final Directory root = Directory.current;
  if (!File(_join(root.path, 'pubspec.yaml')).existsSync() ||
      !File(_join(root.path, 'packages/tree_core_cli/bin/tree_core.dart'))
          .existsSync()) {
    await _fail('请在仓库根目录运行（找不到 pubspec.yaml 或核心入口）', 2);
  }

  final Map<String, String> pubspec = _readPubspec(root);
  final String appName = pubspec['name'] ?? 'tree';
  // 应用可执行文件名来自 windows/CMakeLists.txt 的 BINARY_NAME（不是 pubspec 的
  // name）：本项目里是 Tree.exe，写死成 name 会找不到文件（M7f 第一次跑就踩了）
  final String appExeName = '${_binaryName(root)}.exe';
  final String version = options.version ?? _versionOf(pubspec['version']);
  const String coreEntry = 'packages/tree_core_cli/bin/tree_core.dart';
  final Directory releaseDir = options.releaseDir != null
      ? Directory(options.releaseDir!)
      : Directory(_join(root.path, 'build/windows/x64/runner/Release'));
  final Directory outDir = Directory(_join(root.path, options.out));
  final String coreExe = _join(releaseDir.path, 'tree_core.exe');
  final String appExe = _join(releaseDir.path, appExeName);

  // ① 构建应用（可跳过）
  if (!options.skipBuild) {
    final String flutter = options.flutter ?? _flutterFromEnv();
    if (flutter.isEmpty) {
      await _fail(
        '未指定 Flutter SDK：请传 --flutter <flutter.bat>，'
        '或设置 FLUTTER_ROOT 环境变量。',
        2,
      );
    }
    stdout.writeln('== 构建 Windows 发行版（$flutter）==');
    final int code = await _runLive(flutter, <String>[
      'build',
      'windows',
      '--release',
    ], root.path);
    if (code != 0) {
      await _fail('flutter build windows 失败（exit=$code）', code);
    }
  }
  if (!File(appExe).existsSync()) {
    await _fail('找不到应用可执行文件：$appExe（先构建，或检查 --release-dir）', 3);
  }

  // ② 编译核心并放进同一个目录（发行版布局的硬要求）
  final String flutterRoot = _flutterRoot(options.flutter);
  final String dart = _dartOf(flutterRoot);
  stdout.writeln('== 编译核心进程（$dart）==');
  final int compileCode = await _runLive(dart, <String>[
    'compile',
    'exe',
    coreEntry,
    '-o',
    coreExe,
  ], root.path);
  if (compileCode != 0) {
    await _fail('核心编译失败（exit=$compileCode）', compileCode);
  }
  final int coreSize = File(coreExe).lengthSync();
  stdout.writeln(
    '   核心：$coreExe（${(coreSize / 1024 / 1024).toStringAsFixed(1)} MB）',
  );

  // ②b 原生资源（Dart native assets）拷进发行目录
  //
  // pdfrx 用 native assets 带 pdfium：flutter build windows 会把 DLL 生成到
  // build/native_assets/windows/ 并写进 data/flutter_assets/NativeAssetsManifest.json，
  // 但**不会**把它放到 exe 旁边。运行期按 `pdfium.dll` 这个文件名加载时，Windows
  // 的 DLL 搜索顺序里只有"应用目录"最可靠，所以打包这步必须自己拷——漏了的话
  // 用户机器上一打开 PDF 就报找不到 pdfium（本机测试发现不了：测试环境用的是
  // .dart_tool/lib 下的那份）。
  final Directory nativeAssets = Directory(
    _join(root.path, 'build/native_assets/windows'),
  );
  if (nativeAssets.existsSync()) {
    for (final FileSystemEntity entity in nativeAssets.listSync()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.dll')) {
        continue;
      }
      final String name = _basename(entity.path);
      entity.copySync(_join(releaseDir.path, name));
      stdout.writeln(
        '   原生库：$name（${(entity.lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB）',
      );
    }
  }

  // ③ 便携包说明（首次运行指引：数据在哪、怎么手改配置、出问题看哪）
  final File guide = File(_join(releaseDir.path, '使用说明.txt'));
  // 带 UTF-8 BOM 写出：目标是 Windows 用户，记事本/PowerShell 5.1 对无 BOM 的
  // UTF-8 会按 ANSI 解码，中文说明直接变乱码（实测 Get-Content 就是这样）
  guide.writeAsBytesSync(<int>[
    0xEF,
    0xBB,
    0xBF,
    ...utf8.encode(_portableGuide),
  ], flush: true);

  // ④ 自检：真的启动一次打包好的核心，读到握手再让它优雅退出
  if (!options.skipVerify) {
    stdout.writeln('== 自检：启动打包好的核心并读握手 ==');
    await _verifyCore(coreExe, root.path);
  }

  // ⑤ 压缩为便携 zip（bsdtar 的 -a 按扩展名推断 zip）
  Directory(outDir.path).createSync(recursive: true);
  String? zipPath;
  if (!options.noZip) {
    zipPath = _join(outDir.path, 'tree-desktop-$version-windows-x64.zip');
    if (File(zipPath).existsSync()) File(zipPath).deleteSync();
    stdout.writeln('== 打包 zip（tar -a）==');
    final int zipCode = await _runLive('tar', <String>[
      '-a',
      '-cf',
      zipPath,
      '-C',
      releaseDir.parent.path,
      _basename(releaseDir.path),
    ], root.path);
    if (zipCode != 0) {
      await _fail('压缩失败（exit=$zipCode）', zipCode);
    }
    stdout.writeln(
      '   产物：$zipPath'
      '（${(File(zipPath).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB）',
    );
  }

  // ⑥ 可选：Inno Setup 安装包（本机没装 iscc 时给出手工命令，不假装成功）
  if (options.installer) {
    final String iscc = options.iscc ?? _findIscc() ?? '';
    if (iscc.isEmpty) {
      stdout.writeln(
        '== 跳过安装包：没找到 ISCC.exe ==\n'
        '   装好 Inno Setup 后可用 --iscc <路径> 指定，或手工执行：\n'
        '   iscc /DAppName=$appName /DAppExe=$appExeName /DAppVersion=$version '
        '/DReleaseDir="${releaseDir.path}" tool/installer/tree-desktop.iss',
      );
    } else {
      stdout.writeln('== 编译安装包（$iscc）==');
      final int code = await _runLive(iscc, <String>[
        '/DAppName=$appName',
        '/DAppExe=$appExeName',
        '/DAppVersion=$version',
        '/DReleaseDir=${releaseDir.path}',
        'tool/installer/tree-desktop.iss',
      ], root.path);
      if (code != 0) {
        await _fail('安装包编译失败（exit=$code）', code);
      }
    }
  }

  stdout.writeln('');
  stdout.writeln('完成。');
  stdout.writeln('  便携目录：${releaseDir.path}');
  stdout.writeln('  应用：$appExe');
  stdout.writeln('  核心：$coreExe');
  if (zipPath != null) stdout.writeln('  zip：$zipPath');
  stdout.writeln('  数据目录（首次运行自动创建）：%APPDATA%\\Tree');
}

/// 便携包内的使用说明（首次运行指引）。
const String _portableGuide = '''
Tree 桌面端（Windows 便携版）
============================

怎么启动
  双击 Tree.exe。它会在同目录启动 tree_core.exe（核心进程：随机端口 + 一次性
  token，只监听 127.0.0.1），界面与数据全部走这个本地核心，不连任何服务器。

数据放在哪里
  %APPDATA%\\Tree（C:\\Users\\<你>\\AppData\\Roaming\\Tree）。
  目录结构（都可以直接用记事本改，改完重启应用生效）：
    config/settings.yaml        全局设置（token 帧率 / 推送帧率 / 消息切入…）
    config/models/<id>.yaml     每个模型一个文件（含明文 api_key，只在本机）
    config/mcp.yaml             MCP 服务（stdio 命令 + 环境变量）
    config/plugins.yaml         插件清单
    agents/<id>.yaml            agent 配置（system prompt / 模型 / ssh / workspace_dir）
    spec/builtin/*.md           内置 Spec 模板
    data/<agent>/<session>/     会话数据：session.json + messages.jsonl（一行一条消息）

出问题先看这里
  - 提示"未找到核心进程可执行文件 tree_core.exe"：确认 tree_core.exe 与 Tree.exe
    在同一目录（整包解压，不要只复制主程序）。
  - 想把核心放别处：设置环境变量 TREE_CORE_EXE 指向它。
  - 想单独调试核心 / 对接已运行的核心：设置 TREE_CORE_URL 与 TREE_CORE_TOKEN
    附着过去（两者都要设）。
  - 换数据目录：启动参数 --data-dir <目录>。
''';

/// 打印错误并退出：**必须显式 flush**，否则 exit() 会把缓冲里的输出丢掉。
Future<Never> _fail(String message, int code) async {
  try {
    stderr.writeln(message);
    await stderr.flush();
    await stdout.flush();
  } catch (_) {
    // 输出流已关闭：能报的已经报了，别在兜底路径上再炸一次
  }
  exit(code);
}

/// 启动核心读握手（打包产物自检）。
Future<void> _verifyCore(String coreExe, String workdir) async {
  final Directory dataDir = Directory.systemTemp.createTempSync('tree_pkg_');
  final Process process = await Process.start(coreExe, <String>[
    '--data-dir',
    dataDir.path,
    '--no-heartbeat',
  ], workingDirectory: workdir);
  try {
    final String firstLine = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 30));
    final CoreHandshake? handshake = CoreHandshake.decode(firstLine);
    if (handshake == null) {
      throw StateError('stdout 首行不是握手：$firstLine');
    }
    stdout.writeln('   握手 OK：${handshake.httpBaseUrl}（pid ${handshake.pid}）');
    process.stdin.writeln('shutdown');
    await process.stdin.flush();
    final int code = await process.exitCode.timeout(
      const Duration(seconds: 30),
    );
    if (code != 0) throw StateError('核心退出码非 0：$code');
    stdout.writeln('   优雅退出 OK');
  } finally {
    try {
      process.kill();
    } catch (_) {
      // 已退出
    }
    for (int i = 0; i < 5; i++) {
      try {
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }
}

/// 运行子进程并把输出**实时**透传（构建动辄几分钟，不能憋到结束才打印）。
Future<int> _runLive(
  String executable,
  List<String> args,
  String workdir,
) async {
  stdout.writeln('   > $executable ${args.join(' ')}');
  await stdout.flush();
  final Process process = await Process.start(
    executable,
    args,
    workingDirectory: workdir,
  );
  // 注意：不能用 pipe()——Stream.pipe 会在源结束时**关闭 stdout**，之后任何
  // 输出都会抛 "StreamSink is closed"（第一次跑这个脚本就踩了：编译完就静默
  // 退出，什么都看不到）。forEach + add 只转发，不关闭。
  final Future<void> out = process.stdout.forEach(stdout.add);
  final Future<void> err = process.stderr.forEach(stderr.add);
  final int code = await process.exitCode;
  await out;
  await err;
  return code;
}

Map<String, String> _readPubspec(Directory root) {
  final Map<String, String> out = <String, String>{};
  for (final String line in File(
    _join(root.path, 'pubspec.yaml'),
  ).readAsLinesSync()) {
    final int idx = line.indexOf(':');
    if (idx <= 0) continue;
    final String key = line.substring(0, idx).trim();
    if (key == 'name' || key == 'version') {
      out[key] = line.substring(idx + 1).trim().replaceAll('"', '');
    }
  }
  return out;
}

/// 应用可执行文件名（不含 .exe）：取 windows/CMakeLists.txt 的 BINARY_NAME。
///
/// 这是 Windows 发行版的唯一事实来源：pubspec 的 name 决定 package 名与产物目录，
/// 而 CMake 的 BINARY_NAME 才决定 exe 叫什么。取不到时退回 pubspec 的 name。
String _binaryName(Directory root) {
  final File cmake = File(_join(root.path, 'windows/CMakeLists.txt'));
  if (cmake.existsSync()) {
    final RegExpMatch? match = RegExp(r'set\(BINARY_NAME\s+"([^"]+)"\)')
        .firstMatch(cmake.readAsStringSync());
    if (match != null && match.group(1)!.trim().isNotEmpty) {
      return match.group(1)!.trim();
    }
  }
  final Map<String, String> pubspec = _readPubspec(root);
  return pubspec['name'] ?? 'tree';
}

/// 1.0.0+1 → 1.0.0（构建号不进版本号，避免把 +1 写进文件名）。
String _versionOf(String? raw) {
  final String value = (raw ?? '').trim();
  if (value.isEmpty) return '0.0.0';
  final int plus = value.indexOf('+');
  return plus < 0 ? value : value.substring(0, plus);
}

String _flutterFromEnv() {
  final String root = Platform.environment['FLUTTER_ROOT'] ?? '';
  if (root.isEmpty) return '';
  final String bat = _join(root, 'bin/flutter.bat');
  return File(bat).existsSync() ? bat : '';
}

/// 由 --flutter 推出 SDK 根目录（接受 flutter.bat 路径或 SDK 根目录）。
String _flutterRoot(String? flutter) {
  if (flutter != null && flutter.trim().isNotEmpty) {
    String path = flutter.trim();
    if (File(path).existsSync() && _basename(path).startsWith('flutter')) {
      path = Directory(path).parent.path;
      if (_basename(path) == 'bin') path = Directory(path).parent.path;
      return path;
    }
    return path;
  }
  return Platform.environment['FLUTTER_ROOT'] ?? '';
}

/// 用**与构建应用同一个 SDK** 的 dart 编译核心；找不到才退回当前进程。
String _dartOf(String flutterRoot) {
  if (flutterRoot.isNotEmpty) {
    final String candidate = _join(
      flutterRoot,
      'bin/cache/dart-sdk/bin/dart.exe',
    );
    if (File(candidate).existsSync()) return candidate;
  }
  return Platform.resolvedExecutable;
}

/// 找 Inno Setup 编译器：PATH 优先，其次常见安装目录。
///
/// 为什么不能只看 PATH：Inno 的安装器默认**不**把自己加进 PATH（本机就装在
/// D:\app\Inno Setup 6，直接敲 iscc 是找不到的），只报「没有 iscc」会让用户以为
/// 没装成功。
String? _findIscc() {
  final String? onPath = _which('iscc');
  if (onPath != null) return onPath;
  final List<String> roots = <String>[
    r'C:\Program Files (x86)\Inno Setup 6',
    r'C:\Program Files\Inno Setup 6',
    r'D:\app\Inno Setup 6',
    r'D:\Program Files (x86)\Inno Setup 6',
    '${Platform.environment['LOCALAPPDATA'] ?? ''}\\Programs\\Inno Setup 6',
  ];
  for (final String root in roots) {
    if (root.trim().isEmpty) continue;
    final File candidate = File(_join(root, 'ISCC.exe'));
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

String? _which(String exe) {
  final String pathVar = Platform.environment['PATH'] ?? '';
  for (final String dir in pathVar.split(Platform.isWindows ? ';' : ':')) {
    if (dir.trim().isEmpty) continue;
    for (final String ext in <String>['.exe', '.bat', '.cmd', '']) {
      final File candidate = File(_join(dir.trim(), '$exe$ext'));
      if (candidate.existsSync()) return candidate.path;
    }
  }
  return null;
}

String _join(String a, String b) {
  final String left = a.endsWith(Platform.pathSeparator)
      ? a.substring(0, a.length - 1)
      : a;
  final String right = b.startsWith('/') || b.startsWith('\\')
      ? b.substring(1)
      : b;
  final String normalized = right.replaceAll('/', Platform.pathSeparator);
  return '$left${Platform.pathSeparator}$normalized';
}

String _basename(String path) {
  final int idx = path.lastIndexOf(Platform.pathSeparator);
  return idx < 0 ? path : path.substring(idx + 1);
}

/// 用法提示（--help / 未知参数）：带着退出码往上抛，好让 main 先 flush 再退出。
class _UsageError implements Exception {
  const _UsageError(this.code, [this.message = '']);

  final int code;
  final String message;
}

/// 命令行选项。
class _Options {
  const _Options({
    this.flutter,
    this.iscc,
    this.skipBuild = false,
    this.releaseDir,
    this.out = 'dist',
    this.version,
    this.installer = false,
    this.noZip = false,
    this.skipVerify = false,
  });

  final String? flutter;
  final String? iscc;
  final bool skipBuild;
  final String? releaseDir;
  final String out;
  final String? version;
  final bool installer;
  final bool noZip;
  final bool skipVerify;

  static _Options parse(List<String> args) {
    String? flutter;
    String? iscc;
    String? releaseDir;
    String out = 'dist';
    String? version;
    bool skipBuild = false;
    bool installer = false;
    bool noZip = false;
    bool skipVerify = false;
    for (int i = 0; i < args.length; i++) {
      String value() => i + 1 < args.length ? args[++i] : '';
      switch (args[i]) {
        case '--flutter':
          flutter = value();
        case '--iscc':
          iscc = value();
        case '--release-dir':
          releaseDir = value();
          skipBuild = true;
        case '--out':
          out = value();
        case '--version':
          version = value();
        case '--skip-build':
          skipBuild = true;
        case '--installer':
          installer = true;
        case '--no-zip':
          noZip = true;
        case '--skip-verify':
          skipVerify = true;
        case '--help':
        case '-h':
          throw const _UsageError(0);
        default:
          throw _UsageError(2, '未知参数：${args[i]}');
      }
    }
    return _Options(
      flutter: flutter,
      iscc: iscc,
      skipBuild: skipBuild,
      releaseDir: releaseDir,
      out: out,
      version: version,
      installer: installer,
      noZip: noZip,
      skipVerify: skipVerify,
    );
  }
}
