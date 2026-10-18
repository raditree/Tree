import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'builtin_plugins.dart'
    show BuiltinPluginCatalog, BuiltinPluginSpec, BuiltinRuntime;
import 'plugin_host.dart' show PluginSuspension;

/// 插件**发布**仓库（GitHub Releases）的默认坐标。
///
/// 为什么只读 release、不 `git clone` 源码：`raditree/tree-plugins` 里放的是插件的
/// **源代码**（给人改的），而装机端的插件管理要的是**已发布的成品**。把"能拉到源码"
/// 当成"能装上"会造出一条没人审的路径：源目录的形状、构建产物在不在、谁负责编译，
/// 全都要在用户机器上猜。release 资产由发布方一次性备好，索引（`plugin-index.json`）
/// 就是那张合同，装机端只核合同。
const String kTreePluginsRepo = 'raditree/tree-plugins';

/// GitHub REST 基址（公开仓库匿名可读；限流时给可读原因，不静默重试到永远）。
const String kGitHubApiBase = 'https://api.github.com';

/// 发布索引资产的**固定文件名**（release 必须带它，否则这一版没得上）。
///
/// 为什么不是"从资产名里猜哪个是插件"：猜出来的清单会让"少传了一个文件"表现为
/// "某个插件莫名其妙消失了"。索引是显式的 ⇒ 缺什么就说缺什么。
const String kPluginIndexAsset = 'plugin-index.json';

/// 索引的 schema 版本（现在是 1；将来不兼容改动要在这里升，并按版本给可读原因，
/// 而不是让旧核心把新字段读成 null 再"看起来成功了"）。
const int kPluginIndexSchema = 1;

/// 条目在 `plugins.yaml` 里留下的来源标记（**只是展示用**，行为不读它）。
///
/// 为什么未知键可以留：`PluginConfigStore` 的纪律是"写回保留未知键"（不变量 10），
/// 而面板要回答"这一条是从发布仓库装的、装的是哪一版"。行为（怎么拉起、能不能挂起）
/// 全部来自已知键，所以这个标记坏了也不影响运行。
const String kRepoSourceKey = 'source';
const String kRepoSourceValue = 'release';
const String kRepoVersionKey = 'repo_version';

/// 发布插件的**放置目录**默认值：核心可执行文件同级的 `plugins/`。
///
/// 为什么是这一份而不是数据根：它是 `BuiltinPluginCatalog.scriptRoots()` 的
/// **第 1 优先级**（发行包的正规位置）。装到那里 = 不需要再配任何搜索路径，
/// 下一次拉起就能被解析到；装到别处只会多出一条“命令指不到”的条目。
String defaultPluginInstallDir({String? executablePath}) =>
    p.join(p.dirname(executablePath ?? Platform.resolvedExecutable), 'plugins');

/// 一次 HTTP GET（测试注入假的 ⇒ 整条发布链可以离线测，包括"资产缺一半"这种形状）。
typedef PluginFetcher = Future<PluginFetchResult> Function(
  Uri url, {
  Map<String, String>? headers,
});

/// 脚本型插件的解释器解析（生产接 `BuiltinPluginCatalog.detectRuntime`；null = 没有）。
///
/// 为什么回一个 `BuiltinRuntime`（命令 + 前缀参数）而不是一个字符串：Windows 上
/// 命中的常常是 `py -3` 这种两件套，把它塞进一个字符串再当命令拉起 = 必挂。
typedef PluginRuntimeResolver = Future<BuiltinRuntime?> Function();

/// 已落盘条目的读取器（生产接 `PluginConfigStore.readEntry`，用来判断"有没有更新"）。
typedef PluginInstalledEntryReader = Map<String, dynamic>? Function(
  String pluginId,
);

/// 换文件前的闸门：返回空串 = 可以换；否则是**为什么现在不能换**的可读原因。
///
/// 为什么必须由调用方给：只有 `PluginBus` 知道"这个插件的进程还在不在"。核心
/// **不会**为了换一个文件去杀一个进程（显式强杀只有用户按「强制停止」那一条路），
/// 也不能"先删了再说"—— Windows 上正在运行的 exe 删不掉，失败还会把旧文件一起带走。
typedef PluginSwapGate = Future<String> Function(String pluginId);

/// 一次 HTTP 的结果（状态码 + 字节；失败也带可读原因，不抛异常出边界）。
class PluginFetchResult {
  const PluginFetchResult({
    required this.statusCode,
    this.bytes = const <int>[],
    this.error = '',
  });

  factory PluginFetchResult.failure(String error) =>
      PluginFetchResult(statusCode: 0, error: error);

  final int statusCode;
  final List<int> bytes;
  final String error;

  bool get ok => error.isEmpty && statusCode >= 200 && statusCode < 300;
}

/// 一条要放进 `plugins/` 的文件（索引里的 `files[]` 项）。
class PluginRepoFile {
  const PluginRepoFile({
    required this.asset,
    required this.target,
    this.bytes = 0,
  });

  /// release 资产名（去那儿下载）。
  final String asset;

  /// 落到 `plugins/` 的文件名（**必须纯文件名**，防越界）。
  final String target;

  /// 索引声明的字节数（>0 时才核对：GitHub 的 `size` 与这里的显式值取其一）。
  final int bytes;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'asset': asset,
    'target': target,
    if (bytes > 0) 'bytes': bytes,
  };
}

