/// **自动修复**：把"结果永远拿不到"的工具卡补上一段失败信息。
///
/// 用户 2026-10-03 口径：「在引擎的把关处，失败时自动修复」。
///
/// 为什么需要它：工具卡是**一条**消息（同一个 id 既在前端卡片上、也在历史翻译里）。
/// 取消 / 异常 / 核心重启会让某次工具调用的结果**永远拿不到**——那张卡以
/// `tool_result` 为空落库（`ConversationService` 收尾时把没等到结果的卡照旧落库），
/// 之后没有任何人再填它。以前历史翻译只给模型一句**临时占位**
/// （`(该工具调用未完成，没有结果)`），落库那份始终是空的：界面看着像"还在跑"，
/// 模型看到的与用户看到的不是同一件事。
///
/// 现在引擎在**组装工具批（把关处）**发现这种卡就写回一段失败信息：
/// 幂等（写一次之后卡片就有结果了）、不新增消息（`tool_call_id` 不能重复）。
library;

/// 自动修复的**写回落点**（引擎只认这个签名，不认识存储层——与
/// `LlmAgentEngine.toolTurnCompactor` 同一范式：可写字段 + 显式接线点）。
///
/// 返回值：`true` = 这次真的写回了（调用方据此记一行日志）；
/// `false` = 没必要写（卡片已有结果 / 找不到这张卡 / 不属于该会话）——
/// **幂等**，所以引擎每次组装请求都可以放心地问一次。
typedef ToolResultRepair =
    Future<bool> Function({
      required String agentId,
      required String sessionId,
      required String toolCallId,
      required String toolName,
      required String result,
    });

/// 自动修复写进卡片的那段失败信息（纯函数：措辞由测试钉住）。
///
/// 口径：**如实**说明"这次调用的结果永远拿不到"，并告诉模型接下来怎么自处
/// （不要假设成功、必要时重跑或复查产物）。不编造退出码、输出或耗时。
String autoRepairToolResultText({
  required String toolName,
  required String toolCallId,
}) {
  final String tool = toolName.trim().isEmpty ? '（未知工具）' : toolName.trim();
  final String call = toolCallId.trim().isEmpty
      ? '（没有 call_id）'
      : toolCallId.trim();
  return '【自动修复】这次工具调用的结果没有被收集：$tool（call_id=$call）'
      '在上一轮中途结束（用户停止 / 异常 / 核心重启），它的结果永远拿不到了。'
      '已按**失败**收尾——不要假设它成功：需要就重新调用，'
      '或用 terminal 复查进程与产物（不要直接重跑有副作用的命令）。';
}
