import 'dart:convert';

import 'package:tree_local_exec/tree_local_exec.dart';

import 'tool_runner.dart';

/// 内置工具集（M4 交付**工作空间类** 5 个：read / write / edit / grep / terminal）。
///
/// 其余 6 个内置工具（`set_todo_list` / `ask_user_question` / `spec` /
/// `team` / `message` 属 M5，`mcp` 属 M6）**现在不声明**：声明了但没实现，模型
/// 会去调用并浪费一整轮 token。声明与实现必须同步发布，因此 [specs] 是唯一的
/// 工具清单来源。
///
/// 结果格式面向模型：先一行摘要（路径/行号/命中数/退出码），再放内容；截断与
/// 超时都会显式写出来，模型才知道"这不是全部"。
abstract final class BuiltinTools {
  static const String read = 'read';
  static const String write = 'write';
  static const String edit = 'edit';
  static const String grep = 'grep';
  static const String terminal = 'terminal';

  /// 工具声明（顺序稳定：便于提示词缓存与测试断言）。
  static List<ToolSpec> specs() => <ToolSpec>[
    ToolSpec(
      name: read,
      description:
          '读取工作空间内某个文件的内容；可用 start_line/line_count 只读需要'
          '的行区间。file_path 必须是工作空间内相对路径（如 lib/foo.dart），'
          '禁止绝对路径与盘符。修改文件前应先用本工具确认现状。'
          '图像文件（png/jpg/jpeg/webp/gif）会返回 base64。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'file_path': <String, dynamic>{
            'type': 'string',
            'description': '工作空间内相对路径',
          },
          'start_line': <String, dynamic>{
            'type': 'integer',
            'description': '起始行号（1 基，缺省 1）',
          },
          'line_count': <String, dynamic>{
            'type': 'integer',
            'description': '读取行数（缺省读到文件末尾）',
          },
        },
        'required': <String>['file_path'],
      },
    ),
    ToolSpec(
      name: write,
      description:
          '向工作空间写入文件（覆盖已有内容，自动创建父目录）。'
          '小改动请用 edit 保留上下文；file_path 必须是工作空间内相对路径。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'file_path': <String, dynamic>{'type': 'string'},
          'content': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['file_path', 'content'],
      },
    ),
    ToolSpec(
      name: edit,
      description:
          '对工作空间内已有文件做精确字符串替换（old_text 必须在文件中唯一匹配，'
          '否则报错并提示改用更长片段或 replace_all）。自动兼容 LF/CRLF 换行。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'file_path': <String, dynamic>{'type': 'string'},
          'old_text': <String, dynamic>{
            'type': 'string',
            'description': '要被替换的原文（需唯一匹配）',
          },
          'new_text': <String, dynamic>{
            'type': 'string',
            'description': '替换后的内容（可为空串表示删除）',
          },
          'replace_all': <String, dynamic>{
            'type': 'boolean',
            'description': '替换全部匹配（缺省 false，要求唯一匹配）',
          },
        },
        'required': <String>['file_path', 'old_text', 'new_text'],
      },
    ),
    ToolSpec(
      name: grep,
      description:
          '在工作空间内按模式搜索文件内容，返回"路径:行号: 行内容"。'
          '先用 grep 缩小范围再 read 精读。默认排除 .git 与依赖/构建目录；'
          'regex=true 时 pattern 按正则解释。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pattern': <String, dynamic>{'type': 'string'},
          'path': <String, dynamic>{
            'type': 'string',
            'description': '搜索范围（工作空间内相对路径，缺省整个工作空间）',
          },
          'regex': <String, dynamic>{'type': 'boolean'},
          'ignore_case': <String, dynamic>{'type': 'boolean'},
          'max_depth': <String, dynamic>{
            'type': 'integer',
            'description': '递归层数（1=仅本层，缺省 0 不限）',
          },
          'max_results': <String, dynamic>{
            'type': 'integer',
            'description': '返回命中行数上限（缺省 200）',
          },
          'exclude': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{'type': 'string'},
            'description': '追加排除的 glob（按文件名匹配，如 *.g.dart）',
          },
        },
        'required': <String>['pattern'],
      },
    ),
    ToolSpec(
      name: terminal,
      description:
          '在工作空间根目录执行 shell 命令（Windows 用 cmd.exe，其他平台用 sh）。'
          '用于运行构建/测试/git/文件管理。stdout/stderr 都会被自动捕获，'
          '无需追加 2>&1。超时会终止整棵进程树并回报 timed_out。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'command': <String, dynamic>{'type': 'string'},
          'timeout_seconds': <String, dynamic>{
            'type': 'integer',
            'description': '超时秒数（缺省 120，上限 1800）',
          },
        },
        'required': <String>['command'],
      },
    ),
  ];

  /// 执行一次工具调用。
  ///
  /// 任何失败（路径非法/文件不存在/匹配不唯一/命令超时）都返回
  /// `isError: true` 的**可读结果**，不抛异常——模型要能读到原因并自我纠正。
  static Future<ToolOutcome> run(
    ToolInvocation invocation,
    WorkspaceIO io, {
    bool Function()? isCancelled,
  }) async {
    try {
      switch (invocation.name) {
        case read:
          return await _read(invocation, io);
        case write:
          return await _write(invocation, io);
        case edit:
          return await _edit(invocation, io);
        case grep:
          return await _grep(invocation, io);
        case terminal:
          return await _terminal(invocation, io, isCancelled: isCancelled);
        default:
          return ToolOutcome(
            '未知工具：${invocation.name}（可用：${specs().map((ToolSpec s) => s.name).join('、')}）',
            isError: true,
          );
      }
    } on WorkspacePathException catch (error) {
      return ToolOutcome(
        '路径不合法：${error.reason}（file_path 必须是工作空间内相对路径）',
        isError: true,
      );
    } on WorkspaceIoException catch (error) {
      return ToolOutcome(error.message, isError: true);
    } catch (error) {
      return ToolOutcome('工具执行失败：$error', isError: true);
    }
  }

  // ── 各工具实现 ───────────────────────────────────────────────────────

  static Future<ToolOutcome> _read(
    ToolInvocation invocation,
    WorkspaceIO io,
  ) async {
    final String path = _string(invocation, 'file_path');
    if (path.isEmpty) return const ToolOutcome('file_path 不能为空', isError: true);
    final FileContent content = await io.readFile(
      path,
      startLine: _int(invocation, 'start_line'),
      lineCount: _int(invocation, 'line_count'),
    );
    if (content.base64 != null) {
      return ToolOutcome(
        '文件：${content.path}（图像，${content.base64!.length} 字节 base64）\n'
        '${content.base64}',
      );
    }
    final StringBuffer buffer = StringBuffer()
      ..writeln(
        '文件：${content.path}（共 ${content.totalLines} 行，'
        '本次从第 ${content.startLine} 行开始'
        '${content.truncated ? '，已截断' : ''}）',
      );
    final String language = content.language;
    buffer.writeln(language.isEmpty ? '```' : '```$language');
    buffer.writeln(content.text);
    buffer.write('```');
    return ToolOutcome(buffer.toString());
  }

  static Future<ToolOutcome> _write(
    ToolInvocation invocation,
    WorkspaceIO io,
  ) async {
    final String path = _string(invocation, 'file_path');
    if (path.isEmpty) return const ToolOutcome('file_path 不能为空', isError: true);
    final String content = _string(invocation, 'content');
    final int bytes = await io.writeFile(path, content);
    final int lines = content.isEmpty
        ? 0
        : const LineSplitter().convert(content).length;
    return ToolOutcome('已写入 $path（$bytes 字节，$lines 行）');
  }

  static Future<ToolOutcome> _edit(
    ToolInvocation invocation,
    WorkspaceIO io,
  ) async {
    final String path = _string(invocation, 'file_path');
    if (path.isEmpty) return const ToolOutcome('file_path 不能为空', isError: true);
    final EditOutcome outcome = await io.editFile(
      path,
      oldText: _string(invocation, 'old_text'),
      newText: _string(invocation, 'new_text'),
      replaceAll: _bool(invocation, 'replace_all'),
    );
    return ToolOutcome(
      '已替换 ${outcome.replacements} 处：${outcome.path}'
      '（文件现为 ${outcome.bytesWritten} 字节）',
    );
  }

  static Future<ToolOutcome> _grep(
    ToolInvocation invocation,
    WorkspaceIO io,
  ) async {
    final String pattern = _string(invocation, 'pattern');
    if (pattern.isEmpty) {
      return const ToolOutcome('pattern 不能为空', isError: true);
    }
    final String path = _string(invocation, 'path');
    final GrepOutcome outcome = await io.grep(
      GrepQuery(
        pattern: pattern,
        regex: _bool(invocation, 'regex'),
        ignoreCase: _bool(invocation, 'ignore_case'),
        relativePath: path.isEmpty ? '.' : path,
        maxDepth: _int(invocation, 'max_depth') ?? 0,
        maxResults: _int(invocation, 'max_results') ?? 200,
        exclude: _stringList(invocation, 'exclude'),
      ),
    );
    final StringBuffer buffer = StringBuffer()
      ..writeln(
        '命中 ${outcome.matches.length} 处'
        '（扫描 ${outcome.scannedFiles} 个文件'
        '${outcome.truncated ? '，已达上限被截断' : ''}）',
      );
    for (final GrepMatch match in outcome.matches) {
      buffer.writeln('${match.path}:${match.lineNumber}: ${match.line.trim()}');
    }
    if (outcome.matches.isEmpty) {
      buffer.writeln('（无匹配；已排除 .git 与依赖/构建目录）');
    }
    return ToolOutcome(buffer.toString().trimRight());
  }

  static Future<ToolOutcome> _terminal(
    ToolInvocation invocation,
    WorkspaceIO io, {
    bool Function()? isCancelled,
  }) async {
    final String command = _string(invocation, 'command');
    if (command.isEmpty) {
      return const ToolOutcome('command 不能为空', isError: true);
    }
    int seconds = _int(invocation, 'timeout_seconds') ?? 120;
    if (seconds < 1) {
      seconds = 1;
    }
    if (seconds > 1800) {
      seconds = 1800;
    }
    if (isCancelled?.call() ?? false) {
      return const ToolOutcome('已取消：命令未执行', isError: true);
    }
    final ExecOutcome outcome = await io.exec(
      command,
      timeout: Duration(seconds: seconds),
    );
    final StringBuffer buffer = StringBuffer()
      ..writeln(
        '退出码 ${outcome.exitCode}${outcome.timedOut ? '（超时已终止）' : ''}'
        '｜shell=${outcome.shell}${outcome.truncated ? '｜输出已截断' : ''}',
      );
    if (outcome.stdout.trim().isNotEmpty) {
      buffer.writeln('--- stdout ---');
      buffer.writeln(outcome.stdout.trimRight());
    }
    if (outcome.stderr.trim().isNotEmpty) {
      buffer.writeln('--- stderr ---');
      buffer.writeln(outcome.stderr.trimRight());
    }
    if (outcome.stdout.trim().isEmpty && outcome.stderr.trim().isEmpty) {
      buffer.writeln('（无输出）');
    }
    if (outcome.nonUtf8Output) {
      buffer.writeln(
        '（注意：命令输出不是 UTF-8，中文可能显示为乱码——'
        'Windows 非 UTF-8 代码页下 cmd 内建命令的已知限制）',
      );
    }
    return ToolOutcome(buffer.toString().trimRight(), isError: !outcome.ok);
  }

  // ── 参数读取（模型给的参数不可信，一律宽容处理） ──────────────────────

  static String _string(ToolInvocation invocation, String key) {
    final Object? value = invocation.arguments[key];
    if (value is String) return value;
    if (value == null) return '';
    return '$value';
  }

  static int? _int(ToolInvocation invocation, String key) {
    final Object? value = invocation.arguments[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static bool _bool(ToolInvocation invocation, String key) {
    final Object? value = invocation.arguments[key];
    if (value is bool) return value;
    if (value is String) {
      final String text = value.trim().toLowerCase();
      return text == 'true' || text == '1' || text == 'yes';
    }
    if (value is num) return value != 0;
    return false;
  }

  static List<String> _stringList(ToolInvocation invocation, String key) {
    final Object? value = invocation.arguments[key];
    if (value is List) {
      return value
          .map((Object? e) => '$e')
          .where((String s) => s.isNotEmpty)
          .toList();
    }
    if (value is String && value.trim().isNotEmpty) {
      return value
          .split(',')
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }
}
