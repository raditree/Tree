/// 插件依赖（`requires.plugins`）与版本区间的纯计算（片 D）。
///
/// 这里只放**不碰进程 / 不碰磁盘**的解析与判定：
/// - 依赖清单的形状校验（与 `plugins.yaml`、发布索引共用同一套）；
/// - 语义版本的比较与区间（`>=1.0 <2.0`）求交；
/// - 「启用前依赖闸门」的判定结果（缺失 / 版本不符 / 区间无交集 / 成环）。
///
/// 依赖的安装与停用由总线 / 核心服务层完成，本文件不产生副作用。
library;

/// 一条依赖声明（`requires.plugins[]`）。
class PluginDependency {
  const PluginDependency({
    required this.id,
    this.version = '',
    this.optional = false,
  });

  /// 依赖的插件 id。
  final String id;

  /// 版本区间（空串 = 任意版本）。
  final String version;

  /// 可选依赖：不满足时**不阻止启用**。
  final bool optional;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    if (version.isNotEmpty) 'version': version,
    if (optional) 'optional': true,
  };
}

/// `requires.plugins` 的解析结果（形状错误只回可读原因，不抛）。
class PluginDependencyParseResult {
  const PluginDependencyParseResult({
    this.dependencies = const <PluginDependency>[],
    this.error,
  });

  final List<PluginDependency> dependencies;
  final String? error;
}

final RegExp _pluginIdPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$');

/// 解析 `requires: {plugins: [{id, version?, optional?}]}`。
///
/// [raw] 允许为 null（= 没有依赖）。形状不对、id 非法、版本区间不可解析都回可读
/// 原因——调用方（配置存储 / 发布索引）据此拒绝整条清单，而不是「看起来成功」。
PluginDependencyParseResult parsePluginDependencies(Object? raw) {
  if (raw == null) return const PluginDependencyParseResult();
  if (raw is! Map) {
    return const PluginDependencyParseResult(
      error: 'requires 必须是对象（形如 {plugins: [...]}）',
    );
  }
  final Object? plugins = raw['plugins'];
  if (plugins == null) return const PluginDependencyParseResult();
  if (plugins is! List) {
    return const PluginDependencyParseResult(
      error: 'requires.plugins 必须是数组',
    );
  }
  final List<PluginDependency> dependencies = <PluginDependency>[];
  for (int i = 0; i < plugins.length; i++) {
    final Object? item = plugins[i];
    if (item is! Map) {
      return PluginDependencyParseResult(
        error: 'requires.plugins[$i] 必须是对象（{id, version?, optional?}）',
      );
    }
    final String id = (item['id'] ?? '').toString().trim();
    if (id.isEmpty) {
      return PluginDependencyParseResult(
        error: 'requires.plugins[$i] 缺 id',
      );
    }
    if (id == '.' || id == '..' || !_pluginIdPattern.hasMatch(id)) {
      return PluginDependencyParseResult(
        error: 'requires.plugins[$i] 的 id 只允许字母、数字、下划线、点和连字符：$id',
      );
    }
    final Object? rawVersion = item['version'];
    final String version = rawVersion == null ? '' : rawVersion.toString().trim();
    if (version.isNotEmpty && PluginVersionConstraint.tryParse(version) == null) {
      return PluginDependencyParseResult(
        error: 'requires.plugins[$i]（$id）的 version 区间不可解析：$version',
      );
    }
    final Object? rawOptional = item['optional'];
    if (rawOptional != null && rawOptional is! bool) {
      return PluginDependencyParseResult(
        error: 'requires.plugins[$i]（$id）的 optional 必须是布尔值',
      );
    }
    dependencies.add(
      PluginDependency(
        id: id,
        version: version,
        optional: rawOptional == true,
      ),
    );
  }
  return PluginDependencyParseResult(dependencies: dependencies);
}

/// 语义版本（只比较数字段 + 预发布标签；build metadata 忽略）。
class SemanticVersion implements Comparable<SemanticVersion> {
  const SemanticVersion._(
    this.major,
    this.minor,
    this.patch,
    this.prerelease,
  );

  final int major;
  final int minor;
  final int patch;

