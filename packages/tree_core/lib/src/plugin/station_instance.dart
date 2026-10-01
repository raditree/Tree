import 'dart:async';

import 'station_runtime.dart';
import 'station_schema.dart';
import 'station_scope.dart';

/// 站点实例（M9 §3，用户定稿）：
///
/// - **站点 = 持久化实例**：实例自带 id / 类型 / schema（收集站必填）/ 订阅上限 /
///   scope 绑定 / 订阅者列表，落盘跨重启保留（station_store.dart）；
/// - **触发 = 实例的一个方法**：可在任意位置、任意时机被调用；「触发时机」不由
///   站点类型决定，而由**挂载位置的具体逻辑**决定（例如收集站的触发方是工具表
///   刷新处，收集站的「后续处理」也由触发方负责——站点内部不做管线）；
/// - 四类站：广播站 / 执行站 / 中转站 / 收集站（sealed 子类各带自己的 trigger）。
///
/// 隔离：所有 trigger 的第一件事都是四元组校验（StationIsolation，fail-closed），
/// 校验不过的消息**不投递**并给出可读原因。
sealed class StationInstance {
  StationInstance({
    required this.id,
    required this.description,
    required this.scope,
    this.maxSubscriptions = defaultMaxSubscriptions,
    this.builtin = false,
    int? createdAt,
    List<StationSubscriber>? subscribers,
  }) : createdAt = createdAt ?? nowSeconds(),
       subscribers = subscribers ?? <StationSubscriber>[];

  /// 默认订阅上限（实例自带；<= 0 表示不限制）。
  static const int defaultMaxSubscriptions = 32;

  /// 站点 id（**含 scope 归属**：同一类型在每个 team×mode 上是不同实例）。
  final String id;

  /// 展示说明（人可读；会出现在前端「站点」面板）。
  ///
  /// 命名变更（M9）：旧文档里的「处理站」= 现在的**中转站**；此外还有
  /// 广播站、执行站、收集站，面板按 kind 分组显示。
  final String description;

  /// scope 绑定（站点实例归属的四元组；消息必须与它相容才投递）。
  final StationScope scope;

  /// 订阅上限（**实例自带**，不是全局值；超限拒绝订阅并显式报错）。
  final int maxSubscriptions;

  /// 是否系统自带（内置四站为 true；插件自建为 false）。
  final bool builtin;

  /// 创建时间（epoch 秒）。
  final int createdAt;

  /// 订阅者列表（持久化字段；身份 = plugin_id + scope）。
  final List<StationSubscriber> subscribers;

  /// 分类计数（不落盘；重启归零）。
  final StationCounters counters = StationCounters();

  /// 正在等待回包的请求数（观测用；前端面板显示「等待中」）。
  int waitsInFlight = 0;

  /// 运行时绑定：回包函数（pluginId|scopeKey → responder）；不落盘。
  final Map<String, StationResponder> _responders =
      <String, StationResponder>{};

  /// 运行时绑定：活性探针（默认「无信息」，站点退回活性窗口兜底）。
  StationLivenessProbe liveness = _unknownLiveness;

  /// 运行时绑定：探测节拍（轮询订阅者心跳的间隔；**不是**任务总时长）。
  Duration livenessProbeInterval = const Duration(seconds: 1);

  /// 运行时绑定：活性窗口（I×N；只在「没有活性信息」时兜底，心跳在则续期）。
  Duration livenessWindow = const Duration(seconds: 30);

  /// 运行时绑定：实例被修改（订阅变化 / 公告板变化）后的回调 → 落盘。
  void Function()? onMutated;

  /// 站点类型。
  StationKind get kind;

  /// 是否强制「站 × scope 键位唯一」（只有中转站是：先到先得）。
  bool get scopeKeyUnique => false;

  /// 子类附加持久化字段。
  Map<String, dynamic> extraJson() => const <String, dynamic>{};

  /// 子类附加快照字段（前端面板 / 调试）。
  Map<String, dynamic> extraDescribe() => const <String, dynamic>{};

  // ------------------------------------------------------------------
  // 订阅管理（由 StationHub 统一调用；插件下线走 unsubscribePlugin）
  // ------------------------------------------------------------------

