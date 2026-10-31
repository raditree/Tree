import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory tempDir;
  late TreePaths paths;
  final List<String> logs = <String>[];

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('tree_settings_test_');
    paths = TreePaths(tempDir.path);
    paths.ensureLayoutSync();
    logs.clear();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('装载手写的 settings.yaml（模型池归插件，核心不再装载；未知键保留）', () {
    File(paths.settingsFile).writeAsStringSync('''
# 手写注释
frame_rate: 120
custom_extra_key: 保留我
''');
    File(paths.modelFile('demo')).writeAsStringSync('''
model_id: demo
name: 我的手写模型
base_url: https://api.example.com/v1
api_key: sk-handwritten
''');

    final CoreSettings settings = CoreSettings();
    FileSettingsSink(paths, log: logs.add).load(settings);

    expect(settings.frameRate, 120);
    expect(settings.extra['custom_extra_key'], '保留我');
    // L-22：模型池的写者已是 tree.agent，核心不再装载 models/*.yaml。
    expect(settings.model('demo'), isNull);
    expect(logs.join('\n'), isNot(contains('模型配置')));
  });

  test('改动后落盘：settings.yaml 保留未知键；插件未落新文件时旧领域键原样保留', () async {
    File(paths.settingsFile).writeAsStringSync('token_acquisition_rate: 240\n');
    final FileSettingsSink sink = FileSettingsSink(paths, log: logs.add);
    final CoreSettings settings = CoreSettings();
    sink.load(settings);

    settings.extra['custom_extra_key'] = '保留我';
    settings.setFrameRate(300);
    await sink.flush();

    final String settingsYaml = File(paths.settingsFile).readAsStringSync();
    expect(settingsYaml, contains('frame_rate: 300'));
    expect(settingsYaml, contains('# Tree 全局设置'));
    // 值含中日韩字符会被保守地加引号（读回来仍是字符串）
    expect(settingsYaml, contains('custom_extra_key:'));
    expect(settingsYaml, contains('保留我'));
    // 插件从没启动过 ⇒ 旧键不能被核心抹掉（顺序无关的关键条件）。
    expect(settingsYaml, contains('token_acquisition_rate: 240'));

    final CoreSettings reloaded = CoreSettings();
    FileSettingsSink(paths).load(reloaded);
    expect(reloaded.frameRate, 300);
    expect(reloaded.extra['custom_extra_key'], '保留我');
  });

  test('插件已写 agent_settings.yaml ⇒ 核心删旧键并备份一次', () async {
    File(paths.settingsFile).writeAsStringSync(
      'frame_rate: 60\ntoken_acquisition_rate: 240\n',
    );
    File(paths.agentSettingsFile).writeAsStringSync('token_acquisition_rate: 250\n');

    final FileSettingsSink sink = FileSettingsSink(paths, log: logs.add);
    final CoreSettings settings = CoreSettings();
    sink.load(settings);
    await sink.flush();

    final String settingsYaml = File(paths.settingsFile).readAsStringSync();
    expect(settingsYaml, contains('frame_rate: 60'));
    expect(settingsYaml, isNot(contains('token_acquisition_rate')));
    expect(settings.frameRate, 60);
    // 备份恰好一份，且含被删的旧键（回滚用）。
    final List<String> backups = Directory(paths.configDir)
        .listSync()
        .whereType<File>()
        .map((File file) => file.uri.pathSegments.last)
        .where((String name) => name.startsWith('settings.yaml.bak.'))
        .toList();
    expect(backups, hasLength(1));
    expect(
      File('${paths.settingsFile}.bak.${backups.single.split('bak.').last}')
          .readAsStringSync(),
      contains('token_acquisition_rate: 240'),
    );
    expect(logs.join('\n'), contains('已归 tree.agent'));

    // 再启动一次：旧键已不存在 ⇒ 不重复备份、不再改文件。
    FileSettingsSink(paths).load(CoreSettings());
    expect(
      Directory(paths.configDir)
          .listSync()
          .whereType<File>()
          .map((File file) => file.uri.pathSegments.last)
          .where((String name) => name.startsWith('settings.yaml.bak.')),
      hasLength(1),
    );
  });

  test('agent_settings.yaml 无效值 ⇒ 核心不动旧键', () async {
    File(paths.settingsFile).writeAsStringSync('token_acquisition_rate: 240\n');
    File(paths.agentSettingsFile).writeAsStringSync('token_acquisition_rate: abc\n');

    final FileSettingsSink sink = FileSettingsSink(paths, log: logs.add);
    final CoreSettings settings = CoreSettings();
    sink.load(settings);
    await sink.flush();

    expect(
      File(paths.settingsFile).readAsStringSync(),
      contains('token_acquisition_rate: 240'),
    );
  });

  test('损坏的 settings.yaml：记录日志并使用默认设置（不崩）', () {
    File(paths.settingsFile).writeAsStringSync('- 这不是映射\n- 真的不是\n');
    final CoreSettings settings = CoreSettings();
    FileSettingsSink(paths, log: logs.add).load(settings);
    expect(settings.frameRate, CoreSettings.frameRateMin);
    expect(settings.sink, isNotNull, reason: '即使文件坏了也要挂上落盘（下次保存会修好它）');
    expect(logs.join('\n'), contains('settings.yaml 解析失败'));
  });

  test('load 后 sink 已挂上：后续改动自动落盘', () async {
    final FileSettingsSink sink = FileSettingsSink(paths);
    final CoreSettings settings = CoreSettings();
    sink.load(settings);
    expect(settings.sink, isNotNull);
    settings.setFrameRate(300);
    await settings.sink!.flush();
    expect(
      File(paths.settingsFile).readAsStringSync(),
      contains('frame_rate: 300'),
    );
  });
}
