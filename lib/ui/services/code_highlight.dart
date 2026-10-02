import 'package:flutter/material.dart';

/// 代码高亮（**不引第三方依赖**）。
///
/// 为什么不引包：桌面线与核心都在本机、要能离线构建，引一个高亮包就多一条版本与
/// 许可证链；而这里需要只是「关键字 / 类型 / 字符串 / 注释 / 数字 / 注解 / 函数名」
/// 七类着色，一张规则表 + 单遍扫描就够。真解析（语法树、折叠、诊断）不在范围内。
///
/// 两条性能断言（见 lib/README.md 不变量 12）：
/// - 只在文本 ≤ [kHighlightMaxChars] 时着色，超过退回单色等宽——大文件不能让
///   每次按键都重扫几百 KB；
/// - 记号按「文本内容 + 配色」缓存，按键才重算一次（不是每帧重算）。

/// 超过这么多字符就不着色（保住输入流畅）
const int kHighlightMaxChars = 128 * 1024;

/// 记号类型
enum CodeTokenKind {
  keyword,
  type,
  string,
  comment,
  number,
  annotation,
  function,
}

/// 一个记号（[[start], [end]) 半开区间，单位是 UTF-16 code unit，与 String 下标一致）
class CodeToken {
  const CodeToken(this.start, this.end, this.kind);

  final int start;
  final int end;
  final CodeTokenKind kind;

  @override
  String toString() => 'CodeToken($start, $end, $kind)';
}

/// 一门语言的词法规则
class CodeLanguage {
  const CodeLanguage({
    required this.id,
    required this.label,
    this.keywords = const <String>{},
    this.types = const <String>{},
    this.lineComments = const <String>['//'],
    this.blockComments = const <List<String>>[],
    this.strings = const <String>["'", '"'],
    this.decorator = '',
    this.caseSensitive = true,
  });

  final String id;
  final String label;
  final Set<String> keywords;

  /// 已知类型名（大写开头的标识符也会当类型，见 [tokenize]）
  final Set<String> types;
  final List<String> lineComments;

  /// 块注释的 [开, 关] 对（可多组，如 Dart 的 /* */ 与 HTML 的 <!-- -->）
  final List<List<String>> blockComments;

  /// 字符串定界符，**长的要排在前面**（如 Python 的 `````` 与 `"`）
  final List<String> strings;

  /// 装饰器 / 注解前缀（如 @），空 = 这门语言没有
  final String decorator;
  final bool caseSensitive;

}

/// 不着色（未知扩展名 / Markdown 这类正文语言）
const CodeLanguage kPlainLanguage =
    CodeLanguage(id: 'plain', label: '纯文本', blockComments: <List<String>>[]);

const CodeLanguage kDartLanguage = CodeLanguage(
  id: 'dart',
  label: 'Dart',
  keywords: <String>{
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
    'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
    'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
    'external', 'factory', 'final', 'finally', 'for', 'get', 'hide', 'if',
    'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
    'mixin', 'new', 'on', 'operator', 'part', 'required', 'rethrow', 'return',
    'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync', 'this',
    'throw', 'try', 'typedef', 'var', 'void', 'when', 'while', 'with', 'yield',
  },
  types: <String>{
    'bool', 'double', 'int', 'num', 'String', 'Object', 'Null', 'Never',
    'Future', 'Stream', 'List', 'Map', 'Set', 'Iterable', 'Widget',
    'BuildContext', 'State', 'StatelessWidget', 'StatefulWidget', 'ChangeNotifier',
    'ValueNotifier', 'TextEditingController', 'FocusNode', 'IconData', 'Color',
  },
  blockComments: <List<String>>[
    <String>['/*', '*/'],
  ],
  strings: <String>["'''", '"""', "'", '"'],
  decorator: '@',
);

