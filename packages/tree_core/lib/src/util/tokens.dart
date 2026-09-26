/// 粗略 token 估算：CJK 码点 ≈ 1 token，其余按 4 字符 ≈ 1 token。
///
/// 为什么要自己估：端点不是每次都返回 usage（本地 llama.cpp / vLLM 常常没有），
/// 而"上下文进度条"和**自动压缩阈值**都需要一个稳定口径。本函数刻意**偏保守
/// （宁可略高估）**：低估会让人以为还装得下，直到端点直接 400。
///
/// 口径必须与前端 progress 一致（前端也消费同一套 usage 字段），因此这里是唯一
/// 实现，会话服务与压缩器共用。
int estimateTokens(String text) {
  int cjk = 0;
  int other = 0;
  for (final int rune in text.runes) {
    if ((rune >= 0x2E80 && rune <= 0x9FFF) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0xFF00 && rune <= 0xFFEF)) {
      cjk++;
    } else {
      other++;
    }
  }
  return cjk + (other + 3) ~/ 4;
}
