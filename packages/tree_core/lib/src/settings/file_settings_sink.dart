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
    // L-22 乙方案（阶段 1）：领域键归 `tree.agent`。插件已把 token 速率写进
    // `config/agent_settings.yaml` 时，核心把旧键从 settings.yaml 删掉（删前备份，
    // 只做一次）；插件从未启动过（新文件不存在）则原样保留，不丢用户设置。
    _dropMigratedDomainKeys();
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
    // 模型池归 tree.agent（写者已是插件）：核心**不再装载** `config/models/*.yaml`，
    // 也不再把它们写回任何地方。
    settings.sink = this;
  }

  /// 删除已迁移到 `agent_settings.yaml` 的领域键（目前只有 `token_acquisition_rate`）。
  ///
  /// 条件（顺序无关的关键）：**新文件存在且含有效值**才删旧键 —— 插件从未启动过的
  /// 老用户不会丢设置；插件一写成功，核心下一次启动/保存就收口。
  /// 删前把 settings.yaml 备份成 `.bak.<时间戳>`，且只保留最近一份（回滚用）。
  void _dropMigratedDomainKeys() {
    final File file = File(paths.settingsFile);
    if (!file.existsSync()) return;
    final int? migrated = _readMigratedTokenRate();
    if (migrated == null) return;
    Map<String, dynamic> map;
    try {
      final DecodedText decoded = PlatformTextDecoder.decodeTolerant(
        file.readAsBytesSync(),
      );
      map = YamlCodec.decode(decoded.text);
    } catch (error) {
      log?.call('settings.yaml 解析失败，跳过领域键迁移：${file.path}：$error');
      return;
    }
    if (!map.containsKey('token_acquisition_rate')) return;
    try {
      _backupSettingsFile(file);
      map = Map<String, dynamic>.from(map)..remove('token_acquisition_rate');
      // 同步写：load 是同步入口，异步写会与随后的 saveSettings 抢同一个 `.tmp` 名。
      AtomicFile.writeStringAtomicSync(
        file.path,
        YamlCodec.encode(map, header: _settingsHeader),
      );
      log?.call(
        'settings.yaml 的 token_acquisition_rate 已归 tree.agent'
        '（agent_settings.yaml=$migrated）；旧键已删除，备份保留最近一份',
      );
    } catch (error) {
      log?.call('删除 settings.yaml 的领域键失败（旧键原样保留）：$error');
    }
  }

  /// 读 `agent_settings.yaml` 里的有效 token 速率（文件不存在/坏值 ⇒ null）。
  int? _readMigratedTokenRate() {
    final File agentFile = File(paths.agentSettingsFile);
    if (!agentFile.existsSync()) return null;
    try {
      final DecodedText decoded = PlatformTextDecoder.decodeTolerant(
        agentFile.readAsBytesSync(),
      );
      final Object? raw = YamlCodec.decode(decoded.text)['token_acquisition_rate'];
      if (raw is num) return raw.toInt();
      if (raw is String) return int.tryParse(raw.trim());
    } catch (error) {
      log?.call('agent_settings.yaml 解析失败（本轮不删旧键）：${agentFile.path}：$error');
    }
    return null;
  }

  /// 备份 settings.yaml（`.bak.<yyyyMMddHHmmss>`），并清掉旧的同类备份。
  void _backupSettingsFile(File file) {
    final Directory dir = Directory(paths.configDir);
    if (dir.existsSync()) {
      for (final FileSystemEntity entity in dir.listSync()) {
        if (entity is! File) continue;
        final String name = entity.uri.pathSegments.last;
        if (!name.startsWith('settings.yaml.bak.')) continue;
        try {
          entity.deleteSync();
        } catch (_) {
          // 旧备份删不掉不影响本次迁移（下一份覆盖语义仍成立）。
        }
      }
    }
    final DateTime now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final String stamp =
        '${now.year}${two(now.month)}${two(now.day)}'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    file.copySync('${file.path}.bak.$stamp');
  }

  @override
  void saveSettings(CoreSettings settings) {
    final String file = paths.settingsFile;
    final Map<String, dynamic> map = settings.toMap();
    // 过渡期不丢设置：插件还没写过 agent_settings.yaml 时，磁盘上的旧键原样带回去
    // （核心不解释它的值）。插件一落新文件，下一次保存就把它彻底删掉。
    final int? legacy = File(paths.agentSettingsFile).existsSync()
        ? null
        : _legacyTokenRateOnDisk();
    if (legacy != null) map['token_acquisition_rate'] = legacy;
    final String content = YamlCodec.encode(map, header: _settingsHeader);
    _queue.enqueue(file, () => AtomicFile.writeStringAtomic(file, content));
  }

  /// 磁盘 settings.yaml 里遗留的 token 速率（模型未迁移时用于原样保留）。
  int? _legacyTokenRateOnDisk() {
    final File file = File(paths.settingsFile);
    if (!file.existsSync()) return null;
    try {
      final DecodedText decoded = PlatformTextDecoder.decodeTolerant(
        file.readAsBytesSync(),
      );
      final Object? raw = YamlCodec.decode(decoded.text)['token_acquisition_rate'];
      if (raw is num) return raw.toInt();
      if (raw is String) return int.tryParse(raw.trim());
    } catch (_) {
      return null;
    }
    return null;
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
