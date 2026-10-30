import 'dart:convert';

import 'recovery_archive.dart';

/// 仅移出书库的移除状态待恢复：提交后中断时恢复继续完成；
/// 提交前回滚尚未完成时也抛此异常，保留待办供下次继续回滚，
/// 并非只表示提交后继续删除。
class RecordRemovalPending implements Exception {
  const RecordRemovalPending(this.bookId, this.cause);

  final int bookId;
  final Object cause;

  @override
  String toString() => '书籍 $bookId 的移除状态待恢复：$cause';
}

class _RemovalIntent {
  const _RemovalIntent({
    required this.bookId,
    required this.ignoreKey,
    required this.wasIgnored,
    required this.committed,
  });

  final int bookId;
  final String? ignoreKey;
  final bool wasIgnored;
  final bool committed;

  _RemovalIntent withCommitted(bool value) => _RemovalIntent(
        bookId: bookId,
        ignoreKey: ignoreKey,
        wasIgnored: wasIgnored,
        committed: value,
      );

  String encode() => jsonEncode({
        'bookId': bookId,
        'ignoreKey': ignoreKey,
        'wasIgnored': wasIgnored,
        'committed': committed,
      });

  static _RemovalIntent decode(Object raw) {
    if (raw is! String) throw const FormatException('移除待办类型错误');
    final value = jsonDecode(raw);
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('移除待办格式错误');
    }
    final map = Map<String, dynamic>.from(value);
    final bookId = map['bookId'];
    final ignoreKey = map['ignoreKey'];
    final wasIgnored = map['wasIgnored'];
    final committed = map['committed'];
    if (bookId is! int || bookId <= 0 ||
        (ignoreKey != null && ignoreKey is! String) ||
        wasIgnored is! bool ||
        committed is! bool) {
      throw const FormatException('移除待办字段错误');
    }
    return _RemovalIntent(
      bookId: bookId,
      ignoreKey: ignoreKey as String?,
      wasIgnored: wasIgnored,
      committed: committed,
    );
  }
}

/// 持久化仅移出待办。必须在 LocalLibrary 现有的 _synchronized 内调用。
///
/// 提交边界：committed == false 时只允许修改忽略名单，失败或重启时
/// 恢复该键原有状态，书籍、标签和内部副本都没动；committed == true
/// 后，之后的错误返回“移除待完成”，保留待办，恢复时继续完成。
/// 不再声称“任何失败都留在库中”：跨多个偏好项和文件删除，无法在
/// 进程中断时兑现这种无条件承诺。
class RecordRemovalJournal {
  RecordRemovalJournal({
    required this.readIntent,
    required this.writeIntent,
    Future<void> Function(Object)? archiveIntent,
    required this.readIgnored,
    required this.writeIgnored,
    required this.finishRemoval,
  }) : archiveIntent = archiveIntent ?? ((_) async {});

  final Object? Function() readIntent;
  final Future<void> Function(String?) writeIntent;
  final Future<void> Function(Object) archiveIntent;
  final Set<String> Function() readIgnored;
  final Future<void> Function(Set<String>) writeIgnored;

  /// 必须幂等，并且必须保存最终索引，即使内存里已经找不到 bookId。
  final Future<void> Function(int bookId) finishRemoval;

  Future<void> recover() async {
    final raw = readIntent();
    if (raw == null) return;
    late _RemovalIntent intent;
    try {
      intent = _RemovalIntent.decode(raw);
    } catch (_) {
      try {
        await archiveIntent(raw);
        await writeIntent(null);
      } catch (error) {
        recordRecoveryFailure('record_removal_archive', error);
      }
      return;
    }
    if (!intent.committed) {
      try {
        await _rollbackPrepared(intent);
      } catch (error) {
        throw RecordRemovalPending(intent.bookId, error);
      }
      return;
    }
    await _finishCommitted(intent);
  }

  Future<void> remove({
    required int bookId,
    required String? ignoreKey,
  }) async {
    await recover();
    if (readIntent() != null) {
      throw StateError('旧移除记录尚未归档，请恢复存储后重试');
    }
    final ignoredBefore = Set<String>.of(readIgnored());
    final prepared = _RemovalIntent(
      bookId: bookId,
      ignoreKey: ignoreKey,
      wasIgnored: ignoreKey != null && ignoredBefore.contains(ignoreKey),
      committed: false,
    );
    // 此前不修改任何书籍数据或忽略名单。
    await writeIntent(prepared.encode());
    try {
      if (ignoreKey != null) {
        final ignored = Set<String>.of(ignoredBefore)..add(ignoreKey);
        await writeIgnored(ignored);
      }
      // 这是提交边界。
      await writeIntent(prepared.withCommitted(true).encode());
    } catch (error) {
      try {
        // 提交写入可能已经改变了 prefs 的缓存。
        // 先重新持久化“回滚”方向，再恢复忽略名单。
        await writeIntent(prepared.encode());
        await _rollbackPrepared(prepared);
      } catch (rollbackError) {
        // 不谎称回滚成功；保留可恢复状态。
        throw RecordRemovalPending(bookId, rollbackError);
      }
      rethrow;
    }
    await _finishCommitted(prepared.withCommitted(true));
  }

  Future<void> _rollbackPrepared(_RemovalIntent intent) async {
    final key = intent.ignoreKey;
    if (key != null) {
      final ignored = Set<String>.of(readIgnored());
      if (intent.wasIgnored) {
        ignored.add(key);
      } else {
        ignored.remove(key);
      }
      await writeIgnored(ignored);
    }
    // 恢复成功后才清除待办。
    await writeIntent(null);
  }

  Future<void> _finishCommitted(_RemovalIntent intent) async {
    try {
      final key = intent.ignoreKey;
      if (key != null) {
        final ignored = Set<String>.of(readIgnored());
        if (ignored.add(key)) {
          await writeIgnored(ignored);
        }
      }
      await finishRemoval(intent.bookId);
      await writeIntent(null);
    } catch (error) {
      throw RecordRemovalPending(intent.bookId, error);
    }
  }
}
