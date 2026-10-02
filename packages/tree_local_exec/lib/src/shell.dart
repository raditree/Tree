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
///    taskkill /T /F；
/// 4. **绝不进入交互等待**（2026-10-02 实机事故后加）：命令行带 `-NonInteractive`。
///    起因：agent 写了 `… ; echo; echo "=== …"`——PowerShell 里 `echo` 是
///    `Write-Output` 的别名，而它的 `-InputObject` 是**必填**参数，于是 PowerShell 弹出
///    「cmdlet Write-Output 位于命令管道位置 1 / 请提供以下参数的值: InputObject:」
///    并**等 stdin**；而子进程的 stdin 是 Dart 侧的管道（我们永远不会往里写），本地执行
///    又「进程活着就永不超时」（见 LocalWorkspaceIO.exec 的 M9 1.1 注释）——两头一凑，
///    整轮会话十几分钟一动不动。`-NonInteractive` 让这类提示**立刻变成错误**；配合
///    LocalWorkspaceIO.exec / TerminalHooks.start 关掉子进程 stdin，连原生子进程
///    （git 凭据、pause/choice、REPL）也只拿到 EOF 报错，而不是静默挂死。
///    **根因本身也已兼容**：裸 `echo` 由 [translateBareEcho] 补成 `echo ''`——三层里
///    第一层就让这条命令不进入交互，后面两层是兜底。
///
/// 已知行为差异（如实记录，不粉饰）：
/// - **&& / ||**：PowerShell 7 支持；Windows PowerShell 5.1 **不支持**（ParserError：
///   The token '&&' is not a valid statement separator in this version）。本机只有 5.1，
///   而 cmd.exe 时代这两个运算符是合法的，属于换 shell 带来的行为回归；模型生成的命令里
///   `&&` 又很常见，所以包装层主动做兼容翻译（见 [translateLogicalOperators]）——
///   但翻译只覆盖能确定的写法，命令里优先写 ; 仍然更稳。
/// - **1>&2**：同样只有 PS 7 支持（5.1 报 RedirectionNotSupported）；往 stderr 写请用
///   「[Console]::Error.WriteLine('…')」或 Write-Error。
/// - **裸 `echo`**：PS 下 `Write-Output -InputObject` 必填，`echo;` 会弹参数提示并等 stdin
///   （cmd/sh 里它只是输出一个空行）。包装层按 [translateBareEcho] 补成 `echo ''`，
///   语义与 cmd 一致——模型照 cmd 习惯写就行；
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
    return <String>[
      '-NoProfile',
      // 见类文档「绝不进入交互等待」：少了它，一句裸 echo 就能把整轮会话挂死。
      '-NonInteractive',
      '-Command',
      _wrapPowerShell(command),
    ];
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
      '-NonInteractive',
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

  /// 把 PowerShell 解析不了的 && / || 翻译成 5.1 也能跑的等价语句。
  ///
  /// 为什么在包装层做：本机没有 pwsh 7、只有 Windows PowerShell 5.1，而 5.1 把这两个
  /// 运算符当语法错误（ParserError），换 shell 之前用 cmd.exe 时它们是合法的——这是换
  /// shell 带来的行为回归，而模型生成的命令里 && 很常见，所以在包装层兜住。
  ///
  /// 翻译规则（; 顺序执行 + $? 判上一条的成败）：
  /// - a && b → a; if ($?) { b }
  /// - a || b → a; if (-not $?) { b }
  /// - 多段链按左折叠**平铺**展开：a && b && c → a; if ($?) { b }; if ($?) { c }
  ///   为什么平铺而不是层层嵌套：实测 5.1 里 if 语句**不重置 $?**（条件为假时 $? 保持上一条
  ///   命令的结果，为真且体执行了则取体里最后一条的结果）。于是 c 只在「b 真的跑过且成功」
  ///   时才执行，与 (a && b) && c 的左结合语义一致；顺着这条规则，混用也成立：
  ///   a && b || c → a; if ($?) { b }; if (-not $?) { c }。
  ///
  /// 结合范围按**语句**算，而不是整条命令：顶层 ; 与换行都是语句边界，所以 a && b; c 里的
  /// c 永远执行——若把它也塞进 if 块，a 失败时 c 会被静默吞掉，那是改写语义。语句末尾悬着
  /// 运算符时（a && 换行 b）换行按行继续处理，链可以跨行。
  ///
  /// 引号处理：单/双引号内的内容整体照抄（echo "x && y" 原样保留），双引号内认反引号转义
  /// 与连续两个双引号、单引号内认连续两个单引号（都是 PowerShell 的字面量规则），
  /// 配对不上就整体回退。
  ///
  /// **保守回退**（拿不准就原样返回：宁可让用户看到 PowerShell 的 ParserError，也不要悄悄
  /// 改写语义）：没有顶层运算符时**逐字节**返回原文；此外引号不闭合、链残缺（a &&）、
  /// 顶层注释 #、块注释 <#、here-string @' / @" 一律回退。
  ///
  /// 分支策略：装了 PowerShell 7 的机器上 && / || 本来就能用，其实可以原样透传；这里
  /// **不探测 pwsh 版本**，统一走翻译——翻译后的语句在 7 上语义相同（$? 语义没变），
  /// 少一条版本分支（真要按版本分流，改这一处即可）。
  ///
  /// 后台 hook 的 >> 日志 2>&1 后缀由 [redirectTo] 拼在命令末尾，翻译后它跟着**最后一段**
  /// 走（与 cmd 的重定向绑定规则相同）：a 失败时 b 不跑，日志同样可能是空的，与换 shell 前
  /// 的行为一致。
  static String translateLogicalOperators(String command) {
    // ① 先按语句边界切分。分隔符原样留着，最后按原样拼回去——没有运算符的语句一个字节都不动。
    final List<String> statements = <String>[];
    final List<String> separators = <String>[];
    final StringBuffer current = StringBuffer();
    int i = 0;
    while (i < command.length) {
      final String ch = command[i];
      if (ch == "'" || ch == '"') {
        final int end = _skipQuoted(command, i);
        if (end < 0) return command; // 引号不闭合：拿不准，整体回退
        current.write(command.substring(i, end));
        i = end;
        continue;
      }
      if (ch == '`') {
        // 顶层反引号同样是转义前缀（转义的 & 是字面 &，不是运算符的一半）：
        // 连被转义的字符一起照抄，免得把它当成运算符。
        final int end = i + 2 <= command.length ? i + 2 : command.length;
        current.write(command.substring(i, end));
        i = end;
        continue;
      }
      if (ch == '#' && _startsComment(command, i)) return command; // 行注释：回退
      if (ch == '<' && command.startsWith('<#', i)) return command; // 块注释：回退
      if (ch == '@' &&
          (command.startsWith("@'", i) || command.startsWith('@"', i))) {
        return command; // here-string：内部换行/引号规则是另一套，不解析
      }
      if (ch == ';' || ch == '\n') {
        String text = current.toString();
        String separator = ch == ';' ? ';' : '\n';
        if (ch == '\n' && text.endsWith('\r')) {
          // CRLF：别把 \r 留在语句里，跟分隔符一起原样拼回
          text = text.substring(0, text.length - 1);
          separator = '\r\n';
        }
        if (!_endsWithLogicalOperator(text)) {
          statements.add(text);
          separators.add(separator);
          current.clear();
          i++;
          continue;
        }
        // 语句末尾悬着运算符 → 这里是行继续，不是语句边界
      }
      current.write(ch);
      i++;
    }
    statements.add(current.toString());
    separators.add('');

    // ② 逐条语句折叠；只要有一处拿不准就整体回退（半翻译是最糟的结果：错误信息会指向
    //    被改写的半截命令，用户反而更难定位）。
    bool translated = false;
    final List<String> folded = <String>[];
    for (final String statement in statements) {
      final String? result = _foldLogicalOperators(statement);
      if (result == null) return command;
      if (result != statement) translated = true;
      folded.add(result);
    }
    if (!translated) return command; // 没有顶层运算符：逐字节不变，不重排命令
    final StringBuffer out = StringBuffer();
    for (int k = 0; k < folded.length; k++) {
      out.write(folded[k]);
      out.write(separators[k]);
    }
    return out.toString();
  }

  /// 折叠**一条语句**里的顶层 && / ||；没有运算符时原样返回，拿不准返回 null。
  static String? _foldLogicalOperators(String statement) {
    final List<String> segments = <String>[];
    final List<String> operators = <String>[];
    final StringBuffer current = StringBuffer();
    int i = 0;
    while (i < statement.length) {
      final String ch = statement[i];
      if (ch == "'" || ch == '"') {
        final int end = _skipQuoted(statement, i);
        if (end < 0) return null;
        current.write(statement.substring(i, end));
        i = end;
        continue;
      }
      if (ch == '`') {
        final int end = i + 2 <= statement.length ? i + 2 : statement.length;
        current.write(statement.substring(i, end));
        i = end;
        continue;
      }
      if (ch == '#' && _startsComment(statement, i)) return null;
      if (ch == '<' && statement.startsWith('<#', i)) return null;
      if (ch == '@' &&
          (statement.startsWith("@'", i) || statement.startsWith('@"', i))) {
        return null;
      }
      final String pair = i + 1 < statement.length
          ? statement.substring(i, i + 2)
          : '';
      if (pair == '&&' || pair == '||') {
        segments.add(current.toString());
        current.clear();
        operators.add(pair);
        i += 2;
        continue;
      }
      current.write(ch);
      i++;
    }
    if (operators.isEmpty) return statement; // 逐字节不变
    segments.add(current.toString());
    final List<String> parts = segments
        .map((String s) => s.trim())
        .toList(growable: false);
    if (parts.any((String s) => s.isEmpty)) return null; // 残缺的链（如 a && ）：回退
    final StringBuffer out = StringBuffer(parts.first);
    for (int k = 0; k < operators.length; k++) {
      final String condition = operators[k] == '&&' ? r'$?' : r'-not $?';
      out.write('; if ($condition) { ${parts[k + 1]} }');
    }
    return out.toString();
  }

  /// 语句是否以悬空的 && / || 结尾（用于判断换行是行继续还是语句边界）。
  static bool _endsWithLogicalOperator(String text) {
    final String trimmed = text.trimRight();
    return trimmed.endsWith('&&') || trimmed.endsWith('||');
  }

  /// 从 [start] 处的引号跳到它之后（返回结束位置的下一个下标）；不闭合返回 -1。
  ///
  /// 只做配对所需的最简转义处理，不解析字符串内容：
  /// - 单引号内连续两个单引号 = 一个字面单引号；
  /// - 双引号内连续两个双引号同理，反引号转义下一个字符（转义出来的引号不结束字符串）。
  static int _skipQuoted(String text, int start) {
    final String quote = text[start];
    int i = start + 1;
    while (i < text.length) {
      final String ch = text[i];
      if (quote == '"' && ch == '`') {
        i += 2;
        continue;
      }
      if (ch == quote) {
        if (i + 1 < text.length && text[i + 1] == quote) {
          i += 2; // 连续两个引号 = 字面引号
          continue;
        }
        return i + 1;
      }
      i++;
    }
    return -1;
  }

  /// # 是否处在「注释起始」位置：PowerShell 只在 token 开头才把 # 当注释
  /// （echo a#b 里的 # 是参数的一部分，不是注释）。
  static bool _startsComment(String text, int index) {
    if (index == 0) return true;
    return ' \t\r\n;|({},['.contains(text[index - 1]);
  }

  /// 把**无参数的** `echo` / `write-output` 补成 `echo ''`（兼容翻译，与
  /// [translateLogicalOperators] 同一取舍）。
  ///
  /// 为什么需要：PowerShell 的 `Write-Output -InputObject` 是**必填**参数，裸 `echo;`
  /// （cmd/sh 下合法、模型很爱用来做空行分隔）会弹出「请提供以下参数的值: InputObject:」
  /// 并**等 stdin**——本地执行又没有超时，一次就能把整轮会话挂死（2026-10-02 两次实机
  /// 事故的唯一触发点）。这里在包装层补一个空字符串，语义回到 cmd 的"输出一个空行"，
  /// 模型不必知道这条 PowerShell 差异。
  ///
  /// 只认**命令位置**上的无参调用（后面紧跟 `;` / 换行 / `|` / `)` / `}` / 行注释 / 结尾），
  /// 所以 `echo hi`、`echo ''`、`echo $x`、`function echo {…}`、引号内的 `echo` 一律不动；
  /// 拿不准（引号不闭合、here-string、块注释）就整体原样返回——宁可让模型看到 PowerShell
  /// 的原生报错，也不悄悄改写语义。没有可补之处时**逐字节**返回原文。
  static String translateBareEcho(String command) {
    final StringBuffer out = StringBuffer();
    bool changed = false;
    bool atCommandStart = true;
    int i = 0;
    while (i < command.length) {
      final String ch = command[i];
      if (ch == "'" || ch == '"') {
        final int end = _skipQuoted(command, i);
        if (end < 0) return command; // 引号不闭合：拿不准，整体回退
        out.write(command.substring(i, end));
        atCommandStart = false;
        i = end;
        continue;
      }
      if (ch == '`') {
        // 反引号转义：连被转义的字符一起照抄（转义出来的 ; | 不是分隔符）
        final int end = i + 2 <= command.length ? i + 2 : command.length;
        out.write(command.substring(i, end));
        atCommandStart = false;
        i = end;
        continue;
      }
      if (ch == '<' && command.startsWith('<#', i)) {
        return command; // 块注释：内部规则另一套，不解析
      }
      if (ch == '@' &&
          (command.startsWith("@'", i) || command.startsWith('@"', i))) {
        return command; // here-string：不解析
      }
      if (ch == '#' && _startsComment(command, i)) {
        // 行注释：整行原样抄走（注释里的 echo 不是命令）
        int end = command.indexOf('\n', i);
        if (end < 0) end = command.length;
        out.write(command.substring(i, end));
        i = end;
        continue;
      }
      if (ch == ';' || ch == '\n' || ch == '|' || ch == '&' || ch == '{' ||
          ch == '(') {
        out.write(ch);
        atCommandStart = true;
        i++;
        continue;
      }
      if (ch == ' ' || ch == '\t' || ch == '\r') {
        out.write(ch);
        i++;
        continue;
      }
      if (atCommandStart) {
        final int end = _bareOutputCommandEnd(command, i);
        if (end > 0) {
          out.write(command.substring(i, end));
          out.write(" ''");
          changed = true;
          i = end;
          atCommandStart = false;
          continue;
        }
      }
      out.write(ch);
      atCommandStart = false;
      i++;
    }
    return changed ? out.toString() : command;
  }

  /// [start] 处是不是**无参**的 `echo` / `write-output`；是则返回该名字结束的下标，
  /// 否则返回 -1。
  static int _bareOutputCommandEnd(String text, int start) {
    for (final String name in const <String>['echo', 'write-output']) {
      final int end = start + name.length;
      if (end > text.length) continue;
      if (text.substring(start, end).toLowerCase() != name) continue;
      int i = end;
      while (i < text.length &&
          (text[i] == ' ' || text[i] == '\t' || text[i] == '\r')) {
        i++;
      }
      if (i >= text.length) return end;
      final String next = text[i];
      if (next == ';' ||
          next == '\n' ||
          next == '|' ||
          next == ')' ||
          next == '}') {
        return end;
      }
      if (next == '#' && _startsComment(text, i)) return end;
      return -1;
    }
    return -1;
  }

  /// PowerShell 包装器：UTF-8 输出编码 + 退出码透传。
  ///
  /// 退出码为什么要两步：$LASTEXITCODE 只在跑过**原生命令**（git/ping/gradle…）之后才有值，
  /// 纯 PowerShell 命令（Get-Item 之类）失败时它是 $null——直接 exit $LASTEXITCODE 会让
  /// 失败看起来是成功。所以先把 $? 与 $LASTEXITCODE 都取下来，再决定退出码。
  ///
  /// 用 ; 连接用户命令：等价于「顺序执行、不管前一条成败」，与 cmd 的 & 一致。
  ///
  /// 用户命令先过 [translateLogicalOperators]：5.1 解析不了 && / ||，而模型生成的
  /// 命令里它们很常见（见类文档）。同步执行与后台 hook 共用这一处包装，两边语义一致。
  ///
  /// 全部用 Dart 原始字符串写 PowerShell 片段：省掉一层 $ / \ 转义，读起来就是 PS 原文。
  static String _wrapPowerShell(String command) {
    // 顺序有意：先补裸 echo（在模型的原始命令上认命令位置最准），再翻译 && / ||
    final String translated = translateLogicalOperators(
      translateBareEcho(command),
    );
    return r'[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; '
        r'$OutputEncoding=[System.Text.Encoding]::UTF8; '
        r"$PSDefaultParameterValues['Out-File:Encoding']='utf8'; "
        '$translated; '
        r'$__treeOk=$?; $__treeCode=$LASTEXITCODE; '
        r'if ($__treeCode -is [int] -and $__treeCode -ne 0) { exit $__treeCode }; '
        r'if ($__treeOk) { exit 0 } else { exit 1 }';
  }
}
