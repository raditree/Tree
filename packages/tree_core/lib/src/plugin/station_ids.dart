/// 内置站点的**全局常量 id**（M9 §3，用户定稿语义）。
///
/// 站点 = 拦截点 / 触发点，**每类站全局只有一个实例**，所以它的 id 就是类型本身：
/// 不含 team、不含 mode。team / agent / session / mode 是**每次交互携带的信封**
/// （消息 scope）与**订阅声明**，只在投递时用于匹配订阅者。
///
/// 为什么独立成文件：`StationStore`（读侧迁移）与 `StationHub`（写侧创建）都要用
/// 这四个常量，而 store 不能反向依赖 hub（会成环）。
library;

/// 内置站点 id（同时也是 Hub 的基础 id）。
abstract final class StationHubIds {
  /// 广播站：插件发布 topic → 多订阅者接收 + 持久公告板。
  static const String broadcast = 'system.broadcast';

  /// 执行站：插件主动下命令，由挂载位置执行。
  static const String execute = 'system.execute';

  /// 中转站：数据流拦截-回填；**全站唯一订阅者**。
  static const String relay = 'system.relay';

  /// 收集站（插件定义 tool，首个接入点）：按站点 schema 汇聚订阅者产出。
  static const String collect = 'plugin.tool.define';

  /// 全部内置 id（注册校验 / 迁移判定用）。
  static const Set<String> all = <String>{
    broadcast,
    execute,
    relay,
    collect,
  };
}
