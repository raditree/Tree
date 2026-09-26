import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// M9/Q1-①：token 口径统一为单一标量 `ceil(字符数 / token_scale)`。
///
/// 这里锁住三件事：默认比例、逐模型比例的算法、非法比例的回退——它们是进度条、
/// 压缩阈值与工具结果门控共同的基准。
void main() {
  group('estimateTokens', () {
    test('默认比例 2.00：向上取整，且不再区分 CJK/ASCII', () {
      expect(defaultTokenScale, 2.0);
      expect(estimateTokens(''), 0);
      expect(estimateTokens('a'), 1);
      expect(estimateTokens('ab'), 1);
      expect(estimateTokens('abc'), 2);
      expect(estimateTokens('中文四个字'), 3);
      expect(estimateTokens('x' * 1000), 500);
      expect(
        estimateTokens('中' * 100),
        estimateTokens('a' * 100),
        reason: '同一标量口径下字符集不该再影响结果',
      );
    });

    test('逐模型比例：ceil(字符数 / scale)', () {
      expect(estimateTokens('x' * 1000, scale: 4), 250);
      expect(estimateTokens('x' * 1000, scale: 1.5), 667);
      expect(estimateTokens('x' * 3, scale: 10), 1);
      expect(estimateTokens('x' * 1000, scale: 0.5), 2000);
    });

    test('比例非法（<= 0）时回退到默认值，不产生除零', () {
      expect(estimateTokens('x' * 1000, scale: 0), 500);
      expect(estimateTokens('x' * 1000, scale: -1), 500);
    });

    test('消息与请求的估算共用同一比例', () {
      final LlmMessage message = LlmMessage.user('x' * 1000);
      expect(message.estimatedTokens(), 500);
      expect(message.estimatedTokens(scale: 4), 250);
      expect(message.charCount, 1000);
      final LlmRequest request = LlmRequest(
        model: 'demo',
        messages: <LlmMessage>[message],
      );
      expect(request.estimatedPromptTokens(), 500);
      expect(request.estimatedPromptTokens(scale: 4), 250);
      expect(request.contextChars(), 1000);
    });
  });
}
