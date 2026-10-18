import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../../io/plugin_monitor_service.dart';
import 'plugin_detail_page.dart';
import 'plugin_editor_dialog.dart';

/// 插件管理接口（面板 → 核心）。
///
/// 做成抽象类是为了**可测**：真实实现走 [ApiService] 的 REST 方法，widget 测试注入
/// 假实现就能在没有核心进程的情况下断言"点了哪个开关、发了什么请求、错误怎么显示"。
///
/// 为什么面板不把状态塞进 [PluginMonitorService]：那个服务是只读快照 + WS 增量的
/// 搬运工（M1 起就只读），而清单的增删改是**另一个数据源**（磁盘上的 plugins.yaml）。
/// 两者都在面板里合并展示：清单给"配置成什么样"，快照给"运行成什么样"。
abstract class PluginAdminClient {
  /// 读取插件清单（持久态）+ 每条的运行态。
  Future<Map<String, dynamic>> fetchConfigs();

  /// 读取内置插件目录（[refresh] = 强制核心重探运行时）。
  Future<Map<String, dynamic>> fetchBuiltins({bool refresh = false});

  /// 新增一个自定义插件。
  Future<Map<String, dynamic>> createConfig(Map<String, dynamic> body);

  /// 局部更新一个插件（开关 / 编辑）。
  Future<Map<String, dynamic>> updateConfig(
    String id,
    Map<String, dynamic> patch,
  );

  /// 删除一个自定义插件。
  Future<Map<String, dynamic>> deleteConfig(String id);

  /// 显式处置一个插件实例。
  ///
  /// [mode]：`cold`（缺省，与旧行为逐字一致）/ `hot`（热重启，尽量续跑）/
  /// `force_stop`（**用户显式**强制停止：全框架唯一能因为界面按钮而 kill 的入口）。
  Future<Map<String, dynamic>> restartConfig(
    String id, {
    String mode = 'cold',
    bool keepState = true,
  });

  /// 打开 / 关闭一个内置插件（每项各自一个开关）。
  Future<Map<String, dynamic>> setBuiltinEnabled(
    String id, {
    required bool enabled,
  });

  /// 发布仓库清单（**只读本地缓存**，不联网）：GET /api/plugin/release。
  ///
  /// 为什么面板打开时用它而不是刷新：那是一个网络动作，而左栏打开不该被网络
  /// 拖住（断网时也要能把“上次看到的那些”列出来，并标清这是缓存）。
  Future<Map<String, dynamic>> fetchRelease();

  /// 拉最新 release 的发布索引（**联网**）：POST /api/plugin/release/refresh。
  ///
  /// 只读 GitHub Release 资产，不 `git clone` 源码（插件仓里是给人改的源码，装机端
  /// 要的是发布方事先备好的成品）。失败仍回 `ok:false` + 可读原因 + `cached`。
  Future<Map<String, dynamic>> refreshRelease();

  /// 从发布仓库装一条插件：POST /api/plugin/release/{id}/install。
  ///
  /// 旧进程没确认退出就**不换文件**（核心不为换文件而强杀插件），那种失败回
  /// 400 + 原因；这里抛成异常，面板直接显示那句话。
  Future<Map<String, dynamic>> installRelease(String id);

  /// 站点详情（GET /api/plugin/stations/{id}）：`StationInstance.describe()` 一整块。
  ///
  /// 为什么站点页要单独读而不是直接用快照里那一份：快照是 WS 节流的，可能滞后，
  /// 而「禁用订阅者 / 改配置」必须落在当前真值上（不这样做会出现"界面上还有个早就
  /// 退订的订阅者"，点了核心只会回 404）。
  Future<Map<String, dynamic>> stationDetail(String stationId);

  /// 局部改站点配置（PATCH …/config）：只发要改的键。
  ///
  /// 内置站只能改 `max_subscriptions`，其余键核心回 400 + 原因（原样显示，不改写）。
  Future<Map<String, dynamic>> patchStationConfig(
    String stationId,
    Map<String, dynamic> patch,
  );

  /// 禁用 / 启用一个订阅者（POST …/subscribers/{key}）。
  ///
  /// **禁用不是退订**：订阅关系与回包通道都留着，只让触发时不投递。
  Future<Map<String, dynamic>> setSubscriberDisabled(
    String stationId,
    String subscriberKey, {
    required bool disabled,
  });
}

/// 默认实现：直接走 [ApiService]。
class ApiPluginAdminClient implements PluginAdminClient {
  const ApiPluginAdminClient();

  @override
  Future<Map<String, dynamic>> fetchConfigs() => ApiService.getPluginConfigs();

  @override
  Future<Map<String, dynamic>> fetchBuiltins({bool refresh = false}) =>
      ApiService.getPluginBuiltins(refresh: refresh);

  @override
  Future<Map<String, dynamic>> createConfig(Map<String, dynamic> body) =>
      ApiService.createPluginConfig(
        id: (body['id'] ?? '').toString(),
        name: (body['name'] ?? '').toString(),
        description: (body['description'] ?? '').toString(),
        command: (body['command'] ?? '').toString(),
        args: _strings(body['args']),
        env: _stringMap(body['env']),
        granularity: (body['granularity'] ?? 'team').toString(),
        scope: _stringMap(body['scope']),
        enabled: body['enabled'] != false,
      );

  @override
  Future<Map<String, dynamic>> updateConfig(
    String id,
    Map<String, dynamic> patch,
  ) => ApiService.updatePluginConfig(id, patch);

  @override
  Future<Map<String, dynamic>> deleteConfig(String id) =>
      ApiService.deletePluginConfig(id);

  @override
  Future<Map<String, dynamic>> restartConfig(
    String id, {
    String mode = 'cold',
    bool keepState = true,
  }) => ApiService.restartPluginConfig(id, mode: mode, keepState: keepState);

  @override
  Future<Map<String, dynamic>> setBuiltinEnabled(
    String id, {
    required bool enabled,
  }) => ApiService.setBuiltinPluginEnabled(id, enabled: enabled);

  @override
  Future<Map<String, dynamic>> fetchRelease() => ApiService.getPluginRelease();

  @override
  Future<Map<String, dynamic>> refreshRelease() =>
      ApiService.refreshPluginRelease();

  @override
  Future<Map<String, dynamic>> installRelease(String id) =>
      ApiService.installPluginRelease(id);

  @override
  Future<Map<String, dynamic>> stationDetail(String stationId) =>
      ApiService.getStationDetail(stationId);

  @override
  Future<Map<String, dynamic>> patchStationConfig(
    String stationId,
    Map<String, dynamic> patch,
  ) => ApiService.updateStationConfig(stationId, patch);

  @override
  Future<Map<String, dynamic>> setSubscriberDisabled(
    String stationId,
    String subscriberKey, {
    required bool disabled,
  }) => ApiService.setStationSubscriberDisabled(
    stationId,
    subscriberKey,
    disabled: disabled,
  );

  static List<String> _strings(Object? raw) => raw is List
      ? <String>[for (final Object? e in raw) e.toString()]
      : const <String>[];

  static Map<String, String> _stringMap(Object? raw) => raw is Map
      ? <String, String>{
          for (final MapEntry<Object?, Object?> e in raw.entries)
            e.key.toString(): e.value?.toString() ?? '',
        }
      : const <String, String>{};
}

/// 插件面板（左侧活动栏「插件」页）：**可读写**。
///
/// 数据源两条，分工明确：
/// 1. 清单（读写）——[PluginAdminClient]（默认 REST /api/plugin/configs 与
///    /api/plugin/builtins）：插件实例分「内置」「自定义」两组，**每一项各有自己的
///    开关**（M9 §4.2：不是统一开关），另有 编辑 / 删除 / 重启；
/// 2. 运行态（只读）——[PluginMonitorService]（快照 + WS 增量）：站点 / 看门狗 /
///    心跳健康度，以及清单接口不可用时（旧核心）的实例列表兜底。
///
/// 展示纪律（延续既有口径）：
/// - 心跳降级 **不是** 停用（角标橙色 + 说明，状态标签仍是「已注册」）；
/// - 未知字段与未知状态一律忽略（不崩、不臆测）；
/// - 停用 = 条目保留（面板显示「已停用」而不是让它消失）；
/// - 热应用失败必须如实显示核心给的 notice（「配置已保存，但本次热应用失败，
///   重启核心后生效」）——不显示就等于骗用户"已经生效了"。
///
/// 位于左栏时由活动栏承担标题，可传 [showHeader] = false 避免双标题。
class PluginPanel extends StatefulWidget {
  /// 所属团队 ID（null / 空串 = 不过滤，展示当前用户可见全部实例）
  final String? teamId;

  /// 是否渲染自带标题栏（左栏由活动栏承担标题时传 false）
  final bool showHeader;

  /// 左栏折叠回调（内容下方空白区域点击触发）
  ///
  /// 为 null 时不注册点击（右栏等常驻场景不需要折叠语义）。
  final VoidCallback? onCollapse;

