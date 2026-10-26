import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tree/app_version.dart';
import 'package:tree/io/ui_identity.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_ui_identity_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File writeManifest(Object? content) {
    final File file = File(p.join(temp.path, 'plugin.json'));
    file.writeAsStringSync(
      content is String ? content : jsonEncode(content),
    );
    return file;
  }

  test('有 plugin.json 时声明身份，握手帧带 plugin.manage', () {
    writeManifest(<String, Object>{
      'id': 'tree.ui.default',
      'version': '1.0.5',
      'runtime': 'ui',
    });

    final UiIdentity identity = UiIdentity.load(appDir: temp);

    expect(identity.fromManifest, isTrue);
    expect(identity.pluginId, 'tree.ui.default');
    expect(identity.version, '1.0.5');
    final Map<String, dynamic>? frame = identity.helloFrame();
    expect(frame, isNotNull);
    expect(frame!['type'], 'ui.hello');
    final Map<String, dynamic> data = frame['data'] as Map<String, dynamic>;
    expect(data['plugin_id'], 'tree.ui.default');
    expect(data['version'], '1.0.5');
    expect(data['capabilities'], contains('plugin.manage'));
  });

  test('多窗口：hello 带 window_id（连接与窗口能对上），单窗口不带该键', () {
    writeManifest(<String, Object>{
      'id': 'tree.ui.default',
      'version': '1.0.5',
      'runtime': 'ui',
    });
    final UiIdentity identity = UiIdentity.load(appDir: temp);

    final Map<String, dynamic> multi =
        identity.helloFrame(windowId: 'w2')!;
    final Map<String, dynamic> multiData =
        multi['data'] as Map<String, dynamic>;
    expect(multiData['window_id'], 'w2');

    final Map<String, dynamic> single = identity.helloFrame()!;
    final Map<String, dynamic> singleData =
        single['data'] as Map<String, dynamic>;
    expect(singleData.containsKey('window_id'), isFalse);
  });

  test('没有清单时退回默认 id 且不发握手（开发期不能把自己踢下线）', () {
    final UiIdentity identity = UiIdentity.load(appDir: temp);

    expect(identity.fromManifest, isFalse);
    expect(identity.pluginId, UiIdentity.defaultPluginId);
    expect(identity.helloFrame(), isNull);
  });

  test('清单损坏 / 缺 id 时退回默认 id，并记录可读原因', () {
    writeManifest('{ not json');
    final UiIdentity broken = UiIdentity.load(appDir: temp);
    expect(broken.fromManifest, isFalse);
    expect(broken.error, isNotEmpty);
    expect(broken.helloFrame(), isNull);

    writeManifest(<String, Object>{'version': '9.9.9'});
    final UiIdentity missingId = UiIdentity.load(appDir: temp);
    expect(missingId.fromManifest, isFalse);
    expect(missingId.pluginId, UiIdentity.defaultPluginId);
    expect(missingId.helloFrame(), isNull);
  });

  test('缺 version 时用应用版本兜底', () {
    writeManifest(<String, Object>{'id': 'tree.ui.default'});

    final UiIdentity identity = UiIdentity.load(appDir: temp);

    expect(identity.fromManifest, isTrue);
    expect(identity.version, kAppVersion);
  });
}
