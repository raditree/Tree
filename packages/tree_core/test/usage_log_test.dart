import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// **`usage.jsonl` 的落盘与读取**（逐调用用量账本的存储层）。
///
/// 口径：一行一次调用；字段表见 `UsageCall.toJson()`（= 插件面板消费的对外契约）；
/// 读取**容错**——文件不存在不是错误、坏行跳过并计数，绝不因为一行坏数据读不出来。
void main() {
  late Directory root;
  late TreePaths paths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tree_usage_log_');
    paths = TreePaths(root.path);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String usagePath([String agent = 'agt_1', String session = 'ses_1']) =>
      paths.usageFile(agent, session);

  List<Map<String, dynamic>> linesOf(String path) => <Map<String, dynamic>>[
    for (final String line in const LineSplitter().convert(
      File(path).readAsStringSync(),
    ))
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
  ];

  UsageCall call({
    String source = UsageSource.turn,
    String model = 'demo',
    int prompt = 100,
    int? cached,
    int completion = 7,
    bool estimated = false,
    int durationMs = 1234,
  }) => UsageCall(
    at: DateTime(2026, 10, 3, 17, 20, 31),
    source: source,
    model: model,
    promptTokens: prompt,
    cachedTokens: cached,
    completionTokens: completion,
    estimated: estimated,
    durationMs: durationMs,
  );

  test('路径与会话数据同目录（删会话天然带走它）', () {
    expect(
      usagePath(),
      p.join(paths.sessionDir('agt_1', 'ses_1'), 'usage.jsonl'),
    );
    expect(p.dirname(usagePath()), p.dirname(paths.messagesFile('agt_1', 'ses_1')));
  });

  test('record 追加一行：字段表齐全、cached 留空不编造 0', () async {
    final UsageLog log = UsageLog(paths);
    log.record('agt_1', 'ses_1', call(cached: null));
    log.record(
      'agt_1',
      'ses_1',
      call(source: UsageSource.compact, cached: 128, estimated: true, model: 'm2'),
    );
    await log.flush();

    final List<Map<String, dynamic>> lines = linesOf(usagePath());
    expect(lines, hasLength(2), reason: '一行一次调用，顺序与调用顺序一致');
    expect(lines.first.keys.toSet(), <String>{
      'at',
      'source',
      'model',
      'prompt_tokens',
      'cached_tokens',
      'completion_tokens',
      'estimated',
      'duration_ms',
    }, reason: '字段表就是对外契约（插件面板按它消费）');
    expect(lines.first['cached_tokens'], isNull, reason: '端点没给 ⇒ null，不编造 0');
    expect(lines.first['estimated'], isFalse);
    expect(lines.first['duration_ms'], 1234);
    expect(lines.last['source'], 'compact');
    expect(lines.last['cached_tokens'], 128);
    expect(lines.last['estimated'], isTrue);
    expect(
      DateTime.tryParse(lines.first['at'] as String),
      DateTime(2026, 10, 3, 17, 20, 31),
      reason: 'at 是 ISO-8601（与 session.json / messages.jsonl 同口径）',
    );
  });

  test('sinkFor 绑定会话：形状与 LlmSummarizer / LlmJsonCaller 的 usageSink 一致', () async {
    final UsageLog log = UsageLog(paths);
    final UsageSink sink = log.sinkFor('ses_9');
    sink('agt_7', call(source: UsageSource.llmCall));
    await log.flush();
    expect(File(usagePath('agt_7', 'ses_9')).existsSync(), isTrue);
  });

  test('读回：往返一致', () async {
    final UsageLog log = UsageLog(paths);
    log.record('agt_1', 'ses_1', call(cached: 12));
    log.record('agt_1', 'ses_1', call(source: UsageSource.plugin, cached: null));
    await log.flush();

    final UsageHistory history = await UsageLog.read(paths, 'agt_1', 'ses_1');
    expect(history.skipped, 0);
    expect(history.calls, hasLength(2));
    expect(history.calls.first.promptTokens, 100);
    expect(history.calls.first.cachedTokens, 12);
    expect(history.calls.first.completionTokens, 7);
    expect(history.calls.first.model, 'demo');
    expect(history.calls.last.source, UsageSource.plugin);
    expect(history.calls.last.cachedTokens, isNull);
  });

  test('文件不存在 ⇒ 空账本（老会话本来就没有它，不是错误）', () async {
    final UsageHistory history = await UsageLog.read(paths, 'agt_1', 'ses_1');
    expect(history.isEmpty, isTrue);
    expect(history.skipped, 0);
  });

  test('坏行容错：非 JSON / 缺 source / 缺 at 的行跳过并计数，好行照读', () async {
    final String path = usagePath();
    Directory(p.dirname(path)).createSync(recursive: true);
    File(path).writeAsStringSync(
      <String>[
        '这不是 JSON',
        '{"at":"2026-10-03T10:00:00.000","source":"turn",'
            '"model":"demo","prompt_tokens":11,"cached_tokens":null,'
            '"completion_tokens":2,"estimated":true,"duration_ms":5}',
        '{"source":"compact","prompt_tokens":1}', // 缺 at
        '{"at":"2026-10-03T10:00:01.000"}', // 缺 source
        '',
        '[1,2,3]', // 合法 JSON 但不是对象
      ].join('\n'),
    );

    final UsageHistory history = await UsageLog.read(paths, 'agt_1', 'ses_1');
    expect(history.calls, hasLength(1));
    expect(history.calls.single.promptTokens, 11);
    expect(history.skipped, 4, reason: '坏行必须计数，绝不静默丢');
  });

  test('只读尾部：账本变长后仍能拿到最近的那些', () async {
    final UsageLog log = UsageLog(paths);
    for (int i = 0; i < 40; i++) {
      log.record(
        'agt_1',
        'ses_1',
        call(prompt: i, durationMs: i),
      );
    }
    await log.flush();

    final UsageHistory all = await UsageLog.read(paths, 'agt_1', 'ses_1');
    expect(all.calls, hasLength(40));
    expect(all.calls.last.promptTokens, 39);

    final UsageHistory tail = await UsageLog.read(
      paths,
      'agt_1',
      'ses_1',
      tailBytes: 200,
    );
    expect(tail.calls.length, lessThan(40), reason: '只读尾部若干字节');
    expect(tail.calls.last.promptTokens, 39, reason: '最新一条必须在');
  });

  test('手改的宽容度：at 写成毫秒整数 / 数字字符串都能读', () {
    final UsageCall? byInt = UsageCall.tryFromJson(<String, dynamic>{
      'at': 1759500000000,
      'source': 'turn',
      'prompt_tokens': 3,
    });
    expect(byInt, isNotNull);
    expect(byInt!.at.millisecondsSinceEpoch, 1759500000000);
    final UsageCall? byString = UsageCall.tryFromJson(<String, dynamic>{
      'at': '2026-10-03T10:00:00.000',
      'source': 'turn',
      'prompt_tokens': '7',
      'cached_tokens': '9',
      'completion_tokens': '2',
    });
    expect(byString?.promptTokens, 7);
    expect(byString?.cachedTokens, 9);
    expect(byString?.completionTokens, 2);
  });

  test('路径非法（id 过不了防穿越校验）不抛，只记一句日志', () async {
    final List<String> logs = <String>[];
    final UsageLog log = UsageLog(paths, log: logs.add);
    log.record('../escape', 'ses_1', call());
    await log.flush();
    expect(logs, hasLength(1));
    expect(logs.single, contains('用量落盘跳过'));
    expect(File(p.join(root.path, '..', 'escape')).existsSync(), isFalse);
  });

  test('UsageSource 取值表就是契约', () {
    expect(UsageSource.all, <String>['turn', 'compact', 'llm.call', 'plugin']);
  });
}
