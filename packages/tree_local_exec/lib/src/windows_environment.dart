/// Windows 上"按**登录口径**重建环境变量"（用户自己的终端就是这么来的）。
///
/// **为什么要重建**（用户 2026-10-03：「Tree 的 terminal 和我（用户）直接在本机使用的 terminal
/// 在行为上有分歧」）：core 进程是"被谁拉起来就继承谁的环境"，而 Tree 的终端与工具命令全都
/// 继承 core 的那一份 —— 于是与用户自己的终端对不上：
///
/// - **少**了用户在系统里配的 PATH 项（本机实测少了 `C:\Program Files\GitHub CLI\`，
///   于是 agent 的 shell 里 `gh` 不见了）；
/// - **多**出启动方注入的项（本机实测多了
///   `C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__8wekyb3d8bbwe`，
///   而 `Shell.windowsShell` 是"PATH 上第一个 `pwsh.exe`"，于是 shell 被选成了 **MSIX 打包版**
///   PowerShell —— 打包应用在 Windows 11 上默认带 Redirection Trust 之类的缓解，
///   与"原生终端"的行为并不同口径，见 `docs/known-issues.md` #16）。
///
/// 用户自己的终端拿的是**登录时的环境**：机器级
/// `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment` + 用户级
/// `HKCU\Environment`，其中 `Path` 按"机器级在前、用户级在后"拼接，其余同名变量**用户级覆盖机器级**。
/// 本文件就按这个口径重建。
///
/// **合并规则**（默认口径）：
/// 1. 注册表里**定义了的**键以注册表为准（`Path` 特殊：机器级 + `;` + 用户级）；
/// 2. 注册表里**没有的**、继承来的变量**原样保留**（运行环境注入的 `TREE_*` / 工具链条目不该被抹掉）；
/// 3. `REG_EXPAND_SZ` 的值做 `%NAME%` 展开（用**合成后**的表，最多两轮，防变量环）；
/// 4. **任何一步失败都整体退回继承值**（宁可维持现状，也不静默换一套环境），并把原因交给 [log]。
///
/// 纯函数（[parseRegQueryEnv] / [composeLoginEnvironment]）与"取真值"（[loginEnvironment]）分开，
/// 前者单测直接钉住；`reg.exe` 的调用可注入（[RegQuery]），所以不需要真注册表也能测全。
library;

import 'dart:io';

/// 一条注册表环境值：值本体 + 是不是 `REG_EXPAND_SZ`（需要展开 `%NAME%`）。不可变值对象。
class RegEnvValue {
  const RegEnvValue(this.value, {this.expand = false});

  /// 值本体（未展开）。
  final String value;

  /// `REG_EXPAND_SZ` ⇒ 值是模板，里面的 `%NAME%` 要按合成后的环境展开。
  final bool expand;

  @override
  bool operator ==(Object other) =>
      other is RegEnvValue && other.value == value && other.expand == expand;

  @override
  int get hashCode => Object.hash(value, expand);

  @override
  String toString() =>
      'RegEnvValue(${expand ? 'expand:' : ''}"$value")';
}

/// `HKCU\Environment`（用户级）。
const String kUserEnvironmentKey = r'HKCU\Environment';

/// 机器级环境变量所在键。
const String kMachineEnvironmentKey =
    r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

/// 注册表 `Path` 的键名（进程里通常写成 `PATH`；Windows 环境变量名不区分大小写）。
const String kPathValueName = 'Path';

/// `reg.exe query <key> /v *` 的输出里，一行形如：
///
/// ```text
/// HKEY_CURRENT_USER\Environment
///     Path    REG_EXPAND_SZ    C:\Users\me\bin;%USERPROFILE%\go\bin
///     TEMP    REG_SZ
/// ```
///
/// 名字与类型、类型与数据之间固定四个空格（数据里可以有任意空格，**空值的行没有第三段**）。
/// 这里只认这一种形状，认不出的行直接跳过（注册表工具加噪声不该把整套环境掀掉）。
final RegExp _regLine = RegExp(r'^\s{4}(\S.*?)\s{4}(REG_[A-Z_]+)(?:\s{4}(.*))?$');

