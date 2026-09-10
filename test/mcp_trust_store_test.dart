// MCP 启动命令信任存储单元测试。
//
// 信任是第三方 MCP 服务在本地 / SSH 宿主上「首次确认后才能拉起」的唯一闸门：
// 指纹算错会导致重复索要确认，校验漏判会让未经确认的命令直接执行。本文件覆盖
// 指纹稳定性与授权/撤销/校验语义。
// 运行方式（项目根目录）：
//   flutter test test/mcp_trust_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/io/mcp_trust_store.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('fingerprint', () {
    test('同一命令与参数得到相同指纹（命令首尾空白被忽略）', () {
      expect(
        McpTrustStore.fingerprint('  npx ', <String>['-y', 'pkg']),
        McpTrustStore.fingerprint('npx', <String>['-y', 'pkg']),
      );
    });

    test('参数不同则指纹不同（参数决定实际运行的包）', () {
      expect(
        McpTrustStore.fingerprint('npx', <String>['-y', 'pkg-a']),
        isNot(McpTrustStore.fingerprint('npx', <String>['-y', 'pkg-b'])),
      );
    });

    test('命令与参数不混淆（分隔符分隔，无参数与含参数不同）', () {
      expect(
        McpTrustStore.fingerprint('npx', <String>['pkg']),
        isNot(McpTrustStore.fingerprint('npx pkg', <String>[])),
      );
    });

    test('大小写与路径形态不做归一（各自独立确认）', () {
      expect(
        McpTrustStore.fingerprint('npx', <String>[]),
        isNot(McpTrustStore.fingerprint('C:\\nodejs\\npx.cmd', <String>[])),
      );
    });
  });

  group('trust / revoke / isTrusted', () {
    test('默认未信任，确认后信任，撤销后恢复未信任', () async {
      final String fp = McpTrustStore.fingerprint('mytool', <String>['--serve']);
      expect(await McpTrustStore.isTrusted(fp), isFalse);

      await McpTrustStore.trust(fp);
      expect(await McpTrustStore.isTrusted(fp), isTrue);

      await McpTrustStore.revoke(fp);
      expect(await McpTrustStore.isTrusted(fp), isFalse);
    });

    test('重复确认幂等（持久化列表不产生重复项）', () async {
      final String fp = McpTrustStore.fingerprint('mytool', <String>[]);
      await McpTrustStore.trust(fp);
      await McpTrustStore.trust(fp);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('mcp_trusted_commands'), <String>[fp]);
    });

    test('确认结果持久化（新读取到的实例仍信任）', () async {
      final String fp = McpTrustStore.fingerprint('mytool', <String>[]);
      await McpTrustStore.trust(fp);
      expect(await McpTrustStore.isTrusted(fp), isTrue);
    });

    test('空指纹不入库', () async {
      await McpTrustStore.trust('');
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('mcp_trusted_commands'), isNull);
    });
  });

  group('checkLaunch', () {
    test('无需确认时直接放行（可信启动器免确认）', () async {
      expect(
        await McpTrustStore.checkLaunch(
          'mytool',
          <String>['--serve'],
          needsConfirmation: false,
        ),
        isNull,
      );
    });

    test('需确认且未信任时拒绝，错误信息含命令与引导文案', () async {
      final String? denied = await McpTrustStore.checkLaunch(
        'mytool',
        <String>['--serve'],
        needsConfirmation: true,
      );
      expect(denied, isNotNull);
      expect(denied, contains('mytool --serve'));
      expect(denied, contains('未获信任'));
    });

    test('需确认但已信任时放行', () async {
      await McpTrustStore.trust(
        McpTrustStore.fingerprint('mytool', <String>['--serve']),
      );
      expect(
        await McpTrustStore.checkLaunch(
          'mytool',
          <String>['--serve'],
          needsConfirmation: true,
        ),
        isNull,
      );
    });

    test('信任绑定到完整命令：同启动器换参数仍需确认', () async {
      await McpTrustStore.trust(
        McpTrustStore.fingerprint('npx', <String>['-y', 'pkg-a']),
      );
      expect(
        await McpTrustStore.checkLaunch(
          'npx',
          <String>['-y', 'pkg-b'],
          needsConfirmation: true,
        ),
        isNotNull,
      );
    });
  });
}
