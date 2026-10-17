// 插件发布仓库下载器（阶段 5）的用例：**整条链离线跑**（HTTP 由假取回器给）。
//
// 钉住的口径（用户 2026-10-16 定稿：「plugins 里是插件代码，插件管理只拉 release」）：
// 1. 只读 GitHub **Releases 资产**，索引就是那张合同（`plugin-index.json`，schema=1）；
// 2. 索引校验：坏条目**只跳过并写下原因**，一个手错的 JSON 不许带走整份清单；
// 3. 字节数不符 ⇒ 按"没拿到"处理，**不缓存半截**（半截索引/半截 exe 被下一次离线读到
//    比没有更难查）；
// 4. 放置顺序是 Windows 的现实：先过**换文件闸门**（旧进程没确认退出就不换，核心不
//    为了换文件而强杀），再复制成临时名，最后原子改名覆盖；任一步失败旧文件一字未动；
// 5. 产出的条目带 `source: release` / `repo_version`（只给面板显示，行为一律不读）。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 假的发布仓库：URL → 字节（不发网络，所以"资产缺一半"这种形状也能钉死）。
class _FakeRepo {
  /// 资产名 → 字节（索引与各插件文件都放在这里面）。
  final Map<String, List<int>> assets = <String, List<int>>{};

  /// 最新 release 的元信息（null = 这个仓库还没发布任何 release）。
  Map<String, dynamic>? release;

  /// 被请求过的 URL（用例用它证明"读列表不联网"）。
  final List<String> urls = <String>[];

  /// 强制某次资产下载返回错误字节数（模拟截断）。
  int? truncateBytes;

  /// 强制 releases/latest 返回这个状态码（模拟限流 403 / 429）。
  int? releaseStatusOverride;

  Future<PluginFetchResult> fetch(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    urls.add(url.toString());
    if (url.path.endsWith('/releases/latest')) {
      final int? forced = releaseStatusOverride;
      if (forced != null) {
        return PluginFetchResult(statusCode: forced, error: 'HTTP $forced');
      }
      final Map<String, dynamic>? meta = release;
      if (meta == null) {
        return PluginFetchResult(statusCode: 404, error: 'HTTP 404');
      }
      return PluginFetchResult(
        statusCode: 200,
        bytes: utf8.encode(jsonEncode(meta)),
      );
    }
    final String name = Uri.decodeComponent(url.pathSegments.last);
    final List<int>? bytes = assets[name];
    if (bytes == null) {
      return PluginFetchResult(statusCode: 404, error: 'HTTP 404');
    }
    final int? cut = truncateBytes;
    return PluginFetchResult(
      statusCode: 200,
      bytes: cut == null
          ? bytes
          : bytes.sublist(0, cut < bytes.length ? cut : bytes.length),
    );
  }

  /// 把 [tag] 这一版发布出去：索引 + 已在 [assets] 里的每个文件都挂成资产。
  void publish({
    String tag = 'v0.1.0',
    int schema = kPluginIndexSchema,
    required List<Map<String, dynamic>> plugins,
    int? indexDeclaredSize,
  }) {
    final List<int> indexBytes = utf8.encode(
      jsonEncode(<String, dynamic>{'schema': schema, 'plugins': plugins}),
    );
    assets[kPluginIndexAsset] = indexBytes;
    release = <String, dynamic>{
      'tag_name': tag,
      'assets': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': kPluginIndexAsset,
          'size': indexDeclaredSize ?? indexBytes.length,
          'browser_download_url':
              'https://downloads.example/$kPluginIndexAsset',
        },
        for (final MapEntry<String, List<int>> e in assets.entries)
          if (e.key != kPluginIndexAsset)
            <String, dynamic>{
              'name': e.key,
              'size': e.value.length,
              'browser_download_url': 'https://downloads.example/${e.key}',
            },
      ],
    };
  }
}