  /// 订阅本站点。
  ///
  /// - 执行站不支持订阅（显式拒绝）；
  /// - 订阅声明 scope 必须与站点绑定相容（不得放大到其它 team / mode）；
  /// - 超订阅上限 ⇒ 拒绝并显式报错（code = subscription_limit）；
  /// - 中转站（[scopeKeyUnique]）同键位第二人 ⇒ 先到先得拒绝（code = key_conflict），
  ///   显式 replace = true 时替换并回报被替换者。
  StationSubResult subscribe(
    StationSubscriber subscriber,
    StationResponder responder, {
    bool replace = false,
  }) {
    if (!kind.subscribable) {
      return StationSubResult.rejected(
        '$id 是${kind.label}：不支持订阅（执行站由插件主动下命令）',
        code: 'not_subscribable',
      );
    }
    final StationIsolationVerdict verdict = StationIsolation.checkMessage(
      station: scope,
      message: subscriber.scope,
    );
    if (!verdict.ok) {
      counters.bump('skipped_scope');
      return StationSubResult.rejected(verdict.reason, code: 'scope_mismatch');
    }
    // 身份 = plugin_id + scope：同插件同 scope 重复订阅 = 幂等更新回包函数。
    final int sameIdentity = subscribers.indexWhere(
      (StationSubscriber s) => s.key == subscriber.key,
    );
    if (sameIdentity >= 0) {
      subscribers[sameIdentity] = subscriber;
      _responders[subscriber.key] = responder;
      onMutated?.call();
      return const StationSubResult.accepted();
    }
    // 中转站：**站 × scope 键位唯一**（先到先得 / 显式 replace）。
    String replaced = '';
    if (scopeKeyUnique) {
      final int sameScope = subscribers.indexWhere(
        (StationSubscriber s) => s.scope.key == subscriber.scope.key,
      );
      if (sameScope >= 0) {
        final StationSubscriber existing = subscribers[sameScope];
        if (!replace) {
          counters.bump('rejected_conflict');
          return StationSubResult.rejected(
            '$id 的键位（${subscriber.scope.key}）已被 ${existing.pluginId} 占用'
            '（先到先得）；如需接管请显式 replace',
            code: 'key_conflict',
          );
        }
        _responders.remove(existing.key);
        subscribers.removeAt(sameScope);
        replaced = existing.pluginId;
      }
    }
    if (maxSubscriptions > 0 && subscribers.length >= maxSubscriptions) {
      counters.bump('overflow');
      return StationSubResult.rejected(
        '$id（${kind.label}）的订阅上限（$maxSubscriptions）已满，'
        '拒绝 ${subscriber.pluginId} 订阅',
        code: 'subscription_limit',
      );
    }
    subscribers.add(subscriber);
    _responders[subscriber.key] = responder;
    onMutated?.call();
    return StationSubResult.accepted(replacedPluginId: replaced);
  }

  /// 退订一个键位（plugin_id + scope）；返回是否真的移除了。
  bool unsubscribeKey(String key) {
    final int index = subscribers.indexWhere(
      (StationSubscriber s) => s.key == key,
    );
    if (index < 0) return false;
    subscribers.removeAt(index);
    _responders.remove(key);
    counters.bump('unsubscribed');
    onMutated?.call();
    return true;
  }

  /// **插件下线**：注销该插件的全部订阅（由总线在插件退出 / 停用时调用）。
  int unsubscribePlugin(String pluginId) {
    final List<StationSubscriber> removed = subscribers
        .where((StationSubscriber s) => s.pluginId == pluginId)
        .toList(growable: false);
    if (removed.isEmpty) return 0;
    for (final StationSubscriber sub in removed) {
      subscribers.remove(sub);
      _responders.remove(sub.key);
    }
    counters.bump('unsubscribed', removed.length);
    onMutated?.call();
    return removed.length;
  }

  /// 取某订阅键位的回包函数（不存在返回 null）。
  StationResponder? responderFor(String key) => _responders[key];

  /// 全部键位（调试 / 测试）。
  List<String> get subscriberKeys =>
      subscribers.map((StationSubscriber s) => s.key).toList(growable: false);

  // ------------------------------------------------------------------
  // 等待回包（心跳判活；无静态任务上限）
  // ------------------------------------------------------------------

  /// 等待订阅者回包。
  ///
  /// 判据（plan §1.1 站点部分：**取消硬超时，改心跳保活**）：
  /// - 订阅者心跳丢失 ⇒ 立即判「未响应（心跳丢失）」，不阻塞后续；
  /// - 订阅者心跳在 ⇒ 窗口**续期**，跑多久都不算超时（长任务不被时间杀）；
  /// - 探针无信息（进程内假订阅者）⇒ 用活性窗口 [livenessWindow] 兜底，
  ///   超窗判「窗口内无回」。
  Future<StationReply> awaitReply({
    required StationSubscriber subscriber,
    required StationRequest request,
  }) {
    final StationResponder? responder = _responders[subscriber.key];
    if (responder == null) {
      return Future<StationReply>.value(
        const StationReply.failed('订阅者已不在本站（订阅可能已被注销）'),
      );
    }
    waitsInFlight++;
    final Completer<StationReply> completer = Completer<StationReply>();
    Future<void>(() async {
      try {
        final StationReply reply = await responder(request);
        if (!completer.isCompleted) completer.complete(reply);
      } catch (error) {
        if (!completer.isCompleted) {
          completer.complete(StationReply.failed('订阅者处理异常：$error'));
        }
      }
    });
    unawaited(_watchLiveness(subscriber, completer));
    return completer.future.whenComplete(() {
      waitsInFlight--;
    });
  }

