/// 站点体系的数据模型（M9 §3）：站点类型与收集站 schema。
/// 投递结果、活性探针、分类计数。
///
/// 与旧后端 server/plugin/stations.py 的对应关系：
/// - 「站 × scope 键位唯一 + 先到先得」→ StationSubResult 的拒绝 / replace 语义；
/// - 「触发-等待-回填」→ StationRequest / StationReply；
/// - 「fail-open 放行原数据 + 分类计数」→ StationCounters 与各 trigger 的返回值；
/// - 「15 计数键」→ 保留前端白名单里那 7 个，另外的用可读原因表达。
library;

/// 站点类型（**四种**；插件自建站点也只能注册这四种，不允许发明新类型）。
enum StationKind {
  /// 广播站：插件发布 topic → 多订阅者接收 + 持久公告板；需订阅。
  broadcast,

  /// 执行站：插件主动下命令，由挂载位置执行；**不订阅、不触发插件**。
  execute,

  /// 中转站：数据流拦截-回填；站 × scope 键位唯一（先到先得）。
  relay,

  /// 收集站：一对多收集 + 汇聚交触发方后续处理；不回填原数据流。
  collect;

  /// 线名（落盘 / 帧载荷用；与 Dart 枚举名一致，避免两套词表）。
  String get wire => name;

  /// 中文展示名（日志与可读错误用）。
  String get label => switch (this) {
    StationKind.broadcast => '广播站',
    StationKind.execute => '执行站',
    StationKind.relay => '中转站',
    StationKind.collect => '收集站',
  };

  /// 是否支持订阅（执行站不支持：它由插件主动下命令）。
  bool get subscribable => this != StationKind.execute;

