/// 用户上传附件的提示词片段。
///
/// **为什么单独一个文件、且是纯函数**：这段文本在**两处**被使用——引擎装配请求
/// （`LlmAgentEngine._buildMessages`）与上下文压缩的 token 估算/摘要
/// （`CompactionService`）。两处必须逐字一致，否则会出现"估算说没超、端点说超了"
/// 这类阈值错位（项目里 `systemPromptWithWorkspace` 出于同一理由被两处共用）。
library;

/// 附件的工作空间相对路径列表（无有效路径的条目会被剔除）。
///
/// 只有 `path` 非空的附件才有意义：模型拿不到路径就等于拿不到文件。
List<String> attachmentPaths(List<Map<String, dynamic>>? attachments) {
  if (attachments == null || attachments.isEmpty) {
    return const <String>[];
  }
  final List<String> out = <String>[];
  for (final Map<String, dynamic> attachment in attachments) {
    final String path = (attachment['path'] ?? '').toString().trim();
    if (path.isEmpty) continue;
    out.add(path);
  }
  return out;
}

/// 附着在该条用户消息后面的附件说明段（空串 = 没有附件，调用方原样跳过）。
///
/// 形态：
/// ```
///
/// [用户上传的附件（已保存到工作空间，路径相对工作空间根）]
/// - .input/20261001/屏幕截图.png
/// - .input/20261001/报告.pdf
/// 需要时用 read 等文件工具按上述相对路径读取。
/// ```
///
/// 关键词"相对工作空间根"必须写出来：工具（read/write/grep…）的参数口径就是
/// 工作空间相对路径，与系统提示词里的《工作空间》一节一致，模型据此能直接调用。
String attachmentsPromptSuffix(List<Map<String, dynamic>>? attachments) {
  final List<String> paths = attachmentPaths(attachments);
  if (paths.isEmpty) return '';
  return '\n\n[用户上传的附件（已保存到工作空间，路径相对工作空间根）]\n'
      '${paths.map((String path) => '- $path').join('\n')}\n'
      '需要时用 read 等文件工具按上述相对路径读取。';
}
