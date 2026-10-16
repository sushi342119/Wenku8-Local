import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'catalog.dart';
import 'offline_cache.dart';
import 'reader_content.dart'
    show readerHasMissingIllustrations, readerIllustrationUrl;
import 'ui_notifiers.dart';

enum DownloadPhase {
  queued,
  preparing,
  downloading,
  completed,
  cancelled,
  failed,
}

class ChapterDownload {
  ChapterDownload(this.novel, this.chapterIds, this.epoch);
  Novel novel;
  final Set<int>? chapterIds;
  final CacheEpoch epoch;
  DownloadPhase phase = DownloadPhase.queued;
  int completed = 0;
  int total = 0;
  String? failedChapter;
  Object? error;

  bool get active => switch (phase) {
    DownloadPhase.queued ||
    DownloadPhase.preparing ||
    DownloadPhase.downloading => true,
    _ => false,
  };
  String get label => switch (phase) {
    DownloadPhase.queued => '等待下载',
    DownloadPhase.preparing => '正在获取目录',
    DownloadPhase.downloading => '已缓存 $completed / $total 章',
    DownloadPhase.completed => '下载完成 · $completed 章',
    DownloadPhase.cancelled => '已取消 · 保留已缓存章节',
    DownloadPhase.failed =>
      failedChapter == null ? '获取目录失败，可重试' : '「$failedChapter」下载失败，可重试',
  };
}

class _ChapterRequest {
  _ChapterRequest(this.key);
  final (int, int, CacheEpoch) key;
  int readers = 0;
  Future<String>? response;
}