/// 纯函数：解析 `reg.exe query` 的输出为变量表（键名保持原样，比较时大小写不敏感）。
Map<String, RegEnvValue> parseRegQueryEnv(String stdout) {
  final Map<String, RegEnvValue> out = <String, RegEnvValue>{};
  for (final String rawLine in stdout.split(RegExp(r'\r?\n'))) {
    final RegExpMatch? match = _regLine.firstMatch(rawLine);
    if (match == null) continue;
    final String name = match.group(1)!.trim();
    if (name.isEmpty) continue;
    final String type = match.group(2)!;
    out[name] = RegEnvValue(
      (match.group(3) ?? '').trim(),
      expand: type == 'REG_EXPAND_SZ',
    );
  }
  return out;
}

/// 纯函数：按登录口径合成环境（规则见库文档）。
///
/// [inherited] 是 core 进程当前的环境；注册表里没有的键从它这里原样带过。
Map<String, String> composeLoginEnvironment({
  required Map<String, RegEnvValue> machine,
  required Map<String, RegEnvValue> user,
  required Map<String, String> inherited,
}) {
  // ① 原始表：机器级打底，用户级覆盖（Path 单独拼接，见 ②）
  final Map<String, RegEnvValue> raw = <String, RegEnvValue>{};
  for (final MapEntry<String, RegEnvValue> entry in machine.entries) {
    raw[entry.key] = entry.value;
  }
  final String? pathKey = _pathKeyOf(<String>[
    ...user.keys,
    ...machine.keys,
  ]);
  for (final MapEntry<String, RegEnvValue> entry in user.entries) {
    if (pathKey != null && _sameKey(entry.key, pathKey)) continue;
    raw[entry.key] = entry.value;
  }
  if (pathKey != null) {
    final String machinePath = _valueOf(machine, pathKey)?.value.trim() ?? '';
    final String userPath = _valueOf(user, pathKey)?.value.trim() ?? '';
    final String joined = <String>[
      if (machinePath.isNotEmpty) machinePath,
      if (userPath.isNotEmpty) userPath,
    ].join(';');
    // 用户级里哪怕写着空串，也代表"用户级没加东西"：这时沿用机器级那一份。
    raw[pathKey] = RegEnvValue(joined, expand: true);
  }

  // ② 展开（用合成后的表，最多两轮：够覆盖 %SystemRoot% 套 %SystemDrive% 这类，又能防环）。
  //    **查找表要带上继承值**：注册表里不一定每条都在（例如 SystemRoot 这种"进程环境里有、
  //    注册表里可能没有"的变量），只查注册表就会留下一串没展开的 %SystemRoot% 字面量。
  final Map<String, String> lookup = <String, String>{...inherited};
  for (final MapEntry<String, RegEnvValue> entry in raw.entries) {
    final String? existing = _keyOf(lookup, entry.key);
    if (existing != null && existing != entry.key) lookup.remove(existing);
    lookup[entry.key] = entry.value.value;
  }
  final Map<String, String> expanded = Map<String, String>.of(lookup);
  for (int round = 0; round < 2; round++) {
    bool changed = false;
    for (final MapEntry<String, RegEnvValue> entry in raw.entries) {
      if (!entry.value.expand) continue;
      final String next = _expand(expanded[entry.key] ?? '', expanded);
      if (next != expanded[entry.key]) {
        expanded[entry.key] = next;
        lookup[entry.key] = next;
        changed = true;
      }
    }
    if (!changed) break;
  }

  // ③ 与继承值合并：注册表定义的键以注册表为准，没定义的保留继承值。
  //    展开后的注册表值从 `lookup` 里取（它已带上继承值，见 ②）。
  final Map<String, String> out = <String, String>{...inherited};
  for (final MapEntry<String, RegEnvValue> entry in raw.entries) {
    final String? existing = _keyOf(out, entry.key);
    if (existing != null && existing != entry.key) out.remove(existing);
    out[entry.key] = lookup[entry.key] ?? entry.value.value;
  }
  return out;
}

/// `%NAME%` 展开（大小写不敏感）；认不出的名字**原样留着**（与 Windows 行为一致）。
String _expand(String value, Map<String, String> environment) {
  if (!value.contains('%')) return value;
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < value.length) {
    final int start = value.indexOf('%', i);
    if (start < 0) {
      out.write(value.substring(i));
      break;
    }
    final int end = value.indexOf('%', start + 1);
    if (end < 0) {
      out.write(value.substring(i));
      break;
    }
    out.write(value.substring(i, start));
    final String name = value.substring(start + 1, end);
    final String? replacement = name.isEmpty ? null : _valueOfString(environment, name);
    // 空名字（%%）与认不出的名字都原样保留
    out.write(replacement ?? value.substring(start, end + 1));
    i = end + 1;
  }
  return out.toString();
}

