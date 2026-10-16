import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'app_interactions.dart';
import 'catalog.dart';
import 'offline_cache.dart';
import 'offline_repository.dart';

class OfflineBookStatus extends StatelessWidget {
  const OfflineBookStatus({
    super.key,
    required this.repository,
    required this.novel,
    this.localDirectory = false,
  });
  final OfflineNovelRepository repository;
  final Novel novel;
  final bool localDirectory;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: repository.bookChanges(novel.id),
    builder: (context, _) {
      final job = repository.jobFor(novel.id);
      final saved = repository.cache.book(novel.id);
      final count = saved == null
          ? 0
          : identical(saved.novel.chapters, novel.chapters)
          ? saved.cachedCount
          : novel.chapters
                .where((chapter) => saved.chapterBytes.containsKey(chapter.id))
                .length;
      return Text(
        job?.active == true ||
                job?.phase == DownloadPhase.failed ||
                job?.phase == DownloadPhase.cancelled
            ? job!.label
            : novel.chapters.isEmpty
            ? '暂无章节缓存'
            : '${localDirectory ? '本地目录 · ' : ''}缓存 $count / ${novel.chapters.length} 章',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
          height: 1.5,
        ),
      );
    },
  );
}

enum _BookAction { all, next, retry, cancel, remove }

class OfflineBookMenu extends StatelessWidget {
  const OfflineBookMenu({
    super.key,
    required this.repository,
    required this.novel,
    this.startChapter = 0,
    this.reduceMotion = false,
  });
  final OfflineNovelRepository repository;
  final Novel novel;
  final int startChapter;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) => GlassMenuAnchor(
    child: Builder(
      builder: (anchor) => GlassIconButton(
        icon: CupertinoIcons.cloud_download,
        label: '下载与缓存',
        onPressed: () => _show(anchor),
      ),
    ),
  );

  Future<void> _show(BuildContext context) async {
    final job = repository.jobFor(novel.id);
    final selected = await showGlassMenu<_BookAction>(
      context: context,
      reduceMotion: reduceMotion || MediaQuery.disableAnimationsOf(context),
      builder: (menu) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (job?.active == true)
            GlassMenuItem(
              label: '取消下载',
              onPressed: () => Navigator.pop(menu, _BookAction.cancel),
            )
          else ...[
            GlassMenuItem(
              label: '下载全部章节',
              onPressed: () => Navigator.pop(menu, _BookAction.all),
            ),
            if (novel.chapters.isNotEmpty)
              GlassMenuItem(
                order: 1,
                label: '下载后续 20 章',
                onPressed: () => Navigator.pop(menu, _BookAction.next),
              ),
            if (job?.phase == DownloadPhase.failed ||
                job?.phase == DownloadPhase.cancelled)
              GlassMenuItem(
                order: 2,
                label: '继续下载',
                onPressed: () => Navigator.pop(menu, _BookAction.retry),
              ),
          ],
          if (repository.cache.book(novel.id) != null)
            GlassMenuItem(
              order: 3,
              label: '清除这本缓存',
              onPressed: () => Navigator.pop(menu, _BookAction.remove),
            ),
        ],
      ),
    );
    if (!context.mounted || selected == null) return;
    switch (selected) {
      case _BookAction.all:
        repository.download(novel);
        return;
      case _BookAction.next:
        final start = startChapter.clamp(0, novel.chapters.length - 1);
        repository.download(
          novel,
          chapterIds: novel.chapters
              .skip(start)
              .take(20)
              .map((c) => c.id)
              .toSet(),
        );
        return;
      case _BookAction.retry:
        repository.retry(novel.id);
        return;
      case _BookAction.cancel:
        repository.cancel(novel.id);
        return;
      case _BookAction.remove:
        if (await _confirmClear(
          context,
          '清除这本缓存',
          reduceMotion: reduceMotion,
        )) {
          try {
            await repository.removeCachedBook(novel.id);
          } catch (_) {
            if (context.mounted) _storageFailure(context);
          }
        }
    }
  }
}

Future<bool> _confirmClear(
  BuildContext context,
  String label, {
  bool reduceMotion = false,
}) async =>
    await showGlassMenu<bool>(
      context: context,
      reduceMotion: reduceMotion || MediaQuery.disableAnimationsOf(context),
      builder: (menu) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassMenuItem(
            label: label,
            onPressed: () => Navigator.pop(menu, true),
          ),
          GlassMenuItem(
            order: 1,
            label: '保留缓存',
            onPressed: () => Navigator.pop(menu, false),
          ),
        ],
      ),
    ) ==
    true;