  /// 预发布标识（`1.0.0-beta.2` 的 `beta.2`）；空 = 正式版。
  final List<String> prerelease;

  /// 解析语义版本：允许 `v` 前缀、1~3 段数字、可选 `-prerelease`、可选 `+build`。
  static SemanticVersion? tryParse(String raw) {
    String text = raw.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1).trim();
    }
    // build metadata 不参与比较
    final int plus = text.indexOf('+');
    if (plus >= 0) text = text.substring(0, plus);
    final List<String> pre = <String>[];
    final int dash = text.indexOf('-');
    if (dash >= 0) {
      pre.addAll(
        text
            .substring(dash + 1)
            .split('.')
            .where((String part) => part.isNotEmpty),
      );
      text = text.substring(0, dash);
    }
    final List<String> parts = text.split('.');
    if (parts.length > 3 || parts.isEmpty) return null;
    final List<int> numbers = <int>[0, 0, 0];
    for (int i = 0; i < parts.length; i++) {
      final String part = parts[i].trim();
      if (part.isEmpty || !RegExp(r'^\d+$').hasMatch(part)) return null;
      final int? number = int.tryParse(part);
      if (number == null || number < 0) return null;
      numbers[i] = number;
    }
    return SemanticVersion._(numbers[0], numbers[1], numbers[2], pre);
  }

  @override
  int compareTo(SemanticVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    // 语义版本：有预发布标签的**小于**同版本的正式版。
    if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
    if (prerelease.isEmpty) return 1;
    if (other.prerelease.isEmpty) return -1;
    final int length = prerelease.length < other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (int i = 0; i < length; i++) {
      final String a = prerelease[i];
      final String b = other.prerelease[i];
      final int aNum = int.tryParse(a) ?? -1;
      final int bNum = int.tryParse(b) ?? -1;
      if (aNum >= 0 && bNum >= 0) {
        if (aNum != bNum) return aNum.compareTo(bNum);
      } else if (a != b) {
        return a.compareTo(b);
      }
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }

  @override
  String toString() => '$major.$minor.$patch'
      '${prerelease.isEmpty ? '' : '-${prerelease.join('.')}'}';
}

/// 一个连续的版本区间（下界 / 上界，含边界标记）。
class VersionRange {
  const VersionRange({
    this.lower,
    this.lowerInclusive = true,
    this.upper,
    this.upperInclusive = false,
  });

  static const VersionRange any = VersionRange();

  final SemanticVersion? lower;
  final bool lowerInclusive;
  final SemanticVersion? upper;
  final bool upperInclusive;

  bool get isEmpty {
    final SemanticVersion? lo = lower;
    final SemanticVersion? hi = upper;
    if (lo == null || hi == null) return false;
    final int cmp = lo.compareTo(hi);
    if (cmp > 0) return true;
    if (cmp == 0) return !(lowerInclusive && upperInclusive);
    return false;
  }

  bool contains(SemanticVersion version) {
    final SemanticVersion? lo = lower;
    if (lo != null) {
      final int cmp = version.compareTo(lo);
      if (cmp < 0 || (cmp == 0 && !lowerInclusive)) return false;
    }
    final SemanticVersion? hi = upper;
    if (hi != null) {
      final int cmp = version.compareTo(hi);
      if (cmp > 0 || (cmp == 0 && !upperInclusive)) return false;
    }
    return true;
  }

  /// 求交集；无交集时返回 [isEmpty] 为真的区间（调用方据此判失败）。
  VersionRange intersect(VersionRange other) {
    SemanticVersion? lo = lower;
    bool loInclusive = lowerInclusive;
    final SemanticVersion? otherLo = other.lower;
    if (otherLo != null) {
      if (lo == null) {
        lo = otherLo;
        loInclusive = other.lowerInclusive;
      } else {
        final int cmp = otherLo.compareTo(lo);
        if (cmp > 0) {
          lo = otherLo;
          loInclusive = other.lowerInclusive;
        } else if (cmp == 0) {
          loInclusive = loInclusive && other.lowerInclusive;
        }
      }
    }
    SemanticVersion? hi = upper;
    bool hiInclusive = upperInclusive;
    final SemanticVersion? otherHi = other.upper;
    if (otherHi != null) {
      if (hi == null) {
        hi = otherHi;
        hiInclusive = other.upperInclusive;
      } else {
        final int cmp = otherHi.compareTo(hi);
        if (cmp < 0) {
          hi = otherHi;
          hiInclusive = other.upperInclusive;
        } else if (cmp == 0) {
          hiInclusive = hiInclusive && other.upperInclusive;
        }
      }
    }
    return VersionRange(
      lower: lo,
      lowerInclusive: loInclusive,
      upper: hi,
      upperInclusive: hiInclusive,
    );
  }

