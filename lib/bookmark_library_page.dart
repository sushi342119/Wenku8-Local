import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'app_search_field.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'library_reflow.dart';
import 'local_library.dart';
import 'offline_repository.dart';
import 'pages.dart' show ReaderPage;
import 'quote_card.dart';
import 'reading_report_fonts.dart';
import 'bookmark_categories.dart';
import 'reader_annotation_editor.dart';
import 'reader_annotation_source.dart';
import 'reader_bookmark_excerpt.dart';
import 'setting_menu.dart';

/// A merged volume keeps its original recovery records. Show the equivalent
/// bookmark in the active series once, without deleting those recovery copies.
List<({int novelId, ReaderBookmark bookmark})> libraryBookmarks(
  LibraryState state, {
  LocalLibraryStore? books,
}) => state.bookmarkEntries;

class BookmarkLibraryPage extends StatefulWidget {
  const BookmarkLibraryPage({
    super.key,
    required this.state,
    required this.repository,
  });
  final LibraryState state;
  final NovelRepository repository;
  @override
  State<BookmarkLibraryPage> createState() => _BookmarkLibraryPageState();
}

typedef _BookmarkEntry = ({int novelId, ReaderBookmark bookmark});

class _BookmarkMarkRow {
  const _BookmarkMarkRow(this.entry, this.order);
  final _BookmarkEntry entry;
  final int order;
}

