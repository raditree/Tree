/// 远端命令的**登录外壳**包装（与 `tree_local_exec/lib/src/ssh_login_shell.dart` 同语义）。
///
/// **为什么插件要做这件事**（协议 §3.3）：agent 用 `/bin/sh -c <command>` 执行收到的命令，
/// 那是**非登录 shell** ⇒ 看不到 `/etc/profile` / `~/.profile` 里的 PATH，用户在 ssh 里有的
/// `nvcc` / conda 那类工具就没了。而"探一次 + 包一层"需要一条能跑命令的通道，只有插件有
/// （插件握有 SSH 通道；agent 里做就得再起进程）。
///
/// **语义（逐条对齐 `ssh_login_shell.dart`，不自己发明）**：
/// - 三态模板：`null` = 用内置候选，`''` = 显式关掉，非空 = 自定义模板（必须带 `{cmd}`）；
/// - 逐级回退：`bash -lc {cmd}` → `sh -lc {cmd}` → **原样发**（探测全失败）；
/// - 命令一律 **POSIX 单引号转义**（`'` → `'\''`）；模板非法只**跳过那一档**，不让命令失败；
/// - 一次连接（= 一条隧道）**只探测一次**并缓存。
///
/// 与原件的一处**有意的差异**（任务书指定）：内置候选的探活用 `command -v bash` /
/// `command -v sh`（原件是"跑一次渲染后的 `true`"）；自定义模板仍按原件口径"跑一次
/// 渲染后的 `true`"验活（任意模板都能这么验）。
library;

/// 模板里的命令占位符。
const String kLoginShellPlaceholder = '{cmd}';

/// 内置候选（按顺序探测，第一个能用的胜出）。与 `tree_local_exec` 逐字一致。
const List<String> kLoginShellCandidates = <String>[
  'bash -lc {cmd}',
  'sh -lc {cmd}',
];

/// 内置候选 → 探活命令。
const Map<String, String> kCandidateProbeCommands = <String, String>{
  'bash -lc {cmd}': 'command -v bash',
  'sh -lc {cmd}': 'command -v sh',
};

/// POSIX 单引号转义：命令里可能有单引号、`$`、反引号、换行——一律当字面量送过去。
String posixSingleQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// 按 [template] 把 [command] 渲染成实际发给远端的那条命令（模板必须带 `{cmd}`）。
///
/// 缺占位符时抛 [ArgumentError]：调用方（[LoginShell]）会跳过这一档并记日志，
/// 而不是把一条没人看得懂的命令发出去。
String renderLoginShellCommand({
  required String template,
  required String command,
}) {
  if (!template.contains(kLoginShellPlaceholder)) {
    throw ArgumentError(
      '登录外壳模板里必须有 $kLoginShellPlaceholder 占位符：$template',
    );
  }
  return template.replaceAll(
    kLoginShellPlaceholder,
    posixSingleQuote(command),
  );
}

/// 探活回调：跑一条命令，返回退出码（`0` = 可用）。测试注入假实现。
typedef LoginShellProber = Future<int> Function(String command);

/// 决定"这条隧道上用哪个模板"：**只探测一次**并缓存结论。
class LoginShell {
  LoginShell({
    this.template,
    required this.prober,
    this.candidates = kLoginShellCandidates,
    this.log,
  });

  /// 用户配置：null = 用内置候选；`''` = 显式关掉；非空 = 自定义模板（先试它）。
  final String? template;

  /// 内置候选（测试可换）。
  final List<String> candidates;

  /// 探活回调（测试注入假实现）。
  final LoginShellProber prober;

  final void Function(String message)? log;

  bool _resolved = false;
  String? _chosen;
  List<String> _probed = const <String>[];

  /// 已经探过哪些档（日志/诊断用）。
  List<String> get probed => _probed;

  /// 解析出可用的模板：null = **不包装**（原样发）。结论缓存，第二次调用直接返回。
  Future<String?> resolve() async {
    if (_resolved) return _chosen;
    _resolved = true;
    final List<String> trace = <String>[];
    _chosen = await _decide(trace);
    _probed = List<String>.unmodifiable(trace);
    if (_chosen == null) {
      log?.call(
        '远端没有可用的登录外壳（${_order().join(' → ')} 都探测失败）：命令原样发送',
      );
    } else {
      log?.call('远端命令走登录外壳：$_chosen');
    }
    return _chosen;
  }

  /// 把 [command] 包成实际要发给远端的那条命令（不可用时原样返回）。
  Future<String> wrap(String command) async {
    final String? chosen = await resolve();
    if (chosen == null) return command;
    try {
      return renderLoginShellCommand(template: chosen, command: command);
    } on ArgumentError catch (error) {
      // 不该发生（选中的模板都渲染过一次），真发生也绝不吞：记日志 + 原样发。
      log?.call('登录外壳模板不可用，命令原样发送：$error');
      return command;
    }
  }

  /// 清空缓存（测试用；生产里一条隧道只解析一次）。
  void reset() {
    _resolved = false;
    _chosen = null;
    _probed = const <String>[];
  }

  /// 探测顺序：自定义模板（非空）排最前，然后是内置候选；去重、跳过空串。
  List<String> _order() {
    final String? configured = template?.trim();
    final List<String> out = <String>[];
    if (configured != null && configured.isNotEmpty) out.add(configured);
    for (final String candidate in candidates) {
      final String item = candidate.trim();
      if (item.isEmpty || item == configured) continue;
      if (!out.contains(item)) out.add(item);
    }
    return out;
  }

  Future<String?> _decide(List<String> trace) async {
    // 显式关掉：直接不包装（连探测都不做）。
    if (template != null && template!.trim().isEmpty) {
      trace.add('（已显式关掉登录外壳）');
      return null;
    }
    for (final String candidate in _order()) {
      // 模板本身不合法（缺 {cmd}）就跳过这一档，别让它在每条命令上炸。
      final String probe;
      try {
        probe = kCandidateProbeCommands[candidate] ??
            renderLoginShellCommand(template: candidate, command: 'true');
      } on ArgumentError catch (error) {
        log?.call('跳过不可用的登录外壳模板：$error');
        trace.add('$candidate（非法模板）');
        continue;
      }
      int code;
      try {
        code = await prober(probe);
      } catch (error) {
        log?.call('探测登录外壳失败（$candidate）：$error');
        trace.add('$candidate（探测异常）');
        continue;
      }
      if (code == 0) {
        trace.add('$candidate ✓');
        return candidate;
      }
      trace.add('$candidate ✗（exit=$code）');
    }
    return null;
  }
}