const CodeLanguage kPythonLanguage = CodeLanguage(
  id: 'python',
  label: 'Python',
  keywords: <String>{
    'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue',
    'def', 'del', 'elif', 'else', 'except', 'finally', 'for', 'from', 'global',
    'if', 'import', 'in', 'is', 'lambda', 'match', 'case', 'nonlocal', 'not',
    'or', 'pass', 'raise', 'return', 'try', 'while', 'with', 'yield',
  },
  types: <String>{
    'bool', 'bytes', 'dict', 'float', 'int', 'list', 'object', 'set', 'str',
    'tuple', 'type', 'None', 'True', 'False', 'self', 'cls',
  },
  lineComments: <String>['#'],
  strings: <String>["'''", '"""', "'", '"'],
  decorator: '@',
);

const CodeLanguage kJsLanguage = CodeLanguage(
  id: 'javascript',
  label: 'JavaScript / TypeScript',
  keywords: <String>{
    'as', 'async', 'await', 'break', 'case', 'catch', 'class', 'const',
    'continue', 'debugger', 'default', 'delete', 'do', 'else', 'enum', 'export',
    'extends', 'finally', 'for', 'from', 'function', 'if', 'implements',
    'import', 'in', 'instanceof', 'interface', 'let', 'new', 'of', 'private',
    'protected', 'public', 'readonly', 'return', 'satisfies', 'static', 'super',
    'switch', 'this', 'throw', 'try', 'type', 'typeof', 'var', 'void', 'while',
    'with', 'yield',
  },
  types: <String>{
    'any', 'boolean', 'never', 'number', 'object', 'string', 'symbol',
    'unknown', 'undefined', 'null', 'true', 'false', 'Promise', 'Array',
    'Record', 'Partial',
  },
  blockComments: <List<String>>[
    <String>['/*', '*/'],
  ],
  strings: <String>['`', "'", '"'],
  decorator: '@',
);

const CodeLanguage kJavaLikeLanguage = CodeLanguage(
  id: 'javalike',
  label: 'Java / Kotlin / C# / Swift',
  keywords: <String>{
    'abstract', 'as', 'assert', 'break', 'case', 'catch', 'class', 'const',
    'continue', 'data', 'default', 'do', 'else', 'enum', 'extends', 'final',
    'finally', 'for', 'fun', 'if', 'implements', 'import', 'in', 'instanceof',
    'interface', 'internal', 'is', 'let', 'new', 'object', 'open', 'override',
    'package', 'private', 'protected', 'public', 'return', 'sealed', 'static',
    'super', 'switch', 'synchronized', 'this', 'throw', 'throws', 'try', 'val',
    'var', 'void', 'while', 'when', 'yield',
  },
  types: <String>{
    'boolean', 'byte', 'char', 'double', 'float', 'int', 'long', 'short',
    'String', 'Object', 'Integer', 'Boolean', 'Double', 'List', 'Map', 'Set',
    'null', 'true', 'false', 'Any', 'Unit',
  },
  blockComments: <List<String>>[
    <String>['/*', '*/'],
  ],
  decorator: '@',
);

const CodeLanguage kGoLanguage = CodeLanguage(
  id: 'go',
  label: 'Go',
  keywords: <String>{
    'break', 'case', 'chan', 'const', 'continue', 'default', 'defer', 'else',
    'fallthrough', 'for', 'func', 'go', 'goto', 'if', 'import', 'interface',
    'map', 'package', 'range', 'return', 'select', 'struct', 'switch', 'type',
    'var',
  },
  types: <String>{
    'bool', 'byte', 'complex64', 'complex128', 'error', 'float32', 'float64',
    'int', 'int8', 'int16', 'int32', 'int64', 'rune', 'string', 'uint', 'uint8',
    'uint16', 'uint32', 'uint64', 'uintptr', 'any', 'nil', 'true', 'false',
  },
  blockComments: <List<String>>[
    <String>['/*', '*/'],
  ],
  strings: <String>['`', "'", '"'],
);

