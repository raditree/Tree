import 'package:test/test.dart';
import 'package:tree_core/src/server/token_registry.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 片 E / 5.1：token 作用域注册表。
///
/// 这里**固化**插件端点白名单：会话 token 的放行面是一份显式清单，任何新增 /
/// 删除都必须先改这条用例，避免"顺手放宽"。
void main() {
  group('token 作用域', () {
    test('主 token 行为逐字不变：任何路径都解析为 primary', () {
      final TokenRegistry registry = TokenRegistry(primaryToken: 'main-token');
      final TokenAccess? access = registry.resolveAuthorization(
        'Bearer main-token',
      );
      expect(access, isNotNull);
      expect(access!.scope, TokenScope.primary);
      expect(access.isPrimary, isTrue);
      expect(access.isBootstrapSession, isFalse);
      expect(
        registry.resolveAuthorization('Bearer  main-token '),
        isNotNull,
        reason: '主 token 的比较沿用既有 CoreToken.matches 宽容口径',
      );
    });

    test('缺少 / 伪造 Authorization 一律解析失败', () {
      final TokenRegistry registry = TokenRegistry(primaryToken: 'main-token');
      expect(registry.resolveAuthorization(null), isNull);
      expect(registry.resolveAuthorization('main-token'), isNull);
      expect(registry.resolveAuthorization('Bearer '), isNull);
      expect(registry.resolveAuthorization('Bearer forged'), isNull);
    });

    test('票据单次使用：第二次消费返回可读原因', () {
      final TokenRegistry registry = TokenRegistry(primaryToken: 'main-token');
      final String ticket = registry.issueBootstrapTicket();
      expect(registry.consumeBootstrapTicket(ticket), isNull);
      expect(registry.consumeBootstrapTicket(ticket), contains('已使用'));
      expect(registry.pendingTicketCount, 0);
    });

    test('票据过期：可读原因而不是静默失败', () {
      DateTime now = DateTime(2026, 1, 1);
      final TokenRegistry registry = TokenRegistry(
        primaryToken: 'main-token',
        clock: () => now,
      );
      final String ticket = registry.issueBootstrapTicket(
        ttl: const Duration(seconds: 1),
      );
      now = now.add(const Duration(seconds: 2));
      expect(registry.consumeBootstrapTicket(ticket), contains('已过期'));
    });

    test('票据不能当会话 token 用，也不能直接当 Authorization', () {
      final TokenRegistry registry = TokenRegistry(primaryToken: 'main-token');
      final String ticket = registry.issueBootstrapTicket();
      expect(registry.resolveAuthorization('Bearer $ticket'), isNull);
    });

    test('会话 token 带作用域；过期后解析失败并从表里移除', () {
      DateTime now = DateTime(2026, 1, 1);
      final TokenRegistry registry = TokenRegistry(
        primaryToken: 'main-token',
        clock: () => now,
      );
      final String session = registry.issueBootstrapSession(
        ttl: const Duration(minutes: 10),
      );
      final TokenAccess? access = registry.resolveAuthorization(
        'Bearer $session',
      );
      expect(access!.scope, TokenScope.bootstrapSession);
      expect(access.isBootstrapSession, isTrue);
      expect(registry.liveSessionCount, 1);

      now = now.add(const Duration(minutes: 11));
      expect(registry.resolveAuthorization('Bearer $session'), isNull);
      expect(registry.liveSessionCount, 0);
    });

    test('吊销只清会话，不动票据与主 token', () {
      final TokenRegistry registry = TokenRegistry(primaryToken: 'main-token');
      final String ticket = registry.issueBootstrapTicket();
      registry.issueBootstrapSession();
      registry.issueBootstrapSession();
      expect(registry.revokeSessions(reason: '测试'), 2);
      expect(registry.liveSessionCount, 0);
      expect(registry.pendingTicketCount, 1);
      expect(
        registry.resolveAuthorization('Bearer main-token')!.isPrimary,
        isTrue,
      );
      expect(registry.consumeBootstrapTicket(ticket), isNull);
    });
  });

  group('插件端点白名单（固化）', () {
    test('清单逐条固定：会话 token 只放行插件端点与 GET /api/meta', () {
      expect(TokenRegistry.bootstrapSessionAllowed, <String, Set<String>>{
        ApiPaths.meta: <String>{'GET'},
        ApiPaths.pluginSnapshot: <String>{'GET'},
        ApiPaths.pluginConfigs: <String>{'GET', 'POST'},
        ApiPaths.pluginConfig: <String>{'PATCH', 'DELETE'},
        ApiPaths.pluginConfigRestart: <String>{'POST'},
        ApiPaths.pluginBuiltins: <String>{'GET'},
        ApiPaths.pluginBuiltinEnable: <String>{'POST'},
        ApiPaths.pluginBuiltinDisable: <String>{'POST'},
        ApiPaths.pluginRelease: <String>{'GET'},
        ApiPaths.pluginReleaseRefresh: <String>{'POST'},
        ApiPaths.pluginReleaseInstall: <String>{'POST'},
        ApiPaths.pluginReleaseUninstall: <String>{'POST'},
        ApiPaths.pluginStation: <String>{'GET'},
        ApiPaths.pluginStationConfig: <String>{'PATCH'},
        ApiPaths.pluginStationSubscriber: <String>{'POST'},
      });
    });

    test('占位符路径按一段任意非空路径匹配，方法必须精确命中', () {
      expect(TokenRegistry.allowsBootstrapSession('GET', '/api/meta'), isTrue);
      expect(
        TokenRegistry.allowsBootstrapSession('POST', '/api/meta'),
        isFalse,
      );
      expect(
        TokenRegistry.allowsBootstrapSession('PATCH', '/api/plugin/configs/ui.alpha'),
        isTrue,
      );
      expect(
        TokenRegistry.allowsBootstrapSession('GET', '/api/plugin/configs/ui.alpha'),
        isFalse,
      );
      expect(
        TokenRegistry.allowsBootstrapSession('PATCH', '/api/plugin/configs'),
        isFalse,
        reason: '集合路径只允许 GET / POST',
      );
      expect(
        TokenRegistry.allowsBootstrapSession('GET', '/api/plugin/stations/'),
        isFalse,
        reason: '占位符不能匹配空段',
      );
      expect(
        TokenRegistry.allowsBootstrapSession('GET', '/api/plugin/stations/system.broadcast'),
        isTrue,
      );
    });

    test('领域端点、引导端点、文件端点都不在白名单里', () {
      for (final (String method, String path) in <(String, String)>[
        ('GET', ApiPaths.agents),
        ('GET', '/api/files/ws-1'),
        ('POST', ApiPaths.bootstrapTicket),
        ('POST', ApiPaths.bootstrapSession),
        ('GET', '/api/team'),
        ('GET', '/api/todos'),
        ('POST', '/api/models'),
      ]) {
        expect(
          TokenRegistry.allowsBootstrapSession(method, path),
          isFalse,
          reason: '$method $path 不应被会话 token 放行',
        );
      }
    });
  });
}