  /// 数据源覆盖（**测试注入用**；null = 全局单例 [PluginMonitorService.instance]）。
  ///
  /// 面板在真实使用里是单例（一处连接、多处展示），但 widget 测试需要一个干净的
  /// 服务实例，否则测试之间会共享同一次快照与连接态。
  final PluginMonitorService? service;

  /// 插件管理接口覆盖（**测试注入用**；null = 走 REST 的 [ApiPluginAdminClient]）。
  final PluginAdminClient? admin;

  const PluginPanel({
    super.key,
    this.teamId,
    this.showHeader = true,
    this.onCollapse,
    this.service,
    this.admin,
  });

  @override
  State<PluginPanel> createState() => _PluginPanelState();
}

class _PluginPanelState extends State<PluginPanel> {
  PluginMonitorService get _svc =>
      widget.service ?? PluginMonitorService.instance;

  PluginAdminClient get _admin => widget.admin ?? const ApiPluginAdminClient();

  /// 插件清单（持久态；落盘的那一份）。
  List<Map<String, dynamic>> _configs = <Map<String, dynamic>>[];

  /// 每条插件的运行态（id → running / health / reason / error / known）。
  Map<String, dynamic> _runtime = <String, dynamic>{};

  /// 内置插件目录（静态清单 + 启用态 + 运行时解析结果）。
  List<Map<String, dynamic>> _builtins = <Map<String, dynamic>>[];

  /// plugins.yaml 的真实路径（核心给；清单接口不可用时退回快照里的路径）。
  String _adminPath = '';

  /// 清单接口的错误（旧核心没这些端点时非空 ⇒ 退回只读实例列表）。
  String? _adminError;

  /// 正在提交的插件 id（提交期间禁用该项的开关，避免连点）。
  final Set<String> _busy = <String>{};

  // ── 发布仓库（阶段 5）的展示状态 ────────────────────────────────────

  /// 索引里的条目（已校验）：plugin_id / name / version / installed_version / has_update。
  List<Map<String, dynamic>> _releaseEntries = <Map<String, dynamic>>[];

  /// 被跳过的索引条目 + 为什么（面板要能说出“这一条为什么没出现”，不静默）。
  List<String> _releaseSkipped = <String>[];

  /// 发布清单的失败原因（空 = 正常）。没缓存也是一句可读原因。
  String _releaseError = '';

  /// 这份索引来自哪个 release tag（离线读缓存时可能是空）。
  String _releaseTag = '';

  /// 当前列表是**联网取的**还是读的本地缓存（离线不许看起来像最新）。
  bool _releaseOnline = false;

  /// 索引缓存路径（诊断用：面板会说“我读的是哪一份”）。
  String _releaseIndexPath = '';

  /// 正在拉索引（拉期间禁用刷新按钮，避免连点叠成两个请求）。
  bool _releaseLoading = false;

