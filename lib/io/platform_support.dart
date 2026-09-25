import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 平台能力判断工具（多端适配统一入口）
///
/// Web 端（kIsWeb）下 dart:io 不可用，所有平台判断必须先行判断 kIsWeb。
/// 各端能力差异：
/// - 桌面端（Windows / Linux / macOS）：目录选择、保存对话框、文件拖拽、
///   本地执行模式（LocalExecutorService）可用
/// - 移动端（Android / iOS）：目录选择与保存对话框（file_picker 的
///   getDirectoryPath / saveFile 仅桌面支持）、本地执行模式不可用；
///   单/多文件选择（pickFiles）与上传可用

/// 是否 Android 平台（非 Web 且真实 Android 设备/模拟器）
bool get isAndroid => !kIsWeb && Platform.isAndroid;

/// 是否 iOS 平台（非 Web 且真实 iOS 设备）
bool get isIOS => !kIsWeb && Platform.isIOS;

/// 是否移动端（Android / iOS）
bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// 是否桌面端（Windows / Linux / macOS）
bool get isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// 是否 Linux 桌面
bool get isLinux => !kIsWeb && Platform.isLinux;

/// 读取环境变量（多端安全：Web 端无 `Platform.environment`，一律返回 null）。
///
/// 用于支持"用环境变量提供凭据/配置"的场景（如 SSH 密码
/// `TREE_SSH_PASSWORD`），避免把密钥落盘到 SharedPreferences。
///
/// :param name: 环境变量名
/// :return: 变量值；未设置、为空串或平台不支持时返回 null
String? envVar(String name) {
  if (kIsWeb) return null;
  try {
    final String? value = Platform.environment[name];
    if (value == null || value.isEmpty) return null;
    return value;
  } catch (_) {
    // 平台不支持/受限环境：静默降级为"未提供"
    return null;
  }
}