  /// 解析线名；未知返回 null（fail-closed，不猜）。
  static StationKind? fromWire(Object? raw) {
    final String value = (raw ?? '').toString().trim();
    for (final StationKind kind in StationKind.values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// 收集站 schema 的字段类型（够用即可，不做 JSON Schema 全集）。
abstract final class StationFieldType {
  static const String string = 'string';
  static const String number = 'number';
  static const String boolean = 'boolean';
  static const String object = 'object';
  static const String array = 'array';

  /// 合法类型集合。
  static const Set<String> all = <String>{
    string,
    number,
    boolean,
    object,
    array,
  };
}

/// 收集站 schema 的一个字段。
class StationSchemaField {
  const StationSchemaField({
    required this.name,
    this.type = StationFieldType.string,
    this.required = false,
    this.description = '',
    this.fields = const <StationSchemaField>[],
  });

  /// 字段名。
  final String name;

  /// 字段类型（见 StationFieldType）。
  final String type;

  /// 是否必填。
  final bool required;

  /// 字段说明（会随请求一起发给订阅者，让插件知道该产出什么）。
  final String description;

  /// 子字段（type == object 时生效）。
  final List<StationSchemaField> fields;

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'type': type,
    if (required) 'required': true,
    if (description.isNotEmpty) 'description': description,
    if (fields.isNotEmpty)
      'fields': fields.map((StationSchemaField f) => f.toJson()).toList(),
  };

  /// 宽容解析；字段名非法 / 类型未知返回 null（跳过该字段而不是整站失败）。
  static StationSchemaField? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final String name = (raw['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    final String type = (raw['type'] ?? StationFieldType.string)
        .toString()
        .trim();
    if (!StationFieldType.all.contains(type)) return null;
    final Object? rawFields = raw['fields'];
    final List<StationSchemaField> fields = <StationSchemaField>[];
    if (rawFields is List) {
      for (final Object? item in rawFields) {
        final StationSchemaField? field = tryParse(item);
        if (field != null) fields.add(field);
      }
    }
    return StationSchemaField(
      name: name,
      type: type,
      required: raw['required'] == true,
      description: (raw['description'] ?? '').toString(),
      fields: fields,
    );
  }
}

/// 收集站 schema（**站点定义输入格式**，订阅者必须按它产出）。
///
/// 形状（落盘 yaml / 帧载荷同一形状，人可直接读）：
///
///   kind: object
///   description: 插件工具定义
///   fields:
///     - {name: tool_name, type: string, required: true, description: ...}
///     - {name: description, type: string, required: true}
///     - {name: parameters, type: object, required: true}
///     - {name: execution, type: object, fields: [...]}
class StationSchema {
  const StationSchema({
    required this.description,
    required this.fields,
    this.allowExtra = false,
  });

  /// schema 根类型（当前只支持 object：收集站收的是「一条结构化产出」）。
  static const String rootKind = 'object';

  /// schema 说明（会随采集请求发给订阅者）。
  final String description;

  /// 字段定义（顺序即呈现顺序）。
  final List<StationSchemaField> fields;

  /// 是否允许 schema 未声明的字段（默认 false = 严格，产出多一个字段即报错）。
  final bool allowExtra;

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': rootKind,
    'description': description,
    if (allowExtra) 'allow_extra': true,
    'fields': fields.map((StationSchemaField f) => f.toJson()).toList(),
  };

  /// 解析（缺字段按空 schema 处理；由调用方决定「收集站必须有 schema」）。
  static StationSchema fromJson(Object? raw) {
    if (raw is! Map) {
      return const StationSchema(
        description: '',
        fields: <StationSchemaField>[],
      );
    }
    final List<StationSchemaField> fields = <StationSchemaField>[];
    final Object? rawFields = raw['fields'];
    if (rawFields is List) {
      for (final Object? item in rawFields) {
        final StationSchemaField? field = StationSchemaField.tryParse(item);
        if (field != null) fields.add(field);
      }
    }
    return StationSchema(
      description: (raw['description'] ?? '').toString(),
      fields: fields,
      allowExtra: raw['allow_extra'] == true,
    );
  }

  /// 校验订阅者产出：通过返回 null，否则返回**可读中文错误**（回报该订阅者）。
  String? validate(Object? data) {
    if (data is! Map) {
      final String actual = data == null ? 'null' : data.runtimeType.toString();
      return '产出必须是对象（键值映射），实际是 $actual';
    }
    return _validateFields(
      where: '根',
      value: data,
      fields: fields,
      allowExtra: allowExtra,
    );
  }

  static String? _validateFields({
    required String where,
    required Map<dynamic, dynamic> value,
    required List<StationSchemaField> fields,
    required bool allowExtra,
  }) {
    for (final StationSchemaField field in fields) {
      final bool present = value.containsKey(field.name);
      final Object? item = value[field.name];
      if (!present || item == null) {
        if (field.required) return '$where 缺少必填字段 ${field.name}';
        continue;
      }
      final String? typeError = _validateType(field, item, where);
      if (typeError != null) return typeError;
    }
    if (!allowExtra) {
      final Set<String> declared = fields
          .map((StationSchemaField f) => f.name)
          .toSet();
      for (final Object? key in value.keys) {
        final String name = '$key';
        if (!declared.contains(name)) {
          final String allowed = declared.isEmpty ? '无' : declared.join('、');
          return '$where 出现 schema 未声明的字段 $name（允许的字段：$allowed）';
        }
      }
    }
    return null;
  }

  static String? _validateType(
    StationSchemaField field,
    Object? item,
    String where,
  ) {
    final String path = '$where.${field.name}';
    switch (field.type) {
      case StationFieldType.string:
        return item is String
            ? null
            : '$path 应为 string，实际是 ${item.runtimeType}';
      case StationFieldType.number:
        return item is num ? null : '$path 应为 number，实际是 ${item.runtimeType}';
      case StationFieldType.boolean:
        return item is bool ? null : '$path 应为 boolean，实际是 ${item.runtimeType}';
      case StationFieldType.array:
        if (item is! List) return '$path 应为 array，实际是 ${item.runtimeType}';
        if (field.fields.isEmpty) return null;
        // 数组元素的 schema：fields 描述「每一项」的形状（工具定义清单这类列表用）
        for (int index = 0; index < item.length; index++) {
          final Object? element = item[index];
          if (element is! Map) {
            return '$path[$index] 应为 object，实际是 ${element.runtimeType}';
          }
          final String? error = _validateFields(
            where: '$path[$index]',
            value: element,
            fields: field.fields,
            allowExtra: true,
          );
          if (error != null) return error;
        }
        return null;
      case StationFieldType.object:
        if (item is! Map) return '$path 应为 object，实际是 ${item.runtimeType}';
        if (field.fields.isEmpty) return null;
        return _validateFields(
          where: path,
          value: item,
          fields: field.fields,
          allowExtra: true,
        );
      default:
        return '$path 的类型 ${field.type} 未支持';
    }
  }

  /// 字段名清单（可读错误 / 报文自描述用）。
  List<String> get fieldNames =>
      fields.map((StationSchemaField f) => f.name).toList(growable: false);
}
