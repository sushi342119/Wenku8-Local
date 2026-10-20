/// 书源试验版（source-trial 分支）：后台下载管理器。
///
/// 持有所有下载任务，任务生命周期独立于详情页：
/// 用户点下载后即使离开详情页去找其他书，下载仍在后台继续。
/// 下载中遇到验证时任务暂停（不丢进度），用户完成验证后自动续传。
library;

import 'package:flutter/foundation.dart';

import '../local_library.dart';
import 'source_client.dart';
import 'source_download.dart';
import 'source_models.dart';

class SourceDownloadManager extends ChangeNotifier {
  final Map<String, SourceDownloadTask> _tasks = {};

  /// 是否有任务因验证暂停（UI 层据此显示验证提示）。
  bool _needsVerify = false;
  bool get needsVerify => _needsVerify;

  /// 任务键：书籍 URL（同站内唯一）。
  String _key(SourceBook book) => book.url;

  SourceDownloadTask? taskFor(SourceBook book) => _tasks[_key(book)];

  List<SourceDownloadTask> get tasks => List.unmodifiable(_tasks.values);

  bool get hasActiveTasks => _tasks.values.any(
    (t) =>
        t.status == SourceDownloadStatus.downloading ||
        t.status == SourceDownloadStatus.pausedNeedVerify,
  );

  /// 开始一本书的下载（新建或继续已有任务）。返回任务。
  ///
  /// [onSaved] 下载完成并入库后回调（参数为导入的本地书）。
  /// [onError] 入库或下载终态失败时回调（错误信息）。
  SourceDownloadTask startDownload({
    required SourceBookDetail detail,
    required SourceClient client,
    required ChapterFetcher fetcher,
    required LocalLibraryStore local,
    required void Function(LocalBook book) onSaved,
    required void Function(String message) onError,
  }) {
    final key = _key(detail.book);
    var task = _tasks[key];
    if (task == null) {
      task = SourceDownloadTask(
        detail: detail,
        client: client,
        fetcher: fetcher,
        local: local,
      );
      _tasks[key] = task;
      task.addListener(_onTaskChanged);
    }
    _run(task, onSaved, onError);
    notifyListeners();
    return task;
  }

  Future<void> _run(
    SourceDownloadTask task,
    void Function(LocalBook book) onSaved,
    void Function(String message) onError,
  ) async {
    try {
      await task.start((done, total, current) {});
      // start 正常返回后：completed → 入库；failed → 报错。
      if (task.status == SourceDownloadStatus.completed) {
        try {
          final book = await task.saveToLibrary();
          onSaved(book);
        } catch (e) {
          onError('入库失败：$e');
        }
      } else if (task.status == SourceDownloadStatus.failed) {
        onError(task.error ?? '下载失败，可重试失败章节');
      }
      notifyListeners();
    } on SourceNeedVerify {
      // 任务已置 pausedNeedVerify；标记需要验证，等待 UI 触发续传。
      _needsVerify = true;
      notifyListeners();
    }
  }

  /// 验证完成后调用：续传所有暂停的任务。
  Future<void> resumeAfterVerify({
    required void Function(SourceDownloadTask task, LocalBook book) onSaved,
    required void Function(SourceDownloadTask task, String message) onError,
  }) async {
    _needsVerify = false;
    notifyListeners();
    final paused = _tasks.values
        .where((t) => t.status == SourceDownloadStatus.pausedNeedVerify)
        .toList();
    for (final task in paused) {
      await _run(
        task,
        (book) => onSaved(task, book),
        (msg) => onError(task, msg),
      );
    }
  }

  void cancelTask(SourceBook book) {
    taskFor(book)?.cancel();
    notifyListeners();
  }

  void removeTask(SourceBook book) {
    final task = _tasks.remove(_key(book));
    task?.removeListener(_onTaskChanged);
    task?.dispose();
    notifyListeners();
  }

  void _onTaskChanged() => notifyListeners();

  @override
  void dispose() {
    for (final task in _tasks.values) {
      task.removeListener(_onTaskChanged);
      task.dispose();
    }
    _tasks.clear();
    super.dispose();
  }
}
