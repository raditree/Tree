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
