/// 自定义模型配置（现状 server `configs/models/<model_id>.yaml` 的桌面替身）。
///
/// **api_key 永不回显**：`toApiJson` 剥离密钥并把 `base_url` 脱敏为
/// 协议+主机（与现状 server 行为一致，避免密钥经 UI/日志泄漏）。
/// `PATCH` 时空的 `base_url`/`api_key` 表示"保留原值"。
class CoreModelConfig {
  CoreModelConfig({
    required this.modelId,
    this.name = '',
    this.baseUrl = '',
    this.apiKey = '',
    this.thinking = false,
    this.ifVision = false,
    this.reasoningEffort = '',
    List<String>? reasoningEffortOptions,
    this.maxSeqlen = 0,
    this.maxOutputTokens = 0,
  }) : reasoningEffortOptions =
           reasoningEffortOptions ?? List<String>.of(defaultReasoningEfforts);

  /// 端点支持的思考强度档位兜底（与前端 `_reasoningEfforts` 一致）。
  static const List<String> defaultReasoningEfforts = <String>[
    'low',
    'high',
    'max',
  ];

  final String modelId;
  String name;
  String baseUrl;
  String apiKey;
  bool thinking;
  bool ifVision;
  String reasoningEffort;
  List<String> reasoningEffortOptions;
  int maxSeqlen;
  int maxOutputTokens;

