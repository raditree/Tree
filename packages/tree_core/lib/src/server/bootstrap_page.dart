import 'dart:io';

import 'package:path/path.dart' as p;

/// 引导页（`GET /bootstrap`）的磁盘种子与渲染。
///
/// 规则（片 E / 5.2–5.3）：
/// - 页面从 `<数据根>/bootstrap/index.html` 读取；缺失时从安装包种子复制过去。
/// - 之后每次请求都**重读磁盘**，因此页面可以随核心独立更新。
/// - 种子文件也缺失时释放一份内置最小页面并记一条可读日志，**绝不 500 裸奔**。
class BootstrapPage {
  BootstrapPage({
    required this.dataDir,
    this.sourcePath,
    this.log,
  });

  /// 数据根（页面落在 `<dataDir>/bootstrap/index.html`）。
  final String dataDir;

  /// 显式指定的种子路径（测试用）；空 = 按默认顺序探测。
  final String? sourcePath;

  final void Function(String message)? log;

  /// 票据占位符：核心渲染时替换为一次性的"换会话"票据。
  static const String ticketPlaceholder = '__BOOTSTRAP_TICKET__';

  /// 种子页面的构建号（写进种子 HTML 的 `tree-bootstrap-build` meta）。
  ///
  /// 为什么需要它：页面是**落盘到数据根**的（用户可以改），但它的表单要跟着
  /// 核心接口演进——一直留着一份旧页面，升级后用户看到的还是老毛病（例如
  /// “引导壳只有重启和停用、没有启用”）。磁盘那份比种子旧才覆盖一次；
  /// 构建号相同就完全不动，用户自己的修改照旧保留。
  static const int seedBuild = 3;

  static final RegExp _buildPattern = RegExp(
    r'<meta\s+name="tree-bootstrap-build"\s+content="([0-9]+)"',
    caseSensitive: false,
  );

  /// 从页面 HTML 读构建号（没有 = 升级前的老页面）。
  static int? buildOf(String html) {
    final Match? match = _buildPattern.firstMatch(html);
    return match == null ? null : int.tryParse(match.group(1) ?? '');
  }

  /// 页面落盘路径。
  String get targetPath => p.join(dataDir, 'bootstrap', 'index.html');

  /// 读取 / 种下页面，并把 [exchangeTicket] 注入占位符。
  Future<String> render({required String exchangeTicket}) async {
    String html;
    try {
      html = await _ensureLocalPage();
    } catch (error, stack) {
      log?.call('[core:bootstrap] 读取引导页失败：$error\n$stack');
      html = _builtinFallback(reason: '$error');
    }
    if (html.contains(ticketPlaceholder)) {
      return html.replaceAll(ticketPlaceholder, exchangeTicket);
    }
    // 页面被用户改掉了占位符：追加一段注入，仍让页面拿得到票据。
    final String injection =
        '\n<script>window.__TREE_BOOTSTRAP_TICKET__ = '
        '${_jsString(exchangeTicket)};</script>\n';
    final int index = html.lastIndexOf('</body>');
    if (index < 0) return '$html\n$injection';
    return '${html.substring(0, index)}$injection${html.substring(index)}';
  }

  Future<String> _ensureLocalPage() async {
    final File target = File(targetPath);
    if (!await target.exists()) {
      await target.parent.create(recursive: true);
      final File? seed = await _findSeed();
      if (seed != null) {
        final List<int> bytes = await seed.readAsBytes();
        await target.writeAsBytes(bytes, flush: true);
        log?.call('[core:bootstrap] 已从 ${seed.path} 种子化引导页到 $targetPath');
      } else {
        final String fallback = _builtinFallback(
          reason: '安装包缺少 assets/bootstrap/index.html',
        );
        await target.writeAsString(fallback, flush: true);
        log?.call(
          '[core:bootstrap] 种子文件缺失（assets/bootstrap/index.html），'
          '已释放内置最小引导页到 $targetPath',
        );
      }
    } else {
      // 页面已落盘（可能是旧安装留下的，或用户手改过）：只在“比种子旧”时覆盖。
      await _refreshStalePage(target);
    }
    try {
      return await target.readAsString();
    } catch (error) {
      // 文件存在但读不了（权限 / 损坏）：释放内置页面后继续，不 500。
      log?.call('[core:bootstrap] 读取 $targetPath 失败：$error，改用内置页面');
      final String fallback = _builtinFallback(reason: '$error');
      try {
        await target.writeAsString(fallback, flush: true);
      } catch (_) {
        // 写不进去也只影响下次种子化，本次仍可返回内置页面。
      }
      return fallback;
    }
  }

