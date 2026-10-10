import 'dart:convert';
import 'dart:io';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// 命令行解析失败（缺参数 / 参数不合法）。**不是** RPC 错误：发生在服务启动之前。
class AgentConfigException implements Exception {
  AgentConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `tree_agent` 的启动配置（`bin/tree_agent.dart` 解析出来后交给 [AgentServer]）。
///
/// 命令行：`--root <abs> --token <t> [--state-dir <abs>] [--idle-timeout-ms 0] [--version]`
///
/// - [root]：工作空间根（**目标机绝对路径**，正斜杠口径）。所有路径参数都必须落在它之内
///   （见 [PathGuard]）。
/// - [token]：插件启动 agent 时传的一次性握手凭据（**只走命令行，不进日志**）。
///   agent 用它校验"这一条通道是同一个启动方"，防止别的本机用户蹭上这个 stdio。
/// - [stateDir]：状态目录（`procs.json` / `exit/<id>` / `run/<id>.{sh,out}`）。
///   缺省 `$HOME/.tree/agent/state/<sha256(root) 前 16 hex>` —— 同一台机器上
///   **多工作空间互不串扰**。
/// - [idleTimeout]：`null` = 永不（缺省 `--idle-timeout-ms 0`，与仓库"没有静态总时长上限"
///   同口径）；显式给正数时，连续这么久没有任何帧进来就退出。
class AgentConfig {
  AgentConfig({
    required this.root,
    required this.token,
    required this.stateDir,
    this.idleTimeout,
    this.home = '',
  });

  final String root;
  final String token;
  final String stateDir;
  final Duration? idleTimeout;

  /// 目标机的 HOME（`agent.hello` / `agent.info` 回给插件；缺省状态目录也用它算）。
  final String home;

  /// 解析命令行。`--version` **不走这里**（它在 `bin` 里前置处理，因为它不需要 root/token）。
  static AgentConfig parse(List<String> argv, {Map<String, String>? environment}) {
    final Map<String, String> env = environment ?? Platform.environment;
    String? root;
    String? token;
    String? stateDir;
    int idleMs = 0;
    for (int i = 0; i < argv.length; i++) {
      final String arg = argv[i];
      switch (arg) {
        case '--root':
          root = _valueOf(argv, ++i, '--root');
        case '--token':
          token = _valueOf(argv, ++i, '--token');
        case '--state-dir':
          stateDir = _valueOf(argv, ++i, '--state-dir');
        case '--idle-timeout-ms':
          final String raw = _valueOf(argv, ++i, '--idle-timeout-ms');
          final int? parsed = int.tryParse(raw);
          if (parsed == null || parsed < 0) {
            throw AgentConfigException('--idle-timeout-ms 需要非负整数（收到 "$raw"）');
          }
          idleMs = parsed;
        default:
          throw AgentConfigException('无法识别的参数：$arg$usageSuffix');
      }
    }
    if (root == null || root.trim().isEmpty) {
      throw AgentConfigException('缺少 --root <工作空间根绝对路径>$usageSuffix');
    }
    if (token == null || token.isEmpty) {
      throw AgentConfigException('缺少 --token <握手凭据>$usageSuffix');
    }
    final String normalizedRoot = normalizePosixPath(root.trim());
    final String home = homeOf(env);
    final String dir = (stateDir == null || stateDir.trim().isEmpty)
        ? defaultStateDir(normalizedRoot, home)
        : normalizePosixPath(stateDir.trim());
    return AgentConfig(
      root: normalizedRoot,
      token: token,
      stateDir: dir,
      idleTimeout: idleMs <= 0 ? null : Duration(milliseconds: idleMs),
      home: home,
    );
  }

  /// 缺省状态目录：`$HOME/.tree/agent/state/<sha256(root) 前 16 hex>`。
  static String defaultStateDir(String root, String home) {
    final String key = stateKey(root);
    final String base = home.trim().isEmpty ? '.' : home.trim();
    return normalizePosixPath('$base/$kAgentStateDir/$key');
  }

  /// 工作空间的**状态键**：`sha256(root)` 的前 16 个 hex。
  static String stateKey(String root) =>
      sha256Hex(normalizePosixPath(root)).substring(0, 16);

