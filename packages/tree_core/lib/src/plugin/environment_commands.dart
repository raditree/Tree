import 'dart:io';

import 'package:tree_local_exec/tree_local_exec.dart';

/// 取当前环境（登录口径）的实现入口；默认 = [cachedLoginEnvironment]。
typedef EnvironmentLoad =
    Future<Map<String, String>> Function(void Function(String message)? log);

/// **主动重读**环境的实现入口；默认 = [refreshLoginEnvironment]。
typedef EnvironmentReload =
    Future<Map<String, String>> Function(void Function(String message)? log);

/// 最近一次环境的同步快照（= 刷新前的比较基线）；默认 = [loginEnvironmentSnapshot]。
typedef EnvironmentSnapshot = Map<String, String>? Function();

/// 执行站 `env.*` 族（机器级环境变量）。
///
/// 为什么这族留在核心（A5 之后核心不再实现任何领域执行语义）：
/// 环境变量是**操作系统事实**，不是某个领域（文件 / 终端 / 模型）的能力；它也没有
/// 「挂在哪个 agent 的工作空间上」这层身份。核心是唯一同时知道「按登录口径重建」
/// 规则（[loginEnvironment]）与「什么时候该重读」的地方，插件（如 `local_executor`）
/// 需要一份**新**环境时只能来问这里，而不是各自去 `reg.exe` 一遍。
///
/// 两条命令：
/// - `env.get`：读当前缓存（没算过就算一次）；可带 `names` 只取指定的几个变量；
/// - `env.refresh`：重新读注册表并替换缓存；回「刷新前后差异」，`include_env: true`
///   时才把整份环境带回去（默认不带：`PATH` 之外的东西多数时候只为排障）。
///
/// 归属闸门：本族**不要求 team**——环境是整机一份，团队归属在这里没有对应的资源，
/// 要一个团队 id 只会变成假 rigor。命令白名单（点位表）与插件身份校验仍照旧。
class EnvironmentCommands {
  EnvironmentCommands({
    this.load,
    this.reload,
    this.snapshot,
    this.log,
  });

  /// 命令名前缀（与 `ExecuteStationMounts.implementedPrefixes` 同一口径）。
  static const String prefix = 'env.';

  /// 本族命令（点位表与测试都读它，别在别处另抄一份）。
  static const List<String> commands = <String>['env.get', 'env.refresh'];

  /// null = 默认 [cachedLoginEnvironment]（测试注入假实现）。
  final EnvironmentLoad? load;

  /// null = 默认 [refreshLoginEnvironment]（测试注入假实现）。
  final EnvironmentReload? reload;

  /// null = 默认 [loginEnvironmentSnapshot]（测试注入假实现）。
  final EnvironmentSnapshot? snapshot;

  final void Function(String message)? log;

  /// 这条命令是不是本族实现的（挂载位置复核用）。
  static bool handles(String command) => commands.contains(command);

  /// 分发一条 `env.*` 命令；回包口径与其它族一致：`{ok: true, …}` 或
  /// `{ok: false, error: 可读中文}`。
  Future<Map<String, dynamic>> handle({
    required String command,
    Map<String, dynamic>? arguments,
    String sourcePluginId = '',
  }) async {
    final Map<String, dynamic> args = arguments ?? const <String, dynamic>{};
    switch (command) {
      case 'env.get':
        return _get(args);
      case 'env.refresh':
        return _refresh(args);
    }
    return <String, dynamic>{
      'ok': false,
      'error':
          '命令 $command 不属于环境族（允许：${commands.join('、')}）；'
          '要读环境请用 env.get，要重读注册表请用 env.refresh',
    };
  }

