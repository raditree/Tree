import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../io/platform_support.dart';
import '../../io/ssh_connection_manager.dart';

/// SSH 连接配置表单对话框。
///
/// 字段：主机 / 端口 / 用户名 / 认证方式（密码或私钥）/ 密码或私钥路径 /
/// 远端基础目录 / 是否在本机记住密码。确认后以 ``Map<String, dynamic>`` 返回：
/// ``{host, port, username, auth_type, password, private_key_path,
/// remote_base_dir, persist_password}``。
///
/// 凭据可用环境变量提供（表单留空时兜底，见 `SshConnectionManager`）：
/// ``TREE_SSH_PASSWORD`` / ``TREE_SSH_PRIVATE_KEY`` / ``TREE_SSH_HOST`` /
/// ``TREE_SSH_PORT`` / ``TREE_SSH_USER`` / ``TREE_SSH_REMOTE_DIR``。
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

  /// 是否把密码明文写入本机 SharedPreferences（默认否）
  bool _persistPassword = false;

  /// 是否存在环境变量提供的密码/私钥（用于提示"可留空"）
  bool _hasEnvPassword = false;
  bool _hasEnvKey = false;

  @override
  void initState() {
    super.initState();
    _hasEnvPassword = envVar(SshConnectionManager.envPassword) != null;
    _hasEnvKey = envVar(SshConnectionManager.envPrivateKey) != null;
    final Map<String, dynamic>? cfg = widget.initialConfig;
    if (cfg != null) {
      _hostController.text = (cfg['host'] as String?) ?? '';
      _portController.text = ((cfg['port'] as num?) ?? 22).toString();
      _usernameController.text = (cfg['username'] as String?) ?? '';
      _authType = (cfg['auth_type'] as String?) ?? 'password';
      // 密码不预填（默认不落盘；即便落盘过也不回显，避免明文在界面上暴露）
      _persistPassword = cfg['persist_password'] == true;
      _keyPathController.text = (cfg['private_key_path'] as String?) ?? '';
      final String remoteDir = (cfg['remote_base_dir'] as String?) ?? '';
      _remoteDirController.text = remoteDir.isNotEmpty ? remoteDir : '/';
    } else if (_hasEnvKey && !_hasEnvPassword) {
      // 仅提供了私钥环境变量：默认切到私钥认证，减少一次手工选择
      _authType = 'key';
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
    // 主机/用户名允许留空——建连时会用 TREE_SSH_HOST / TREE_SSH_USER 兜底
    final bool hostFromEnv =
        host.isEmpty && envVar(SshConnectionManager.envHost) != null;
    if (host.isEmpty && !hostFromEnv) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '主机地址不能为空：请填写，或设置环境变量 TREE_SSH_HOST',
          ),
        ),
      );
      return;
    }
    final String password =
        _authType == 'password' ? _passwordController.text : '';
    if (_authType == 'password' && password.isEmpty && !_hasEnvPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '未提供 SSH 密码：请填写，或设置环境变量 TREE_SSH_PASSWORD',
          ),
        ),
      );
      return;
    }
    Navigator.of(context).pop(<String, dynamic>{
      'host': host,
      'port': int.tryParse(_portController.text.trim()) ?? 22,
      'username': _usernameController.text.trim(),
      'auth_type': _authType,
      'password': password,
      'private_key_path':
          _authType == 'key' ? _keyPathController.text.trim() : '',
      'remote_base_dir': _remoteDirController.text.trim().isEmpty
          ? '/'
          : _remoteDirController.text.trim(),
      // 是否把密码明文写入本机存储（默认否；密码来自环境变量时无意义）
      'persist_password': _persistPassword,
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
                decoration: InputDecoration(
                  labelText: '主机地址',
                  hintText: '例如 192.168.1.10 或 host.example.com',
                  helperText: envVar(SshConnectionManager.envHost) != null
                      ? '留空将使用环境变量 ${SshConnectionManager.envHost}'
                      : '需从前端所在机器可达（IP 相对前端）',
                  prefixIcon: const Icon(Icons.dns_outlined, size: 20),
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
                  decoration: InputDecoration(
                    labelText: '密码',
                    helperText: _hasEnvPassword
                        ? '留空将使用环境变量 '
                            '${SshConnectionManager.envPassword}'
                        : null,
                    prefixIcon: const Icon(Icons.lock_outline, size: 20),
                    isDense: true,
                  ),
                )
              else
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _keyPathController,
                        decoration: InputDecoration(
                          labelText: '私钥路径',
                          hintText: _hasEnvKey
                              ? '留空将使用环境变量 '
                                  '${SshConnectionManager.envPrivateKey}'
                              : '例如 C:\\Users\\xxx\\.ssh\\id_rsa',
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
              if (_authType == 'password') ...[
                const SizedBox(height: 4),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _persistPassword,
                  onChanged: (bool? value) {
                    setState(() => _persistPassword = value ?? false);
                  },
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    '在本机记住密码（明文存储）',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: const Text(
                    '不勾选时密码只用于本次运行，不写入本机存储；'
                    '推荐改用环境变量 TREE_SSH_PASSWORD',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _remoteDirController,
                decoration: const InputDecoration(
                  labelText: '远端基础目录',
                  hintText: '/',
                  helperText: '成员与顶部 agent 共用此目录；各 agent 私人记忆在 agentspace/{id}/.self 下',
                  prefixIcon: Icon(Icons.folder_outlined, size: 20),
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
            backgroundColor: cs.primary,
            foregroundColor: cs.onPrimary,
          ),
          child: const Text('测试并启用'),
        ),
      ],
    );
  }
}