const CodeLanguage kRustLanguage = CodeLanguage(
  id: 'rust',
  label: 'Rust',
  keywords: <String>{
    'as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn',
    'else', 'enum', 'extern', 'fn', 'for', 'if', 'impl', 'in', 'let', 'loop',
    'match', 'mod', 'move', 'mut', 'pub', 'ref', 'return', 'self', 'static',
    'struct', 'super', 'trait', 'type', 'unsafe', 'use', 'where', 'while',
  },
  types: <String>{
    'bool', 'char', 'f32', 'f64', 'i8', 'i16', 'i32', 'i64', 'i128', 'isize',
    'str', 'u8', 'u16', 'u32', 'u64', 'u128', 'usize', 'String', 'Vec', 'Option',
    'Result', 'Box', 'Some', 'None', 'Ok', 'Err',
  },
  blockComments: <List<String>>[
    <String>['/*', '*/'],
  ],
  strings: <String>['"', "'"],
  decorator: '#',
);

const CodeLanguage kCLanguage = CodeLanguage(
  id: 'c',
  label: 'C / C++',
  keywords: <String>{
    'auto', 'break', 'case', 'class', 'const', 'constexpr', 'continue',
    'default', 'delete', 'do', 'else', 'enum', 'explicit', 'extern', 'false',
    'for', 'friend', 'goto', 'if', 'inline', 'mutable', 'namespace', 'new',
    'noexcept', 'nullptr', 'operator', 'override', 'private', 'protected',
    'public', 'register', 'return', 'sizeof', 'static', 'struct', 'switch',
    'template', 'this', 'throw', 'true', 'try', 'typedef', 'typename', 'union',
    'using', 'virtual', 'volatile', 'while',
  },
  types: <String>{
    'bool', 'char', 'double', 'float', 'int', 'long', 'short', 'signed',
    'size_t', 'uint32_t', 'uint64_t', 'unsigned', 'void', 'string', 'vector',
  },
  blockComments: <List<String>>[
    <String>['/*', '*/'],
  ],
  strings: <String>["'", '"'],
  decorator: '#',
);

const CodeLanguage kShellLanguage = CodeLanguage(
  id: 'shell',
  label: 'Shell',
  keywords: <String>{
    'case', 'do', 'done', 'elif', 'else', 'esac', 'fi', 'for', 'function',
    'if', 'in', 'select', 'then', 'time', 'until', 'while', 'export', 'local',
    'readonly', 'return', 'set', 'shift', 'source', 'unset',
  },
  types: <String>{'true', 'false', 'echo', 'cd', 'ls', 'cat', 'grep', 'sed', 'awk', 'find'},
  lineComments: <String>['#'],
  strings: <String>["'", '"'],
);

const CodeLanguage kPowerShellLanguage = CodeLanguage(
  id: 'powershell',
  label: 'PowerShell',
  keywords: <String>{
    'begin', 'break', 'catch', 'class', 'continue', 'data', 'do', 'dynamicparam',
    'else', 'elseif', 'end', 'enum', 'filter', 'finally', 'for', 'foreach',
    'from', 'function', 'if', 'in', 'param', 'process', 'return', 'switch',
    'throw', 'trap', 'try', 'until', 'using', 'while', 'workflow',
  },
  types: <String>{
    'Get-ChildItem', 'Get-Content', 'Get-Item', 'Set-Content', 'Select-Object',
    'Where-Object', 'ForEach-Object', 'Measure-Object', 'Write-Output', 'Test-Path',
  },
  lineComments: <String>['#'],
  blockComments: <List<String>>[
    <String>['<#', '#>'],
  ],
  strings: <String>["'", '"'],
  caseSensitive: false,
  decorator: r'$',
);