  /// 心跳观察循环（只在「有活性信息且已失活」或「无信息且超窗」时终结等待）。
  Future<void> _watchLiveness(
    StationSubscriber subscriber,
    Completer<StationReply> completer,
  ) async {
    final DateTime started = DateTime.now();
    while (!completer.isCompleted) {
      await Future<void>.delayed(livenessProbeInterval);
      if (completer.isCompleted) return;
      final StationLivenessState state = liveness(subscriber.pluginId);
      if (state.known) {
        if (!state.alive) {
          final String detail = state.detail.isEmpty ? '连续未达' : state.detail;
          completer.complete(StationReply.failed('订阅者心跳丢失（$detail）'));
          return;
        }
        continue; // 心跳在 ⇒ 窗口续期（不因总时长判超时）
      }
      if (DateTime.now().difference(started) >= livenessWindow) {
        completer.complete(
          StationReply.failed(
            '活性窗口（${livenessWindow.inMilliseconds}ms）内无回，'
            '且订阅者无心跳信息',
          ),
        );
        return;
      }
    }
  }

  static StationLivenessState _unknownLiveness(String pluginId) =>
      const StationLivenessState.unknown();

  /// 当前时间（epoch 秒）。
  static int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// 隔离校验（子类 trigger 的第一道闸）。
  StationIsolationVerdict checkScope(StationScope message) =>
      StationIsolation.checkMessage(station: scope, message: message);

  // ------------------------------------------------------------------
  // 持久化 / 快照
  // ------------------------------------------------------------------

  /// 持久化 JSON（落盘 yaml 的一项）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'kind': kind.wire,
    'description': description,
    'scope': scope.toJson(),
    'max_subscriptions': maxSubscriptions,
    if (builtin) 'builtin': true,
    'created_at': createdAt,
    'subscribers': subscribers
        .map((StationSubscriber s) => s.toJson())
        .toList(),
    ...extraJson(),
  };

  /// 前端快照形状（与既有 PluginStationInfo 的宽容解析对齐）。
  Map<String, dynamic> describe() => <String, dynamic>{
    'station_id': id,
    'kind': kind.wire,
    'kind_label': kind.label,
    'description': description,
    'scope': scope.toJson(),
    'builtin': builtin,
    'max_subscriptions': maxSubscriptions,
    'subscriber_count': subscribers.length,
    'subscriptions': subscribers
        .map((StationSubscriber s) => s.describe())
        .toList(),
    'counts': counters.describe(),
    'gauges': <String, dynamic>{'waits_in_flight': waitsInFlight},
    ...extraDescribe(),
  };

  /// 从持久化 JSON 恢复；kind 未知 / id 缺失返回 null（跳过该条而不是整库失败）。
  static StationInstance? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final String id = (raw['id'] ?? raw['station_id'] ?? '').toString().trim();
    if (id.isEmpty) return null;
    final StationKind? kind = StationKind.fromWire(raw['kind']);
    if (kind == null) return null;
    final StationScope scope = StationScope.parse(raw['scope']);
    final String description = (raw['description'] ?? '').toString();
    final Object? rawMax = raw['max_subscriptions'];
    final int maxSubscriptions = rawMax is num
        ? rawMax.toInt()
        : defaultMaxSubscriptions;
    final bool builtin = raw['builtin'] == true;
    final Object? rawCreated = raw['created_at'];
    final int createdAt = rawCreated is num ? rawCreated.toInt() : nowSeconds();
    final List<StationSubscriber> subscribers = <StationSubscriber>[];
    final Object? rawSubs = raw['subscribers'];
    if (rawSubs is List) {
      for (final Object? item in rawSubs) {
        final StationSubscriber? sub = StationSubscriber.tryParse(item);
        if (sub != null) subscribers.add(sub);
      }
    }
    switch (kind) {
      case StationKind.broadcast:
        final Object? rawLimit = raw['board_limit'];
        final Object? rawSeq = raw['board_seq'];
        return BroadcastStation(
          id: id,
          description: description,
          scope: scope,
          maxSubscriptions: maxSubscriptions,
          builtin: builtin,
          createdAt: createdAt,
          subscribers: subscribers,
          boardLimit: rawLimit is num ? rawLimit.toInt() : 50,
          boardSeq: rawSeq is num ? rawSeq.toInt() : 0,
          board: BroadcastStation.parseBoard(raw['board']),
        );
      case StationKind.execute:
        return ExecuteStation(
          id: id,
          description: description,
          scope: scope,
          maxSubscriptions: maxSubscriptions,
          builtin: builtin,
          createdAt: createdAt,
          subscribers: subscribers,
        );
      case StationKind.relay:
        return RelayStation(
          id: id,
          description: description,
          scope: scope,
          maxSubscriptions: maxSubscriptions,
          builtin: builtin,
          createdAt: createdAt,
          subscribers: subscribers,
        );
      case StationKind.collect:
        return CollectStation(
          id: id,
          description: description,
          scope: scope,
          maxSubscriptions: maxSubscriptions,
          builtin: builtin,
          createdAt: createdAt,
          subscribers: subscribers,
          schema: StationSchema.fromJson(raw['schema']),
        );
    }
  }
}