  Future<Map<String, dynamic>> _get(Map<String, dynamic> arguments) async {
    final List<String>? names = _namesOf(arguments['names']);
    if (names == null) {
      return const <String, dynamic>{
        'ok': false,
        'error': 'env.get 的 names 必须是字符串数组（不传 = 取整份环境）',
      };
    }
    final Map<String, String> env = await (load ?? _defaultLoad)(log);
    if (names.isEmpty) {
      return <String, dynamic>{
        'ok': true,
        'count': env.length,
        'env': env,
      };
    }
    final Map<String, String> picked = <String, String>{};
    final List<String> missing = <String>[];
    for (final String name in names) {
      final MapEntry<String, String>? found = _find(env, name);
      if (found == null) {
        missing.add(name);
      } else {
        picked[found.key] = found.value;
      }
    }
    return <String, dynamic>{
      'ok': true,
      'count': picked.length,
      'env': picked,
      'missing': missing,
    };
  }

  Future<Map<String, dynamic>> _refresh(Map<String, dynamic> arguments) async {
    final Map<String, String>? before = (snapshot ?? loginEnvironmentSnapshot)();
    final Map<String, String> env = await (reload ?? _defaultReload)(log);
    // 还没算过缓存时拿进程环境当基线：它才是"插件进程此刻拿到的默认值"，
    // 与空缓存比会把整份环境都报成 added（那等于没说）。
    final ({List<String> changed, List<String> added, List<String> removed})
    diff = _diff(before ?? Platform.environment, env);
    final bool includeEnv = arguments['include_env'] == true;
    return <String, dynamic>{
      'ok': true,
      'count': env.length,
      'refreshed_at': DateTime.now().toIso8601String(),
      'baseline': before == null ? 'process' : 'cache',
      'changed': diff.changed,
      'added': diff.added,
      'removed': diff.removed,
      if (includeEnv) 'env': env,
    };
  }

  Future<Map<String, String>> _defaultLoad(
    void Function(String message)? log,
  ) => cachedLoginEnvironment(log: log);

  Future<Map<String, String>> _defaultReload(
    void Function(String message)? log,
  ) => refreshLoginEnvironment(log: log);

  /// `names` 解析：null = 入参非法；空列表 = 没指定（取整份）。
  static List<String>? _namesOf(Object? raw) {
    if (raw == null) return const <String>[];
    if (raw is! List) return null;
    final List<String> out = <String>[];
    for (final Object? value in raw) {
      if (value is! String || value.trim().isEmpty) return null;
      out.add(value.trim());
    }
    return out;
  }

  /// 大小写不敏感地找一条（Windows 环境变量名不区分大小写）。
  static MapEntry<String, String>? _find(
    Map<String, String> env,
    String name,
  ) {
    for (final MapEntry<String, String> entry in env.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return entry;
    }
    return null;
  }

  /// 刷新前后差异（名字按 Windows 口径大小写不敏感比较；输出排序保证可断言）。
  static ({List<String> changed, List<String> added, List<String> removed})
  _diff(Map<String, String> before, Map<String, String> after) {
    final Map<String, MapEntry<String, String>> beforeByKey =
        <String, MapEntry<String, String>>{
          for (final MapEntry<String, String> entry in before.entries)
            entry.key.toLowerCase(): entry,
        };
    final Map<String, MapEntry<String, String>> afterByKey =
        <String, MapEntry<String, String>>{
          for (final MapEntry<String, String> entry in after.entries)
            entry.key.toLowerCase(): entry,
        };
    final List<String> changed = <String>[];
    final List<String> added = <String>[];
    final List<String> removed = <String>[];
    for (final MapEntry<String, MapEntry<String, String>> entry
        in afterByKey.entries) {
      final MapEntry<String, String>? old = beforeByKey[entry.key];
      if (old == null) {
        added.add(entry.value.key);
      } else if (old.value != entry.value.value) {
        changed.add(entry.value.key);
      }
    }
    for (final MapEntry<String, MapEntry<String, String>> entry
        in beforeByKey.entries) {
      if (!afterByKey.containsKey(entry.key)) removed.add(entry.value.key);
    }
    changed.sort();
    added.sort();
    removed.sort();
    return (changed: changed, added: added, removed: removed);
  }
}
