import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_service.dart';

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

  /// 当前是否处于注册模式
  bool _isRegister = false;

  /// 是否正在提交
  bool _submitting = false;

  /// 错误提示信息
  String _errorMsg = '';

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nicknameController.dispose();
    super.dispose();
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
    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Card(
              margin: const EdgeInsets.all(24),
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
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
                        color: Color(0xFF2563EB),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildModeSwitcher(),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _usernameController,
                      decoration: const InputDecoration(
                        labelText: '用户名',
                        prefixIcon: Icon(Icons.person_outline, size: 20),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '密码',
                        prefixIcon: Icon(Icons.lock_outline, size: 20),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_isRegister) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _confirmPasswordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: '确认密码',
                          prefixIcon: Icon(Icons.lock_outline, size: 20),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _nicknameController,
                        decoration: const InputDecoration(
                          labelText: '昵称（可选）',
                          prefixIcon: Icon(Icons.badge_outlined, size: 20),
                          border: OutlineInputBorder(),
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
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: _submitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
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
    );
  }

  /// 登录/注册标签切换
  Widget _buildModeSwitcher() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
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
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 4,
                    ),
                  ]
                : null,
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected
                  ? const Color(0xFF2563EB)
                  : Colors.black.withOpacity(0.6),
            ),
          ),
        ),
      ),
    );
  }
}