/// 发布仓库里一条插件条目（索引解析结果，已校验）。
class PluginRepoEntry {
  const PluginRepoEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.files,
    required this.command,
    required this.runtime,
    this.description = '',
    this.args = const <String>[],
    this.suspension = '',
    this.granularity = 'team',
    this.scope = const <String, dynamic>{},
    this.installedVersion = '',
  });

  final String id;
  final String name;
  final String version;
  final List<PluginRepoFile> files;

  /// 装完后用来拉起它的那个**目标文件名**（必在 [files] 的 target 里）。
  final String command;

  /// `binary`（随包可执行文件）/ `python`（脚本，需要解释器）。
  final String runtime;

  final String description;
  final List<String> args;
  final String suspension;
  final String granularity;
  final Map<String, dynamic> scope;

  /// 本机已落盘条目记的发布版本（没装过 = 空串）。
  final String installedVersion;

  /// 有没有更新可装：没装过，或发布版本比本机记的高。
  bool get hasUpdate =>
      installedVersion.isEmpty || _versionGreater(version, installedVersion);

  List<String> get targets =>
      files.map((PluginRepoFile file) => file.target).toList(growable: false);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'plugin_id': id,
    'name': name,
    'version': version,
    'description': description,
    'runtime': runtime,
    'command': command,
    'files': files.map((PluginRepoFile f) => f.toJson()).toList(),
    'suspension': suspension,
    'granularity': granularity,
    'installed_version': installedVersion,
    'has_update': hasUpdate,
  };
}

/// 一次"看发布仓库里有什么"的结果。
class PluginReleaseListing {
  const PluginReleaseListing({
    required this.ok,
    this.entries = const <PluginRepoEntry>[],
    this.skipped = const <String>[],
    this.error = '',
    this.tag = '',
    this.indexPath = '',
    this.online = false,
  });

  factory PluginReleaseListing.failed(String error, {String indexPath = ''}) =>
      PluginReleaseListing(ok: false, error: error, indexPath: indexPath);

  final bool ok;
  final List<PluginRepoEntry> entries;

  /// 每个被跳过的条目 + 为什么（面板显示"这一条为什么没出现"，不静默）。
  final List<String> skipped;
  final String error;

  /// 这一份索引来自哪个 release tag（离线读缓存时可能是空）。
  final String tag;

  /// 索引缓存文件的路径（诊断用：面板会显示"我读的是哪一份"）。
  final String indexPath;

  /// 这次是**联网取的**，还是读的本地缓存（面板要如实区分，别让离线看起来像最新）。
  final bool online;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ok': ok,
    'error': error,
    'tag': tag,
    'index_path': indexPath,
    'online': online,
    'count': entries.length,
    'entries': entries.map((PluginRepoEntry e) => e.toJson()).toList(),
    'skipped': skipped,
  };
}

/// 一次安装的结果。
class PluginInstallResult {
  const PluginInstallResult({
    required this.ok,
    this.pluginId = '',
    this.version = '',
    this.files = const <String>[],
    this.entry,
    this.error = '',
    this.swapped = false,
    this.downloaded = 0,
    this.note = '',
  });

  factory PluginInstallResult.failed(String error, {String pluginId = ''}) =>
      PluginInstallResult(ok: false, pluginId: pluginId, error: error);

  final bool ok;
  final String pluginId;
  final String version;

  /// 真正落到 `plugins/` 的文件名。
  final List<String> files;

  /// 该写进 `plugins.yaml` 的那一条（调用方负责落盘 + 热应用；见类注释）。
  final Map<String, dynamic>? entry;

  /// 是否真的替换了文件（false = 一步都没动旧文件）。
  final bool swapped;

  /// 这次从 release 下载了多少字节（0 = 缓存里已有，全部命中）。
  final int downloaded;
  final String error;
  final String note;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ok': ok,
    'plugin_id': pluginId,
    'version': version,
    'files': files,
    'config': entry,
    'swapped': swapped,
    'downloaded_bytes': downloaded,
    'error': error,
    'note': note,
  };
}

/// 插件**发布仓库**（GitHub Releases）的取清单、下载与放置。
///
/// 四段职责，刻意**不含**第五件（不落 plugins.yaml、不动插件总线）：
/// 1. [refresh]：`releases/latest` → 找到 `plugin-index.json` 资产 → 下载并缓存；
/// 2. [cachedListing]：读本地缓存列清单（**不联网**，面板"列表"用它；离线不冒充最新）；
/// 3. 索引校验：一个条目 = 一份合同 —— id 字符集与 `PluginConfigStore` 同一条（防路径
///    穿越）、`target` 必须是纯文件名、`command` 必须在文件表里、version 是三段数字；
///    **坏条目只跳过并写下原因**，不让一个手错的 JSON 把整份清单带走；
/// 4. [install]：资产下到缓存（临时名 + 原子改名，字节数对不上就失败）→ 过
///    [PluginSwapGate]（旧进程确认退出才换）→ 复制到 `plugins/` 的临时名 → 原子改名覆盖。
///
/// 为什么"落盘 + 热更新"在调用方（core_server）而不是这里：那是 `plugins.yaml` 唯一的
/// 既有路径（内置开关、自定义新增都走 `_pluginStore` + `_applyPluginChange`）。这里再
/// 写一遍 = 两套会漂移的语义，而漂移的代价是"面板说装好了、总线里却没有"。
class PluginDownloader {
  PluginDownloader({
    required this.cacheDir,
    required this.installDir,
    this.repo = kTreePluginsRepo,
    this.apiBase = kGitHubApiBase,
    this.accessToken = '',
    this.runtimeResolver,
    this.log,
    PluginFetcher? fetcher,
    HttpClient? client,
    String Function()? nonce,
    PluginInstalledEntryReader? installedEntryOf,
    Set<String> Function()? protectedFiles,
    this.isWindows,
  }) : fetcherOverride = fetcher,
       injectedClient = client,
       nonceFactory = nonce ?? _defaultNonce,
       installedReader = installedEntryOf ?? _noInstalledEntry,
       protectedOverride = protectedFiles;