/// 键名比较（Windows 环境变量名大小写不敏感）。
bool _sameKey(String a, String b) => a.toLowerCase() == b.toLowerCase();

String? _keyOf(Map<String, String> map, String key) {
  for (final String candidate in map.keys) {
    if (_sameKey(candidate, key)) return candidate;
  }
  return null;
}

String? _valueOfString(Map<String, String> map, String key) => map[_keyOf(map, key) ?? ''];

String? _pathKeyOf(Iterable<String> names) {
  for (final String name in names) {
    if (_sameKey(name, kPathValueName)) return name;
  }
  return null;
}

RegEnvValue? _valueOf(Map<String, RegEnvValue> map, String key) {
  for (final MapEntry<String, RegEnvValue> entry in map.entries) {
    if (_sameKey(entry.key, key)) return entry.value;
  }
  return null;
}

/// 取注册表值的方式（可注入：单测不需要真注册表）。
typedef RegQuery = Future<String?> Function(String key);

/// `reg.exe query "<key>" /v *` 的真实现。拿不到（非 Windows / 命令失败）返回 null。
Future<String?> regQueryValues(String key) async {
  if (!Platform.isWindows) return null;
  try {
    final ProcessResult result = await Process.run('reg.exe', <String>[
      'query',
      key,
      '/v',
      '*',
    ]);
    if (result.exitCode != 0) return null;
    return '${result.stdout}';
  } catch (_) {
    return null;
  }
}

/// 取一份环境：**进程内只算一次**（注册表里的登录环境在一次运行里不会变；用户改完
/// PATH 也要重开终端才生效，与 Windows 自己的口径一致）。
///
/// 失败仍按 [loginEnvironment] 的规则整体退回继承值。
Future<Map<String, String>> cachedLoginEnvironment({
  Map<String, String>? inherited,
  RegQuery? query,
  void Function(String message)? log,
}) async {
  final Map<String, String>? cached = _cached;
  if (cached != null) return cached;
  final Map<String, String> env = await loginEnvironment(
    inherited: inherited,
    query: query,
    log: log,
  );
  _cached = env;
  return env;
}

Map<String, String>? _cached;

/// 仅供测试：清掉进程内缓存（生产代码不需要——注册表环境在一次运行里当常量看）。
void resetLoginEnvironmentCache() => _cached = null;

/// 按登录口径取一份环境；**任何一步失败整体退回 [inherited]**（默认 = 当前进程环境）。
///
/// 非 Windows 直接返回继承值（POSIX 的登录环境是另一套语义，不在本文件范围）。
Future<Map<String, String>> loginEnvironment({
  Map<String, String>? inherited,
  RegQuery? query,
  void Function(String message)? log,
}) async {
  final Map<String, String> base = inherited ?? Platform.environment;
  if (!Platform.isWindows) return base;
  final RegQuery ask = query ?? regQueryValues;
  try {
    final String? machineOut = await ask(kMachineEnvironmentKey);
    final String? userOut = await ask(kUserEnvironmentKey);
    if (machineOut == null || userOut == null) {
      log?.call(
        '按登录口径重建环境失败：读不到注册表环境变量，退回继承的环境'
        '（machine=${machineOut == null ? 'null' : 'ok'}, user=${userOut == null ? 'null' : 'ok'}）',
      );
      return base;
    }
    final Map<String, RegEnvValue> machine = parseRegQueryEnv(machineOut);
    final Map<String, RegEnvValue> user = parseRegQueryEnv(userOut);
    // 读到了输出却一条都没解析出来（多半是 reg 输出格式变了）⇒ 也算失败
    if (machine.isEmpty && user.isEmpty) {
      log?.call('按登录口径重建环境：reg 输出一条都没解析出来，退回继承的环境（可能是默认值被清空或格式变了）');
      return base;
    }
    return composeLoginEnvironment(
      machine: machine,
      user: user,
      inherited: base,
    );
  } catch (error) {
    log?.call('按登录口径重建环境抛错，退回继承的环境：$error');
    return base;
  }
}
