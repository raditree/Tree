import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/src/plugin/ui_branding.dart';

/// 片 E / 5.5：`system.collect.ui.branding` 的闸门与生效顺序。
void main() {
  late Directory root;
  late Directory outside;
  late UiBrandingRegistry registry;
  late List<String> logs;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tree_brand_root_');
    outside = await Directory.systemTemp.createTemp('tree_brand_outside_');
    logs = <String>[];
    registry = UiBrandingRegistry(
      allowedDirs: <String>[root.path],
      log: logs.add,
    );
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
    if (outside.existsSync()) await outside.delete(recursive: true);
  });

  File writeIco(String name, List<int> sizes) {
    final File file = File('${root.path}/$name');
    file.writeAsBytesSync(_ico(sizes));
    return file;
  }

  File writePng(String name, int width, int height) {
    final File file = File('${root.path}/$name');
    file.writeAsBytesSync(_png(width, height));
    return file;
  }

  Future<String?> declareIco(
    String pluginId, {
    String name = 'app.ico',
    List<int> sizes = const <int>[16, 32, 48, 256],
    String role = 'exe',
    List<int>? declaredSizes,
  }) {
    writeIco(name, sizes);
    return registry.declare(pluginId, <String, dynamic>{
      'icon': name,
      'role': role,
      'sizes': declaredSizes ?? sizes,
    });
  }

  group('生效顺序（最后到达者生效）', () {
    test('最后申报的插件生效；撤回回退上一条；全撤回回默认', () async {
      expect(await declareIco('ui.alpha'), isNull);
      expect(registry.active!.pluginId, 'ui.alpha');

      expect(await declareIco('ui.beta'), isNull);
      expect(registry.active!.pluginId, 'ui.beta', reason: '最后到达者生效');
      expect(registry.entries.length, 2);

      registry.retract('ui.beta');
      expect(registry.active!.pluginId, 'ui.alpha');

      registry.retract('ui.alpha');
      expect(registry.active, isNull);
      expect(registry.entries, isEmpty);
    });

    test('同一插件覆盖申报会移到最新（最后到达）', () async {
      expect(await declareIco('ui.alpha'), isNull);
      expect(await declareIco('ui.beta'), isNull);
      expect(registry.active!.pluginId, 'ui.beta');

      expect(await declareIco('ui.alpha', name: 'app2.ico'), isNull);
      expect(registry.active!.pluginId, 'ui.alpha');
      expect(registry.entries, hasLength(2), reason: '按 plugin_id 记账');
      expect(registry.entries.last.iconPath, endsWith('app2.ico'));
    });

    test('retainOnly 只保留在线插件', () async {
      expect(await declareIco('ui.alpha'), isNull);
      expect(await declareIco('ui.beta'), isNull);
      registry.retainOnly(<String>{'ui.alpha'});
      expect(registry.entries.single.pluginId, 'ui.alpha');
    });

    test('申报结构带 plugin_id / icon / role / sizes', () async {
      writeIco('app.ico', <int>[16, 32, 48, 256]);
      expect(await declareIco('ui.alpha'), isNull);
      final Map<String, dynamic> json = registry.active!.toJson();
      expect(json['plugin_id'], 'ui.alpha');
      expect(json['role'], 'exe');
      expect(json['sizes'], <int>[16, 32, 48, 256]);
      expect(json['icon'], endsWith('app.ico'));
    });
  });

  group('闸门（全部可读拒收）', () {
    test('禁止 URL / base64', () async {
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'https://example.com/a.ico',
          'role': 'exe',
        }),
        contains('禁止 URL / base64'),
      );
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'data:image/png;base64,AAAA',
          'role': 'exe',
        }),
        contains('禁止 URL / base64'),
      );
    });

    test('申报结构非法', () async {
      expect(await registry.declare(' ', <String, dynamic>{}), contains('plugin_id'));
      expect(await registry.declare('ui.alpha', 'x'), contains('必须是对象'));
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{'role': 'exe'}),
        contains('缺少 icon'),
      );
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'a.ico',
          'role': 'logo',
        }),
        contains('role 必须是'),
      );
    });

    test('扩展名白名单：exe/lnk 只认 .ico，window/tray 认 .png/.ico', () async {
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'readme.txt',
          'role': 'exe',
        }),
        contains('扩展名必须是'),
      );
      writePng('app.png', 64, 64);
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'app.png',
          'role': 'exe',
        }),
        contains('role=exe 的图标必须是 .ico'),
      );
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'app.png',
          'role': 'tray',
        }),
        isNull,
      );
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'app.png',
          'role': 'window',
        }),
        isNull,
      );
    });

    test('文件必须存在、非空、≤256KB 且可读', () async {
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'missing.ico',
          'role': 'exe',
        }),
        contains('不存在'),
      );
      File('${root.path}/empty.ico').writeAsBytesSync(<int>[]);
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'empty.ico',
          'role': 'exe',
        }),
        contains('为空'),
      );
      final File big = File('${root.path}/big.ico');
      big.writeAsBytesSync(<int>[
        0,
        0,
        1,
        0,
        ...List<int>.filled(UiBrandingRegistry.maxBytes, 0),
      ]);
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'big.ico',
          'role': 'exe',
        }),
        contains('256KB'),
      );
    });

    test('ICO 必须含 16/32/48/256', () async {
      writeIco('app.ico', <int>[16, 32, 48]);
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'app.ico',
          'role': 'exe',
        }),
        contains('ICO 必须包含 16/32/48/256'),
      );
      writeIco('bad.ico', <int>[]);
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'bad.ico',
          'role': 'exe',
        }),
        contains('图标文件损坏'),
      );
    });

    test('窗口图标 ≥32×32；托盘不限尺寸', () async {
      writePng('small.png', 16, 16);
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'small.png',
          'role': 'window',
        }),
        contains('窗口图标必须 ≥32×32'),
      );
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'small.png',
          'role': 'tray',
        }),
        isNull,
      );
    });

    test('sizes 申报必须与文件内容一致', () async {
      writeIco('app.ico', <int>[16, 32, 48, 256]);
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'app.ico',
          'role': 'exe',
          'sizes': <int>[16, 64],
        }),
        contains('不一致'),
      );
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'app.ico',
          'role': 'exe',
          'sizes': <String>['16'],
        }),
        contains('sizes 必须是'),
      );
    });

    test('路径必须落在插件目录内（相对路径逃逸也被拒）', () async {
      final File escaped = File('${outside.path}/evil.ico');
      escaped.writeAsBytesSync(_ico(<int>[16, 32, 48, 256]));
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': escaped.path,
          'role': 'exe',
        }),
        contains('必须落在插件目录内'),
      );
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': '../${outside.path.split(Platform.pathSeparator).last}/evil.ico',
          'role': 'exe',
        }),
        contains('必须落在插件目录内'),
      );
    });

    test('未配置插件目录 ⇒ fail-closed', () async {
      final UiBrandingRegistry empty = UiBrandingRegistry();
      final File file = writeIco('app.ico', <int>[16, 32, 48, 256]);
      expect(
        await empty.declare('ui.alpha', <String, dynamic>{
          'icon': file.path,
          'role': 'exe',
        }),
        contains('无法确认图标归属'),
      );
    });
  });

  group('应用前重校验（失效回默认，不留旧图）', () {
    test('最新一条失效 ⇒ 移除并回退上一条', () async {
      expect(await declareIco('ui.alpha'), isNull);
      final File beta = writeIco('beta.ico', <int>[16, 32, 48, 256]);
      expect(
        await registry.declare('ui.beta', <String, dynamic>{
          'icon': 'beta.ico',
          'role': 'exe',
        }),
        isNull,
      );
      expect(registry.active!.pluginId, 'ui.beta');

      beta.deleteSync();
      final UiBrandingEntry? active = await registry.revalidateActive();
      expect(active!.pluginId, 'ui.alpha', reason: '失效后回退上一条');
      expect(registry.entries.map((UiBrandingEntry e) => e.pluginId), <String>['ui.alpha']);
      expect(logs.single, contains('品牌失效'));
      expect(logs.single, contains('ui.beta'));
    });

    test('全部失效 ⇒ null（默认品牌）', () async {
      final File alpha = writeIco('alpha.ico', <int>[16, 32, 48, 256]);
      expect(
        await registry.declare('ui.alpha', <String, dynamic>{
          'icon': 'alpha.ico',
          'role': 'exe',
        }),
        isNull,
      );
      alpha.deleteSync();
      expect(await registry.revalidateActive(), isNull);
      expect(registry.active, isNull);
      expect(logs.single, contains('默认品牌'));
    });

    test('文件仍在但已不可读 ⇒ 也回默认', () async {
      // Windows 上打开中的文件仍可读，这里用"换成目录"制造不可读：
      // 先申报成功，再把文件替换成同名目录（exists 仍为真，但不是文件）。
      final File icon = writeIco('app.ico', <int>[16, 32, 48, 256]);
      expect(await declareIco('ui.alpha'), isNull);
      icon.deleteSync();
      Directory(icon.path).createSync();
      expect(await registry.revalidateActive(), isNull);
      expect(registry.active, isNull);
    });
  });
}

/// 最小 ICO（解析器只读目录项）。
List<int> _ico(List<int> sizes) {
  final List<int> bytes = <int>[0, 0, 1, 0];
  final int count = sizes.length;
  bytes.addAll(<int>[count & 0xff, (count >> 8) & 0xff]);
  for (final int size in sizes) {
    final int side = size >= 256 ? 0 : size;
    bytes.addAll(<int>[
      side,
      side,
      0,
      0,
      1,
      0,
      32,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
  }
  return bytes;
}

/// 最小 PNG（18 字节签名+IHDR 足够过解析器）。
List<int> _png(int width, int height) => <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  (width >> 24) & 0xff,
  (width >> 16) & 0xff,
  (width >> 8) & 0xff,
  width & 0xff,
  (height >> 24) & 0xff,
  (height >> 16) & 0xff,
  (height >> 8) & 0xff,
  height & 0xff,
];