  String describe() {
    if (lower == null && upper == null) return '任意版本';
    final List<String> parts = <String>[];
    if (lower != null) parts.add('${lowerInclusive ? '>=' : '>'}${lower!}');
    if (upper != null) parts.add('${upperInclusive ? '<=' : '<'}${upper!}');
    return parts.join(' ');
  }
}

/// 版本约束（由 `[>=1.0, <2.0]`、`^1.2`、`~1.2` 等拼成）。
class PluginVersionConstraint {
  const PluginVersionConstraint._(this.raw, this.range);

  final String raw;
  final VersionRange range;

  bool get isAny => range.lower == null && range.upper == null;

  bool satisfies(String version) {
    final SemanticVersion? parsed = SemanticVersion.tryParse(version);
    if (parsed == null) return isAny;
    return range.contains(parsed);
  }

  PluginVersionConstraint intersect(PluginVersionConstraint other) =>
      PluginVersionConstraint._(
        '$raw ${other.raw}'.trim(),
        range.intersect(other.range),
      );

  /// 解析约束；空串 = 任意版本。
  static PluginVersionConstraint? tryParse(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return const PluginVersionConstraint._('', VersionRange.any);
    // 支持逗号分隔；`1.0.0` 是精确版本。
    final List<String> tokens = text
        .split(RegExp(r'[,\s]+'))
        .where((String token) => token.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) {
      return const PluginVersionConstraint._('', VersionRange.any);
    }
    VersionRange range = VersionRange.any;
    for (final String token in tokens) {
      final VersionRange? piece = _parseToken(token);
      if (piece == null) return null;
      range = range.intersect(piece);
      if (range.isEmpty) return null;
    }
    return PluginVersionConstraint._(text, range);
  }

  static VersionRange? _parseToken(String token) {
    final String lower = token.toLowerCase();
    if (lower.startsWith('^') || lower.startsWith('~')) {
      final SemanticVersion? base = SemanticVersion.tryParse(
        token.substring(1),
      );
      if (base == null) return null;
      final SemanticVersion upper;
      if (lower.startsWith('~')) {
        upper = SemanticVersion._(base.major, base.minor + 1, 0, const []);
      } else if (base.major > 0) {
        upper = SemanticVersion._(base.major + 1, 0, 0, const []);
      } else if (base.minor > 0) {
        upper = SemanticVersion._(0, base.minor + 1, 0, const []);
      } else {
        upper = SemanticVersion._(0, 0, base.patch + 1, const []);
      }
      return VersionRange(lower: base, upper: upper);
    }
    final RegExpMatch? cmp = RegExp(r'^(>=|<=|>|<|=)?(.+)$').firstMatch(token);
    if (cmp == null) return null;
    final SemanticVersion? version = SemanticVersion.tryParse(cmp.group(2)!);
    if (version == null) return null;
    return switch (cmp.group(1) ?? '') {
      '>=' => VersionRange(lower: version),
      '>' => VersionRange(lower: version, lowerInclusive: false),
      '<=' => VersionRange(upper: version, upperInclusive: true),
      '<' => VersionRange(upper: version),
      _ => VersionRange(lower: version, upper: version, upperInclusive: true),
    };
  }
}

/// 参与依赖判定的插件输入（由 `PluginConfig` / 发布索引条目投影而来）。
class PluginDependencyInput {
  const PluginDependencyInput({
    required this.id,
    this.version = '',
    this.dependencies = const <PluginDependency>[],
    this.enabled = true,
  });

  final String id;
  final String version;
  final List<PluginDependency> dependencies;
  final bool enabled;
}

