import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/local_scan_follow_up.dart';

void main() {
  const readWrite = LocalTreePermission(
    persistedRead: true,
    persistedWrite: true,
  );

  test('重授权换目录处理清理队列、迁移确认和迁移失败记录', () async {
    final calls = <String>[];
    final result = await finishLocalReauthorization(
      previousFolder: 'old',
      pickedFolder: 'new',
      permission: readWrite,
      scanAndApply: () async {
        calls.add('scan');
        return applyLocalScanFollowUp<int>(
          remaps: [1, 2],
          cleanupAssociations: () async {
            calls.add('cleanup-queue');
          },
          migrate: (id) async {
            calls.add('migrate:$id');
            if (id == 2) throw StateError('migration failed');
          },
          confirm: (id) async {
            calls.add('confirm:$id');
          },
          recordFailure: (id, error) async {
            calls.add('persist-failure:$id');
          },
          bookIdOf: (id) => id,
        );
      },
    );
    expect(calls, [
      'scan',
      'cleanup-queue',
      'migrate:1',
      'confirm:1',
      'migrate:2',
      'persist-failure:2',
    ]);
    expect(result.folderChanged, isTrue);
    expect(result.canRetryDelete, isFalse);
    expect(result.followUp.failedMigrations, 1);
    expect(result.followUp.handled, isTrue);
  });

  test('扫描异常向调用方传播，不能返回切换完成', () async {
    await expectLater(
      finishLocalReauthorization(
        previousFolder: 'old',
        pickedFolder: 'new',
        permission: readWrite,
        scanAndApply: () async => throw StateError('offline'),
      ),
      throwsStateError,
    );
  });

  test('清理失败仍处理迁移，但总体结果不是完成', () async {
    var confirmed = false;
    final result = await applyLocalScanFollowUp<int>(
      remaps: [1],
      cleanupAssociations: () async {
        throw StateError('cleanup failed');
      },
      migrate: (_) async {},
      confirm: (_) async {
        confirmed = true;
      },
      recordFailure: (_, error) async {},
      bookIdOf: (id) => id,
    );
    expect(confirmed, isTrue);
    expect(result.handled, isFalse);
    expect(result.cleanupError, isNotNull);
  });

  test('同一本书前序迁移失败后，后继任务暂停不执行', () async {
    final calls = <String>[];
    final result = await applyLocalScanFollowUp<({int bookId, String id})>(
      remaps: [
        (bookId: 1, id: 'a-b'),
        (bookId: 1, id: 'b-c'),
        (bookId: 2, id: 'x-y'),
      ],
      cleanupAssociations: () async {},
      migrate: (remap) async {
        calls.add('migrate:${remap.id}');
        if (remap.id == 'a-b') throw StateError('first failed');
      },
      confirm: (remap) async {
        calls.add('confirm:${remap.id}');
      },
      recordFailure: (remap, error) async {
        calls.add('persist-failure:${remap.id}');
      },
      bookIdOf: (remap) => remap.bookId,
    );
    expect(calls, [
      'migrate:a-b',
      'persist-failure:a-b',
      'migrate:x-y',
      'confirm:x-y',
    ]);
    expect(result.failedMigrations, 1);
  });

  test('迁移成功但确认失败时走失败记录，且同书后继任务暂停', () async {
    final calls = <String>[];
    final result = await applyLocalScanFollowUp<({int bookId, String id})>(
      remaps: [
        (bookId: 1, id: 'a-b'),
        (bookId: 1, id: 'b-c'),
        (bookId: 2, id: 'x-y'),
      ],
      cleanupAssociations: () async {},
      migrate: (remap) async {
        calls.add('migrate:${remap.id}');
      },
      confirm: (remap) async {
        calls.add('confirm:${remap.id}');
        if (remap.id == 'a-b') throw StateError('confirm failed');
      },
      recordFailure: (remap, error) async {
        calls.add('persist-failure:${remap.id}');
      },
      bookIdOf: (remap) => remap.bookId,
    );
    expect(calls, [
      'migrate:a-b',
      'confirm:a-b',
      'persist-failure:a-b',
      'migrate:x-y',
      'confirm:x-y',
    ]);
    expect(result.failedMigrations, 1);
    expect(result.handled, isTrue);
  });

  test('清理部分完成后续抛异常时，清理错误仍要上报、整体不算完成', () async {
    final confirmed = <int>[];
    final calls = <String>[];
    final result = await applyLocalScanFollowUp<int>(
      remaps: [1],
      cleanupAssociations: () async {
        confirmed.add(1);
        throw StateError('cleanup failed on second id');
      },
      migrate: (_) async {
        calls.add('migrate');
      },
      confirm: (_) async {
        calls.add('confirm');
      },
      recordFailure: (_, error) async {},
      bookIdOf: (id) => id,
    );
    expect(confirmed, [1]);
    expect(calls, ['migrate', 'confirm']);
    expect(result.cleanupError, isNotNull);
    expect(result.handled, isFalse);
  });

  test('迁移失败记录写入失败，不能声称已保存待重试状态', () async {
    final result = await applyLocalScanFollowUp<int>(
      remaps: [1],
      cleanupAssociations: () async {},
      migrate: (_) async => throw StateError('migration'),
      confirm: (_) async => fail('失败任务不能确认'),
      recordFailure: (_, error) async => throw StateError('persistence'),
      bookIdOf: (id) => id,
    );
    expect(result.failedMigrations, 1);
    expect(result.unrecordedFailures, 1);
    expect(result.handled, isFalse);
  });
}