/// 公告板一条（广播站的持久公告板；跨重启保留，可回看最近若干条）。
class StationBoardEntry {
  const StationBoardEntry({
    required this.seq,
    required this.topic,
    required this.sourcePluginId,
    required this.scope,
    this.payload,
    required this.ts,
  });

  /// 单调序号（跨重启不回退）。
  final int seq;

  /// 主题。
  final String topic;

  /// 发布者插件 id（空 = 系统发布）。
  final String sourcePluginId;

  /// 发布 scope（隔离留痕）。
  final StationScope scope;

  /// 载荷（原样保留，便于回看）。
  final Object? payload;

  /// 发布时间（epoch 秒）。
  final int ts;

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'seq': seq,
    'topic': topic,
    'source_plugin_id': sourcePluginId,
    'scope': scope.toJson(),
    'payload': payload,
    'ts': ts,
  };

  /// 前端 / 调试快照形状。
  Map<String, dynamic> describe() => <String, dynamic>{
    'seq': seq,
    'topic': topic,
    'plugin_id': sourcePluginId,
    'ts': ts,
    if (payload != null) 'payload': payload,
  };

  /// 宽容解析；序号非法返回 null。
  static StationBoardEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? rawSeq = raw['seq'];
    final int seq = rawSeq is num ? rawSeq.toInt() : 0;
    if (seq <= 0) return null;
    final String topic = (raw['topic'] ?? '').toString();
    if (topic.isEmpty) return null;
    final Object? rawTs = raw['ts'];
    return StationBoardEntry(
      seq: seq,
      topic: topic,
      sourcePluginId: (raw['source_plugin_id'] ?? '').toString(),
      scope: StationScope.parse(raw['scope']),
      payload: raw['payload'],
      ts: rawTs is num ? rawTs.toInt() : 0,
    );
  }
}

/// **广播站**：插件发布 topic → 多订阅者接收；带**持久公告板**（可回看最近若干条）。
///
/// - 需订阅（订阅上限由实例自带）；
/// - 触发 = [publish]（实例的一个方法），触发时机由挂载位置的具体逻辑决定；
/// - 无订阅者也照样入板（公告板本身就是「跨插件交火」的回看入口）。
final class BroadcastStation extends StationInstance {
  BroadcastStation({
    required super.id,
    required super.description,
    required super.scope,
    super.maxSubscriptions,
    super.builtin,
    super.createdAt,
    super.subscribers,
    this.boardLimit = 50,
    this.boardSeq = 0,
    List<StationBoardEntry>? board,
  }) : board = board ?? <StationBoardEntry>[];

  /// 公告板容量（最近若干条；超出丢最旧）。
  final int boardLimit;

  /// 公告板序号水位（持久化，跨重启不回退）。
  int boardSeq;

  /// 公告板（按时间从旧到新；末尾最新）。
  final List<StationBoardEntry> board;

  @override
  StationKind get kind => StationKind.broadcast;

