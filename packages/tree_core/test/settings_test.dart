import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 记录落盘调用的假 sink。
class _RecordingSink implements CoreSettingsSink {
  int settingsSaved = 0;
  final List<String> modelsSaved = <String>[];
  final List<String> modelsDeleted = <String>[];
  int flushes = 0;

  @override
  void saveSettings(CoreSettings settings) => settingsSaved++;

  @override
  void saveModel(CoreModelConfig model) => modelsSaved.add(model.modelId);

  @override
  void deleteModel(String modelId) => modelsDeleted.add(modelId);

  @override
  Future<void> flush() async => flushes++;
}

void main() {
  group('CoreSettings 模型池', () {
    test('新增模型校验必填项，重复 model_id 被拒绝', () {
      final CoreSettings settings = CoreSettings();
      expect(CoreSettings.validateNewModel(<String, dynamic>{}), isNotNull);
      expect(
        CoreSettings.validateNewModel(<String, dynamic>{
          'model_id': 'm1',
          'base_url': 'https://api.example.com/v1',
        }),
        isNotNull,
      );
      final CoreModelConfig? created = settings.createModel(<String, dynamic>{
        'model_id': 'm1',
        'name': '示例',
        'base_url': 'https://api.example.com/v1',
        'api_key': 'sk-secret',
        'max_seqlen': 64000,
      });
      expect(created, isNotNull);
      expect(
        settings.createModel(<String, dynamic>{
          'model_id': 'm1',
          'base_url': 'https://x',
          'api_key': 'k',
        }),
        isNull,
      );
      expect(settings.models().map((CoreModelConfig m) => m.modelId), <String>[
        'm1',
      ]);
    });

    test('API 形态剥离密钥并把 base_url 脱敏为协议+主机', () {
      final CoreSettings settings = CoreSettings();
      settings.createModel(<String, dynamic>{
        'model_id': 'm1',
        'base_url': 'https://api.example.com:8443/v1/chat',
        'api_key': 'sk-secret',
      });
      final Map<String, dynamic> api = settings.model('m1')!.toApiJson();
      expect(api.containsKey('api_key'), isFalse);
      expect(api['base_url'], 'https://api.example.com:8443');
      expect(settings.model('m1')!.toJson()['api_key'], 'sk-secret');
      expect(
        CoreModelConfig.maskBaseUrl('https://api.example.com/v1'),
        'https://api.example.com',
      );
      expect(CoreModelConfig.maskBaseUrl(''), '');
      expect(CoreModelConfig.maskBaseUrl('not a url'), '');
    });

    test('更新时空 base_url/api_key 保留原值；档位收窄时默认档位跟随', () {
      final CoreSettings settings = CoreSettings();
      settings.createModel(<String, dynamic>{
        'model_id': 'm1',
        'base_url': 'https://api.example.com/v1',
        'api_key': 'sk-old',
        'reasoning_effort': 'max',
      });
      settings.updateModel('m1', <String, dynamic>{
        'base_url': '',
        'api_key': '',
        'name': '新名字',
      });
      final CoreModelConfig model = settings.model('m1')!;
      expect(model.apiKey, 'sk-old');
      expect(model.baseUrl, 'https://api.example.com/v1');
      expect(model.name, '新名字');
      settings.updateModel('m1', <String, dynamic>{
        'reasoning_effort_options': <String>['low', 'high'],
      });
      expect(model.reasoningEffort, 'low');
      expect(settings.updateModel('missing', <String, dynamic>{}), isNull);
      expect(settings.deleteModel('missing'), isFalse);
    });

    test('帧率夹取到 20~1000；有效上下文长度有兜底', () {
      final CoreSettings settings = CoreSettings();
      expect(settings.setFrameRate(5), CoreSettings.frameRateMin);
      expect(settings.setFrameRate(99999), CoreSettings.frameRateMax);
      expect(settings.setFrameRate(60), 60);
      expect(settings.frameRate, 60);
      expect(CoreModelConfig(modelId: 'm').effectiveMaxSeqlen, 128000);
    });

    test('token 获取帧率默认上限，夹取到 20~1000', () {
      final CoreSettings settings = CoreSettings();
      expect(settings.tokenAcquisitionRate, CoreSettings.tokenRateMax);
      expect(settings.setTokenAcquisitionRate(1), CoreSettings.tokenRateMin);
      expect(
        settings.setTokenAcquisitionRate(99999),
        CoreSettings.tokenRateMax,
      );
      expect(settings.setTokenAcquisitionRate(60), 60);
      expect(settings.tokenAcquisitionRate, 60);
    });
  });

  group('CoreSettings 与配置文件的映射', () {
    test('applyMap/toMap 往返；未知键进入 extra 并在保存时写回', () {
      final CoreSettings settings = CoreSettings();
      settings.applyMap(<String, dynamic>{
        'frame_rate': 90,
        'token_acquisition_rate': 45,
        'message_cutin_direct': true,
        'data_collection_enabled': true,
        'my_custom_key': <String, dynamic>{
          'nested': <int>[1, 2],
        },
        'another': 'x',
      });
      expect(settings.frameRate, 90);
      expect(settings.tokenAcquisitionRate, 45);
      expect(settings.messageCutinDirect, isTrue);
      expect(settings.dataCollectionEnabled, isTrue);
      expect(
        settings.extra.keys,
        containsAll(<String>['my_custom_key', 'another']),
      );
      final Map<String, dynamic> out = settings.toMap();
      expect(out['frame_rate'], 90);
      expect(out['token_acquisition_rate'], 45);
      expect(out['my_custom_key'], <String, dynamic>{
        'nested': <int>[1, 2],
      });
      // 再次装载应完全一致
      final CoreSettings again = CoreSettings()..applyMap(out);
      expect(again.toMap(), out);
    });

    test('手写的字符串/数字也能被宽容解析', () {
      final CoreSettings settings = CoreSettings();
      settings.applyMap(<String, dynamic>{
        'frame_rate': '120',
        'token_acquisition_rate': '240',
        'message_cutin_direct': 'off',
        'data_collection_enabled': 1,
      });
      expect(settings.frameRate, 120);
      expect(settings.tokenAcquisitionRate, 240);
      expect(settings.messageCutinDirect, isFalse);
      expect(settings.dataCollectionEnabled, isTrue);
      // 非法帧率被夹取
      settings.applyMap(<String, dynamic>{'frame_rate': 'abc'});
      expect(settings.frameRate, CoreSettings.frameRateMin);
      // 非法 token 帧率回退到上限（近似不限速）
      settings.applyMap(<String, dynamic>{'token_acquisition_rate': 'abc'});
      expect(settings.tokenAcquisitionRate, CoreSettings.tokenRateMax);
    });
  });

  group('CoreSettings 落盘通知', () {
    test('设置变更通知 settings.yaml；模型增改删通知对应文件', () {
      final _RecordingSink sink = _RecordingSink();
      final CoreSettings settings = CoreSettings()..sink = sink;

      settings.dataCollectionEnabled = true;
      settings.dataCollectionEnabled = true; // 相同值不重复落盘
      settings.messageCutinDirect = true;
      settings.setTokenAcquisitionRate(120);
      settings.setFrameRate(120);
      expect(sink.settingsSaved, 4);

      settings.createModel(<String, dynamic>{
        'model_id': 'm1',
        'base_url': 'https://x',
        'api_key': 'k',
      });
      settings.updateModel('m1', <String, dynamic>{'name': 'n'});
      settings.deleteModel('m1');
      expect(sink.modelsSaved, <String>['m1', 'm1']);
      expect(sink.modelsDeleted, <String>['m1']);
    });

    test('无 sink 时全部改动只留内存（不抛错）', () {
      final CoreSettings settings = CoreSettings();
      settings.setTokenAcquisitionRate(120);
      settings.messageCutinDirect = true;
      settings.setFrameRate(50);
      settings.createModel(<String, dynamic>{
        'model_id': 'm1',
        'base_url': 'https://x',
        'api_key': 'k',
      });
      expect(settings.tokenAcquisitionRate, 120);
      expect(settings.models(), hasLength(1));
    });
  });

  group('token_scale 与最长会话记录（Q1-①）', () {
    CoreModelConfig model(CoreSettings settings) {
      settings.createModel(<String, dynamic>{
        'model_id': 'm1',
        'base_url': 'https://x',
        'api_key': 'k',
      });
      return settings.model('m1')!;
    }

    test('初值 2.00 / 0，并写进 toJson / fromJson / toApiJson', () {
      final CoreModelConfig config = model(CoreSettings());
      expect(config.tokenScale, defaultTokenScale);
      expect(config.longestSessionTokens, 0);
      expect(config.toJson()['token_scale'], 2.0);
      expect(config.toJson()['longest_session_tokens'], 0);
      expect(config.toApiJson()['token_scale'], 2.0);
      expect(config.toApiJson()['longest_session_tokens'], 0);
      final CoreModelConfig back = CoreModelConfig.fromJson(config.toJson());
      expect(back.tokenScale, 2.0);
      expect(back.longestSessionTokens, 0);
      // 手写 yaml 的字符串也能读进来
      expect(
        CoreModelConfig.fromJson(<String, dynamic>{'token_scale': '3.5'})
            .tokenScale,
        3.5,
      );
      expect(
        CoreModelConfig.fromJson(<String, dynamic>{'token_scale': -1})
            .tokenScale,
        defaultTokenScale,
        reason: '越界的比例回退到初值',
      );
    });

    test('真实 prompt_tokens 刷新最长记录并回写比例（保留两位）', () {
      final CoreModelConfig config = model(CoreSettings());
      expect(
        config.learnTokenScale(contextChars: 6000, promptTokens: 2400),
        isTrue,
      );
      expect(config.tokenScale, 2.5);
      expect(config.longestSessionTokens, 2400);
      // 不比记录更长的请求不再刷新
      expect(
        config.learnTokenScale(contextChars: 6000, promptTokens: 2400),
        isFalse,
      );
      expect(
        config.learnTokenScale(contextChars: 300, promptTokens: 100),
        isFalse,
      );
      expect(config.tokenScale, 2.5);
      // 更长的请求才继续刷新
      expect(
        config.learnTokenScale(contextChars: 10000, promptTokens: 3000),
        isTrue,
      );
      expect(config.tokenScale, 3.33, reason: '10/3 保留两位');
      expect(config.longestSessionTokens, 3000);
    });

    test('比值明显不合理的样本整条丢弃（不污染全局估算）', () {
      final CoreModelConfig config = model(CoreSettings());
      expect(
        config.learnTokenScale(contextChars: 6, promptTokens: 100),
        isFalse,
        reason: '0.06 字符/token：上下文太短或端点另算了固定开销',
      );
      expect(
        config.learnTokenScale(contextChars: 100000, promptTokens: 100),
        isFalse,
        reason: '1000 字符/token：不可能',
      );
      expect(
        config.learnTokenScale(contextChars: 0, promptTokens: 100),
        isFalse,
      );
      expect(
        config.learnTokenScale(contextChars: 100, promptTokens: 0),
        isFalse,
      );
      expect(config.tokenScale, defaultTokenScale);
      expect(config.longestSessionTokens, 0);
    });

    test('学习状态不参与 merge（用户编辑模型时不接受该字段）', () {
      final CoreSettings settings = CoreSettings();
      final CoreModelConfig config = model(settings);
      config.learnTokenScale(contextChars: 6000, promptTokens: 2400);
      settings.updateModel('m1', <String, dynamic>{
        'token_scale': 9.9,
        'longest_session_tokens': 99999,
        'name': '改名',
      });
      expect(config.name, '改名');
      expect(config.tokenScale, 2.5, reason: '学习状态不接受用户编辑');
      expect(config.longestSessionTokens, 2400);
    });

    test('学习后按既有落盘路径写回模型 yaml（与手动保存同一条路）', () {
      final _RecordingSink sink = _RecordingSink();
      final CoreSettings settings = CoreSettings()..sink = sink;
      final CoreModelConfig config = model(settings);
      expect(sink.modelsSaved, <String>['m1'], reason: '新建时保存一次');
      expect(
        config.learnTokenScale(contextChars: 6000, promptTokens: 2400),
        isTrue,
      );
      expect(sink.modelsSaved, <String>['m1', 'm1']);
    });

    test('成员级覆盖的副本带走学习状态（否则估算会随发起者漂移）', () {
      final CoreModelConfig config = model(CoreSettings());
      config.learnTokenScale(contextChars: 6000, promptTokens: 2400);
      final CoreModelConfig copy = config.withOverrides(<String, Object?>{
        'max_seqlen': 32000,
      });
      expect(copy.tokenScale, 2.5);
      expect(copy.longestSessionTokens, 2400);
    });

    test('max_seqlen 兜底值是一个显式常量（不再各处硬编码 128000）', () {
      expect(CoreSettings.fallbackMaxSeqlen, 128000);
      expect(
        CoreModelConfig(modelId: 'm').effectiveMaxSeqlen,
        CoreSettings.fallbackMaxSeqlen,
      );
    });
  });
}