/// 一条未满足的依赖（缺失 / 版本不符 / 区间无交集）。
class PluginDependencyIssue {
  const PluginDependencyIssue({
    required this.id,
    required this.required,
    required this.installed,
    required this.actual,
    required this.by,
    required this.reason,
    this.optional = false,
  });

  final String id;

  /// 依赖方要求的版本区间（多方要求时用 `；` 连接）。
  final String required;

  /// 是否**已安装**（true = 装了但版本不符；false = 缺失）。
  final bool installed;

  /// 已安装版本（未安装 = 空串）。
  final String actual;

  /// 谁要求它。
  final List<String> by;

  final String reason;
  final bool optional;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'required': required,
    'installed': installed,
    'actual': actual,
    'by': by,
    'optional': optional,
    'reason': reason,
  };
}

/// 依赖闸门结果。
class PluginDependencyReport {
  const PluginDependencyReport({
    this.error,
    this.reasons = const <String>[],
    this.issues = const <PluginDependencyIssue>[],
  });

  const PluginDependencyReport.ok()
    : error = null,
      reasons = const <String>[],
      issues = const <PluginDependencyIssue>[];

  final String? error;
  final List<String> reasons;
  final List<PluginDependencyIssue> issues;

  bool get ok => error == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ok': false,
    'error': error ?? '',
    'reasons': reasons,
    'missing_dependencies': issues
        .map((PluginDependencyIssue issue) => issue.toJson())
        .toList(growable: false),
  };
}