const CodeLanguage kSqlLanguage = CodeLanguage(
  id: 'sql',
  label: 'SQL',
  keywords: <String>{
    'ADD', 'ALTER', 'AND', 'AS', 'ASC', 'BEGIN', 'BETWEEN', 'BY', 'CASE',
    'COMMIT', 'CREATE', 'DELETE', 'DESC', 'DISTINCT', 'DROP', 'ELSE', 'END',
    'EXISTS', 'FOREIGN', 'FROM', 'GROUP', 'HAVING', 'IN', 'INDEX', 'INNER',
    'INSERT', 'INTO', 'JOIN', 'KEY', 'LEFT', 'LIKE', 'LIMIT', 'NOT', 'NULL',
    'OFFSET', 'ON', 'OR', 'ORDER', 'OUTER', 'PRIMARY', 'RIGHT', 'ROLLBACK',
    'SELECT', 'SET', 'TABLE', 'THEN', 'UNION', 'UNIQUE', 'UPDATE', 'VALUES',
    'WHEN', 'WHERE',
  },
  types: <String>{'BIGINT', 'BOOLEAN', 'DATE', 'INT', 'INTEGER', 'NUMERIC', 'REAL', 'TEXT', 'TIMESTAMP', 'VARCHAR'},
  lineComments: <String>['--'],
  blockComments: <List<String>>[
    <String>['/*', '*/'],
  ],
  strings: <String>["'", '"'],
  caseSensitive: false,
);

const CodeLanguage kJsonLanguage = CodeLanguage(
  id: 'json',
  label: 'JSON',
  types: <String>{'true', 'false', 'null'},
  strings: <String>['"'],
);

const CodeLanguage kYamlLanguage = CodeLanguage(
  id: 'yaml',
  label: 'YAML / TOML / INI',
  types: <String>{'true', 'false', 'null', 'yes', 'no', 'on', 'off'},
  lineComments: <String>['#', ';'],
  strings: <String>["'", '"'],
);

const CodeLanguage kHtmlLanguage = CodeLanguage(
  id: 'html',
  label: 'HTML / XML',
  keywords: <String>{
    'a', 'body', 'button', 'div', 'head', 'html', 'img', 'input', 'link',
    'meta', 'script', 'span', 'style', 'table', 'td', 'th', 'tr', 'title',
  },
  blockComments: <List<String>>[
    <String>['<!--', '-->'],
  ],
  strings: <String>['"', "'"],
);

const CodeLanguage kCssLanguage = CodeLanguage(
  id: 'css',
  label: 'CSS / SCSS',
  keywords: <String>{
    'align', 'animation', 'background', 'border', 'bottom', 'box', 'color',
    'content', 'display', 'flex', 'font', 'gap', 'grid', 'height', 'justify',
    'left', 'margin', 'max', 'min', 'opacity', 'overflow', 'padding',
    'position', 'right', 'shadow', 'text', 'top', 'transform', 'transition',
    'width', 'z',
  },
  blockComments: <List<String>>[
    <String>['/*', '*/'],
  ],
  strings: <String>["'", '"'],
);

const CodeLanguage kBatchLanguage = CodeLanguage(
  id: 'batch',
  label: 'Batch',
  keywords: <String>{
    'call', 'cd', 'cls', 'copy', 'del', 'do', 'echo', 'else', 'endlocal',
    'exist', 'exit', 'for', 'goto', 'if', 'in', 'md', 'move', 'not', 'pause',
    'popd', 'pushd', 'rd', 'rem', 'ren', 'set', 'setlocal', 'shift', 'start',
    'type',
  },
  types: <String>{'errorlevel', 'nul', 'off', 'on', 'defined'},
  lineComments: <String>['::'],
  strings: <String>['"'],
  caseSensitive: false,
  decorator: '%',
);

