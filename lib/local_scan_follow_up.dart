import 'package:flutter/foundation.dart';

import 'local_platform.dart';

/// 扫描后处理结果：关联清理与章节迁移任务的统一记录。
class LocalScanFollowUp {
  const LocalScanFollowUp({
    this.cleanupError,
    this.failedMigrations = 0,
    this.unrecordedFailures = 0,
  });

  final Object? cleanupError;
  final int failedMigrations;
  final int unrecordedFailures;

  // 已成功记录的迁移失败属于“已处理、待重试”。
  bool get handled => cleanupError == null && unrecordedFailures == 0;
}

typedef LocalMigrationCommit<M> =
    Future<void> Function(
      List<M> confirmed,
      List<({M remap, Object error})> failures,
    );

class LocalScanFollowUpException implements Exception {
  const LocalScanFollowUpException(this.result);

  final LocalScanFollowUp result;

  @override
  String toString() =>
      '扫描后处理未完成：关联清理错误=${result.cleanupError}，'
      '失败状态未保存=${result.unrecordedFailures}';
}

/// 统一的扫描后处理入口：先做关联清理，再逐本迁移章节进度。
/// 关联清理失败不阻止独立的章节迁移任务被处理；单本迁移失败
/// 不中断其他书，失败记录写入失败时计入 unrecordedFailures。
Future<LocalScanFollowUp> applyLocalScanFollowUp<M>({
  required Iterable<M> remaps,
  required Future<void> Function() cleanupAssociations,
  required Future<void> Function(M) migrate,
  required Future<void> Function(M) confirm,
  required Future<void> Function(M, Object) recordFailure,
  // 提供时在所有迁移完成后一次提交确认和失败状态。
  LocalMigrationCommit<M>? commitMigrationOutcomes,
  // 按小胖补丁改为必传：不传时同书暂停静默失效，编译就能查出遗漏。
  required int Function(M) bookIdOf,
}) async {
  Object? cleanupError;
  var failedMigrations = 0;
  var unrecordedFailures = 0;
  // 同一本书的前序迁移失败后，暂停该书的后继任务。
  final failedBooks = <int>{};
  final confirmed = <M>[];
  final failures = <({M remap, Object error})>[];
  try {
    await cleanupAssociations();
  } catch (error, stackTrace) {
    cleanupError = error;
    debugPrint('association cleanup failed: $error\n$stackTrace');
  }
  for (final remap in remaps) {
    final bookId = bookIdOf(remap);
    if (failedBooks.contains(bookId)) continue;
    try {
      await migrate(remap);
      if (commitMigrationOutcomes == null) {
        await confirm(remap);
      } else {
        confirmed.add(remap);
      }
    } catch (error, stackTrace) {
      failedBooks.add(bookId);
      failedMigrations++;
      debugPrint('chapter migration failed: $error\n$stackTrace');
      if (commitMigrationOutcomes == null) {
        try {
          await recordFailure(remap, error);
        } catch (recordError, recordStackTrace) {
          unrecordedFailures++;
          debugPrint(
            'failed to persist chapter migration failure: '
            '$recordError\n$recordStackTrace',
          );
        }
      } else {
        failures.add((remap: remap, error: error));
      }
    }
  }
  if (commitMigrationOutcomes != null &&
      (confirmed.isNotEmpty || failures.isNotEmpty)) {
    try {
      await commitMigrationOutcomes(confirmed, failures);
    } catch (error, stackTrace) {
      unrecordedFailures++;
      debugPrint(
        'failed to persist chapter migration outcomes: $error\n$stackTrace',
      );
    }
  }
  return LocalScanFollowUp(
    cleanupError: cleanupError,
    failedMigrations: failedMigrations,
    unrecordedFailures: unrecordedFailures,
  );
}

class LocalReauthorizationResult {
  const LocalReauthorizationResult({
    required this.folderChanged,
    required this.permission,
    required this.followUp,
  });

  final bool folderChanged;
  final LocalTreePermission permission;
  final LocalScanFollowUp followUp;

  bool get canRetryDelete => !folderChanged && permission.persistedWrite;
}

Future<LocalReauthorizationResult> finishLocalReauthorization({
  required String? previousFolder,
  required String pickedFolder,
  required LocalTreePermission permission,
  required Future<LocalScanFollowUp> Function() scanAndApply,
}) async {
  if (!permission.persistedRead) {
    throw StateError('已选中目录，但没有取得持久化读取权限');
  }
  // 原目录、不同目录都走同一个入口。
  final followUp = await scanAndApply();
  if (!followUp.handled) {
    throw LocalScanFollowUpException(followUp);
  }
  return LocalReauthorizationResult(
    folderChanged: pickedFolder != previousFolder,
    permission: permission,
    followUp: followUp,
  );
}
