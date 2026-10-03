import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    // `--no-tree-shake-icons`：**不要**让构建去子集化图标字体。
    //
    // 实测（2026-10-04，用户报"这个按钮为什么是黑的"）：子集化会**静默丢掉**
    // 明明在用的图标——同一批代码里 `Icons.auto_awesome` / `Icons.hub`（老代码）
    // 在子集里，而 `Icons.badge_outlined`（临时员工入口）、`Icons.difference`、
    // `Icons.keyboard_double_arrow_left/right`（文件树开关）、`Icons.chat_bubble`、
    // `Icons.folder`（移动端 tab 的 selectedIcon）、`Icons.visibility(_off)`
    // （三元表达式里选的图标）**全都不在**。字形缺失时 Icon 画不出任何东西：
    // 按钮还在、tooltip 还在，但看上去就是**一片空白/黑**——这是最难查的一类
    // "发布版才有、开发机没有"的毛病（Debug 不做子集化）。
    // 代价只是字体从 18 KB 变 1.6 MB（安装包 +~0.5 MB），换来"图标永远画得出来"。
    final int code = await _runLive(flutter, <String>[
      'build',
      'windows',
      '--release',
      '--no-tree-shake-icons',
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

  // ②a 图标字体门禁：`lib/` 里用到的每个 Icons.* 都必须真在字体里
  // （见 §① 的说明：子集化/字体缺失 = 按钮一片空白，且只有发布版才看得见）
  await _checkIconFont(root, flutterRoot, releaseDir);

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

  // ②c 内置插件脚本：examples/plugins/ → 发行目录 plugins/（与 Tree.exe / tree_core.exe 同级）
  //
  // 为什么必须拷：核心按**自身可执行文件同级的** plugins/<name>.py 解析内置插件的
  // 脚本（见 packages/tree_core/lib/src/plugin/builtin_plugins.dart 的 scriptRoots）。
  // 漏了这一层，用户在界面上打开「示例插件」只会得到"找不到内置插件脚本"。
  // 目录不存在不算失败（有人可能只要核心，不带示例脚本），但要**打印一行**说明。
  final _PluginCopy plugins = _copyPlugins(root, releaseDir);
  stdout.writeln(
    !plugins.sourceExists
        ? '   插件脚本：跳过（没有 examples/plugins 目录）'
        : '   插件脚本：plugins/（${plugins.copied} 个文件'
              '${plugins.skipped > 0 ? '，跳过 ${plugins.skipped} 个本地产物' : ''}）',
  );

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
  目录结构（都可以直接用记事本改；工作空间里的提示词/规范改完下一轮生效，
  其余在重启核心后生效）：
    config/settings.yaml        全局设置（token 帧率 / 推送帧率 / 消息切入…）
    config/models/<id>.yaml     每个模型一个文件（含明文 api_key，只在本机）
    config/mcp.yaml             MCP 服务（stdio 命令 + 环境变量）
    config/plugins.yaml         插件清单（内置与自定义插件各有一个开关）
    agents/<id>.yaml            agent 配置（system prompt / 模型 / ssh / workspace_dir）
    workspaces/<agent>/.self/   该工作空间/团队的私有状态（按团队分隔）：
        system_prompt.md        系统提示词基础段（改完保存，下一轮对话即生效）
        spec/*.md               内置 + 自定义 Spec（右栏可一键重置，旧文件备份 .bak.N）
    data/<agent>/<session>/     会话数据：session.json + messages.jsonl（一行一条消息）

内置插件
  plugins/ 目录与 Tree.exe 同级，里面是核心自带的示例插件脚本。界面上「插件」页把
  内置插件与自定义插件分开列出，每一项都有自己的开关；打开内置插件时核心会去探测
  Python（python / py -3）并解析 plugins/<name>.py 的绝对路径，两者缺一都会给可读
  错误（装了 Python 之后点面板上的刷新即可重新探测）。

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

/// 一次插件脚本拷贝的结果。
///
/// [sourceExists] 单独一个字段：`examples/plugins` 不存在（"没有可拷的"）与
/// "拷了 0 个文件"是两件事，日志与调用方要能区分（原来用一个 -1 表达；加了
/// "跳过几个"之后，继续挤在一个 int 里会更难读）。
class _PluginCopy {
  const _PluginCopy({
    required this.sourceExists,
    this.copied = 0,
    this.skipped = 0,
  });

  const _PluginCopy.missing() : this(sourceExists: false);

  final bool sourceExists;

  /// 真正拷进去的文件数（含指南副本）。
  final int copied;

  /// 被当作"本地产物"跳过的文件数（见 [_isPluginJunkPath]）。
  final int skipped;
}

/// **不该进发行包**的目录名：本地跑插件留下的缓存与环境。
///
/// 实际踩到的：在仓库里用 python 跑一次示例插件，目录里就多出 `__pycache__/*.pyc`；
/// 而打包脚本原来是**整目录递归复制**，于是两个字节码文件一路进了 `Release/plugins/`，
/// 再被 zip 与安装包原样带走（用户机器上纯属垃圾，也让"包里到底有什么"说不清）。
const Set<String> _pluginJunkDirs = <String>{
  '__pycache__',
  '.git',
  '.venv',
  'venv',
  '.mypy_cache',
  '.pytest_cache',
  '.ruff_cache',
  '.idea',
};

/// 相对路径是否属于"本地产物"：任一路径段命中 [_pluginJunkDirs]，或是字节码文件。
bool _isPluginJunkPath(String relative) {
  final List<String> segments = relative.split(RegExp(r'[\\/]+'));
  for (final String segment in segments) {
    if (_pluginJunkDirs.contains(segment.toLowerCase())) return true;
  }
  final String name = segments.isEmpty ? relative : segments.last;
  final String lower = name.toLowerCase();
  return lower.endsWith('.pyc') || lower.endsWith('.pyo');
}

/// 把 examples/plugins/ 复制到发行目录的 plugins/。
///
/// 递归复制、保留子目录结构：插件常带自己的模块与数据文件；但**跳过本地产物**
/// （[_pluginJunkDirs] 里的目录与 `.pyc`/`.pyo`，见 [_isPluginJunkPath]），
/// 并顺手清掉目标目录里同类的残留（上一轮构建留下的、这一轮才发现不该在里面）。
///
/// 为什么不"先清空目标再拷"：`--release-dir` 可以指向任意目录（包括用户装好的
/// 应用目录），那里的 `plugins/` 下可能有用户自己放的插件，整目录删除会把它一起抹掉；
/// 只删自己认得出来的产物，是这里刻意的保守取舍。
///
/// **另外**把 `docs/plugin-development.md`（系统性插件开发指南）也拷进 `plugins/`：
/// 应用内「打开插件开发说明」首先找的就是 `plugins/plugin-development.md`
/// （见 `lib/app_version.dart` 的 `PluginDocs`），发行版因此不必带整个 `docs/`。
/// 指南缺失不算失败（会退回 `plugins/README.md`），所以这里静默跳过。
_PluginCopy _copyPlugins(Directory root, Directory releaseDir) {
  final Directory source = Directory(_join(root.path, 'examples/plugins'));
  if (!source.existsSync()) return const _PluginCopy.missing();
  final Directory target = Directory(_join(releaseDir.path, 'plugins'))
    ..createSync(recursive: true);
  // 目标里的同类残留：只删认得出来的产物（保守起见不整目录重建）。
  for (final FileSystemEntity entity in target.listSync()) {
    final String name = _basename(entity.path).toLowerCase();
    final bool junkDir = entity is Directory && _pluginJunkDirs.contains(name);
    final bool junkFile =
        entity is File && (name.endsWith('.pyc') || name.endsWith('.pyo'));
    if (junkDir || junkFile) entity.deleteSync(recursive: true);
  }
  int copied = 0;
  int skipped = 0;
  for (final FileSystemEntity entity in source.listSync(recursive: true)) {
    if (entity is! File) continue;
    final String relative = entity.path
        .substring(source.path.length)
        .replaceAll(RegExp(r'^[\\/]+'), '');
    if (relative.isEmpty) continue;
    if (_isPluginJunkPath(relative)) {
      skipped++;
      continue;
    }
    final File destination = File(_join(target.path, relative));
    destination.parent.createSync(recursive: true);
    entity.copySync(destination.path);
    copied++;
  }
  final File guide = File(
    _join(root.path, _join('docs', 'plugin-development.md')),
  );
  if (guide.existsSync()) {
    guide.copySync(_join(target.path, 'plugin-development.md'));
    copied++;
  }
  return _PluginCopy(sourceExists: true, copied: copied, skipped: skipped);
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

/// 图标字体门禁（发布前必须过）：`lib/` 里用到的每个 `Icons.*` 都要真在字体里。
///
/// 为什么这是**打包脚本**的活而不是测试的活：字体只有在 `flutter build windows
/// --release` 之后才存在，而"图标画不出来"这件事**只有发布版会犯**（Debug 不子集化
/// 字体）。真机现场（2026-10-04）：临时员工入口是个**空白按钮**——tooltip 有、点击有
/// 反应，就是画不出字形，因为发布版的字体子集里没有 `badge_outlined`。
///
/// 两道防线，这里是第二道（第一道是构建参数 `--no-tree-shake-icons`）：
/// 万一有人把第一道去掉，这里会立刻点名"哪几个图标在用、但字体里没有"，
/// 而不是把一堆空白按钮发给用户。
Future<void> _checkIconFont(
  Directory root,
  String flutterRoot,
  Directory releaseDir,
) async {
  final File font = File(
    _join(
      releaseDir.path,
      'data/flutter_assets/fonts/MaterialIcons-Regular.otf',
    ),
  );
  if (!font.existsSync()) {
    await _fail('图标字体不存在：${font.path}（flutter_assets 不完整？）', 4);
  }
  final Set<int> available = _fontCodepoints(font.readAsBytesSync());
  final Map<String, List<String>> used = _iconsUsedInLib(root);
  final Map<String, int> codepoints = _iconCodepoints(flutterRoot);
  final List<String> missing = <String>[];
  final List<String> unknown = <String>[];
  used.forEach((String name, List<String> where) {
    final int? code = codepoints[name];
    if (code == null) {
      unknown.add(name);
      return;
    }
    if (!available.contains(code)) {
      missing.add('$name（0x${code.toRadixString(16)}，用在 ${where.join('、')}）');
    }
  });
  if (missing.isNotEmpty) {
    await _fail(
      '图标字体缺 ${missing.length} 个"代码里在用的"图标 —— '
      '这些按钮会渲染成**一片空白**（字形没有，画不出东西）：\n'
      '  - ${missing.join('\n  - ')}\n'
      '修法：确认构建带了 --no-tree-shake-icons（见本文件 §①），或删掉 '
      'build/flutter_assets 重新构建。',
      4,
    );
  }
  stdout.writeln(
    '   图标字体：${used.length} 个 Icons.* 全覆盖'
    '（字体覆盖 ${available.length} 个码点${unknown.isEmpty ? '' : '，'
        '${unknown.length} 个别名没解析：${unknown.join('、')}'}）',
  );
}

/// `lib/**/*.dart` 里出现过的 `Icons.<名字>`（值 = 出现在哪些文件里，报错时点名）。
///
/// `Icons.adaptive` 是命名空间（`Icons.adaptive.more` 之类），不是图标本身，跳过。
Map<String, List<String>> _iconsUsedInLib(Directory root) {
  final RegExp pattern = RegExp(r'Icons\.(\w+)');
  final Map<String, List<String>> out = <String, List<String>>{};
  final Directory lib = Directory(_join(root.path, 'lib'));
  for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final String source = entity.readAsStringSync();
    for (final RegExpMatch match in pattern.allMatches(source)) {
      final String name = match.group(1)!;
      if (name == 'adaptive') continue;
      final String where = entity.path
          .substring(root.path.length + 1)
          .replaceAll('\\', '/');
      (out[name] ??= <String>[]).add(where);
    }
  }
  return out;
}

/// Flutter SDK 的 `icons.dart` → 图标名到码点。别名（`static const IconData a = b;`）
/// 也解开，免得把"用了别名"误报成"字体里没有"。
Map<String, int> _iconCodepoints(String flutterRoot) {
  final File file = File(
    _join(flutterRoot, 'packages/flutter/lib/src/material/icons.dart'),
  );
  final Map<String, int> out = <String, int>{};
  if (!file.existsSync()) return out;
  final String source = file.readAsStringSync();
  final Map<String, String> alias = <String, String>{};
  // 定义可能跨行（`IconData(\n  0xe5c4,`），所以用 dotAll + \s*
  final RegExp direct = RegExp(
    r'static const IconData (\w+)\s*=\s*IconData\(\s*0x([0-9a-fA-F]+)',
    dotAll: true,
  );
  for (final RegExpMatch match in direct.allMatches(source)) {
    out[match.group(1)!] = int.parse(match.group(2)!, radix: 16);
  }
  for (final RegExpMatch match in RegExp(
    r'static const IconData (\w+)\s*=\s*(\w+)\s*;',
  ).allMatches(source)) {
    alias[match.group(1)!] = match.group(2)!;
  }
  alias.forEach((String name, String target) {
    final int? code = out[target];
    if (code != null) out[name] = code;
  });
  return out;
}

/// 解析 TrueType/OpenType 的 `cmap` 表，返回字体真正覆盖的码点。
///
/// 只认格式 4（BMP 分段映射）与格式 12（完整 Unicode 分组映射）：Material 图标
/// 字体两种都有，覆盖到就够判断"这个字形在不在"。手写而不是引依赖——工具与核心
/// 都保持零第三方依赖。
Set<int> _fontCodepoints(Uint8List bytes) {
  final ByteData data = ByteData.view(
    bytes.buffer,
    bytes.offsetInBytes,
    bytes.length,
  );
  int u16(int offset) => data.getUint16(offset);
  int u32(int offset) => data.getUint32(offset);
  int? cmap;
  final int tables = u16(4);
  for (int i = 0; i < tables; i++) {
    final int record = 12 + i * 16;
    final String tag = String.fromCharCodes(bytes, record, record + 4);
    if (tag == 'cmap') cmap = u32(record + 8);
  }
  final Set<int> out = <int>{};
  if (cmap == null) return out;
  final int subtables = u16(cmap + 2);
  for (int i = 0; i < subtables; i++) {
    final int record = cmap + 4 + i * 8;
    final int sub = cmap + u32(record + 4);
    final int format = u16(sub);
    if (format == 4) {
      final int segX2 = u16(sub + 6);
      final int segments = segX2 ~/ 2;
      for (int s = 0; s < segments; s++) {
        final int start = u16(sub + 16 + segX2 + s * 2);
        final int end = u16(sub + 14 + s * 2);
        if (start == 0xFFFF) continue;
        for (int code = start; code <= end && code != 0xFFFF; code++) {
          out.add(code);
        }
      }
    } else if (format == 12) {
      final int groups = u32(sub + 12);
      for (int g = 0; g < groups; g++) {
        final int group = sub + 16 + g * 12;
        final int start = u32(group);
        final int end = u32(group + 4);
        for (int code = start; code <= end; code++) {
          out.add(code);
        }
      }
    }
  }
  return out;
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
