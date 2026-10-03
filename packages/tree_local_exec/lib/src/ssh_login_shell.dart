/// 远端命令的**登录外壳**包装：让 agent 的工具环境与"用户自己 ssh 登进去"一致。
///
/// **为什么需要**（用户 2026-10-03：「我发现 SSH 下也有类似情况（上次我有 nvcc，另一个 agent
/// 没有）」）：工具命令走 SSH 的 **exec 通道**（`client.runWithResult(cmd)`），按 sshd 的语义
/// 那是**非交互、非登录**的 shell（`$SHELL -c '<cmd>'`）——于是 `/etc/profile`、`~/.profile`、
/// conda/CUDA 那类"登录时才加载"的 PATH 全都不在，agent 就看不到用户 ssh 进来时明明有的
/// `nvcc`。交互终端（Ctrl+J 的远端分支）走 `shell(pty:)`，本来就是登录 shell，不受影响。
///
/// **做法**：把命令包一层登录 shell（默认 `bash -lc '<cmd>'`）。**探测 + 逐级回退**：
/// `bash` 不在 ⇒ `sh -lc`；都不在（探测失败）⇒ **原样发**（行为与今天完全一致）并记日志。
///
/// **可配**：模板用 `{cmd}` 占位（例如 `zsh -lc {cmd}`）；空串 = 显式关掉包装。
/// 模板拿不准（缺 `{cmd}` 之类）不会让命令失败——那一档被跳过并记日志，后面还有兜底。
///
/// **代价（如实标注）**：登录外壳会读远端 profile，profile 里若往 stdout 打印欢迎语，
/// 那些字会混进命令输出；`resolveRemoteRoot` 因此改成**带标记**取 `$HOME`
/// （见 `ssh_workspace_io.dart`）。真嫌吵就在 agent yaml 里写 `login_shell: ''`。
library;

/// 模板里的命令占位符。
const String kSshLoginShellPlaceholder = '{cmd}';

/// 内置候选（按顺序探测，第一个能用的胜出）。
const List<String> kSshLoginShellCandidates = <String>[
  'bash -lc {cmd}',
  'sh -lc {cmd}',
];

/// POSIX 单引号转义：命令里可能有单引号、`$`、反引号、换行——一律当字面量送过去。
String posixSingleQuote(String value) =>
    "'${value.replaceAll("'", "'\\''")}'";

/// 按 [template] 把 [command] 渲染成实际发给远端的那条命令（模板必须带 `{cmd}`）。
///
/// 缺占位符时抛 [ArgumentError]：调用方（[SshLoginShell]）会跳过这一档并记日志，
/// 而不是把一条没人看得懂的命令发出去。
String renderLoginShellCommand({
  required String template,
  required String command,
}) {
  if (!template.contains(kSshLoginShellPlaceholder)) {
    throw ArgumentError(
      '登录外壳模板里必须有 $kSshLoginShellPlaceholder 占位符：$template',
    );
  }
  return template.replaceAll(
    kSshLoginShellPlaceholder,
    posixSingleQuote(command),
  );
}

/// 决定"这条连接上用哪个模板"：**只探测一次**并缓存结论，供 [wrap] 反复使用。
class SshLoginShell {
  SshLoginShell({
    this.template,
    this._prober,
    this.log,
    this.candidates = kSshLoginShellCandidates,
  });

  /// 用户配置：null = 用内置候选；`''` = 显式关掉；非空 = 自定义模板（先试它）。
  final String? template;

  /// 内置候选（测试可换）。
  final List<String> candidates;

  /// 探测：跑一条命令看能不能用（默认由调用方注入，通常是"远端跑一次 `true`"）。
  final Future<bool> Function(String command)? _prober;

  final void Function(String message)? log;

  bool _resolved = false;
  String? _chosen;

  /// 解析出可用的模板：null = **不包装**（原样发）。结论缓存。
  Future<String?> resolve() async {
    if (_resolved) return _chosen;
    _resolved = true;
    _chosen = await _decide();
    if (_chosen == null) {
      log?.call('远端没有可用的登录外壳（${_order().join(' → ')} 都探测失败）：命令原样发送');
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
      // 不该发生（选中的模板都渲染过一次），真发生也绝不吞：记日志 + 原样发
      log?.call('登录外壳模板不可用，命令原样发送：$error');
      return command;
    }
  }

  /// 清空缓存（测试用；生产里一条连接只解析一次）。
  void reset() {
    _resolved = false;
    _chosen = null;
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

  Future<String?> _decide() async {
    // 显式关掉：直接不包装（连探测都不做）
    if (template != null && template!.trim().isEmpty) return null;
    final Future<bool> Function(String command)? prober = _prober;
    if (prober == null) return null;
    for (final String candidate in _order()) {
      // 模板本身不合法（缺 {cmd}）就跳过这一档，别让它在每条命令上炸
      final String probe;
      try {
        probe = renderLoginShellCommand(template: candidate, command: 'true');
      } on ArgumentError catch (error) {
        log?.call('跳过不可用的登录外壳模板：$error');
        continue;
      }
      bool ok;
      try {
        ok = await prober(probe);
      } catch (error) {
        log?.call('探测登录外壳失败（$candidate）：$error');
        continue;
      }
      if (ok) return candidate;
    }
    return null;
  }
}