  /// 持久化形态（含密钥；M2 落 `~/.tree/config/models/<model_id>.yaml`，
  /// 计划中要求 600 权限）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'model_id': modelId,
    'name': name,
    'base_url': baseUrl,
    'api_key': apiKey,
    'thinking': thinking,
    'if_vision': ifVision,
    'reasoning_effort': reasoningEffort,
    'reasoning_effort_options': reasoningEffortOptions,
    'max_seqlen': maxSeqlen,
    'max_output_tokens': maxOutputTokens,
  };

  /// 前端形态：无密钥、base_url 脱敏。
  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'model_id': modelId,
    'name': name.isEmpty ? modelId : name,
    'base_url': maskBaseUrl(baseUrl),
    'thinking': thinking,
    'if_vision': ifVision,
    'reasoning_effort': reasoningEffort,
    'reasoning_effort_options': reasoningEffortOptions,
    'max_seqlen': maxSeqlen,
    'max_output_tokens': maxOutputTokens,
  };

  static CoreModelConfig fromJson(Map<String, dynamic> json) {
    return CoreModelConfig(
      modelId: json['model_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      baseUrl: json['base_url'] as String? ?? '',
      apiKey: json['api_key'] as String? ?? '',
      thinking: json['thinking'] as bool? ?? false,
      ifVision: json['if_vision'] as bool? ?? false,
      reasoningEffort: json['reasoning_effort'] as String? ?? '',
      reasoningEffortOptions:
          (json['reasoning_effort_options'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toList(),
      maxSeqlen: (json['max_seqlen'] as num?)?.toInt() ?? 0,
      maxOutputTokens: (json['max_output_tokens'] as num?)?.toInt() ?? 0,
    );
  }

  /// 用请求体合并字段；`base_url`/`api_key` 为空串表示保留原值。
  void merge(Map<String, dynamic> payload) {
    if (payload.containsKey('name')) name = payload['name'] as String? ?? name;
    if (payload.containsKey('base_url')) {
      final String value = (payload['base_url'] as String? ?? '').trim();
      if (value.isNotEmpty) baseUrl = value;
    }
    if (payload.containsKey('api_key')) {
      final String value = (payload['api_key'] as String? ?? '').trim();
      if (value.isNotEmpty) apiKey = value;
    }
    if (payload.containsKey('thinking')) {
      thinking = payload['thinking'] as bool? ?? thinking;
    }
    if (payload.containsKey('if_vision')) {
      ifVision = payload['if_vision'] as bool? ?? ifVision;
    }
    if (payload.containsKey('reasoning_effort')) {
      reasoningEffort = payload['reasoning_effort'] as String? ?? '';
    }
    final List<dynamic>? options =
        payload['reasoning_effort_options'] as List<dynamic>?;
    if (options != null && options.isNotEmpty) {
      final List<String> normalized = options
          .map((dynamic e) => e.toString().trim())
          .where((String e) => e.isNotEmpty)
          .toList();
      if (normalized.isNotEmpty) {
        reasoningEffortOptions = normalized;
        // 档位列表变窄时，默认档位必须仍落在其中，否则前端下拉断言失败
        if (reasoningEffort.isNotEmpty &&
            !reasoningEffortOptions.contains(reasoningEffort)) {
          reasoningEffort = reasoningEffortOptions.first;
        }
      }
    }
    if (payload.containsKey('max_seqlen')) {
      maxSeqlen = (payload['max_seqlen'] as num?)?.toInt() ?? maxSeqlen;
    }
    if (payload.containsKey('max_output_tokens')) {
      maxOutputTokens =
          (payload['max_output_tokens'] as num?)?.toInt() ?? maxOutputTokens;
    }
  }

  /// `base_url` 脱敏：仅保留协议 + 主机（+ 非默认端口）。
  static String maskBaseUrl(String raw) {
    if (raw.isEmpty) return '';
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return '';
    final bool defaultPort =
        (uri.scheme == 'https' && uri.port == 443) ||
        (uri.scheme == 'http' && uri.port == 80);
    return defaultPort || uri.port == 0
        ? '${uri.scheme}://${uri.host}'
        : '${uri.scheme}://${uri.host}:${uri.port}';
  }

  /// 模型上下文长度（前端进度条分母）；未配置时给保守兜底。
  int get effectiveMaxSeqlen => maxSeqlen > 0 ? maxSeqlen : 128000;
}

/// 设置落盘后端（M2 起由 `FileSettingsSink` 提供）。
///
/// 设置层只声明"该保存了"，不认识文件系统；`FileSettingsSink` 负责序列化与
/// write-behind 排队。测试与"无落盘"场景把 [CoreSettings.sink] 留空即可。
abstract interface class CoreSettingsSink {
  /// 保存全局设置（`config/settings.yaml`）。
  void saveSettings(CoreSettings settings);

  /// 保存单个模型配置（`config/models/<model_id>.yaml`）。
  void saveModel(CoreModelConfig model);

  /// 删除模型配置文件。
  void deleteModel(String modelId);

  /// 等待全部在途落盘（关停与测试用）。
  Future<void> flush();
}

/// 核心进程的设置集合。
///
/// 两个设计点直接服务"用户绕开 UI 直接改配置文件"：
/// - 读取用 [_bool]/[_int] 做宽容转换，手写 `"true"` / `1` 也能生效；
/// - **未知键原样保留**在 [extra] 中并在保存时写回，用户自己加的配置项不会
///   被界面操作悄悄抹掉。
///
/// 说明：`dataCollection` 在桌面单用户形态下**没有收集方**，保留该开关
/// 只为兼容既有设置页；M7 删除设置页对应卡片后应一并移除。
class CoreSettings {
  /// 流式帧率下限（与前端声明范围一致）。
  static const int frameRateMin = 20;

  /// 流式帧率上限。
  static const int frameRateMax = 1000;

  /// 落盘后端；为 null 时所有改动只留在内存（测试/无盘场景）。
  CoreSettingsSink? sink;

  /// settings.yaml 中**不属于已知键**的内容（原样保留并写回）。
  Map<String, dynamic> extra = <String, dynamic>{};

  bool _rateLimitEnabled = false;
  bool _dataCollectionEnabled = false;
  bool _messageCutinDirect = false;
  int _frameRate = frameRateMin;

  /// 是否开启主动延迟（限制单 agent 的 API 调用频率）。
  bool get rateLimitEnabled => _rateLimitEnabled;

  set rateLimitEnabled(bool value) {
    if (_rateLimitEnabled == value) return;
    _rateLimitEnabled = value;
    sink?.saveSettings(this);
  }

  /// 是否允许收集使用数据（桌面形态下无收集方，见类文档）。
  bool get dataCollectionEnabled => _dataCollectionEnabled;

  set dataCollectionEnabled(bool value) {
    if (_dataCollectionEnabled == value) return;
    _dataCollectionEnabled = value;
    sink?.saveSettings(this);
  }

  /// 消息切入模式：true = 直接切入，false = 串行排队。
  bool get messageCutinDirect => _messageCutinDirect;

  set messageCutinDirect(bool value) {
    if (_messageCutinDirect == value) return;
    _messageCutinDirect = value;
    sink?.saveSettings(this);
  }

  /// 流式帧率（帧/秒）。
  int get frameRate => _frameRate;

  final Map<String, CoreModelConfig> _models = <String, CoreModelConfig>{};

  /// 从 settings.yaml 的映射装载（未知键进入 [extra]）。
  void applyMap(Map<String, dynamic> map) {
    _frameRate = _clampFrameRate(_int(map, 'frame_rate', frameRateMin));
    _rateLimitEnabled = _bool(map, 'rate_limit_enabled', false);
    _dataCollectionEnabled = _bool(map, 'data_collection_enabled', false);
    _messageCutinDirect = _bool(map, 'message_cutin_direct', false);
    extra = Map<String, dynamic>.from(map)
      ..remove('frame_rate')
      ..remove('rate_limit_enabled')
      ..remove('data_collection_enabled')
      ..remove('message_cutin_direct');
  }

  /// 序列化为 settings.yaml 的映射（已知键 + [extra] 保留的未知键）。
  Map<String, dynamic> toMap() => <String, dynamic>{
    ...extra,
    'frame_rate': _frameRate,
    'rate_limit_enabled': _rateLimitEnabled,
    'data_collection_enabled': _dataCollectionEnabled,
    'message_cutin_direct': _messageCutinDirect,
  };

  /// 模型列表（按 model_id 排序，稳定可预测）。
  List<CoreModelConfig> models() {
    final List<CoreModelConfig> list = _models.values.toList()
      ..sort(
        (CoreModelConfig a, CoreModelConfig b) =>
            a.modelId.compareTo(b.modelId),
      );
    return list;
  }

  CoreModelConfig? model(String modelId) => _models[modelId];

  /// 直接放入模型（装载用；不触发落盘）。
  void putModel(CoreModelConfig model) => _models[model.modelId] = model;

  /// 新建模型；`model_id` 已存在时返回 null（调用方回 409）。
  CoreModelConfig? createModel(Map<String, dynamic> payload) {
    final String modelId = (payload['model_id'] as String? ?? '').trim();
    if (modelId.isEmpty || _models.containsKey(modelId)) return null;
    final CoreModelConfig model = CoreModelConfig(modelId: modelId);
    model.merge(payload);
    _models[modelId] = model;
    sink?.saveModel(model);
    return model;
  }

  /// 更新模型；不存在返回 null。
  CoreModelConfig? updateModel(String modelId, Map<String, dynamic> payload) {
    final CoreModelConfig? model = _models[modelId];
    if (model == null) return null;
    model.merge(payload);
    sink?.saveModel(model);
    return model;
  }

  /// 删除模型；返回是否真的删除了条目。
  bool deleteModel(String modelId) {
    final bool removed = _models.remove(modelId) != null;
    if (removed) sink?.deleteModel(modelId);
    return removed;
  }

  /// 校验新增模型必填项（与前端拦截一致：base_url / api_key 必填）。
  static String? validateNewModel(Map<String, dynamic> payload) {
    final String modelId = (payload['model_id'] as String? ?? '').trim();
    if (modelId.isEmpty) return 'model_id 不能为空';
    final String baseUrl = (payload['base_url'] as String? ?? '').trim();
    if (baseUrl.isEmpty) return 'base_url 不能为空';
    final String apiKey = (payload['api_key'] as String? ?? '').trim();
    if (apiKey.isEmpty) return 'api_key 不能为空';
    return null;
  }

  /// 帧率夹取到 [frameRateMin, frameRateMax]。
  int setFrameRate(int value) {
    _frameRate = _clampFrameRate(value);
    sink?.saveSettings(this);
    return _frameRate;
  }

  static int _clampFrameRate(int value) => value < frameRateMin
      ? frameRateMin
      : (value > frameRateMax ? frameRateMax : value);

  static bool _bool(Map<String, dynamic> map, String key, bool fallback) {
    final Object? value = map[key];
    if (value is bool) return value;
    if (value is String) {
      final String text = value.trim().toLowerCase();
      if (text == 'true' || text == 'yes' || text == 'on' || text == '1') {
        return true;
      }
      if (text == 'false' || text == 'no' || text == 'off' || text == '0') {
        return false;
      }
    }
    if (value is num) return value != 0;
    return fallback;
  }

  static int _int(Map<String, dynamic> map, String key, int fallback) {
    final Object? value = map[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }
}
