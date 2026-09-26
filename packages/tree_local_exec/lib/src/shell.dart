import 'dart:io';

/// 命令执行相关的跨平台细节（同步执行与后台 hook 模式**共用同一套语义**）。
///
/// Windows 上不再用 cmd.exe，改用 **PowerShell**（优先 PowerShell 7 「pwsh.exe」，其次系统
/// 自带的 Windows PowerShell 5.1，两者都没有才退回 cmd.exe）。换 shell 是为了**从源头**
/// 解决编码问题：cmd.exe 时代无论怎么前置 「chcp 65001」，**cmd 内建命令（dir/echo/type）
/// 写管道时仍按系统 ANSI 代码页输出**（中文机器 = GBK），chcp 管不住管道；PowerShell 里把
/// 「[Console]::OutputEncoding」显式设成 UTF-8 后，管道输出就是 UTF-8（实测 PS 5.1 同样生效）。
/// 执行器**仍保留**按系统代码页解码的兜底链（见 [LocalWorkspaceIO.decodeBytes]）：cmd 内建
/// 命令、旧工具、cmd /c 子进程照样可能吐 GBK 字节。
///
/// Windows 包装器同时承担三件事（见 [_wrapPowerShell]）：
/// 1. **输出编码固定 UTF-8**：「[Console]::OutputEncoding」+「$OutputEncoding」，顺带把
///    「Out-File」的默认编码钉成 utf8（后台 hook 的 >> 日志在 PS 5.1 下默认是 UTF-16LE，
///    那样日志会被读成乱码）；
/// 2. **退出码透传**：-Command 默认返回 0，末尾必须把真实退出码还原（$LASTEXITCODE 只管
///    原生命令，纯 cmdlet 的失败要靠 $? 兜，见 [_wrapPowerShell]）；
/// 3. 进程树终止语义不变：只杀 shell 会留下真正干活的后台进程，[killProcessTree] 仍走
///    taskkill /T /F。
///
/// 已知行为差异（如实记录，不粉饰）：
/// - **&& / ||**：PowerShell 7 支持；Windows PowerShell 5.1 **不支持**，会报解析错误——
///   此时 stderr 有可读报错、退出码 1，而不是静默空输出。需要兼容 5.1 就用 ; 顺序执行。
/// - **1>&2**：同样只有 PS 7 支持（5.1 报 RedirectionNotSupported）；往 stderr 写请用
///   「[Console]::Error.WriteLine('…')」或 Write-Error。
/// - **cmd 内建命令变成别名/cmdlet**：dir→Get-ChildItem、type→Get-Content，输出格式不同；
///   cd（Set-Location）**不再打印当前目录**，要打印用 $PWD.Path。
/// - 非 Windows 仍是 /bin/sh -c；SSH 远端跑的是**远端自己的 shell**，与此无关。
abstract final class Shell {
  /// 当前平台的 shell 可执行文件（Windows 上优先 PowerShell 7）。
  static String get executable => Platform.isWindows ? windowsShell : '/bin/sh';

  /// Windows shell 的候选顺序：PowerShell 7 → Windows PowerShell 5.1 → cmd.exe。
  ///
  /// 抽成常量是为了让「回退策略」只有一处可改：如果 5.1 的 && / 1>&2 差异不可接受，
  /// 把 cmd.exe 提到 powershell.exe 之前即可（编码兜底链与它无关，照样生效）。
  static const List<String> windowsShellCandidates = <String>[
    'pwsh.exe',
    'powershell.exe',
    'cmd.exe',
  ];

  static String? _cachedWindowsShell;

  /// 探测出来的 Windows shell（只探一次：exec 是热路径）。
  ///
  /// 用 where.exe 查 PATH，是因为 Process.start 不会替我们做 PATH 兜底：找不到就抛
  /// ProcessException。探测本身失败不抛异常，只是换下一个候选；候选全落空时用最后一项
  /// （cmd.exe，Windows 必然自带），真找不到会由 Process.start 如实报错给工具层。
  static String get windowsShell {
    final String? cached = _cachedWindowsShell;
    if (cached != null) return cached;
    String resolved = windowsShellCandidates.last;
    for (final String candidate in windowsShellCandidates) {
      if (_isOnPath(candidate)) {
        resolved = candidate;
        break;
      }
    }
    _cachedWindowsShell = resolved;
    return resolved;
  }

