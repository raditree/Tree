import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_version.dart';
import '../../io/api_service.dart';
import '../theme_service.dart';

/// 设置页面（desktop 分支：账号/等级/密码/后端地址/注销 五组设置已删除）
///
/// 保留的设置项：
/// - token 获取帧率 / 推送刷新帧率 / 消息切入模式：agent 运行节奏控制
/// - 心跳判活参数（I=心跳间隔秒 / N=连续丢失阈值次）：核心判"链路失活"的唯一判据
///   （M9 规约 1.1 取消了静态时间超时）；判活窗口 I×N 必须大于前端固定的 10s 心跳
/// - 自定义模型：模型池 CRUD（M2 起落 `~/.tree/config/models/*.yaml`）
/// - 主题管理：浅色 / 深色 / 跟随系统三种模式
/// - 插件开发：文档入口（打开 `plugins/README.md`）+ 插件目录定位
/// - 版本信息：应用 / 核心 / 接口契约 / 核心进程与产物（含"核心比界面旧"告警）
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.versionInfo});

  /// 版本信息数据源（**测试注入用**；null = 从核心启动器读当前运行态）。
  final VersionInfo? versionInfo;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // --- 消息切入模式（false=串行排队，true=直接切入） ---
  bool _directCutin = false;

  // --- token 获取帧率（从 LLM 流逐 token 取回复的节奏，帧/秒，20~1000） ---
  int _tokenRate = 1000;
  int _tokenRateMin = 20;
  int _tokenRateMax = 1000;

  /// 后端 token 帧率是否已加载。加载前不渲染滑块：_tokenRate 的初值是上限
  /// （1000，滑块最右端），加载完成后会左移到真实值，视觉上会先跳到最右再回来。
  bool _tokenRateLoaded = false;

  // --- 推送刷新帧率（把流式增量攒帧后合并下发的频率，帧/秒，20~1000） ---
  int _frameRate = 20;
  int _frameRateMin = 20;
  int _frameRateMax = 1000;

  /// 后端推送帧率是否已加载（同 [_tokenRateLoaded]，加载前不渲染滑块）。
  bool _frameRateLoaded = false;

  /// token 获取帧率输入框（允许直接键入，提交时按范围夹取）
  final TextEditingController _tokenRateController = TextEditingController();

  /// 推送刷新帧率输入框（允许用户直接键入，提交时按范围夹取）
  final TextEditingController _frameRateController = TextEditingController();

  // --- 心跳判活参数（判活窗口 = 心跳间隔 I × 连续丢失阈值 N，必须 > 前端 10s 心跳） ---
  int _heartbeatIntervalSeconds = 10;
  int _heartbeatIntervalMin = 1;
  int _heartbeatIntervalMax = 600;
  int _missedHeartbeatLimit = 3;
  int _missedHeartbeatLimitMin = 1;
  int _missedHeartbeatLimitMax = 60;

  /// 判活窗口必须**严格大于**的下限（秒）：前端 WS 心跳固定 10s
  /// （lib/io/websocket_service.dart，本页不可调），窗口不足会把"在线但空闲"的
  /// 连接判成失活并反复重连。
  int _minLivenessWindowSeconds = 10;

  /// 当前生效的判活窗口（= I×N，秒）。
  int _livenessWindowSeconds = 30;

  /// 核心侧**在线生效**的值：与设置值不一致 = 要重启核心（或该消费者重建）才完全一致。
  int _liveIntervalSeconds = 10;
  int _liveMissLimit = 3;

  /// 最近一次夹取的可读原因（没有夹取则为 null）。
  String? _livenessNotice;

  /// 心跳间隔 / 丢失阈值输入框
  final TextEditingController _heartbeatIntervalController =
      TextEditingController();
  final TextEditingController _missedHeartbeatLimitController =
      TextEditingController();

  // --- 自定义模型（设置页 CRUD） ---
  List<Map<String, dynamic>> _models = <Map<String, dynamic>>[];
  bool _modelsLoading = false;
  String? _modelsError;

  // --- 插件开发入口（M9 §4.2 的开发面） ---

  /// 插件清单的**真实路径**（从插件快照拿；拿不到则为 null）。
  ///
  /// 为什么不写死 `<数据根>/config/plugins.yaml`：数据根可被环境变量改，猜出来的
  /// 路径会把用户送到一个不存在的地方。拿不到就退回"去插件面板看"的指引。
  String? _pluginConfigPath;

  @override
  void initState() {
    super.initState();
    _loadMessageCutinSetting();
    _loadTokenRateSetting();
    _loadFrameRateSetting();
    _loadHeartbeatSetting();
    _loadModelList();
    _loadPluginConfigPath();
  }

  /// 读插件快照，只为拿 `config.path`（插件清单的真实路径）。
  ///
  /// 失败**不报错也不阻塞**：这只是设置页的一个提示行，拿不到就退回"去插件面板看"
  /// ——版本 / 开发信息本身不依赖核心可用（应用与核心都起来时才有快照）。
  Future<void> _loadPluginConfigPath() async {
    try {
      final Map<String, dynamic> snap = await ApiService.getPluginSnapshot();
      final Object? config = snap['config'];
      final String path = config is Map
          ? (config['path'] ?? '').toString()
          : '';
      if (!mounted || path.isEmpty) return;
      setState(() => _pluginConfigPath = path);
    } catch (_) {
      // 核心不可达 / 未接入插件总线：保留指引文案
    }
  }

  @override
  void dispose() {
    _tokenRateController.dispose();
    _frameRateController.dispose();
    _heartbeatIntervalController.dispose();
    _missedHeartbeatLimitController.dispose();
    super.dispose();
  }

  /// 加载消息切入模式设置
  Future<void> _loadMessageCutinSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final local = prefs.getBool('message_cutin_direct') ?? false;
    if (mounted) {
      setState(() => _directCutin = local);
    }
    // 尝试从后端拉取权威状态（后端未启动/未登录时忽略，保留本地值）
    try {
      final bool remote = await ApiService.getMessageCutinDirect();
      if (mounted) setState(() => _directCutin = remote);
    } catch (_) {
      // 后端不可达时保留本地持久化值
    }
  }

  /// 切换消息切入模式（false=串行排队，true=直接切入）
  Future<void> _toggleMessageCutin(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('message_cutin_direct', value);
    try {
      await ApiService.setMessageCutinDirect(value);
    } catch (_) {
      // 后端设置失败不阻塞本地持久化
    }
    if (mounted) {
      setState(() => _directCutin = value);
    }
  }

  /// 加载 token 获取帧率设置（权威值来自后端；后端不可达时用默认 1000）
  Future<void> _loadTokenRateSetting() async {
    try {
      final Map<String, dynamic> data = await ApiService.getTokenRate();
      if (!mounted) return;
      final int rate = (data['token_rate'] as num?)?.toInt() ?? _tokenRate;
      final int min = (data['min'] as num?)?.toInt() ?? _tokenRateMin;
      final int max = (data['max'] as num?)?.toInt() ?? _tokenRateMax;
      setState(() {
        _tokenRate = rate;
        _tokenRateMin = min;
        _tokenRateMax = max;
        _tokenRateController.text = '$rate';
        _tokenRateLoaded = true;
      });
    } catch (_) {
      // 后端不可达：保留默认值，控件仍可编辑（提交时后端会夹取范围）
      if (mounted) {
        setState(() {
          _tokenRateController.text = '$_tokenRate';
          _tokenRateLoaded = true;
        });
      }
    }
  }

  /// 提交 token 获取帧率（按后端声明的范围夹取，以后端返回的生效值为准）
  Future<void> _applyTokenRate(int value) async {
    final int clamped = value < _tokenRateMin
        ? _tokenRateMin
        : (value > _tokenRateMax ? _tokenRateMax : value);
    try {
      final int effective = await ApiService.setTokenRate(clamped);
      if (!mounted) return;
      setState(() {
        _tokenRate = effective;
        _tokenRateController.text = '$effective';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _tokenRateController.text = '$_tokenRate');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('token 帧率设置失败：$e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 加载推送刷新帧率设置（权威值来自后端；后端不可达时用默认 20）
  Future<void> _loadFrameRateSetting() async {
    try {
      final Map<String, dynamic> data = await ApiService.getFrameRate();
      if (!mounted) return;
      final int rate = (data['frame_rate'] as num?)?.toInt() ?? _frameRate;
      final int min = (data['min'] as num?)?.toInt() ?? _frameRateMin;
      final int max = (data['max'] as num?)?.toInt() ?? _frameRateMax;
      setState(() {
        _frameRate = rate;
        _frameRateMin = min;
        _frameRateMax = max;
        _frameRateController.text = '$rate';
        _frameRateLoaded = true;
      });
    } catch (_) {
      // 后端不可达：保留默认值，控件仍可编辑（提交时后端会夹取范围）
      if (mounted) {
        setState(() {
          _frameRateController.text = '$_frameRate';
          _frameRateLoaded = true;
        });
      }
    }
  }

  /// 提交推送刷新帧率（按后端声明的范围夹取，以后端返回的生效值为准）
  Future<void> _applyFrameRate(int value) async {
    final int clamped = value < _frameRateMin
        ? _frameRateMin
        : (value > _frameRateMax ? _frameRateMax : value);
    try {
      final int effective = await ApiService.setFrameRate(clamped);
      if (!mounted) return;
      setState(() {
        _frameRate = effective;
        _frameRateController.text = '$effective';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _frameRateController.text = '$_frameRate');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('帧率设置失败：$e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 加载心跳判活参数（权威值来自后端；后端不可达时保留默认 10s / 3 次）
  Future<void> _loadHeartbeatSetting() async {
    try {
      final Map<String, dynamic> data =
          await ApiService.getHeartbeatLivenessSettings();
      _applyHeartbeatResponse(data);
    } catch (_) {
      // 后端不可达：保留默认值，控件仍可编辑（提交时后端还会再夹一次）
      if (mounted) {
        setState(() {
          _heartbeatIntervalController.text = '$_heartbeatIntervalSeconds';
          _missedHeartbeatLimitController.text = '$_missedHeartbeatLimit';
        });
      }
    }
  }

  /// 把后端返回的心跳判活参数写进界面。
  ///
  /// 两个端点（heartbeat-interval / missed-heartbeat-limit）的响应**同形状**，
  /// 所以只解析一次：值、各自区间、当前的判活窗口、核心侧在线生效值、夹取说明。
  /// [fallbackNotice] 是前端预夹取时自己生成的说明（后端没夹取时用它）。
  void _applyHeartbeatResponse(
    Map<String, dynamic> data, {
    String? fallbackNotice,
  }) {
    if (!mounted) return;
    setState(() {
      _heartbeatIntervalSeconds =
          (data['heartbeat_interval'] as num?)?.toInt() ??
          _heartbeatIntervalSeconds;
      _missedHeartbeatLimit =
          (data['missed_heartbeat_limit'] as num?)?.toInt() ??
          _missedHeartbeatLimit;
      _heartbeatIntervalMin =
          (data['heartbeat_interval_min'] as num?)?.toInt() ??
          _heartbeatIntervalMin;
      _heartbeatIntervalMax =
          (data['heartbeat_interval_max'] as num?)?.toInt() ??
          _heartbeatIntervalMax;
      _missedHeartbeatLimitMin =
          (data['missed_heartbeat_limit_min'] as num?)?.toInt() ??
          _missedHeartbeatLimitMin;
      _missedHeartbeatLimitMax =
          (data['missed_heartbeat_limit_max'] as num?)?.toInt() ??
          _missedHeartbeatLimitMax;
      _minLivenessWindowSeconds =
          (data['min_window_seconds'] as num?)?.toInt() ??
          _minLivenessWindowSeconds;
      _livenessWindowSeconds =
          (data['window_seconds'] as num?)?.toInt() ??
          _heartbeatIntervalSeconds * _missedHeartbeatLimit;
      _liveIntervalSeconds =
          (data['live_interval_seconds'] as num?)?.toInt() ??
          _heartbeatIntervalSeconds;
      _liveMissLimit =
          (data['live_miss_limit'] as num?)?.toInt() ?? _missedHeartbeatLimit;
      _livenessNotice = (data['notice'] as String?) ?? fallbackNotice;
      _heartbeatIntervalController.text = '$_heartbeatIntervalSeconds';
      _missedHeartbeatLimitController.text = '$_missedHeartbeatLimit';
    });
  }

  /// 提交心跳判活参数。
  ///
  /// 两个字段**一起**下发：判活窗口是 I×N 的乘积，分两次写会经过非法中间态
  /// （例如从 10s/3 改成 3s/6 时，先把间隔改成 3 的那一瞬间窗口只剩 9s）。
  ///
  /// 前端按后端同一口径先算一遍：窗口必须严格大于 [_minLivenessWindowSeconds]
  /// （前端固定 10s 心跳），不足时抬高间隔 I——夹取而不是拒绝，并把可读原因同时
  /// 显示在卡片上（持久）与 SnackBar 里（当下），用户要能知道"我填的 1s 为什么
  /// 生效成 4s"。后端仍会独立夹取（它是权威），两侧口径一致。
  Future<void> _applyHeartbeatSetting({
    int? intervalSeconds,
    int? limit,
  }) async {
    int nextInterval = (intervalSeconds ?? _heartbeatIntervalSeconds).clamp(
      _heartbeatIntervalMin,
      _heartbeatIntervalMax,
    );
    final int nextLimit = (limit ?? _missedHeartbeatLimit).clamp(
      _missedHeartbeatLimitMin,
      _missedHeartbeatLimitMax,
    );
    String? localNotice;
    if (nextInterval * nextLimit <= _minLivenessWindowSeconds) {
      final int repaired = _minLivenessWindowSeconds ~/ nextLimit + 1;
      localNotice =
          '判活窗口 ${nextInterval}s×$nextLimit='
          '${nextInterval * nextLimit}s 不大于前端固定 '
          '${_minLivenessWindowSeconds}s 的心跳间隔，空闲连接会被误判失活并反复'
          '重连；已把心跳间隔夹到 ${repaired}s（判活窗口 ${repaired * nextLimit}s）';
      nextInterval = repaired;
    }
    try {
      final Map<String, dynamic> data =
          await ApiService.setHeartbeatLivenessSettings(
            heartbeatIntervalSeconds: nextInterval,
            missedHeartbeatLimit: nextLimit,
          );
      if (!mounted) return;
      _applyHeartbeatResponse(data, fallbackNotice: localNotice);
      final String? notice = (data['notice'] as String?) ?? localNotice;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(notice ?? '心跳判活参数已保存并生效'),
          duration: Duration(seconds: notice == null ? 2 : 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _heartbeatIntervalController.text = '$_heartbeatIntervalSeconds';
        _missedHeartbeatLimitController.text = '$_missedHeartbeatLimit';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('心跳判活参数保存失败：$e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// 加载自定义模型列表
  Future<void> _loadModelList() async {
    if (mounted) {
      setState(() {
        _modelsLoading = true;
        _modelsError = null;
      });
    }
    try {
      final List<Map<String, dynamic>> models = await ApiService.getModels();
      if (!mounted) return;
      setState(() {
        _models = models;
        _modelsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _modelsLoading = false;
        _modelsError = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSectionTitle('流式帧率'),
          const SizedBox(height: 8),
          _buildTokenRateCard(),
          const SizedBox(height: 12),
          _buildFrameRateCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('心跳判活'),
          const SizedBox(height: 8),
          _buildHeartbeatCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('自定义模型'),
          const SizedBox(height: 8),
          _buildCustomModelCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('消息切入模式'),
          const SizedBox(height: 8),
          _buildMessageCutinCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('主题管理'),
          const SizedBox(height: 8),
          _buildThemeCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('插件开发'),
          const SizedBox(height: 8),
          _buildPluginDevCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('版本信息'),
          const SizedBox(height: 8),
          _buildVersionCard(),
        ],
      ),
    );
  }

  /// 插件开发卡片（M9 §4.2 的开发面）。
  ///
  /// 为什么要一个"入口"而不是把文档抄进设置页：插件协议面（五个 RPC、四类站、
  /// `ui/manifest`、`plugins.yaml` 全字段）已经写在 `plugins/README.md` 里，抄一份
  /// 就是第二份真相源，必然与代码漂移。这里只负责**把人送到那份文档**，并把
  /// 文档的真实路径摆在界面上（路径找不到时给可读原因，不静默）。
  Widget _buildPluginDevCard() {
    final cs = Theme.of(context).colorScheme;
    final String? path = PluginDocs.resolvePath();
    const String dirHintFallback =
        '未找到 ${PluginDocs.readmeName}（发行版看应用目录下的 '
        '${PluginDocs.bundledDirName}/，源码仓库看 ${PluginDocs.repoDirName}/）';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '开发一个插件',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              '插件是独立进程，走 stdio JSON-RPC 与核心通信：可申报工具（收集站）、'
              '订阅事件与中转站（每次工具调用前后各一次）、主动下命令（执行站）、'
              '自建站点、声明前端面板。参考实现与协议细节都在 plugins/README.md。',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.icon(
                  key: const Key('plugin-docs-open'),
                  onPressed: () => _openPluginDocs(),
                  icon: const Icon(Icons.menu_book_outlined, size: 16),
                  label: const Text('打开插件开发说明'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const Key('plugin-docs-reveal'),
                  onPressed: path == null ? null : () => _revealPluginDir(path),
                  icon: const Icon(Icons.folder_open_outlined, size: 16),
                  label: const Text('打开所在目录'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              path ?? dirHintFallback,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              '插件配置：${_pluginConfigPathHint()}'
              '（可直接编辑，保存后立即热应用；热应用失败时重启核心生效）',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// 插件清单路径提示：从插件快照拿（拿了才知道真实数据根在哪，不臆测）。
  ///
  /// 快照还没到手时给出"打开插件面板可见"的指引，而不是留空或编一个路径。
  String _pluginConfigPathHint() =>
      _pluginConfigPath ?? '见「插件」面板（面板里显示真实路径）';

  /// 打开插件开发说明（失败给可读原因）。
  Future<void> _openPluginDocs() async {
    final String? error = await PluginDocs.openReadme();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? '已用系统默认程序打开插件开发说明'),
        duration: Duration(seconds: error == null ? 2 : 6),
      ),
    );
  }

  /// 在资源管理器里定位插件文档所在目录。
  Future<void> _revealPluginDir(String path) async {
    final String? error = await PluginDocs.openPath(File(path).parent.path);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), duration: const Duration(seconds: 4)),
      );
    }
  }

  /// 版本信息卡片。
  ///
  /// 三个常被问到的"我到底跑的是哪一版"在这里一次答完：应用版本、核心版本、
  /// 核心进程（pid / 端口 / 是否附着）。另外把启动期算好的**产物陈旧告警**摆在
  /// 这里——核心是独立进程，产物可能比界面旧，此时新功能会"看起来没生效"，
  /// 这是真机上最难自证的一类问题。
  Widget _buildVersionCard() {
    final cs = Theme.of(context).colorScheme;
    final VersionInfo info =
        widget.versionInfo ?? VersionInfo.fromLauncher();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '版本',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('version-copy'),
                  onPressed: () => _copyVersionInfo(info),
                  icon: const Icon(Icons.copy_all_outlined, size: 16),
                  label: const Text('复制版本信息'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final InfoRow row in info.rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 76,
                      child: Text(
                        row.label,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        row.value,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            if (info.buildWarning != null) ...[
              const SizedBox(height: 6),
              Text(
                info.buildWarning!,
                key: const Key('version-build-warning'),
                style: const TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 复制版本信息（整块文本，便于贴到 issue / 对话里）。
  Future<void> _copyVersionInfo(VersionInfo info) async {
    await Clipboard.setData(ClipboardData(text: info.toReportText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('版本信息已复制'), duration: Duration(seconds: 2)),
    );
  }

  /// token 获取帧率卡片
  ///
  /// 控制**从 LLM 流逐 token 取回复**的节奏：每消费一个文本/思考增量按该帧率
  /// 间隔让出一帧。常开、无开关——取代旧的「主动延迟」（那是一次性限 API 调用
  /// 次数，这里是连续可调的取词节奏）。范围 20~1000 帧/秒（1000 近似不限速）。
  Widget _buildTokenRateCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'token 获取帧率（帧/秒）',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              '从 LLM 流逐 token 取回复的节奏，常开生效；越慢越能看清生成过程',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _tokenRateController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '帧率',
                      helperText: '$_tokenRateMin~$_tokenRateMax',
                      isDense: true,
                    ),
                    onSubmitted: (String value) {
                      final int? parsed = int.tryParse(value.trim());
                      if (parsed != null) _applyTokenRate(parsed);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '减少 20',
                  onPressed: _tokenRate <= _tokenRateMin
                      ? null
                      : () => _applyTokenRate(_tokenRate - 20),
                  icon: const Icon(Icons.remove_circle_outline),
                  color: cs.primary,
                ),
                IconButton(
                  tooltip: '增加 20',
                  onPressed: _tokenRate >= _tokenRateMax
                      ? null
                      : () => _applyTokenRate(_tokenRate + 20),
                  icon: const Icon(Icons.add_circle_outline),
                  color: cs.primary,
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: () {
                    final int? parsed = int.tryParse(
                      _tokenRateController.text.trim(),
                    );
                    if (parsed != null) _applyTokenRate(parsed);
                  },
                  child: const Text('应用'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 后端值返回前不渲染滑块：初值 1000 会让滑块先出现在最右端，加载
            // 完成后再左移，视觉上是明显的"跳一下"。用等高占位消除这段位移。
            if (_tokenRateLoaded)
              Slider(
                value: _tokenRate.toDouble().clamp(
                  _tokenRateMin.toDouble(),
                  _tokenRateMax.toDouble(),
                ),
                min: _tokenRateMin.toDouble(),
                max: _tokenRateMax.toDouble(),
                divisions: 49,
                label: '$_tokenRate fps',
                onChanged: (double value) {
                  setState(() => _tokenRate = value.round());
                },
                onChangeEnd: (double value) => _applyTokenRate(value.round()),
              )
            else
              const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  /// 推送刷新帧率卡片
  ///
  /// 控制**流式增量的合并下发频率**：把同一轮回复内的 token 攒帧后按该帧率合并
  /// 成一条 `msg_chunk` 推送，避免以 token 速度刷屏。常开、无开关。
  ///
  /// 与上面的「token 获取帧率」互不干扰：取词慢则下发帧数自然少；取词满速时由
  /// 这里决定实际刷新频率。范围 20~1000 帧/秒，可直接键入，提交时按范围夹取。
  Widget _buildFrameRateCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '推送刷新帧率（帧/秒）',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              '把同一轮回复内的流式增量攒帧后按该帧率合并下发，常开生效',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _frameRateController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '帧率',
                      helperText: '$_frameRateMin~$_frameRateMax',
                      isDense: true,
                    ),
                    onSubmitted: (String value) {
                      final int? parsed = int.tryParse(value.trim());
                      if (parsed != null) _applyFrameRate(parsed);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '减少 20',
                  onPressed: _frameRate <= _frameRateMin
                      ? null
                      : () => _applyFrameRate(_frameRate - 20),
                  icon: const Icon(Icons.remove_circle_outline),
                  color: cs.primary,
                ),
                IconButton(
                  tooltip: '增加 20',
                  onPressed: _frameRate >= _frameRateMax
                      ? null
                      : () => _applyFrameRate(_frameRate + 20),
                  icon: const Icon(Icons.add_circle_outline),
                  color: cs.primary,
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: () {
                    final int? parsed = int.tryParse(
                      _frameRateController.text.trim(),
                    );
                    if (parsed != null) _applyFrameRate(parsed);
                  },
                  child: const Text('应用'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 同 token 帧率：加载完成前用等高占位，避免滑块先跳到默认值再回位。
            if (_frameRateLoaded)
              Slider(
                value: _frameRate.toDouble().clamp(
                  _frameRateMin.toDouble(),
                  _frameRateMax.toDouble(),
                ),
                min: _frameRateMin.toDouble(),
                max: _frameRateMax.toDouble(),
                divisions: 49,
                label: '$_frameRate fps',
                onChanged: (double value) {
                  setState(() => _frameRate = value.round());
                },
                onChangeEnd: (double value) => _applyFrameRate(value.round()),
              )
            else
              const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  /// 心跳判活参数卡片（心跳间隔 I 秒 / 连续丢失阈值 N 次）
  ///
  /// 核心判"链路失活"的唯一判据（M9 规约 1.1：静态时间超时全部取消，改心跳丢失），
  /// 所以这两个值直接决定"多久没有心跳就判死"。硬约束：判活窗口 I×N 必须**严格
  /// 大于**前端固定的 10s WS 心跳（lib/io/websocket_service.dart，本页不可调），
  /// 否则"在线但空闲"的连接会被判失活、关连接、反复重连；不足时前后端都会把 I 抬到
  /// 刚好够，并把可读原因显示在下面。
  Widget _buildHeartbeatCard() {
    final cs = Theme.of(context).colorScheme;
    // 核心侧的"在线生效值"可能落后于设置值：WS 判活节拍会立即热更新，但丢失阈值 N
    // 与插件宿主 / MCP 客户端的心跳参数要等下次启动核心（SSH 是下次建连）才用新值，
    // 这里如实说明生效时机，不含糊。
    final bool liveBehind =
        _liveIntervalSeconds != _heartbeatIntervalSeconds ||
        _liveMissLimit != _missedHeartbeatLimit;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '心跳判活参数',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              '核心判链路失活的唯一判据：连续 N 拍没收到心跳即判失活（不做静态时间'
              '超时）。判活窗口 = 间隔 × 阈值，必须大于前端固定 10s 的心跳，'
              '否则空闲连接会被误判失活并反复重连。',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 104,
                  child: TextField(
                    key: const Key('heartbeat-interval-input'),
                    controller: _heartbeatIntervalController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '间隔（秒）',
                      helperText:
                          '$_heartbeatIntervalMin~$_heartbeatIntervalMax',
                      isDense: true,
                    ),
                    onSubmitted: (String value) {
                      final int? parsed = int.tryParse(value.trim());
                      if (parsed != null) {
                        _applyHeartbeatSetting(intervalSeconds: parsed);
                      }
                    },
                  ),
                ),
                IconButton(
                  key: const Key('heartbeat-interval-decrease'),
                  tooltip: '间隔减少 1 秒',
                  onPressed: _heartbeatIntervalSeconds <= _heartbeatIntervalMin
                      ? null
                      : () => _applyHeartbeatSetting(
                          intervalSeconds: _heartbeatIntervalSeconds - 1,
                        ),
                  icon: const Icon(Icons.remove_circle_outline),
                  color: cs.primary,
                ),
                IconButton(
                  key: const Key('heartbeat-interval-increase'),
                  tooltip: '间隔增加 1 秒',
                  onPressed: _heartbeatIntervalSeconds >= _heartbeatIntervalMax
                      ? null
                      : () => _applyHeartbeatSetting(
                          intervalSeconds: _heartbeatIntervalSeconds + 1,
                        ),
                  icon: const Icon(Icons.add_circle_outline),
                  color: cs.primary,
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 104,
                  child: TextField(
                    key: const Key('heartbeat-limit-input'),
                    controller: _missedHeartbeatLimitController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '阈值（次）',
                      helperText:
                          '$_missedHeartbeatLimitMin~'
                          '$_missedHeartbeatLimitMax',
                      isDense: true,
                    ),
                    onSubmitted: (String value) {
                      final int? parsed = int.tryParse(value.trim());
                      if (parsed != null) {
                        _applyHeartbeatSetting(limit: parsed);
                      }
                    },
                  ),
                ),
                IconButton(
                  key: const Key('heartbeat-limit-decrease'),
                  tooltip: '阈值减少 1 次',
                  onPressed: _missedHeartbeatLimit <= _missedHeartbeatLimitMin
                      ? null
                      : () => _applyHeartbeatSetting(
                          limit: _missedHeartbeatLimit - 1,
                        ),
                  icon: const Icon(Icons.remove_circle_outline),
                  color: cs.primary,
                ),
                IconButton(
                  key: const Key('heartbeat-limit-increase'),
                  tooltip: '阈值增加 1 次',
                  onPressed: _missedHeartbeatLimit >= _missedHeartbeatLimitMax
                      ? null
                      : () => _applyHeartbeatSetting(
                          limit: _missedHeartbeatLimit + 1,
                        ),
                  icon: const Icon(Icons.add_circle_outline),
                  color: cs.primary,
                ),
                const Spacer(),
                OutlinedButton(
                  key: const Key('heartbeat-apply'),
                  onPressed: () {
                    // 两个输入框一起提交（I×N 是一个整体）；解析失败的框按"保持原值"
                    // 处理，不静默当成 0
                    final int? interval = int.tryParse(
                      _heartbeatIntervalController.text.trim(),
                    );
                    final int? limit = int.tryParse(
                      _missedHeartbeatLimitController.text.trim(),
                    );
                    if (interval == null && limit == null) return;
                    _applyHeartbeatSetting(
                      intervalSeconds: interval,
                      limit: limit,
                    );
                  },
                  child: const Text('应用'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '判活窗口 ${_livenessWindowSeconds}s（间隔 '
              '${_heartbeatIntervalSeconds}s × 阈值 $_missedHeartbeatLimit 次；'
              '必须 > ${_minLivenessWindowSeconds}s）',
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            if (liveBehind)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '核心侧在线生效：间隔 ${_liveIntervalSeconds}s × 阈值 '
                  '$_liveMissLimit 次 —— 丢失阈值与插件宿主 / MCP 客户端的'
                  '心跳参数在下次启动核心后完全一致（WS 判活节拍已立即生效），'
                  'SSH 在下次建连时生效',
                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ),
            if (_livenessNotice != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '已按安全下限夹取：$_livenessNotice',
                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 自定义模型卡片（列出模型池 + 新增/编辑/删除入口）
  Widget _buildCustomModelCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '模型池',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _modelsLoading ? null : _loadModelList,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
                FilledButton.icon(
                  onPressed: () => _openModelEditor(null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新增'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '写入 ~/.tree/config/models/<model_id>.yaml，保存后立即对全部 Agent 生效。'
              'API Key 以明文保存在该文件（已在 .gitignore 中忽略）。',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 8),
            if (_modelsLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_modelsError != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '模型列表加载失败：$_modelsError',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _loadModelList,
                    child: const Text('重试'),
                  ),
                ],
              )
            else if (_models.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '模型池为空，请新增一个模型配置',
                  style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                ),
              )
            else
              ..._models.map((Map<String, dynamic> m) => _buildModelRow(m, cs)),
          ],
        ),
      ),
    );
  }

  /// 单个模型条目行
  Widget _buildModelRow(Map<String, dynamic> model, ColorScheme cs) {
    final String modelId = model['model_id'] as String? ?? '';
    final String name = model['name'] as String? ?? modelId;
    final bool hasKey = model['has_api_key'] as bool? ?? false;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(name, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        '$modelId'
        '${hasKey ? '' : ' · 未配置 API Key'}'
        '${(model['thinking'] as bool? ?? false) ? ' · thinking' : ''}'
        '${(model['if_vision'] as bool? ?? false) ? ' · vision' : ''}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined, size: 18),
            color: cs.primary,
            onPressed: () => _openModelEditor(model),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline, size: 18),
            color: Colors.redAccent,
            onPressed: () => _deleteModel(model),
          ),
        ],
      ),
    );
  }

  /// 打开模型编辑对话框（[existing] 为 null 表示新增）
  Future<void> _openModelEditor(Map<String, dynamic>? existing) async {
    final Map<String, dynamic>? payload =
        await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (BuildContext context) =>
              _ModelEditorDialog(existing: existing),
        );
    if (payload == null || !mounted) return;
    try {
      if (existing == null) {
        await ApiService.createModel(payload);
      } else {
        final String modelId = existing['model_id'] as String? ?? '';
        await ApiService.updateModel(modelId, payload);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(existing == null ? '模型已新增' : '模型已更新'),
          duration: const Duration(seconds: 2),
        ),
      );
      await _loadModelList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存失败：$e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// 删除模型（二次确认；若仍有 agent 绑定则提示）
  Future<void> _deleteModel(Map<String, dynamic> model) async {
    final String modelId = model['model_id'] as String? ?? '';
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除模型'),
        content: Text(
          '确定删除模型「${model['name'] ?? modelId}」？\n'
          '其配置文件将从服务器移除，操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final Map<String, dynamic> result = await ApiService.deleteModel(modelId);
      final List<dynamic> bound =
          result['bound_agents'] as List<dynamic>? ?? <dynamic>[];
      if (!mounted) return;
      final String suffix = bound.isEmpty
          ? ''
          : '；注意：仍有 ${bound.length} 个 Agent 绑定该模型，需重新指定模型';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已删除$suffix'),
          duration: const Duration(seconds: 3),
        ),
      );
      await _loadModelList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('删除失败：$e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// 消息切入模式卡片
  ///
  /// 关闭（默认，串行排队）：新消息入队，仅在当前消息的 tool_call 间隙
  /// 逐条切入，当前轮结束后再逐条处理剩余消息。
  /// 开启（直接切入）：间隙把队列中当前会话的消息一次性全部切入；且本轮
  /// 给出最终文本后若仍有新消息则继续本轮，使几乎同时到达的消息一起处理。
  Widget _buildMessageCutinCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '直接切入新消息（不排队）',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _directCutin
                        ? '已开启：新消息一次性全部切入当前上下文，几乎同时到达的消息（如多名成员的回传总结）一起处理'
                        : '已关闭（串行排队）：新消息逐条切入，当前轮结束后再逐条处理剩余消息',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: _directCutin,
              onChanged: _toggleMessageCutin,
              activeThumbColor: cs.primary,
            ),
          ],
        ),
      ),
    );
  }

  /// 分区标题
  Widget _buildSectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: Color(0xFF94A3B8),
      ),
    );
  }

  /// 主题管理卡片
  ///
  /// Flutter 3.32+ 起 Radio 的 groupValue/onChanged 迁移到 [RadioGroup] 祖先：
  /// 组状态与变更回调由 RadioGroup 统一持有，子项 RadioListTile 只声明自身 value。
  Widget _buildThemeCard() {
    final ThemeService themeService = ThemeService.instance;
    return Card(
      margin: EdgeInsets.zero,
      child: AnimatedBuilder(
        animation: themeService,
        builder: (BuildContext context, _) {
          return RadioGroup<ThemeMode>(
            groupValue: themeService.mode,
            onChanged: (ThemeMode? value) {
              if (value != null) {
                themeService.setMode(value);
              }
            },
            child: Column(
              children: [
                _buildThemeOption(
                  ThemeMode.light,
                  Icons.light_mode_outlined,
                  '浅色',
                  '明亮模式，适合白天使用',
                ),
                _buildThemeOption(
                  ThemeMode.dark,
                  Icons.dark_mode_outlined,
                  '深色',
                  '深色模式，适合夜间或省电',
                ),
                _buildThemeOption(
                  ThemeMode.system,
                  Icons.brightness_auto_outlined,
                  '跟随系统',
                  '根据操作系统自动切换',
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 单个主题选项（RadioListTile 风格；组状态由 [_buildThemeCard] 的 RadioGroup 持有）
  Widget _buildThemeOption(
    ThemeMode mode,
    IconData icon,
    String title,
    String subtitle,
  ) {
    final cs = Theme.of(context).colorScheme;
    return RadioListTile<ThemeMode>(
      value: mode,
      activeColor: cs.primary,
      secondary: Icon(icon, color: cs.primary),
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }
}

/// 自定义模型编辑对话框（新增 / 编辑）
///
/// 提交时返回一份 `Map<String, dynamic>` 请求体（交给 `ApiService.createModel`
/// 或 `updateModel`）。编辑模式下 **不预填 API Key**（后端从不回显密钥）：
/// 留空即"不修改"，`has_api_key` 只用于提示当前是否已配置。
class _ModelEditorDialog extends StatefulWidget {
  /// 待编辑模型（null = 新增）
  final Map<String, dynamic>? existing;

  const _ModelEditorDialog({this.existing});

  @override
  State<_ModelEditorDialog> createState() => _ModelEditorDialogState();
}

class _ModelEditorDialogState extends State<_ModelEditorDialog> {
  final TextEditingController _modelId = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _maxSeqlen = TextEditingController();
  final TextEditingController _maxOutput = TextEditingController();

  /// 思考强度可选档位（逗号分隔）。留空 = 用后端默认档位
  /// （low/high/max，见 `config.models.REASONING_EFFORT_CANONICAL`）。
  final TextEditingController _effortOptions = TextEditingController();

  bool _thinking = false;
  bool _ifVision = false;
  String _reasoningEffort = '';

  /// 思考强度档位兜底（与后端 REASONING_EFFORT_CANONICAL 一致）。
  ///
  /// 只列**有实际区分度**的档位：端点接受的枚举全集里
  /// minimal/medium/xhigh/ultra 与服务端档位一一等价，列出来就是假选项。
  static const List<String> _reasoningEfforts = <String>['low', 'high', 'max'];

  bool get _isEdit => widget.existing != null;

  /// 解析逗号分隔的档位输入（兼容中文逗号与空白）。
  static List<String> _parseEffortOptions(String raw) {
    return raw
        .replaceAll('，', ',')
        .split(',')
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();
  }

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? e = widget.existing;
    if (e == null) return;
    _modelId.text = e['model_id'] as String? ?? '';
    _name.text = e['name'] as String? ?? '';
    // base_url 后端已脱敏（仅协议+主机），编辑时留空表示"按原值不变"
    _thinking = e['thinking'] as bool? ?? false;
    _ifVision = e['if_vision'] as bool? ?? false;
    _reasoningEffort = e['reasoning_effort'] as String? ?? '';
    // 后端已按"模型声明或全局回退"解析好档位列表，直接回填（不预设当前选中值：
    // 列表仅表示"哪些可被 agent 覆盖"，与模型自身默认档位是两件事）
    final List<dynamic>? opts = e['reasoning_effort_options'] as List<dynamic>?;
    if (opts != null && opts.isNotEmpty) {
      _effortOptions.text = opts.map((dynamic v) => v.toString()).join(', ');
    }
    final int? seq = (e['max_seqlen'] as num?)?.toInt();
    if (seq != null) _maxSeqlen.text = '$seq';
    final int? out = (e['max_output_tokens'] as num?)?.toInt();
    if (out != null) _maxOutput.text = '$out';
  }

  @override
  void dispose() {
    _modelId.dispose();
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _maxSeqlen.dispose();
    _maxOutput.dispose();
    _effortOptions.dispose();
    super.dispose();
  }

  /// 思考强度下拉项：候选来自「可选档位」输入框，留空则用兜底档位。
  ///
  /// 当前 `_reasoningEffort` 若不在候选中（如文件里存的是档位声明之外的旧值，
  /// 或用户刚把档位列表改窄）**必须补进 items**：`DropdownButtonFormField` 的
  /// value 不在 items 中会直接断言失败，整个编辑弹窗打不开。
  List<DropdownMenuItem<String>> _buildEffortItems() {
    final List<String> options = _parseEffortOptions(_effortOptions.text);
    final List<String> candidates = options.isEmpty
        ? List<String>.of(_reasoningEfforts)
        : options;
    if (_reasoningEffort.isNotEmpty && !candidates.contains(_reasoningEffort)) {
      candidates.add(_reasoningEffort);
    }
    return <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(value: '', child: Text('不设置')),
      ...candidates.map(
        (String e) => DropdownMenuItem<String>(value: e, child: Text(e)),
      ),
    ];
  }

  void _submit() {
    final String modelId = _modelId.text.trim();
    if (modelId.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('model_id 不能为空')));
      return;
    }
    final Map<String, dynamic> payload = <String, dynamic>{
      'model_id': modelId,
      'name': _name.text.trim(),
      'thinking': _thinking,
      'if_vision': _ifVision,
    };
    // base_url / api_key：编辑时留空表示沿用原值（后端据此保留）
    final String baseUrl = _baseUrl.text.trim();
    if (baseUrl.isNotEmpty) payload['base_url'] = baseUrl;
    final String apiKey = _apiKey.text.trim();
    if (apiKey.isNotEmpty) payload['api_key'] = apiKey;
    if (_reasoningEffort.isNotEmpty) {
      payload['reasoning_effort'] = _reasoningEffort;
    }
    // 可选档位：留空 = 用后端默认（low/high/max），此时**不下发该键**让后端保留
    // 文件现值或走回退；非空则解析为列表下发（后端会归一化并校验默认档位落在其中）
    final List<String> effortOptions = _parseEffortOptions(_effortOptions.text);
    if (effortOptions.isNotEmpty) {
      payload['reasoning_effort_options'] = effortOptions;
    }
    final int? seq = int.tryParse(_maxSeqlen.text.trim());
    if (seq != null) payload['max_seqlen'] = seq;
    final int? out = int.tryParse(_maxOutput.text.trim());
    if (out != null) payload['max_output_tokens'] = out;

    // 新增必须提供 base_url / api_key（后端校验），前端先行拦截给出可读提示
    if (!_isEdit && (baseUrl.isEmpty || apiKey.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('新增模型必须填写 base_url 与 api_key')),
      );
      return;
    }
    Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool hasKey = widget.existing?['has_api_key'] as bool? ?? false;
    return AlertDialog(
      title: Text(_isEdit ? '编辑模型' : '新增模型'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _modelId,
                enabled: !_isEdit,
                decoration: const InputDecoration(
                  labelText: 'model_id',
                  helperText: '唯一标识，同时作为配置文件名（字母/数字/. _ -）',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '显示名称',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _baseUrl,
                decoration: InputDecoration(
                  labelText: 'base_url',
                  helperText: _isEdit
                      ? '留空 = 保持原地址不变'
                      : 'OpenAI 兼容端点，如 https://api.example.com/v1',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _apiKey,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'api_key',
                  helperText: _isEdit
                      ? (hasKey ? '已配置；留空 = 不修改' : '当前未配置')
                      : '必填',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _reasoningEffort,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '思考强度默认档位（reasoning_effort）',
                  helperText: '仅在该模型可选档位内；可被各 Agent 覆盖',
                  isDense: true,
                ),
                items: _buildEffortItems(),
                onChanged: (String? value) {
                  setState(() => _reasoningEffort = value ?? '');
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _effortOptions,
                // 重建下拉项：候选档位随本输入框内容变化（见 _buildEffortItems）
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '可选档位（reasoning_effort_options）',
                  hintText: '如 low, high, max',
                  helperText:
                      '留空 = 默认 low/high/max；'
                      '只列该端点真正区分的档位，别名会被折叠',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _maxSeqlen,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '总上下文上限 tokens',
                        hintText: '如 65536',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _maxOutput,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '最大输出 tokens',
                        hintText: '留空不限',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _thinking,
                onChanged: (bool v) => setState(() => _thinking = v),
                activeThumbColor: cs.primary,
                title: const Text(
                  '思考模型（thinking）',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: const Text(
                  '开启后历史思考会按 DeepSeek 规则作为 reasoning_content 回传端点'
                  '（带 tools 时官方要求回传，缺失会 400）；'
                  '复用思考链能让后续思考更短、成功率更高，代价是输入 token 增加。',
                  style: TextStyle(fontSize: 11),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _ifVision,
                onChanged: (bool v) => setState(() => _ifVision = v),
                activeThumbColor: cs.primary,
                title: const Text(
                  '支持图像输入（if_vision）',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: const Text(
                  '开启后：对话里的图片会先上传到该模型的 Files API，'
                  '再以 file_id 引用发送（需端点支持 file 内容块，如 DeepSeek）；'
                  '关闭时模型只会拿到图片在工作空间里的路径。',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(onPressed: _submit, child: Text(_isEdit ? '保存' : '创建')),
      ],
    );
  }
}