  /// **触发**：发布一条广播（可在任意位置、任意时机被调用）。
  ///
  /// 隔离校验不过 ⇒ 整条拒绝（不入板、不投递）；订阅者逐个过「消息 → 订阅者」
  /// 校验，跨 scope 的记入 [StationPublishResult.skipped]（fail-closed，不静默）。
  Future<StationPublishResult> publish({
    required String topic,
    required StationScope scope,
    Object? payload,
    Map<String, dynamic> meta = const <String, dynamic>{},
    String sourcePluginId = '',
  }) async {
    final StationIsolationVerdict verdict = checkScope(scope);
    if (!verdict.ok) {
      counters.bump('skipped_scope');
      return StationPublishResult(
        topic: topic,
        boardSeq: 0,
        skipped: <String>['广播被拒：${verdict.reason}'],
      );
    }
    final StationBoardEntry entry = StationBoardEntry(
      seq: ++boardSeq,
      topic: topic,
      sourcePluginId: sourcePluginId,
      scope: scope,
      payload: payload,
      ts: StationInstance.nowSeconds(),
    );
    board.add(entry);
    while (boardLimit > 0 && board.length > boardLimit) {
      board.removeAt(0);
    }
    onMutated?.call();

    final List<StationDelivery> deliveries = <StationDelivery>[];
    final List<String> skipped = <String>[];
    final List<Future<void>> pending = <Future<void>>[];
    for (final StationSubscriber subscriber in List<StationSubscriber>.of(
      subscribers,
    )) {
      final StationIsolationVerdict toSubscriber =
          StationIsolation.checkSubscriber(
            message: scope,
            subscriber: subscriber.scope,
          );
      if (!toSubscriber.ok) {
        counters.bump('skipped_scope');
        skipped.add('跳过 ${subscriber.pluginId}：${toSubscriber.reason}');
        continue;
      }
      counters.bump('requests');
      final StationRequest request = StationRequest(
        requestId: '${entry.seq}-${subscribers.indexOf(subscriber)}',
        stationId: id,
        kind: StationKind.broadcast,
        scope: scope,
        payload: payload,
        meta: <String, dynamic>{'topic': topic, ...meta},
      );
      pending.add(() async {
        final StationReply reply = await awaitReply(
          subscriber: subscriber,
          request: request,
        );
        if (reply.isFailed) {
          counters.bump('handler_error');
          deliveries.add(
            StationDelivery(
              subscriber: subscriber,
              ok: false,
              error: reply.error,
            ),
          );
        } else {
          counters.bump('delivered');
          deliveries.add(
            StationDelivery(
              subscriber: subscriber,
              ok: true,
              payload: reply.payload,
            ),
          );
        }
      }());
    }
    await Future.wait(pending);
    return StationPublishResult(
      topic: topic,
      boardSeq: entry.seq,
      deliveries: deliveries,
      skipped: skipped,
    );
  }

  /// **公告板回看**：最近 limit 条（可选按 topic 过滤；最新在前）。
  List<StationBoardEntry> boardEntries({int limit = 10, String topic = ''}) {
    final List<StationBoardEntry> matched = board
        .where((StationBoardEntry e) => topic.isEmpty || e.topic == topic)
        .toList(growable: false);
    if (limit <= 0 || matched.length <= limit) {
      return matched.reversed.toList(growable: false);
    }
    return matched
        .sublist(matched.length - limit)
        .reversed
        .toList(growable: false);
  }

  @override
  Map<String, dynamic> extraJson() => <String, dynamic>{
    'board_limit': boardLimit,
    'board_seq': boardSeq,
    if (board.isNotEmpty)
      'board': board.map((StationBoardEntry e) => e.toJson()).toList(),
  };

  @override
  Map<String, dynamic> extraDescribe() => <String, dynamic>{
    'board_limit': boardLimit,
    'board_size': board.length,
    'board_latest': board
        .skip(board.length > 5 ? board.length - 5 : 0)
        .map((StationBoardEntry e) => e.describe())
        .toList(),
  };

  /// 公告板解析（宽容：坏条目跳过）。
  static List<StationBoardEntry> parseBoard(Object? raw) {
    final List<StationBoardEntry> entries = <StationBoardEntry>[];
    if (raw is! List) return entries;
    for (final Object? item in raw) {
      final StationBoardEntry? entry = StationBoardEntry.tryParse(item);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }
}

/// 执行站的一个挂载位置（命令处理器 + 标识；**运行时不落盘**）。
class StationCommandMount {
  const StationCommandMount({
    required this.command,
    required this.mountId,
    required this.handler,
    this.priority = 0,
    required this.mountedAt,
  });

  /// 命令名（白名单内）。
  final String command;

  /// 挂载位置 id（如 ui.push / frontend / system）。
  final String mountId;

  /// 处理器。
  final StationCommandHandler handler;

  /// 优先级（大者优先；相同取先挂载者）。
  final int priority;

  /// 挂载时间（epoch 秒）。
  final int mountedAt;

