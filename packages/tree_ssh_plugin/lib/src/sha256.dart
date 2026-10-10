/// 最小 SHA-256（纯函数）。
///
/// **为什么不引 `package:crypto`**：本插件的运行时依赖只有 `dartssh2` 与
/// `tree_tunnel_protocol`（协议 §2/§6 要求按 sha256 做 agent 版本对账，
/// 而随包 agent 的 sha 必须在**本机**算一遍才能与目标机的 `sha256sum` 比）。
/// 为这一件事多引一个包不划算，且这段算法有标准向量可钉（见 `test/sha256_test.dart`）。
///
/// 只做"算一个文件的摘要"这一件事：不做流式 API、不做 HMAC。
library;

/// 常量表（FIPS 180-4）。
const List<int> _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// 初始哈希值。
const List<int> _h0 = <int>[
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

/// 计算 [data] 的 SHA-256，返回 64 位小写十六进制。
String sha256Hex(List<int> data) {
  final List<int> h = List<int>.of(_h0);
  // padding：0x80 + 若干 0 + 64 位大端 bit 长度
  final int bitLength = data.length * 8;
  final List<int> padded = List<int>.of(data)..add(0x80);
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (int i = 7; i >= 0; i--) {
    padded.add((bitLength >> (8 * i)) & 0xff);
  }

  final List<int> w = List<int>.filled(64, 0);
  for (int offset = 0; offset < padded.length; offset += 64) {
    for (int i = 0; i < 16; i++) {
      final int b = offset + i * 4;
      w[i] =
          (padded[b] << 24) |
          (padded[b + 1] << 16) |
          (padded[b + 2] << 8) |
          padded[b + 3];
    }
    for (int i = 16; i < 64; i++) {
      final int s0 =
          _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final int s1 =
          _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }

    int a = h[0];
    int b = h[1];
    int c = h[2];
    int d = h[3];
    int e = h[4];
    int f = h[5];
    int g = h[6];
    int hh = h[7];

    for (int i = 0; i < 64; i++) {
      final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final int ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final int temp1 = (hh + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int temp2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }

  final StringBuffer out = StringBuffer();
  for (final int word in h) {
    out.write(word.toRadixString(16).padLeft(8, '0'));
  }
  return out.toString();
}

int _rotr(int value, int bits) =>
    ((value >> bits) | (value << (32 - bits))) & 0xffffffff;

/// 把摘要转成"前 8 位 + …"的短形态（只用于日志；**对账永远用完整摘要**）。
String shortDigest(String hex) =>
    hex.length <= 16 ? hex : '${hex.substring(0, 8)}…';
