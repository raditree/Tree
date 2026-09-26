import '../util/tokens.dart';

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
    this.tokenScale = defaultTokenScale,
    this.longestSessionTokens = 0,
  }) : reasoningEffortOptions =
           reasoningEffortOptions ?? List<String>.of(defaultReasoningEfforts);

  /// token_scale 的可接受区间。
  ///
  /// 超出这个区间的"学习样本"一律不采纳（见 [learnTokenScale]）：真实端点里
  /// 0.2~20 字符/token 已经覆盖了从紧凑中文到稀疏代码的全部情形，超出只可能是
  /// 上下文太短或端点把缓存/工具声明另算。
  static const double minTokenScale = 0.2;
  static const double maxTokenScale = 20;

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

  /// 逐模型的 字符→token 换算比例（plan 1.3 的唯一口径，初值 2.00）。
  ///
  /// 由 [learnTokenScale] 用端点真实 usage 持续校准；**不参与 [merge]**——它是
  /// 学习状态，不是用户可编辑的配置项（用户手改 yaml 也会被下一轮学习覆盖）。
  double tokenScale;

  /// 学到 [tokenScale] 那次请求的真实 prompt_tokens（"最长会话"水位线）。
  ///
  /// 只有更长的请求才有资格刷新它：短请求里系统提示词/工具声明的占比过高，
  /// 算出来的比例不代表内容本身。
  int longestSessionTokens;

  /// 学习状态变更后的落盘回调（由 [CoreSettings] 放入模型池时挂上）。
  ///
  /// 让模型自己回调而不是把设置层传进来：解析器只交出模型对象，引擎不该认识设置
  /// 层；挂上这个闭包后，"学到新比例"与"用户在设置页点保存"走**同一条**落盘
  /// 路径。为 null 时只改内存（测试 / 无盘场景）。
  void Function(CoreModelConfig model)? onChanged;

  /// 用一次真实 usage 学习 字符/token 比例（Q1-①，plan 1.3）。
  ///
  /// 口径：真实 `prompt_tokens` **超过** [longestSessionTokens] 时刷新水位线，
  /// 并令 `token_scale = 该次请求上下文字符数 / 真实 prompt_tokens`（保留两位）。
  /// 返回是否采纳了这次样本——**无 usage 的端点只会读不会写**（调用方压根不会
  /// 调到这里）。
  bool learnTokenScale({required int contextChars, required int promptTokens}) {
    if (contextChars <= 0 || promptTokens <= 0) return false;
    if (promptTokens <= longestSessionTokens) return false;
    final double ratio = contextChars / promptTokens;
    if (ratio < minTokenScale || ratio > maxTokenScale) return false;
    longestSessionTokens = promptTokens;
    tokenScale = (ratio * 100).round() / 100;
    onChanged?.call(this);
    return true;
  }

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
    'token_scale': tokenScale,
    'longest_session_tokens': longestSessionTokens,
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
    'token_scale': tokenScale,
    'longest_session_tokens': longestSessionTokens,
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
      tokenScale: _readScale(json['token_scale']),
      longestSessionTokens:
          (json['longest_session_tokens'] as num?)?.toInt() ?? 0,
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

  /// 应用**成员级模型参数覆盖**（M5b）：只覆盖传入的非空项，返回新对象。
  ///
  /// 覆盖来自成员 agent 的 `agents/<id>.yaml`（用户在「团队成员 → 模型配置」页
  /// 设置）。注意 `compress_threshold` 只存不在这里用：压缩策略由后续里程碑
  /// （上下文 compaction）读取，当前请求不受它影响。
  CoreModelConfig withOverrides(Map<String, Object?> overrides) {
    if (overrides.isEmpty) return this;
    final CoreModelConfig copy = CoreModelConfig(
      modelId: modelId,
      name: name,
      baseUrl: baseUrl,
      apiKey: apiKey,
      thinking: thinking,
      ifVision: ifVision,
      reasoningEffort: reasoningEffort,
      reasoningEffortOptions: reasoningEffortOptions,
      maxSeqlen: maxSeqlen,
      maxOutputTokens: maxOutputTokens,
      // 学习状态必须一起带走：成员级覆盖用的是副本，漏掉就等于把学到的比例
      // 悄悄降回初值 2.00（估算口径会随"谁发起请求"漂移）。
      tokenScale: tokenScale,
      longestSessionTokens: longestSessionTokens,
    );
    final Object? effort = overrides['reasoning_effort'];
    if (effort is String && effort.trim().isNotEmpty) {
      copy.reasoningEffort = effort.trim();
    }
    final Object? seqlen = overrides['max_seqlen'];
    if (seqlen is num && seqlen.toInt() > 0) copy.maxSeqlen = seqlen.toInt();
    final Object? output = overrides['max_output_tokens'];
    if (output is num && output.toInt() > 0) {
      copy.maxOutputTokens = output.toInt();
    }
    return copy;
  }

  /// 模型上下文长度（前端进度条分母）；未配置时给保守兜底。
  ///
  /// 兜底值见 [CoreSettings.fallbackMaxSeqlen]：压缩判断走的是
  /// [CoreSettings]/[CoreAgent] 那条显式路径（会提示用户去补配置），
  /// 这个 getter 只服务"界面分母不能为空"。
  int get effectiveMaxSeqlen =>
      maxSeqlen > 0 ? maxSeqlen : CoreSettings.fallbackMaxSeqlen;

  /// 宽容读取 token_scale：手写 yaml 里的整数 / 字符串也能生效，非法值回初值。
  static double _readScale(Object? raw) {
    double? value;
    if (raw is num) {
      value = raw.toDouble();
    } else if (raw is String) {
      value = double.tryParse(raw.trim());
    }
    if (value == null || value < minTokenScale || value > maxTokenScale) {
      return defaultTokenScale;
    }
    return value;
  }
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
  /// 推送刷新帧率下限（与前端声明范围一致）。
  static const int frameRateMin = 20;

  /// 推送刷新帧率上限。
  static const int frameRateMax = 1000;

  /// token 获取帧率下限（与前端声明范围一致）。
  static const int tokenRateMin = 20;

  /// token 获取帧率上限（= 近似不限速）。
  static const int tokenRateMax = 1000;

  /// 模型没配 max_seqlen 时的兜底上下文长度。
  ///
  /// 兜底本身保留（进度条分母不能为空），但**不再静默**：压缩判断会显式标注用了
  /// 这个值并提示用户去「设置 → 自定义模型」补上真实的上下文长度（Q1-③）。
  static const int fallbackMaxSeqlen = 128000;

  /// 落盘后端；为 null 时所有改动只留在内存（测试/无盘场景）。
  CoreSettingsSink? sink;

  /// settings.yaml 中**不属于已知键**的内容（原样保留并写回）。
  Map<String, dynamic> extra = <String, dynamic>{};

  bool _dataCollectionEnabled = false;
  bool _messageCutinDirect = false;

  /// 推送刷新帧率（帧/秒）：把同一轮回复内的流式增量攒帧后合并下发的频率。
  int _frameRate = frameRateMin;

  /// token 获取帧率（帧/秒）：从 LLM 流中逐 token 取回复的节奏。
  ///
  /// 默认上限值（1000）= 近似不限速，保证未调校时行为与逐 token 直取一致。
  int _tokenAcquisitionRate = tokenRateMax;

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

  /// 推送刷新帧率（帧/秒）。
  int get frameRate => _frameRate;

  /// token 获取帧率（帧/秒）。
  int get tokenAcquisitionRate => _tokenAcquisitionRate;

  final Map<String, CoreModelConfig> _models = <String, CoreModelConfig>{};

  /// 从 settings.yaml 的映射装载（未知键进入 [extra]）。
  void applyMap(Map<String, dynamic> map) {
    _frameRate = _clampFrameRate(_int(map, 'frame_rate', frameRateMin));
    _tokenAcquisitionRate = _clampTokenRate(
      _int(map, 'token_acquisition_rate', tokenRateMax),
    );
    _dataCollectionEnabled = _bool(map, 'data_collection_enabled', false);
    _messageCutinDirect = _bool(map, 'message_cutin_direct', false);
    extra = Map<String, dynamic>.from(map)
      ..remove('frame_rate')
      ..remove('token_acquisition_rate')
      ..remove('data_collection_enabled')
      ..remove('message_cutin_direct');
  }

  /// 序列化为 settings.yaml 的映射（已知键 + [extra] 保留的未知键）。
  Map<String, dynamic> toMap() => <String, dynamic>{
    ...extra,
    'frame_rate': _frameRate,
    'token_acquisition_rate': _tokenAcquisitionRate,
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
  void putModel(CoreModelConfig model) => _attach(model);

  /// 放进模型池并挂上落盘回调。
  ///
  /// 回调里**延迟读** [sink]：FileSettingsSink.load 是先 putModel 再挂 sink 的，
  /// 提前捕获会让"学习 token_scale"写不回文件。
  void _attach(CoreModelConfig model) {
    model.onChanged = (CoreModelConfig changed) => sink?.saveModel(changed);
    _models[model.modelId] = model;
  }

  /// 新建模型；`model_id` 已存在时返回 null（调用方回 409）。
  CoreModelConfig? createModel(Map<String, dynamic> payload) {
    final String modelId = (payload['model_id'] as String? ?? '').trim();
    if (modelId.isEmpty || _models.containsKey(modelId)) return null;
    final CoreModelConfig model = CoreModelConfig(modelId: modelId);
    model.merge(payload);
    _attach(model);
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

  /// 推送刷新帧率夹取到 [frameRateMin, frameRateMax]。
  int setFrameRate(int value) {
    _frameRate = _clampFrameRate(value);
    sink?.saveSettings(this);
    return _frameRate;
  }

  /// token 获取帧率夹取到 [tokenRateMin, tokenRateMax]。
  int setTokenAcquisitionRate(int value) {
    _tokenAcquisitionRate = _clampTokenRate(value);
    sink?.saveSettings(this);
    return _tokenAcquisitionRate;
  }

  static int _clampFrameRate(int value) => value < frameRateMin
      ? frameRateMin
      : (value > frameRateMax ? frameRateMax : value);

  static int _clampTokenRate(int value) => value < tokenRateMin
      ? tokenRateMin
      : (value > tokenRateMax ? tokenRateMax : value);

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