  /// 快照形状。
  Map<String, dynamic> describe() => <String, dynamic>{
    'command': command,
    'mount_id': mountId,
    'priority': priority,
    'mounted_at': mountedAt,
  };
}

/// **执行站**：插件**主动下命令**，由挂载位置执行；**不订阅、不触发插件**。
///
/// - 首命令集 = [builtinCommands]（白名单；白名单外的命令一律显式拒绝）；
/// - 「执行器只是站点的一种挂载位置」：前端执行器 / 插件 / 系统内置都可以
///   [mount] 自己的处理器；
/// - 触发 = [execute]（实例的一个方法）。
final class ExecuteStation extends StationInstance {
  ExecuteStation({
    required super.id,
    required super.description,
    required super.scope,
    super.maxSubscriptions,
    super.builtin,
    super.createdAt,
    super.subscribers,
  });

  /// 首命令集（白名单）：插件只能下这些命令。
  static const Set<String> builtinCommands = <String>{
    'fs.read',
    'fs.write',
    'fs.list',
    'fs.grep',
    'terminal.exec',
    'agent.message',
    'agent.stop',
    'agent.compact',
    'ui.push',
  };

  final List<StationCommandMount> _mounts = <StationCommandMount>[];

  @override
  StationKind get kind => StationKind.execute;

  /// 已挂载的位置（调试 / 快照）。
  List<StationCommandMount> mounts({String? command}) => _mounts
      .where((StationCommandMount m) => command == null || m.command == command)
      .toList(growable: false);

  /// **挂载**一个命令处理器（「执行器」= 站点的一种挂载位置）。
  ///
  /// 返回 null = 成功；否则返回可读中文原因（命令不在白名单 / 参数非法）。
  String? mount({
    required String command,
    required String mountId,
    required StationCommandHandler handler,
    int priority = 0,
  }) {
    if (!builtinCommands.contains(command)) {
      final List<String> allowed = builtinCommands.toList()..sort();
      return '命令 $command 不在首命令集内（允许：${allowed.join('、')}）';
    }
    if (mountId.trim().isEmpty) return '挂载位置 id 不能为空';
    _mounts.removeWhere(
      (StationCommandMount m) => m.mountId == mountId && m.command == command,
    );
    _mounts.add(
      StationCommandMount(
        command: command,
        mountId: mountId,
        handler: handler,
        priority: priority,
        mountedAt: StationInstance.nowSeconds(),
      ),
    );
    return null;
  }

  /// 卸载某挂载位置的全部命令；返回卸载数量。
  int unmount(String mountId) {
    final int before = _mounts.length;
    _mounts.removeWhere((StationCommandMount m) => m.mountId == mountId);
    return before - _mounts.length;
  }

  /// **触发**：下一条命令（隔离 → 白名单 → 挂载 → 执行）。
  ///
  /// 执行站**不触发插件**：这里只把命令交给挂载位置，命令结果的后续处理由
  /// 下命令的插件自己负责。
  Future<StationCommandResult> execute({
    required String command,
    required StationScope scope,
    Map<String, dynamic> arguments = const <String, dynamic>{},
    String sourcePluginId = '',
  }) async {
    final StationIsolationVerdict verdict = checkScope(scope);
    if (!verdict.ok) {
      counters.bump('skipped_scope');
      return StationCommandResult(
        command: command,
        ok: false,
        error: '命令被拒（隔离）：${verdict.reason}',
      );
    }
    if (!builtinCommands.contains(command)) {
      counters.bump('invalid_response');
      final List<String> allowed = builtinCommands.toList()..sort();
      return StationCommandResult(
        command: command,
        ok: false,
        error: '命令 $command 不在首命令集内（允许：${allowed.join('、')}）',
      );
    }
    final List<StationCommandMount> candidates =
        _mounts.where((StationCommandMount m) => m.command == command).toList()
          ..sort((StationCommandMount a, StationCommandMount b) {
            final int byPriority = b.priority.compareTo(a.priority);
            return byPriority != 0
                ? byPriority
                : a.mountedAt.compareTo(b.mountedAt);
          });
    if (candidates.isEmpty) {
      counters.bump('no_subscriber');
      return StationCommandResult(
        command: command,
        ok: false,
        error:
            '命令 $command 暂无挂载位置（没有执行器接管；'
            '「执行器」只是执行站的一种挂载位置）',
      );
    }
    final StationCommandMount mount = candidates.first;
    counters.bump('requests');
    try {
      final StationCommandOutcome outcome = await mount.handler(
        StationCommandContext(
          command: command,
          arguments: arguments,
          scope: scope,
          stationId: id,
          sourcePluginId: sourcePluginId,
        ),
      );
      if (outcome.isFailed) {
        counters.bump('handler_error');
        return StationCommandResult(
          command: command,
          ok: false,
          mountId: mount.mountId,
          error: outcome.error,
        );
      }
      counters.bump('responded');
      return StationCommandResult(
        command: command,
        ok: true,
        mountId: mount.mountId,
        payload: outcome.payload,
      );
    } catch (error) {
      counters.bump('handler_error');
      return StationCommandResult(
        command: command,
        ok: false,
        mountId: mount.mountId,
        error: '挂载位置 ${mount.mountId} 执行异常：$error',
      );
    }
  }