/// 按路径挑语言（认不出给 [kPlainLanguage]：纯文本不着色）
CodeLanguage languageForPath(String path) {
  final String name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  final int dot = name.lastIndexOf('.');
  final String ext = dot <= 0 ? '' : name.substring(dot + 1);
  switch (ext) {
    case 'dart':
      return kDartLanguage;
    case 'py':
    case 'pyw':
      return kPythonLanguage;
    case 'js':
    case 'mjs':
    case 'cjs':
    case 'jsx':
    case 'ts':
    case 'tsx':
      return kJsLanguage;
    case 'java':
    case 'kt':
    case 'kts':
    case 'cs':
    case 'swift':
      return kJavaLikeLanguage;
    case 'go':
      return kGoLanguage;
    case 'rs':
      return kRustLanguage;
    case 'c':
    case 'h':
    case 'cc':
    case 'cpp':
    case 'cxx':
    case 'hpp':
    case 'hh':
      return kCLanguage;
    case 'sh':
    case 'bash':
    case 'zsh':
    case 'fish':
      return kShellLanguage;
    case 'ps1':
    case 'psm1':
      return kPowerShellLanguage;
    case 'sql':
      return kSqlLanguage;
    case 'json':
    case 'jsonl':
      return kJsonLanguage;
    case 'yaml':
    case 'yml':
    case 'toml':
    case 'ini':
    case 'cfg':
    case 'conf':
    case 'env':
    case 'properties':
      return kYamlLanguage;
    case 'html':
    case 'htm':
    case 'xml':
    case 'svg':
    case 'vue':
      return kHtmlLanguage;
    case 'css':
    case 'scss':
    case 'sass':
    case 'less':
      return kCssLanguage;
    case 'bat':
    case 'cmd':
      return kBatchLanguage;
    default:
      return kPlainLanguage;
  }
}
/// 单遍词法扫描：返回按位置升序、互不重叠的记号；空隙（空白 / 标点 / 普通标识符）
/// 不产生记号，由渲染方按基础样式补上。
///
/// 判定顺序在同一个起点上是互斥的（`//` 与引号不可能同时开始），所以按
/// 「行注释 → 块注释 → 字符串 → 数字 → 标识符」逐个试即可，不需要最长匹配。
List<CodeToken> tokenize(String text, CodeLanguage language) {
  final int n = text.length;
  if (n == 0) return const <CodeToken>[];
  final List<CodeToken> out = <CodeToken>[];
  int i = 0;
  while (i < n) {
    // 行注释：到行尾
    final String? line = _startsLineComment(text, i, language);
    if (line != null) {
      int end = text.indexOf('\n', i);
      if (end < 0) end = n;
      out.add(CodeToken(i, end, CodeTokenKind.comment));
      i = end;
      continue;
    }
    // 块注释：到闭合串（没闭合就吃到结尾，跟编辑器一样"未闭合仍然高亮"）
    final CodeToken? block = _readBlockComment(text, i, language);
    if (block != null) {
      out.add(block);
      i = block.end;
      continue;
    }
    // 字符串
    final String? quote = _startsString(text, i, language);
    if (quote != null) {
      final int end = _readString(text, i, quote);
      out.add(CodeToken(i, end, CodeTokenKind.string));
      i = end;
      continue;
    }
    final int c = text.codeUnitAt(i);
    // 数字
    if (_isDigit(c)) {
      int j = i + 1;
      while (j < n && _isNumberChar(text.codeUnitAt(j))) {
        j++;
      }
      out.add(CodeToken(i, j, CodeTokenKind.number));
      i = j;
      continue;
    }
    // 标识符 / 关键字 / 类型 / 函数名 / 注解
    if (_isIdentStart(c)) {
      int j = i + 1;
      while (j < n && _isIdentPart(text.codeUnitAt(j))) {
        j++;
      }
      final String word = text.substring(i, j);
      final CodeTokenKind? kind = _classify(text, i, j, word, language);
      if (kind != null) out.add(CodeToken(i, j, kind));
      i = j;
      continue;
    }
    i++;
  }
  return out;
}

