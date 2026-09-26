import 'dart:io';

import 'package:tree_local_exec/tree_local_exec.dart';

import '../store/atomic_file.dart';
import '../store/tree_paths.dart';
import '../store/write_queue.dart';
import '../store/yaml_codec.dart';
import 'core_settings.dart';

/// 设置与模型池的落盘实现（`~/.tree/config/`）。
///
/// - `settings.yaml`：全局设置。未知键原样保留（见 [CoreSettings.extra]），
///   文件头带说明注释，用户可直接手改。
/// - `models/<model_id>.yaml`：每个模型一个文件，**含明文 api_key**——这是
///   刻意的：桌面单用户形态下用户必须能直接看到并替换自己的密钥；文件位于
///   用户私有目录（Windows `%APPDATA%`、macOS/Linux 家目录），依赖操作系统的
///   用户目录权限而非进程内加密。方案中的"600 权限"在 Dart 标准库里没有
///   跨平台实现（`dart:io` 不提供 chmod），故本里程碑以"私有目录 + 明文"为准，
///   待 M7 打包时再评估是否需要 FFI chmod。
///
/// 写入同样是 write-behind（每文件串行），[flush] 等待落盘。
class FileSettingsSink implements CoreSettingsSink {
  FileSettingsSink(this.paths, {this.log});

  /// 路径布局。
  final TreePaths paths;

  /// 可读日志回调。
  final void Function(String message)? log;

  final WriteQueue _queue = WriteQueue();

  static const String _settingsHeader = 'Tree 全局设置：可直接手改（未知键会被原样保留）。';
  static const String _modelHeader = 'Tree 模型配置：api_key 为明文，请勿外传。';

  /// 装载既有配置到 [settings]，并把自己挂到 `settings.sink`。
  ///
  /// 装载阶段的 `putModel` 不触发落盘（见 [CoreSettings.putModel]），因此
  /// 启动过程不会把用户的文件重写一遍。
  void load(CoreSettings settings) {
    final File file = File(paths.settingsFile);
    if (file.existsSync()) {
      try {
        // 配置被手改坏时**不能抛**（那会让启动直接失败）：容错解码 + 记一条可见日志
        final DecodedText decoded = PlatformTextDecoder.decodeTolerant(
          file.readAsBytesSync(),
        );
        if (decoded.decoding == TextDecoding.utf8Malformed) {
          log?.call('settings.yaml 含非法 UTF-8 字节，已按 U+FFFD 顶替后解析：${file.path}');
        }
        settings.applyMap(YamlCodec.decode(decoded.text));
      } catch (error) {
        log?.call('settings.yaml 解析失败，本次使用默认设置：${file.path}：$error');
      }
    }
    final Directory dir = Directory(paths.modelsDir);
    if (dir.existsSync()) {
      for (final FileSystemEntity entity in dir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.yaml')) continue;
        try {
          final DecodedText decoded = PlatformTextDecoder.decodeTolerant(
            entity.readAsBytesSync(),
          );
          if (decoded.decoding == TextDecoding.utf8Malformed) {
            log?.call('模型配置含非法 UTF-8 字节，已按 U+FFFD 顶替后解析：${entity.path}');
          }
          final Map<String, dynamic> map = YamlCodec.decode(decoded.text);
          final CoreModelConfig model = CoreModelConfig.fromJson(map);
          if (model.modelId.isEmpty) {
            log?.call('模型配置缺少 model_id，已跳过：${entity.path}');
            continue;
          }
          settings.putModel(model);
        } catch (error) {
          log?.call('模型配置解析失败（已跳过）：${entity.path}：$error');
        }
      }
    }
    settings.sink = this;
  }

  @override
  void saveSettings(CoreSettings settings) {
    final String file = paths.settingsFile;
    final String content = YamlCodec.encode(
      settings.toMap(),
      header: _settingsHeader,
    );
    _queue.enqueue(file, () => AtomicFile.writeStringAtomic(file, content));
  }

  @override
  void saveModel(CoreModelConfig model) {
    final String file = paths.modelFile(model.modelId);
    final String content = YamlCodec.encode(
      model.toJson(),
      header: _modelHeader,
    );
    _queue.enqueue(file, () => AtomicFile.writeStringAtomic(file, content));
  }

  @override
  void deleteModel(String modelId) {
    final String file = paths.modelFile(modelId);
    _queue.enqueue(file, () async {
      final File target = File(file);
      if (await target.exists()) await target.delete();
    });
  }

  @override
  Future<void> flush() => _queue.flush();
}
