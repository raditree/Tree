import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/services/download_center.dart';

/// M8d：下载列表的状态机与「来源 team」标注。
///
/// 这是全局单例（左栏面板的数据源），因此每个用例开始/结束都清干净，避免串味。
void main() {
  final DownloadCenter center = DownloadCenter.instance;

  void clearAll() {
    // clearFinished 故意保留进行中的任务，测试之间要连它们一起清掉
    for (final DownloadTask task in center.tasks) {
      center.remove(task);
    }
  }

  setUp(clearAll);
  tearDown(clearAll);

  test('begin → progress → complete：进度、状态与来源都落在任务上', () {
    final DownloadTask task = center.begin(
      kind: DownloadKind.file,
      name: 'a.bin',
      sourceTeam: '团队A',
      sourceTeamId: 'agt_1',
      savePath: '/tmp/a.bin',
    );
    expect(center.runningCount, 1);
    expect(center.hasFinished, isFalse);

    center.progress(task, 10, 100);
    expect(task.progress, closeTo(0.1, 1e-9));
    expect(task.statusText, contains('10'));

    center.complete(task);
    expect(task.status, DownloadStatus.done);
    expect(center.runningCount, 0);
    expect(center.hasFinished, isTrue);
    expect(center.tasks.single.sourceLabel, '团队A');
  });

  test('总长未知：progress 为 null（界面用不确定进度条）', () {
    final DownloadTask task = center.begin(
      kind: DownloadKind.folder,
      name: 'd.tar.gz',
      sourceTeam: '',
      sourceTeamId: 'agt_2',
    );
    expect(task.sourceLabel, 'agt_2', reason: '没有显示名时退回 agent id');
    center.progress(task, 1024, -1);
    expect(task.progress, isNull);
    expect(task.statusText, contains('KB'));
  });

  test('fail / cancel 都结束任务，clearFinished 只清已结束的', () {
    final DownloadTask failing = center.begin(
      kind: DownloadKind.file,
      name: 'bad.bin',
      sourceTeam: 'T',
      sourceTeamId: 'agt_3',
    );
    center.fail(failing, '磁盘已满');
    expect(failing.status, DownloadStatus.failed);
    expect(failing.statusText, contains('磁盘已满'));

    final DownloadTask running = center.begin(
      kind: DownloadKind.file,
      name: 'now.bin',
      sourceTeam: 'T',
      sourceTeamId: 'agt_4',
    );
    final DownloadTask cancelled = center.begin(
      kind: DownloadKind.file,
      name: 'stop.bin',
      sourceTeam: 'T',
      sourceTeamId: 'agt_5',
    );
    center.cancel(cancelled);
    expect(cancelled.status, DownloadStatus.cancelled);

    center.clearFinished();
    expect(center.tasks.single.id, running.id, reason: '进行中的任务不该被清掉');
    expect(center.runningCount, 1);
  });
}