CodeTokenKind? _classify(
  String text,
  int start,
  int end,
  String word,
  CodeLanguage language,
) {
  final String probe = language.caseSensitive ? word : word.toLowerCase();
  final Set<String> keywords = language.caseSensitive
      ? language.keywords
      : language.keywords.map((String k) => k.toLowerCase()).toSet();
  final Set<String> types = language.caseSensitive
      ? language.types
      : language.types.map((String t) => t.toLowerCase()).toSet();
  if (keywords.contains(probe)) return CodeTokenKind.keyword;
  if (types.contains(probe)) return CodeTokenKind.type;
  // 装饰器 / 注解：@Override、#[derive]、$env:...（前缀紧贴在标识符前）
  if (language.decorator.isNotEmpty && start > 0) {
    final String before = text.substring(start - 1, start);
    if (before == language.decorator) return CodeTokenKind.annotation;
  }
  // 函数名：后面（跳过空白）紧跟 '('
  int k = end;
  while (k < text.length && (text.codeUnitAt(k) == 0x20 || text.codeUnitAt(k) == 0x09)) {
    k++;
  }
  if (k < text.length && text.codeUnitAt(k) == 0x28) return CodeTokenKind.function;
  // 大写开头：类 / 枚举 / 组件名（语言无关的通用启发）
  if (word.isNotEmpty && word[0].toUpperCase() == word[0] && word[0] != word[0].toLowerCase()) {
    return CodeTokenKind.type;
  }
  return null;
}

String? _startsLineComment(String text, int i, CodeLanguage language) {
  for (final String mark in language.lineComments) {
    if (text.startsWith(mark, i)) return mark;
  }
  return null;
}

CodeToken? _readBlockComment(String text, int i, CodeLanguage language) {
  for (final List<String> pair in language.blockComments) {
    if (pair.length != 2 || !text.startsWith(pair[0], i)) continue;
    final int close = text.indexOf(pair[1], i + pair[0].length);
    final int end = close < 0 ? text.length : close + pair[1].length;
    return CodeToken(i, end, CodeTokenKind.comment);
  }
  return null;
}

String? _startsString(String text, int i, CodeLanguage language) {
  for (final String quote in language.strings) {
    if (text.startsWith(quote, i)) return quote;
  }
  return null;
}

