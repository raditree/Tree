import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 本地后端服务 - 管理本地 Python 后端进程的启动/停止
///
/// 适用于拥有较好设备的开发者，在客户端本地运行后端服务。
/// 开关状态和工作目录通过 SharedPreferences 持久化。
class LocalBackendService {
  LocalBackendService._();

  static Process? _process;
  static bool _isRunning = false;
  static String? _lastWorkingDir;

  /// 本地模式是否启用（持久化状态）
  static bool _enabled = false;
  static bool get enabled => _enabled;

  /// 后端进程是否正在运行
  static bool get isRunning => _isRunning;

  /// 当前工作目录
  static String? get workingDirectory => _lastWorkingDir;

  /// 从 SharedPreferences 恢复持久化状态
  static Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('local_backend_enabled') ?? false;
    _lastWorkingDir = prefs.getString('local_backend_working_dir');
  }

  /// 持久化开关状态
  static Future<void> _saveEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('local_backend_enabled', value);
  }

  /// 持久化工作目录
  static Future<void> _saveWorkingDir(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('local_backend_working_dir', path);
  }

  /// 设置开关状态
  static Future<bool> setEnabled(bool value) async {
    if (value == _enabled) return true;
    if (value) {
      // 开启本地模式：需要先有工作目录
      if (_lastWorkingDir == null || _lastWorkingDir!.isEmpty) {
        return false;
      }
      final started = await start(_lastWorkingDir!);
      if (!started) return false;
    } else {
      await stop();
    }
    _enabled = value;
    await _saveEnabled(value);
    return true;
  }

  /// 设置工作目录
  static Future<void> setWorkingDirectory(String path) async {
    _lastWorkingDir = path;
    await _saveWorkingDir(path);
  }

  /// 启动本地后端进程
  ///
  /// [workingDirectory] 为项目根目录（包含 server/main.py）。
  /// 启动后等待 2 秒让服务初始化，随后返回是否成功。
  static Future<bool> start(String workingDirectory) async {
    if (_isRunning) return true;
    _lastWorkingDir = workingDirectory;
    try {
      // 检查 Python 是否可用
      final pythonResult = await Process.run(
        'python',
        ['--version'],
        workingDirectory: workingDirectory,
      );
      if (pythonResult.exitCode != 0) {
        return false;
      }

      _process = await Process.start(
        'python',
        ['-m', 'server.main'],
        workingDirectory: workingDirectory,
        environment: {
          'PYTHONUNBUFFERED': '1',
          // 标记本地运行模式：即使本机装有 Docker，后端也直接使用本地终端
          // 在用户选择的工作目录下执行命令，而非进入 Docker 沙箱。
          'LOCAL_MODE': '1',
        },
      );

      // 非阻塞处理 stdout/stderr（日志输出）
      _process!.stdout.transform(SystemEncoding().decoder).listen(
        (data) {
          // stdout 日志（可忽略）
        },
      );
      _process!.stderr.transform(SystemEncoding().decoder).listen(
        (data) {
          // stderr 日志（可忽略，uvicorn 输出在 stderr）
        },
      );

      // 等待服务启动
      await Future.delayed(const Duration(seconds: 2));
      _isRunning = true;
      return true;
    } catch (e) {
      _isRunning = false;
      return false;
    }
  }

  /// 停止本地后端进程
  static Future<void> stop() async {
    if (_process != null) {
      _process!.kill(ProcessSignal.sigterm);
      await _process!.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _process!.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      _process = null;
    }
    _isRunning = false;
  }

  /// 应用退出时清理（同步，强制杀死进程）
  static void dispose() {
    if (_process != null) {
      _process!.kill(ProcessSignal.sigkill);
      _process = null;
    }
    _isRunning = false;
  }
}