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

/// 核心进程的设置集合（M1 全内存，M2 落 `~/.tree/config/settings.yaml`）。
///
/// 说明：`dataCollection` 在桌面单用户形态下**没有收集方**，保留该开关
/// 只为兼容既有设置页；M7 删除设置页对应卡片后应一并移除。
class CoreSettings {
  /// 流式帧率下限（与前端声明范围一致）。
  static const int frameRateMin = 20;

  /// 流式帧率上限。
  static const int frameRateMax = 1000;

  bool rateLimitEnabled = false;
  bool dataCollectionEnabled = false;
  bool messageCutinDirect = false;
  int frameRate = frameRateMin;

  final Map<String, CoreModelConfig> _models = <String, CoreModelConfig>{};

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

  void putModel(CoreModelConfig model) => _models[model.modelId] = model;

  /// 新建模型；`model_id` 已存在时返回 null（调用方回 409）。
  CoreModelConfig? createModel(Map<String, dynamic> payload) {
    final String modelId = (payload['model_id'] as String? ?? '').trim();
    if (modelId.isEmpty || _models.containsKey(modelId)) return null;
    final CoreModelConfig model = CoreModelConfig(modelId: modelId);
    model.merge(payload);
    _models[modelId] = model;
    return model;
  }

  /// 更新模型；不存在返回 null。
  CoreModelConfig? updateModel(String modelId, Map<String, dynamic> payload) {
    final CoreModelConfig? model = _models[modelId];
    if (model == null) return null;
    model.merge(payload);
    return model;
  }

  /// 删除模型；返回是否真的删除了条目。
  bool deleteModel(String modelId) => _models.remove(modelId) != null;

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
    frameRate = value < frameRateMin
        ? frameRateMin
        : (value > frameRateMax ? frameRateMax : value);
    return frameRate;
  }
}
