import '../settings/ssh_config.dart';
import '../store/records.dart';

/// Spec 索引提供者（M9 Q9）：返回**当前**索引文本（空串 = 不注入）；默认 null。
///
/// 为什么用可设置的 provider，而不是给 [systemPromptWithWorkspace] 加必填参数：
/// 系统提示词在**两处**被拼装——会话生成（ConversationService 的 _contextOf）与压缩
/// 估算（CompactionService.estimateContextTokens）——两处必须看到逐字一致的字符串，
/// 否则压缩阈值会失真。provider 让两处自动同口径，接线只要一行（核心启动处）：
/// `specIndexProvider = (agent) => specs.indexSnapshot(agent.id)`。
///
/// 每轮拼提示词都会重新调它（这里不做缓存），因此 `spec create` / `spec update`
/// 之后下一轮的索引就是新的。
String Function(CoreAgent agent)? specIndexProvider;

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

/// Spec 索引段（Q9）：索引文本来自 [specIndexProvider] 或调用方显式传入的 [explicit]。
///
/// 行格式（`- id [task_type] 标题（内置）（适用: when 摘要）`，id 自带反引号）与截断口径
/// 都在 `SpecService.renderIndex` 里——这里只加章节标题与用法说明，不重复实现格式。
String specIndexSection(String explicit) {
  final String index = explicit.trim();
  if (index.isEmpty) return '';
  return '\n\n## Spec 索引（任务型规范）\n\n$index\n\n'
      '开工前先按上表的 id 与适用条件判断该挂哪份规范：`spec select` 会**直接返回全文**'
      '并挂上 hook；没有合适的就不挂（不要硬凑），任务收尾可用 `spec create` 把经验沉淀成新规范。';
}

/// agent 自己的系统提示词 + 工作空间软约束 + Spec 索引（Q9）。
///
/// 空提示词只返回约束段；非空则保留原文，用空行分隔追加——原文一字不改，
/// 便于用户对照自己写在 agent 配置里的内容。索引为空（没接 Spec 服务）时
/// 输出与 M8a 完全一致。
String systemPromptWithWorkspace(CoreAgent agent, {String specIndex = ''}) {
  final String base = agent.systemPrompt.trimRight();
  final String suffix = workspacePromptSuffix(agent);
  final String index = specIndexSection(
    specIndex.trim().isEmpty
        ? (specIndexProvider?.call(agent) ?? '')
        : specIndex,
  );
  final String tail = '$suffix$index';
  return base.isEmpty ? tail : '$base\n\n$tail';
}
