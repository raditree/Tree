import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/single_instance.dart';

/// 单实例锁：**同一数据根只允许一个实例**，但又不能因为"撞了个端口"把用户挡在门外。
///
/// 两个方向都要钉住：
/// 1. 真正的第二个实例必须被识别出来（并请第一个实例把窗口叫到前面）；
/// 2. 端口被**别的程序**占用时必须照常启动。
void main() {
  test('锁键：TREE_INSTANCE_KEY 优先 / TREE_HOME 归一 / 都没有给 default', () {
    expect(SingleInstanceLock.lockKey(<String, String>{}), 'default');
    expect(
      SingleInstanceLock.lockKey(<String, String>{'TREE_HOME': r'C:\Data'}),
      r'c:\data',
      reason: 'Windows 路径大小写不敏感：同一个数据根必须归一成同一个键',
    );
    expect(
      SingleInstanceLock.lockKey(<String, String>{
        'TREE_HOME': r'C:\Data',
        'TREE_INSTANCE_KEY': '  extra  ',
      }),
      'extra',
      reason: '显式锁键优先（多开调试用）',
    );
  });

  test('锁键 → 端口：同键恒等、落在私有区间、不同数据根分散', () {
    final int a = SingleInstanceLock.portFor('default');
    expect(SingleInstanceLock.portFor('DEFAULT'), a, reason: '键再归一一次');
    expect(a, greaterThanOrEqualTo(SingleInstanceLock.portBase));
    expect(a, lessThan(SingleInstanceLock.portBase + SingleInstanceLock.portSpan));
    final Set<int> ports = <int>{
      for (final String key in <String>['default', r'c:\a', r'c:\b', r'd:\x'])
        SingleInstanceLock.portFor(key),
    };
    expect(ports.length, greaterThan(1), reason: '不同数据根不该挤在同一个端口上');
  });

  test('同一锁键：第二个实例判为已运行，并触发唤起窗口；释放后可以再来', () async {
    final SingleInstanceLock first = SingleInstanceLock(
      keyOverride: 'unit-test-same-key',
    );
    final Completer<void> activated = Completer<void>();
    first.onActivate = () async {
      if (!activated.isCompleted) activated.complete();
    };
    expect(await first.acquire(), SingleInstanceState.acquired);

    final SingleInstanceLock second = SingleInstanceLock(
      keyOverride: 'unit-test-same-key',
    );
    expect(
      await second.acquire(),
      SingleInstanceState.alreadyRunning,
      reason: '同数据根的第二个实例必须退出，绝不拉起第二个核心',
    );
    await activated.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => fail('持有者没有收到"唤起窗口"的请求'),
    );

    await second.release();
    await first.release();
    final SingleInstanceLock third = SingleInstanceLock(
      keyOverride: 'unit-test-same-key',
    );
    expect(await third.acquire(), SingleInstanceState.acquired, reason: '锁是进程级的，释放即可复用');
    await third.release();
  });

  test('不同锁键互不干扰：两个实例都能拿到锁', () async {
    final SingleInstanceLock a = SingleInstanceLock(keyOverride: 'unit-test-key-a');
    final SingleInstanceLock b = SingleInstanceLock(keyOverride: 'unit-test-key-b');
    expect(await a.acquire(), SingleInstanceState.acquired);
    expect(
      await b.acquire(),
      SingleInstanceState.acquired,
      reason: '开发用的临时数据根（TREE_HOME）不该被装好的那份挡住',
    );
    await b.release();
    await a.release();
  });

  test('端口被别的程序占着（不回话）：照常启动，不拦人', () async {
    const String key = 'unit-test-foreign-silent';
    final ServerSocket foreign = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      SingleInstanceLock.portFor(key),
    );
    foreign.listen((Socket s) => s.listen((List<int> _) {}, onError: (Object _) {}));
    addTearDown(foreign.close);

    final SingleInstanceLock lock = SingleInstanceLock(keyOverride: key);
    expect(await lock.acquire(), SingleInstanceState.acquired);
  });

  test('端口上的程序回了别的东西：不认成自己人，照常启动', () async {
    const String key = 'unit-test-foreign-http';
    final ServerSocket foreign = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      SingleInstanceLock.portFor(key),
    );
    foreign.listen(
      (Socket s) => s.listen((List<int> _) {
        s.write('HTTP/1.1 400 Bad Request\n\n');
        s.close();
      }, onError: (Object _) {}),
    );
    addTearDown(foreign.close);

    final SingleInstanceLock lock = SingleInstanceLock(keyOverride: key);
    expect(await lock.acquire(), SingleInstanceState.acquired);
  });
}
