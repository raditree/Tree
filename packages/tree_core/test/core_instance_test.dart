import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  group('核心实例发现文件（单实例）', () {
    test('JSON 往返：字段原样保留', () {
      const CoreInstanceRecord record = CoreInstanceRecord(
        pid: 12,
        port: 54321,
        token: 'abc',
        version: '1.0.5',
        dataRoot: r'C:\data',
      );
      final CoreInstanceRecord? decoded = CoreInstanceRecord.decode(
        '{"pid":12,"host":"127.0.0.1","port":54321,"token":"abc",'
        '"version":"1.0.5","data_root":"C:\\\\data"}',
      );
      expect(decoded, isNotNull);
      expect(decoded!.pid, 12);
      expect(decoded.port, 54321);
      expect(decoded.token, 'abc');
      expect(decoded.version, '1.0.5');
      expect(decoded.dataRoot, r'C:\data');
      expect(decoded.httpBaseUrl, 'http://127.0.0.1:54321');
      expect(record.toJson()['port'], 54321);
    });

    test('缺 port / token 的记录一律当“没有”', () {
      expect(CoreInstanceRecord.decode('not json'), isNull);
      expect(CoreInstanceRecord.decode('{"port":0,"token":"x"}'), isNull);
      expect(CoreInstanceRecord.decode('{"port":123}'), isNull);
    });

    test('写入后可读、clear 后为空', () async {
      final Directory dir = await Directory.systemTemp.createTemp('tree_inst');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final CoreInstanceFile file = CoreInstanceFile(
        '${dir.path}${Platform.pathSeparator}runtime'
        '${Platform.pathSeparator}core.json',
      );
      expect(file.read(), isNull);
      await file.write(
        const CoreInstanceRecord(pid: 99, port: 4040, token: 'tk'),
      );
      final CoreInstanceRecord? read = file.read();
      expect(read, isNotNull);
      expect(read!.pid, 99);
      expect(read.port, 4040);
      expect(read.token, 'tk');
      file.clear();
      expect(file.read(), isNull);
    });

    test('没人监听 ⇒ 探测为不活（陈旧记录不会被误认）', () async {
      final ServerSocket probe = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int port = probe.port;
      await probe.close();
      final CoreInstanceFile file = CoreInstanceFile('${Directory.systemTemp.path}/x/core.json');
      expect(
        await file.alive(
          CoreInstanceRecord(pid: 1, port: port, token: 'tk'),
          timeout: const Duration(milliseconds: 500),
        ),
        isFalse,
      );
    });
  });
}
