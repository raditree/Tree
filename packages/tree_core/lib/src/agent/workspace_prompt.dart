import '../settings/ssh_config.dart';
import '../store/records.dart';

/// 工作空间说明（M8a）——作为**软约束**追加在 agent 自己的系统提示词之后。
///
/// 三个设计决定：
/// - **运行时生成、不落库**：根目录来自 `workspace_dir` / `ssh.root`，用户改配置
///   就会变；写进 agent 配置文件只会在配置改动后留下过期副本，因此只在本轮上下文里拼。
/// - **根不收窄**：真实用法里数据文件与项目文件常分处根下不同子目录（如 `~/data` 与
///   `~/proj`）。SSH agent 的根就取用户填的那一级（留空 = 远端登录用户的 `$HOME`），
///   由提示词说明"布局是混合的、按用户指示定位"，而不是逼用户把根改到某个项目子目录。
/// - **与压缩估算共用同一个函数**：[CompactionService.estimateContextTokens] 必须看到
///   与引擎完全一致的字符串，否则加了这段之后阈值会失真。
String workspacePromptSuffix(CoreAgent agent) {
  final SshConfig? ssh = agent.sshConfig;
  final String location;
  if (ssh != null) {
    final String root = ssh.root.trim();
    location = root.isEmpty
        ? '远端登录用户 `${ssh.username}` 的 `HOME`（核心连接后解析成绝对路径）'
        : '远端 `$root`（`~` 与相对路径按远端 `HOME` 展开）';
  } else {
    final String dir = agent.workspaceDir.trim();
    location = dir.isEmpty
        ? '本机默认工作目录 `workspaces/${agent.id}`（Tree 数据根目录之下）'
        : '本机目录 `$dir`';
  }
  return '''
## 工作空间（软约束）

- 你的工作空间根：$location。所有文件工具（read/write/edit/grep/terminal 等）的参数都是**相对这个根**的路径。
- 根之下通常是**混合布局**：数据文件与项目文件可能分处不同子目录（例如 `data/` 与 `proj/`），也可能混着缓存与临时文件。请按用户当前的指示在正确的子目录里操作，不要假定目标文件一定在根目录下。
- 不要自行收窄工作范围：用户没有明确限制时，你可以在根下任意位置读写；只有用户明确说"只动某个目录"时才限制。反过来，也不要把根当成只读展示区。
- 布局不确定时先用 list/grep 看一眼，不要凭猜测拼路径。''';
}

/// agent 自己的系统提示词 + 工作空间软约束。
///
/// 空提示词只返回这一段；非空则保留原文，用空行分隔追加——原文一字不改，
/// 便于用户对照自己写在 agent 配置里的内容。
String systemPromptWithWorkspace(CoreAgent agent) {
  final String base = agent.systemPrompt.trimRight();
  final String suffix = workspacePromptSuffix(agent);
  return base.isEmpty ? suffix : '$base\n\n$suffix';
}