  /// 「从仓库装它 / 从仓库更新」的**就地**失败原因（id → 原因）。
  ///
  /// 与 release 那一节的 snack 不同：这颗按钮长在卡片上，失败就必须显示在卡片上 ——
  /// 刷新失败、索引里没有这一条、安装被闸门拦住都算，成功或重试时清掉。
  final Map<String, String> _repoErrors = <String, String>{};

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChanged);
    _svc.start(teamId: widget.teamId ?? '');
    _loadAdmin();
    // 发布仓库：只读本地缓存（不联网），所以面板打开不会卡在网络上。
    _loadRelease();
  }

  @override
  void didUpdateWidget(covariant PluginPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.teamId != widget.teamId) {
      _svc.setTeam(widget.teamId ?? '');
    }
  }

  @override
  void dispose() {
    _svc.removeListener(_onChanged);
    _svc.stop();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  // ── 数据 ─────────────────────────────────────────────────────────────

  /// 拉清单 + 内置目录（[refreshBuiltins] = 让核心重探运行时）。
  Future<void> _loadAdmin({bool refreshBuiltins = false}) async {
    try {
      final Map<String, dynamic> configs = await _admin.fetchConfigs();
      final Map<String, dynamic> builtins = await _admin.fetchBuiltins(
        refresh: refreshBuiltins,
      );
      if (!mounted) return;
      setState(() {
        _configs = _mapList(configs['configs']);
        final Object? runtime = configs['runtime'];
        _runtime = runtime is Map
            ? Map<String, dynamic>.from(runtime)
            : <String, dynamic>{};
        _builtins = _mapList(builtins['builtins']);
        _adminPath = (configs['path'] ?? builtins['path'] ?? '').toString();
        _adminError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _adminError = '$error'.replaceFirst('Exception: ', '');
      });
    }
  }

  static List<Map<String, dynamic>> _mapList(Object? raw) => raw is List
      ? <Map<String, dynamic>>[
          for (final Object? item in raw)
            if (item is Map) Map<String, dynamic>.from(item),
        ]
      : <Map<String, dynamic>>[];

  // ── 发布仓库（阶段 5：只拉 GitHub Release 资产，不拉源码）─────────────

  /// 读**本地缓存**的发布清单（不联网）。
  Future<void> _loadRelease() async {
    try {
      _applyReleaseListing(await _admin.fetchRelease());
    } catch (error) {
      if (!mounted) return;
      setState(() => _releaseError = _reasonOf(error));
    }
  }

  /// 联网拉最新 release 的索引并缓存。
  ///
  /// 失败**不清空列表**：核心会把上一次那份递在 `cached` 里，面板要说的是
  /// “这次没刷成功，下面这些是上次那份”，而不是把限流显示成“仓库里没插件”。
  Future<void> _refreshRelease() async {
    setState(() => _releaseLoading = true);
    try {
      final Map<String, dynamic> result = await _admin.refreshRelease();
      _applyReleaseListing(result);
      final String error = (result['error'] ?? '').toString();
      if (error.isNotEmpty) {
        final Object? cached = result['cached'];
        if (cached is Map) {
          _applyReleaseListing(
            Map<String, dynamic>.from(cached),
            keepError: error,
          );
        }
        _snack('刷新失败：$error');
      }
    } catch (error) {
      final String reason = _reasonOf(error);
      setState(() => _releaseError = reason);
      _snack('刷新失败：$reason');
    } finally {
      if (mounted) setState(() => _releaseLoading = false);
    }
  }

  /// 把一份清单响应写进展示状态。
  ///
  /// `ok:false` 时**只换错误话术、不动条目**：“刷新失败但缓存里那些还能装”是
  /// 一个常见现场，把它们从界面上抹掉只会让用户以为什么都没了。
  void _applyReleaseListing(
    Map<String, dynamic> listing, {
    String keepError = '',
  }) {
    if (!mounted) return;
    final bool ok = listing['ok'] != false;
    final Object? rawSkipped = listing['skipped'];
    setState(() {
      if (ok) {
        _releaseEntries = _mapList(listing['entries']);
        _releaseSkipped = <String>[
          if (rawSkipped is List) for (final Object? item in rawSkipped) '$item',
        ];
      }
      _releaseTag = (listing['tag'] ?? '').toString();
      _releaseOnline = listing['online'] == true;
      _releaseIndexPath = (listing['index_path'] ?? '').toString();
      _releaseError = keepError.isNotEmpty
          ? keepError
          : (ok ? '' : (listing['error'] ?? '').toString());
    });
  }

  /// 装一条（含写盘 + 热应用）：走 [_submit] ⇒ 提交期间禁用该项、结果如实显示、
  /// 之后重拉清单与快照（新装的那一条应该立刻出现在“自定义”组里）。
  Future<void> _installRelease(String id) => _submit(
    id,
    () => _admin.installRelease(id),
    successFrom: (Map<String, dynamic> result) {
      final Object? install = result['install'];
      final String version = install is Map
          ? (install['version'] ?? '').toString()
          : '';
      return version.isEmpty
          ? '已从发布仓库安装 $id'
          : '已从发布仓库安装 $id（$version）';
    },
  );

  static String _reasonOf(Object error) =>
      '$error'.replaceFirst('Exception: ', '');

  /// 内置项的「从仓库装它 / 从仓库更新」：**先自动刷新索引，再 install**。
  ///
  /// 与 release 那一节的手动按钮不同，这颗按钮是“缺成品”场景的就地入口 —— 用户不该
  /// 先去下面那一节点「刷新」再找这一条。失败原因写进 [_repoErrors]（卡片上直接显示，
  /// 不只是一条转瞬即逝的 snack）：刷新失败、索引里没有这一条、安装被闸门拦住都算。
  Future<void> _installFromRepo(String id) async {
    setState(() {
      _busy.add(id);
      _repoErrors.remove(id);
    });
    try {
      // ① 先刷新：装机端要的是**最新索引**（缓存那份可能还没有这一条，或版本旧）。
      final Map<String, dynamic> refreshed = await _admin.refreshRelease();
      _applyReleaseListing(refreshed);
      final String refreshError = (refreshed['error'] ?? '').toString();
      if (refreshed['ok'] == false) {
        // 刷新失败不清空条目：核心把上一次那份递在 cached 里，里面**有**这一条
        // 就还能装（“今晚限流”不该变成“什么都装不了”）。
        final Object? cached = refreshed['cached'];
        if (cached is Map) {
          _applyReleaseListing(
            Map<String, dynamic>.from(cached),
            keepError: refreshError,
          );
        }
      }
      // ② 索引里没有这一条（仓库还没发 / 刷新后仍是旧索引）⇒ 就地说明，不发 install。
      final bool known = _releaseEntries.any(
        (Map<String, dynamic> e) =>
            (e['plugin_id'] ?? '').toString() == id,
      );
      if (!known) {
        setState(() {
          _repoErrors[id] = refreshError.isEmpty
              ? '索引里没有 $id 这一条（发布仓库还没发它，或刷新后仍是旧索引）'
              : '刷新索引失败：$refreshError（缓存里也没有 $id 这一条）';
        });
        return;
      }
      // ③ install（核心失败会抛成带原因的异常，下面 catch 里就地显示）。
      final Map<String, dynamic> result = await _admin.installRelease(id);
      setState(() => _repoErrors.remove(id));
      final Object? install = result['install'];
      final String version = install is Map
          ? (install['version'] ?? '').toString()
          : '';
      _showWriteResult(
        result,
        successText: version.isEmpty
            ? '已从发布仓库安装 $id'
            : '已从发布仓库安装 $id（$version）',
      );
      await _loadAdmin();
      await _svc.refresh();
    } catch (error) {
      final String reason = _reasonOf(error);
      if (!mounted) return;
      setState(() => _repoErrors[id] = reason);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  /// 从仓库装/更新成功后的重拉（清单 + 快照：新版本立刻反映在卡片上）。
  /// 详情页的仓库按钮装完也走这里（页面自己不持有面板状态）。
  Future<void> _reloadAfterRepoInstall() async {
    await _loadAdmin();
    await _svc.refresh();
  }

  /// 自定义插件：落盘条目里没有 builtin 标记、且**不属于内置清单**的那些。
  ///
  /// 排除内置 id 是为了防手改：用户把 plugins.yaml 里的 builtin 标记删掉之后，
  /// 同一条目会同时出现在内置组（清单常驻）与自定义组（显示两份）——这里按 id 去重。
  List<Map<String, dynamic>> get _customConfigs {
    final Set<String> builtinIds = <String>{
      for (final Map<String, dynamic> b in _builtins)
        (b['id'] ?? '').toString(),
    };
    return <Map<String, dynamic>>[
      for (final Map<String, dynamic> c in _configs)
        if (c['builtin'] != true &&
            !builtinIds.contains((c['id'] ?? '').toString()))
          c,
    ];
  }

  // ── 提交 ─────────────────────────────────────────────────────────────

  /// 提交一次改动：调用 → 如实显示结果 → 重拉清单与快照。
  Future<void> _submit(
    String id,
    Future<Map<String, dynamic>> Function() action, {
    String successText = '',
    String Function(Map<String, dynamic> result)? successFrom,
  }) async {
    setState(() => _busy.add(id));
    try {
      final Map<String, dynamic> result = await action();
      // 热重启的“成功”有两层意思（续上了 / 只是换了一世），必须分开说；
      // 拿一个固定文案就等于把“状态其实没续上”报成了一件好事。
      _showWriteResult(
        result,
        successText: successFrom == null ? successText : successFrom(result),
      );
      await _loadAdmin();
      await _svc.refresh();
    } catch (error) {
      _snack('操作失败：${'$error'.replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  /// 写盘结果：核心给了 notice（热应用失败话术）就**必须**显示。
  void _showWriteResult(
    Map<String, dynamic> result, {
    required String successText,
  }) {
    final String notice = (result['notice'] ?? '').toString();
    final String detail = (result['hot_apply_detail'] ?? '').toString();
    if (notice.isNotEmpty) {
      _snack(detail.isEmpty ? notice : '$notice（$detail）');
      return;
    }
    if (successText.isNotEmpty) {
      _snack(successText);
    }
  }

  void _snack(String text) {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    messenger?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
    );
  }

  // ── 详情页导航 ─────────────────────────────────────────────────────

  /// 推一个详情页（卡片整张可点；卡片内的开关与按钮自己吃掉手势，不会误跳）。
  void _push(Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (BuildContext ctx) => page),
    );
  }

  /// 某个插件的运行实例（快照里同 id 可能有多条：粒度不同）。
  ///
  /// 工具表按**插件 id** 对账（`toolsOf(config.id)`），同一插件的多条实例共用一份，
  /// 所以详情页取第一条不会看到"另一半工具不见了"。
  PluginInstanceInfo? _instanceOf(String pluginId) {
    final PluginSnapshot? snap = _svc.snapshot;
    if (snap == null || pluginId.isEmpty) return null;
    for (final PluginInstanceInfo e in snap.instances) {
      if (e.pluginId == pluginId) return e;
    }
    return null;
  }

  /// 某条清单条目的运行态（无条目 ⇒ 空表，由详情页按"没有运行实例"显示）。
  Map<String, dynamic> _runtimeOf(String id) {
    final Object? raw = _runtime[id];
    return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  }

  List<PluginStationInfo> get _allStations =>
      _svc.snapshot?.stations ?? const <PluginStationInfo>[];

  /// 介绍取值口径与「编辑」弹窗回填一致（先清单、再内置目录、最后快照）：
  /// 两处优先级不同就会出现"弹窗里写着 A、详情页讲 B"。
  String _introOf(
    String id, {
    Map<String, dynamic> entry = const <String, dynamic>{},
    Map<String, dynamic> spec = const <String, dynamic>{},
  }) {
    final String fromEntry = (entry['description'] ?? '').toString();
    if (fromEntry.isNotEmpty) return fromEntry;
    final String fromSpec = (spec['description'] ?? '').toString();
    if (fromSpec.isNotEmpty) return fromSpec;
    return _instanceOf(id)?.description ?? '';
  }

  /// 打开插件详情页（**只读**：数据全部来自面板已有的清单 + 快照，不发新请求）。
  void _openPluginDetail(PluginDetailPage page) => _push(page);

  /// 打开站点详情页（带上快照里那一份先渲染，页面自己再去 GET 当前真值）。
  void _openStationDetail(String stationId) {
    PluginStationInfo? initial;
    for (final PluginStationInfo s in _allStations) {
      if (s.stationId == stationId) {
        initial = s;
        break;
      }
    }
    _push(
      StationDetailPage(
        stationId: stationId,
        admin: _admin,
        initial: initial,
      ),
    );
  }

  /// 卡片底部的「点进来」提示：整张卡片都可点，但**看得出来**是另一回事。
  Widget _detailAffordance(ColorScheme cs, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          Text(text, style: TextStyle(fontSize: 10, color: cs.outline)),
          Icon(Icons.chevron_right, size: 14, color: cs.outline),
        ],
      ),
    );
  }

  /// 把一张卡片包成"整张可点"。
  ///
  /// 不加 InkWell 的水波纹：面板密度高，涟漪会和开关的反馈混在一起，改用卡片底部
  /// 一行 chevron 提示。卡片里的开关与按钮各自吃掉自己的手势，不会误跳详情。
  Widget _tappable({
    required Key key,
    required VoidCallback onTap,
    required Widget card,
  }) {
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: card,
    );
  }

  /// 内置项详情（介绍口径与「编辑」弹窗回填一致：清单条目优先于内置目录）。
  void _openBuiltinDetail(Map<String, dynamic> item) {
    final String id = (item['id'] ?? '').toString();
    final Map<String, dynamic> entry =
        (item['config'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    _openPluginDetail(
      PluginDetailPage(
        pluginId: id,
        name: (item['name'] ?? '').toString(),
        intro: _introOf(id, entry: entry, spec: item),
        isBuiltin: true,
        entry: entry,
        runtime: _runtimeOf(id),
        resolution: item['resolution'] as Map<String, dynamic>?,
        instance: _instanceOf(id),
        stations: _allStations,
        onOpenStation: _openStationDetail,
        admin: _admin,
        onInstalled: _reloadAfterRepoInstall,
      ),
    );
  }

  /// 自定义项详情。
  void _openCustomDetail(Map<String, dynamic> entry) {
    final String id = (entry['id'] ?? '').toString();
    _openPluginDetail(
      PluginDetailPage(
        pluginId: id,
        name: (entry['name'] ?? '').toString(),
        intro: _introOf(id, entry: entry),
        entry: entry,
        runtime: _runtimeOf(id),
        instance: _instanceOf(id),
        stations: _allStations,
        onOpenStation: _openStationDetail,
      ),
    );
  }

  /// 快照实例详情（**清单接口不可用时的兜底路径**：只有运行态，没有落盘条目）。
  void _openInstanceDetail(PluginInstanceInfo e) {
    _openPluginDetail(
      PluginDetailPage(
        pluginId: e.pluginId,
        name: e.name,
        intro: _introOf(e.pluginId),
        instance: e,
        stations: _allStations,
        onOpenStation: _openStationDetail,
      ),
    );
  }

  /// 每一项自己的开关：自定义插件 → PATCH enabled；内置插件 → enable / disable。
  Future<void> _toggleCustom(Map<String, dynamic> entry, bool value) {
    final String id = (entry['id'] ?? '').toString();
    return _submit(
      id,
      () => _admin.updateConfig(id, <String, dynamic>{'enabled': value}),
      successText: value ? '已写入启用状态' : '已写入停用状态',
    );
  }

  Future<void> _toggleBuiltin(Map<String, dynamic> item, bool value) {
    final String id = (item['id'] ?? '').toString();
    return _submit(
      id,
      () => _admin.setBuiltinEnabled(id, enabled: value),
      successText: value ? '已写入启用状态' : '已写入停用状态',
    );
  }

  Future<void> _restart(String id) =>
      _submit(id, () => _admin.restartConfig(id), successText: '已重启插件 $id');

  /// 热重启（保留状态）：文案跟着回包的 `resumed` 走 —— “换了一世”与“续上了”是两件事。
  ///
  /// 目标没声明 `suspension: keep` 时核心**按冷启动**完成重启（那不算失败，
  /// D3 的定型语义）；这里如果只说“已重启”，用户会以为状态还在。
  Future<void> _hotRestart(String id) => _submit(
    id,
    () => _admin.restartConfig(id, mode: 'hot'),
    successFrom: (Map<String, dynamic> result) => result['resumed'] == true
        ? '已热重启插件 $id，状态续到了第 ${result['generation'] ?? '?'} 代'
        : '已重启插件 $id，但按冷启动（目标没声明 suspension: keep 或没递快照）'
              '：这不是失败，但状态确实没续上',
  );

  /// 强制停止：**用户显式动作**，全框架唯一能因界面按钮而 `kill()` 的入口（D8）。
  ///
  /// 所以上面有确认对话框；而看门狗 / 心跳 / “跑得太久”都不得走到这里。
  Future<void> _forceStop(String id) async {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('强制停止这个插件？'),
        content: Text(
          '先按优雅路径要求它退出；它没走完时会被显式 kill。\n'
          '站点订阅、工具表与 UI 槽位会一并收掉。\n'
          '注意：条目仍是启用时，下一次对账会把它再拉起来 —— 想不再跑请关掉开关。',
          style: const TextStyle(fontSize: 12),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('plugin-force-stop-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            child: const Text('强制停止'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _submit(
      id,
      () => _admin.restartConfig(id, mode: 'force_stop'),
      successFrom: (Map<String, dynamic> result) =>
          (result['killed'] as num? ?? 0).toInt() > 0
              ? '已强制停止插件 $id（显式 kill；原因已记进日志）'
              : '已停止插件 $id（它自己走完了，没需要强杀）',
    );
  }

  /// 卡片的两个新动作（热重启 / 强制停止），放在既有按钮行**下面一行**。
  ///
  /// 为什么不挤进原来那行：五个 TextButton 在右栏那个宽度上会直接 RenderFlex 溢出
  /// （而溢出在 widget 测试里是以异常计数的，不是一个“看得到但拖一下”的小问题）；
  /// 用 [Wrap] 单独一行既能自适应也不丢可读性。
  List<Widget> _lifecycleActions(String id) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return <Widget>[
      TextButton(
        key: Key('plugin-hot-restart-$id'),
        onPressed: _busy.contains(id) ? null : () => _hotRestart(id),
        child: const Text('热重启（保留状态）', style: TextStyle(fontSize: 12)),
      ),
      TextButton(
        key: Key('plugin-force-stop-$id'),
        onPressed: _busy.contains(id) ? null : () => _forceStop(id),
        child: Text(
          '强制停止',
          style: TextStyle(fontSize: 12, color: cs.error),
        ),
      ),
    ];
  }

  Future<void> _delete(Map<String, dynamic> entry) async {
    final String id = (entry['id'] ?? '').toString();
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除插件？'),
        content: Text(
          '将从 plugins.yaml 里删除「$id」（条目与开关一并消失）。'
          '删除后需要重启核心才会断开正在运行的实例。',
          style: const TextStyle(fontSize: 12),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('plugin-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _submit(id, () => _admin.deleteConfig(id), successText: '已删除插件 $id');
  }

  /// 添加 / 编辑弹窗（内置插件也能编辑；id 不可改）。
  Future<void> _openEditor({
    Map<String, dynamic>? entry,
    Map<String, dynamic>? spec,
    bool isBuiltin = false,
  }) async {
    final Map<String, dynamic>? body = await PluginEditorDialog.show(
      context,
      entry: entry,
      builtinSpec: spec,
      isBuiltin: isBuiltin,
    );
    if (body == null || !mounted) return;
    final String id = (body['id'] ?? '').toString();
    if (entry != null) {
      await _submit(
        id,
        () => _admin.updateConfig(id, body),
        successText: '已保存插件 $id',
      );
      return;
    }
    await _submit(
      id,
      () => _admin.createConfig(body),
      successText: '已保存插件 $id',
    );
  }

  // ── 渲染 ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final PluginSnapshot? snap = _svc.snapshot;
    return Column(
      children: [
        if (widget.showHeader) _buildHeader(cs),
        if (!_svc.connected) _buildBanner(cs, '连接断开，正在重连…（下方为最近一次数据）'),
        if (_svc.error != null) _buildBanner(cs, '快照获取失败：${_svc.error}'),
        Expanded(child: _buildBody(cs, snap)),
      ],
    );
  }

  /// 头部：标题 + 连接指示 + 刷新按钮。
  Widget _buildHeader(ColorScheme cs) {
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: [
          Text(
            '插件管理',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _svc.connected ? Colors.green : Colors.orange,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            _svc.connected ? '已连接' : '未连接',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          const Spacer(),
          IconButton(
            tooltip: '刷新快照与插件清单',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: _svc.loading
                ? null
                : () {
                    _svc.refresh();
                    _loadAdmin();
                  },
            icon: _svc.loading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  /// 顶部提示条（断连 / 快照错误）。
  Widget _buildBanner(ColorScheme cs, String text) {
    return Container(
      width: double.infinity,
      color: cs.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: cs.onErrorContainer),
      ),
    );
  }

  /// 主体：按数据与连接状态渲染（断连 / 空 / 错误 / 数据四分支）。
  Widget _buildBody(ColorScheme cs, PluginSnapshot? snap) {
    if (snap == null) {
      if (!_svc.connected) {
        return _buildEmptyArea(cs, '等待连接…');
      }
      if (_svc.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return _buildEmptyArea(cs, '暂无数据');
    }
    // 用 CustomScrollView 而非 ListView：内容不足一屏时，底部剩余空白由
    // SliverFillRemaining 撑满，成为"点击空白处折叠左栏"的折叠区
    // （与 AgentList 的实现一致）。
    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.only(top: 8),
          sliver: SliverList(
            delegate: SliverChildListDelegate(<Widget>[_bodyContent(cs, snap)]),
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: _buildCollapseZone(cs, snap),
        ),
      ],
    );
  }

  /// 面板主体内容（各区块，原 ListView 的 children）。
  Widget _bodyContent(ColorScheme cs, PluginSnapshot snap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle(cs, '开关与配置'),
          _buildSwitchSection(cs, snap),
          const SizedBox(height: 12),
          _sectionTitle(cs, '插件实例（${_instanceCount(snap)}）'),
          _buildConfigPathHint(cs, snap),
          ..._buildInstances(cs, snap),
          const SizedBox(height: 12),
          _sectionTitle(cs, '从发布仓库更新'),
          _buildReleaseSection(cs),
          const SizedBox(height: 12),
          // M9 §3 的正式名字是「站点」（广播 / 执行 / 中转 / 收集四类），
          // 旧文案「处理站」是已废弃的旧名（旧「处理站」= 现在的中转站）。
          _sectionTitle(cs, _stationsTitle(snap)),
          if (snap.stations.isEmpty)
            _emptyHint(cs, _stationsEmptyText(snap))
          else
            ..._buildStationGroups(cs, snap),
          const SizedBox(height: 12),
          _sectionTitle(cs, '看门狗'),
          _buildWatchdog(cs, snap),
        ],
      ),
    );
  }

  /// 「插件实例」的条目数：清单可用 = 内置项 + 自定义项；否则退回快照实例数。
  int _instanceCount(PluginSnapshot snap) => _adminError == null
      ? _builtins.length + _customConfigs.length
      : snap.instances.length;

  /// 清单文件路径 + 生效方式（M9 §4.2 要求把"真实路径"与"怎么生效"写在界面上）。
  ///
  /// 文案刻意用「清单文件：」而不是「插件配置：」——站点段的空态里已经有一句
  /// 「插件配置：<路径>」，两处同名会让人以为是重复渲染。
  Widget _buildConfigPathHint(ColorScheme cs, PluginSnapshot snap) {
    final String path = _adminPath.isNotEmpty
        ? _adminPath
        : snap.pluginConfigPath;
    if (path.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '清单文件：$path（保存后立即热应用；热应用失败时重启核心生效）',
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      ),
    );
  }

  /// 插件实例区：内置 / 自定义两组；清单接口不可用时退回只读实例列表。
  List<Widget> _buildInstances(ColorScheme cs, PluginSnapshot snap) {
    if (_adminError != null) {
      return <Widget>[
        _emptyHint(cs, '插件清单接口不可用：$_adminError'),
        _emptyHint(cs, '（下面是快照里的运行态实例；升级核心后可直接在此增删改）'),
        if (snap.instances.isEmpty)
          _emptyHint(cs, _instancesEmptyText(snap))
        else
          ...snap.instances.map(
            (PluginInstanceInfo e) => _tappable(
              key: Key('plugin-detail-instance-${e.pluginId}'),
              onTap: () => _openInstanceDetail(e),
              card: _instanceCard(cs, e, snap.watchdog),
            ),
          ),
      ];
    }
    final List<Map<String, dynamic>> custom = _customConfigs;
    return <Widget>[
      _groupHeader(
        cs,
        '内置插件（${_builtins.length}）',
        trailing: IconButton(
          key: const Key('plugin-builtins-refresh'),
          tooltip: '重新解析内置插件的成品（从发布仓库装完点这里）',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          onPressed: () => _loadAdmin(refreshBuiltins: true),
          icon: const Icon(Icons.refresh),
        ),
      ),
      if (_builtins.isEmpty)
        _emptyHint(cs, '核心没有提供内置插件目录（旧核心？）')
      else
        ..._builtins.map(
          (Map<String, dynamic> b) => _tappable(
            key: Key('plugin-detail-builtin-${(b['id'] ?? '').toString()}'),
            onTap: () => _openBuiltinDetail(b),
            card: _builtinCard(cs, b),
          ),
        ),
      _groupHeader(
        cs,
        '自定义插件（${custom.length}）',
        trailing: TextButton.icon(
          key: const Key('plugin-add'),
          onPressed: () => _openEditor(),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('添加插件', style: TextStyle(fontSize: 12)),
        ),
      ),
      if (custom.isEmpty)
        _emptyHint(cs, '还没有自定义插件。点「添加插件」写一个（命令 = 要拉起的进程）。')
      else
        ...custom.map(
          (Map<String, dynamic> e) => _tappable(
            key: Key('plugin-detail-custom-${(e['id'] ?? '').toString()}'),
            onTap: () => _openCustomDetail(e),
            card: _configCard(cs, e),
          ),
        ),
    ];
  }

  /// 分组标题（内置 / 自定义），右侧可挂一个操作。
  Widget _groupHeader(ColorScheme cs, String text, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  /// 内置插件卡片：**每一项一个开关**；内置项不给删除（只给停用）。
  Widget _builtinCard(ColorScheme cs, Map<String, dynamic> item) {
    final String id = (item['id'] ?? '').toString();
    final String name = (item['name'] ?? '').toString();
    final bool enabled = item['enabled'] == true;
    final bool configured = item['configured'] == true;
    final Map<String, dynamic> entry =
        (item['config'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final Map<String, dynamic> resolution =
        (item['resolution'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final bool resolvable = resolution['ok'] == true;
    final String resolutionText = resolvable
        ? '运行时 ${resolution['command']} · 脚本 ${resolution['script_path']}'
        : '运行时未就绪：${resolution['error'] ?? '未知原因'}';
    final List<String> entryArgs = <String>[
      for (final Object? a in (entry['args'] as List<dynamic>? ?? <dynamic>[]))
        a.toString(),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  name.isEmpty ? id : name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _pill(cs, '内置', emphasize: true),
              const SizedBox(width: 6),
              _enabledLabel(cs, enabled),
              Switch(
                key: Key('plugin-switch-builtin-$id'),
                value: enabled,
                onChanged: _busy.contains(id)
                    ? null
                    : (bool value) => _toggleBuiltin(item, value),
              ),
            ],
          ),
          Text(id, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          if ((item['description'] ?? '').toString().isNotEmpty)
            Text(
              (item['description'] ?? '').toString(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          Text(
            resolutionText,
            style: TextStyle(
              fontSize: 11,
              color: resolvable ? cs.onSurfaceVariant : cs.error,
            ),
          ),
          if (!resolvable)
            // 2026-10-18：插件成品不再随安装包（只由 tree-plugins 的 release 提供），
            // 所以“解析不到”是新装机的**常态**而不是故障。上面那行只说“运行时未就绪：
            // 在 … 找不到 tree_xxx.exe”，读起来像坏了；这一行把用户引到他真能动手的
            // 地方——就地这颗「从仓库装它」（A+ 起按钮就在卡片上，不用再去下面那一节）。
            // 两条都留着：原始错误是诊断信息（它列了查找路径），不能拿指引替掉它。
            Text(
              '本机还没有这一份成品 · 点「从仓库装它」（装完回来再打开开关）',
              key: Key('plugin-builtin-needs-repo-$id'),
              style: TextStyle(fontSize: 11, color: cs.tertiary),
            ),
          // A+：同一颗按钮两种文案 —— 缺成品「从仓库装它」、已装/有更新「从仓库更新」。
          // 点它先自动刷新索引再 install；失败原因**就地**显示在这张卡上（不只 snack）。
          TextButton(
            key: Key('plugin-builtin-repo-$id'),
            onPressed: _busy.contains(id) ? null : () => _installFromRepo(id),
            child: Text(
              _busy.contains(id)
                  ? '正在处理…'
                  : (resolvable ? '从仓库更新' : '从仓库装它'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (_repoErrors.containsKey(id))
            Text(
              _repoErrors[id]!,
              key: Key('plugin-builtin-repo-error-$id'),
              style: TextStyle(fontSize: 11, color: cs.error),
            ),
          if (configured)
            Text(
              '命令：${entry['command']} ${entryArgs.join(' ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          Row(
            children: <Widget>[
              if (configured)
                TextButton(
                  key: Key('plugin-edit-$id'),
                  onPressed: _busy.contains(id)
                      ? null
                      : () => _openEditor(
                          entry: entry,
                          spec: item,
                          isBuiltin: true,
                        ),
                  child: const Text('编辑', style: TextStyle(fontSize: 12)),
                ),
              if (configured)
                TextButton(
                  key: Key('plugin-restart-$id'),
                  onPressed: _busy.contains(id) ? null : () => _restart(id),
                  child: const Text('重启', style: TextStyle(fontSize: 12)),
                ),
              Expanded(
                child: Text(
                  configured ? '内置插件不可删除；停用请用右侧开关' : '打开后可编辑（核心会解析运行时与脚本）',
                  style: TextStyle(fontSize: 10, color: cs.outline),
                ),
              ),
            ],
          ),
          // 热重启 / 强制停止（阶段 3）：只对已落盘的内置项开放。
          if (configured) Wrap(spacing: 4, children: _lifecycleActions(id)),
          _detailAffordance(cs, '看插件介绍与工具'),
        ],
      ),
    );
  }

  /// 自定义插件卡片：**每一项一个开关** + 编辑 / 删除 / 重启。
  Widget _configCard(ColorScheme cs, Map<String, dynamic> entry) {
    final String id = (entry['id'] ?? '').toString();
    final String name = (entry['name'] ?? '').toString();
    final bool enabled = entry['enabled'] != false;
    final Map<String, dynamic> runtime = _runtimeOf(id);
    final List<String> args = <String>[
      for (final Object? a in (entry['args'] as List<dynamic>? ?? <dynamic>[]))
        a.toString(),
    ];
    final Map<String, dynamic> scope = <String, dynamic>{};
    final Object? rawScope = entry['scope'];
    if (rawScope is Map) {
      for (final MapEntry<Object?, Object?> e in rawScope.entries) {
        scope[e.key.toString()] = e.value ?? '';
      }
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  name.isEmpty ? id : name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _enabledLabel(cs, enabled),
              Switch(
                key: Key('plugin-switch-custom-$id'),
                value: enabled,
                onChanged: _busy.contains(id)
                    ? null
                    : (bool value) => _toggleCustom(entry, value),
              ),
            ],
          ),
          if (name.isNotEmpty)
            Text(
              id,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          Text(
            '命令：${entry['command']} ${args.join(' ')}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          Text(
            '粒度 ${entry['granularity']} · scope: ${_scopeSummary(scope)}',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          Text(
            _runtimeText(enabled, runtime),
            style: TextStyle(
              fontSize: 11,
              color: _runtimeColor(cs, enabled, runtime),
            ),
          ),
          if ((runtime['error'] ?? '').toString().isNotEmpty)
            Text(
              '启动失败：${runtime['error']}',
              style: TextStyle(fontSize: 11, color: cs.error),
            ),
          // 心跳降级的原因（M9 §1.1：判活结果必须前端可见，且不能与"停用"混为一谈）
          if (runtime['health'] == 'degraded' &&
              (runtime['reason'] ?? '').toString().isNotEmpty)
            Text(
              '心跳降级：${runtime['reason']}（插件仍注册运行，非停用）',
              style: const TextStyle(fontSize: 11, color: Colors.orange),
            ),
          Row(
            children: <Widget>[
              TextButton(
                key: Key('plugin-edit-$id'),
                onPressed: _busy.contains(id)
                    ? null
                    : () => _openEditor(entry: entry),
                child: const Text('编辑', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                key: Key('plugin-restart-$id'),
                onPressed: _busy.contains(id) ? null : () => _restart(id),
                child: const Text('重启', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                key: Key('plugin-delete-$id'),
                onPressed: _busy.contains(id) ? null : () => _delete(entry),
                child: Text(
                  '删除',
                  style: TextStyle(fontSize: 12, color: cs.error),
                ),
              ),
            ],
          ),
          // 热重启 / 强制停止（阶段 3）：与「重启」并列而不是替掉它 ——
          // 三件事对用户的差别是“会不会丢状态”与“是不是必须立即停下”。
          Wrap(spacing: 4, children: _lifecycleActions(id)),
          _detailAffordance(cs, '看插件介绍与工具'),
        ],
      ),
    );
  }

  /// 「已启用 / 已停用」标签（每项自己的开关状态）。
  Widget _enabledLabel(ColorScheme cs, bool enabled) => Text(
    enabled ? '已启用' : '已停用',
    style: TextStyle(
      fontSize: 11,
      color: enabled ? Colors.green : cs.onSurfaceVariant,
    ),
  );

  /// 自定义插件的运行态一句话。
  ///
  /// known=false 表示这条配置**还没被总线对账过**（例如刚写盘、或在旧核心上）。
  /// 热应用（applyConfigs）落地后这种情况不再出现：写入即对账，所以这里
  /// 提示用户"可点重启或看原因"，而不是断言一定要重启核心。
  ///
  /// **阶段看 `lifecycle`**（阶段 2 新增的第三个轴）：重启中 / 已挂起都不能说成
  /// “未运行”——前者是安排内的一世交替（站点请求由核心有界暂存后重放），后者是
  /// 进程已退但快照已转储。两行都不写“失败/停用”：那是 `status` 与健康度的事。
  /// 旧核心没有这个键 ⇒ 空串 ⇒ 走下面的原有分支（行为与改动前逐字一致）。
  String _runtimeText(bool enabled, Map<String, dynamic> runtime) {
    if (!enabled) return '状态：已停用（条目保留）';
    final String lifecycle = (runtime['lifecycle'] ?? '').toString();
    if (lifecycle == PluginInstanceInfo.lifecycleRestarting) {
      return '状态：重启中（暂时不接新活，站点请求由核心暂存后重放）';
    }
    if (lifecycle == PluginInstanceInfo.lifecycleSuspended) {
      return '状态：已挂起（可续跑状态已转储给核心，等下一世取回）';
    }
    if (runtime['running'] == true) {
      return runtime['health'] == 'degraded' ? '状态：运行中（心跳降级，仍注册）' : '状态：运行中';
    }
    if (runtime['known'] == true) return '状态：已启用但未运行（可点「重启」）';
    return '状态：已启用但未运行（可点「重启」，或看上方原因）';
  }

  /// 运行态颜色（与 [_runtimeText] 同一判据顺序，否则文字说“重启中”而颜色说“没跑”）。
  ///
  /// 重启中 / 已挂起都用蓝色：它不是错（橙色 = 降级、红色 = 失败），但也不是“一切照旧”。
  Color _runtimeColor(
    ColorScheme cs,
    bool enabled,
    Map<String, dynamic> runtime,
  ) {
    if (!enabled) return cs.onSurfaceVariant;
    final String lifecycle = (runtime['lifecycle'] ?? '').toString();
    if (lifecycle == PluginInstanceInfo.lifecycleRestarting ||
        lifecycle == PluginInstanceInfo.lifecycleSuspended) {
      return Colors.lightBlue;
    }
    if (runtime['health'] == 'degraded') return Colors.orange;
    if (runtime['running'] == true) return Colors.green;
    return cs.onSurfaceVariant;
  }

  /// 空态占位（等待连接 / 暂无数据），点击任意空白处折叠左栏。
  Widget _buildEmptyArea(ColorScheme cs, String text) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onCollapse,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              text,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            if (widget.onCollapse != null) ...<Widget>[
              const SizedBox(height: 10),
              _buildCollapseHint(cs, ''),
            ],
          ],
        ),
      ),
    );
  }

  /// 数据态下方的折叠区：占满内容之外的剩余空白，点击即折叠左栏。
  ///
  /// 内容超过一屏时该区域被挤到滚动末尾，折叠入口仍保留在标题栏与活动栏。
  Widget _buildCollapseZone(ColorScheme cs, PluginSnapshot snap) {
    // 没有任何实例时，在折叠提示上方补一行空态说明：面板数据稀疏时，
    // 下方大片空白容易被误认为"还在加载"。
    final String hint = snap.instances.isNotEmpty ? '' : '暂无插件实例';
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onCollapse,
      child: Container(
        width: double.infinity,
        alignment: Alignment.center,
        padding: const EdgeInsets.only(top: 16, bottom: 24),
        child: _buildCollapseHint(cs, hint),
      ),
    );
  }

  /// 折叠提示（图标 + 文案，可选上方附加一行空态说明）。
  ///
  /// 仅注册 onTap：同时注册 onDoubleTap 会让 GestureDetector 等待双击超时
  /// （约 300ms）再响应单击，折叠出现明显延迟。
  Widget _buildCollapseHint(ColorScheme cs, String extra) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (extra.isNotEmpty) ...<Widget>[
          Text(
            extra,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
        ],
        if (widget.onCollapse != null) ...<Widget>[
          Icon(Icons.chevron_left, size: 20, color: cs.outline),
          const SizedBox(height: 4),
          Text('点击空白处折叠左栏', style: TextStyle(fontSize: 11, color: cs.outline)),
        ],
      ],
    );
  }

  /// 开关与配置摘要（配置按白名单裁剪，未知键忽略）。
  Widget _buildSwitchSection(ColorScheme cs, PluginSnapshot snap) {
    final List<Widget> pills = <Widget>[
      _pill(cs, snap.enabled ? '已启用' : '未启用', emphasize: snap.enabled),
      _pill(cs, '每个插件各自一个开关'),
    ];
    if (snap.generatedAt != null) {
      pills.add(_pill(cs, '更新于 ${_relativeTime(snap.generatedAt)}'));
    }
    const List<String> configWhitelist = <String>[
      'station_timeout_s',
      'instance_ttl_s',
      'status_max_per_sec',
    ];
    for (final String k in configWhitelist) {
      final Object? v = snap.config[k];
      if (v != null) {
        pills.add(_pill(cs, '$k: $v'));
      }
    }
    return Wrap(spacing: 6, runSpacing: 6, children: pills);
  }

  /// 「从发布仓库更新」区块。
  ///
  /// 三件事必须看得见：**这不是最新**（离线/缓存要说清，不然看起来就像最新的）、
  /// **这一条为什么没出现**（skipped 的原因逐条写出来，不静默）、**装它会怎样**
  /// （旧进程没退就换不了文件 —— 那句话由核心的可读回包给出，面板原样显示，
  /// 不自己编第二套说法）。
  Widget _buildReleaseSection(ColorScheme cs) {
    final String source = _releaseOnline
        ? (_releaseTag.isEmpty ? '刚拉的索引' : '刚拉的索引（release $_releaseTag）')
        : (_releaseTag.isEmpty
              ? '本地缓存（还没拉过）'
              : '本地缓存（release $_releaseTag，不是最新）');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '只读 GitHub Release 资产（不拉插件源码）。当前：$source',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ),
            if (_releaseLoading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton(
                key: const Key('plugin-release-refresh'),
                onPressed: _refreshRelease,
                child: const Text('刷新'),
              ),
          ],
        ),
        if (_releaseError.isNotEmpty)
          Text(_releaseError, style: TextStyle(fontSize: 11, color: cs.error)),
        if (_releaseIndexPath.isNotEmpty)
          Text(
            '索引：$_releaseIndexPath',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        if (_releaseEntries.isEmpty && _releaseError.isEmpty)
          _emptyHint(
            cs,
            '索引里没有可装的条目（发布时要把 plugin-index.json 与各插件文件一起传到 release）',
          )
        else
          for (final Map<String, dynamic> entry in _releaseEntries)
            _releaseRow(cs, entry),
        if (_releaseSkipped.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          for (final String line in _releaseSkipped)
            Text(
              '跳过：$line',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
        ],
      ],
    );
  }

  /// 一条发布条目（名字 + 版本对比 + 装它那颗按钮）。
  ///
  /// “已是最新”时按钮**禁用而不是隐藏**：隐藏会让人以为这一条不能装，而它其实
  /// 只是没必要再装一次。提交期间该条目禁用（连点会叠出两次放置）。
  Widget _releaseRow(ColorScheme cs, Map<String, dynamic> entry) {
    final String id = (entry['plugin_id'] ?? '').toString();
    final String name = (entry['name'] ?? '').toString();
    final String version = (entry['version'] ?? '').toString();
    final String installed = (entry['installed_version'] ?? '').toString();
    final bool hasUpdate = entry['has_update'] == true;
    final String title = name.isEmpty ? id : name;
    final bool busy = _busy.contains(id);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (title != id)
                  Text(
                    id,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                Text(
                  installed.isEmpty
                      ? '发布 $version · 本机未装'
                      : '发布 $version · 本机 $installed',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (!hasUpdate && installed.isNotEmpty) _pill(cs, '已是最新'),
          const SizedBox(width: 6),
          TextButton(
            key: Key('plugin-release-install-$id'),
            onPressed: hasUpdate && !busy ? () => _installRelease(id) : null,
            child: Text(
              busy
                  ? '安装中…'
                  : (installed.isEmpty
                        ? '安装'
                        : (hasUpdate ? '更新' : '已是最新')),
            ),
          ),
        ],
      ),
    );
  }

  /// 看门狗概要。
  ///
  /// 「判死」在 M9 §1.1 下恒为 0：心跳巡检只标健康度（degraded）**不终止插件**，
  /// 所以真正要看的数字是「降级」——有降级实例时该 pill 转橙提示。
  Widget _buildWatchdog(ColorScheme cs, PluginSnapshot snap) {
    final PluginWatchdogInfo? w = snap.watchdog;
    if (w == null) {
      return _emptyHint(cs, '暂无数据');
    }
    final int? degraded = w.degradedCount;
    final List<Widget> pills = <Widget>[
      _pill(cs, '活跃 runs: ${w.activeRuns}'),
      _pill(cs, '判死: ${w.judgedDead}'),
      if (degraded != null)
        _pill(cs, '降级: $degraded', color: degraded > 0 ? Colors.orange : null),
      if (w.intervalS != null && w.missThreshold != null)
        _pill(cs, '判活窗口 ${_trimNumber(w.intervalS!)}s×${w.missThreshold}'),
    ];
    return Wrap(spacing: 6, runSpacing: 6, children: pills);
  }

  /// 单个插件实例卡片（**清单接口不可用时的兜底**：只读运行态）。
  ///
  /// 健康度（M9 §1.1）：心跳连续丢失 ⇒ 角标「心跳降级」+ 一行说明；
  /// 此时 **状态标签仍是「已注册」**——降级不是停用，文案不得写成"已停用"。
  ///
  /// 生命周期（阶段 2）：另加一个角标（「重启中」/「已挂起」/「启动中」）。
  /// **活性看 `health`、启停看 `status`、阶段看 `lifecycle`**：三个轴各自成图，
  /// 谁也不吃掉谁——重启中的实例仍是「已注册」，也不会因为重启而被报成降级。
  /// 旧核心没有 lifecycle ⇒ 不渲染角标（与改动前逐字一致）。
  Widget _instanceCard(
    ColorScheme cs,
    PluginInstanceInfo e,
    PluginWatchdogInfo? watchdog,
  ) {
    final String title = e.name.isNotEmpty ? e.name : e.pluginId;
    final List<String> meta = <String>[
      if (e.granularity.isNotEmpty) '粒度 ${e.granularity}',
      '心跳 ${_relativeTime(e.lastHeartbeat)}',
      if (e.missedHeartbeats != null && e.missedHeartbeats! > 0)
        '丢失 ${e.missedHeartbeats} 拍',
      if (e.queueDepth != null && e.queueDepth! > 0) '队列 ${e.queueDepth}',
      // 阶段与代际：只在核心真的报了 lifecycle 时才写（旧核心不臆测）
      if (e.lifecycle.isNotEmpty) '阶段 ${pluginLifecycleText(e.lifecycle)}',
      if (e.generation != null && e.generation! > 0) '第 ${e.generation} 代',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(
          // 降级实例描边转橙：不靠读文字也能一眼扫到
          color: e.isDegraded
              ? Colors.orange.withValues(alpha: 0.7)
              : Theme.of(context).dividerColor,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (e.isDegraded) ...<Widget>[
                _pill(cs, '心跳降级', color: Colors.orange),
                const SizedBox(width: 6),
              ],
              // 生命周期角标（阶段 2）：与上面的降级角标互不干扰，两个轴各说各的事。
              if (_lifecyclePill(cs, e.lifecycle) != null) ...<Widget>[
                _lifecyclePill(cs, e.lifecycle)!,
                const SizedBox(width: 6),
              ],
              _statusLabel(cs, e.status),
            ],
          ),
          if (title != e.pluginId)
            Text(
              e.pluginId,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          const SizedBox(height: 2),
          Text(
            meta.join(' · '),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          Text(
            'scope: ${_scopeSummary(e.scope)}',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          if (e.isDegraded)
            Text(
              _degradedDetail(e, watchdog),
              style: const TextStyle(fontSize: 11, color: Colors.orange),
            ),
          if (e.disabledReason.isNotEmpty)
            Text(
              '停用原因: ${e.disabledReason}',
              style: TextStyle(fontSize: 11, color: cs.error),
            ),
          _detailAffordance(cs, '看插件介绍与工具'),
        ],
      ),
    );
  }

  /// 生命周期角标（阶段 2）：只给「需要用户看得见的中间态」上角标。
  ///
  /// 就绪 / 未运行 不上角标：它们与旁边的 [pluginStatusText] 标签（已注册 / 已停用）
  /// 说的是同一件事的两个面，多一个角标只会让人以为出了新情况。返回 null = 不渲染
  ///（包括旧核心没报 lifecycle 的空值 ⇒ 面板与改动前逐字一致）。
  Widget? _lifecyclePill(ColorScheme cs, String lifecycle) {
    switch (lifecycle) {
      case PluginInstanceInfo.lifecycleRestarting:
      case PluginInstanceInfo.lifecycleBooting:
        return _pill(cs, pluginLifecycleText(lifecycle), color: Colors.lightBlue);
      case PluginInstanceInfo.lifecycleSuspended:
        return _pill(cs, '已挂起', color: Colors.teal);
      case PluginInstanceInfo.lifecycleFailed:
        return _pill(cs, '本轮失败', color: cs.error);
      default:
        return null;
    }
  }

  /// 降级说明（角标下方那行橙字）：原因 + 丢失拍数 + 判活窗口 I×N。
  ///
  /// 文案纪律：**不出现"已停用"**——降级 = 心跳连续丢失，插件仍注册、仍在跑，
  /// 心跳恢复即自动清除；缺失的字段不臆测（缺失就不写）。
  String _degradedDetail(PluginInstanceInfo e, PluginWatchdogInfo? watchdog) {
    final int? n = watchdog?.missThreshold;
    final double? interval = e.heartbeatIntervalS ?? watchdog?.intervalS;
    final String head = e.degradedReason.isNotEmpty
        ? e.degradedReason
        : (n != null ? '连续 $n 拍未收到心跳' : '心跳连续丢失');
    final List<String> tail = <String>[
      '插件仍注册运行（非停用）',
      if (e.missedHeartbeats != null) '丢失 ${e.missedHeartbeats} 拍',
      if (interval != null && n != null)
        '判活窗口 ${_trimNumber(interval)}s×$n'
      else if (interval != null)
        '心跳间隔 ${_trimNumber(interval)}s',
    ];
    return '$head · ${tail.join(' · ')}';
  }

  /// 秒数去掉多余小数（30.0 → 30；2.5 → 2.5）。
  String _trimNumber(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);

  /// 四类站点的展示顺序与中文名（与核心 `StationKind` 的四类一一对应）。
  ///
  /// **列全四类是刻意的**：站点语义是"每类站点全局唯一"，所以"面板上有几类站"
  /// 本身就是语义的一部分。只列实例的话（收集站由接入点需要时才现建）用户看到的
  /// 是"三站"，与文档里的"四站体系"对不上。
  static const List<({String wire, String label})> _stationKinds =
      <({String wire, String label})>[
        (wire: 'broadcast', label: '广播站'),
        (wire: 'execute', label: '执行站'),
        (wire: 'relay', label: '中转站'),
        (wire: 'collect', label: '收集站'),
      ];

  /// 站点段标题：计数用「已建 N/4 类」而不是裸实例数。
  ///
  /// 裸实例数会被读成"站点体系只有三条腿"——收集站按需创建，没接入点用工具申报时
  /// 根本就不存在。写成"已建 N/4 类"才能同时表达"体系有四类"与"实建了几类"。
  String _stationsTitle(PluginSnapshot snap) {
    final int materialized = _stationKinds
        .where(
          (({String wire, String label}) k) =>
              snap.stations.any((PluginStationInfo s) => s.kind == k.wire),
        )
        .length;
    return '站点（已建 $materialized/${_stationKinds.length} 类）';
  }

  /// 站点分四类列出（每类一个分组头，组内是该类的具体站点）。
  ///
  /// 三件事：
  /// 1. **按类型分组**（广播 / 执行 / 中转 / 收集，顺序固定），类型名取自核心给的
  ///    `kind_label`，缺失时按线名兜底；
  /// 2. **空类也列**，并注明"未创建"——否则用户会以为该类站点不存在（收集站正是
  ///    按需创建的那一个）；
  /// 3. 认不出的类型（旧核心 / 将来新增）归入「其他」，不丢站点。
  List<Widget> _buildStationGroups(ColorScheme cs, PluginSnapshot snap) {
    final List<Widget> out = <Widget>[];
    final Set<String> known = <String>{
      for (final ({String wire, String label}) k in _stationKinds) k.wire,
    };
    for (final ({String wire, String label}) k in _stationKinds) {
      final List<PluginStationInfo> group = snap.stations
          .where((PluginStationInfo s) => s.kind == k.wire)
          .toList(growable: false);
      out.add(_stationGroupHeader(cs, _stationKindLabel(k, group), group.length));
      if (group.isEmpty) {
        out.add(_emptyHint(cs, '未创建（该类站点按需创建）'));
        continue;
      }
      out.addAll(
        group.map(
          (PluginStationInfo s) => _tappable(
            key: Key('station-detail-${s.stationId}'),
            onTap: () => _openStationDetail(s.stationId),
            card: _stationCard(cs, s),
          ),
        ),
      );
    }
    final List<PluginStationInfo> others = snap.stations
        .where((PluginStationInfo s) => !known.contains(s.kind))
        .toList(growable: false);
    if (others.isNotEmpty) {
      out.add(_stationGroupHeader(cs, '其他（类型未知）', others.length));
      out.addAll(
        others.map(
          (PluginStationInfo s) => _tappable(
            key: Key('station-detail-${s.stationId}'),
            onTap: () => _openStationDetail(s.stationId),
            card: _stationCard(cs, s),
          ),
        ),
      );
    }
    return out;
  }

  /// 分组头：类型名 + 该类站点数（弱化样式，与区块标题区分开）。
  Widget _stationGroupHeader(ColorScheme cs, String label, int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 5),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 分组头的类型名：核心的中文名优先（同组内取第一个非空），否则用本地常量，
  /// 再不然回退线名（不猜）。
  String _stationKindLabel(
    ({String wire, String label}) kind,
    List<PluginStationInfo> group,
  ) {
    for (final PluginStationInfo s in group) {
      if (s.kindLabel.isNotEmpty) return s.kindLabel;
    }
    return kind.label;
  }

  /// 单个站点卡片（计数白名单裁剪，未知键忽略）。
  ///
  /// 展示口径（M9 §3，站点全局化后）：
  /// **类型用核心给的 kind / kind_label**（中文名不写死在前端，旧核心缺 kind_label
  /// 时按线名兜底、两者都认不出就不显示类型标签），内置站打「内置」标识，
  /// 订阅数用核心给的 subscriber_count。
  ///
  /// **team 视角改看订阅者分组**（`subscribers_by_team`）：站点全局唯一、不绑 team，
  /// 所以"哪些团队在用这个站"只能由订阅声明回答；不再显示 mode_key 摘要。
  Widget _stationCard(ColorScheme cs, PluginStationInfo s) {
    final String kindLabel = s.displayKindLabel;
    final String subscriber =
        s.subscriptions.isEmpty || s.subscriptions.first.subscriber.isEmpty
        ? '—'
        : s.subscriptions.first.subscriber;
    final String subNote = s.subscriptions.length > 1
        ? '（+${s.subscriptions.length - 1}）'
        : '';
    // 团队分组摘要：`team（n）`，多个用「、」连；没有订阅者时不显示这一行。
    final String teamSummary = s.subscribersByTeam.entries
        .map(
          (MapEntry<String, int> e) =>
              '${e.key.isEmpty ? '全部 team（未限定）' : e.key}（${e.value}）',
        )
        .join('、');
    const List<String> countKeys = <String>[
      'requests',
      'responded',
      'timeout',
      'cancelled',
      'no_subscriber',
      'overflow',
      'handler_error',
    ];
    final List<Widget> countPills = <Widget>[];
    for (final String k in countKeys) {
      final int? v = s.counts[k];
      if (v != null) {
        countPills.add(_pill(cs, '$k: $v'));
      }
    }
    if (s.waitsInFlight != null) {
      countPills.add(_pill(cs, '等待中: ${s.waitsInFlight}'));
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.stationId,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (kindLabel.isNotEmpty) ...[
                _pill(cs, kindLabel, emphasize: true),
                const SizedBox(width: 6),
              ],
              if (s.builtin) _pill(cs, '内置'),
            ],
          ),
          if (s.description.isNotEmpty)
            Text(
              s.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          Text(
            '订阅（${s.subscriberCount}）: $subscriber$subNote',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          if (teamSummary.isNotEmpty)
            Text(
              '团队: $teamSummary',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          if (countPills.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 6, children: countPills),
          ],
          _detailAffordance(cs, '看站点介绍与配置'),
        ],
      ),
    );
  }

  /// 插件实例段的空态说明。
  ///
  /// 用户实机反馈（截图）：「插件实例（0）／暂无插件实例」没说清**插件配在哪**。
  /// 插件来自快照里的配置文件（config.path，默认 <数据根>/config/plugins.yaml），
  /// 所以这里直接把路径写出来，并说明"改完要重启核心"。路径缺失（旧核心 / 未接入
  /// 总线）时退回原来那句，不臆测路径。
  String _instancesEmptyText(PluginSnapshot snap) {
    final String path = snap.pluginConfigPath;
    if (path.isEmpty) {
      return '暂无插件实例';
    }
    return '暂无插件实例\n插件配置在 $path（可直接编辑，保存后重启核心生效）';
  }

  /// 站点段的空态说明（可直接照做的文案）。
  ///
  /// 站点全局化后的口径：**每类站全局只有一个实例**（广播 / 执行 / 中转在核心启动
  /// 时就位，收集站由接入点需要时现建），team / agent / session / mode 是**每次交互
  /// 携带的信封**，不再是站点维度。真的为空只剩一种情况：数据来自没有预建逻辑的
  /// 旧核心（正常核心启动后至少有三站）。
  String _stationsEmptyText(PluginSnapshot snap) {
    final StringBuffer buffer = StringBuffer(
      '暂无站点实例。'
      '内置四站（广播 / 执行 / 中转 / 收集）全局各一个：前三站在核心启动时'
      '自动就位，收集站按需创建（如插件申报工具时）；'
      'team / session / agent 随每次交互携带，不把站点按团队拆开。',
    );
    final String path = snap.pluginConfigPath;
    if (path.isNotEmpty) {
      buffer.write('\n插件配置：$path');
    }
    return buffer.toString();
  }

  /// 状态文本（未知状态原样展示、不崩；口径与详情页共用 [pluginStatusText]）。
  Widget _statusLabel(ColorScheme cs, String status) {
    final String label = pluginStatusText(status);
    final Color color;
    switch (status) {
      case 'registered':
        color = Colors.green;
        break;
      case 'disabled':
        color = cs.error;
        break;
      case 'destroyed':
        color = cs.onSurfaceVariant;
        break;
      default:
        color = cs.onSurfaceVariant;
        break;
    }
    return Text(label, style: TextStyle(fontSize: 11, color: color));
  }

  /// 小圆角标签。
  ///
  /// [color] 覆盖文字色（如降级用橙色）；[emphasize] 给"当前态"标签上底色。
  Widget _pill(
    ColorScheme cs,
    String text, {
    bool emphasize = false,
    Color? color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: emphasize ? cs.primaryContainer : null,
        border: emphasize ? null : Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color:
              color ??
              (emphasize ? cs.onPrimaryContainer : cs.onSurfaceVariant),
        ),
      ),
    );
  }

  /// 区块标题。
  Widget _sectionTitle(ColorScheme cs, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 区块空提示。
  Widget _emptyHint(ColorScheme cs, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
    );
  }

  /// scope 摘要（仅展示非空维度；空则 '—'）。
  ///
  /// **mode_key 必须显示**（M9 §1.2）：local / ssh 是站点隔离的关键维度，
  /// 同一个团队在两个工作面上是两个不同实例（id 就带 @local / @ssh）——
  /// 面板上看不出模式，用户就无法理解"为什么有两个广播站"。
  String _scopeSummary(Map<String, dynamic> scope) {
    final List<String> parts = <String>[];
    for (final String k in <String>[
      'team_id',
      'agent_id',
      'session_id',
      'mode_key',
    ]) {
      final String v = (scope[k] ?? '').toString();
      if (v.isNotEmpty) {
        parts.add('$k=$v');
      }
    }
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  /// 相对时间（epoch 秒 → 'Ns 前' / 'Nmin 前' / 'Nh 前' / 日期）。
  String _relativeTime(double? ts) {
    if (ts == null) {
      return '—';
    }
    final DateTime t = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    final Duration diff = DateTime.now().difference(t);
    if (diff.inSeconds >= 0 && diff.inSeconds < 60) {
      return '${diff.inSeconds}s 前';
    }
    if (diff.inMinutes >= 0 && diff.inMinutes < 60) {
      return '${diff.inMinutes}min 前';
    }
    if (diff.inHours >= 0 && diff.inHours < 24) {
      return '${diff.inHours}h 前';
    }
    return t.toLocal().toString().split('.').first;
  }
}