void _storageFailure(BuildContext context) =>
    showNovelFeedback(context, '缓存操作失败，请重试');

class OfflineCachePage extends StatefulWidget {
  const OfflineCachePage({
    super.key,
    required this.repository,
    required this.onOpen,
    this.reduceMotion = false,
  });
  final OfflineNovelRepository repository;
  final void Function(BuildContext context, Novel novel) onOpen;
  final bool reduceMotion;

  @override
  State<OfflineCachePage> createState() => _OfflineCachePageState();
}

class _OfflineCachePageState extends State<OfflineCachePage> {
  late Future<void> _loaded = widget.repository.loadCache();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Atmosphere(
      child: GlassHeaderLayout(
        header: Row(
          children: [
            GlassIconButton(
              icon: CupertinoIcons.back,
              label: '返回',
              onPressed: () => Navigator.pop(context),
            ),
            const Expanded(
              child: ArchiveRouteTitle(
                title: '离线缓存',
                code: 'ARCHIVE / LOCAL STORAGE',
              ),
            ),
            GlassMenuAnchor(
              child: Builder(
                builder: (anchor) => GlassIconButton(
                  icon: CupertinoIcons.trash,
                  label: '清空缓存',
                  onPressed: () => _clear(anchor),
                ),
              ),
            ),
          ],
        ),
        body: FutureBuilder<void>(
          future: _loaded,
          builder: (context, snapshot) => LoadedContentSequence(
            generation: snapshot.connectionState == ConnectionState.done
                ? _loaded
                : null,
            child: AnimatedBuilder(
              animation: widget.repository,
              builder: (context, _) {
                final books = widget.repository.cache.books;
                final known = books.map((b) => b.novel.id).toSet();
                final pending = widget.repository.jobs
                    .where((j) => !known.contains(j.novel.id))
                    .toList();
                final count = books.length + pending.length;
                final loading =
                    snapshot.connectionState != ConnectionState.done &&
                    count == 0;
                return ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    MediaQuery.paddingOf(context).top +
                        FrostedHeader.toolbarHeight +
                        20,
                    24,
                    MediaQuery.paddingOf(context).bottom + 28,
                  ),
                  itemCount: loading ? 4 : count + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return LoadedContentItem(
                        index: 0,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 22),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              sectionHeader(
                                context,
                                '本地存储',
                                formatCacheBytes(widget.repository.cache.bytes),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                '已缓存正文可离线阅读。清理缓存不会移出书架，也不会删除阅读进度。',
                                style: TextStyle(fontSize: 13, height: 1.7),
                              ),
                              if (snapshot.hasError ||
                                  widget.repository.cacheError != null) ...[
                                const SizedBox(height: 12),
                                const Text('缓存读取或写入失败，请释放存储后重试。'),
                                GlassTextButton(
                                  onPressed: () => setState(
                                    () =>
                                        _loaded = widget.repository.loadCache(),
                                  ),
                                  child: const Text('重试'),
                                ),
                              ] else if (!loading && count == 0)
                                const Padding(
                                  padding: EdgeInsets.only(top: 24),
                                  child: Text('暂无离线缓存，在图书详情中下载章节。'),
                                ),
                            ],
                          ),
                        ),
                      );
                    }
                    if (loading) return const BookRowSkeleton(label: '正在读取缓存');
                    final novel = index <= books.length
                        ? books[index - 1].novel
                        : pending[index - books.length - 1].novel;
                    return LoadedContentItem(
                      key: ValueKey('offline-book-${novel.id}'),
                      index: index,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ContentPanel(
                          onTap: novel.chapters.isEmpty
                              ? null
                              : () => widget.onOpen(context, novel),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      novel.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 7),
                                    OfflineBookStatus(
                                      repository: widget.repository,
                                      novel: novel,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      formatCacheBytes(
                                        widget.repository.cache
                                                .book(novel.id)
                                                ?.bytes ??
                                            0,
                                      ),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              OfflineBookMenu(
                                repository: widget.repository,
                                novel: novel,
                                reduceMotion: widget.reduceMotion,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _clear(BuildContext context) async {
    if (!await _confirmClear(
      context,
      '清空全部缓存',
      reduceMotion: widget.reduceMotion,
    )) {
      return;
    }
    try {
      await widget.repository.clearCache();
    } catch (_) {
      if (context.mounted) _storageFailure(context);
    }
  }
}