  @override
  Map<String, dynamic> extraDescribe() => <String, dynamic>{
    'commands': (builtinCommands.toList()..sort()),
    'mounts': _mounts.map((StationCommandMount m) => m.describe()).toList(),
  };
}

/// **中转站**：数据流拦截 → 订阅者处理 → **回填**（改写原数据流）。
///
/// - 需订阅；**站 × scope 键位唯一**（先到先得：同键位第二人被拒，显式 replace
///   则替换并回报被替换者）——所以一个接入点只能有一个处理者；
/// - 触发 = [relay]（实例的一个方法）；
/// - **fail-open 红线**（照旧后端）：无订阅者 / 订阅者心跳丢失 / 回包非法 /
///   处理异常，一律**放行原数据**并给出可读原因，绝不抛出、绝不出半成品。
final class RelayStation extends StationInstance {
  RelayStation({
    required super.id,
    required super.description,
    required super.scope,
    super.maxSubscriptions,
    super.builtin,
    super.createdAt,
    super.subscribers,
  });

  @override
  StationKind get kind => StationKind.relay;

  /// 中转站强制键位唯一（一个接入点只能有一个处理者）。
  @override
  bool get scopeKeyUnique => true;

  /// 触发解析：scope 匹配 + **最细粒度优先**（照旧后端 resolve 语义）。
  ///
  /// 匹配方向 fail-closed：订阅者声明的非空字段必须与消息一致；
  /// 消息字段为空而订阅者要求该字段 ⇒ 不匹配。
  StationSubscriber? resolve(StationScope message) {
    StationSubscriber? best;
    int bestRank = -1;
    int bestSpecificity = -1;
    for (final StationSubscriber subscriber in subscribers) {
      if (!StationIsolation.checkSubscriber(
        message: message,
        subscriber: subscriber.scope,
      ).ok) {
        continue;
      }
      final int rank = subscriber.scope.sessionId.isNotEmpty
          ? 3
          : subscriber.scope.agentId.isNotEmpty
          ? 2
          : 1;
      final int specificity = subscriber.scope.specificity;
      if (rank > bestRank ||
          (rank == bestRank && specificity > bestSpecificity)) {
        bestRank = rank;
        bestSpecificity = specificity;
        best = subscriber;
      }
    }
    return best;
  }

  /// **触发**：拦截数据并等待回填。
  ///
  /// 返回值的 data 就是"最终数据流"：处理成功 = 订阅者给的新数据；
  /// 其余任何情况 = **原数据放行**（fail-open），原因写在 [StationRelayResult.reason]。
  Future<StationRelayResult> relay({
    required Object? data,
    required StationScope scope,
    Map<String, dynamic> meta = const <String, dynamic>{},
    String sourcePluginId = '',
  }) async {
    final StationIsolationVerdict verdict = checkScope(scope);
    if (!verdict.ok) {
      counters.bump('skipped_scope');
      return StationRelayResult(
        data: data,
        handled: false,
        reason: '中转被拒（隔离）：${verdict.reason}',
      );
    }
    final StationSubscriber? subscriber = resolve(scope);
    if (subscriber == null) {
      counters.bump('no_subscriber');
      return StationRelayResult(
        data: data,
        handled: false,
        reason: '无匹配订阅者（原数据放行）',
      );
    }
    counters.bump('requests');
    final StationRequest request = StationRequest(
      requestId:
          'relay-${StationInstance.nowSeconds()}-${subscribers.indexOf(subscriber)}',
      stationId: id,
      kind: StationKind.relay,
      scope: scope,
      payload: data,
      meta: meta,
    );
    final StationReply reply = await awaitReply(
      subscriber: subscriber,
      request: request,
    );
    if (reply.isFailed) {
      counters.bump('timeout');
      return StationRelayResult(
        data: data,
        handled: false,
        pluginId: subscriber.pluginId,
        reason: '订阅者未回填：${reply.error}（原数据放行）',
      );
    }
    counters.bump('responded');
    final Object? payload = reply.payload;
    if (payload == null) {
      // 照旧后端语义：None = 不改动、放行原数据（但算"已响应"）
      return StationRelayResult(
        data: data,
        handled: true,
        pluginId: subscriber.pluginId,
        reason: '订阅者选择不改动数据',
      );
    }
    if (payload is String || payload is Map || payload is List) {
      // 回填 = **整体替换**原数据：字符串用于文本流（工具结果），
      // 映射 / 数组用于结构化流（工具调用报文本身就是 Map）。
      return StationRelayResult(
        data: payload,
        handled: true,
        pluginId: subscriber.pluginId,
      );
    }
    counters.bump('invalid_response');
    return StationRelayResult(
      data: data,
      handled: false,
      pluginId: subscriber.pluginId,
      reason:
          '回填类型非法（只接受 string / 对象 / 数组替换，空表示不改动），'
          '实际是 ${payload.runtimeType}（原数据放行）',
    );
  }
}

/// **收集站**（用户定稿）：站点 --（附带信息，可选）--> 所有订阅者 --目标数据-->
/// 站点 --> 触发方后续处理。
///
/// - **站点定义输入格式**（[schema]，必填）：订阅者必须按 schema 产出，
///   校验失败按可读错误回报该订阅者；
/// - 需订阅（可多个）；订阅上限由实例自带；
/// - **不回填**原数据流：trigger 的返回值就是结果，后续处理由**触发方**负责；
/// - **部分结果**：某订阅者未响应（心跳丢失 / 窗口内无回 / 校验失败 / 回包报错）
///   ⇒ 返回已收集部分 + **显式列出未响应者**，不静默、不阻塞、不整体失败。
final class CollectStation extends StationInstance {
  CollectStation({
    required super.id,
    required super.description,
    required super.scope,
    required this.schema,
    super.maxSubscriptions,
    super.builtin,
    super.createdAt,
    super.subscribers,
  });

