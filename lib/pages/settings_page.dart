import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/theme_service.dart';

/// 设置页面
///
/// 提供账号管理与主题管理：
/// - 账号管理：展示当前用户信息（昵称、openid），支持退出登录
/// - 主题管理：浅色 / 深色 / 跟随系统三种模式，切换后持久化并即时生效
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

  @override
  void initState() {
    super.initState();
    _loadUser();
    _loadAccountStatus();
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
            style: TextStyle(fontSize: 13, color: Colors.black54),
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
                style: TextStyle(fontSize: 12, color: Colors.black54),
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
            style: const TextStyle(fontSize: 13, color: Colors.black54),
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
              style: TextStyle(fontSize: 12, color: Colors.black54),
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
        color: Colors.black54,
      ),
    );
  }

  /// 账号管理卡片
  Widget _buildAccountCard() {
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
                  backgroundColor: const Color(0xFF2563EB),
                  backgroundImage: avatar.isNotEmpty
                      ? NetworkImage(avatar)
                      : null,
                  child: avatar.isEmpty
                      ? Text(
                          nickname.isNotEmpty ? nickname.substring(0, 1) : '?',
                          style: const TextStyle(
                            color: Colors.white,
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
                          color: Colors.black54,
                        ),
                        overflow: TextOverflow.ellipsis,
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
        return RadioListTile<ThemeMode>(
          value: mode,
          groupValue: themeService.mode,
          onChanged: (ThemeMode? value) {
            if (value != null) {
              themeService.setMode(value);
            }
          },
          activeColor: const Color(0xFF2563EB),
          secondary: Icon(icon, color: const Color(0xFF2563EB)),
          title: Text(title),
          subtitle: Text(subtitle),
        );
      },
    );
  }
}