/// 读一个字符串到闭合定界符（含）；\ 转义跳过下一个字符；没闭合吃到结尾。
/// 多行字符串（``` / """ / `）自然支持：不在这里对换行做限制。
int _readString(String text, int start, String quote) {
  final int n = text.length;
  int i = start + quote.length;
  while (i < n) {
    if (text.codeUnitAt(i) == 0x5C) {
      i += 2;
      continue;
    }
    if (text.startsWith(quote, i)) return i + quote.length;
    i++;
  }
  return n;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isNumberChar(int c) =>
    _isDigit(c) ||
    (c >= 0x41 && c <= 0x46) ||
    (c >= 0x61 && c <= 0x66) ||
    c == 0x78 ||
    c == 0x58 ||
    c == 0x2E ||
    c == 0x5F ||
    c == 0x2B ||
    c == 0x2D;

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0x5F ||
    c == 0x24 ||
    c > 0x7F;

bool _isIdentPart(int c) => _isIdentStart(c) || _isDigit(c);

/// 代码配色：暗色 / 浅色各一套，都往品牌绿靠（别把主题里的主色当关键字色，
/// 那样整屏都是荧光绿）。
class CodeTheme {
  const CodeTheme({
    required this.keyword,
    required this.type,
    required this.string,
    required this.comment,
    required this.number,
    required this.annotation,
    required this.function,
  });

  final Color keyword;
  final Color type;
  final Color string;
  final Color comment;
  final Color number;
  final Color annotation;
  final Color function;

  /// 深色：黑底 + 亮绿主题下可读的柔和色
  static const CodeTheme dark = CodeTheme(
    keyword: Color(0xFF7FD1A6),
    type: Color(0xFF6FB7E8),
    string: Color(0xFFE8C07D),
    comment: Color(0xFF5E8E71),
    number: Color(0xFFC792EA),
    annotation: Color(0xFFF78C6C),
    function: Color(0xFF82AAFF),
  );

  /// 浅色：白底上压暗，保证对比度
  static const CodeTheme light = CodeTheme(
    keyword: Color(0xFF0A7B4B),
    type: Color(0xFF1F6FB2),
    string: Color(0xFF9A6A00),
    comment: Color(0xFF6FA98A),
    number: Color(0xFF7C3AED),
    annotation: Color(0xFFC2410C),
    function: Color(0xFF1D4ED8),
  );

  static CodeTheme of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  Color colorOf(CodeTokenKind kind) {
    switch (kind) {
      case CodeTokenKind.keyword:
        return keyword;
      case CodeTokenKind.type:
        return type;
      case CodeTokenKind.string:
        return string;
      case CodeTokenKind.comment:
        return comment;
      case CodeTokenKind.number:
        return number;
      case CodeTokenKind.annotation:
        return annotation;
      case CodeTokenKind.function:
        return function;
    }
  }
}

/// 把文本按记号切成带色的 span：记号区间上色，空隙（空白 / 标点 / 普通标识符）
/// 并进相邻 span 的基础样式。
///
/// 只读视图（SelectableText.rich）与可编辑控制器共用这一份：两边分别实现，颜色
/// 迟早会漂——切到编辑态时颜色一跳就很难看。
TextSpan buildCodeTextSpan({
  required String text,
  required CodeLanguage language,
  required CodeTheme theme,
  TextStyle? baseStyle,
}) {
  final List<CodeToken> tokens = tokenize(text, language);
  if (tokens.isEmpty) return TextSpan(style: baseStyle, text: text);
  final List<TextSpan> spans = <TextSpan>[];
  int cursor = 0;
  for (final CodeToken token in tokens) {
    if (token.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, token.start)));
    }
    spans.add(TextSpan(
      text: text.substring(token.start, token.end),
      style: TextStyle(color: theme.colorOf(token.kind)),
    ));
    cursor = token.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return TextSpan(style: baseStyle, children: spans);
}

/// 带高亮的编辑控制器：**只**重写 [buildTextSpan]。
///
/// 编辑能力（光标、选区、撤销、输入法、粘贴）全部交给 Flutter 原生
/// [TextEditingController]——手搓一个编辑器内核只会把输入法搞坏。
class CodeEditingController extends TextEditingController {
  CodeEditingController({required this.language, super.text});

  /// 当前语言（可随文件切换；切了就丢缓存重算）
  CodeLanguage language;

  /// 缓存：同一段文本 + 同一套配色只切一次 span（按键才重算，不是每帧重算）
  String? _cacheText;
  CodeTheme? _cacheTheme;
  List<InlineSpan>? _cacheChildren;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final String text = this.text;
    // 大文件不加色：每次按键重扫几百 KB 会让输入发涩（见 kHighlightMaxChars）
    if (text.length > kHighlightMaxChars) {
      return TextSpan(style: style, text: text);
    }
    // 输入法组字期间交回平台：组字区间要下划线，自己切分会把它切碎
    if (withComposing && !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final CodeTheme theme = CodeTheme.of(context);
    if (_cacheText != text || !identical(_cacheTheme, theme) || _cacheChildren == null) {
      _cacheText = text;
      _cacheTheme = theme;
      // 只缓存 children：基础样式（字号/颜色）会随焦点态变，留着它就没法复用
      _cacheChildren = buildCodeTextSpan(
            text: text,
            language: language,
            theme: theme,
            baseStyle: style,
          ).children ??
          <InlineSpan>[TextSpan(text: text)];
    }
    return TextSpan(style: style, children: _cacheChildren);
  }
}
