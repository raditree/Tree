import 'package:tree_local_exec/tree_local_exec.dart';

import '../plugin/plugin_guide.dart';
import 'builtin_specs.dart';

/// 选中内置规范时，把它引用的**随附文档**播种到工作空间。
///
/// 为什么需要：规范正文会引用只在**核心所在机器**上存在的文档（插件开发指南住在
/// 应用目录 `plugins/` 或仓库 `docs/`），而 agent 的工作空间类工具只认工作空间相对
/// 路径——工作空间不是仓库时，正文里那句"读指南"根本执行不了。于是选中规范时把原件
/// 复制一份进工作空间，让 `read` 看得见（路径见 [kPluginGuideWorkspacePath]）。
///
/// 与内置规范模板的差别：模板是**内嵌常量**（核心编译成单文件也能兜底），随附文档是
/// **磁盘原件**（随包分发，核心只负责搬运）——文档因此只有一份真相源，不会漂移。
/// 代价是原件缺失时不播种：如实回报 `action: missing` + 找过的目录，由规范正文的
/// 兜底流程接住（让 agent 向用户索取原件），不静默、不假装成功。
///
/// 接线：核心启动时挂到 `SpecService.seedAssetsFor`（见 `server/core_server.dart`）。
Future<List<Map<String, dynamic>>> seedBuiltinSpecAssets(
  WorkspaceIO io,
  List<String> specIds, {
  String? executableDir,
  String? overrideDir,
  String? currentDir,
  void Function(String)? log,
}) async {
  final List<Map<String, dynamic>> results = <Map<String, dynamic>>[];
  for (final String id in specIds) {
    if (id != kPluginCreatorSpecId) continue; // 其余内置规范没有随附文档
    final PluginGuideSeed seed = await seedPluginGuide(
      io,
      executableDir: executableDir,
      overrideDir: overrideDir,
      currentDir: currentDir,
      log: log,
    );
    results.add(<String, dynamic>{'spec_id': id, ...seed.toJson()});
  }
  return results;
}