  /// 磁盘上的页面比安装包种子旧（或没有构建号）⇒ 用种子覆盖一次。
  ///
  /// 构建号相同 / 种子自己没标号 ⇒ 一寸都不动（用户的修改照旧保留）。
  Future<void> _refreshStalePage(File target) async {
    try {
      final File? seed = await _findSeed();
      if (seed == null) return;
      final int? seedBuild = buildOf(await seed.readAsString());
      if (seedBuild == null) return;
      final int? localBuild = buildOf(await target.readAsString());
      if (localBuild != null && localBuild >= seedBuild) return;
      final List<int> bytes = await seed.readAsBytes();
      await target.writeAsBytes(bytes, flush: true);
      log?.call(
        '[core:bootstrap] 引导页已更新到种子版本（build $seedBuild）：$targetPath',
      );
    } catch (error) {
      // 读种子 / 读旧页面失败：保持现状，交给上面的读取分支处理。
      log?.call('[core:bootstrap] 检查引导页版本失败：$error');
    }
  }

  Future<File?> _findSeed() async {
    final String explicit = sourcePath?.trim() ?? '';
    if (explicit.isNotEmpty) {
      final File file = File(explicit);
      return await file.exists() ? file : null;
    }
    for (final String candidate in _defaultCandidates()) {
      final File file = File(candidate);
      if (await file.exists()) return file;
    }
    return null;
  }

  /// 默认种子候选：可执行文件同级 → 当前目录 → 向上找仓库根。
  List<String> _defaultCandidates() {
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final Set<String> seen = <String>{};
    final List<String> candidates = <String>[];
    void add(String dir) {
      final String value = p.join(dir, 'assets', 'bootstrap', 'index.html');
      if (seen.add(value)) candidates.add(value);
    }

    add(exeDir);
    add(Directory.current.path);
    Directory cursor = Directory(exeDir);
    for (int i = 0; i < 8; i++) {
      add(cursor.path);
      final Directory parent = cursor.parent;
      if (parent.path == cursor.path) break;
      cursor = parent;
    }
    return candidates;
  }

  static String _builtinFallback({required String reason}) {
    final String safe = _htmlEscape(reason);
    return '''
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tree 引导页（内置最小版本）</title>
<style>
body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:#111418;color:#e6e9ef;margin:0;padding:40px;line-height:1.6}
.card{max-width:720px;margin:0 auto;background:#1a1f26;border:1px solid #2b3440;border-radius:12px;padding:24px}
h1{font-size:20px;margin:0 0 12px}
code{background:#0d1117;padding:2px 6px;border-radius:6px}
.muted{color:#9aa7b8;font-size:13px}
</style>
</head>
<body>
<div class="card">
<h1>引导页文件缺失，已使用内置最小页面</h1>
<p>原因：$safe</p>
<p>请把安装包里的 <code>assets/bootstrap/index.html</code> 放到核心可执行文件同级的
<code>assets/bootstrap/</code> 目录，或直接放到数据根的
<code>bootstrap/index.html</code> 后再刷新本页。</p>
<p class="muted">本页面不含主 token；插件管理功能需要完整的引导页。</p>
</div>
</body>
</html>
''';
  }

  static String _htmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _jsString(String value) {
    final String escaped = value
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r');
    return '"$escaped"';
  }
}