/// 启用前依赖闸门：只判目标插件的**非可选**依赖闭包。
///
/// - 缺失 / 已安装版本不符 ⇒ issue；
/// - 同一 id 被多个插件要求 ⇒ 取区间交集，空交集 ⇒ 可读失败并逐条列出要求方
///   （不擅自择一）；
/// - 依赖成环 ⇒ 可读失败并给出环路。
PluginDependencyReport evaluatePluginDependencies({
  required PluginDependencyInput target,
  required Iterable<PluginDependencyInput> installed,
}) {
  final Map<String, PluginDependencyInput> byId =
      <String, PluginDependencyInput>{
        for (final PluginDependencyInput input in installed) input.id: input,
      };
  byId[target.id] = target;

  final List<String> cycle = _findCycle(target.id, byId);
  if (cycle.isNotEmpty) {
    final String path = cycle.join(' → ');
    final String reason = '依赖成环：$path';
    return PluginDependencyReport(
      error: '插件 ${target.id} 的依赖无法满足：$reason',
      reasons: <String>[reason],
    );
  }

  final Map<String, PluginDependencyIssue> issues =
      <String, PluginDependencyIssue>{};
  final List<String> reasons = <String>[];
  final Set<String> visited = <String>{target.id};
  final List<String> queue = <String>[target.id];
  while (queue.isNotEmpty) {
    final String currentId = queue.removeAt(0);
    final PluginDependencyInput? current = byId[currentId];
    if (current == null) continue;
    for (final PluginDependency dependency in current.dependencies) {
      if (dependency.optional) continue;
      // 取所有启用插件对同一 id 的要求（发布中的目标也在内）：D-10 的口径是
      // 「不得擅自择一」，所以冲突必须在这里显形。
      final List<PluginDependencyInput> requesters = <PluginDependencyInput>[
        for (final PluginDependencyInput input in byId.values)
          if (input.enabled &&
              input.dependencies.any(
                (PluginDependency d) => d.id == dependency.id && !d.optional,
              ))
            input,
      ];
      if (!requesters.any((PluginDependencyInput input) => input.id == target.id)) {
        requesters.add(target);
      }
      final List<PluginDependency> requirements = <PluginDependency>[
        for (final PluginDependencyInput input in requesters)
          ...input.dependencies.where(
            (PluginDependency d) => d.id == dependency.id && !d.optional,
          ),
      ];
      final List<String> by = <String>[
        for (final PluginDependencyInput input in requesters) input.id,
      ];
      final String requiredText = requirements
          .map(
            (PluginDependency d) =>
                '${d.id}：${d.version.isEmpty ? '任意版本' : d.version}',
          )
          .join('；');
      PluginVersionConstraint? intersection;
      for (final PluginDependency requirement in requirements) {
        final PluginVersionConstraint? one =
            PluginVersionConstraint.tryParse(requirement.version);
        if (one == null) {
          final String reason =
              '依赖 ${dependency.id} 的版本区间不可解析：${requirement.version}';
          reasons.add(reason);
          issues[dependency.id] = PluginDependencyIssue(
            id: dependency.id,
            required: requiredText,
            installed: byId.containsKey(dependency.id),
            actual: byId[dependency.id]?.version ?? '',
            by: by,
            reason: reason,
          );
          break;
        }
        intersection = intersection == null ? one : intersection.intersect(one);
        if (intersection.range.isEmpty) {
          final String reason =
              '依赖 ${dependency.id} 的版本区间无交集：$requiredText';
          reasons.add(reason);
          issues[dependency.id] = PluginDependencyIssue(
            id: dependency.id,
            required: requiredText,
            installed: byId.containsKey(dependency.id),
            actual: byId[dependency.id]?.version ?? '',
            by: by,
            reason: reason,
          );
          break;
        }
      }
      if (issues.containsKey(dependency.id)) continue;
      final PluginDependencyInput? actual = byId[dependency.id];
      if (actual == null) {
        final String reason = dependency.version.isEmpty
            ? '缺少依赖 ${dependency.id}（由 ${by.join(' / ')} 要求）'
            : '缺少依赖 ${dependency.id}（需要 ${dependency.version}，'
                  '由 ${by.join(' / ')} 要求）';
        reasons.add(reason);
        issues[dependency.id] = PluginDependencyIssue(
          id: dependency.id,
          required: requiredText,
          installed: false,
          actual: '',
          by: by,
          reason: reason,
        );
        continue;
      }
      final String version = actual.version.trim();
      if (version.isEmpty && intersection != null && !intersection.isAny) {
        final String reason =
            '依赖 ${dependency.id} 未记录版本，无法确认满足 ${intersection.raw}'
            '（由 ${by.join(' / ')} 要求）';
        reasons.add(reason);
        issues[dependency.id] = PluginDependencyIssue(
          id: dependency.id,
          required: requiredText,
          installed: true,
          actual: '',
          by: by,
          reason: reason,
        );
        continue;
      }
      if (intersection != null &&
          !intersection.isAny &&
          !intersection.satisfies(version)) {
        final String reason =
            '依赖 ${dependency.id} 已安装版本 $version 不满足 '
            '${intersection.raw}（由 ${by.join(' / ')} 要求）';
        reasons.add(reason);
        issues[dependency.id] = PluginDependencyIssue(
          id: dependency.id,
          required: requiredText,
          installed: true,
          actual: version,
          by: by,
          reason: reason,
        );
        continue;
      }
      if (visited.add(dependency.id)) queue.add(dependency.id);
    }
  }

  if (issues.isEmpty) return const PluginDependencyReport.ok();
  return PluginDependencyReport(
    error: '插件 ${target.id} 的依赖未满足：${reasons.join('；')}',
    reasons: reasons,
    issues: issues.values.toList(growable: false),
  );
}

/// 沿非可选依赖边找环；返回环上的 id（按路径顺序，首尾重复）。
List<String> _findCycle(
  String startId,
  Map<String, PluginDependencyInput> byId,
) {
  final List<String> stack = <String>[];
  final Set<String> inStack = <String>{};

  List<String>? walk(String id) {
    final PluginDependencyInput? input = byId[id];
    if (input == null) return null;
    stack.add(id);
    inStack.add(id);
    for (final PluginDependency dependency in input.dependencies) {
      if (dependency.optional) continue;
      if (!byId.containsKey(dependency.id)) continue;
      if (inStack.contains(dependency.id)) {
        final int index = stack.indexOf(dependency.id);
        return <String>[...stack.sublist(index), dependency.id];
      }
      final List<String>? found = walk(dependency.id);
      if (found != null) return found;
    }
    stack.removeLast();
    inStack.remove(id);
    return null;
  }

  return walk(startId) ?? const <String>[];
}
