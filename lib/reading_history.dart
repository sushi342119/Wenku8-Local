import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'app_interactions.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'offline_repository.dart';

class ReadingHistoryPage extends StatefulWidget {
  const ReadingHistoryPage({
    super.key,
    required this.state,
    required this.repository,
    required this.onOpen,
  });
  final LibraryState state;
  final NovelRepository repository;
  final void Function(BuildContext context, int id, Novel? novel) onOpen;

  @override
  State<ReadingHistoryPage> createState() => _ReadingHistoryPageState();
}

class _ReadingHistoryPageState extends State<ReadingHistoryPage> {
  final Map<int, Future<Novel?>> _requests = {};

  Novel? _known(int id) {
    if (widget.repository case final OfflineNovelRepository offline) {
      final book = offline.cache.book(id)?.novel;
      if (book != null) return book;
    }
    return widget.state.cachedNovel(id);
  }

  Future<Novel?> _resolve(int id) async {
    Novel? book;
    if (widget.repository case final OfflineNovelRepository offline) {
      book = await offline.cachedBook(id);
    }
    book ??= await widget.repository.find(id);
    if (book != null) await widget.state.rememberNovel(book);
    return book;
  }

  Future<Novel?> _request(int id) async {
    try {
      return await _resolve(id);
    } catch (_) {
      // A failed lookup remains an explicit, independently retryable ID row.
      return null;
    }
  }

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
                title: '阅读历史',
                code: 'ARCHIVE / READING LOG',
              ),
            ),
            GlassMenuAnchor(
              child: Builder(
                builder: (anchor) => GlassIconButton(
                  icon: CupertinoIcons.trash,
                  label: '清空阅读历史',
                  onPressed: () => _clear(anchor),
                ),
              ),
            ),
          ],
        ),
        body: AnimatedBuilder(
          animation: widget.state.historyChanges,
          builder: (context, _) {
            final ids = widget.state.readingHistoryIds;
            return ListView.builder(
              key: const PageStorageKey('reading-history'),
              padding: EdgeInsets.fromLTRB(
                24,
                MediaQuery.paddingOf(context).top +
                    FrostedHeader.toolbarHeight +
                    20,
                24,
                MediaQuery.paddingOf(context).bottom + 28,
              ),
              itemCount: ids.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        sectionHeader(context, '最近阅读', '${ids.length} 本书'),
                        const SizedBox(height: 12),
                        const Text(
                          '未收藏的作品也会记录。移除历史只隐藏记录，书架、续读进度和离线缓存保留。',
                          style: TextStyle(fontSize: 13, height: 1.7),
                        ),
                        if (ids.isEmpty) ...[
                          const SizedBox(height: 30),
                          const Text('暂无阅读历史'),
                        ],
                      ],
                    ),
                  );
                }
                final id = ids[index - 1];
                final known = _known(id);
                return FutureBuilder<Novel?>(
                  key: ValueKey('history-resolve-$id'),
                  initialData: known,
                  future: known == null
                      ? _requests.putIfAbsent(id, () => _request(id))
                      : _requests[id],
                  builder: (context, snapshot) => LoadedContentSequence(
                    generation: (known ?? snapshot.data)?.id,
                    child:
                        known == null &&
                            snapshot.data == null &&
                            snapshot.connectionState != ConnectionState.done
                        ? const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: SizedBox(
                              height: 108,
                              child: LoadingSkeleton(
                                layout: SkeletonLayout.history,
                                label: '正在载入阅读历史',
                              ),
                            ),
                          )
                        : LoadedContentItem(
                            index: index - 1,
                            child: _row(context, id, known ?? snapshot.data),
                          ),
                  ),
                );
              },
            );
          },
        ),
      ),
    ),
  );

  Widget _row(BuildContext context, int id, Novel? novel) {
    final title = novel?.title ?? '书籍 $id';
    final position = widget.state.positionFor(id);
    final chapter = novel == null
        ? widget.state.chapterFor(id)
        : widget.state.chapterForNovel(novel);
    return Padding(
      key: ValueKey('history-book-$id'),
      padding: const EdgeInsets.only(bottom: 12),
      child: ContentPanel(
        onTap: () => widget.onOpen(context, id, novel),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '第 ${chapter + 1} 章${position == null ? '' : ' · 本章 ${(position.fraction * 100).round()}%'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _readingTime(position?.updatedAt ?? 0),
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (novel == null) ...[
                    const SizedBox(height: 8),
                    GlassTextButton(
                      onPressed: () => setState(() {
                        _requests[id] = _request(id);
                      }),
                      child: const Text('重试载入书名'),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            GlassMenuAnchor(
              child: Builder(
                builder: (anchor) => GlassIconButton(
                  icon: CupertinoIcons.ellipsis,
                  label: '$title阅读记录操作',
                  onPressed: () => _remove(anchor, id),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context, int id) async {
    final remove = await showGlassMenu<bool>(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      builder: (menu) => GlassMenuItem(
        label: '移除这条历史',
        onPressed: () => Navigator.pop(menu, true),
      ),
    );
    if (!mounted || remove != true) return;
    try {
      await widget.state.hideReadingHistory(id);
      if (!mounted) return;
      showNovelFeedback(
        this.context,
        '历史已移除，续读进度保留',
        actionLabel: '撤销',
        action: () => widget.state.restoreReadingHistory(id),
        actionFailure: '阅读历史保存失败，请重试',
      );
    } catch (_) {
      if (mounted) _failed();
    }
  }

  Future<void> _clear(BuildContext context) async {
    final clear = await showGlassMenu<bool>(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      builder: (menu) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassMenuItem(
            label: '清空历史，保留进度',
            onPressed: () => Navigator.pop(menu, true),
          ),
          GlassMenuItem(
            order: 1,
            label: '保留阅读历史',
            onPressed: () => Navigator.pop(menu, false),
          ),
        ],
      ),
    );
    if (!mounted || clear != true) return;
    try {
      await widget.state.clearReadingHistory();
    } catch (_) {
      if (mounted) _failed();
    }
  }

  void _failed() => showNovelFeedback(context, '阅读历史保存失败，请重试');
}

String _readingTime(int timestamp) {
  if (timestamp <= 0) return '旧版阅读记录';
  try {
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  } on ArgumentError {
    return '已保存阅读进度';
  }
}
