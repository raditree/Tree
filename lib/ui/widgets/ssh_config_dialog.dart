import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// SSH 连接配置表单对话框。
///
/// 字段：主机 / 端口 / 用户名 / 认证方式（密码或私钥）/ 密码或私钥路径 /
/// 远端基础目录。确认后以 ``Map<String, dynamic>`` 返回：
/// ``{host, port, username, auth_type, password, private_key_path, remote_base_dir}``。
class SshConfigDialog extends StatefulWidget {
  const SshConfigDialog({super.key, this.initialConfig});

  /// 预填的已有配置（再次启用时避免重复输入）
  final Map<String, dynamic>? initialConfig;

  @override
  State<SshConfigDialog> createState() => _SshConfigDialogState();
}

class _SshConfigDialogState extends State<SshConfigDialog> {
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController(text: '22');
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _keyPathController = TextEditingController();
  final TextEditingController _remoteDirController =
      TextEditingController(text: '/');

  /// 认证方式：'password' | 'key'
  String _authType = 'password';

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? cfg = widget.initialConfig;
    if (cfg != null) {
      _hostController.text = (cfg['host'] as String?) ?? '';
      _portController.text = ((cfg['port'] as num?) ?? 22).toString();
      _usernameController.text = (cfg['username'] as String?) ?? '';
      _authType = (cfg['auth_type'] as String?) ?? 'password';
      _passwordController.text = (cfg['password'] as String?) ?? '';
      _keyPathController.text = (cfg['private_key_path'] as String?) ?? '';
      final String remoteDir = (cfg['remote_base_dir'] as String?) ?? '';
      _remoteDirController.text = remoteDir.isNotEmpty ? remoteDir : '/';
    }
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _keyPathController.dispose();
    _remoteDirController.dispose();
    super.dispose();
  }

  Future<void> _pickKeyPath() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 SSH 私钥文件',
      allowMultiple: false,
    );
    if (result != null && result.files.isNotEmpty) {
      final String? path = result.files.single.path;
      if (path != null && path.isNotEmpty && mounted) {
        setState(() => _keyPathController.text = path);
      }
    }
  }

  void _submit() {
    final String host = _hostController.text.trim();
    if (host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('主机地址不能为空')),
      );
      return;
    }
    Navigator.of(context).pop(<String, dynamic>{
      'host': host,
      'port': int.tryParse(_portController.text.trim()) ?? 22,
      'username': _usernameController.text.trim(),
      'auth_type': _authType,
      'password': _authType == 'password' ? _passwordController.text : '',
      'private_key_path':
          _authType == 'key' ? _keyPathController.text.trim() : '',
      'remote_base_dir': _remoteDirController.text.trim().isEmpty
          ? '/'
          : _remoteDirController.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('SSH 执行模式配置'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: '主机地址',
                  hintText: '例如 192.168.1.10 或 host.example.com',
                  prefixIcon: Icon(Icons.dns_outlined, size: 20),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _portController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '端口',
                        hintText: '22',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _usernameController,
                      decoration: const InputDecoration(
                        labelText: '用户名',
                        hintText: 'root',
                        prefixIcon: Icon(Icons.person_outline, size: 20),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _authType,
                decoration: const InputDecoration(
                  labelText: '认证方式',
                  prefixIcon: Icon(Icons.vpn_key_outlined, size: 20),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(
                    value: 'password',
                    child: Text('密码'),
                  ),
                  DropdownMenuItem<String>(
                    value: 'key',
                    child: Text('私钥'),
                  ),
                ],
                onChanged: (String? value) {
                  if (value != null) {
                    setState(() => _authType = value);
                  }
                },
              ),
              const SizedBox(height: 12),
              if (_authType == 'password')
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    prefixIcon: Icon(Icons.lock_outline, size: 20),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                )
              else
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _keyPathController,
                        decoration: const InputDecoration(
                          labelText: '私钥路径',
                          hintText: '例如 C:\\Users\\xxx\\.ssh\\id_rsa',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '选择私钥文件',
                      icon: const Icon(Icons.folder_open, size: 20),
                      onPressed: _pickKeyPath,
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _remoteDirController,
                decoration: const InputDecoration(
                  labelText: '远端基础目录',
                  hintText: '/',
                  helperText: '顶部 agent 文件落在此目录下；成员落在其 workspaces/ 子目录',
                  prefixIcon: Icon(Icons.folder_outlined, size: 20),
                  border: OutlineInputBorder(),
                  isDense: true,
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
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF2563EB),
            foregroundColor: Colors.white,
          ),
          child: const Text('测试并启用'),
        ),
      ],
    );
  }
}
