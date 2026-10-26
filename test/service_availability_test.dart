import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/service_availability.dart';

/// G-7 / L-07：领域服务不可用的全局可见状态。
///
/// 钉住三条：
/// 1. 503 ⇒ 记下可读原因（空详情有兜底文案），主界面据此显示提示条；
/// 2. **领域端点**成功 ⇒ 自动撤掉；
/// 3. **平台面端点**成功不参与（核心自己的路由永远可用，不能拿它当"领域已恢复"）。
void main() {
  setUp(ServiceAvailability.dismiss);
  tearDown(ServiceAvailability.dismiss);

  test('503 记原因；空详情给兜底文案；领域成功自动清除', () {
    ServiceAvailability.reportUnavailable('agent 插件已停用');
    expect(ServiceAvailability.reason.value, 'agent 插件已停用');

    ServiceAvailability.reportAvailable('/api/plugin/snapshot');
    expect(
      ServiceAvailability.reason.value,
      'agent 插件已停用',
      reason: '平台面端点成功不代表领域服务恢复',
    );

    ServiceAvailability.reportAvailable('/api/agents/agt1/sessions');
    expect(ServiceAvailability.reason.value, isNull);

    ServiceAvailability.reportUnavailable('   ');
    expect(ServiceAvailability.reason.value, '依赖的插件服务不可用');
  });

  test('手动关闭：下一次 503 会再出现', () {
    ServiceAvailability.reportUnavailable('agent 插件进程异常退出');
    expect(ServiceAvailability.reason.value, isNotNull);

    ServiceAvailability.dismiss();
    expect(ServiceAvailability.reason.value, isNull);

    ServiceAvailability.reportUnavailable('agent 插件进程异常退出');
    expect(ServiceAvailability.reason.value, 'agent 插件进程异常退出');
  });
}