/// SSH 密码补录对话框（连接反复失败时弹出）。
///
/// 只接收密码：SSH 建连重试耗尽（认证失败 / 密码未落盘 / 连接断开 / 密钥
/// 丢失）后由 `SshExecutorService` 回调 UI 弹出，补录成功后按新凭据重连。
/// 勾选「在本机记住密码」时密码会明文写入本机存储（见
/// `SshExecutorService._sanitizedForPersistence`）。
///
/// 确认后以 ``{password, persist}`` 返回；取消返回 null。
class SshPasswordDialog extends StatefulWidget {
  const SshPasswordDialog({
    super.key,
    required this.host,
    required this.username,
    required this.reason,
  });

  /// 目标主机（用于提示"正在补录哪台机器"）
  final String host;

  /// 登录用户名
  final String username;

  /// 失败原因（建连异常信息，供用户判断是密码错还是别的问题）
  final String reason;

  @override
  State<SshPasswordDialog> createState() => _SshPasswordDialogState();
}

class _SshPasswordDialogState extends State<SshPasswordDialog> {
  final TextEditingController _passwordController = TextEditingController();

  /// 是否把密码明文写入本机 SharedPreferences（默认否）
  bool _persist = false;

  /// 密码可见性切换
  bool _obscure = true;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    final String password = _passwordController.text;
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入 SSH 密码')),
      );
      return;
    }
    Navigator.of(context).pop(<String, dynamic>{
      'password': password,
      'persist': _persist,
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String target = widget.username.isEmpty
        ? widget.host
        : '${widget.username}@${widget.host}';
    return AlertDialog(
      title: const Text('SSH 连接失败，请补录密码'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '目标主机：$target',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              '失败原因：${widget.reason}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: _obscure,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: '密码',
                prefixIcon: const Icon(Icons.lock_outline, size: 20),
                suffixIcon: IconButton(
                  tooltip: _obscure ? '显示密码' : '隐藏密码',
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                isDense: true,
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _persist,
              onChanged: (bool? value) {
                setState(() => _persist = value ?? false);
              },
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                '在本机记住密码（明文存储）',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                '不勾选时密码只用于本次运行；也可改用环境变量 '
                'TREE_SSH_PASSWORD',
                style: TextStyle(fontSize: 11),
              ),
            ),
            Text(
              '提示：若是私钥丢失或需要改主机/用户名，请关闭本窗口后改用'
              '「SSH 执行模式配置」表单。',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
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
            backgroundColor: cs.primary,
            foregroundColor: cs.onPrimary,
          ),
          child: const Text('保存并重连'),
        ),
      ],
    );
  }
}
