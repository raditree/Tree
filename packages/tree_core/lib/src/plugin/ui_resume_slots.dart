/// 一次 UI 热重启里「待新世取走的视图状态切片」。
///
/// 为什么单独一个类型而不是 `Map<String, dynamic>`：
/// - **一片只喂一世**：`pending` / `taken` 是取走与否的唯一账本，`resumed` 只能由它说话；
/// - **世代校验**：切片属于「上一世」，中途又重启一次就必须作废（`generation` 不符即丢）；
/// - **字节读数**：面板按窗口报续跑结果时要能说清「这一片多大」，而切片取走后
///   原 map 会被删掉，因此尺寸单独留一份。
///
/// 生命周期只有「一次重启」那么长：新世每个窗口的 `ui.hello` 到达后取走自己那一片
/// 并推 `plugin.resume`；没被取走的随快照池 TTL 自然过期（不手工删）。
class UiResumeSlots {
  UiResumeSlots({
    required this.generation,
    required this.dumpId,
    required this.slices,
    required this.pending,
  }) : sizes = <String, int>{
         for (final MapEntry<String, UiResumeSlice> entry in slices.entries)
           entry.key: entry.value.bytes,
       };

  /// 切片所属**新世**的代际（`hello` 时若已不符则整批作废）。
  final int generation;

  /// 快照 id（`pluginId#旧世代`，回包里给调用方看的那一个）。
  final String dumpId;

  /// 还没被取走的切片：`window_id → 切片`。
  final Map<String, UiResumeSlice> slices;

  /// 还在等 hello 的窗口（都访问过一遍即视为本轮握手收尾）。
  final Set<String> pending;

  /// 已取走切片的窗口（`resumed` 的唯一判据）。
  final Set<String> taken = <String>{};

  /// 每个窗口切片的大小（字节；切片取走后仍要能报读）。
  final Map<String, int> sizes;

  int bytesOf(String windowId) => sizes[windowId] ?? 0;
}

/// 单个窗口的视图状态切片（载荷对核心**不透明**）。
class UiResumeSlice {
  const UiResumeSlice({required this.payload, required this.bytes});

  /// 界面自己写下的那层 JSON（核心不认识其中任何字段）。
  final Object? payload;

  final int bytes;
}
