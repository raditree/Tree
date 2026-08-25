import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../io/api_service.dart';
import '../../io/auth_service.dart';
import '../../io/websocket_service.dart';
import '../theme_service.dart';

/// 设置页面
///
/// 提供账号管理、密码修改、后端配置、数据收集与主题管理：
/// - 账号管理：展示当前用户信息（昵称、openid），支持退出登录
/// - 密码修改：修改当前账号密码
/// - 后端配置：自定义后端 IP+端口
/// - 数据收集：允许收集使用数据用于分析
/// - 主题管理：浅色 / 深色 / 跟随系统三种模式
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 当前用户信息（从本地 token 解析）
  Map<String, dynamic>? _user;

  /// 是否正在加载用户信息
  bool _loadingUser = true;

  /// 是否正在执行登出
  bool _loggingOut = false;

  /// 账号注销状态（null 表示尚未加载）
  Map<String, dynamic>? _accountStatus;

  /// 是否正在执行注销/取消操作
  bool _deleteBusy = false;

  // --- 密码修改 ---
  final TextEditingController _oldPwdController = TextEditingController();
  final TextEditingController _newPwdController = TextEditingController();
  final TextEditingController _confirmNewPwdController = TextEditingController();
  bool _changingPassword = false;

  // --- 等级升级 ---
  final TextEditingController _upgradeController = TextEditingController();
  bool _upgrading = false;

  // --- 后端配置 ---
  final TextEditingController _backendHostController = TextEditingController();
  final TextEditingController _backendPortController = TextEditingController();

  // --- 数据收集 ---
  bool _dataCollectionEnabled = false;

  // --- 主动延迟（限制单个 agent 的 API 调用频率，平均 6 次/分钟） ---
  bool _rateLimitEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadUser();
    _loadAccountStatus();
    _loadBackendConfig();
    _loadDataCollectionSetting();
    _loadRateLimitSetting();
  }

  @override
  void dispose() {
    _oldPwdController.dispose();
    _newPwdController.dispose();
    _confirmNewPwdController.dispose();
    _upgradeController.dispose();
    _backendHostController.dispose();
    _backendPortController.dispose();
    super.dispose();
  }

  /// 解析本地 token 中的用户信息
  Future<void> _loadUser() async {
    final AuthService authService = AuthService();
    final Map<String, dynamic>? user = await authService.getUserInfo();
    if (!mounted) return;
    setState(() {
      _user = user;
      _loadingUser = false;
    });
  }

  /// 查询账号注销状态
  Future<void> _loadAccountStatus() async {
    try {
      final Map<String, dynamic> status = await ApiService.getAccountStatus();
      if (!mounted) return;
      setState(() => _accountStatus = status);
    } catch (_) {
      // 查询失败时保持 null，不阻塞其他设置项
    }
  }

  /// 加载后端配置（IP+端口）
  Future<void> _loadBackendConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString('custom_backend_host') ?? '';
    final port = prefs.getString('custom_backend_port') ?? '';
    _backendHostController.text = host;
    _backendPortController.text = port;
  }

  /// 加载数据收集设置
  Future<void> _loadDataCollectionSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('data_collection_enabled') ?? false;
    if (mounted) {
      setState(() => _dataCollectionEnabled = enabled);
    }
  }

  /// 加载主动延迟设置
  Future<void> _loadRateLimitSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final local = prefs.getBool('rate_limit_enabled') ?? false;
    if (mounted) {
      setState(() => _rateLimitEnabled = local);
    }
    // 尝试从后端拉取权威状态（后端未启动/未登录时忽略，保留本地值）
    try {
      final bool remote = await ApiService.getRateLimit();
      if (mounted) setState(() => _rateLimitEnabled = remote);
    } catch (_) {
      // 后端不可达时保留本地持久化值
    }
  }

  /// 切换主动延迟开关
  Future<void> _toggleRateLimit(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('rate_limit_enabled', value);
    try {
      await ApiService.setRateLimit(value);
    } catch (_) {
      // 后端设置失败不阻塞本地持久化
    }
    if (mounted) {
      setState(() => _rateLimitEnabled = value);
    }
  }

  /// 保存后端配置并更新 ApiService.baseUrl / WebSocketService.baseUrl
  Future<void> _saveBackendConfig() async {
    final host = _backendHostController.text.trim();
    final port = _backendPortController.text.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_backend_host', host);
    await prefs.setString('custom_backend_port', port);
    final String backendHost =
        host.isNotEmpty && port.isNotEmpty ? host : ApiService.defaultBackendHost();
    final String backendPort = host.isNotEmpty && port.isNotEmpty ? port : '8000';
    // HTTP 与 WebSocket 同步指向同一后端，避免自定义地址后 WS 仍连 localhost
    ApiService.baseUrl = 'http://$backendHost:$backendPort';
    WebSocketService.baseUrl = 'ws://$backendHost:$backendPort';
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('后端地址已保存，当前请求已使用新地址')),
    );
  }

  /// 切换数据收集开关
  Future<void> _toggleDataCollection(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('data_collection_enabled', value);
    try {
      await ApiService.setDataCollection(value);
    } catch (_) {
      // 后端设置失败不阻塞本地持久化
    }
    if (mounted) {
      setState(() => _dataCollectionEnabled = value);
    }
  }

  /// 修改密码
  Future<void> _changePassword() async {
    final oldPwd = _oldPwdController.text;
    final newPwd = _newPwdController.text;
    final confirmPwd = _confirmNewPwdController.text;

    if (oldPwd.isEmpty || newPwd.isEmpty || confirmPwd.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写所有密码字段')),
      );
      return;
    }
    if (newPwd != confirmPwd) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('两次输入的新密码不一致')),
      );
      return;
    }
    if (newPwd.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('新密码长度不能少于 6 位')),
      );
      return;
    }

    setState(() => _changingPassword = true);
    try {
      await ApiService.changePassword(
        oldPassword: oldPwd,
        newPassword: newPwd,
      );
      if (!mounted) return;
      _oldPwdController.clear();
      _newPwdController.clear();
      _confirmNewPwdController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码修改成功')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('密码修改失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _changingPassword = false);
    }
  }

  /// 使用邀请码升级等级
  Future<void> _upgrade() async {
    final String code = _upgradeController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入邀请码')),
      );
      return;
    }
    setState(() => _upgrading = true);
    try {
      final Map<String, dynamic> data = await ApiService.upgradeLevel(code);
      if (!mounted) return;
      final String level = data['level'] as String? ?? '';
      final Map<String, dynamic>? user = data['user'] as Map<String, dynamic>?;
      setState(() {
        _upgrading = false;
        // 把后端返回的最新 user 合并进本地用户信息
        if (user != null) {
          _user = {...?_user, ...user};
        }
      });
      _upgradeController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已升级至 $level')),
      );
      // 刷新账号状态以获取最新等级
      _loadAccountStatus();
    } catch (e) {
      if (!mounted) return;
      setState(() => _upgrading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '升级失败：${e.toString().replaceFirst('Exception: ', '')}',
          ),
        ),
      );
    }
  }

  /// 请求注销账号（进入十日倒计时）
  Future<void> _requestDeleteAccount() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('注销账号'),
        content: const Text(
          '注销后将进入十日倒计时，期间功能照常，可随时取消。\n'
          '倒计时结束后数据将保留 31 天，之后彻底删除。是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确认注销'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _deleteBusy = true);
    try {
      final Map<String, dynamic> status =
          await ApiService.requestAccountDelete();
      if (!mounted) return;
      setState(() => _accountStatus = status);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已发起注销，进入十日倒计时')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('操作失败：$e')));
    } finally {
      if (mounted) setState(() => _deleteBusy = false);
    }
  }

  /// 取消注销账号
  Future<void> _cancelDeleteAccount() async {
    setState(() => _deleteBusy = true);
    try {
      final Map<String, dynamic> status =
          await ApiService.cancelAccountDelete();
      if (!mounted) return;
      setState(() => _accountStatus = status);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已取消注销，账号恢复正常')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('操作失败：$e')));
    } finally {
      if (mounted) setState(() => _deleteBusy = false);
    }
  }

  /// 退出登录：撤销后端 token、清除本地凭证并回到登录页
  Future<void> _logout() async {
    setState(() {
      _loggingOut = true;
    });
    // 后端撤销 token 失败不阻塞登出，本地清除后仍跳转登录页
    try {
      await ApiService.logout();
    } catch (_) {
      // 忽略后端登出错误，继续本地登出流程
    }
    final AuthService authService = AuthService();
    await authService.clearToken();
    ApiService.setToken(null);
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSectionTitle('账号管理'),
          const SizedBox(height: 8),
          _buildAccountCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('等级升级'),
          const SizedBox(height: 8),
          _buildUpgradeCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('修改密码'),
          const SizedBox(height: 8),
          _buildChangePasswordCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('后端配置'),
          const SizedBox(height: 8),
          _buildBackendConfigCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('数据收集'),
          const SizedBox(height: 8),
          _buildDataCollectionCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('主动延迟'),
          const SizedBox(height: 8),
          _buildRateLimitCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('注销账号'),
          const SizedBox(height: 8),
          _buildDeleteAccountCard(),
          const SizedBox(height: 24),
          _buildSectionTitle('主题管理'),
          const SizedBox(height: 8),
          _buildThemeCard(),
        ],
      ),
    );
  }

  /// 修改密码卡片
  Widget _buildChangePasswordCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _oldPwdController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '当前密码',
                prefixIcon: Icon(Icons.lock_outline, size: 20),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _newPwdController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '新密码',
                prefixIcon: Icon(Icons.lock, size: 20),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmNewPwdController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '确认新密码',
                prefixIcon: Icon(Icons.lock, size: 20),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _changingPassword ? null : _changePassword,
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                ),
                icon: _changingPassword
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onPrimary,
                        ),
                      )
                    : const Icon(Icons.lock_reset, size: 18),
                label: Text(_changingPassword ? '修改中...' : '修改密码'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 等级升级卡片
  Widget _buildUpgradeCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '等级升级',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              '输入邀请码升级等级，升级后保持到后端重启',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _upgradeController,
              decoration: const InputDecoration(
                labelText: '邀请码',
                prefixIcon: Icon(Icons.vpn_key_outlined, size: 20),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _upgrading ? null : _upgrade,
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                ),
                icon: _upgrading
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onPrimary,
                        ),
                      )
                    : const Icon(Icons.workspace_premium, size: 18),
                label: Text(_upgrading ? '升级中...' : '升级'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 后端配置卡片
  Widget _buildBackendConfigCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _backendHostController,
                    decoration: const InputDecoration(
                      labelText: 'IP 地址',
                      hintText: 'localhost',
                      prefixIcon: Icon(Icons.dns_outlined, size: 20),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _backendPortController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '端口',
                      hintText: '8000',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _saveBackendConfig,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存后端地址'),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '修改后需重启应用生效',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
          ],
        ),
      ),
    );
  }

  /// 数据收集卡片
  Widget _buildDataCollectionCard() {
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
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '允许收集使用数据',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _dataCollectionEnabled
                            ? '已开启，仅保存开启期间的使用数据快照'
                            : '关闭状态，不会收集任何使用数据',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _dataCollectionEnabled,
                  onChanged: _toggleDataCollection,
                  activeColor: cs.primary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 主动延迟卡片
  ///
  /// 开启后限制单个 agent 的 API 调用频率（平均 6 次/分钟），
  /// 适合交互式开发——放慢 agent 节奏，让用户跟得上每个步骤。
  Widget _buildRateLimitCard() {
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
                    '主动延迟（API 限速）',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _rateLimitEnabled
                        ? '已开启：限制单个 agent 的 API 调用频率（平均 6 次/分钟），适合交互式开发'
                        : '关闭：API 调用不限速',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ),
            Switch(
              value: _rateLimitEnabled,
              onChanged: _toggleRateLimit,
              activeColor: cs.primary,
            ),
          ],
        ),
      ),
    );
  }

  /// 注销账号卡片
  Widget _buildDeleteAccountCard() {
    final String? status = _accountStatus?['status'] as String?;
    if (status == null) {
      return const Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            '无法获取账号状态，请稍后重试',
            style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
          ),
        ),
      );
    }

    if (status == 'pending_delete') {
      final int daysLeft = (_accountStatus?['cancel_days_left'] as int?) ?? 0;
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '您已申请注销，剩余 $daysLeft 天倒计时。',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 4),
              const Text(
                '倒计时期间功能照常，倒计时结束后数据保留 31 天再彻底删除。',
                style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _deleteBusy ? null : _cancelDeleteAccount,
                  icon: _deleteBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.undo, size: 18),
                  label: Text(_deleteBusy ? '处理中...' : '取消注销'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (status == 'deleting') {
      final int daysLeft = (_accountStatus?['erase_days_left'] as int?) ?? 0;
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '账号已注销，数据将在 $daysLeft 天后彻底删除，无法恢复。',
            style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
          ),
        ),
      );
    }

    // active：正常状态，显示注销按钮
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '注销后账号数据将按「十日倒计时 → 保留 31 天 → 彻底删除」流程处理。',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _deleteBusy ? null : _requestDeleteAccount,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                ),
                icon: _deleteBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_forever, size: 18),
                label: Text(_deleteBusy ? '处理中...' : '注销账号'),
              ),
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

  /// 等级中文映射（未知名显示原字符串）
  String _levelLabel(String level) {
    const Map<String, String> levelNames = {
      'common': '普通',
      'pro': '专业',
      'ultra': '旗舰',
      'beta': '测试',
    };
    return levelNames[level] ?? level;
  }

  /// 账号管理卡片
  Widget _buildAccountCard() {
    final cs = Theme.of(context).colorScheme;
    if (_loadingUser) {
      return const Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final Map<String, dynamic> user = _user ?? {};
    final String nickname = user['nickname'] as String? ?? '未知用户';
    final String openid = user['openid'] as String? ?? '未登录';
    final String avatar = user['avatar'] as String? ?? '';
    // 当前等级：优先取本地 user，回退到账号状态中的 user，缺省 common
    final String level = (user['level'] as String?) ??
        ((_accountStatus?['user'] as Map<String, dynamic>?)?['level'] as String?) ??
        'common';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: cs.primary,
                  backgroundImage: avatar.isNotEmpty
                      ? NetworkImage(avatar)
                      : null,
                  child: avatar.isEmpty
                      ? Text(
                          nickname.isNotEmpty ? nickname.substring(0, 1) : '?',
                          style: TextStyle(
                            color: cs.onPrimary,
                            fontSize: 18,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nickname,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'openid: $openid',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF94A3B8),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '等级：${_levelLabel(level)} ($level)',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _loggingOut ? null : _logout,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                ),
                icon: _loggingOut
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.logout, size: 18),
                label: Text(_loggingOut ? '正在退出...' : '退出登录'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 主题管理卡片
  Widget _buildThemeCard() {
    final ThemeService themeService = ThemeService.instance;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          _buildThemeOption(
            themeService,
            ThemeMode.light,
            Icons.light_mode_outlined,
            '浅色',
            '明亮模式，适合白天使用',
          ),
          _buildThemeOption(
            themeService,
            ThemeMode.dark,
            Icons.dark_mode_outlined,
            '深色',
            '深色模式，适合夜间或省电',
          ),
          _buildThemeOption(
            themeService,
            ThemeMode.system,
            Icons.brightness_auto_outlined,
            '跟随系统',
            '根据操作系统自动切换',
          ),
        ],
      ),
    );
  }

  /// 单个主题选项（RadioListTile 风格）
  Widget _buildThemeOption(
    ThemeService themeService,
    ThemeMode mode,
    IconData icon,
    String title,
    String subtitle,
  ) {
    // 监听 ThemeService，切换时重建以更新选中态
    return AnimatedBuilder(
      animation: themeService,
      builder: (BuildContext context, _) {
        final cs = Theme.of(context).colorScheme;
        return RadioListTile<ThemeMode>(
          value: mode,
          groupValue: themeService.mode,
          onChanged: (ThemeMode? value) {
            if (value != null) {
              themeService.setMode(value);
            }
          },
          activeColor: cs.primary,
          secondary: Icon(icon, color: cs.primary),
          title: Text(title),
          subtitle: Text(subtitle),
        );
      },
    );
  }
}