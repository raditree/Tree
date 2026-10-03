import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/core_process_launcher.dart';
import 'package:tree/ui/services/usage_log_files.dart';
import 'package:tree/ui/widgets/usage_calls_panel.dart';

/// 逐调用用量账本入口的应用侧测试（**纯 Dart 逻辑 + 临时目录**，不起核心）。
///
/// 为什么值得测：这条链路是"这一轮到底花了多少"的唯一取证手段，而它有四个
/// 静默失败的坑——id 非法却照样拼路径去读（`../` 能读到数据根之外）、
/// 拿不到数据根却猜一个路径、坏行让整块读数消失、读到空与"没调用过"被混为一谈。
/// 四处都必须给出**可读状态**而不是空白。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('tree_usage_log_');
  });

  tearDown(() {
    // Windows 上文件可能还被句柄占着：清理失败不该让测试红。
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String filePath([String name = 'usage.jsonl']) =>
      '${tempDir.path}${Platform.pathSeparator}$name';

  /// 账本的一行（固定契约的 8 个键；`cached_tokens` 可显式为 null）。
  String usageLine({
    required String at,
    required String source,
    String model = 'claude-sonnet-4',
    int prompt = 0,
    int? cached,
    int completion = 0,
    bool estimated = false,
    int? durationMs = 0,
  }) =>
      jsonEncode(<String, dynamic>{
        'at': at,
        'source': source,
        'model': model,
        'prompt_tokens': prompt,
        'cached_tokens': cached,
        'completion_tokens': completion,
        'estimated': estimated,
        'duration_ms': durationMs,
      });

  void writeLines(String path, List<String> lines) =>
      File(path).writeAsStringSync('${lines.join('\n')}\n');

  group('契约常量', () {
    test('默认看最近 50 次调用；单次最多回读 256 KiB', () {
      expect(UsageLogFiles.defaultLines, 50);
      expect(UsageLogFiles.maxTailBytes, 256 * 1024);
    });
  });

  group('UsageLogFiles.resolveUsageFile', () {
    test('override（测试注入）原样返回', () {
      final String path = filePath();
      expect(
        UsageLogFiles.resolveUsageFile(
          agentId: 'agent_1',
          sessionId: 'session_1',
          override: path,
        ),
        path,
      );
    });

    test('id 非法 ⇒ 空串（即便给了 override 也不给路径）', () {
      final String path = filePath();
      for (final String bad in <String>[
        '', ' ', '.', '..', '../escape', 'a/b', r'a\b', 'a b', 'agent#1',
        '会话', '../..',
      ]) {
        expect(
          UsageLogFiles.resolveUsageFile(agentId: bad, sessionId: 's1'),
          '',
          reason: 'agentId="$bad" 必须被拒',
        );
        expect(
          UsageLogFiles.resolveUsageFile(agentId: 'a1', sessionId: bad),
          '',
          reason: 'sessionId="$bad" 必须被拒',
        );
        expect(
          UsageLogFiles.resolveUsageFile(
            agentId: bad,
            sessionId: 's1',
            override: path,
          ),
          '',
          reason: 'agentId="$bad" 即便带 override 也必须被拒',
        );
      }
    });

    test('拿不到数据根 ⇒ 空串（不猜 %APPDATA%）', () {
      // 前置条件：测试环境里握手无从发生 ⇒ 数据根恒为空串。
      expect(CoreProcessLauncher.instance.coreDataRoot, isEmpty);
      expect(
        UsageLogFiles.resolveUsageFile(agentId: 'agent_1', sessionId: 's1'),
        '',
      );
    });
  });

  group('UsageLogFiles.readRecent', () {
    test('正常：3 行合法账本 → 3 个 UsageCallView，顺序与字段都对', () async {
      final String path = filePath();
      writeLines(path, <String>[
        usageLine(
          at: '2026-01-02T03:04:05Z',
          source: 'turn',
          prompt: 1200,
          cached: null,
          completion: 300,
          durationMs: 820,
        ),
        usageLine(
          at: '2026-01-02T03:05:00.500Z',
          source: 'compact',
          model: 'gpt-5.5',
          prompt: 9000,
          cached: 8000,
          completion: 512,
          durationMs: 1800,
        ),
        usageLine(
          at: '2026-01-02T03:06:00Z',
          source: 'llm.call',
          prompt: 40,
          cached: 0,
          completion: 7,
          estimated: true,
          durationMs: 120,
        ),
      ]);

      final UsageHistoryRead read = await UsageLogFiles.readRecent(
        agentId: 'agent_1',
        sessionId: 'session_1',
        override: path,
      );

      expect(read.ok, isTrue);
      expect(read.reason, isEmpty);
      expect(read.usageFile, path);
      expect(read.skippedLines, 0);
      expect(read.isEmpty, isFalse);
      expect(read.calls, hasLength(3));
      // 文件顺序：早 → 晚。
      expect(
        read.calls.map((UsageCallView c) => c.source).toList(),
        <String>['turn', 'compact', 'llm.call'],
      );
      expect(read.calls[0].promptTokens, 1200);
      expect(read.calls[0].completionTokens, 300);
      expect(read.calls[0].durationMs, 820);
      expect(read.calls[0].estimated, isFalse);
      expect(read.calls[0].model, 'claude-sonnet-4');
      // null 保 null：端点没报这个字段 ≠ 命中 0 个 token。
      expect(read.calls[0].cachedTokens, isNull);
      expect(read.calls[1].cachedTokens, 8000);
      expect(read.calls[1].model, 'gpt-5.5');
      // 0 就是 0，不能变成 null。
      expect(read.calls[2].cachedTokens, 0);
      expect(read.calls[2].estimated, isTrue);
      expect(read.calls[0].at?.toUtc(), DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(
        read.calls[1].at?.toUtc(),
        DateTime.utc(2026, 1, 2, 3, 5, 0, 500),
      );
      expect(read.calls[2].at?.toUtc(), DateTime.utc(2026, 1, 2, 3, 6, 0));
    });

    test('文件不存在 ⇒ ok=false + 可读 reason，不抛', () async {
      final String path = filePath('nope-usage.jsonl');
      expect(File(path).existsSync(), isFalse);

      final UsageHistoryRead read = await UsageLogFiles.readRecent(
        agentId: 'agent_1',
        sessionId: 'session_1',
        override: path,
      );

      expect(read.ok, isFalse);
      expect(read.reason, isNotEmpty);
      expect(read.reason, contains('还没有 usage.jsonl'));
      expect(read.reason, contains(path));
      expect(read.calls, isEmpty);
      expect(read.isEmpty, isTrue);
      expect(read.skippedLines, 0);
      expect(read.usageFile, path);
    });

    test('空文件 ⇒ ok=true + 空列表（跑过但还没记上是正常状态）', () async {
      final String path = filePath();
      File(path).writeAsStringSync('');

      final UsageHistoryRead read = await UsageLogFiles.readRecent(
        agentId: 'agent_1',
        sessionId: 'session_1',
        override: path,
      );

      expect(read.ok, isTrue);
      expect(read.reason, isEmpty);
      expect(read.calls, isEmpty);
      expect(read.isEmpty, isTrue);
      expect(read.skippedLines, 0);
    });

    test('坏行：跳过并计数，好行照读；空行不算坏行', () async {
      final String path = filePath();
      writeLines(path, <String>[
        usageLine(at: '2026-01-02T03:04:05Z', source: 'turn', prompt: 10),
        'not json at all', // 非法 JSON
        '{"source":"turn"}', // 缺 at
        '[1,2]', // 不是对象
        '{"at":"2026-01-02T03:04:06Z"}', // 缺 source
        '{"at":"2026-01-02T03:04:06Z","source":"   "}', // source 是空白
        '', // 空行（手改留白）：不该被记成坏行
        usageLine(at: '2026-01-02T03:04:07Z', source: 'plugin', prompt: 30),
      ]);

      final UsageHistoryRead read = await UsageLogFiles.readRecent(
        agentId: 'agent_1',
        sessionId: 'session_1',
        override: path,
      );

      expect(read.ok, isTrue);
      expect(read.skippedLines, 5);
      expect(
        read.calls.map((UsageCallView c) => c.promptTokens).toList(),
        <int>[10, 30],
      );
      expect(
        read.calls.map((UsageCallView c) => c.source).toList(),
        <String>['turn', 'plugin'],
      );
    });

    test('尾部截断：40 行里只要最后 5 行，最新那条在最后', () async {
      final String path = filePath();
      writeLines(path, <String>[
        for (int i = 0; i < 40; i++)
          usageLine(
            at: '2026-01-02T03:04:${i.toString().padLeft(2, '0')}Z',
            source: 'turn',
            prompt: i,
          ),
      ]);

      final UsageHistoryRead read = await UsageLogFiles.readRecent(
        agentId: 'agent_1',
        sessionId: 'session_1',
        lines: 5,
        override: path,
      );

      expect(read.ok, isTrue);
      expect(read.skippedLines, 0);
      expect(
        read.calls.map((UsageCallView c) => c.promptTokens).toList(),
        <int>[35, 36, 37, 38, 39],
      );
      // 最新一条在最后（面板按文件顺序渲染，最下面就是刚跑完的那次）。
      expect(read.calls.last.promptTokens, 39);
      expect(read.calls.last.at?.toUtc(), DateTime.utc(2026, 1, 2, 3, 4, 39));
    });

    test('lines <= 0 退化成 defaultLines（不崩、也不是"不要"）', () async {
      final String path = filePath();
      final int total = UsageLogFiles.defaultLines + 10;
      writeLines(path, <String>[
        for (int i = 0; i < total; i++)
          usageLine(
            at: '2026-01-02T03:04:05Z',
            source: 'turn',
            prompt: i,
          ),
      ]);

      for (final int lines in <int>[0, -1, -999]) {
        final UsageHistoryRead read = await UsageLogFiles.readRecent(
          agentId: 'agent_1',
          sessionId: 'session_1',
          lines: lines,
          override: path,
        );
        expect(read.ok, isTrue, reason: 'lines=$lines');
        expect(read.calls, hasLength(UsageLogFiles.defaultLines));
        expect(read.calls.first.promptTokens, total - UsageLogFiles.defaultLines);
        expect(read.calls.last.promptTokens, total - 1);
      }
    });

    test('账本超长：只读尾部 maxTailBytes，最后几行完整可用', () async {
      final String path = filePath();
      const int total = 4000;
      writeLines(path, <String>[
        for (int i = 0; i < total; i++)
          usageLine(
            at: '2026-01-02T03:04:05Z',
            source: 'llm.call',
            model: 'claude-sonnet-4-5-20250929',
            prompt: i,
            cached: i,
            completion: i,
            durationMs: i,
          ),
      ]);
      expect(
        await File(path).length(),
        greaterThan(UsageLogFiles.maxTailBytes),
      );

      final UsageHistoryRead read = await UsageLogFiles.readRecent(
        agentId: 'agent_1',
        sessionId: 'session_1',
        lines: 3,
        override: path,
      );

      expect(read.ok, isTrue);
      expect(
        read.calls.map((UsageCallView c) => c.promptTokens).toList(),
        <int>[total - 3, total - 2, total - 1],
      );
      expect(read.calls.last.durationMs, total - 1);
      // 截断点的半行被丢掉，不该被算成坏行。
      expect(read.skippedLines, 0);
    });

    test('id 非法 ⇒ ok=false + 可读 reason，且没去读任何文件', () async {
      // 这个 override 指向**真实存在且有好行**的账本：只要实现偷偷去读了，
      // calls 就不会是空。
      final String path = filePath();
      writeLines(path, <String>[
        usageLine(at: '2026-01-02T03:04:05Z', source: 'turn', prompt: 1234),
      ]);

      final UsageHistoryRead read = await UsageLogFiles.readRecent(
        agentId: '../escape',
        sessionId: 'session_1',
        override: path,
      );

      expect(read.ok, isFalse);
      expect(read.usageFile, isEmpty);
      expect(read.calls, isEmpty);
      expect(read.skippedLines, 0);
      expect(read.reason, isNotEmpty);
      expect(read.reason, contains('不合法'));

      final UsageHistoryRead badSession = await UsageLogFiles.readRecent(
        agentId: 'agent_1',
        sessionId: '..',
        override: path,
      );
      expect(badSession.ok, isFalse);
      expect(badSession.calls, isEmpty);
      expect(badSession.usageFile, isEmpty);
      expect(badSession.reason, contains('不合法'));
    });

    test('数据根不可用（不传 override）⇒ ok=false + 可读 reason', () async {
      expect(CoreProcessLauncher.instance.coreDataRoot, isEmpty);

      final UsageHistoryRead read = await UsageLogFiles.readRecent(
        agentId: 'agent_1',
        sessionId: 'session_1',
      );

      expect(read.ok, isFalse);
      expect(read.usageFile, isEmpty);
      expect(read.calls, isEmpty);
      expect(read.reason, contains('数据根'));
      expect(read.reason, contains('不猜'));
    });

    test('missingReason 给出路径与可能原因', () {
      final String path = filePath();
      final String reason = UsageLogFiles.missingReason(path);
      expect(reason, contains(path));
      expect(reason, contains('还没有 usage.jsonl'));
      expect(reason, contains('还没跑过 LLM 调用'));
    });
  });
}