/// 一条索引条目（默认是**合法**的 binary 型）。
Map<String, dynamic> _entry({
  String id = 'released',
  String name = '发布版插件',
  String version = '1.2.0',
  String runtime = 'binary',
  String command = 'tree_released.exe',
  String suspension = '',
  List<Map<String, dynamic>>? files,
  List<String> args = const <String>[],
  Map<String, dynamic> scope = const <String, dynamic>{},
  String granularity = 'team',
}) => <String, dynamic>{
  'id': id,
  'name': name,
  'version': version,
  'runtime': runtime,
  'command': command,
  'files':
      files ??
      <Map<String, dynamic>>[
        <String, dynamic>{'asset': command, 'target': command, 'bytes': 8},
      ],
  'args': args,
  'suspension': suspension,
  'granularity': granularity,
  'scope': scope,
  'description': '从 release 装的插件',
};

void main() {
  late Directory temp;
  late String cacheDir;
  late String installDir;
  late _FakeRepo repo;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_release_');
    cacheDir = p.join(temp.path, 'plugins_release');
    installDir = p.join(temp.path, 'plugins');
    Directory(installDir).createSync(recursive: true);
    repo = _FakeRepo();
  });

  tearDown(() {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        sleep(const Duration(milliseconds: 50));
      }
    }
  });

  PluginDownloader downloader({
    Map<String, dynamic>? Function(String id)? installedEntryOf,
    PluginRuntimeResolver? runtimeResolver,
  }) => PluginDownloader(
    cacheDir: cacheDir,
    installDir: installDir,
    fetcher: repo.fetch,
    nonce: () => 'nonce',
    installedEntryOf: installedEntryOf,
    runtimeResolver: runtimeResolver,
  );

  /// 往仓库里放一个插件文件（默认 8 字节，与 [_entry] 里声明的 bytes 对齐）。
  void putAsset(String name, {int bytes = 8}) {
    repo.assets[name] = List<int>.generate(bytes, (int i) => 65 + (i % 26));
  }

  Future<String> allowSwap(String id) async => '';

  group('取索引（releases/latest → plugin-index.json）', () {
    test('成功：缓存落盘 + tag 记一份 + 条目解析成 online', () async {
      putAsset('tree_released.exe');
      repo.publish(plugins: <Map<String, dynamic>>[_entry()]);
      final PluginReleaseListing listing = await downloader().refresh();
      expect(listing.ok, isTrue, reason: listing.error);
      expect(listing.online, isTrue, reason: '这次是联网取的');
      expect(listing.tag, 'v0.1.0');
      expect(listing.entries, hasLength(1));
      expect(listing.entries.single.id, 'released');
      expect(listing.entries.single.targets, <String>['tree_released.exe']);
      expect(File(p.join(cacheDir, kPluginIndexAsset)).existsSync(), isTrue);
      expect(
        File(p.join(cacheDir, 'release-tag.txt')).readAsStringSync().trim(),
        'v0.1.0',
        reason: '离线时面板要能说"这是 v0.1.0 那次发布的东西"',
      );
    });

    test('404（仓库还没有 release）⇒ 可读原因，不静默回退', () async {
      repo.release = null;
      final PluginReleaseListing listing = await downloader().refresh();
      expect(listing.ok, isFalse);
      expect(listing.error, contains('还没有 release'));
    });

    test('有 release 但没有索引资产 ⇒ 说"缺它就等于这一版没得上"', () async {
      putAsset('tree_released.exe');
      repo.release = <String, dynamic>{
        'tag_name': 'v0.1.0',
        'assets': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'tree_released.exe',
            'size': 8,
            'browser_download_url':
                'https://downloads.example/tree_released.exe',
          },
        ],
      };
      final PluginReleaseListing listing = await downloader().refresh();
      expect(listing.ok, isFalse);
      expect(listing.error, contains(kPluginIndexAsset));
      expect(listing.error, contains('没得上'));
    });

    test('索引字节数不符 ⇒ 失败且**不缓存半截索引**', () async {
      putAsset('tree_released.exe');
      repo.publish(
        plugins: <Map<String, dynamic>>[_entry()],
        indexDeclaredSize: 999999,
      );
      final PluginReleaseListing listing = await downloader().refresh();
      expect(listing.ok, isFalse);
      expect(listing.error, contains('不缓存半截索引'));
      expect(
        File(p.join(cacheDir, kPluginIndexAsset)).existsSync(),
        isFalse,
        reason: '半截索引被下一次离线读到，比没有索引更难查',
      );
    });

    test('schema 不是本核心认的那一版 ⇒ 拒并说"不猜新字段"', () async {
      putAsset('tree_released.exe');
      repo.publish(
        schema: kPluginIndexSchema + 1,
        plugins: <Map<String, dynamic>>[_entry()],
      );
      final PluginReleaseListing listing = await downloader().refresh();
      expect(listing.ok, isFalse);
      expect(listing.error, contains('不猜新字段'));
    });

    test('限流（403）⇒ 原因里给出 GITHUB_TOKEN 这条路', () async {
      putAsset('tree_released.exe');
      repo.publish(plugins: <Map<String, dynamic>>[_entry()]);
      repo.releaseStatusOverride = 403;
      final PluginReleaseListing listing = await downloader().refresh();
      expect(listing.ok, isFalse);
      expect(listing.error, contains('限流'));
      expect(listing.error, contains('GITHUB_TOKEN'));
    });
  });

  group('读缓存（不联网）', () {
    test('没缓存 ⇒ 说"请先点刷新"，并且一个 URL 都不碰', () async {
      final PluginReleaseListing listing = downloader().cachedListing();
      expect(listing.ok, isFalse);
      expect(listing.error, contains('请先点「刷新」'));
      expect(repo.urls, isEmpty, reason: '读列表不是网络动作');
    });

    test('有缓存 ⇒ online=false（离线不许看起来像最新）', () async {
      putAsset('tree_released.exe');
      repo.publish(plugins: <Map<String, dynamic>>[_entry()]);
      await downloader().refresh();
      repo.urls.clear();
      final PluginReleaseListing listing = downloader().cachedListing();
      expect(listing.ok, isTrue);
      expect(listing.online, isFalse);
      expect(listing.entries.single.installedVersion, '', reason: '本机没装过');
      expect(listing.entries.single.hasUpdate, isTrue);
      expect(repo.urls, isEmpty);
    });

    test('已装条目的 repo_version 决定"有没有更新"', () async {
      putAsset('tree_released.exe');
      repo.publish(plugins: <Map<String, dynamic>>[_entry(version: '1.2.0')]);
      await downloader().refresh();
      PluginDownloader d({String? installed}) => downloader(
        installedEntryOf: (String id) => installed == null
            ? null
            : <String, dynamic>{'repo_version': installed},
      );
      expect(
        d(installed: '1.2.0').cachedListing().entries.single.hasUpdate,
        isFalse,
      );
      expect(
        d(installed: '1.1.9').cachedListing().entries.single.hasUpdate,
        isTrue,
      );
      // 读不出的版本（用户手改过）⇒ 保守回答"有更新"，不许说"已是最新"
      expect(
        d(installed: '乱写').cachedListing().entries.single.hasUpdate,
        isTrue,
      );
    });
  });

  group('索引校验（坏条目只跳过，不带走整份清单）', () {
    test('五种坏法各自给原因，好条目照常进列表', () async {
      putAsset('tree_released.exe');
      repo.publish(
        plugins: <Map<String, dynamic>>[
          _entry(),
          _entry(id: 'bad_version', version: '1.2'),
          _entry(
            id: 'bad_target',
            files: <Map<String, dynamic>>[
              <String, dynamic>{'asset': 'x.exe', 'target': '../evil.exe'},
            ],
            command: '../evil.exe',
          ),
          _entry(
            id: 'bad_asset',
            files: <Map<String, dynamic>>[
              <String, dynamic>{'asset': 'a/b.exe', 'target': 'b.exe'},
            ],
            command: 'b.exe',
          ),
          _entry(
            id: 'bad_command',
            command: 'not_in_files.exe',
            // 文件表里没有 command 要拉的那个名字（装完根本不知道跑哪个）
            files: <Map<String, dynamic>>[
              <String, dynamic>{
                'asset': 'tree_released.exe',
                'target': 'tree_released.exe',
                'bytes': 8,
              },
            ],
          ),
          _entry(id: 'bad_runtime', runtime: 'node'),
          _entry(id: 'bad_suspension', suspension: 'Keep'),
          _entry(id: 'bad_granularity', granularity: 'global'),
          <String, dynamic>{
            'id': 'no_files',
            'name': '没有文件表',
            'version': '1.0.0',
          },
        ],
      );
      final PluginReleaseListing fresh = await downloader().refresh();
      expect(fresh.ok, isTrue);
      expect(fresh.entries.map((PluginRepoEntry e) => e.id).toList(), <String>[
        'released',
      ], reason: '只有第一条是合法的（其余每条都该被跳过）');
      expect(fresh.skipped, hasLength(8), reason: '坏条目逐个带原因进 skipped，不许静默');
      final String all = fresh.skipped.join('\n');
      expect(all, contains('三段数字'));
      expect(all, contains('目标名'));
      expect(all, contains('资产名'));
      expect(all, contains('不在 files 的目标名里'));
      expect(all, contains('binary | python'));
      expect(all, contains('suspension 只能留空或 keep'));
      expect(all, contains('team | agent | session'));
      expect(all, contains('files 必须是非空数组'));
    });

    test('scope 不是对象 ⇒ 跳过（不许把字符串当归属）', () async {
      putAsset('tree_released.exe');
      repo.publish(
        plugins: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'bad_scope',
            'name': 'x',
            'version': '1.0.0',
            'command': 'tree_released.exe',
            'files': <Map<String, dynamic>>[
              <String, dynamic>{
                'asset': 'tree_released.exe',
                'target': 'tree_released.exe',
              },
            ],
            'scope': 'team-1',
          },
        ],
      );
      final PluginReleaseListing listing = await downloader().refresh();
      expect(listing.entries, isEmpty);
      expect(listing.skipped.single, contains('scope 必须是 JSON 对象'));
    });

    test('目标名撞上随包的内置插件成品 ⇒ 跳过，install 也拿不到它', () async {
      // 「plugins/ 里是插件代码」的另一面：发布仓库只能装自己的成品。
      // 一条把 target 写成 `tree_sample[.exe]` 的索引，本来能把核心自带的成品盖掉，
      // 而现象是“示例插件突然起不来”——归因要翻到一份远端 JSON 里去了。
      // 名字按本机口径算（Windows 上补 .exe）：写死一个平台名就会在另一个平台上假绿。
      final String builtinName = BuiltinPluginCatalog.binaryFileName(
        BuiltinPluginCatalog.specOf(kSamplePluginId)!,
        isWindows: Platform.isWindows,
      );
      putAsset(builtinName);
      repo.publish(
        plugins: <Map<String, dynamic>>[
          _entry(
            id: 'overwrite_builtin',
            command: builtinName,
            files: <Map<String, dynamic>>[
              <String, dynamic>{
                'asset': builtinName,
                'target': builtinName,
                'bytes': 8,
              },
            ],
          ),
        ],
      );
      final PluginDownloader d = downloader();
      final PluginReleaseListing listing = await d.refresh();
      expect(listing.ok, isTrue, reason: listing.error);
      expect(listing.entries, isEmpty);
      expect(
        listing.skipped.single,
        contains('不盖 plugins/ 里的插件源码'),
        reason: '列清单时就要说出来，不能“列得出、点了才失败”',
      );
      final PluginInstallResult result = await d.install(
        'overwrite_builtin',
        swapGate: allowSwap,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('skipped'));
      expect(
        File(p.join(installDir, builtinName)).existsSync(),
        isFalse,
        reason: '被跳过的条目一个字节都不许落进 plugins/',
      );
    });
  });

  group('安装（缓存 → 闸门 → 临时名 → 原子改名）', () {
    test('binary 条目：文件就位、字节一致、条目形状可拉起', () async {
      putAsset('tree_released.exe');
      repo.publish(
        plugins: <Map<String, dynamic>>[
          _entry(suspension: PluginSuspension.keep),
        ],
      );
      final PluginInstallResult result = await downloader().install(
        'released',
        swapGate: allowSwap,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(result.swapped, isTrue);
      expect(result.downloaded, 8);
      final File placed = File(p.join(installDir, 'tree_released.exe'));
      expect(placed.existsSync(), isTrue);
      expect(placed.readAsBytesSync(), repo.assets['tree_released.exe']);
      final Map<String, dynamic> entry = result.entry!;
      expect(entry['id'], 'released');
      expect(entry['command'], p.join(installDir, 'tree_released.exe'));
      expect(entry['suspension'], PluginSuspension.keep);
      expect(entry[kRepoSourceKey], kRepoSourceValue);
      expect(entry[kRepoVersionKey], '1.2.0');
      expect(entry['enabled'], isTrue);
      // 落盘动作不在这里做（那是 core_server 的 plugins.yaml 唯一路径）
      expect(result.note, contains('调用方写入 plugins.yaml'));
    });

    test('第二次装同一版：全部命中缓存 ⇒ 一个字节都不再下载', () async {
      putAsset('tree_released.exe');
      repo.publish(plugins: <Map<String, dynamic>>[_entry()]);
      final PluginDownloader d = downloader();
      expect((await d.install('released', swapGate: allowSwap)).downloaded, 8);
      repo.urls.clear();
      final PluginInstallResult again = await d.install(
        'released',
        swapGate: allowSwap,
      );
      expect(again.ok, isTrue, reason: again.error);
      expect(again.downloaded, 0, reason: '缓存里已经有了就别再走网络');
    });

    test('闸门说"换不了" ⇒ 失败原因原样递出，旧文件一字未动', () async {
      putAsset('tree_released.exe');
      repo.publish(plugins: <Map<String, dynamic>>[_entry()]);
      final File old = File(p.join(installDir, 'tree_released.exe'))
        ..writeAsBytesSync(<int>[0, 1, 2, 3, 4, 5, 6, 7]);
      final PluginInstallResult result = await downloader().install(
        'released',
        swapGate: (String id) async => '插件 $id 的进程还没确认退出 ⇒ 不替换文件',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('还没确认退出'));
      expect(result.swapped, isFalse);
      expect(old.readAsBytesSync(), <int>[0, 1, 2, 3, 4, 5, 6, 7]);
      expect(
        Directory(installDir)
            .listSync()
            .whereType<File>()
            .map((File f) => p.basename(f.path)),
        containsAll(<String>['tree_released.exe']),
      );
      expect(
        Directory(installDir)
            .listSync()
            .whereType<File>()
            .where((File f) => p.basename(f.path).contains('.part-')),
        isEmpty,
        reason: '闸门之后一步都没走，不该留下临时文件',
      );
    });

    test('资产字节数不符 ⇒ 不缓存半截，旧文件也没动', () async {
      putAsset('tree_released.exe', bytes: 8);
      repo.publish(plugins: <Map<String, dynamic>>[_entry()]);
      // 先把索引拿到手（否则 install 会先自己刷一次，测不出资产那一段）
      expect((await downloader().refresh()).ok, isTrue);
      final File old = File(p.join(installDir, 'tree_released.exe'))
        ..writeAsStringSync('OLD');
      repo.truncateBytes = 3;
      final PluginInstallResult result = await downloader().install(
        'released',
        swapGate: allowSwap,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('不缓存半截文件'));
      expect(old.readAsStringSync(), 'OLD');
      expect(
        File(p.join(cacheDir, 'released', '1.2.0', 'tree_released.exe'))
            .existsSync(),
        isFalse,
      );
    });

    test('release 里找不到那个资产 ⇒ 说"发布与索引不同版"', () async {
      // 索引声明了 tree_released.exe，但这一版 release 只传了别的文件
      repo.assets['other.exe'] = <int>[1];
      repo.publish(plugins: <Map<String, dynamic>>[_entry()]);
      // publish 会把 tree_released.exe 漏掉（assets 里没有它）⇒ 查不到
      final PluginInstallResult result = await downloader().install(
        'released',
        swapGate: allowSwap,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('找不到资产'));
      expect(result.error, contains('不同版'));
    });

    test('索引里没有这个 id ⇒ 原因里列出"现在能装的"', () async {
      putAsset('tree_released.exe');
      repo.publish(
        plugins: <Map<String, dynamic>>[
          _entry(),
          _entry(id: 'second'),
        ],
      );
      final PluginInstallResult result = await downloader().install(
        'ghost',
        swapGate: allowSwap,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('没有插件 ghost'));
      expect(result.error, contains('released'));
      expect(result.error, contains('second'));
    });

    test('还没缓存就装 ⇒ 先自己刷一次（不要求用户必须先点刷新）', () async {
      putAsset('tree_released.exe');
      repo.publish(plugins: <Map<String, dynamic>>[_entry()]);
      final PluginInstallResult result = await downloader().install(
        'released',
        swapGate: allowSwap,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(File(p.join(cacheDir, kPluginIndexAsset)).existsSync(), isTrue);
    });

    test('脚本型：没有解释器就拒（不写一条注定起不来的配置）', () async {
      putAsset('released_plugin.py', bytes: 8);
      repo.publish(
        plugins: <Map<String, dynamic>>[
          _entry(
            runtime: 'python',
            command: 'released_plugin.py',
            files: <Map<String, dynamic>>[
              <String, dynamic>{
                'asset': 'released_plugin.py',
                'target': 'released_plugin.py',
                'bytes': 8,
              },
            ],
          ),
        ],
      );
      // 1) 这台核心没接解释器解析
      final PluginInstallResult none = await downloader().install(
        'released',
        swapGate: allowSwap,
      );
      expect(none.ok, isFalse);
      expect(none.error, contains('没有接解释器解析'));
      // 2) 接了但探测不到
      final PluginInstallResult missing = await downloader(
        runtimeResolver: () async => null,
      ).install('released', swapGate: allowSwap);
      expect(missing.ok, isFalse);
      expect(missing.error, contains('没检测到'));
      // 3) 探测到 py -3 ⇒ 命令是解释器，脚本进 args 首项（两件套不许塞进一个字符串）
      final PluginInstallResult ok = await downloader(
        runtimeResolver: () async => BuiltinRuntime('py', <String>['-3']),
      ).install('released', swapGate: allowSwap);
      expect(ok.ok, isTrue, reason: ok.error);
      final Map<String, dynamic> entry = ok.entry!;
      expect(entry['command'], 'py');
      expect(entry['args'], <String>[
        '-3',
        p.join(installDir, 'released_plugin.py'),
      ]);
      expect(
        File(p.join(installDir, 'released_plugin.py')).existsSync(),
        isTrue,
      );
    });

    test('放置中途失败不留临时文件（改名目标已存在时走删除兜底）', () async {
      putAsset('tree_released.exe');
      putAsset('extra.dll', bytes: 4);
      repo.publish(
        plugins: <Map<String, dynamic>>[
          _entry(
            files: <Map<String, dynamic>>[
              <String, dynamic>{
                'asset': 'tree_released.exe',
                'target': 'tree_released.exe',
                'bytes': 8,
              },
              <String, dynamic>{
                'asset': 'extra.dll',
                'target': 'extra.dll',
                'bytes': 4,
              },
            ],
          ),
        ],
      );
      final PluginInstallResult result = await downloader(
        installedEntryOf: (String id) => null,
      ).install('released', swapGate: allowSwap);
      expect(result.ok, isTrue, reason: result.error);
      expect(result.files, hasLength(2));
      expect(
        Directory(installDir)
            .listSync()
            .whereType<File>()
            .where((File f) => p.basename(f.path).contains('.part-')),
        isEmpty,
        reason: '成功路径上临时名都应被改名吃掉',
      );
    });
  });
}
