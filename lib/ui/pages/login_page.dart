import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../io/api_service.dart';
import '../../io/auth_service.dart';
import '../../io/websocket_service.dart';

/// 登录页面
///
/// 使用账号密码登录/注册（checklist 1：替代微信登录，无开发者模拟登入按钮）。
/// - 支持「登录」与「注册」两个标签页切换
/// - 登录成功后保存 token 并跳转至 /main
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  final TextEditingController _nicknameController = TextEditingController();

  /// 后端 IP 与端口输入控制器（左下角切换后端地址用）
  final TextEditingController _backendHostController = TextEditingController();
  final TextEditingController _backendPortController = TextEditingController();

  /// 当前显示的后端地址（host:port）
  String _backendLabel = '';

  /// 当前是否处于注册模式
  bool _isRegister = false;

  /// 是否正在提交
  bool _submitting = false;

  /// 错误提示信息
  String _errorMsg = '';

  @override
  void initState() {
    super.initState();
    _loadBackendConfig();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nicknameController.dispose();
    _backendHostController.dispose();
    _backendPortController.dispose();
    super.dispose();
  }

  /// 加载本地保存的后端地址配置（未自定义时使用平台默认值）
  Future<void> _loadBackendConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final String host = prefs.getString('custom_backend_host') ?? '';
    final String port = prefs.getString('custom_backend_port') ?? '';
    final String backendHost =
        host.isNotEmpty && port.isNotEmpty ? host : ApiService.defaultBackendHost();
    final String backendPort =
        host.isNotEmpty && port.isNotEmpty ? port : '8000';
    _backendHostController.text = host;
    _backendPortController.text = port;
    if (mounted) {
      setState(() => _backendLabel = '$backendHost:$backendPort');
    }
  }

  /// 弹窗编辑后端 IP + 端口，保存后立即生效（允许先切换再登录）
  Future<void> _openBackendSwitchDialog() async {
    final String currentHost = ApiService.baseUrl
        .replaceFirst('http://', '')
        .replaceFirst('https://', '')
        .split(':')
        .first;
    _backendHostController.text =
        _backendHostController.text.isNotEmpty ? _backendHostController.text : currentHost;
    _backendPortController.text =
        _backendPortController.text.isNotEmpty ? _backendPortController.text : '8000';

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('切换后端地址'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _backendHostController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'IP / 域名',
                  hintText: 'localhost',
                  prefixIcon: Icon(Icons.dns_outlined, size: 20),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _backendPortController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '端口',
                  hintText: '8000',
                  prefixIcon: Icon(Icons.numbers_outlined, size: 20),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (saved != true || !mounted) return;

    final String hostText = _backendHostController.text.trim();
    final String portText = _backendPortController.text.trim();
    final String backendHost = hostText.isNotEmpty ? hostText : ApiService.defaultBackendHost();
    final String backendPort = hostText.isNotEmpty && portText.isNotEmpty ? portText : '8000';

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_backend_host', hostText);
    await prefs.setString('custom_backend_port', portText);

    // HTTP 与 WebSocket 同步指向同一后端，避免切换后 WS 仍连旧地址
    ApiService.baseUrl = 'http://$backendHost:$backendPort';
    WebSocketService.baseUrl = 'ws://$backendHost:$backendPort';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换后端地址：$backendHost:$backendPort')),
    );
    setState(() => _backendLabel = '$backendHost:$backendPort');
  }

  /// 切换登录/注册模式并清空错误提示
  void _switchMode(bool isRegister) {
    setState(() {
      _isRegister = isRegister;
      _errorMsg = '';
    });
  }

  /// 提交登录或注册
  Future<void> _submit() async {
    final String username = _usernameController.text.trim();
    final String password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      setState(() => _errorMsg = '请输入用户名和密码');
      return;
    }

    if (_isRegister) {
      final String confirmPassword = _confirmPasswordController.text;
      if (password != confirmPassword) {
        setState(() => _errorMsg = '两次输入的密码不一致');
        return;
      }
    }

    setState(() {
      _submitting = true;
      _errorMsg = '';
    });

    try {
      final Map<String, dynamic> data;
      if (_isRegister) {
        data = await ApiService.register(
          username: username,
          password: password,
          nickname: _nicknameController.text.trim(),
        );
      } else {
        data = await ApiService.login(username: username, password: password);
      }
      final String token = data['token'] as String? ?? '';
      if (token.isEmpty) {
        throw Exception('登录失败：未返回 token');
      }
      await _handleLoginSuccess(token);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMsg = '请求失败，请检查后端服务是否启动';
      });
    }
  }

  /// 处理登录成功：保存 token 并跳转主页
  Future<void> _handleLoginSuccess(String token) async {
    final AuthService authService = AuthService();
    await authService.saveToken(token);
    ApiService.setToken(token);
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/main');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 主题色（黑色背景 + 绿色边线框，见 main.dart 品牌色板）
    final cs = Theme.of(context).colorScheme;
    // 登录页保持品牌 HUD 暗色风：局部覆盖输入框样式为亮色，
    // 避免浅色主题（白绿）派生出的黑字在黑卡片上不可读。
    return Theme(
      data: Theme.of(context).copyWith(
        inputDecorationTheme: const InputDecorationTheme(
          labelStyle: TextStyle(color: Color(0xFFB8FFD9)),
          hintStyle: TextStyle(color: Color(0xFF94A3B8)),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF2B7A4B)),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF00FF8C), width: 1.5),
          ),
        ),
      ),
      child: Scaffold(
      // 登录页强制品牌黑底（HUD 风），不随浅色/深色主题变化，
      // 与黑卡片、亮绿标题、白字按钮保持一致
      backgroundColor: const Color(0xFF030705),
      body: Stack(
        children: [
          Center(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Card(
                  margin: const EdgeInsets.fromLTRB(24, 24, 24, 64),
                  elevation: 2,
                  // 卡片形状跟随主题 cardTheme（黑底 + 绿色描边）
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Agent 团队效率工具',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            // 与 main.dart 品牌亮绿保持一致（黑底上高对比）
                            color: Color(0xFF00FF8C),
                          ),
                        ),
                        const SizedBox(height: 24),
                        _buildModeSwitcher(),
                        const SizedBox(height: 20),
                        TextField(
                          controller: _usernameController,
                          style: const TextStyle(color: Color(0xFFE6F3EC)),
                          cursorColor: const Color(0xFF00FF8C),
                          decoration: const InputDecoration(
                            labelText: '用户名',
                            prefixIcon: Icon(Icons.person_outline, size: 20),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          style: const TextStyle(color: Color(0xFFE6F3EC)),
                          cursorColor: const Color(0xFF00FF8C),
                          decoration: const InputDecoration(
                            labelText: '密码',
                            prefixIcon: Icon(Icons.lock_outline, size: 20),
                          ),
                        ),
                        if (_isRegister) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _confirmPasswordController,
                            obscureText: true,
                            style: const TextStyle(color: Color(0xFFE6F3EC)),
                            cursorColor: const Color(0xFF00FF8C),
                            decoration: const InputDecoration(
                              labelText: '确认密码',
                              prefixIcon: Icon(Icons.lock_outline, size: 20),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _nicknameController,
                            style: const TextStyle(color: Color(0xFFE6F3EC)),
                            cursorColor: const Color(0xFF00FF8C),
                            decoration: const InputDecoration(
                              labelText: '昵称（可选）',
                              prefixIcon: Icon(Icons.badge_outlined, size: 20),
                            ),
                          ),
                        ],
                        if (_errorMsg.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            _errorMsg,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 13,
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _submitting ? null : _submit,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: cs.primary,
                              foregroundColor: cs.onPrimary,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: _submitting
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: cs.onPrimary,
                                    ),
                                  )
                                : Text(_isRegister ? '注册' : '登录'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 左下角：后端 IP 切换入口
          Positioned(
            left: 12,
            bottom: 12,
            child: TextButton.icon(
              onPressed: _openBackendSwitchDialog,
              icon: const Icon(Icons.dns_outlined, size: 18),
              label: Text(
                '后端 ${_backendLabel.isEmpty ? '...' : _backendLabel}',
                style: const TextStyle(fontSize: 13),
              ),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white70,
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// 登录/注册标签切换
  Widget _buildModeSwitcher() {
    return Container(
      decoration: BoxDecoration(
        // 品牌卡片底色（黑底绿边风格，与 main.dart brandCard 一致）
        color: const Color(0xFF0A1A10),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          _buildModeButton('登录', !_isRegister),
          _buildModeButton('注册', _isRegister),
        ],
      ),
    );
  }

  Widget _buildModeButton(String text, bool selected) {
    return Expanded(
      child: InkWell(
        onTap: () => _switchMode(text == '注册'),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            // 选中项：品牌容器深绿底；未选中：透明
            color: selected ? const Color(0xFF0E2B1A) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? const Color(0xFF2B7A4B) : Colors.transparent,
            ),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected
                  ? const Color(0xFF00FF8C)
                  : const Color(0xFF94A3B8),
            ),
          ),
        ),
      ),
    );
  }
}