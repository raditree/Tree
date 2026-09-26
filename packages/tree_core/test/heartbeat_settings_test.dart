import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 心跳判活参数（M9 规约 1.1 收尾）：设置项 + 端点 + 运行期接线。
///
/// 三组断言对应三件事：
/// 1. CoreSettings：默认 I=10s / N=3（用户已确认）、各自绝对区间夹取、进
///    settings.yaml、未知键原样保留；
/// 2. **不变式**：判活窗口 I×N 必须**严格大于**前端固定的 10s WS 心跳
///    （lib/io/websocket_service.dart，本次不改），不足时必须夹取并给出可读原因——
///    否则"在线但空闲"的连接会被判失活、关连接、反复重连；
/// 3. 端点与运行期：GET/PATCH 的形状（当前值 + min/max + 窗口）、两个字段一起写、
///    CoreServer.start 默认读设置、保存后 WS 判活节拍**立即**生效（热更新）。
///
/// 单独一个文件而不是往 server_test.dart 里加：那份文件正被另一路并行修改。
void main() {
  group('CoreSettings 心跳判活参数', () {
    test('默认 10s / 3：判活窗口 30s，且没有任何夹取说明', () {
      final CoreSettings settings = CoreSettings();
      expect(settings.heartbeatIntervalSeconds, 10);
      expect(settings.missedHeartbeatLimit, 3);
      expect(settings.heartbeatInterval, const Duration(seconds: 10));
      expect(settings.livenessWindowSeconds, 30);
      expect(settings.livenessNotice, isNull);
      expect(
        CoreSettings.livenessWindowOk(
          settings.heartbeatIntervalSeconds,
          settings.missedHeartbeatLimit,
        ),
        isTrue,
      );
    });

    test('绝对区间夹取：I ∈ [1,600] 秒、N ∈ [1,60] 次（与帧率同风格，返回生效值）', () {
      final CoreSettings settings = CoreSettings();
      // 先把 N 放到上限，避免下面的 I 夹取触发"窗口修复"，好单独观察绝对区间
      expect(settings.setMissedHeartbeatLimit(60), 60);
      expect(settings.setHeartbeatIntervalSeconds(99999), 600);
      expect(settings.setHeartbeatIntervalSeconds(0), 1);
      expect(settings.heartbeatIntervalSeconds, 1);
      expect(settings.livenessNotice, isNotNull, reason: '夹取必须留下可读原因');
      expect(settings.livenessNotice, contains('心跳间隔'));

      // N 的区间：I=600 时窗口恒 > 10s，不会触发修复
      expect(settings.setHeartbeatIntervalSeconds(600), 600);
      expect(settings.setMissedHeartbeatLimit(999), 60);
      expect(settings.setMissedHeartbeatLimit(0), 1);
      expect(settings.missedHeartbeatLimit, 1);
      expect(settings.livenessNotice, contains('丢失阈值'));
    });

    test('不变式：I×N ≤ 10s 时抬高间隔并给出可读原因', () {
      final CoreSettings settings = CoreSettings();
      // 10s × 1 = 10s（不大于前端 10s 心跳）⇒ 把 I 抬到 11s（保留用户给的 N）
      expect(settings.setMissedHeartbeatLimit(1), 1);
      expect(settings.heartbeatIntervalSeconds, 11);
      expect(settings.missedHeartbeatLimit, 1, reason: '用户给的 N 保留');
      expect(settings.livenessWindowSeconds, 11);
      expect(
        settings.livenessWindowSeconds,
        greaterThan(CoreSettings.minLivenessWindowSeconds),
        reason: '窗口必须严格大于前端固定 10s 心跳',
      );
      expect(settings.livenessNotice, contains('判活窗口'));
      expect(settings.livenessNotice, contains('误判失活'));
    });

    test('两个字段一起写：一次结算，不经过非法中间态', () {
      final CoreSettings settings = CoreSettings();
      expect(settings.setLiveness(intervalSeconds: 4, missedLimit: 3), (
        intervalSeconds: 4,
        missedLimit: 3,
      ));
      expect(settings.livenessWindowSeconds, 12);
      expect(settings.livenessNotice, isNull, reason: '没夹取就没有说明');

      // 5s × 2 = 10s ≤ 10s ⇒ 抬 I 到 6s
      expect(settings.setLiveness(intervalSeconds: 5, missedLimit: 2), (
        intervalSeconds: 6,
        missedLimit: 2,
      ));
      expect(settings.livenessWindowSeconds, 12);
      expect(settings.livenessNotice, contains('6s'));

      // 只给一个字段：另一个保持原值；这次合法，旧说明要被清掉
      expect(settings.setLiveness(intervalSeconds: 12), (
        intervalSeconds: 12,
        missedLimit: 2,
      ));
      expect(settings.livenessNotice, isNull);
    });

    test('最小可行间隔与窗口判定是同一套公式（端点/UI 预校验同口径）', () {
      expect(CoreSettings.minimumIntervalSecondsFor(1), 11);
      expect(CoreSettings.minimumIntervalSecondsFor(3), 4);
      expect(CoreSettings.minimumIntervalSecondsFor(10), 2);
      expect(CoreSettings.minimumIntervalSecondsFor(11), 1);
      expect(
        CoreSettings.minimumIntervalSecondsFor(0),
        CoreSettings.heartbeatIntervalMax,
        reason: 'N ≤ 0 不可能满足，给上限而不是死循环',
      );
      for (final int limit in <int>[1, 2, 3, 7, 10, 11, 60]) {
        final int interval = CoreSettings.minimumIntervalSecondsFor(limit);
        expect(interval, lessThanOrEqualTo(CoreSettings.heartbeatIntervalMax));
        expect(CoreSettings.livenessWindowOk(interval, limit), isTrue);
      }
      expect(
        CoreSettings.livenessWindowOk(10, 1),
        isFalse,
        reason: '10×1 = 10 不够（必须严格大于）',
      );
      expect(
        CoreSettings.livenessWindowOk(5, 2),
        isFalse,
        reason: '5×2 = 10 不够',
      );
      expect(CoreSettings.livenessWindowOk(2, 5), isFalse);
      expect(
        CoreSettings.livenessWindowOk(10, 10),
        isTrue,
        reason: '10×10 = 100 够',
      );
      expect(CoreSettings.livenessWindowOk(11, 1), isTrue);
      expect(CoreSettings.livenessWindowOk(0, 60), isFalse);
    });

    test('落盘：每次写入通知一次 settings.yaml', () {
      final _RecordingSink sink = _RecordingSink();
      final CoreSettings settings = CoreSettings()..sink = sink;
      settings.setHeartbeatIntervalSeconds(20);
      settings.setMissedHeartbeatLimit(5);
      settings.setLiveness(intervalSeconds: 30, missedLimit: 6);
      expect(sink.settingsSaved, 3);
      expect(settings.heartbeatIntervalSeconds, 30);
      expect(settings.missedHeartbeatLimit, 6);
    });

    test('不变式的前提没变：前端 WS 心跳仍是 10s', () {
      // 跨仓约束（M9 收口）：前端心跳间隔必须**小于**服务端的判活窗口 I×N。
      // 前端这一侧固定在 10s（lib/io/websocket_service.dart，本次不动），
      // CoreSettings.minLivenessWindowSeconds 就是照它定的——哪一侧改了这里都会红，
      // 逼着两侧一起改，避免"核心判活窗口比前端心跳还短"重新出现。
      final File source = File('../../lib/io/websocket_service.dart');
      expect(source.existsSync(), isTrue, reason: '找不到前端 WS 服务源码（仓库布局变了？）');
      final String src = source.readAsStringSync();
      final int timer = src.indexOf('_heartbeatTimer = Timer.periodic(');
      expect(timer, greaterThanOrEqualTo(0), reason: '前端心跳定时器不见了：判活口径的前提变了');
      final String around = src.substring(
        timer,
        timer + 200 > src.length ? src.length : timer + 200,
      );
      final RegExpMatch? seconds = RegExp(r'Duration\(seconds: (\d+)\)')
          .firstMatch(around);
      expect(seconds, isNotNull, reason: '没读出前端心跳间隔');
      expect(
        int.parse(seconds!.group(1)!),
        CoreSettings.minLivenessWindowSeconds,
        reason: '前端心跳间隔变了：请同步 CoreSettings.minLivenessWindowSeconds 与两侧注释',
      );
    });
  });

  group('CoreSettings 与 settings.yaml 的映射', () {
    test('applyMap / toMap 往返；未知键仍进 extra 并写回', () {
      final CoreSettings settings = CoreSettings();
      settings.applyMap(<String, dynamic>{
        'heartbeat_interval': 30,
        'missed_heartbeat_limit': 4,
        'my_custom_key': 'x',
      });
      expect(settings.heartbeatIntervalSeconds, 30);
      expect(settings.missedHeartbeatLimit, 4);
      expect(settings.livenessWindowSeconds, 120);
      expect(settings.livenessNotice, isNull);
      expect(settings.extra.keys, contains('my_custom_key'));
      expect(
        settings.extra.keys,
        isNot(contains('heartbeat_interval')),
        reason: '已知键不该留在 extra 里（否则保存时会写两份）',
      );
      final Map<String, dynamic> out = settings.toMap();
      expect(out['heartbeat_interval'], 30);
      expect(out['missed_heartbeat_limit'], 4);
      final CoreSettings again = CoreSettings()..applyMap(out);
      expect(again.toMap(), out);
    });

    test('手改 yaml 的越界值被夹取，非法组合被修好并留下可读原因', () {
      final CoreSettings clamped = CoreSettings()
        ..applyMap(<String, dynamic>{
          'heartbeat_interval': 99999,
          'missed_heartbeat_limit': 999,
        });
      expect(
        clamped.heartbeatIntervalSeconds,
        CoreSettings.heartbeatIntervalMax,
      );
      expect(
        clamped.missedHeartbeatLimit,
        CoreSettings.missedHeartbeatLimitMax,
      );
      expect(clamped.livenessNotice, isNotNull);

      final CoreSettings repaired = CoreSettings()
        ..applyMap(<String, dynamic>{
          'heartbeat_interval': 1,
          'missed_heartbeat_limit': 1,
        });
      expect(
        repaired.heartbeatIntervalSeconds,
        11,
        reason: '窗口 1s ≤ 10s ⇒ 抬 I',
      );
      expect(repaired.missedHeartbeatLimit, 1);
      expect(repaired.livenessNotice, isNotNull);
      expect(
        repaired.toMap()['heartbeat_interval'],
        11,
        reason: '下一次保存写回的是修好的值',
      );
    });

    test('宽容解析：字符串数字生效，非法值回默认（与帧率一致）', () {
      final CoreSettings settings = CoreSettings()
        ..applyMap(<String, dynamic>{
          'heartbeat_interval': '45',
          'missed_heartbeat_limit': '2',
        });
      expect(settings.heartbeatIntervalSeconds, 45);
      expect(settings.missedHeartbeatLimit, 2);
      expect(settings.livenessNotice, isNull);

      settings.applyMap(<String, dynamic>{
        'heartbeat_interval': 'abc',
        'missed_heartbeat_limit': null,
      });
      expect(settings.heartbeatIntervalSeconds, 10);
      expect(settings.missedHeartbeatLimit, 3);
      expect(settings.livenessNotice, isNull, reason: '回默认值本身就是合法的');
    });
  });

  group('心跳判活端点', () {
    late CoreServer server;
    late _Client client;

    setUp(() async {
      server = await CoreServer.start(
        streamChunkDelay: Duration.zero,
        enableHeartbeat: false,
      );
      client = _Client(server);
    });

    tearDown(() async {
      client.close();
      await server.close();
    });

    test('GET：当前值 + 各自区间 + 判活窗口 + 在线生效值', () async {
      final _Res res = await client.send(
        'GET',
        ApiPaths.settingsHeartbeatInterval,
      );
      expect(res.status, 200);
      expect(res.json['heartbeat_interval'], 10);
      expect(res.json['missed_heartbeat_limit'], 3);
      expect(res.json['min'], CoreSettings.heartbeatIntervalMin);
      expect(res.json['max'], CoreSettings.heartbeatIntervalMax);
      expect(
        res.json['heartbeat_interval_min'],
        CoreSettings.heartbeatIntervalMin,
      );
      expect(
        res.json['heartbeat_interval_max'],
        CoreSettings.heartbeatIntervalMax,
      );
      expect(
        res.json['missed_heartbeat_limit_min'],
        CoreSettings.missedHeartbeatLimitMin,
      );
      expect(
        res.json['missed_heartbeat_limit_max'],
        CoreSettings.missedHeartbeatLimitMax,
      );
      expect(res.json['window_seconds'], 30);
      expect(
        res.json['min_window_seconds'],
        CoreSettings.minLivenessWindowSeconds,
      );
      expect(res.json['live_interval_seconds'], 10);
      expect(res.json['live_miss_limit'], 3);
      expect(res.json.containsKey('notice'), isFalse, reason: '没夹取就没有说明');

      // 另一个端点同形状，只是 min/max 描述它自己那一项
      final _Res limit = await client.send(
        'GET',
        ApiPaths.settingsMissedHeartbeatLimit,
      );
      expect(limit.status, 200);
      expect(limit.json['min'], CoreSettings.missedHeartbeatLimitMin);
      expect(limit.json['max'], CoreSettings.missedHeartbeatLimitMax);
      expect(limit.json['heartbeat_interval'], 10);
      expect(limit.json['missed_heartbeat_limit'], 3);
    });

    test('PATCH：绝对区间夹取后返回新值，越界带 notice', () async {
      final _Res res = await client.send(
        'PATCH',
        ApiPaths.settingsHeartbeatInterval,
        body: <String, dynamic>{'heartbeat_interval': 99999},
      );
      expect(res.status, 200);
      expect(res.json['heartbeat_interval'], CoreSettings.heartbeatIntervalMax);
      expect(res.json['notice'], isNotNull);
      expect(res.json['notice'].toString(), contains('已夹到'));

      // 只给一个字段时另一个不动（部分更新语义）
      final _Res one = await client.send(
        'PATCH',
        ApiPaths.settingsHeartbeatInterval,
        body: <String, dynamic>{'missed_heartbeat_limit': 1},
      );
      expect(one.status, 200);
      expect(one.json['heartbeat_interval'], CoreSettings.heartbeatIntervalMax);
      expect(one.json['missed_heartbeat_limit'], 1);
    });

    test('不变式落到端点上：I×N ≤ 10s 被抬高，响应给可读原因', () async {
      // 600s × 1 是合法的，先把 N 压到 1
      await client.send(
        'PATCH',
        ApiPaths.settingsHeartbeatInterval,
        body: <String, dynamic>{'missed_heartbeat_limit': 1},
      );
      // 再把 I 设成 10s：窗口 10s 不满足 > 10s ⇒ 抬到 11s
      final _Res res = await client.send(
        'PATCH',
        ApiPaths.settingsHeartbeatInterval,
        body: <String, dynamic>{'heartbeat_interval': 10},
      );
      expect(res.status, 200);
      expect(res.json['heartbeat_interval'], 11);
      expect(res.json['missed_heartbeat_limit'], 1);
      expect(res.json['window_seconds'], 11);
      expect(res.json['notice'].toString(), contains('判活窗口'));
      expect(res.json['notice'].toString(), contains('误判失活'));
      expect(
        (res.json['window_seconds'] as int) >
            (res.json['min_window_seconds'] as int),
        isTrue,
        reason: '响应里的窗口必须真的大于 10s',
      );
    });

    test('两个字段可以一起写（任一端点都行）', () async {
      final _Res res = await client.send(
        'PATCH',
        ApiPaths.settingsMissedHeartbeatLimit,
        body: <String, dynamic>{
          'heartbeat_interval': 4,
          'missed_heartbeat_limit': 5,
        },
      );
      expect(res.status, 200);
      expect(res.json['heartbeat_interval'], 4);
      expect(res.json['missed_heartbeat_limit'], 5);
      expect(res.json['window_seconds'], 20);
      expect(res.json.containsKey('notice'), isFalse);

      // POST 是同一处理器的别名（与帧率端点的调用习惯一致）
      final _Res post = await client.send(
        'POST',
        ApiPaths.settingsHeartbeatInterval,
        body: <String, dynamic>{'heartbeat_interval': 20},
      );
      expect(post.status, 200);
      expect(post.json['heartbeat_interval'], 20);
      expect(post.json['missed_heartbeat_limit'], 5);

      // 落到设置对象（= 下次写盘的内容）
      expect(server.settings.heartbeatIntervalSeconds, 20);
      expect(server.settings.toMap()['heartbeat_interval'], 20);
    });

    test('缺字段 / 非法值 = 不改该项（不静默改成下限）', () async {
      final _Res empty = await client.send(
        'PATCH',
        ApiPaths.settingsHeartbeatInterval,
        body: <String, dynamic>{},
      );
      expect(empty.status, 200);
      expect(empty.json['heartbeat_interval'], 10);
      expect(empty.json['missed_heartbeat_limit'], 3);

      final _Res bad = await client.send(
        'PATCH',
        ApiPaths.settingsHeartbeatInterval,
        body: <String, dynamic>{'heartbeat_interval': 'abc'},
      );
      expect(bad.status, 200);
      expect(
        bad.json['heartbeat_interval'],
        10,
        reason: '非法值不该被当成 0 再夹到下限（那等于悄悄改了配置）',
      );
    });
  });

  group('运行期接线（WS 判活）', () {
    test('CoreServer.start 的心跳参数默认读设置', () async {
      final CoreSettings settings = CoreSettings()
        ..applyMap(<String, dynamic>{
          'heartbeat_interval': 20,
          'missed_heartbeat_limit': 5,
        });
      final CoreServer server = await CoreServer.start(
        streamChunkDelay: Duration.zero,
        settings: settings,
      );
      addTearDown(server.close);
      expect(server.liveHeartbeatInterval, const Duration(seconds: 20));
      expect(server.liveHeartbeatMissLimit, 5);
      final LivenessWsHub hub = server.hub as LivenessWsHub;
      expect(hub.interval, const Duration(seconds: 20), reason: '判活节拍来自设置');
      expect(hub.linkLiveness.maxMisses, 5, reason: '丢失阈值来自设置');
    });

    test('保存后立即生效：在跑的判活节拍被热更新', () async {
      final CoreServer server = await CoreServer.start(
        streamChunkDelay: Duration.zero,
      );
      addTearDown(server.close);
      expect(server.liveHeartbeatInterval, const Duration(seconds: 10));
      final _Client client = _Client(server);
      addTearDown(client.close);

      final _Res res = await client.send(
        'PATCH',
        ApiPaths.settingsHeartbeatInterval,
        body: <String, dynamic>{'heartbeat_interval': 4},
      );
      expect(res.status, 200);
      expect(
        server.liveHeartbeatInterval,
        const Duration(seconds: 4),
        reason: '不必重启核心：节拍跟着设置走',
      );
      expect(res.json['live_interval_seconds'], 4);
      expect(server.liveHeartbeatMissLimit, 3);
    });

    test('显式传参是逃生口：设置变更不改动调用方指定的节拍', () async {
      final CoreServer server = await CoreServer.start(
        streamChunkDelay: Duration.zero,
        heartbeatInterval: const Duration(milliseconds: 60),
        heartbeatMissLimit: 2,
      );
      addTearDown(server.close);
      expect(server.liveHeartbeatInterval, const Duration(milliseconds: 60));
      expect(server.liveHeartbeatMissLimit, 2);
      final _Client client = _Client(server);
      addTearDown(client.close);

      await client.send(
        'PATCH',
        ApiPaths.settingsHeartbeatInterval,
        body: <String, dynamic>{'heartbeat_interval': 30},
      );
      expect(
        server.liveHeartbeatInterval,
        const Duration(milliseconds: 60),
        reason: '显式传参优先，且不参与热更新',
      );
      expect(server.settings.heartbeatIntervalSeconds, 30, reason: '设置本身写进去了');
    });

    test('保活关着时不热更新（不会把定时器重新打开）', () async {
      final CoreServer server = await CoreServer.start(
        streamChunkDelay: Duration.zero,
        enableHeartbeat: false,
      );
      addTearDown(server.close);
      final _Client client = _Client(server);
      addTearDown(client.close);

      await client.send(
        'PATCH',
        ApiPaths.settingsHeartbeatInterval,
        body: <String, dynamic>{'heartbeat_interval': 4},
      );
      expect(server.settings.heartbeatIntervalSeconds, 4);
      expect(
        server.liveHeartbeatInterval,
        const Duration(seconds: 10),
        reason: 'enableHeartbeat: false 时行为与旧版一致：不判活、不动定时器',
      );
    });
  });
}

/// 记录落盘调用的假 sink（照 settings_test.dart 的写法，保持本文件自足）。
class _RecordingSink implements CoreSettingsSink {
  int settingsSaved = 0;

  @override
  void saveSettings(CoreSettings settings) => settingsSaved++;

  @override
  void saveModel(CoreModelConfig model) {}

  @override
  void deleteModel(String modelId) {}

  @override
  Future<void> flush() async {}
}

/// 极简 HTTP 客户端（与 server_test.dart 里的同名实现等价，避免依赖另一路在改的文件）。
class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse(_server.handshake.httpBaseUrl + path),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_server.token}',
    );
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder.bind(response).join();
    return _Res(
      response.statusCode,
      text.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  void close() => _http.close(force: true);
}

class _Res {
  const _Res(this.status, this.json);

  final int status;
  final Map<String, dynamic> json;

  @override
  String toString() => 'HTTP $status $json';
}