  /// 没注入读条目时的默认：永远当"本机没装过"（判断有没有更新就保守地回答"有"）。
  static Map<String, dynamic>? _noInstalledEntry(String pluginId) => null;

  /// 下载缓存（`<数据根>/plugins_release`）：索引 + 资产都按 `<id>/<version>/` 分层放。
  final String cacheDir;

  /// 放置目录 = **可执行文件同级的 `plugins/`**（与 binary 型内置插件的查找路径同源）。
  final String installDir;

  /// `owner/name`（GitHub 仓库坐标；只用来拼 API，不 clone）。
  final String repo;

  final String apiBase;

  /// 可选 token（`GITHUB_TOKEN`）：公开仓库匿名可读，限流时才需要它。
  final String accessToken;

  /// 注入的 HTTP 取回器（null = 用本类自带的 `dart:io HttpClient`）。
  ///
  /// 为什么留这个口子而不是"测联网的用例全部门控"：**放置与校验**（索引坏条目跳过、
  /// 字节数不符不缓存、旧文件没动）是这段代码真正难的部分，它们不需要网络也能钉死。
  final PluginFetcher? fetcherOverride;

  /// 注入的 HTTP 客户端（只给测试控连接用）；null ⇒ 惰性自建并在 [close] 里收掉。
  final HttpClient? injectedClient;
  HttpClient? _ownedClient;

  final String Function() nonceFactory;

  /// 脚本型条目的解释器解析（null = 这台核心不接脚本 ⇒ python 条目安装时如实拒绝）。
  final PluginRuntimeResolver? runtimeResolver;

  /// 读已落盘条目（看“装的是哪一版”，从而判断有没有更新）。
  final PluginInstalledEntryReader installedReader;

  /// 成品文件名的平台口径（null = 本机）。**测试必须注入**：不注入的话，
  /// 夹具写 `tree_sample.exe` 而真实平台不是 Windows ⇒ 保护面算空，用例假绿。
  final bool? isWindows;

  /// 测试注入的覆盖（null = 用本机事实算，见 [protectedFileNames]）。
  final Set<String> Function()? protectedOverride;
  
  /// **本机不许被发布仓库覆盖的文件名**（按两个事实算，不按静态清单猜）。
  ///
  /// 2026-10-18 的口径变化（以前是 `BuiltinPluginCatalog.protectedFileNames()` 从清单推）：
  /// 插件成品不再随包之后，“清单项 = 随包成品”不成立，那张表会把**本机根本没有的文件**
  /// 当成受保护名 ⇒ 这些内置 id 从 release 永远装不上，而它们在面板上又开不了 ——
  /// 保护做过头，条目就彻底坏死。所以判据改成两个事实的**合取**：
  ///
  /// 1. `installDir/<文件名>` 确实存在 ⇒ 本机带着这一份成品；
  /// 2. 该 id 的条目**没打过 `source: release`** ⇒ 它是内置随包的那一份，不是上一次从
  ///    仓库装的。**这一半不能省**：随包成品与装进来的成品住在**同一个目录**，只看
  ///    “文件在不在”会把上一次刚装好的那条也变成受保护 ⇒ 从此它自己再也更新不了
  ///    （那是把保护做成死锁，而表现是“更新按下去没反应”）。
  ///
  /// 两条防线各管一面，别混淆：这一条管**文件名**（不撞内置 id 也能把 `tree_sample.exe`
  /// 盖掉）；`_installPluginRelease` 里的“撞内置 id”是另一条，两者现在共用这一份事实。
  Set<String> protectedFileNames() {
    final Set<String> Function()? injected = protectedOverride;
    if (injected != null) return injected();
    final Set<String> names = <String>{};
    final bool windows = isWindows ?? Platform.isWindows;
    for (final BuiltinPluginSpec spec in BuiltinPluginCatalog.specs) {
      if (spec.kind != BuiltinPluginSpec.kindBinary) continue;
      final String fileName = BuiltinPluginCatalog.binaryFileName(
        spec,
        isWindows: windows,
      );
      if (!File(p.join(installDir, fileName)).existsSync()) continue;
      // 上一次从 release 装的那一份 ⇒ 不算随包，允许再装（否则它自己锁死自己）。
      final Object? source = installedReader(spec.id)?[kRepoSourceKey];
      if (source == kRepoSourceValue) continue;
      names.add(fileName);
    }
    return names;
  }

  final void Function(String message)? log;