class _BookmarkLibraryPageState extends State<BookmarkLibraryPage>
    with TickerProviderStateMixin {
  String _query = '';
  String _category = '_book';
  final _search = TextEditingController();
  final _expandedBooks = <int>{};
  bool _searchOpen = false;
  String? _opening;
  final _bookClocks = <int, AnimationController>{};
  final _reflow = LibraryReflowController();
  bool _settlingMotion = false;
  late final _reorder =
      AnimationController(
        vsync: this,
        duration: NovelMotion.enter,
        value: 1,
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed && _reflow.active && mounted) {
          setState(_reflow.finish);
        }
      });

  bool get _reduced =>
      widget.state.reduceMotion || MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    widget.state.appearanceChanges.addListener(_appearanceChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduced) _settleMotion();
  }

  @override
  void didUpdateWidget(BookmarkLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.appearanceChanges.removeListener(_appearanceChanged);
      widget.state.appearanceChanges.addListener(_appearanceChanged);
    }
  }

  void _appearanceChanged() {
    if (!mounted) return;
    if (_reduced) _settleMotion();
    setState(() {});
  }

  void _settleMotion() {
    _settlingMotion = true;
    _reflow.finish();
    _reorder.stop();
    for (final entry in _bookClocks.entries) {
      entry.value.value = _expandedBooks.contains(entry.key) ? 1 : 0;
    }
    _settlingMotion = false;
  }

  AnimationController _clockFor(int id) => _bookClocks.putIfAbsent(id, () {
    final clock = AnimationController(
      vsync: this,
      duration: NovelMotion.enter,
      reverseDuration: NovelMotion.exit,
    );
    clock.addStatusListener((status) {
      if (status == AnimationStatus.dismissed &&
          !_settlingMotion &&
          !_expandedBooks.contains(id) &&
          mounted) {
        _layoutChange(() {}, duration: NovelMotion.contact);
      }
    });
    return clock;
  });

  void _layoutChange(
    VoidCallback change, {
    Duration duration = NovelMotion.enter,
  }) {
    _reorder.duration = duration;
    if (!_reduced) _reflow.begin(_reorder);
    setState(change);
    if (!_reduced) _reorder.forward(from: 0);
  }

  void _toggleBook(int id) {
    final clock = _clockFor(id);
    final opening = !_expandedBooks.contains(id);
    if (_reduced || _query.trim().isNotEmpty) {
      _settlingMotion = true;
      setState(() {
        opening ? _expandedBooks.add(id) : _expandedBooks.remove(id);
        clock.value = opening ? 1 : 0;
      });
      _settlingMotion = false;
    } else if (opening) {
      _layoutChange(() => _expandedBooks.add(id));
      clock.forward();
    } else {
      setState(() => _expandedBooks.remove(id));
      clock.reverse();
    }
  }

  bool _keepsBookRows(int id) =>
      _expandedBooks.contains(id) ||
      _query.trim().isNotEmpty ||
      (_bookClocks[id]?.value ?? 0) > 0;

  Key _rowKey(Object row) {
    if (row is int) return ValueKey(('bookmark-book-row', row));
    final mark = row as _BookmarkMarkRow;
    return ValueKey((
      'bookmark-entry-row',
      mark.entry.novelId,
      mark.entry.bookmark.id,
    ));
  }

  @override
  void dispose() {
    widget.state.appearanceChanges.removeListener(_appearanceChanged);
    _reflow.dispose();
    _reorder.dispose();
    for (final clock in _bookClocks.values) {
      clock.dispose();
    }
    _search.dispose();
    super.dispose();
  }

  Novel? _known(int id) =>
      widget.state.localLibrary?.novelFor(id) ??
      (widget.repository is OfflineNovelRepository
          ? (widget.repository as OfflineNovelRepository).cache
                    .book(id)
                    ?.novel ??
                widget.state.cachedNovel(id)
          : widget.state.cachedNovel(id));

  Future<void> _open(int id, ReaderBookmark mark) async {
    if (_opening != null) return;
    setState(() => _opening = mark.id);
    try {
      final repository = widget.repository;
      if (isLocalBook(id) &&
          widget.state.localLibrary != null &&
          widget.state.localLibrary?.novelFor(id) == null) {
        throw const FormatException('本地原书已移除，摘录仍可查看和分享');
      }
      var novel = _known(id) ?? await repository.find(id);
      if (novel == null) throw const FormatException('暂时无法读取原书，请检查本机文件或网络');
      if (novel.chapters.isEmpty) {
        novel = novel.withChapters(await repository.chapters(novel.id));
      }
      final chapter = widget.state.chapterForPosition(novel, mark.position);
      if (chapter == null) throw const FormatException('原章节已变动，摘录仍保留');
      if (!mounted) return;
      await pushNovelPage<void>(
        context,
        ReaderPage(
          novel: novel,
          state: widget.state,
          repository: repository,
          initialChapter: chapter,
          initialBookmark: mark,
        ),
        reduceMotion: widget.state.reduceMotion,
      );
    } catch (error) {
      if (mounted) {
        showNovelFeedback(
          context,
          error is FormatException ? error.message : '暂时无法打开原文，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _edit(int id, ReaderBookmark mark) => showReaderAnnotationEditor(
    context,
    state: widget.state,
    novelId: id,
    bookmark: mark,
    rangeContextResolver: (ranges, anchor) =>
        loadOfflineReaderAnnotationContext(
          state: widget.state,
          repository: widget.repository,
          novelId: id,
          ranges: ranges,
          anchor: anchor,
          novel: _known(id),
          locale: Localizations.maybeLocaleOf(context),
        ),
  );

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '书签',
    code: 'PERSONAL / EXCERPTS',
    actions: [
      GlassIconButton(
        key: const ValueKey('bookmark-search-toggle'),
        icon: _searchOpen ? CupertinoIcons.xmark : CupertinoIcons.search,
        label: _searchOpen ? '收起搜索' : '搜索书签',
        onPressed: () {
          if (_searchOpen) {
            FocusScope.of(context).unfocus();
            _search.clear();
          }
          setState(() {
            _searchOpen = !_searchOpen;
            if (!_searchOpen) _query = '';
          });
        },
      ),
    ],
    child: AnimatedBuilder(
      animation: widget.state.bookmarkChanges,
      builder: (context, _) {
        final query = _query.trim().toLowerCase();
        final local = widget.state.localLibrary;
        final entries = libraryBookmarks(widget.state, books: local).where((
          entry,
        ) {
          final book = _known(entry.novelId);
          return (_category == '_all' ||
                  _category == '_book' ||
                  'category:${entry.bookmark.category}' == _category) &&
              (query.isEmpty ||
                  entry.bookmark.quote.toLowerCase().contains(query) ||
                  entry.bookmark.chapterTitle.toLowerCase().contains(query) ||
                  (book?.title.toLowerCase().contains(query) ?? false) ||
                  (book?.author.toLowerCase().contains(query) ?? false) ||
                  entry.bookmark.note.toLowerCase().contains(query));
        }).toList();
        final groups = <int, List<({int novelId, ReaderBookmark bookmark})>>{};
        for (final entry in entries) {
          groups.putIfAbsent(entry.novelId, () => []).add(entry);
        }
        final rows = <Object>[];
        if (_category == '_book') {
          for (final group in groups.entries) {
            rows.add(group.key);
            if (_keepsBookRows(group.key)) {
              rows.addAll([
                for (final (order, entry) in group.value.indexed)
                  _BookmarkMarkRow(entry, order),
              ]);
            }
          }
        } else {
          rows.addAll([
            for (final (order, entry) in entries.indexed)
              _BookmarkMarkRow(entry, order),
          ]);
        }
        final rowIndices = {
          for (final (index, row) in rows.indexed) _rowKey(row): index + 1,
        };
        final contentPadding = featurePadding(context);
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: EdgeInsets.only(top: contentPadding.top),
              child: LibraryReflowScope(
                controller: _reflow,
                enabled: !_reduced,
                generation: _reflow.generation,
                active: _reflow.active,
                child: LibraryReflowClip(
                  controller: _reflow,
                  child: ListView.builder(
                    clipBehavior: _reflow.active ? Clip.none : Clip.hardEdge,
                    padding: contentPadding.copyWith(top: 0),
                    itemCount: rows.length + 1,
                    findChildIndexCallback: (key) => rowIndices[key],
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AnimatedOptionSection(
                              expanded: _searchOpen,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 18),
                                child: AppSearchField(
                                  inputKey: const ValueKey('bookmark-search'),
                                  controller: _search,
                                  autofocus: true,
                                  hint: '搜索摘录、书名或作者',
                                  onChanged: (value) =>
                                      setState(() => _query = value),
                                ),
                              ),
                            ),
                            GlassSettingMenu<String>(
                              icon: CupertinoIcons.folder,
                              label: '书签分类',
                              value: _category,
                              options: {
                                '_book': '按书分类',
                                '_all': '全部书签',
                                'category:': '未分类',
                                for (final e in widget.state.bookmarkEntries)
                                  if (e.bookmark.category.isNotEmpty)
                                    'category:${e.bookmark.category}':
                                        e.bookmark.category,
                              },
                              onChanged: (value) =>
                                  setState(() => _category = value),
                              reduceMotion: widget.state.reduceMotion,
                            ),
                            const SizedBox(height: 12),
                            AppText(
                              '${entries.length} 条记录 · ${groups.length} 本书',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 16),
                            if (entries.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 36,
                                ),
                                child: AppText(
                                  query.isEmpty
                                      ? '长按正文选择喜欢的句子，点「书签」即可收藏。\n已有的位置书签也会显示在这里。'
                                      : widget.state.bookmarkEntries.any(
                                          (entry) => entry.bookmark.isUnderline,
                                        )
                                      ? '没有找到匹配的记录'
                                      : '没有找到匹配的书签',
                                  style: const TextStyle(height: 1.8),
                                ),
                              ),
                          ],
                        );
                      }
                      final row = rows[index - 1];
                      if (row is int) {
                        final book = _known(row), marks = groups[row]!;
                        final expanded =
                            _expandedBooks.contains(row) || query.isNotEmpty;
                        return KeyedSubtree(
                          key: _rowKey(row),
                          child: LibraryReflowPart(
                            id: ('bookmark-book', row),
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: ContentPanel(
                                key: ValueKey('bookmark-book-$row'),
                                onTap: () => _toggleBook(row),
                                child: ArchivePart(
                                  start: .18,
                                  end: .84,
                                  travel: const Offset(0, 6),
                                  child: Row(
                                    children: [
                                      const ArchiveIcon(
                                        CupertinoIcons.book,
                                        size: 22,
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            AppText(
                                              book?.title ?? '书籍 $row',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            AppText(
                                              '${marks.length} 条书签与标记',
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      AnimatedRotation(
                                        turns: expanded ? .25 : 0,
                                        duration: widget.state.reduceMotion
                                            ? Duration.zero
                                            : NovelMotion.contact,
                                        child: const ArchiveIcon(
                                          CupertinoIcons.chevron_right,
                                          size: 14,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }
                      final markRow = row as _BookmarkMarkRow;
                      final entry = markRow.entry;
                      final mark = entry.bookmark;
                      final novel = _known(entry.novelId);
                      final content = Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: ContentPanel(
                          key: ValueKey('my-bookmark-${mark.id}'),
                          onTap: () => _open(entry.novelId, mark),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (mark.quote.isNotEmpty ||
                                  mark.note.isNotEmpty) ...[
                                ReaderBookmarkExcerpt(mark: mark),
                                const SizedBox(height: 20),
                              ],
                              if (mark.quote.isEmpty && mark.note.isEmpty) ...[
                                AppText(
                                  mark.kindLabel,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 10),
                              ],
                              if (_category != '_book') ...[
                                AppText(
                                  novel?.title ?? '书籍 ${entry.novelId}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                              ],
                              AppText(
                                mark.chapterTitle,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.6,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              if (mark.category.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                AppText(
                                  '分类 · ${mark.category}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: GlassTextButton(
                                      key: ValueKey('bookmark-read-${mark.id}'),
                                      onPressed: _opening == null
                                          ? () => _open(entry.novelId, mark)
                                          : null,
                                      child: AppText(
                                        _opening == mark.id ? '正在打开…' : '回到原文',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  if (mark.quote.isNotEmpty)
                                    GlassIconButton(
                                      key: ValueKey(
                                        'bookmark-share-${mark.id}',
                                      ),
                                      icon: CupertinoIcons.square_arrow_up,
                                      label: '分享摘录图片 ${mark.id}',
                                      onPressed: () async {
                                        String? serifFamily;
                                        try {
                                          serifFamily =
                                              await registeredReadingReportSerif(
                                                widget.state.fonts,
                                              );
                                        } catch (_) {
                                          // Optional installed typography never blocks sharing.
                                        }
                                        if (!context.mounted) return;
                                        await pushNovelPage<void>(
                                          context,
                                          QuoteCardPage(
                                            serifFamily: serifFamily,
                                            data: QuoteCardData(
                                              text: mark.quote,
                                              book: novel?.title ?? '',
                                              author: novel?.author ?? '',
                                              chapter: mark.chapterTitle,
                                              recordedAt:
                                                  mark.createdAt == null ||
                                                      mark.createdOffsetMinutes ==
                                                          null
                                                  ? null
                                                  : mark.createdAt!.toUtc().add(
                                                      Duration(
                                                        minutes: mark
                                                            .createdOffsetMinutes!,
                                                      ),
                                                    ),
                                            ),
                                          ),
                                          reduceMotion:
                                              widget.state.reduceMotion,
                                        );
                                      },
                                    ),
                                  GlassIconButton(
                                    icon: CupertinoIcons.folder,
                                    label:
                                        '${mark.isUnderline ? '分类划线' : '分类书签'} ${mark.id}',
                                    onPressed: () => organizeBookmark(
                                      context,
                                      widget.state,
                                      entry.novelId,
                                      mark,
                                    ),
                                  ),
                                  GlassIconButton(
                                    icon: CupertinoIcons.square_pencil,
                                    label: '查看与编辑批注 ${mark.id}',
                                    onPressed: () => _edit(entry.novelId, mark),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                      final grouped = _category == '_book' && query.isEmpty;
                      final clock = grouped
                          ? _bookClocks[entry.novelId] ??
                                const AlwaysStoppedAnimation<double>(1)
                          : const AlwaysStoppedAnimation<double>(1);
                      final interactive =
                          !grouped || _expandedBooks.contains(entry.novelId);
                      return KeyedSubtree(
                        key: _rowKey(row),
                        child: LibraryReflowPart(
                          id: ('bookmark-mark', entry.novelId, mark.id),
                          child: IgnorePointer(
                            key: ValueKey((
                              'bookmark-entry-input',
                              entry.novelId,
                              mark.id,
                            )),
                            ignoring: !interactive,
                            child: ExcludeSemantics(
                              excluding: !interactive,
                              child: LoadedContentItem(
                                key: ValueKey((
                                  'bookmark-entry-motion',
                                  entry.novelId,
                                  mark.id,
                                )),
                                animation: _reduced
                                    ? const AlwaysStoppedAnimation<double>(1)
                                    : clock,
                                index: markRow.order,
                                placeholder: null,
                                child: content,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