/// Adds persistent offline reading without changing the remote request contract.
/// Download notifications are independent of appearance/reader state updates.
class OfflineNovelRepository extends FrameChangeNotifier
    implements NovelRepository {
  OfflineNovelRepository({required this.remote, required this.cache}) {
    cache.addListener(_cacheChanged);
  }

  final NovelRepository remote;
  final OfflineCacheStore cache;
  final Map<int, Novel> _known = {};
  final Set<int> _offlineDirectories = {};
  final Map<(int, int, CacheEpoch), _ChapterRequest> _requests = {};
  final Set<(int, int, CacheEpoch)> _illustrationRepairs = {};
  final Map<int, ChapterDownload> _jobs = {};
  final Queue<ChapterDownload> _queue = Queue();
  final Map<int, FrameChangeNotifier> _bookChanges = {};
  final Map<int, Listenable> _bookObservers = {};
  bool _draining = false;
  bool _disposed = false;
  Object? cacheError;

  ChapterDownload? jobFor(int id) => _jobs[id];
  List<ChapterDownload> get jobs => List.unmodifiable(_jobs.values);
  bool isDirectoryOffline(int id) => _offlineDirectories.contains(id);
  Listenable bookChanges(int id) => _bookObservers.putIfAbsent(
    id,
    () => Listenable.merge([
      _bookChanges.putIfAbsent(id, FrameChangeNotifier.new),
      cache.bookChanges(id),
    ]),
  );

  Future<void> loadCache() async {
    try {
      await cache.load();
      cacheError = null;
      _changed();
    } catch (error) {
      cacheError = error;
      _changed();
      rethrow;
    }
  }

  void _cacheChanged() {
    if (!_disposed) notifyListeners();
  }

  void _changed([int? id]) {
    if (_disposed) return;
    if (id == null) {
      for (final observer in _bookChanges.values) {
        observer.notifyListeners();
      }
    } else {
      _bookChanges[id]?.notifyListeners();
    }
    notifyListeners();
  }

  @override
  Future<List<Novel>> list() => remote.list();
  @override
  Future<List<Novel>> search(String query) => remote.search(query);
  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) => remote.browse(sort: sort, page: page, refresh: refresh);
  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) => remote.searchPage(query, page: page, refresh: refresh);

  Future<Novel?> cachedBook(int id) async {
    final book = cache.book(id)?.novel ?? await cache.readBook(id);
    if (book != null) _known.putIfAbsent(id, () => book);
    return book;
  }

  /// Explicitly refresh old bodies that predate illustration support. A failed
  /// request keeps the previous offline body; no cache purge is necessary.
  Future<String> refreshChapterContent(int id, NovelChapter chapter) async {
    final epoch = cache.epochFor(id);
    final request = _retainRequest(id, chapter.id, epoch);
    try {
      final previous = await cache.readChapter(id, chapter.id);
      final text = await _fetch(id, chapter, request);
      if (previous != null &&
          readerHasMissingIllustrations(previous) &&
          !_hasIllustration(text)) {
        throw const FormatException('暂未获取到本章插图地址，请稍后重试');
      }
      await _saveBody(id, chapter.id, text, epoch);
      return text;
    } finally {
      _releaseRequest(request);
    }
  }

  static bool _hasIllustration(String text) => text
      .split('\n\n')
      .any((paragraph) => readerIllustrationUrl(paragraph) != null);

  Future<void> _saveBody(int id, int cid, String text, CacheEpoch epoch) async {
    if (_disposed || !cache.isCurrent(id, epoch)) return;
    try {
      await cache.saveChapter(id, cid, text, epoch: epoch);
      cacheError = null;
    } catch (error) {
      cacheError = error;
      _changed(id);
    }
  }

  /// Called after the reader has displayed its cached paragraphs, so an offline
  /// image repair never holds readable text behind a network timeout.
  Future<String?> repairChapterIllustrations(
    int id,
    NovelChapter chapter,
  ) async {
    if (chapter.id <= 0) return null;
    final epoch = cache.epochFor(id);
    final request = _retainRequest(id, chapter.id, epoch);
    try {
      final saved = await cache.readChapter(id, chapter.id);
      if (saved == null || !readerHasMissingIllustrations(saved)) return null;
      if (!_illustrationRepairs.add(request.key) && request.response == null) {
        return null;
      }
      final repaired = await _fetch(id, chapter, request);
      if (!_hasIllustration(repaired)) return null;
      await _saveBody(id, chapter.id, repaired, epoch);
      return repaired;
    } catch (_) {
      // Continue reading the existing offline body. A user-initiated refresh
      // bypasses the attempted-repair set when connectivity returns.
      return null;
    } finally {
      _releaseRequest(request);
    }
  }

  @override
  Future<Novel?> find(int id) async {
    try {
      final book = await remote.find(id);
      if (book != null) {
        _known[id] = book;
        return book;
      }
    } catch (_) {
      final saved = await cachedBook(id);
      if (saved != null) return saved;
      rethrow;
    }
    return cachedBook(id);
  }

  @override
  Future<Novel> detail(Novel novel) async {
    try {
      final loaded = await remote.detail(novel);
      _known[novel.id] = loaded;
      return loaded;
    } catch (_) {
      final saved = await cachedBook(novel.id);
      if (saved != null) return saved;
      rethrow;
    }
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    final epoch = cache.epochFor(id);
    try {
      final chapters = await remote.chapters(id);
      _offlineDirectories.remove(id);
      final meta = _known[id];
      if (meta != null) {
        final full = meta.withChapters(chapters);
        _known[id] = full;
        await _remember(full, epoch);
      }
      return chapters;
    } catch (_) {
      final saved = await cachedBook(id);
      if (saved != null && saved.chapters.isNotEmpty) {
        _offlineDirectories.add(id);
        return saved.chapters;
      }
      rethrow;
    }
  }

  Future<void> rememberDirectory(Novel novel) async {
    _known[novel.id] = novel;
    final saved = cache.book(novel.id)?.novel;
    if (saved != null &&
        saved.title == novel.title &&
        saved.author == novel.author &&
        saved.summary == novel.summary &&
        saved.coverUrl == novel.coverUrl &&
        saved.isComplete == novel.isComplete &&
        saved.lastUpdate == novel.lastUpdate &&
        _sameDirectory(saved.chapters, novel.chapters)) {
      return;
    }
    await _remember(novel, cache.epochFor(novel.id));
  }

  static bool _sameDirectory(List<NovelChapter> a, List<NovelChapter> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index].id != b[index].id || a[index].title != b[index].title) {
        return false;
      }
    }
    return true;
  }

  Future<void> _remember(Novel novel, CacheEpoch epoch) async {
    if (novel.chapters.isEmpty || novel.chapters.any((c) => c.id <= 0)) return;
    try {
      await cache.saveBook(novel, epoch: epoch);
      cacheError = null;
    } catch (error) {
      // A disk failure must not turn a successful online read into an error.
      cacheError = error;
      _changed(novel.id);
    }
  }

  _ChapterRequest _retainRequest(int id, int cid, CacheEpoch epoch) {
    final key = (id, cid, epoch);
    final request = _requests.putIfAbsent(key, () => _ChapterRequest(key));
    request.readers++;
    return request;
  }

  void _releaseRequest(_ChapterRequest request) {
    request.readers--;
    if (request.readers == 0 && identical(_requests[request.key], request)) {
      _requests.remove(request.key);
    }
  }

  Future<String> _fetch(
    int id,
    NovelChapter chapter,
    _ChapterRequest request,
  ) => request.response ??= () async {
    final text = await remote.chapterContent(id, chapter);
    if (text.trim().isEmpty) throw const FormatException('章节正文为空');
    return text;
  }();

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    // Inline/demo chapters have no remote stable ID and stay source-owned.
    if (chapter.id <= 0) return remote.chapterContent(novelId, chapter);
    final epoch = cache.epochFor(novelId);
    // Retain before the asynchronous disk lookup, through its eventual commit.
    // A concurrent cache miss must not re-fetch a just-completed response.
    final request = _retainRequest(novelId, chapter.id, epoch);
    try {
      final saved = await cache.readChapter(novelId, chapter.id);
      if (saved != null) return saved;
      final text = await _fetch(novelId, chapter, request);
      await _saveBody(novelId, chapter.id, text, epoch);
      return text;
    } finally {
      _releaseRequest(request);
    }
  }

  void download(Novel novel, {Set<int>? chapterIds}) {
    if (_disposed || jobFor(novel.id)?.active == true) return;
    final job = ChapterDownload(
      novel,
      chapterIds == null ? null : Set.unmodifiable(chapterIds),
      cache.epochFor(novel.id),
    );
    _jobs[novel.id] = job;
    _queue.add(job);
    _changed(novel.id);
    if (!_draining) unawaited(_drain());
  }

  void cancel(int id) {
    final job = _jobs[id];
    if (job?.active != true) return;
    job!.phase = DownloadPhase.cancelled;
    _changed(id);
  }

  void retry(int id) {
    final previous = _jobs[id];
    if (previous == null || previous.active) return;
    download(previous.novel, chapterIds: previous.chapterIds);
  }

  bool _current(ChapterDownload job) {
    if (_disposed || !job.active) return false;
    if (!cache.isCurrent(job.novel.id, job.epoch)) {
      job.phase = DownloadPhase.cancelled;
      _changed(job.novel.id);
      return false;
    }
    return true;
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final job = _queue.removeFirst();
        if (!_current(job)) continue;
        await _run(job);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _run(ChapterDownload job) async {
    try {
      job.phase = DownloadPhase.preparing;
      _changed(job.novel.id);
      // Refresh through the same legacy calls before an explicit book download.
      final meta = await remote.detail(job.novel);
      if (!_current(job)) return;
      final chapters = await remote.chapters(meta.id);
      if (!_current(job)) return;
      final full = meta.withChapters(chapters);
      if (chapters.isEmpty) throw const FormatException('目录为空');
      final stored = await cache.saveBook(full, epoch: job.epoch);
      if (!_current(job)) return;
      if (!stored) throw StateError('目录缓存未完成');
      _known[meta.id] = full;
      job.novel = full;
      final selected = chapters
          .where((c) => job.chapterIds?.contains(c.id) ?? true)
          .toList();
      if (selected.isEmpty) throw const FormatException('选择的章节已不在目录中');
      job.total = selected.length;
      job.phase = DownloadPhase.downloading;
      _changed(job.novel.id);
      for (final chapter in selected) {
        if (!_current(job)) return;
        job.failedChapter = chapter.title;
        final request = _retainRequest(meta.id, chapter.id, job.epoch);
        try {
          final saved = await cache.readChapter(meta.id, chapter.id);
          if (!_current(job)) return;
          if (saved == null) {
            final text = await _fetch(meta.id, chapter, request);
            // Cancelling stops further calls and suppresses a late body commit.
            if (!_current(job)) return;
            final stored = await cache.saveChapter(
              meta.id,
              chapter.id,
              text,
              epoch: job.epoch,
            );
            if (!_current(job)) return;
            if (!stored) throw StateError('章节已不在本地目录中');
          }
          if (!_current(job)) return;
          job.completed++;
          _changed(job.novel.id);
        } finally {
          _releaseRequest(request);
        }
      }
      job.failedChapter = null;
      job.phase = DownloadPhase.completed;
      cacheError = null;
      _changed(job.novel.id);
    } catch (error) {
      if (!_current(job)) return;
      // Stop at the first failure; retry skips all previously committed bodies.
      job.error = error;
      job.phase = DownloadPhase.failed;
      _changed(job.novel.id);
    }
  }

  Future<void> removeCachedBook(int id) async {
    final previousJob = _jobs[id];
    cancel(id);
    await cache.removeBook(id);
    // A newer download may already own the new cache generation. Deletion
    // completion must not remove that later user action's progress entry.
    if (identical(_jobs[id], previousJob)) _jobs.remove(id);
    _offlineDirectories.remove(id);
    _illustrationRepairs.removeWhere((key) => key.$1 == id);
    cacheError = null;
    _changed(id);
  }

  Future<void> clearCache() async {
    for (final job in _jobs.values) {
      if (job.active) job.phase = DownloadPhase.cancelled;
    }
    _changed();
    await cache.clear();
    _jobs.removeWhere((_, job) => !cache.isCurrent(job.novel.id, job.epoch));
    _offlineDirectories.clear();
    _illustrationRepairs.clear();
    cacheError = null;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final job in _jobs.values) {
      if (job.active) job.phase = DownloadPhase.cancelled;
    }
    cache.removeListener(_cacheChanged);
    for (final observer in _bookChanges.values) {
      observer.dispose();
    }
    super.dispose();
  }
}
