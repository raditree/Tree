import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// M9/Q1-②：超长工具结果门控。
///
/// 口径：阈值按 **token 估算**（默认 8000），超过就把完整结果写进工作空间
/// `.self/results/<yyyyMMdd_HHmmss>_<3位序号>.<工具名>.result`，送模型的换成提示
/// （字符数 / 阈值 / 路径 / 查看建议 / 前 300 字符预览）；写不进去则退化为截断。
void main() {
  ToolResultGate gate({
    ResultRedirectWriter? writer,
    double tokenScale = defaultTokenScale,
    int thresholdTokens = ToolResultGate.defaultThresholdTokens,
    DateTime? now,
  }) => ToolResultGate(
    agentId: 'agt_1',
    thresholdTokens: thresholdTokens,
    tokenScale: tokenScale,
    writer: writer,
    clock: () => now ?? DateTime(2026, 3, 4, 5, 6, 7),
  );

  group('阈值判定', () {
    test('默认阈值 8000 token、落点 .self/results', () {
      expect(ToolResultGate.defaultThresholdTokens, 8000);
      expect(ToolResultGate.defaultPreviewChars, 300);
      expect(ToolResultGate.resultsDir, '.self/results');
    });

    test('按 token 判定，而不是字符数', () {
      final ToolResultGate subject = gate();
      // 8000 token @2.0 = 16000 字符：正好等于阈值时不算超
      expect(subject.exceeds('x' * 16000), isFalse);
      expect(subject.exceeds('x' * 16001), isTrue);
      // 比例变了，同一个字符串的判定也跟着变：比例越大，同样字符数折算出的
      // token 越少，越不容易触发门控
      expect(gate(tokenScale: 4).exceeds('x' * 16000), isFalse);
      expect(gate(tokenScale: 1).exceeds('x' * 16000), isTrue);
    });
  });

  group('重定向', () {
    test('完整原文落文件，返回提示（路径 / 字符数 / 阈值 / 建议 / 预览）', () async {
      final String huge = '中文结果' * 4000; // 16000 字符 = 8000 token，超过 800 阈值用例
      final List<String> writes = <String>[];
      final ToolResultGate subject = gate(
        thresholdTokens: 800,
        writer: (String agentId, String path, String content) async {
          writes.add('$agentId|$path|${content.length}|${content == huge}');
        },
      );
      final String notice = await subject.apply('read', huge);
      expect(
        writes.single,
        'agt_1|.self/results/20260304_050607_001.read.result|16000|true',
      );
      expect(notice, contains('[工具结果已重定向]'));
      expect(notice, contains('read'));
      expect(notice, contains('16000 字符'));
      expect(notice, contains('> 800 阈值'));
      expect(notice, contains('.self/results/20260304_050607_001.read.result'));
      expect(notice, contains('read 工具'));
      expect(notice, contains('terminal 工具'));
      expect(notice, contains(huge.substring(0, 300)));
      expect(notice, isNot(contains(huge.substring(0, 301))));
      expect(notice.length, lessThan(600));
    });

    test('未超阈值原样返回，不产生写入', () async {
      int writes = 0;
      final ToolResultGate subject = gate(
        writer: (String a, String p, String c) async => writes++,
      );
      expect(await subject.apply('read', 'x' * 100), 'x' * 100);
      expect(writes, 0);
    });

    test('连续重定向的序号递增（同一次 run 内）', () async {
      final List<String> paths = <String>[];
      final ToolResultGate subject = gate(
        thresholdTokens: 10,
        writer: (String a, String path, String c) async => paths.add(path),
      );
      await subject.apply('read', 'x' * 100);
      await subject.apply('grep', 'x' * 100);
      expect(paths, <String>[
        '.self/results/20260304_050607_001.read.result',
        '.self/results/20260304_050607_002.grep.result',
      ]);
    });

    test('工具名里的不安全字符被替换（MCP 命名空间工具也能落文件）', () async {
      final List<String> paths = <String>[];
      final ToolResultGate subject = gate(
        thresholdTokens: 10,
        writer: (String a, String path, String c) async => paths.add(path),
      );
      await subject.apply('mcp__files/read:1', 'x' * 100);
      expect(paths.single, endsWith('.mcp__files_read_1.result'));
    });
  });

  group('退化路径（没有写入能力 / 写失败）', () {
    test('没有写入器：按阈值截断并如实标注', () async {
      final String huge = 'x' * 4000;
      final ToolResultGate subject = gate(thresholdTokens: 800);
      final String text = await subject.apply('read', huge);
      expect(text, startsWith('x' * 1600));
      expect(text, contains('已截断至 1600 字符'));
      expect(text, contains('4000 字符'));
      expect(text.length, lessThan(huge.length));
    });

    test('写入抛异常：不冒泡，退化为截断', () async {
      final ToolResultGate subject = gate(
        thresholdTokens: 800,
        writer: (String a, String p, String c) async =>
            throw StateError('磁盘满了'),
      );
      final String text = await subject.apply('read', 'y' * 4000);
      expect(text, startsWith('y' * 1600));
      expect(text, contains('已截断至'));
    });

    test('截断不会切出半个代理对', () async {
      // 阈值 1 token @2.0 = 2 字符：第 1 个码元是 emoji 的高代理
      final ToolResultGate subject = gate(
        thresholdTokens: 1,
        writer: (String a, String p, String c) async => throw StateError('不写'),
      );
      final String text = await subject.apply('read', '😀😀');
      expect(text.startsWith('😀'), isTrue);
    });
  });
}