  /// 站点定义的输入格式（订阅者必须按它产出）。
  final StationSchema schema;

  @override
  StationKind get kind => StationKind.collect;

  /// **触发**：向所有订阅者采集目标数据（可在任意位置、任意时机被调用）。
  ///
  /// [request] 是「站点 --（附带信息，可选）--> 所有订阅者」里的可选请求体；
  /// [meta] 是随请求下发的附带信息。返回值就是最终结果，站点内部不做管线。
  Future<StationCollectResult> collect({
    required StationScope scope,
    Object? request,
    Map<String, dynamic> meta = const <String, dynamic>{},
    String sourcePluginId = '',
  }) async {
    final StationIsolationVerdict verdict = checkScope(scope);
    if (!verdict.ok) {
      counters.bump('skipped_scope');
      return StationCollectResult(
        skipped: <String>['采集被拒（隔离）：${verdict.reason}'],
      );
    }
    final List<StationCollectedItem> items = <StationCollectedItem>[];
    final List<StationUnresponsive> unresponsive = <StationUnresponsive>[];
    final List<String> skipped = <String>[];
    final List<Future<void>> pending = <Future<void>>[];
    final List<StationSubscriber> targets = List<StationSubscriber>.of(
      subscribers,
    );
    for (int index = 0; index < targets.length; index++) {
      final StationSubscriber subscriber = targets[index];
      final StationIsolationVerdict toSubscriber =
          StationIsolation.checkSubscriber(
            message: scope,
            subscriber: subscriber.scope,
          );
      if (!toSubscriber.ok) {
        counters.bump('skipped_scope');
        skipped.add('跳过 ${subscriber.pluginId}：${toSubscriber.reason}');
        continue;
      }
      counters.bump('requests');
      final StationRequest stationRequest = StationRequest(
        requestId: 'collect-${StationInstance.nowSeconds()}-$index',
        stationId: id,
        kind: StationKind.collect,
        scope: scope,
        payload: request,
        meta: meta,
        schema: schema,
      );
      pending.add(() async {
        final StationReply reply = await awaitReply(
          subscriber: subscriber,
          request: stationRequest,
        );
        if (reply.isFailed) {
          counters.bump('handler_error');
          unresponsive.add(
            StationUnresponsive(subscriber: subscriber, reason: reply.error),
          );
          return;
        }
        final String? invalid = schema.validate(reply.payload);
        if (invalid != null) {
          counters.bump('invalid_response');
          unresponsive.add(
            StationUnresponsive(
              subscriber: subscriber,
              reason: '产出不符合站点 schema：$invalid',
            ),
          );
          return;
        }
        counters.bump('responded');
        items.add(
          StationCollectedItem(subscriber: subscriber, payload: reply.payload),
        );
      }());
    }
    await Future.wait(pending);
    return StationCollectResult(
      items: items,
      unresponsive: unresponsive,
      skipped: skipped,
    );
  }

  @override
  Map<String, dynamic> extraJson() => <String, dynamic>{
    'schema': schema.toJson(),
  };

  @override
  Map<String, dynamic> extraDescribe() => <String, dynamic>{
    'schema': schema.toJson(),
    'schema_fields': schema.fieldNames,
  };
}