  /// 这条内置 id 在本机是否已有“核心自带的那一份成品”（`POST /release/{id}/install` 的判据）。
  ///
  /// 为什么住在这里而不是路由层：它要用的平台口径与受保护名是**同一件事**（见
  /// [protectedFileNames]）。路由层自己再拼一次 `binaryFileName(…, isWindows: Platform.isWindows)`
  /// 就是第二套判断 —— 不注入 isWindows 的用例在别的平台上会**假绿**（保护面算 `.exe`、
  /// 查的名字不带 `.exe`，两边对不上谁也不报错）。
  bool shipsOwnArtifact(String id) {
    final BuiltinPluginSpec? spec = BuiltinPluginCatalog.specOf(id.trim());
    if (spec == null || spec.kind != BuiltinPluginSpec.kindBinary) return false;
    // 受保护名本身已尊重注入（[protectedFileNames] 开头那行），这里不再分叉；
    // 只把名字按**同一个平台口径**拼出来去查它。
    return protectedFileNames().contains(
      BuiltinPluginCatalog.binaryFileName(
        spec,
        isWindows: isWindows ?? Platform.isWindows,
      ),
    );
  }

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_.-]+$');
  static final RegExp _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');

  static String _defaultNonce() =>
      '$pid-${DateTime.now().microsecondsSinceEpoch}'.replaceAll('-', '');

  String get indexPath => p.join(cacheDir, kPluginIndexAsset);

  /// 每次都要**新的**随机串（同一进程内连续两次安装不能撞临时名，否则第二次的
  /// 复制会把第一次还没改完的临时文件覆盖掉）。
  String _nonce() => nonceFactory();

  /// 收掉本类自己建的 HTTP 客户端（注入的那一份归注入方所有，不动它）。
  void close() => _ownedClient?.close(force: true);

  // ── ① 取索引（联网那一段）─────────────────────────────────────────────

  /// 拉最新 release 的 `plugin-index.json` 并缓存，然后回清单。
  ///
  /// 失败都回可读原因（网络、404「这个仓库还没发布任何 release」、403/429 限流、
  /// 以及"有 release 但没有索引资产"），**不静默回退到本地旧缓存** —— 面板要能说出
  /// "这次没刷成功，你现在看到的是上一次的那份"，所以调用方失败后自己再读 [cachedListing]。
  Future<PluginReleaseListing> refresh() async {
    final Uri releaseUri = Uri.parse('$apiBase/repos/$repo/releases/latest');
    final PluginFetchResult meta = await _get(releaseUri);
    if (!meta.ok) {
      return PluginReleaseListing.failed(
        _httpFailure('取最新 release 失败', meta, releaseUri),
        indexPath: indexPath,
      );
    }
    final String metaText;
    try {
      metaText = utf8.decode(meta.bytes);
    } catch (error) {
      return PluginReleaseListing.failed(
        'release 响应不是 UTF-8（$error）',
        indexPath: indexPath,
      );
    }
    final Object? release;
    try {
      release = jsonDecode(metaText);
    } catch (error) {
      return PluginReleaseListing.failed(
        'release 响应不是合法 JSON（$error）',
        indexPath: indexPath,
      );
    }
    if (release is! Map) {
      return PluginReleaseListing.failed(
        'release 响应不是 JSON 对象（形状与 GitHub API 不符）',
        indexPath: indexPath,
      );
    }
    final String tag = (release['tag_name'] ?? '').toString();
    final Object? rawAssets = release['assets'];
    if (rawAssets is! List || rawAssets.isEmpty) {
      return PluginReleaseListing.failed(
        '最新 release（$tag）没有任何资产 ⇒ 没有可安装的插件；'
        '发布时必须附带 $kPluginIndexAsset 与各插件文件',
        indexPath: indexPath,
      );
    }
    final ({String url, int size})? indexAsset = _findIndexAsset(rawAssets);
    if (indexAsset == null) {
      return PluginReleaseListing.failed(
        '最新 release（$tag）里没有 $kPluginIndexAsset 资产：'
        '装机端只认这份索引，缺它就等于"这一版没得上"',
        indexPath: indexPath,
      );
    }
    final PluginFetchResult index = await _get(Uri.parse(indexAsset.url));
    if (!index.ok) {
      return PluginReleaseListing.failed(
        _httpFailure(
          '下载 $kPluginIndexAsset 失败',
          index,
          Uri.parse(indexAsset.url),
        ),
        indexPath: indexPath,
      );
    }
    if (indexAsset.size > 0 && index.bytes.length != indexAsset.size) {
      return PluginReleaseListing.failed(
        '$kPluginIndexAsset 字节数不符（下载 ${index.bytes.length}，声明 ${indexAsset.size}）'
        '⇒ 按"没拿到"处理，不缓存半截索引',
        indexPath: indexPath,
      );
    }
    try {
      await Directory(cacheDir).create(recursive: true);
      // 缓存也走"临时名 + 原子改名"：半截索引被下一次离线读到，比没有索引更难查。
      await _atomicWriteBytes(indexPath, index.bytes);
    } catch (error) {
      return PluginReleaseListing.failed(
        '索引落缓存失败（$indexPath）：$error',
        indexPath: indexPath,
      );
    }
    log?.call('插件发布仓库：索引已更新（release $tag，$kPluginIndexAsset）');
    final PluginReleaseListing parsed = _readIndex(tag: tag, online: true);
    return parsed;
  }

  /// 读本地缓存的索引（**不联网**）。没有缓存 ⇒ 可读的"先点刷新"。
  PluginReleaseListing cachedListing() {
    if (!File(indexPath).existsSync()) {
      return PluginReleaseListing.failed(
        '本机还没有发布索引的缓存：$indexPath（请先点「刷新」拉一次最新 release）',
        indexPath: indexPath,
      );
    }
    return _readIndex(tag: _cachedTag(), online: false);
  }

  ({String url, int size})? _findIndexAsset(List<dynamic> assets) {
    for (final Object? item in assets) {
      if (item is! Map) continue;
      final String name = (item['name'] ?? '').toString();
      if (name != kPluginIndexAsset) continue;
      final String url = (item['browser_download_url'] ?? '').toString();
      if (url.isEmpty) continue;
      return (url: url, size: (item['size'] as num?)?.toInt() ?? 0);
    }
    return null;
  }

  String _cachedTag() {
    final File marker = File(p.join(cacheDir, 'release-tag.txt'));
    return marker.existsSync() ? marker.readAsStringSync().trim() : '';
  }

  /// 解析索引（[refresh] 与 [cachedListing] 共用同一段校验 —— 两条路必须同口径）。
  PluginReleaseListing _readIndex({required String tag, required bool online}) {
    final Map<String, dynamic> json;
    try {
      final Object? decoded = jsonDecode(
        utf8.decode(File(indexPath).readAsBytesSync()),
      );
      if (decoded is! Map) {
        return PluginReleaseListing.failed(
          '$kPluginIndexAsset 必须是 JSON 对象',
          indexPath: indexPath,
        );
      }
      json = decoded.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    } catch (error) {
      return PluginReleaseListing.failed(
        '$kPluginIndexAsset 不是合法 JSON（$error）：$indexPath',
        indexPath: indexPath,
      );
    }
    final int schema = (json['schema'] as num?)?.toInt() ?? 0;
    if (schema != kPluginIndexSchema) {
      return PluginReleaseListing.failed(
        '索引 schema=$schema，本核心只认 schema=$kPluginIndexSchema：'
        '不猜新字段的含义（猜错的表现是"装上去起不来"），请更新核心',
        indexPath: indexPath,
      );
    }
    // tag 记一份，离线时面板能说"这是 v0.1.0 那次发布的东西"。
    if (tag.isNotEmpty) {
      try {
        File(p.join(cacheDir, 'release-tag.txt')).writeAsStringSync(tag);
      } catch (_) {
        // 只是诊断信息，写不进不影响正确性（不因此报失败：清单已经拿到了）。
      }
    }
    final Object? rawPlugins = json['plugins'];
    if (rawPlugins is! List) {
      return PluginReleaseListing.failed(
        '索引缺 plugins 数组（形状见 plugins/README.md）',
        indexPath: indexPath,
      );
    }
    final List<PluginRepoEntry> entries = <PluginRepoEntry>[];
    final List<String> skipped = <String>[];
    for (final Object? item in rawPlugins) {
      if (item is! Map) {
        skipped.add('（某项）不是 JSON 对象，已跳过');
        continue;
      }
      final Map<String, dynamic> raw = item.map(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v),
      );
      final String id = (raw['id'] ?? '').toString().trim();
      final ({PluginRepoEntry? entry, String? error}) parsed = _readEntry(raw);
      if (parsed.error != null) {
        skipped.add('${id.isEmpty ? '（缺 id）' : id}：${parsed.error}');
        continue;
      }
      entries.add(parsed.entry!);
    }
    return PluginReleaseListing(
      ok: true,
      entries: entries,
      skipped: skipped,
      tag: tag,
      indexPath: indexPath,
      online: online,
    );
  }

  ({PluginRepoEntry? entry, String? error}) _readEntry(
    Map<String, dynamic> raw,
  ) {
    final String id = (raw['id'] ?? '').toString().trim();
    if (id.isEmpty) return (entry: null, error: '索引项缺 id');
    if (id == '.' || id == '..' || !_idPattern.hasMatch(id)) {
      return (entry: null, error: '插件 id 只允许字母、数字、下划线、点和连字符：$id');
    }
    final String name = (raw['name'] ?? '').toString().trim();
    if (name.isEmpty) return (entry: null, error: '索引项 $id 缺 name（面板要显示它）');
    final String version = (raw['version'] ?? '').toString().trim();
    if (!_versionPattern.hasMatch(version)) {
      return (entry: null, error: '$id 的 version 必须是三段数字 x.y.z（当前：$version）');
    }
    final Object? rawFiles = raw['files'];
    if (rawFiles is! List || rawFiles.isEmpty) {
      return (entry: null, error: '$id 的 files 必须是非空数组（要放进 plugins/ 的文件）');
    }
    final List<PluginRepoFile> files = <PluginRepoFile>[];
    final Set<String> reserved = protectedFileNames();
    for (final Object? item in rawFiles) {
      if (item is! Map) {
        return (entry: null, error: '$id 的 files 里有一项不是对象（要 {asset, target}）');
      }
      final String asset = (item['asset'] ?? '').toString().trim();
      final String target = (item['target'] ?? '').toString().trim();
      if (asset.isEmpty || target.isEmpty) {
        return (entry: null, error: '$id 的 files 项必须同时有 asset 与 target');
      }
      if (asset != p.basename(asset)) {
        return (entry: null, error: '$id 的资产名「$asset」不是纯文件名（不许含路径）');
      }
      // 发布方给的文件名不能把 plugins/ 写到别处去 —— 与 TreePaths.safeSegment 同一条防线。
      if (target != p.basename(target) || p.isAbsolute(target)) {
        return (entry: null, error: '$id 的目标名「$target」不是纯文件名（不许含路径或绝对路径）');
      }
      // 也不能拿它盖住随包的插件源码与成品（它们同在一个 plugins/ 里，靠文件名区分）。
      if (reserved.contains(target)) {
        return (
          entry: null,
          error:
              '$id 的目标名「$target」是核心内置插件随包的文件：'
              '发布仓库只装自己的成品，不盖 plugins/ 里的插件源码',
        );
      }
      files.add(
        PluginRepoFile(
          asset: asset,
          target: target,
          bytes: (item['bytes'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    final String command = (raw['command'] ?? '').toString().trim();
    if (command.isEmpty) {
      return (entry: null, error: '$id 缺 command（装完后拿什么拉起它）');
    }
    if (!files.any((PluginRepoFile f) => f.target == command)) {
      return (entry: null, error: '$id 的 command「$command」不在 files 的目标名里');
    }
    final String runtime = (raw['runtime'] ?? 'binary').toString().trim();
    if (runtime != 'binary' && runtime != 'python') {
      return (
        entry: null,
        error: '$id 的 runtime 只能是 binary | python（当前：$runtime）',
      );
    }
    final String suspension = (raw['suspension'] ?? '').toString().trim();
    if (suspension.isNotEmpty && suspension != PluginSuspension.keep) {
      // 值域与 plugins.yaml 完全一致：写错就当场说，不能"用户写了 keep、核心当没看见"。
      return (
        entry: null,
        error: '$id 的 suspension 只能留空或 keep（当前：$suspension）',
      );
    }
    final String granularity = (raw['granularity'] ?? 'team').toString().trim();
    if (!const <String>['team', 'agent', 'session'].contains(granularity)) {
      return (
        entry: null,
        error: '$id 的 granularity 只能是 team | agent | session（当前：$granularity）',
      );
    }
    final Object? rawScope = raw['scope'];
    if (rawScope != null && rawScope is! Map) {
      return (entry: null, error: '$id 的 scope 必须是 JSON 对象');
    }
    final Map<String, dynamic>? installed = installedReader(id);
    return (
      entry: PluginRepoEntry(
        id: id,
        name: name,
        version: version,
        files: files,
        command: command,
        runtime: runtime,
        description: (raw['description'] ?? '').toString(),
        args: <String>[
          if (raw['args'] is List)
            for (final Object? a in (raw['args'] as List<dynamic>)) '$a',
        ],
        suspension: suspension,
        granularity: granularity,
        scope: rawScope is Map
            ? rawScope.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
            : <String, dynamic>{},
        installedVersion: (installed == null
            ? ''
            : (installed[kRepoVersionKey] ?? '').toString()),
      ),
      error: null,
    );
  }

  // ── ② 下载 + 放置 ─────────────────────────────────────────────────────

  /// 装一条插件：资产进缓存 → 闸门 → 复制到临时名 → 原子改名覆盖 `plugins/`。
  ///
  /// 顺序就是 Windows 的现实（详见 plugins/README.md「安装会发生什么」）：
  /// 下载只写缓存（碰不到正在跑的文件）；**碰 targets 之前**必须先过 [swapGate]；
  /// 然后所有文件复制成 `.part-<nonce>`（一个都还没碰旧文件）→ 逐个原子改名。
  /// 任一步失败就删临时名、旧文件保持原样、回一句人话；**绝不为了换文件而杀进程**。
  Future<PluginInstallResult> install(
    String pluginId, {
    required PluginSwapGate swapGate,
  }) async {
    final String id = pluginId.trim();
    final PluginReleaseListing listing = File(indexPath).existsSync()
        ? cachedListing()
        : await refresh();
    if (!listing.ok) {
      return PluginInstallResult.failed(listing.error, pluginId: id);
    }
    final PluginRepoEntry? entry = listing.entries
        .where((PluginRepoEntry e) => e.id == id)
        .firstOrNull;
    if (entry == null) {
      final String known = listing.entries
          .map((PluginRepoEntry e) => e.id)
          .join(' | ');
      return PluginInstallResult.failed(
        '发布索引里没有插件 $id（现在能装的：${known.isEmpty ? '（空）' : known}）'
        '——被跳过的条目与原因见列表的 skipped',
        pluginId: id,
      );
    }
    // 脚本型要先有解释器，否则装上去就是一条永远起不来的条目（那比不装更糟）。
    BuiltinRuntime? interpreter;
    if (entry.runtime == 'python') {
      final PluginRuntimeResolver? resolver = runtimeResolver;
      if (resolver == null) {
        return PluginInstallResult.failed(
          '插件 $id 是脚本型（runtime=python），但这台核心没有接解释器解析：'
          '不写一条注定起不来的配置',
          pluginId: id,
        );
      }
      interpreter = await resolver();
      if (interpreter == null) {
        return PluginInstallResult.failed(
          '插件 $id 需要 Python 解释器，本机没检测到（依次试过 python / py -3 / python3）：'
          '请先装 Python，或改用自定义命令写插件',
          pluginId: id,
        );
      }
    }

    // ① 资产进缓存（缺什么就下什么；字节数不符 = 失败且不落地）
    int downloadedBytes = 0;
    final Map<String, String> ready = <String, String>{}; // target → 缓存路径
    for (final PluginRepoFile file in entry.files) {
      final String cachedPath = p.join(
        cacheDir,
        entry.id,
        entry.version,
        file.target,
      );
      final File cached = File(cachedPath);
      if (cached.existsSync() &&
          (file.bytes == 0 || cached.lengthSync() == file.bytes)) {
        ready[file.target] = cachedPath;
        continue;
      }
      final ({String url, int size})? asset = await _lookupAsset(file.asset);
      if (asset == null) {
        return PluginInstallResult.failed(
          '最新 release 里找不到资产「${file.asset}」（插件 $id 需要它）：'
          '发布与索引不同版 ⇒ 请重新发布，或先刷新索引',
          pluginId: id,
        );
      }
      final PluginFetchResult data = await _get(Uri.parse(asset.url));
      if (!data.ok) {
        return PluginInstallResult.failed(
          _httpFailure('下载资产「${file.asset}」失败', data, Uri.parse(asset.url)),
          pluginId: id,
        );
      }
      // 期望字节数：索引显式声明优先，否则取 API 给的 asset.size
      final int expected = file.bytes > 0 ? file.bytes : asset.size;
      if (expected > 0 && data.bytes.length != expected) {
        return PluginInstallResult.failed(
          '资产「${file.asset}」字节数不符（下载 ${data.bytes.length}，声明 $expected）'
          '⇒ 不缓存半截文件，旧文件也没动',
          pluginId: id,
        );
      }
      try {
        await _atomicWriteBytes(cachedPath, data.bytes);
      } catch (error) {
        return PluginInstallResult.failed(
          '资产「${file.asset}」写缓存失败（$cachedPath）：$error',
          pluginId: id,
        );
      }
      downloadedBytes += data.bytes.length;
      ready[file.target] = cachedPath;
    }

    // ② 闸门：旧进程没确认退出就不换（核心不为了换文件而杀进程，也不无限等）
    final String blocked = await swapGate(id);
    if (blocked.isNotEmpty) {
      return PluginInstallResult.failed(blocked, pluginId: id);
    }

    final Directory target = Directory(installDir);
    try {
      await target.create(recursive: true);
    } catch (error) {
      return PluginInstallResult.failed(
        '建不出放置目录 $installDir：$error',
        pluginId: id,
      );
    }

    // ③ 复制到同目录临时名
    final String nonce = _nonce();
    final Map<String, String> staged = <String, String>{};
    try {
      ready.forEach((String targetName, String cachedPath) {
        final String tempPath = p.join(installDir, '$targetName.part-$nonce');
        File(cachedPath).copySync(tempPath);
        staged[targetName] = tempPath;
      });
    } catch (error) {
      _dropStaged(staged);
      return PluginInstallResult.failed(
        '复制插件文件失败（旧文件一个都没动）：$error',
        pluginId: id,
      );
    }

    // ④ 原子改名覆盖
    final List<String> placed = <String>[];
    for (final MapEntry<String, String> staging in staged.entries) {
      final String targetPath = p.join(installDir, staging.key);
      try {
        await _atomicRename(staging.value, targetPath);
        placed.add(staging.key);
      } catch (error) {
        final Map<String, String> rest = Map<String, String>.of(staged)
          ..remove(staging.key);
        _dropStaged(rest);
        return PluginInstallResult.failed(
          '原子改名覆盖 ${staging.key} 失败（已放置 ${placed.length} 个文件，'
          '插件条目未写入，其余旧文件保持原样）：$error',
          pluginId: id,
        );
      }
    }

    final String installedCommand = p.join(installDir, entry.command);
    final Map<String, dynamic> configEntry = <String, dynamic>{
      'id': entry.id,
      'name': entry.name,
      'description': entry.description,
      // 脚本型：command = 解释器，脚本路径进 args 首项（与内置插件解析同形状）。
      'command': interpreter == null ? installedCommand : interpreter.command,
      'args': <String>[
        if (interpreter != null) ...interpreter.prefixArgs,
        if (interpreter != null) installedCommand,
        ...entry.args,
      ],
      'env': <String, String>{},
      'enabled': true,
      'granularity': entry.granularity,
      'scope': entry.scope,
      if (entry.suspension.isNotEmpty) 'suspension': entry.suspension,
      // 来源标记（展示用；行为一律不读它 —— 见 kRepoSourceKey 的注释）
      kRepoSourceKey: kRepoSourceValue,
      kRepoVersionKey: entry.version,
    };
    log?.call(
      '插件发布仓库：已放置 $id（${entry.version}，${placed.length} 个文件，'
      '本次下载 $downloadedBytes 字节）到 $installDir',
    );
    return PluginInstallResult(
      ok: true,
      pluginId: id,
      version: entry.version,
      files: placed,
      entry: configEntry,
      swapped: true,
      downloaded: downloadedBytes,
      note:
          '文件已就位；插件条目由调用方写入 plugins.yaml 并热应用'
          '（起不来的原因会由面板与日志如实给出）',
    );
  }

  /// 按资产名去最新 release 里查下载地址（install 时再查一次，而不是把 URL 缓存进索引：
  /// release 资产的 URL 带 id，重新发布就会变；缓存下来的旧 URL 会把人带到 404）。
  Future<({String url, int size})?> _lookupAsset(String assetName) async {
    final PluginFetchResult meta = await _get(
      Uri.parse('$apiBase/repos/$repo/releases/latest'),
    );
    if (!meta.ok) return null;
    final Object? release;
    try {
      release = jsonDecode(utf8.decode(meta.bytes));
    } catch (_) {
      return null;
    }
    final Object? assets = release is Map ? release['assets'] : null;
    if (assets is! List) return null;
    return _findAsset(assets, assetName);
  }

  ({String url, int size})? _findAsset(List<dynamic> assets, String name) {
    for (final Object? item in assets) {
      if (item is! Map) continue;
      if ((item['name'] ?? '').toString() != name) continue;
      final String url = (item['browser_download_url'] ?? '').toString();
      if (url.isEmpty) continue;
      return (url: url, size: (item['size'] as num?)?.toInt() ?? 0);
    }
    return null;
  }

  // ── 内部：HTTP 与原子写 ────────────────────────────────────────────────

  Future<PluginFetchResult> _get(Uri url) async {
    final PluginFetcher? injected = fetcherOverride;
    if (injected != null) {
      return injected(url, headers: _headers);
    }
    // 注入的客户端归注入方；自己建的那一份留到 [close] 里收。
    final HttpClient client = injectedClient ?? (_ownedClient ??= HttpClient());
    try {
      final HttpClientRequest request = await client.getUrl(url);
      _headers.forEach(
        (String key, String value) => request.headers.set(key, value),
      );
      // GitHub API 要求 User-Agent；缺了会被拒成 403，而那条错误看上去像"没权限"。
      request.headers.set(HttpHeaders.userAgentHeader, 'tree-desktop-core');
      request.followRedirects = true;
      request.maxRedirects = 5;
      final HttpClientResponse response = await request.close();
      // 响应体是 Stream<List<int>>：逐块收进一个列表，收完才交给上层校验字节数。
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in response) {
        bytes.addAll(chunk);
      }
      return PluginFetchResult(statusCode: response.statusCode, bytes: bytes);
    } catch (error) {
      // 网络失败**不静默重试**（那是"看起来在转圈"的根源），一次就把原因说清。
      return PluginFetchResult.failure('$error');
    }
  }

  Map<String, String> get _headers => <String, String>{
    'Accept': 'application/vnd.github+json',
    if (accessToken.trim().isNotEmpty)
      'Authorization': 'Bearer ${accessToken.trim()}',
  };

  String _httpFailure(String what, PluginFetchResult result, Uri url) {
    final String reason = result.error.isNotEmpty
        ? result.error
        : 'HTTP ${result.statusCode}';
    final String hint = result.statusCode == 403 || result.statusCode == 429
        ? '（GitHub API 限流：公开仓库匿名每小时 60 次；需要更多请给核心设 GITHUB_TOKEN）'
        : result.statusCode == 404
        ? '（404：这个仓库还没有 release，或坐标写错了：$repo）'
        : '';
    return '$what：$reason $url$hint';
  }

  Future<void> _atomicWriteBytes(String path, List<int> bytes) async {
    final File target = File(path);
    await target.parent.create(recursive: true);
    final String tempPath = '$path.part-${_nonce()}';
    final File temp = File(tempPath);
    final RandomAccessFile handle = await temp.open(mode: FileMode.write);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await _atomicRename(tempPath, path);
  }

  /// 改名覆盖，带 Windows 兜底（与 `AtomicFile` 同一套理由：`File.rename` 对已存在的
  /// 目标在某些平台会失败，那就先删目标再改名 —— 而**能走到这里说明旧进程已退出**）。
  Future<void> _atomicRename(String from, String to) async {
    final File temp = File(from);
    try {
      await temp.rename(to);
    } on FileSystemException {
      final File target = File(to);
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(to);
    }
  }

  void _dropStaged(Map<String, String> staged) {
    staged.forEach((String targetName, String tempPath) {
      try {
        final File temp = File(tempPath);
        if (temp.existsSync()) temp.deleteSync();
      } catch (error) {
        log?.call('清临时文件 $tempPath 失败（不影响结果，占位无害）：$error');
      }
    });
  }
}

/// 三段数字版本比较：[a] > [b] 返回 true。读不出来的版本一律当"更小"（保守：
/// 宁可提示有更新，也不把一个装不上的东西说成"已是最新"）。
bool _versionGreater(String a, String b) {
  final List<int>? left = _parseVersion(a);
  final List<int>? right = _parseVersion(b);
  if (left == null) return false;
  if (right == null) return true;
  for (int i = 0; i < 3; i++) {
    if (left[i] != right[i]) return left[i] > right[i];
  }
  return false;
}

List<int>? _parseVersion(String raw) {
  final List<String> parts = raw.trim().split('.');
  if (parts.length != 3) return null;
  return <int>[
    for (final String part in parts)
      if (int.tryParse(part) == null) -1 else int.parse(part),
  ];
}
