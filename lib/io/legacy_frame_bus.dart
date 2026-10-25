import 'package:flutter/foundation.dart' show debugPrint;

/// **旧帧名分发总线**（U3 配套）。
///
/// 迁移后领域帧从站点通道来（[FrameRouter]），但渲染入口仍是各个面板自己的
/// `onMessage` 处理函数。`WebSocketService.onMessage` 是**单槽**字段，多个面板
/// 会互相覆盖；直接把站点帧塞回某个实例又会漏掉其它面板（团队页同样要收
/// `agent_status`）。
///
/// 因此这里提供一个**多订阅者**的总线：面板在 `initState` 注册、`dispose` 注销，
/// [FrameRouter] 统一投递。它只搬帧，不做任何业务判断。
typedef LegacyFrameHandler = void Function(Map<String, dynamic> frame);

abstract final class LegacyFrameBus {
  static final Set<LegacyFrameHandler> _sinks = <LegacyFrameHandler>{};

  static void add(LegacyFrameHandler handler) => _sinks.add(handler);

  static void remove(LegacyFrameHandler handler) => _sinks.remove(handler);

  /// 当前订阅者数（诊断 / 测试用；面板销毁后必须下降，避免泄漏）。
  static int get sinkCount => _sinks.length;

  /// 投递给全部订阅者；单个订阅者抛异常不影响其它人。
  static void emit(Map<String, dynamic> frame) {
    for (final LegacyFrameHandler handler in List<LegacyFrameHandler>.of(_sinks)) {
      try {
        handler(frame);
      } catch (error) {
        // 一个面板的渲染异常不该让同一帧对其它面板失效，更不能打到根 zone。
        debugPrint('[LegacyFrameBus] 订阅者处理 ${frame['type']} 失败：$error');
      }
    }
  }
}
