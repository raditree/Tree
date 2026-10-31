/// `station/command` 应答信封的**六个键名**（`docs/exec_station_contract.md` §4.1）。
///
/// 为什么单列一张表：同一个信封由**两条出口**构造——"命令路由不到"的早退与
/// "执行站回了结果"的正常出口。两处各写一遍键名，最先漂的往往是其中一处少写
/// 一个键（尤其 `code`），而调用方那边只会看到"有时有码、有时没码"。
/// 门禁（`exec_station_error_code_gate_test.dart`）据此断言两条出口的键集合相同。
///
/// 插件侧（`plugins/_kit`）按 ADR 不许 import 本包，因此它在自己的常量家抄同一组
/// 名字；两张表的一致性由同一条门禁的**字符串字面量扫描**覆盖（不是靠 import）。
abstract final class ExecStationEnvelopeKeys {
  /// 命令名（回显请求里的那一条，便于调用方对齐在途请求）。
  static const String command = 'command';

  /// 本次是否成功（`true` ⇒ [code] 必须为空串）。
  static const String ok = 'ok';

  /// 接管本次命令的挂载位置 id（空串 = 没挂上）。
  static const String mountId = 'mount_id';

  /// 结论载荷（形状由挂载位置定义；核心不补键）。
  static const String payload = 'payload';

  /// 可读中文原因（失败时非空；与 [code] 不互替）。
  static const String error = 'error';

  /// 稳定错误码（见 [ExecStationErrorCodes]；成功时为空串）。
  static const String code = 'code';

  /// 六键全集（门禁据此断言"两条出口键集合相同且不多不少"）。
  static const Set<String> all = <String>{
    command,
    ok,
    mountId,
    payload,
    error,
    code,
  };
}
