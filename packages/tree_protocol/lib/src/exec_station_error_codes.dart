/// 执行站回包的错误码（`docs/exec_station_contract.md` §4.2 的**单一来源**）。
///
/// 口径（逐条可门禁化）：
/// - `code` 是 **snake_case 稳定字符串**，跨版本不改名；要改名就新增一个、旧的标 deprecated；
/// - `ok == true` ⇒ `code` 必须是**空串**（不许"成功也带个码"，否则判据变成两套）；
/// - `ok == false` ⇒ `code` 必须非空且在 [all] 里；`error` 继续带可读中文人话（两者不互替）；
/// - 老插件不回 `code` ⇒ 核心补 [unknown] 并写一条日志（缺码可见，不许静默当成无码可判）；
/// - `code` **不进** JSON-RPC 的 `error.code`（那是协议层的 `-32602` 那一族，两套语义混不得）。
///
/// 命名规则：`<对象>_<状态>`，不带族前缀（`file_` / `ssh_` 不带）。
/// 唯一的共用是 [leaseUnknown]：两侧（本机 / SSH）都用它——"租约不在"这件事由
/// "谁持有租约表"决定，语义同、来源异，`mount_id` 已经指出是谁。
abstract final class ExecStationErrorCodes {
  /// 成功：码恒为空串（[ok] 的判据）。
  static const String none = '';

  // ── 核心 ────────────────────────────────────────────────────────────
  /// 命令名不认识（看 `error` 里的可用命令表改名字）。
  static const String commandUnknown = 'command_unknown';

  // ── 站点 ────────────────────────────────────────────────────────────
  /// 点位已停用：等启用或换挂载。
  static const String stationDisabled = 'station_disabled';

  /// 身份 / 隔离校验不过：**不重试**。
  static const String scopeDenied = 'scope_denied';

  /// 命令名不属于这个点位。
  static const String commandNotOnStation = 'command_not_on_station';

  /// 没有执行器接管：装配或启动插件。
  static const String noMount = 'no_mount';

  // ── 挂载 ────────────────────────────────────────────────────────────
  /// 插件实体不在：按生命周期分化（crash / uninstalled ⇒ 503 不是 404）。
  static const String pluginOffline = 'plugin_offline';

  /// 插件回包非法（不是对象 / 缺 `payload`）：报插件 bug。
  static const String badReply = 'bad_reply';

  /// 挂载位置抛异常。
  static const String mountException = 'mount_exception';

  // ── 插件（执行器）──────────────────────────────────────────────────
  /// 参数缺失 / 越界（`path` 越出根、缺 `pattern` 等）。
  static const String invalidArguments = 'invalid_arguments';

  /// 路径不存在（read / list / delete / rename 的 missing）。
  static const String fileNotFound = 'file_not_found';

  /// 目标是目录，不能当文件读。
  static const String notAFile = 'not_a_file';

  /// 删除需要 `recursive: true`。
  static const String dirNotEmpty = 'dir_not_empty';

  /// rename 目标已存在 ⇒ **绝不覆盖**。
  static const String targetExists = 'target_exists';

  /// base64 非法。
  static const String badBase64 = 'bad_base64';

  /// 租约不在（本机 / SSH 共用）：调用方重登记后**只重试一次**。
  static const String leaseUnknown = 'lease_unknown';

  /// 跨插件借用别人的租约：登记方与调用方不是同一个插件（契约 §8.3）。
  static const String leaseDenied = 'lease_denied';

  /// 隧道 / 远端 agent 不可用。
  static const String backendUnreachable = 'backend_unreachable';

  // ── 兜底 ────────────────────────────────────────────────────────────
  /// 任何没给码的失败：只能当"可读原因、不可编程分支"处理。
  static const String unknown = 'unknown';

  /// 登记表（门禁与"老插件补码"唯一依据）。
  static const Set<String> all = <String>{
    commandUnknown,
    stationDisabled,
    scopeDenied,
    commandNotOnStation,
    noMount,
    pluginOffline,
    badReply,
    mountException,
    invalidArguments,
    fileNotFound,
    notAFile,
    dirNotEmpty,
    targetExists,
    badBase64,
    leaseUnknown,
    leaseDenied,
    backendUnreachable,
    unknown,
  };

  /// 码是否已登记（空串 = 成功，不算失败码）。
  static bool isKnown(String code) => all.contains(code);

  /// 失败时补码：空串 / 未登记的码一律收敛成 [unknown]（"缺码可见"由调用方记日志）。
  static String settle(String code) {
    final String trimmed = code.trim();
    return isKnown(trimmed) ? trimmed : unknown;
  }
}