  static bool _isOnPath(String executable) {
    try {
      final ProcessResult probe = Process.runSync('where.exe', <String>[
        executable,
      ]);
      return probe.exitCode == 0 && '${probe.stdout}'.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 把命令包成 shell 参数。
  static List<String> argsFor(String command) {
    if (!Platform.isWindows) return <String>['-c', command];
    if (_isCmd(windowsShell)) {
      // 退回 cmd 时保留老写法：内建命令的管道输出仍是系统 ANSI 代码页，
      // 由解码链（decodeBytes）兜住。
      return <String>['/c', 'chcp 65001 >nul && $command'];
    }
    return <String>['-NoProfile', '-Command', _wrapPowerShell(command)];
  }

  /// 后台模式的重定向后缀（把 stdout/stderr 都写进日志文件）。
  ///
  /// 用 shell 自带的重定向而不是 Dart 侧转发：这样日志是**子进程直接写文件**，
  /// 核心进程重启/退出都不会丢输出，也少一层管道。
  ///
  /// PowerShell 下不用「| Out-File」是有意的：管道会多一层缓冲与格式化，而 >> 是原样追加；
  /// 它的编码由 [_wrapPowerShell] 里的 $PSDefaultParameterValues 钉死为 utf8。
  static String redirectTo(String logPath) {
    if (!Platform.isWindows) return " >> '$logPath' 2>&1";
    return ' >> "$logPath" 2>&1';
  }

  /// 后台 hook 脚本的扩展名（必须与 [scriptFor] 的 shell 对上：PS 用 .ps1，cmd 用 .cmd）。
  static String get scriptExtension {
    if (!Platform.isWindows) return '.sh';
    return _isCmd(windowsShell) ? '.cmd' : '.ps1';
  }

  /// 后台 hook 脚本内容（同步执行与后台 hook **共用同一套 shell 与包装**）。
  ///
  /// 为什么后台也要跟着换：同一条命令前台用 PowerShell、后台用 cmd.exe，会出现「前台能跑、
  /// 后台说 'Out-Null' 不是内部或外部命令」这种自相矛盾的行为（换 shell 时实测踩到）。
  /// 这里直接复用 [_wrapPowerShell] / cmd 前缀，两边语义完全一致。
  static String scriptFor(String body) {
    if (!Platform.isWindows) return '#!/bin/sh\n$body\nexit \$?\n';
    if (_isCmd(windowsShell)) {
      return '@echo off\r\nchcp 65001 >nul\r\n$body\r\nexit /b %ERRORLEVEL%\r\n';
    }
    return '${_wrapPowerShell(body)}\r\n';
  }

  /// 跑后台 hook 脚本的参数（Process.start(Shell.executable, Shell.argsForScript(path))）。
  ///
  /// -ExecutionPolicy Bypass：默认执行策略（Restricted）会直接拒绝 .ps1；组策略级别的限制
  /// 它覆盖不了，那种机器上会如实报错，不会静默空跑。
  static List<String> argsForScript(String scriptPath) {
    if (!Platform.isWindows) return <String>[scriptPath];
    if (_isCmd(windowsShell)) return <String>['/c', scriptPath];
    return <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
    ];
  }

  /// 终止进程及其整棵子树（Windows: taskkill /T；POSIX: 先 TERM 后 KILL）。
  static Future<void> killProcessTree(int pid) async {
    if (!Platform.isWindows) {
      Process.killPid(pid, ProcessSignal.sigterm);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      Process.killPid(pid, ProcessSignal.sigkill);
      return;
    }
    try {
      await Process.run('taskkill', <String>['/PID', '$pid', '/T', '/F']);
    } catch (_) {
      // 尽力而为：进程可能已经退出
    }
  }

  static bool _isCmd(String shell) => shell.toLowerCase().endsWith('cmd.exe');

  /// PowerShell 包装器：UTF-8 输出编码 + 退出码透传。
  ///
  /// 退出码为什么要两步：$LASTEXITCODE 只在跑过**原生命令**（git/ping/gradle…）之后才有值，
  /// 纯 PowerShell 命令（Get-Item 之类）失败时它是 $null——直接 exit $LASTEXITCODE 会让
  /// 失败看起来是成功。所以先把 $? 与 $LASTEXITCODE 都取下来，再决定退出码。
  ///
  /// 用 ; 连接用户命令：等价于「顺序执行、不管前一条成败」，与 cmd 的 & 一致；
  /// 用户自己写 && 由 PowerShell 自己解释（5.1 会报解析错误，见类文档）。
  ///
  /// 全部用 Dart 原始字符串写 PowerShell 片段：省掉一层 $ / \ 转义，读起来就是 PS 原文。
  static String _wrapPowerShell(String command) =>
      r'[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; '
      r'$OutputEncoding=[System.Text.Encoding]::UTF8; '
      r"$PSDefaultParameterValues['Out-File:Encoding']='utf8'; "
      '$command; '
      r'$__treeOk=$?; $__treeCode=$LASTEXITCODE; '
      r'if ($__treeCode -is [int] -and $__treeCode -ne 0) { exit $__treeCode }; '
      r'if ($__treeOk) { exit 0 } else { exit 1 }';
}
