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

  test('装载手写的 settings.yaml 与 models/*.yaml（未知键保留）', () {
    File(paths.settingsFile).writeAsStringSync('''
# 手写注释
frame_rate: 120
rate_limit_enabled: "true"
message_cutin_direct: on
custom_extra_key: 保留我
''');
    File(paths.modelFile('demo')).writeAsStringSync('''
model_id: demo
name: 我的手写模型
base_url: https://api.example.com/v1
api_key: sk-handwritten
thinking: true
max_seqlen: 32000
''');
    // 未闭合的 flow 序列：必定解析失败
    File(paths.modelFile('broken')).writeAsStringSync('a: [1, 2\n');

    final CoreSettings settings = CoreSettings();
    FileSettingsSink(paths, log: logs.add).load(settings);

    expect(settings.frameRate, 120);
    expect(settings.rateLimitEnabled, isTrue);
    expect(settings.messageCutinDirect, isTrue);
    expect(settings.extra['custom_extra_key'], '保留我');
    expect(settings.model('demo')?.name, '我的手写模型');
    expect(settings.model('demo')?.apiKey, 'sk-handwritten');
    expect(settings.model('demo')?.thinking, isTrue);
    expect(settings.model('demo')?.maxSeqlen, 32000);
    expect(settings.model('broken'), isNull);
    expect(logs.join('\n'), contains('模型配置解析失败'));
  });

  test('改动后落盘：settings.yaml 保留未知键，模型文件含明文密钥与注释', () async {
    final FileSettingsSink sink = FileSettingsSink(paths, log: logs.add);
    final CoreSettings settings = CoreSettings();
    sink.load(settings);

    settings.extra['custom_extra_key'] = '保留我';
    settings.setFrameRate(300);
    settings.rateLimitEnabled = true;
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'name': '新模型',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-plain',
    });
    await sink.flush();

    final String settingsYaml = File(paths.settingsFile).readAsStringSync();
    expect(settingsYaml, contains('frame_rate: 300'));
    expect(settingsYaml, contains('rate_limit_enabled: true'));
    expect(settingsYaml, contains('# Tree 全局设置'));
    // 值含中日韩字符会被保守地加引号（读回来仍是字符串）
    expect(settingsYaml, contains('custom_extra_key:'));
    expect(settingsYaml, contains('保留我'));

    final String modelYaml = File(paths.modelFile('demo')).readAsStringSync();
    expect(modelYaml, contains('# Tree 模型配置'));
    expect(modelYaml, contains('model_id: demo'));
    // 明文密钥（用户需要能直接看到并替换）
    expect(modelYaml, contains('api_key: sk-plain'));

    // 重新装载：值一致
    final CoreSettings reloaded = CoreSettings();
    FileSettingsSink(paths).load(reloaded);
    expect(reloaded.frameRate, 300);
    expect(reloaded.rateLimitEnabled, isTrue);
    expect(reloaded.model('demo')?.apiKey, 'sk-plain');
    expect(reloaded.extra['custom_extra_key'], '保留我');

    // 删除模型：文件消失（必须 flush **装载时挂上的那个 sink**——落盘任务
    // 排在它的队列里，新建 sink 的队列是空的）
    reloaded.deleteModel('demo');
    await reloaded.sink!.flush();
    expect(File(paths.modelFile('demo')).existsSync(), isFalse);
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
    settings.messageCutinDirect = true;
    await settings.sink!.flush();
    expect(
      File(paths.settingsFile).readAsStringSync(),
      contains('message_cutin_direct: true'),
    );
  });
}
