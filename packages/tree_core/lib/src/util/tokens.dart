/// 全局唯一的 token 估算口径（plan 1.3）：`tokens = ceil(字符数 / token_scale)`。
///
/// 为什么要自己估：端点不是每次都返回 usage（本地 llama.cpp / vLLM 常常没有），
/// 而"上下文进度条"、**自动压缩阈值**、超长工具结果门控都需要一个稳定口径。
///
/// 为什么不再按 CJK/ASCII 细分（M9/Q1-①）：细分的那两个系数是拍出来的，与端点
/// 真实分词器无关；改用**逐模型的单一标量** token_scale（存在
/// `models/<model_id>.yaml`，初值 [defaultTokenScale]），它可以被端点回传的真实
/// `prompt_tokens` 持续校准（见 [CoreModelConfig.learnTokenScale]）——长会话下系统
/// 提示词/工具声明这些固定开销被摊薄，chars/token 才逼近内容真实比值。
///
/// 因此上下文进度、压缩阈值、工具结果门控、工具参数计量**全部共用这一个函数**：
/// 口径一旦分叉，就会出现"进度条说没超、端点却报超限"这种没法排查的现象。
library;

/// 字符 → token 的默认换算比例（逐模型 token_scale 的初值）。
///
/// 取 2.00 是**刻意偏保守**的起点：中文约 1~1.5 字符/token、英文约 4 字符/token，
/// 用 2 意味着对英文略高估——低估会让人以为还装得下，直到端点直接 400。
const double defaultTokenScale = 2.0;

/// 估算 [text] 占用的 token 数：`ceil(字符数 / scale)`。
///
/// 字符数取 Dart 的 `String.length`（UTF-16 码元；中文、日文等 BMP 字符与码点数
/// 一致），这样估算点与提示文案里的"字符数"是同一个量。
///
/// [scale] 是逐模型的 token_scale；<= 0 视为无效值，回退到 [defaultTokenScale]。
int estimateTokens(String text, {double scale = defaultTokenScale}) {
  if (text.isEmpty) return 0;
  final double effective = scale > 0 ? scale : defaultTokenScale;
  return (text.length / effective).ceil();
}