  /// 目标机的 HOME（Linux 是 `$HOME`；Windows 只在开发机单测里用到）。
  static String homeOf(Map<String, String> env) {
    final String home = (env['HOME'] ?? '').trim();
    if (home.isNotEmpty) return home;
    return (env['USERPROFILE'] ?? '').trim();
  }

  /// 目标机架构（`x64` / `arm64` / …），从 [Platform.version] 的 `on "<os>_<arch>"` 里取。
  ///
  /// 为什么不用 `dart:ffi` 的 `Abi.current()`：本包刻意零第三方依赖、也不引 ffi
  /// （目标机二进制越小越静态越好）；`Platform.version` 已足够。
  static String detectArch([String? version]) {
    final String text = version ?? Platform.version;
    final Match? match = RegExp(
      r'on "([A-Za-z0-9]+)_([A-Za-z0-9]+)"',
    ).firstMatch(text);
    return match?.group(2) ?? '';
  }

  static const String usageSuffix =
      '\n用法：tree_agent --root <abs> --token <t> '
      '[--state-dir <abs>] [--idle-timeout-ms 0] [--version]';

  static String _valueOf(List<String> argv, int index, String flag) {
    if (index >= argv.length) throw AgentConfigException('$flag 缺少取值$usageSuffix');
    return argv[index];
  }
}

// ── SHA-256（纯 Dart，零依赖）────────────────────────────────────────────
//
// 为什么自己写：缺省状态目录要 `sha256(root)` 的前 16 hex 做多工作空间隔离键，
// 而 `packages/tree_tunnel_protocol` 不许引 `package:crypto`、本包也不许引第三方。
// 目标机虽有 `sha256sum`，但调用外部进程既慢又依赖 PATH，还要在 Windows 开发机上
// 能跑单测 ⇒ 自带一份最小的 SHA-256（FIPS 180-4）。

const List<int> _kSha256K = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

int _u32(int x) => x & 0xFFFFFFFF;

/// `sha256(input 的 UTF-8 字节)` 的小写 hex（64 字符）。
String sha256Hex(String input) {
  final List<int> message = utf8.encode(input);
  final List<int> h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final int bitLength = message.length * 8;
  final List<int> padded = List<int>.of(message)..add(0x80);
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (int shift = 56; shift >= 0; shift -= 8) {
    padded.add((bitLength >> shift) & 0xff);
  }

  final List<int> w = List<int>.filled(64, 0);
  for (int offset = 0; offset < padded.length; offset += 64) {
    for (int i = 0; i < 16; i++) {
      final int base = offset + i * 4;
      w[i] = _u32(
        (padded[base] << 24) |
            (padded[base + 1] << 16) |
            (padded[base + 2] << 8) |
            padded[base + 3],
      );
    }
    for (int i = 16; i < 64; i++) {
      final int x = w[i - 15];
      final int y = w[i - 2];
      final int s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
      final int s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
      w[i] = _u32(w[i - 16] + s0 + w[i - 7] + s1);
    }
    int a = h[0], b = h[1], c = h[2], d = h[3];
    int e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
      final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final int ch = (e & f) ^ (_u32(~e) & g);
      final int temp1 = _u32(hh + s1 + ch + _kSha256K[i] + w[i]);
      final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int temp2 = _u32(s0 + maj);
      hh = g;
      g = f;
      f = e;
      e = _u32(d + temp1);
      d = c;
      c = b;
      b = a;
      a = _u32(temp1 + temp2);
    }
    h[0] = _u32(h[0] + a);
    h[1] = _u32(h[1] + b);
    h[2] = _u32(h[2] + c);
    h[3] = _u32(h[3] + d);
    h[4] = _u32(h[4] + e);
    h[5] = _u32(h[5] + f);
    h[6] = _u32(h[6] + g);
    h[7] = _u32(h[7] + hh);
  }
  final StringBuffer out = StringBuffer();
  for (final int word in h) {
    out.write(word.toRadixString(16).padLeft(8, '0'));
  }
  return out.toString();
}
