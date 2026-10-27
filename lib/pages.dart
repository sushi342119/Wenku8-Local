import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';

import 'app_ui.dart';
import 'app_typography.dart';
import 'app_interactions.dart';
import 'archive_carousel.dart';
import 'novel_random_pick_section.dart';
import 'backup_page.dart';
import 'book_tags.dart';
import 'catalog.dart';
import 'glass_dock.dart';
import 'library_state.dart';
import 'listening/controller.dart';
import 'listening/models.dart' show hasSpeechText;
import 'listening/widgets.dart';
import 'local_platform.dart';
import 'native_effects.dart' show NativeGlassGroup;
import 'novel_feed_controller.dart';
import 'offline_repository.dart';
import 'offline_widgets.dart';
import 'low_performance_page.dart';
import 'reader_catalogue.dart';
import 'reader_chrome.dart';
import 'reader_content.dart';
import 'reader_follow_scroll.dart';
import 'reader_illustrations.dart';
import 'reader_find.dart';
import 'reader_landing_highlight.dart';
import 'reader_tools.dart';
import 'reading_history.dart';
import 'recent_searches.dart';
import 'ui_notifiers.dart';
import 'feature_pages.dart';
import 'local_library.dart';
import 'local_record_removal.dart';
import 'local_scan_follow_up.dart';
import 'local_library_page.dart';
import 'local_pdf_reader.dart';
import 'tag_pages.dart';
import 'updates/update_page.dart';
import 'updates/app_updates.dart';

export 'app_ui.dart' show sectionHeader;

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state, required this.repository});
  final LibraryState state;
  final NovelRepository repository;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with TickerProviderStateMixin {
  /// 冷启动自动扫描本地书库：已绑定文件夹时静默扫描，有变化才提示。
  Future<void> _autoScanLocal(LocalLibraryStore local) async {
    if (local.folderUri == null) return;
    // 等首帧后再跑，避免阻塞启动。
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    try {
      final result = await local.scan();
      // 章节重切后迁移阅读进度，避免旧章节序号在新章节表下串章。
      // state 不依赖页面生命周期且切分版本标记已在 scan 内写入，
      // 必须赶在 mounted 检查前逐条执行；单条失败不中断其余。
      final failedChapterMigrations = <String>[];
      // 同一本书的前序迁移失败后，暂停该书的后继任务：链式迁移
      // 必须按序执行，不能跳过失败项直接跑下一项。
      final failedMigrationBooks = <int>{};
      for (final remap in result.chapterRemaps) {
        if (failedMigrationBooks.contains(remap.bookId)) continue;
        try {
          await widget.state.remapChapterProgress(
            remap.bookId,
            oldChapters: remap.oldChapters,
            newChapters: remap.newChapters,
            migrationId: remap.migrationId,
          );
          // state 已经完整写入目标位置后，才能确认本地任务。
          await local.confirmChapterRemap(remap.migrationId);
        } catch (error, stackTrace) {
          failedMigrationBooks.add(remap.bookId);
          failedChapterMigrations.add(remap.migrationId);
          try {
            await local.markChapterRemapFailed(remap, error);
          } catch (recordError, recordStackTrace) {
            // 任务在 scan() 中已经先入队；这里记录的是更新失败详情。
            // 不能让一个任务阻塞其他任务。
            debugPrint(
              'failed to persist chapter migration error '
              '${remap.migrationId}: $recordError\n$recordStackTrace',
            );
          }
          debugPrint(
            'chapter migration failed '
            '${remap.migrationId}: $error\n$stackTrace',
          );
        }
      }
      if (failedChapterMigrations.isNotEmpty && mounted) {
        showNovelFeedback(
          context,
          '${failedChapterMigrations.length} 本书的阅读进度迁移失败，已保存待重试任务',
        );
      }
      if (!mounted) return;
      // 文件夹切换：清理旧来源书籍的书架/标签/阅读进度。
      // peek→逐个幂等清理→confirm：中断后未确认的 ID 下次重试。
      // 这里不接删除步骤，清理失败只中断本轮、静默失败后用户可
      // 手动扫描重试；重授权路径的同名清理见 _applyLocalScanAfterReauth，
      // 那里异常必须向上传，不能吞掉。
      final state = widget.state;
      final cleanupIds = await local.peekAssociatedCleanupIds();
      final cleanupDone = <int>[];
      for (final id in cleanupIds) {
        try {
          await state.setShelfMembership(id, false);
          await TagStore.shared.setTagsForBook(id, const {});
          await state.clearBookProgress(id);
          cleanupDone.add(id);
        } catch (_) {
          break;
        }
      }
      await local.confirmAssociatedCleanupIds(cleanupDone);
      // 字数静默补算后刷新首页 feed，详情页简介才能显示最新字数。
      if (result.backfilled > 0) {
        await _catalog.refresh();
        if (!mounted) return;
      }
      final changed = result.added + result.refreshed + result.removed;
      if (changed == 0 && result.switchedRemovedIds.isEmpty) return;
      for (final book in local.books) {
        if (!state.shelf.contains(book.id)) {
          await state.toggleShelf(book.id, novel: local.toNovel(book));
        }
      }
      if (!mounted) return;
      final parts = <String>[];
      if (result.added > 0) parts.add('新增 ${result.added} 本');
      if (result.refreshed > 0) parts.add('更新 ${result.refreshed} 本');
      if (result.removed > 0) parts.add('移除 ${result.removed} 本');
      if (result.switchedRemovedIds.isNotEmpty) {
        parts.add('旧文件夹移除 ${result.switchedRemovedIds.length} 本');
      }
      showNovelFeedback(context, '本地书库自动扫描：${parts.join('，')}');
    } catch (_) {
      // 静默失败：用户可在本地书库页手动扫描。
    }
  }

  late NovelFeedController _catalog;
  late NovelFeedController _searchFeed;
  List<Widget> _pageWidgets = const [];
  List<WidgetBuilder> _headers = const [];
  int _tab = 0;
  double _tabDirection = 1;
  int? _outgoingTab;
  bool _searchOpen = false;
  bool _searchMounted = false;
  bool _searchCovered = false;
  final _searchText = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'inline-search');
  bool _searchStarted = false;
  String _lastRecordedSearch = '';
  late final AnimationController _searchExpansion =
      AnimationController(
        vsync: this,
        duration: NovelMotion.enter,
        reverseDuration: NovelMotion.exit,
      )..addStatusListener((status) {
        if (!mounted) return;
        if (status == AnimationStatus.dismissed && !_searchOpen) {
          setState(() => _searchMounted = false);
        } else if (status == AnimationStatus.completed && _searchOpen) {
          setState(() => _searchCovered = true);
          _searchFocus.requestFocus();
        }
      });
  late final AnimationController _pageTransition =
      AnimationController(vsync: this, duration: NovelMotion.enter, value: 1)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() => _outgoingTab = null);
          }
        });

  @override
  void initState() {
    super.initState();
    // 首页改用本地书库数据源（纯本地阅读）。
    final NovelRepository homeRepository;
    final repo = widget.repository;
    if (repo is CompositeNovelRepository) {
      homeRepository = repo.local;
    } else {
      homeRepository = repo;
    }
    _catalog = NovelFeedController(
      homeRepository,
      // 本地书库首页加载全部书籍，用于 3D 轮播全量循环和随机抽选。
      loadAll: true,
    );
    _searchFeed = NovelFeedController(homeRepository, search: true);
    _searchText.addListener(_searchEdited);
    _searchFeed.addListener(_searchSucceeded);
    final repository = widget.repository;
    final OfflineNovelRepository? offline = repository
            is CompositeNovelRepository
        ? (repository.remote is OfflineNovelRepository
              ? repository.remote as OfflineNovelRepository
              : null)
        : (repository is OfflineNovelRepository ? repository : null);
    if (offline != null) {
      unawaited(offline.loadCache().catchError((Object _) {}));
    }
    // 启动自动扫描本地书库（静默，有变化才提示）。
    if (repository is CompositeNovelRepository) {
      _autoScanLocal(repository.local);
    }
    final discover = DiscoverPage(
      books: const [],
      feed: _catalog,
      state: widget.state,
      repository: widget.repository,
      showHeader: false,
      onSearch: _openSearch,
      categoryTitle: '本地书库',
    );
    final shelf = ShelfPage(
      books: const [],
      state: widget.state,
      repository: widget.repository,
      showHeader: false,
    );
    final settings = SettingsPage(
      state: widget.state,
      repository: widget.repository,
      showHeader: false,
    );
    _headers = [discover.buildHeader, shelf.buildHeader, settings.buildHeader];
    _pageWidgets = [discover, shelf, settings]
        .map((page) => RepaintBoundary(child: Atmosphere(child: page)))
        .toList(growable: false);
    _catalog.loadInitial();
  }

  @override
  void dispose() {
    _pageTransition.dispose();
    _searchExpansion.dispose();
    _searchText.dispose();
    _searchFocus.dispose();
    _catalog.dispose();
    _searchFeed.dispose();
    super.dispose();
  }

  bool get _reduceMotion =>
      widget.state.reduceMotion || MediaQuery.disableAnimationsOf(context);

  void _openSearch() {
    if (!_searchStarted || (_searchFeed.page == 0 && !_searchFeed.loading)) {
      _searchStarted = true;
      _searchFeed.loadInitial();
    }
    setState(() {
      _searchOpen = true;
      _searchMounted = true;
    });
    if (_reduceMotion) {
      _searchExpansion.value = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searchOpen) _searchFocus.requestFocus();
      });
    } else {
      _searchExpansion.forward();
    }
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    _searchFeed.cancelScheduledSearch();
    setState(() {
      _searchOpen = false;
      _searchCovered = false;
    });
    if (_reduceMotion) {
      _searchExpansion.value = 0;
    } else {
      _searchExpansion.reverse();
    }
  }

  void _searchEdited() {
    if (!_searchOpen) return;
    if (!_searchText.value.composing.isCollapsed) {
      _searchFeed.cancelScheduledSearch();
      return;
    }
    _searchFeed.scheduleSearch(_searchText.text);
  }

  void _searchSucceeded() {
    if (_searchFeed.loading ||
        _searchFeed.error != null ||
        _searchFeed.page < 1) {
      return;
    }
    final query = _searchFeed.query.trim();
    if (query == _lastRecordedSearch) return;
    _lastRecordedSearch = query;
    unawaited(
      widget.state.recordSearch(query).catchError((Object _) {
        if (_lastRecordedSearch == query) _lastRecordedSearch = '';
        if (mounted) showNovelFeedback(context, '最近搜索保存失败');
      }),
    );
  }

  void _recallSearch(String query) {
    _searchText.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    _searchFeed.searchFor(query);
    _searchFocus.unfocus();
  }

  void _selectTab(int index) {
    if (index == _tab) return;
    final reduceMotion =
        widget.state.reduceMotion || MediaQuery.disableAnimationsOf(context);
    if (index != _tab) HapticFeedback.selectionClick();
    setState(() {
      if (index != _tab) {
        _tabDirection = index > _tab ? 1 : -1;
        _outgoingTab = reduceMotion ? null : _tab;
        if (reduceMotion) {
          _pageTransition.value = 1;
        } else {
          _pageTransition.forward(from: 0);
        }
      }
      _tab = index;
    });
  }

  Widget _tabPlane(int index) {
    final active = index == _tab;
    final outgoing = index == _outgoingTab;
    final animation = (active || outgoing) && !_reduceMotion
        ? _pageTransition
        : const AlwaysStoppedAnimation<double>(1);
    return Offstage(
      key: ValueKey('home-tab-$index'),
      offstage: _searchCovered || (!active && !outgoing),
      child: TickerMode(
        enabled: active && !_searchCovered,
        child: HeroMode(
          enabled: active && !_searchMounted,
          child: IgnorePointer(
            ignoring: !active || _searchMounted,
            child: ExcludeSemantics(
              excluding: !active || _searchMounted,
              child: ArchivePlaneTransition(
                key: ValueKey('home-archive-plane-$index'),
                animation: animation,
                kind: outgoing
                    ? ArchivePlaneKind.outgoing
                    : ArchivePlaneKind.incoming,
                direction: _tabDirection,
                child: ArchiveMotionScope(
                  animation: animation,
                  enabled: active && !_reduceMotion,
                  child: _pageWidgets[index],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_searchMounted,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _searchMounted) _closeSearch();
    },
    child: Scaffold(
      body: Atmosphere(
        // Each tab/search paints its own archive diagram; the shell only
        // supplies the fallback canvas during a transition.
        archiveBackdrop: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        for (var i = 0; i < _pageWidgets.length; i++)
                          if (i != _tab && i != _outgoingTab) _tabPlane(i),
                        if (_outgoingTab case final outgoing?)
                          _tabPlane(outgoing),
                        _tabPlane(_tab),
                      ],
                    ),
                  ),
                  if (_searchMounted)
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: !_searchOpen,
                        child: ArchivePlaneTransition(
                          key: const ValueKey('search-archive-plane'),
                          animation: _searchExpansion,
                          child: Atmosphere(
                            child: InlineSearchResults(
                              feed: _searchFeed,
                              state: widget.state,
                              repository: widget.repository,
                              onOpenBook: _searchFocus.unfocus,
                              onRecall: _recallSearch,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    key: const ValueKey('home-pinned-header'),
                    top: 0,
                    left: 0,
                    right: 0,
                    child: FrostedHeader(
                      child: _searchMounted
                          ? _expandedSearchHeader(context)
                          : ArchiveMotionScope(
                              animation: _pageTransition,
                              enabled: !_reduceMotion,
                              child: Row(
                                children: [
                                  Expanded(child: _headers[_tab](context)),
                                  if (ListeningScope.maybeOf(context)
                                      case final listening?)
                                    ValueListenableBuilder<ListeningSnapshot>(
                                      valueListenable: listening.snapshot,
                                      builder: (context, session, _) =>
                                          session.novel == null ||
                                              !session.active
                                          ? const SizedBox.shrink()
                                          : Padding(
                                              padding: const EdgeInsets.only(
                                                left: 4,
                                              ),
                                              child: GlassIconButton(
                                                key: const ValueKey(
                                                  'home-listening-entry',
                                                ),
                                                icon: CupertinoIcons.headphones,
                                                label:
                                                    '正在听书 · ${session.novel!.title}',
                                                onPressed: () =>
                                                    showListeningPanel(
                                                      context,
                                                      controller: listening,
                                                      novel: session.novel!,
                                                      chapter: session.chapter,
                                                      paragraph:
                                                          session
                                                              .current
                                                              ?.paragraph ??
                                                          0,
                                                      reduceMotion: widget
                                                          .state
                                                          .reduceMotion,
                                                    ),
                                              ),
                                            ),
                                    ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
            const Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: DockUnderlay(),
            ),
            AnimatedBuilder(
              animation: _searchExpansion,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    22 + MediaQuery.paddingOf(context).left,
                    0,
                    22 + MediaQuery.paddingOf(context).right,
                    12 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: GlassDock(
                    key: const ValueKey('liquid-dock'),
                    selectedIndex: _tab,
                    reduceMotion: widget.state.reduceMotion,
                    onSelected: _selectTab,
                  ),
                ),
              ),
              builder: (context, child) => IgnorePointer(
                ignoring: _searchMounted,
                child: ExcludeSemantics(
                  excluding: _searchMounted,
                  child: Opacity(
                    opacity: 1 - _searchExpansion.value,
                    child: child,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _expandedSearchHeader(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => AnimatedBuilder(
      animation: _searchExpansion,
      child: _searchField(context),
      builder: (context, child) {
        final t = _searchExpansion.value;
        final expansion = NovelMotion.ease.transform(t);
        final wobble = _reduceMotion ? 0.0 : NovelMotion.jelly(t);
        final width = 46 + (constraints.maxWidth - 46) * expansion;
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            ExcludeSemantics(
              child: Opacity(
                opacity: 1 - expansion,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: const ArchiveMasthead(
                    title: '轻小说文库',
                    code: 'WENKU8 / READING ARCHIVE',
                    brand: true,
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Transform(
                key: const ValueKey('search-jelly-transform'),
                alignment: Alignment.centerRight,
                transform: Matrix4.diagonal3Values(
                  1 + .026 * wobble,
                  1 - .042 * wobble,
                  1,
                ),
                child: IgnorePointer(
                  ignoring: !_searchOpen || t < .4,
                  child: LiquidGlass(
                    key: const ValueKey('expanded-search-bar'),
                    radius: 24 - expansion,
                    elevated: false,
                    activation: wobble.abs() * .35,
                    touchPosition: .94,
                    child: SizedBox(
                      width: width,
                      height: 46,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24 - expansion),
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          minWidth: constraints.maxWidth,
                          maxWidth: constraints.maxWidth,
                          minHeight: 46,
                          maxHeight: 46,
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  Widget _searchField(BuildContext context) => Row(
    children: [
      const SizedBox(width: 46, child: Icon(CupertinoIcons.search, size: 21)),
      Expanded(
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchText,
          builder: (context, value, _) => TextField(
            key: const ValueKey('expanded-search-input'),
            controller: _searchText,
            focusNode: _searchFocus,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 14),
            onSubmitted: (query) {
              _searchFeed.searchFor(query);
              _searchFocus.unfocus();
            },
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: '书名、作者',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      icon: const Icon(
                        CupertinoIcons.xmark_circle_fill,
                        size: 17,
                      ),
                      onPressed: _searchText.clear,
                    ),
            ),
          ),
        ),
      ),
      SizedBox(
        width: 46,
        height: 46,
        child: IconButton(
          key: const ValueKey('inline-search-close'),
          tooltip: '收起搜索',
          onPressed: _closeSearch,
          icon: const Icon(CupertinoIcons.xmark, size: 17),
        ),
      ),
    ],
  );
}

/// showGlassMenu 的外层 null 表示关闭菜单；实例中的 tagId == null 表示选择“全部”。
class _TagMenuChoice {
  const _TagMenuChoice(this.tagId);

  final String? tagId;
}

class DiscoverPage extends StatefulWidget {
  const DiscoverPage({
    super.key,
    required this.books,
    required this.state,
    required this.repository,
    required this.onSearch,
    this.showHeader = true,
    this.feed,
    this.categoryTitle,
    this.onChooseCategory,
  });
  final List<Novel> books;
  final LibraryState state;
  final NovelRepository repository;
  final VoidCallback onSearch;
  final bool showHeader;
  final NovelFeedController? feed;
  final String? categoryTitle;
  final void Function(BuildContext context)? onChooseCategory;

  /// 顶部栏由 HomeShell 通过 widget 实例直接取用，不依赖 State。
  Widget buildHeader(BuildContext context) => Row(
        children: [
          const Expanded(
            child: ArchiveMasthead(
              title: '轻小说文库',
              code: 'WENKU8 / READING ARCHIVE',
              brand: true,
            ),
          ),
          GlassIconButton(
            icon: CupertinoIcons.search,
            label: '搜索',
            onPressed: onSearch,
          ),
        ],
      );

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  final TagStore _tagStore = TagStore.shared;

  /// 当前选中的标签 id；null 表示“全部”。纯展示状态，不持久化。
  String? _selectedTagId;

  @override
  void initState() {
    super.initState();
    _tagStore.addListener(_onTagsChanged);
  }

  @override
  void dispose() {
    _tagStore.removeListener(_onTagsChanged);
    super.dispose();
  }

  void _onTagsChanged() {
    if (!mounted) return;
    // 标签改名、增删、书籍归属变化都要刷新；选中标签被删除则回退到全部。
    setState(() {
      final selectedTagId = _selectedTagId;
      if (selectedTagId != null &&
          _tagStore.tagById(selectedTagId) == null) {
        _selectedTagId = null;
      }
    });
  }

  void _showAllTags() {
    if (!mounted || _selectedTagId == null) return;
    setState(() {
      _selectedTagId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;
    return feed == null
        ? _buildContent(context, widget.books)
        : AnimatedBuilder(
            animation: feed,
            builder: (context, _) => LoadedContentSequence(
              generation: feed.resultRevision,
              firstIndex: feed.resultStartIndex == 0
                  ? 0
                  : feed.resultStartIndex + 2,
              child: _buildContent(context, feed.items),
            ),
          );
  }

  /// 轮播区域：只在这里应用标签过滤。
  Widget _buildCarouselArea(BuildContext context, List<Novel> carouselBooks) {
    if (carouselBooks.isNotEmpty) {
      return ArchiveFileCarousel(
        // 同一标签下保持轮播 State（分页追加不重置焦点）；
        // 切换标签或切回全部时重建，从初始位置展示。
        key: ValueKey(
          'archive-files-${widget.feed?.sort.name ?? 'recent'}-${_selectedTagId ?? 'all'}',
        ),
        books: carouselBooks,
        reduceMotion: widget.state.reduceMotion,
        animateEntrance: true,
        onOpen: (book, tag) => openDetail(
          context,
          book,
          widget.state,
          widget.repository,
          coverHeroTag: tag,
        ),
      );
    }
    if (_selectedTagId != null) {
      // 分页加载中：已加载部分暂无匹配不代表最终结果。
      final stillLoading = widget.feed?.loading == true;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 72),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(stillLoading ? '已加载书籍中暂无匹配，正在继续加载…' : '该标签下暂无书籍'),
              const SizedBox(height: 12),
              CupertinoButton(
                onPressed: _showAllTags,
                child: const Text('查看全部'),
              ),
            ],
          ),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 90),
      child: Center(child: Text('暂无书籍')),
    );
  }

  Widget _buildContent(BuildContext context, List<Novel> books) {
    final feed = widget.feed;
    final allBooks = books;
    final selectedTagId = _selectedTagId;
    // 只过滤轮播；随机抽阅与“更多书籍”始终使用全量。
    final List<Novel> carouselBooks = selectedTagId == null
        ? allBooks
        : allBooks
            .where(
              (book) => _tagStore
                  .tagsForBook(book.id)
                  .any((tag) => tag.id == selectedTagId),
            )
            .toList(growable: false);

    final featuredCount = allBooks.length.clamp(0, 10);
    Widget body;
    if (allBooks.isEmpty && feed?.loading == true) {
      body = LibrarySkeleton(header: _categoryHeader(context));
    } else if (allBooks.isEmpty && feed?.error != null) {
      body = ContentNotice(
        icon: CupertinoIcons.wifi_exclamationmark,
        title: '书籍加载失败',
        message: '检查网络后再试，已保存的书架与阅读记录仍保留。',
        onRetry: feed!.retry,
      );
    } else {
      body = NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth == 0 &&
              notification.metrics.axis == Axis.vertical &&
              feed?.loading == false &&
              feed?.hasMore == true &&
              feed?.error == null &&
              notification.metrics.extentAfter <
                  math.max(800, notification.metrics.viewportDimension * 1.5)) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => feed?.loadMore(),
            );
          }
          return false;
        },
        child: KeyedSubtree(
          key: ValueKey(feed?.sort),
          child: CustomScrollView(
            key: const PageStorageKey('discover'),
            physics: const AlwaysScrollableScrollPhysics(),
            cacheExtent: 500,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  MediaQuery.paddingOf(context).top +
                      FrostedHeader.toolbarHeight +
                      20,
                  24,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LoadedContentItem(
                        index: 0,
                        child: _categoryHeader(context),
                      ),
                      const SizedBox(height: 14),
                      _buildCarouselArea(context, carouselBooks),
                      if (allBooks.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        NovelRandomPickSection(
                          books: allBooks,
                          onOpenDetail: (book) => openDetail(
                            context,
                            book,
                            widget.state,
                            widget.repository,
                          ),
                        ),
                        if (allBooks.length > featuredCount ||
                            feed?.loading == true) ...[
                          const SizedBox(height: 32),
                          LoadedContentItem(
                            index: 2,
                            child: sectionHeader(context, '更多书籍', ''),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverList.builder(
                  itemCount: allBooks.length - featuredCount,
                  itemBuilder: (context, index) {
                    final book = allBooks[index + featuredCount];
                    return LoadedContentItem(
                      key: ValueKey(book.id),
                      index: index + featuredCount + 2,
                      child: NovelRow(
                        novel: book,
                        coverHeroTag: CoverHeroTag(context, book.id),
                        onTap: () => openDetail(
                          context,
                          book,
                          widget.state,
                          widget.repository,
                          coverHeroTag: CoverHeroTag(context, book.id),
                        ),
                      ),
                    );
                  },
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + 120,
                ),
                sliver: SliverToBoxAdapter(
                  child: feed == null
                      ? const SizedBox.shrink()
                      : FeedFooter(feed: feed),
                ),
              ),
            ],
          ),
        ),
      );
      if (feed != null) {
        body = FeedRefresh(feed: feed, child: body);
      }
    }
    return GlassHeaderLayout(
      showHeader: widget.showHeader,
      header: widget.buildHeader(context),
      body: body,
    );
  }

  Widget _categoryHeader(BuildContext context) {
    final selectedTagId = _selectedTagId;
    final selectedTag =
        selectedTagId == null ? null : _tagStore.tagById(selectedTagId);
    final title = selectedTag?.name ?? widget.categoryTitle ?? '全部';
    return Row(
      children: [
        Expanded(
          child: sectionHeader(
            context,
            title,
            '',
          ),
        ),
        if (widget.feed != null)
          GlassMenuAnchor(
            child: Builder(
              builder: (buttonContext) => GlassIconButton(
                icon: CupertinoIcons.line_horizontal_3_decrease,
                label: '标签筛选',
                onPressed: () => widget.onChooseCategory != null
                    ? widget.onChooseCategory!(buttonContext)
                    : _chooseTag(buttonContext),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _chooseTag(BuildContext context) async {
    final choice = await showGlassMenu<_TagMenuChoice>(
      context: context,
      reduceMotion: widget.state.reduceMotion,
      builder: (menuContext) => AnimatedBuilder(
        // 菜单打开期间标签发生增删改名时同步更新菜单内容。
        animation: _tagStore,
        builder: (context, _) {
          final tags = _tagStore.tags.toList(growable: false);
          final selectedTagId = _selectedTagId;
          final effectiveSelectedTagId = selectedTagId != null &&
                  _tagStore.tagById(selectedTagId) != null
              ? selectedTagId
              : null;
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(menuContext).height * .62,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassMenuItem(
                    order: 0,
                    label: '全部',
                    selected: effectiveSelectedTagId == null,
                    onPressed: () =>
                        Navigator.of(menuContext).pop<_TagMenuChoice>(
                      const _TagMenuChoice(null),
                    ),
                  ),
                  for (var index = 0; index < tags.length; index++)
                    GlassMenuItem(
                      order: index + 1,
                      label: tags[index].name,
                      selected: effectiveSelectedTagId == tags[index].id,
                      onPressed: () =>
                          Navigator.of(menuContext).pop<_TagMenuChoice>(
                        _TagMenuChoice(tags[index].id),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );

    // 外层 null 是取消菜单，不清除现有选择。
    if (!mounted || choice == null) return;

    final requestedTagId = choice.tagId;
    // 标签可能在点击与菜单 Future 返回之间被删除。
    final String? nextTagId = requestedTagId != null &&
            _tagStore.tagById(requestedTagId) != null
        ? requestedTagId
        : null;

    // 重复选择不触发重建。
    if (_selectedTagId == nextTagId) return;

    setState(() {
      _selectedTagId = nextTagId;
    });
  }
}

/// Pull-to-refresh keeps content/scroll position and announces a bounded static
/// skeleton strip. There is no native spinner hidden behind the glass header.
class FeedRefresh extends StatelessWidget {
  const FeedRefresh({super.key, required this.feed, required this.child});
  final NovelFeedController feed;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: RefreshIndicator.noSpinner(
          onRefresh: feed.refresh,
          child: child,
        ),
      ),
      if (feed.refreshing)
        Positioned(
          top: MediaQuery.paddingOf(context).top + FrostedHeader.toolbarHeight,
          left: 24,
          right: 24,
          height: 64,
          child: IgnorePointer(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: const LoadingSkeleton(
                key: ValueKey('feed-refresh-skeleton'),
                layout: SkeletonLayout.actions,
                label: '正在刷新书籍',
              ),
            ),
          ),
        ),
    ],
  );
}

class FeedFooter extends StatelessWidget {
  const FeedFooter({super.key, required this.feed});
  final NovelFeedController feed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (feed.loading)
          const BookRowSkeleton(label: '正在加载更多书籍')
        else if (feed.error != null) ...[
          Text(
            feed.refreshFailed ? '刷新失败，已保留原列表' : '加载下一页失败',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          GlassTextButton(onPressed: feed.retry, child: const Text('重试')),
        ] else if (feed.hasMore)
          GlassTextButton(onPressed: feed.loadMore, child: const Text('加载更多'))
        else if (feed.items.isNotEmpty)
          Text(
            '已经到底了',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
      ],
    ),
  );
}

void openDetail(
  BuildContext context,
  Novel novel,
  LibraryState state,
  NovelRepository repository, {
  Object? coverHeroTag,
  bool fromCache = false,
}) {
  unawaited(
    pushNovelPage<void>(
      context,
      fromCache
          ? DetailPage(
              novel: novel,
              state: state,
              repository: repository,
              fromCache: true,
              coverHeroTag: coverHeroTag,
            )
          : DetailLoaderPage(
              novel: novel,
              state: state,
              repository: repository,
              coverHeroTag: coverHeroTag,
            ),
      reduceMotion: state.reduceMotion,
      paperFlight: coverHeroTag != null,
      slot: 'detail',
    ),
  );
}

void openReadingHistory(
  BuildContext context,
  LibraryState state,
  NovelRepository repository,
) => unawaited(
  pushNovelPage<void>(
    context,
    ReadingHistoryPage(
      state: state,
      repository: repository,
      onOpen: (pageContext, id, book) => openDetail(
        pageContext,
        book ??
            Novel(
              id: id,
              title: '书籍 $id',
              author: '',
              genre: '',
              summary: '',
              colors: const [Color(0xFF202020), Color(0xFF333333)],
            ),
        state,
        repository,
      ),
    ),
    reduceMotion: state.reduceMotion,
  ),
);

/// 书架行内的标签，只负责展示。
///
/// 由父级决定是否传入；为 null 时不占高度。
class _ShelfBookTags extends StatelessWidget {
  const _ShelfBookTags({required this.tags});

  final List<Tag> tags;

  static const double _maxChipWidth = 120;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 标签整体宽度最多 120；窄屏时不超过标题栏可用宽度。
        final double maxChipWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth.clamp(0.0, _maxChipWidth).toDouble()
            : _maxChipWidth;
        return Wrap(
          spacing: 4,
          runSpacing: 2,
          children: [
            for (final tag in tags)
              _buildChip(tag: tag, theme: theme, maxWidth: maxChipWidth),
          ],
        );
      },
    );
  }

  Widget _buildChip({
    required Tag tag,
    required ThemeData theme,
    required double maxWidth,
  }) {
    // 沿用详情页配色；调色板为空时回退到主题色，避免取模异常。
    final Color color = tagPalette.isEmpty
        ? theme.colorScheme.primary
        : tagPalette[tag.colorIndex % tagPalette.length];
    // 不用 Chip：其最小高度受主题约束，无法保证缩小到一半。
    // 这里用 Container 自绘：字号 9（行高约 10.8）+ 上下内边距 2 + 边框 2，
    // 总高度约 15，仅为原来 Chip（约 36~40）的三分之一多一点。
    // 文字样式沿用主题 labelLarge（原 Chip 默认），只改字号，保证颜色不变。
    return Tooltip(
      message: tag.name,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          key: ValueKey<String>(tag.id),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .18),
            border: Border.all(color: color.withValues(alpha: .5)),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            tag.name,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
                  fontSize: 9,
                  height: 1.2,
                ) ??
                const TextStyle(fontSize: 9, height: 1.2),
          ),
        ),
      ),
    );
  }
}

class NovelRow extends StatelessWidget {
  const NovelRow({
    super.key,
    required this.novel,
    required this.onTap,
    this.trailing,
    this.coverHeroTag,
    this.tagRow,
  });
  final Novel novel;
  final VoidCallback onTap;
  final Widget? trailing;
  final Object? coverHeroTag;

  /// 标题下方的可选标签区域。为 null 时不占高度。
  final Widget? tagRow;

  @override
  Widget build(BuildContext context) => JellyTapSurface(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          NovelCover(novel, width: 56, height: 76, heroTag: coverHeroTag),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ArchiveCode(ArchiveDesign.fileCode(novel.id)),
                const SizedBox(height: 4),
                Text(
                  novel.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                // 标签紧接标题；无标签时不创建间距。
                if (tagRow != null) ...[
                  const SizedBox(height: 4),
                  tagRow!,
                ],
                // 本地书作者可能为空，不创建空作者行及其间距。
                if (novel.author.trim().isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    novel.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          trailing ?? const Icon(CupertinoIcons.chevron_right, size: 15),
        ],
      ),
    ),
  );
}

class ShelfPage extends StatefulWidget {
  const ShelfPage({
    super.key,
    required this.books,
    required this.state,
    required this.repository,
    this.showHeader = true,
  });
  final List<Novel> books;
  final LibraryState state;
  final NovelRepository repository;
  final bool showHeader;

  Widget buildHeader(BuildContext context) => Row(
    children: [
      Expanded(
        child: const ArchiveMasthead(
          title: '书架',
          code: '02 / PERSONAL ARCHIVE',
        ),
      ),
      GlassIconButton(
        icon: CupertinoIcons.clock,
        label: '阅读历史',
        onPressed: () => openReadingHistory(context, state, repository),
      ),
    ],
  );

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

enum _ShelfSort { recentRead, recentAdded, title }

class _ShelfPageState extends State<ShelfPage> {
  final Map<int, Future<Novel?>> _requests = {};
  final _query = TextEditingController();
  String? _activeTagId;
  _ShelfSort get _sort =>
      _ShelfSort.values.firstWhere((sort) => sort.name == state.shelfSort);
  LibraryState get state => widget.state;
  late final _changes = Listenable.merge([
    state,
    state.historyChanges,
    state.shelfViewChanges,
    TagStore.shared,
  ]);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _matches(int id) {
    if (_activeTagId != null &&
        !TagStore.shared.tagsForBook(id).any((t) => t.id == _activeTagId)) {
      return false;
    }
    final book = _known(id);
    final term = _query.text.trim().toLowerCase();
    if (term.isNotEmpty &&
        !'$id ${book?.title ?? ''} ${book?.author ?? ''}'
            .toLowerCase()
            .contains(term)) {
      return false;
    }
    final read = state.hasRead(id);
    final finished = book != null && state.finishedReading(book);
    return switch (state.shelfFilter) {
      'unread' => !read,
      'reading' => read && !finished,
      'finished' => finished,
      _ => true,
    };
  }

  Novel? _known(int id) {
    final cached = state.cachedNovel(id);
    if (cached != null) return cached;
    for (final book in widget.books) {
      if (book.id == id) return book;
    }
    return null;
  }

  Future<Novel?> _resolve(int id) async {
    final book = await widget.repository.find(id);
    if (book != null) await state.rememberNovel(book);
    return book;
  }

  int _compare(int a, int b) {
    final result = switch (_sort) {
      _ShelfSort.recentRead =>
        state.lastReadAt(b).compareTo(state.lastReadAt(a)),
      _ShelfSort.recentAdded => state.addedAt(b).compareTo(state.addedAt(a)),
      _ShelfSort.title => (_known(a)?.title ?? '$a').compareTo(
        _known(b)?.title ?? '$b',
      ),
    };
    if (result != 0) return result;
    final added = state.addedAt(b).compareTo(state.addedAt(a));
    return added != 0 ? added : a.compareTo(b);
  }

  @override
  Widget build(BuildContext context) => ActiveListenableBuilder(
    listenable: _changes,
    builder: (context) {
      final saved = state.shelf.where(_matches).toList()..sort(_compare);
      return GlassHeaderLayout(
        showHeader: widget.showHeader,
        header: widget.buildHeader(context),
        body: ListView.builder(
          key: const PageStorageKey('shelf'),
          padding: EdgeInsets.fromLTRB(
            24,
            MediaQuery.paddingOf(context).top +
                FrostedHeader.toolbarHeight +
                20,
            24,
            MediaQuery.paddingOf(context).bottom + 120,
          ),
          itemCount: saved.isEmpty ? 2 : saved.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CupertinoSearchTextField(
                      key: const ValueKey('shelf-search'),
                      controller: _query,
                      borderRadius: BorderRadius.circular(
                        ArchiveDesign.panelRadius,
                      ),
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      placeholder: '在书架中查找书名、作者或 ID',
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            saved.length == state.shelf.length
                                ? '${saved.length} 本书'
                                : '${saved.length} / ${state.shelf.length} 本书',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        GlassMenuAnchor(
                          child: Builder(
                            builder: (buttonContext) => GlassTextButton(
                              key: const ValueKey('shelf-filter'),
                              onPressed: () => _chooseFilter(buttonContext),
                              child: Text(switch (state.shelfFilter) {
                                'unread' => '未读',
                                'reading' => '阅读中',
                                'finished' => '已读完',
                                _ => '全部',
                              }),
                            ),
                          ),
                        ),
                        GlassMenuAnchor(
                          child: Builder(
                            builder: (buttonContext) => GlassIconButton(
                              icon: CupertinoIcons.line_horizontal_3_decrease,
                              label: '书架排序',
                              onPressed: () => _chooseSort(buttonContext),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (TagStore.shared.tags.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 34,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            _tagChip(context, null, '全部'),
                            for (final tag in TagStore.shared.tags)
                              _tagChip(context, tag.id, tag.name),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }
            if (saved.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 90),
                child: Column(
                  children: [
                    Icon(
                      CupertinoIcons.book,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 34,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      state.shelf.isEmpty ? '书架还空着' : '没有符合条件的书',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      state.shelf.isEmpty ? '在发现页收藏喜欢的书' : '试试其他关键词或切回全部',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }
            final id = saved[index - 1];
            final book = _known(id);
            return FutureBuilder<Novel?>(
              key: ValueKey('shelf-resolve-$id'),
              initialData: book,
              future: book == null
                  ? _requests.putIfAbsent(id, () => _resolve(id))
                  : _requests[id],
              builder: (context, snapshot) {
                final resolved = book ?? snapshot.data;
                final pending =
                    snapshot.connectionState != ConnectionState.done;
                return LoadedContentSequence(
                  generation: resolved?.id,
                  child: resolved != null
                      ? LoadedContentItem(
                          index: index - 1,
                          child: _row(context, resolved),
                        )
                      : pending
                      ? BookRowSkeleton(label: '正在载入书籍 $id')
                      : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Row(
                            children: [
                              const Icon(CupertinoIcons.book, size: 26),
                              const SizedBox(width: 15),
                              Expanded(child: Text('书籍 $id 暂未载入')),
                              GlassTextButton(
                                onPressed: () => setState(() {
                                  _requests[id] = _resolve(id);
                                }),
                                child: const Text('重试'),
                              ),
                              GlassMenuAnchor(
                                child: Builder(
                                  builder: (buttonContext) => GlassIconButton(
                                    icon: CupertinoIcons.ellipsis,
                                    label: '书籍 $id 书架操作',
                                    onPressed: () =>
                                        _bookMenu(buttonContext, id),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                );
              },
            );
          },
        ),
      );
    },
  );

  /// 该书的标签行；无标签时返回 null，不占高度。
  /// 书架已监听 TagStore，标签变化会自动重建行。
  Widget? _tagRowForBook(int bookId) {
    final List<Tag> tags = TagStore.shared.tagsForBook(bookId);
    if (tags.isEmpty) {
      return null;
    }
    return _ShelfBookTags(tags: tags);
  }

  Widget _row(BuildContext context, Novel book) => NovelRow(
    key: ValueKey('shelf-book-${book.id}'),
    novel: book,
    coverHeroTag: CoverHeroTag(this, book.id),
    tagRow: _tagRowForBook(book.id),
    onTap: () => openDetail(
      context,
      book,
      state,
      widget.repository,
      coverHeroTag: CoverHeroTag(this, book.id),
    ),
    trailing: SizedBox(
      width: 74,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassMenuAnchor(
            child: Builder(
              builder: (buttonContext) => GlassIconButton(
                icon: CupertinoIcons.ellipsis,
                label: '${book.title}书架操作',
                onPressed: () => _bookMenu(buttonContext, book.id, book: book),
              ),
            ),
          ),
          Text(
            !state.hasRead(book.id)
                ? '未读'
                : state.finishedReading(book)
                ? '已读完'
                : (book.chapters.isNotEmpty || book.chapterCount > 0)
                ? '${state.chapterForNovel(book) + 1}/${book.chapters.isNotEmpty ? book.chapters.length : book.chapterCount}'
                : '第 ${state.chapterFor(book.id) + 1} 章',
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _chooseSort(BuildContext context) async {
    final sort = await showGlassMenu<_ShelfSort>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (menuContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (value, label) in [
            (_ShelfSort.recentRead, '最近阅读'),
            (_ShelfSort.recentAdded, '最近加入'),
            (_ShelfSort.title, '书名'),
          ])
            GlassMenuItem(
              order: value.index,
              label: label,
              selected: value == _sort,
              onPressed: () => Navigator.of(menuContext).pop(value),
            ),
        ],
      ),
    );
    if (!mounted || sort == null) return;
    try {
      await state.setShelfView(sort: sort.name);
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '书架排序保存失败，请重试');
    }
  }

  Future<void> _chooseFilter(BuildContext context) async {
    final filter = await showGlassMenu<String>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (menu) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, (value, label)) in [
            ('all', '全部'),
            ('unread', '未读'),
            ('reading', '阅读中'),
            ('finished', '已读完'),
          ].indexed)
            GlassMenuItem(
              order: index,
              label: label,
              selected: state.shelfFilter == value,
              onPressed: () => Navigator.pop(menu, value),
            ),
        ],
      ),
    );
    if (!mounted || filter == null) return;
    try {
      await state.setShelfView(filter: filter);
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '书架筛选保存失败，请重试');
    }
  }

  /// 标签筛选小方片：null 表示全部。
  Widget _tagChip(BuildContext context, String? tagId, String label) {
    final selected = _activeTagId == tagId;
    final tag = tagId == null ? null : TagStore.shared.tagById(tagId);
    final color = tag == null
        ? Theme.of(context).colorScheme.primary
        : tagPalette[tag.colorIndex % tagPalette.length];
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _activeTagId = tagId),
        selectedColor: color.withValues(alpha: .22),
        side: BorderSide(
          color: selected ? color : Theme.of(context).dividerColor,
        ),
      ),
    );
  }

  Future<void> _bookMenu(BuildContext context, int id, {Novel? book}) async {
    final repository = widget.repository;
    final local = repository is CompositeNovelRepository ? repository.local : null;
    final localBook = local?.bookFor(id);
    final action = await showGlassMenu<_ShelfBookAction>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (menuContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassMenuItem(
            label: '移出书架',
            onPressed: () =>
                Navigator.of(menuContext).pop(_ShelfBookAction.removeFromShelf),
          ),
          if (localBook != null)
            GlassMenuItem(
              label: '编辑书籍信息',
              onPressed: () =>
                  Navigator.of(menuContext).pop(_ShelfBookAction.editInfo),
            ),
          if (localBook != null)
            GlassMenuItem(
              label: '删除文件',
              onPressed: () =>
                  Navigator.of(menuContext).pop(_ShelfBookAction.deleteFile),
            ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _ShelfBookAction.removeFromShelf:
        await _removeFromShelf(context, id, book: book);
      case _ShelfBookAction.editInfo:
        if (local != null) await _editShelfBookInfo(context, local, id);
      case _ShelfBookAction.deleteFile:
        if (local != null) await _deleteShelfBookFile(context, local, id);
    }
  }

  Future<void> _removeFromShelf(
    BuildContext context,
    int id, {
    Novel? book,
  }) async {
    if (!state.contains(id)) return;
    final addedAt = state.addedAt(id);
    try {
      await state.setShelfMembership(id, false);
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '书架操作保存失败，请重试');
      return;
    }
    final revision = state.shelfRevision(id);
    if (!mounted) return;
    showNovelFeedback(
      this.context,
      '已移出书架',
      actionLabel: '撤销',
      action: () async {
        if (!state.contains(id) && state.shelfRevision(id) == revision) {
          await state.setShelfMembership(
            id,
            true,
            novel: book,
            restoredAddedAt: addedAt,
          );
        }
      },
    );
  }

  /// 编辑本地书籍的书名/作者；书名变化时重命名源文件（保留原扩展名）。
  Future<void> _editShelfBookInfo(
    BuildContext context,
    LocalLibraryStore local,
    int id,
  ) async {
    final book = local.bookFor(id);
    if (book == null || !context.mounted) return;
    final titleController = TextEditingController(text: book.displayTitle);
    final authorController = TextEditingController(text: book.displayAuthor);
    final result = await showDialog<(String, String)?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final preview = LocalLibraryStore.safeFileNameForTitle(
            book.fileName,
            titleController.text.trim(),
          );
          final willRename =
              preview != null && preview != book.fileName;
          return AlertDialog(
            title: const Text('编辑书籍信息'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: '书名'),
                  onChanged: (_) => setDialogState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: authorController,
                  decoration: const InputDecoration(labelText: '作者'),
                ),
                const SizedBox(height: 12),
                Text(
                  willRename
                      ? '书名修改后，源文件将重命名为：\n$preview'
                      : '修改书名会同步重命名源文件（保留原扩展名）。',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  (titleController.text, authorController.text),
                ),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    titleController.dispose();
    authorController.dispose();
    if (result == null || !mounted) return;
    LocalBook updated;
    try {
      updated = await local.editBookFile(
        id,
        title: result.$1,
        author: result.$2,
      );
    } catch (e) {
      if (context.mounted) {
        showNovelFeedback(context, '保存失败：${_friendlyEditError(e)}');
      }
      return;
    }
    // 同步书架快照里的书名/作者。
    if (state.shelf.contains(id)) {
      try {
        await state.rememberNovel(local.toNovel(updated));
      } catch (_) {}
    }
    if (mounted) showNovelFeedback(context, '已保存');
  }

  /// 二次确认后彻底删除本地书籍的源文件，并清理书架/标签/阅读进度。
  Future<void> _deleteShelfBookFile(
    BuildContext context,
    LocalLibraryStore local,
    int id,
  ) async {
    final book = local.bookFor(id);
    if (book == null || !context.mounted) return;
    final title = book.displayTitle;
    final first = await confirmNovelAction(
      context,
      title: '彻底删除文件？',
      message: '「$title」将从手机存储中彻底删除，书架、标签和阅读进度一并清除。此操作无法撤销。',
      confirmLabel: '继续',
      reduceMotion: state.reduceMotion,
    );
    if (!mounted || !first || !context.mounted) return;
    final second = await confirmNovelAction(
      context,
      title: '再次确认删除',
      message: '这是最后一次确认。文件删除后无法恢复，确定要删除「$title」吗？',
      confirmLabel: '确认删除',
      reduceMotion: state.reduceMotion,
    );
    if (!mounted || !second) return;
    // 删除失败的区分提示与兜底在 _deleteLocalBookWithFallback 内处理；
    // failed 时记录保留，直接返回。
    final deleteResult = await _deleteLocalBookWithFallback(
      context,
      local,
      id,
      reduceMotion: state.reduceMotion,
      state: state,
    );
    if (deleteResult == _DeleteFileResult.failed) return;
    final successText = switch (deleteResult) {
      _DeleteFileResult.recordOnly => '已移出书库「$title」，源文件已保留',
      _DeleteFileResult.recordOnlySourceGone => '已移出书库「$title」',
      _ => '已删除「$title」',
    };
    // 书籍记录已移除：关联数据尽力清理，失败如实提示。
    var cleanupOk = true;
    try {
      await state.setShelfMembership(id, false);
    } catch (_) {
      cleanupOk = false;
    }
    try {
      await TagStore.shared.setTagsForBook(id, const {});
    } catch (_) {
      cleanupOk = false;
    }
    try {
      await state.clearBookProgress(id);
    } catch (_) {
      cleanupOk = false;
    }
    if (!mounted) return;
    showNovelFeedback(
      context,
      cleanupOk ? successText : '书籍已移除，但部分关联数据未清干净，可重启后重试',
    );
  }

  static String _friendlyEditError(Object e) {
    final message = e.toString();
    if (message.contains('书名不能为空')) return '书名不能为空';
    if (message.contains('无法用作文件名')) return '书名无法用作文件名';
    if (message.contains('同名文件已存在')) return '同名文件已存在';
    if (message.contains('书籍不存在')) return '书籍已不存在';
    return '请重试';
  }
}

/// 删除源文件的结果：已彻底删除 / 仅移出书库（源文件保留）/
/// 仅移出书库（源文件已不存在）/ 失败（记录保留）。
enum _DeleteFileResult { deleted, recordOnly, recordOnlySourceGone, failed }

/// 重授权后的统一扫描后处理：关联清理 + 章节迁移任务。
/// 与首页自动扫描、本地书库页走同一套顺序，扫描结果不丢弃。
Future<LocalScanFollowUp> _applyLocalScanAfterReauth(
  LocalLibraryStore local,
  LibraryState? state,
) async {
  final scanResult = await local.scan();
  return applyLocalScanFollowUp<LocalChapterRemap>(
    remaps: scanResult.chapterRemaps,
    cleanupAssociations: () async {
      if (state == null) {
        throw StateError('LibraryState is not available');
      }
      final cleanupIds = await local.peekAssociatedCleanupIds();
      final cleanupDone = <int>[];
      // 异常不能吞掉：已完整处理的 ID 在 finally 里确认，未处理的
      // ID 留待下次重试，异常向上传给 applyLocalScanFollowUp，
      // 使 followUp.handled 为 false、调用方不再继续删除源文件。
      // 单个清理动作本身幂等（移出书架、清空标签、清进度），
      // 已完成的部分不需要回滚。
      try {
        for (final id in cleanupIds) {
          await state.setShelfMembership(id, false);
          await TagStore.shared.setTagsForBook(id, const {});
          await state.clearBookProgress(id);
          cleanupDone.add(id);
        }
      } finally {
        if (cleanupDone.isNotEmpty) {
          await local.confirmAssociatedCleanupIds(cleanupDone);
        }
      }
    },
    migrate: (remap) async {
      if (state == null) {
        throw StateError('LibraryState is not available');
      }
      await state.remapChapterProgress(
        remap.bookId,
        oldChapters: remap.oldChapters,
        newChapters: remap.newChapters,
        migrationId: remap.migrationId,
      );
    },
    confirm: (remap) => local.confirmChapterRemap(remap.migrationId),
    recordFailure: (remap, error) =>
        local.markChapterRemapFailed(remap, error),
    bookIdOf: (remap) => remap.bookId,
  );
}

enum _UnconfirmedDeleteAction { retry, removeRecordOnly }

Future<_UnconfirmedDeleteAction?> _showUnconfirmedDeleteDialog(
  BuildContext context,
) {
  return showDialog<_UnconfirmedDeleteAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('无法确认删除结果'),
      content: const Text(
        '文件提供方未能确认源文件是否已删除。'
        '文件可能暂时离线，或提供方当前无法解析该文件。\n\n'
        '本地记录已保留。请恢复连接、挂载存储或解锁提供方后重试；'
        '也可以仅移出书库，此操作不会删除源文件。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            dialogContext,
            _UnconfirmedDeleteAction.removeRecordOnly,
          ),
          child: const Text('仅移出书库'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            dialogContext,
            _UnconfirmedDeleteAction.retry,
          ),
          child: const Text('重试'),
        ),
      ],
    ),
  );
}

/// 删除源文件；失败时按原生错误码区分处理，不再统一一句「删除失败，请重试」：
/// 无写权限可重新授权文件夹后重试；provider 拒绝/不支持/地址失效时，
/// 可兜底「仅移出书库」；其余错误如实提示。关联数据清理由调用方负责。
Future<_DeleteFileResult> _deleteLocalBookWithFallback(
  BuildContext context,
  LocalLibraryStore local,
  int id, {
  required bool reduceMotion,
  bool canReauth = true,
  LibraryState? state,
}) async {
  try {
    await local.deleteBookFile(id);
    return _DeleteFileResult.deleted;
  } on BookCleanupFailed {
    // 源文件已删、记录保存失败已恢复，可重试（重试时文件不存在视为已删）。
    if (context.mounted) {
      showNovelFeedback(context, '文件已删除，但书籍记录未清干净，请重试');
    }
    return _DeleteFileResult.failed;
  } on LocalDeleteException catch (e) {
    if (!context.mounted) return _DeleteFileResult.failed;
    switch (e.code) {
      case 'permission':
        final choice = await showNovelChoiceSheet(
          context,
          title: '没有删除权限',
          message: canReauth
              ? 'App 当前没有该文件夹的删除（写）权限，无法删除或改名源文件。'
                  '重新授权一次文件夹（仍选原来的文件夹），并在系统授权时确认授予写权限；'
                  '也可以先把这本书移出书库，源文件保留在手机里。'
              : '重新授权后仍无法删除这本书的源文件。'
                  '可以先把这本书移出书库，源文件保留在手机里。',
          choices: [
            if (canReauth) (value: 'reauth', label: '重新授权文件夹'),
            (value: 'recordOnly', label: '仅移出书库（源文件保留）'),
          ],
          reduceMotion: reduceMotion,
        );
        if (choice == 'reauth') {
          if (!context.mounted) return _DeleteFileResult.failed;
          final previousFolder = local.folderUri;
          String? picked;
          try {
            picked = await local.pickFolder();
          } catch (_) {
            // pickFolder 的异常发生在本 catch 块内，外层 catch 捕获不到，
            // 必须就地处理，不能逸出成未捕获异步错误。
            if (context.mounted) {
              showNovelFeedback(context, '重新授权失败，请重试');
            }
            return _DeleteFileResult.failed;
          }
          if (picked == null || !context.mounted) {
            return _DeleteFileResult.failed;
          }
          // 原目录、换目录都走同一套扫描后处理：关联清理 + 迁移任务，
          // 扫描结果不再丢弃，失败不再静默吞掉。
          LocalScanFollowUp followUp;
          try {
            followUp = await _applyLocalScanAfterReauth(local, state);
          } catch (_) {
            if (context.mounted) {
              showNovelFeedback(context, '重新授权未完成，请重试');
            }
            return _DeleteFileResult.failed;
          }
          if (!context.mounted) return _DeleteFileResult.failed;
          if (!followUp.handled) {
            // 关联清理或失败记录本身未完成，不能误报“切换完成”就重试删除。
            showNovelFeedback(
              context,
              '目录选择已返回，但扫描或后续整理未完成；本次未删除源文件，请重新扫描',
            );
            return _DeleteFileResult.failed;
          }
          // 权限以实际查询为准，不凭“重授权成功”就断定写权限已拿到。
          final permission =
              await LocalPlatform.queryTreePermission(picked);
          if (!context.mounted) return _DeleteFileResult.failed;
          final migrationNotice = followUp.failedMigrations == 0
              ? ''
              : '；${followUp.failedMigrations} 本书的阅读进度迁移失败，已记录待重试状态';
          if (picked != previousFolder) {
            // 用户选了别的目录：已完成新文件夹扫描和关联整理，
            // 不再拿旧书 id 盲目重试删除，避免误判与误报。
            showNovelFeedback(
              context,
              '已完成新文件夹扫描和关联整理，原文件未删除$migrationNotice'
              '${permission.persistedWrite ? '' : '；当前只有持久化读取权限，App 暂不能凭此授权删除源文件'}',
            );
            return _DeleteFileResult.failed;
          }
          if (!permission.persistedWrite) {
            showNovelFeedback(
              context,
              '${permission.deletionHint}$migrationNotice',
            );
            return _DeleteFileResult.failed;
          }
          if (followUp.failedMigrations != 0) {
            showNovelFeedback(
              context,
              '${followUp.failedMigrations} 本书的阅读进度迁移失败，已记录待重试状态',
            );
          }
          if (local.bookFor(id) == null) {
            showNovelFeedback(context, '这本书已不在书库中');
            return _DeleteFileResult.failed;
          }
          // 每次用户触发删除，重授权后最多自动重试一次。
          // 若仍失败，显示实际错误，不能再次自动进入重授权循环。
          return _deleteLocalBookWithFallback(
            context,
            local,
            id,
            reduceMotion: reduceMotion,
            canReauth: false,
            state: state,
          );
        }
        if (choice == 'recordOnly') {
          if (!context.mounted) return _DeleteFileResult.failed;
          return _removeBookRecordOnly(context, local, id);
        }
        return _DeleteFileResult.failed;
      case 'unsupported':
      case 'delete_rejected':
        final choice = await showNovelChoiceSheet(
          context,
          title: '这个存储位置不让 App 删除',
          message: '源文件所在的存储不允许 App 删除文件，需要用文件管理器手动删除。'
              '可以先把这本书移出书库，源文件保留在手机里。',
          choices: [(value: 'recordOnly', label: '仅移出书库（源文件保留）')],
          reduceMotion: reduceMotion,
        );
        if (choice == 'recordOnly') {
          if (!context.mounted) return _DeleteFileResult.failed;
          return _removeBookRecordOnly(context, local, id);
        }
        return _DeleteFileResult.failed;
      case 'invalid_uri':
        final choice = await showNovelChoiceSheet(
          context,
          title: '源文件已找不到',
          message: '这本书的源文件可能已被移动或删除，无法再彻底删除。'
              '可以把它的书库记录移出。',
          choices: [(value: 'recordOnly', label: '移出书库记录')],
          reduceMotion: reduceMotion,
        );
        if (choice == 'recordOnly') {
          if (!context.mounted) return _DeleteFileResult.failed;
          // 源文件已不存在，成功文案不写「源文件已保留」。
          return _removeBookRecordOnly(
            context,
            local,
            id,
            successResult: _DeleteFileResult.recordOnlySourceGone,
          );
        }
        return _DeleteFileResult.failed;
      case 'io_error':
        // 无法确认删除结果：保留书籍记录及内部副本，不误报已删。
        // 重试只再次发起原删除操作，由用户每次点击触发，不自动循环。
        final action = await _showUnconfirmedDeleteDialog(context);
        if (action == _UnconfirmedDeleteAction.retry) {
          if (!context.mounted) return _DeleteFileResult.failed;
          return _deleteLocalBookWithFallback(
            context,
            local,
            id,
            reduceMotion: reduceMotion,
            canReauth: canReauth,
            state: state,
          );
        }
        if (action == _UnconfirmedDeleteAction.removeRecordOnly) {
          if (!context.mounted) return _DeleteFileResult.failed;
          return _removeBookRecordOnly(context, local, id);
        }
        return _DeleteFileResult.failed;
      default:
        showNovelFeedback(context, '删除失败，请重试');
        return _DeleteFileResult.failed;
    }
  } catch (_) {
    if (context.mounted) showNovelFeedback(context, '删除失败，请重试');
    return _DeleteFileResult.failed;
  }
}

/// 兜底：仅移出书库（加入忽略名单防再次扫描导入）。
/// [successResult] 区分成功文案：默认源文件保留；源文件已不存在时传
/// [_DeleteFileResult.recordOnlySourceGone]。
Future<_DeleteFileResult> _removeBookRecordOnly(
  BuildContext context,
  LocalLibraryStore local,
  int id, {
  _DeleteFileResult successResult = _DeleteFileResult.recordOnly,
}) async {
  try {
    await local.removeBookRecordOnly(id);
    return successResult;
  } on RecordRemovalPending {
    if (context.mounted) {
      showNovelFeedback(context, '移除状态尚未收尾，请重新扫描或重启以恢复处理');
    }
    return _DeleteFileResult.failed;
  } catch (_) {
    if (context.mounted) showNovelFeedback(context, '移出书库失败，请重试');
    return _DeleteFileResult.failed;
  }
}

enum _ShelfBookAction { removeFromShelf, editInfo, deleteFile }

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.state,
    this.repository,
    this.showHeader = true,
  });
  final LibraryState state;
  final NovelRepository? repository;
  final bool showHeader;

  Widget buildHeader(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: const ArchiveMasthead(title: '设置', code: '03 / SYSTEM PROFILE'),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.settingsChanges,
    builder: (context, child) => GlassHeaderLayout(
      showHeader: showHeader,
      header: buildHeader(context),
      body: ListView(
        key: const PageStorageKey('settings'),
        padding: EdgeInsets.fromLTRB(
          24,
          MediaQuery.paddingOf(context).top + FrostedHeader.toolbarHeight + 20,
          24,
          MediaQuery.paddingOf(context).bottom + 120,
        ),
        children: [
          sectionHeader(context, '阅读偏好', ''),
          const SizedBox(height: 14),
          ContentPanel(
            child: Column(
              children: [
                _appearanceSetting(context),
                const Divider(height: 22),
                Row(
                  children: [
                    const Icon(CupertinoIcons.textformat, size: 21),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '应用字体',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            state.currentFont.displayName,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    GlassTextButton(
                      key: const ValueKey('settings-font-picker'),
                      onPressed: () => _showFontPicker(context),
                      child: const Text('选择'),
                    ),
                  ],
                ),
                const Divider(height: 22),
                ReaderValueSlider(
                  sliderKey: const ValueKey('settings-font-slider'),
                  label: '阅读字号',
                  value: state.fontSize,
                  min: 15,
                  max: 27,
                  divisions: 12,
                  format: (value) => '${value.round()} pt',
                  onCommitted: (value) =>
                      _savePreference(context, () => state.setFontSize(value)),
                ),
                if (LocalPlatform.android)
                  Row(
                    children: [
                      Icon(
                        CupertinoIcons.sun_max,
                        size: 21,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          '阅读时保持亮屏',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      CupertinoSwitch(
                        value: state.keepScreenOn,
                        activeTrackColor: Theme.of(context).colorScheme.primary,
                        onChanged: (value) => _savePreference(
                          context,
                          () => state.setKeepScreenOn(value),
                        ),
                      ),
                    ],
                  ),
                const Divider(height: 13),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        CupertinoIcons.circle_grid_3x3,
                        color: Theme.of(context).colorScheme.primary,
                        size: 21,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          '减少动态效果',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      CupertinoSwitch(
                        value: state.reduceMotion,
                        activeTrackColor: Theme.of(context).colorScheme.primary,
                        onChanged: (value) => _savePreference(
                          context,
                          () => state.setReduceMotion(value),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (repository case final NovelRepository source) ...[
            sectionHeader(context, '阅读记录', ''),
            const SizedBox(height: 14),
            ContentPanel(
              onTap: () => openReadingHistory(context, state, source),
              child: const Row(
                children: [
                  Icon(CupertinoIcons.clock, size: 21),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '阅读历史',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(CupertinoIcons.chevron_right, size: 14),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
          if (repository case final OfflineNovelRepository offline) ...[
            sectionHeader(context, '离线阅读', ''),
            const SizedBox(height: 14),
            ContentPanel(
              onTap: () => pushNovelPage<void>(
                context,
                OfflineCachePage(
                  repository: offline,
                  reduceMotion: state.reduceMotion,
                  onOpen: (pageContext, novel) => openDetail(
                    pageContext,
                    novel,
                    state,
                    offline,
                    fromCache: true,
                  ),
                ),
                reduceMotion: state.reduceMotion,
              ),
              child: const Row(
                children: [
                  Icon(CupertinoIcons.cloud_download, size: 21),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '缓存管理',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(CupertinoIcons.chevron_right, size: 14),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
          sectionHeader(context, '玻璃外观', '实时预览'),
          const SizedBox(height: 14),
          ContentPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _glassSettingLabel(
                  context,
                  '模糊度',
                  '${state.glassBlur.round()}',
                ),
                CupertinoSlider(
                  key: const ValueKey('glass-blur-slider'),
                  value: state.glassBlur,
                  min: 0,
                  max: 24,
                  divisions: 24,
                  activeColor: Theme.of(context).colorScheme.primary,
                  onChanged: (value) =>
                      state.setGlassBlur(value, persist: false),
                  onChangeEnd: state.setGlassBlur,
                ),
                const Divider(height: 22),
                _glassSettingLabel(
                  context,
                  '不透明度',
                  '${(state.glassOpacity * 100).round()}%',
                ),
                CupertinoSlider(
                  key: const ValueKey('glass-opacity-slider'),
                  value: state.glassOpacity,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  activeColor: Theme.of(context).colorScheme.primary,
                  onChanged: (value) =>
                      state.setGlassOpacity(value, persist: false),
                  onChangeEnd: state.setGlassOpacity,
                ),
                GlassTextButton(
                  onPressed: () async {
                    await state.setGlassBlur(8);
                    await state.setGlassOpacity(.87);
                  },
                  child: const Text('恢复默认'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          sectionHeader(context, '本地数据', ''),
          const SizedBox(height: 14),
          ContentPanel(
            key: const ValueKey('settings-backup'),
            onTap: () => pushNovelPage<void>(
              context,
              LibraryBackupPage(state: state),
              reduceMotion: state.reduceMotion,
            ),
            child: const Row(
              children: [
                Icon(CupertinoIcons.folder, size: 21),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '备份与恢复',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(CupertinoIcons.chevron_right, size: 14),
              ],
            ),
          ),
          if (LocalPlatform.android && localLibraryOf(repository) != null) ...[
            const SizedBox(height: 14),
            FeatureEntry(
              key: const ValueKey('settings-local-library'),
              title: '本地书库',
              icon: CupertinoIcons.book,
              subtitle: '选择文件夹，扫描导入 TXT / PDF',
              onTap: () => pushNovelPage<void>(
                context,
                LocalLibraryPage(
                  state: state,
                  local: localLibraryOf(repository)!,
                  repository: repository!,
                ),
                reduceMotion: state.reduceMotion,
              ),
            ),
            const SizedBox(height: 14),
            FeatureEntry(
              key: const ValueKey('settings-tag-manage'),
              title: '标签管理',
              icon: CupertinoIcons.tag,
              subtitle: '新建、重命名或删除书架标签',
              onTap: () => pushNovelPage<void>(
                context,
                TagManagePage(state: state),
                reduceMotion: state.reduceMotion,
              ),
            ),
          ],
          const SizedBox(height: 24),
          sectionHeader(context, '性能与流畅度', ''),
          const SizedBox(height: 14),
          ContentPanel(
            key: const ValueKey('settings-performance'),
            onTap: () => pushNovelPage<void>(
              context,
              LowPerformancePage(state: state),
              reduceMotion: state.reduceMotion,
            ),
            child: const Row(
              children: [
                Icon(CupertinoIcons.speedometer, size: 21),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '低性能设备模式',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(CupertinoIcons.chevron_right, size: 14),
              ],
            ),
          ),
          const SizedBox(height: 24),
          sectionHeader(context, '关于', ''),
          const SizedBox(height: 14),
          FeatureEntry(
            key: const ValueKey('settings-app-update'),
            title: '关于轻小说文库',
            icon: CupertinoIcons.arrow_down_circle,
            subtitle:
                '版本 ${AppUpdatesScope.maybeOf(context)?.installed?.version ?? currentAppVersion}'
                ' · 构建 ${AppUpdatesScope.maybeOf(context)?.installed?.build ?? currentAppBuild}'
                '${AppUpdatesScope.maybeOf(context)?.available == true ? ' · 有新版本' : ''}',
            onTap: () => pushNovelPage<void>(
              context,
              AppUpdatePage(updates: AppUpdatesScope.maybeOf(context)),
              reduceMotion: state.reduceMotion,
            ),
          ),
        ],
      ),
    ),
  );

  /// 应用字体选择：内置字体 + 从手机导入的字体。
  /// SettingsPage 为 StatelessWidget，刷新依赖 state 的通知。
  Future<void> _showFontPicker(BuildContext context) async {
    // 预加载已导入字体以便预览。
    unawaited(state.preloadImportedFonts());
    await showJellySheet<void>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (sheet) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          // 用干净的文本主题包一层，避免“系统字体”预览继承当前自定义字体。
          final baseTheme = Theme.of(sheetContext);
          final cleanTheme = baseTheme.copyWith(
            textTheme: ThemeData(brightness: baseTheme.brightness).textTheme,
          );
          final fonts = state.allFonts;
          // 异步回调后刷新前检查弹层仍在。
          void refreshIfOpen() {
            if (sheetContext.mounted) setSheetState(() {});
          }

          return Theme(
            data: cleanTheme,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '应用字体',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '对整个应用生效（含阅读器）。',
                    style: TextStyle(
                      fontSize: 12,
                      color: cleanTheme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: fonts.length,
                      itemBuilder: (listContext, index) {
                        final font = fonts[index];
                        final selected = state.appFontId == font.id;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            font.displayName,
                            style: TextStyle(
                              // 系统字体 family 为 null，用干净主题的平台默认；
                              // 导入字体缺字时回退到思源宋体。
                              fontFamily: font.family,
                              fontFamilyFallback:
                                  font.source == AppFontSource.imported
                                      ? const ['SourceHanSerifCN']
                                      : null,
                            ),
                          ),
                          subtitle: font.source == AppFontSource.imported
                              ? const Text(
                                  '从手机导入',
                                  style: TextStyle(fontSize: 12),
                                )
                              : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (font.source == AppFontSource.imported)
                                IconButton(
                                  icon:
                                      const Icon(CupertinoIcons.delete, size: 20),
                                  onPressed: () async {
                                    final confirm = await confirmNovelAction(
                                      sheetContext,
                                      title: '删除字体？',
                                      message:
                                          '「${font.displayName}」将从应用中移除。如正在使用，会切回系统字体。',
                                      confirmLabel: '删除',
                                      reduceMotion: state.reduceMotion,
                                    );
                                    if (!confirm || !sheetContext.mounted) {
                                      return;
                                    }
                                    await _savePreference(
                                      sheetContext,
                                      () => state.removeImportedFont(font.id),
                                    );
                                    refreshIfOpen();
                                  },
                                ),
                              if (selected)
                                const Icon(CupertinoIcons.check_mark, size: 20),
                            ],
                          ),
                          onTap: selected
                              ? null
                              : () async {
                                  await _savePreference(
                                    sheetContext,
                                    () => state.setAppFont(font.id),
                                  );
                                  refreshIfOpen();
                                },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  GlassTextButton(
                    onPressed: () => _importFontFromPhone(
                      sheetContext,
                      onDone: refreshIfOpen,
                    ),
                    child: const Text('从手机导入字体文件'),
                  ),
                  const SizedBox(height: 8),
                  GlassTextButton(
                    onPressed: () => Navigator.pop(sheet),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    // 设置页通过 state.settingsChanges 自动刷新，无需 setState。
  }

  /// 从手机选择 TTF/OTF 字体文件并导入，成功后自动应用。
  Future<void> _importFontFromPhone(
    BuildContext context, {
    VoidCallback? onDone,
  }) async {
    String? path;
    try {
      path = await LocalPlatform.pickFontFile();
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '无法打开文件选择器');
      return;
    }
    if (path == null || path.isEmpty) return; // 用户取消
    final fileName = path.split('/').last;
    final displayName = fileName.replaceAll(
      RegExp(r'\.(ttf|otf|ttc)$', caseSensitive: false),
      '',
    );
    try {
      final id = await state.registerImportedFont(path, displayName);
      await state.setAppFont(id);
      onDone?.call();
      if (context.mounted) {
        showNovelFeedback(context, '已应用「$displayName」');
      }
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '字体导入失败，文件可能已损坏');
    }
  }

  Widget _appearanceSetting(BuildContext context) {
    final label = Row(
      children: [
        Icon(
          CupertinoIcons.moon_stars,
          size: 21,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Text('外观模式', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
    final selector = GlassMenuAnchor(
      child: Builder(
        builder: (anchorContext) => LiquidGlass(
          radius: 20,
          elevated: false,
          semanticLabel: '选择外观模式',
          onTap: () => _chooseTheme(anchorContext),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(switch (state.theme) {
                ThemeMode.system => '跟随系统',
                ThemeMode.light => '浅色',
                ThemeMode.dark => '深色',
              }),
              const SizedBox(width: 7),
              const Icon(CupertinoIcons.chevron_down, size: 14),
            ],
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        if (constraints.maxWidth < 160 * scale + 70) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              label,
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerRight, child: selector),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: label),
            const SizedBox(width: 12),
            selector,
          ],
        );
      },
    );
  }

  Widget _glassSettingLabel(
    BuildContext context,
    String title,
    String value,
  ) => Row(
    children: [
      Expanded(
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      Text(
        value,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );

  Future<void> _chooseTheme(BuildContext context) async {
    final selected = await showGlassMenu<ThemeMode>(
      context: context,
      reduceMotion:
          state.reduceMotion || MediaQuery.disableAnimationsOf(context),
      builder: (menuContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (mode, label) in [
            (ThemeMode.system, '跟随系统'),
            (ThemeMode.light, '浅色'),
            (ThemeMode.dark, '深色'),
          ])
            GlassMenuItem(
              order: mode.index,
              selected: state.theme == mode,
              onPressed: () => Navigator.of(menuContext).pop(mode),
              label: label,
            ),
        ],
      ),
    );
    if (selected != null && context.mounted) {
      await _savePreference(context, () => state.setTheme(selected));
    }
  }

  Future<void> _savePreference(
    BuildContext context,
    Future<void> Function() save,
  ) async {
    try {
      await save();
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '设置保存失败，请重试');
    }
  }
}

class InlineSearchResults extends StatelessWidget {
  const InlineSearchResults({
    super.key,
    required this.state,
    required this.repository,
    required this.feed,
    required this.onOpenBook,
    this.onRecall,
  });
  final LibraryState state;
  final NovelRepository repository;
  final NovelFeedController feed;
  final VoidCallback onOpenBook;
  final ValueChanged<String>? onRecall;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: feed,
    builder: (context, _) => LoadedContentSequence(
      generation: feed.resultRevision,
      firstIndex: feed.resultStartIndex == 0 ? 0 : feed.resultStartIndex + 1,
      child: _buildResults(context),
    ),
  );

  Widget _buildResults(BuildContext context) {
    final books = feed.items;
    if (books.isEmpty &&
        feed.query.isEmpty &&
        onRecall != null &&
        state.recentSearches.isNotEmpty) {
      return ListView(
        padding: EdgeInsets.fromLTRB(
          24,
          MediaQuery.paddingOf(context).top + FrostedHeader.toolbarHeight + 20,
          24,
          24,
        ),
        children: [
          RecentSearches(state: state, onRecall: onRecall!),
          if (feed.loading)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Column(children: [BookRowSkeleton(), BookRowSkeleton()]),
            )
          else if (feed.error != null)
            Column(
              children: [
                const Text('推荐载入失败，仍可搜索书名或作者'),
                GlassTextButton(onPressed: feed.retry, child: const Text('重试')),
              ],
            )
          else
            const Text('搜索书名或作者，开始寻找故事。'),
        ],
      );
    }
    if (books.isEmpty && feed.loading) {
      return const SearchSkeleton();
    }
    if (books.isEmpty && feed.error != null) {
      return ContentNotice(
        icon: CupertinoIcons.wifi_exclamationmark,
        title: '搜索失败，请稍后重试',
        onRetry: feed.retry,
      );
    }
    if (books.isEmpty) {
      return const ContentNotice(
        icon: CupertinoIcons.search,
        title: '没有找到相关故事',
        message: '试试更短的书名或作者名',
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            !feed.loading &&
            feed.hasMore &&
            feed.error == null &&
            notification.metrics.extentAfter < 400) {
          WidgetsBinding.instance.addPostFrameCallback((_) => feed.loadMore());
        }
        return false;
      },
      child: FeedRefresh(
        feed: feed,
        child: ListView.builder(
          key: PageStorageKey('inline-search-results-${feed.query}'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            22,
            MediaQuery.paddingOf(context).top +
                FrostedHeader.toolbarHeight +
                20,
            22,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          itemCount: books.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              return LoadedContentItem(
                index: 0,
                child: Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 7),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (feed.query.isEmpty && onRecall != null)
                        RecentSearches(state: state, onRecall: onRecall!),
                      Text(
                        feed.query.isEmpty
                            ? '你可能会喜欢'
                            : '找到 ${feed.totalItems ?? books.length} 个结果',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
            if (index == books.length + 1) return FeedFooter(feed: feed);
            final book = books[index - 1];
            return LoadedContentItem(
              key: ValueKey(book.id),
              index: index,
              child: NovelRow(
                novel: book,
                coverHeroTag: CoverHeroTag(context, book.id),
                onTap: () {
                  onOpenBook();
                  openDetail(
                    context,
                    book,
                    state,
                    repository,
                    coverHeroTag: CoverHeroTag(context, book.id),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class DetailLoaderPage extends StatefulWidget {
  const DetailLoaderPage({
    super.key,
    required this.novel,
    required this.state,
    required this.repository,
    this.coverHeroTag,
  });
  final Novel novel;
  final LibraryState state;
  final NovelRepository repository;
  final Object? coverHeroTag;

  @override
  State<DetailLoaderPage> createState() => _DetailLoaderPageState();
}

class _DetailLoaderPageState extends State<DetailLoaderPage> {
  late Future<Novel> _loaded = _load();
  Novel? _cached;

  @override
  void initState() {
    super.initState();
    unawaited(_seedFromCache());
  }

  Future<void> _seedFromCache() async {
    if (widget.repository case final OfflineNovelRepository offline) {
      try {
        final cached = await offline.cachedBook(widget.novel.id);
        if (mounted && cached != null && cached.chapters.isNotEmpty) {
          setState(() => _cached = cached);
        }
      } catch (_) {
        // Online loading remains available when a local snapshot is damaged.
      }
    }
  }

  Future<Novel> _load() async {
    final detail = await widget.repository.detail(widget.novel);
    final chapters = await widget.repository.chapters(widget.novel.id);
    final loaded = detail.withChapters(chapters);
    await widget.state.rememberNovel(loaded);
    return loaded;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Novel>(
    future: _loaded,
    // Keep the destination cover's element and layout alive from the first
    // route frame through loading, errors and completion of its Hero flight.
    builder: (context, snapshot) => DetailPage(
      novel: snapshot.data ?? _cached ?? widget.novel,
      transitionNovel: widget.novel,
      coverHeroTag: widget.coverHeroTag,
      state: widget.state,
      repository: widget.repository,
      isLoading:
          !snapshot.hasData &&
          _cached == null &&
          snapshot.connectionState != ConnectionState.done,
      loadError: _cached == null ? snapshot.error : null,
      fromCache:
          (_cached != null && !snapshot.hasData) ||
          (widget.repository is OfflineNovelRepository &&
              (widget.repository as OfflineNovelRepository).isDirectoryOffline(
                widget.novel.id,
              )),
      onRetry: () => setState(() {
        _loaded = _load();
      }),
    ),
  );
}

class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.novel,
    required this.state,
    required this.repository,
    this.coverHeroTag,
    this.transitionNovel,
    this.isLoading = false,
    this.loadError,
    this.onRetry,
    this.fromCache = false,
  });
  final Novel novel;
  final LibraryState state;
  final NovelRepository repository;
  final Object? coverHeroTag;
  final Novel? transitionNovel;
  final bool isLoading;
  final Object? loadError;
  final VoidCallback? onRetry;
  final bool fromCache;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: NovelMotion.reveal,
  );
  late final AnimationController _contentIntro = AnimationController(
    vsync: this,
    duration: NovelMotion.reveal,
  );
  Animation<double>? _routeAnimation;
  bool _introStarted = false;
  bool _contentStarted = false;
  bool _readerOpening = false;
  bool _shelfChanging = false;
  int? _resumeChapter;

  /// 当前显示的书籍（编辑后更新，刷新详情页）。
  Novel? _novelOverride;

  Novel get novel => _novelOverride ?? widget.novel;
  LibraryState get state => widget.state;
  NovelRepository get repository => widget.repository;
  Object? get coverHeroTag => widget.coverHeroTag;
  Novel? get transitionNovel => widget.transitionNovel;
  bool get _titleUpdated =>
      transitionNovel != null && transitionNovel!.title != novel.title;
  bool get _authorUpdated =>
      transitionNovel != null && transitionNovel!.author != novel.author;
  bool get isLoading => widget.isLoading;
  Object? get loadError => widget.loadError;
  VoidCallback? get onRetry => widget.onRetry;
  bool get _reduceMotion =>
      state.reduceMotion || MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (_routeAnimation != animation) {
      _routeAnimation?.removeStatusListener(_routeChanged);
      _routeAnimation = animation;
      animation?.addStatusListener(_routeChanged);
    }
    if (_reduceMotion) {
      _intro.stop();
      _contentIntro.stop();
      _intro.value = 1;
      _contentIntro.value = 1;
      _introStarted = true;
      _contentStarted = !isLoading;
    } else if (animation == null ||
        animation.status == AnimationStatus.completed) {
      // A newly installed route's proxy can briefly report completed before
      // Navigator attaches the push animation at the end of its first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startIntro();
      });
    }
  }

  void _routeChanged(AnimationStatus status) {
    if (mounted && status == AnimationStatus.completed) _startIntro();
  }

  void _startIntro() {
    if (_routeAnimation != null &&
        _routeAnimation!.status != AnimationStatus.completed) {
      return;
    }
    if (!_introStarted) {
      _introStarted = true;
      _intro.forward();
    }
    if (!isLoading && !_contentStarted) {
      _contentStarted = true;
      _contentIntro.forward();
    }
  }

  @override
  void didUpdateWidget(DetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (isLoading && !oldWidget.isLoading) {
      _contentStarted = false;
      _contentIntro.value = 0;
    } else if (!isLoading && oldWidget.isLoading) {
      if (_reduceMotion) {
        _contentIntro.value = 1;
        _contentStarted = true;
      } else if (_introStarted) {
        _startIntro();
      }
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_routeChanged);
    _intro.dispose();
    _contentIntro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Resolve a stable chapter ID once for the lazily built directory, not once
    // per visible row or once per animation/scroll frame.
    _resumeChapter = state.hasRead(novel.id) && novel.chapters.isNotEmpty
        ? state.chapterForNovel(novel)
        : null;
    return Scaffold(
      body: Atmosphere(
        child: GlassHeaderLayout(
          header: _header(context),
          body: Stack(
            children: [
              Positioned.fill(
                child: CustomScrollView(
                  key: PageStorageKey('detail-scroll-${novel.id}'),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        MediaQuery.paddingOf(context).top +
                            FrostedHeader.toolbarHeight +
                            12,
                        24,
                        0,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: RepaintBoundary(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  NovelCover(
                                    transitionNovel ?? novel,
                                    width: 118,
                                    height: 166,
                                    heroTag: coverHeroTag,
                                    isDetailCover: true,
                                  ),
                                  const SizedBox(width: 22),
                                  Expanded(
                                    child: Padding(
                                      // Keep the title at its existing landing
                                      // position; the inverse ID plaque belongs
                                      // below the fixed header's blur feather.
                                      padding: const EdgeInsets.only(top: 32),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          RevealFromTop(
                                            key: const ValueKey(
                                              'detail-title-reveal',
                                            ),
                                            axis: ArchiveRevealAxis.horizontal,
                                            animation: _titleUpdated
                                                ? _contentIntro
                                                : _intro,
                                            end: .46,
                                            child: Text(
                                              novel.title,
                                              maxLines: 4,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 23,
                                                height: 1.3,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          RevealFromTop(
                                            key: const ValueKey(
                                              'detail-author-reveal',
                                            ),
                                            axis: ArchiveRevealAxis.horizontal,
                                            animation: _authorUpdated
                                                ? _contentIntro
                                                : _intro,
                                            start: .09,
                                            end: .56,
                                            child:
                                                isLoading &&
                                                    novel.author.trim().isEmpty
                                                ? const InlineSkeleton(
                                                    key: ValueKey(
                                                      'detail-author-skeleton',
                                                    ),
                                                    height: 20,
                                                    label: '正在加载作者信息',
                                                  )
                                                : Text(
                                                    novel.author,
                                                    style: TextStyle(
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                      fontSize: 14,
                                                    ),
                                                  ),
                                          ),
                                          const SizedBox(height: 20),
                                          RevealFromTop(
                                            key: const ValueKey(
                                              'detail-meta-reveal',
                                            ),
                                            axis: ArchiveRevealAxis.horizontal,
                                            animation: isLoading
                                                ? _intro
                                                : _contentIntro,
                                            start: .18,
                                            end: .64,
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                if (isLoading)
                                                  const InlineSkeleton(
                                                    key: ValueKey(
                                                      'detail-meta-skeleton',
                                                    ),
                                                    label: '正在加载章节信息',
                                                  )
                                                else
                                                  Text(
                                                    loadError != null
                                                        ? '目录暂未载入'
                                                        : '${novel.isComplete ? '已完结' : '连载中'}  ·  ${novel.chapters.length} 章',
                                                    style: TextStyle(
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                const SizedBox(height: 8),
                                                ArchiveCode(
                                                  ArchiveDesign.fileCode(
                                                    novel.id,
                                                  ),
                                                  inverse: true,
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (repository
                                              case final OfflineNovelRepository
                                                  offline) ...[
                                            const SizedBox(height: 8),
                                            if (isLoading)
                                              const InlineSkeleton(
                                                key: ValueKey(
                                                  'detail-cache-skeleton',
                                                ),
                                                label: '正在加载缓存信息',
                                              )
                                            else if (loadError == null)
                                              RevealFromTop(
                                                key: const ValueKey(
                                                  'detail-cache-reveal',
                                                ),
                                                axis: ArchiveRevealAxis
                                                    .horizontal,
                                                animation: _contentIntro,
                                                start: .24,
                                                end: .72,
                                                child: OfflineBookStatus(
                                                  repository: offline,
                                                  novel: novel,
                                                  localDirectory:
                                                      widget.fromCache,
                                                ),
                                              )
                                            else
                                              const SizedBox(height: 18),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 35),
                              if (isLoading) ...[
                                const DetailSkeleton(),
                              ] else if (loadError != null) ...[
                                const Center(child: Text('书籍详情加载失败')),
                                Center(
                                  child: GlassTextButton(
                                    onPressed: onRetry,
                                    child: const Text('重试'),
                                  ),
                                ),
                              ] else ...[
                                RevealFromTop(
                                  key: const ValueKey('detail-summary-reveal'),
                                  animation: _contentIntro,
                                  start: .27,
                                  end: .76,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      sectionHeader(context, '简介', ''),
                                      const SizedBox(height: 13),
                                      Text(
                                        novel.summary,
                                        style: TextStyle(
                                          fontSize: 14,
                                          height: 1.75,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 32),
                                RevealFromTop(
                                  key: const ValueKey(
                                    'detail-tags-reveal',
                                  ),
                                  animation: _contentIntro,
                                  start: .35,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      sectionHeader(context, '标签', ''),
                                      const SizedBox(height: 13),
                                      ListenableBuilder(
                                        listenable: TagStore.shared,
                                        builder: (context, _) {
                                          final tags = TagStore.shared
                                              .tagsForBook(novel.id);
                                          return Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: [
                                              for (final tag in tags)
                                                Chip(
                                                  label: Text(tag.name),
                                                  backgroundColor: tagPalette[tag
                                                          .colorIndex %
                                                      tagPalette.length]
                                                  .withValues(alpha: .18),
                                                  side: BorderSide(
                                                    color: tagPalette[tag
                                                            .colorIndex %
                                                        tagPalette.length]
                                                    .withValues(alpha: .5),
                                                  ),
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                ),
                                              ActionChip(
                                                label: Text(
                                                  tags.isEmpty ? '添加标签' : '编辑',
                                                ),
                                                avatar: const Icon(
                                                  CupertinoIcons.tag,
                                                  size: 16,
                                                ),
                                                onPressed: () => showTagEditor(
                                                  context,
                                                  widget.state,
                                                  novel.id,
                                                ),
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 32),
                                RevealFromTop(
                                  key: const ValueKey(
                                    'detail-directory-reveal',
                                  ),
                                  animation: _contentIntro,
                                  start: .43,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      sectionHeader(context, '目录', ''),
                                      const SizedBox(height: 7),
                                      if (novel.chapters.isEmpty)
                                        const Text('暂无章节'),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (!isLoading && loadError == null)
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        // Keep the directory out of a single tall Column: only
                        // visible/cache-nearby rows build, lay out and paint.
                        sliver: SliverList.builder(
                          itemCount: novel.chapters.length,
                          itemBuilder: (context, index) => RevealFromTop(
                            key: ValueKey('detail-chapter-$index'),
                            animation: _contentIntro,
                            start: .48 + index.clamp(0, 8) * .025,
                            end: .78 + index.clamp(0, 8) * .025,
                            child: _chapterRow(context, index),
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: MediaQuery.paddingOf(context).bottom + 96,
                      ),
                    ),
                  ],
                ),
              ),
              const Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: DockUnderlay(),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    22,
                    0,
                    22,
                    MediaQuery.paddingOf(context).bottom + 12,
                  ),
                  child: RevealFromTop(
                    key: const ValueKey('detail-footer-reveal'),
                    animation: _intro,
                    start: .52,
                    child: ArchiveMotionScope(
                      animation: _contentIntro,
                      enabled: !_reduceMotion && loadError == null,
                      child: AnimatedBuilder(
                        animation: state,
                        builder: (context, _) => GlassPillButton(
                          key: const ValueKey('detail-read-button'),
                          icon: CupertinoIcons.book,
                          loading: isLoading,
                          label: _readLabel,
                          onPressed: isLoading
                              ? null
                              : loadError != null
                              ? onRetry
                              : novel.chapters.isEmpty
                              ? null
                              : () => _openReader(
                                  context,
                                  state.chapterForNovel(novel),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _readLabel {
    if (isLoading) return '正在加载目录';
    if (loadError != null) return '重试加载目录';
    if (novel.chapters.isEmpty) return '暂无可读章节';
    final action = state.hasRead(novel.id) ? '继续阅读' : '开始阅读';
    final unit =
        localLibraryOf(repository)?.kindFor(novel.id) == LocalBookKind.pdf
        ? '页'
        : '章';
    return '$action · 第${state.chapterForNovel(novel) + 1}$unit';
  }

  Widget _chapterRow(BuildContext context, int index) => JellyTapSurface(
    onTap: () => _openReader(context, index),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 17),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(
              (index + 1).toString().padLeft(2, '0'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              novel.chapters[index].title,
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
            ),
          ),
          if (index == _resumeChapter) ...[
            const SizedBox(width: 8),
            Text(
              '上次阅读',
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
          ],
          const Icon(CupertinoIcons.chevron_right, size: 14),
        ],
      ),
    ),
  );

  Widget _header(BuildContext context) => Row(
    children: [
      GlassIconButton(
        icon: CupertinoIcons.back,
        label: '返回',
        onPressed: () => Navigator.pop(context),
      ),
      if (repository is OfflineNovelRepository) const SizedBox(width: 46),
      Expanded(
        child: ArchiveRouteTitle(
          title: '图书详情',
          code: ArchiveDesign.fileCode(novel.id),
        ),
      ),
      if (repository case final OfflineNovelRepository offline)
        if (isLoading || loadError != null || novel.chapters.isEmpty)
          const GlassIconButton(
            icon: CupertinoIcons.cloud_download,
            label: '下载与缓存',
            onPressed: null,
          )
        else
          OfflineBookMenu(
            repository: offline,
            novel: novel,
            startChapter: state.chapterForNovel(novel),
            reduceMotion: state.reduceMotion,
          ),
      AnimatedBuilder(
        animation: state,
        builder: (context, child) => GlassIconButton(
          icon: state.contains(novel.id)
              ? CupertinoIcons.bookmark_fill
              : CupertinoIcons.bookmark,
          label: state.contains(novel.id) ? '移出书架' : '加入书架',
          onPressed: () async {
            if (_shelfChanging) return;
            _shelfChanging = true;
            try {
              await state.toggleShelf(novel.id, novel: novel);
            } catch (_) {
              if (context.mounted) showNovelFeedback(context, '书架操作保存失败，请重试');
            } finally {
              _shelfChanging = false;
            }
          },
        ),
      ),
      // 本地书：更多操作（编辑信息、删除文件）。
      if (localLibraryOf(repository)?.bookFor(novel.id) != null)
        GlassIconButton(
          icon: CupertinoIcons.ellipsis,
          label: '更多操作',
          onPressed: () => _detailMenu(context),
        ),
    ],
  );

  /// 详情页的本地书操作菜单：编辑书籍信息、删除文件。
  Future<void> _detailMenu(BuildContext context) async {
    final local = localLibraryOf(repository);
    if (local == null || local.bookFor(novel.id) == null) return;
    final action = await showGlassMenu<String>(
      context: context,
      reduceMotion: state.reduceMotion,
      builder: (menuContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassMenuItem(
            label: '编辑书籍信息',
            onPressed: () =>
                Navigator.of(menuContext).pop('edit'),
          ),
          GlassMenuItem(
            label: '删除文件',
            onPressed: () =>
                Navigator.of(menuContext).pop('delete'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'edit') {
      await _editDetailBookInfo(context, local, novel.id);
    } else if (action == 'delete') {
      await _deleteDetailBookFile(context, local, novel.id);
    }
  }

  /// 编辑书籍信息（详情页版）：复用与书架页相同的对话框逻辑，
  /// 成功后刷新详情页显示。
  Future<void> _editDetailBookInfo(
    BuildContext context,
    LocalLibraryStore local,
    int id,
  ) async {
    final book = local.bookFor(id);
    if (book == null || !context.mounted) return;
    final titleController = TextEditingController(text: book.displayTitle);
    final authorController = TextEditingController(text: book.displayAuthor);
    try {
      final result = await showDialog<(String, String)?>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final preview = LocalLibraryStore.safeFileNameForTitle(
              book.fileName,
              titleController.text.trim(),
            );
            final willRename =
                preview != null && preview != book.fileName;
            return AlertDialog(
              title: const Text('编辑书籍信息'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleController,
                    decoration: const InputDecoration(labelText: '书名'),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  TextField(
                    controller: authorController,
                    decoration: const InputDecoration(labelText: '作者'),
                  ),
                  if (willRename)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '将重命名为：$preview',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(dialogContext).colorScheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(
                    (titleController.text.trim(), authorController.text.trim()),
                  ),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        ),
      );
      if (!mounted || result == null) return;
      final (newTitle, newAuthor) = result;
      if (newTitle.isEmpty) {
        if (context.mounted) showNovelFeedback(context, '书名不能为空');
        return;
      }
      LocalBook updated;
      try {
        updated = await local.editBookFile(
          id,
          title: newTitle,
          author: newAuthor,
        );
      } catch (e) {
        if (context.mounted) {
          showNovelFeedback(context, '保存失败：${e.toString()}');
        }
        return;
      }
      // 同步书架快照里的书名/作者。
      if (state.shelf.contains(id)) {
        try {
          await state.rememberNovel(local.toNovel(updated));
        } catch (_) {}
      }
      if (mounted) {
        showNovelFeedback(context, '已保存');
        // 刷新详情页显示。
        setState(() => _novelOverride = local.toNovel(updated));
      }
    } catch (e) {
      if (context.mounted) {
        showNovelFeedback(context, '保存失败：${e.toString()}');
      }
    } finally {
      titleController.dispose();
      authorController.dispose();
    }
  }

  /// 删除文件（详情页版）：双确认，成功后返回上一页。
  Future<void> _deleteDetailBookFile(
    BuildContext context,
    LocalLibraryStore local,
    int id,
  ) async {
    final book = local.bookFor(id);
    if (book == null || !context.mounted) return;
    final title = book.displayTitle;
    final first = await confirmNovelAction(
      context,
      title: '彻底删除文件？',
      message: '「$title」将从手机存储中彻底删除，书架、标签和阅读进度一并清除。此操作无法撤销。',
      confirmLabel: '继续',
      reduceMotion: state.reduceMotion,
    );
    if (!mounted || !first || !context.mounted) return;
    final second = await confirmNovelAction(
      context,
      title: '再次确认删除',
      message: '这是最后一次确认。文件删除后无法恢复，确定要删除「$title」吗？',
      confirmLabel: '确认删除',
      reduceMotion: state.reduceMotion,
    );
    if (!mounted || !second) return;
    final deleteResult = await _deleteLocalBookWithFallback(
      context,
      local,
      id,
      reduceMotion: state.reduceMotion,
      state: state,
    );
    if (deleteResult == _DeleteFileResult.failed) return;
    final successText = switch (deleteResult) {
      _DeleteFileResult.recordOnly => '已移出书库「$title」，源文件已保留',
      _DeleteFileResult.recordOnlySourceGone => '已移出书库「$title」',
      _ => '已删除「$title」',
    };
    var cleanupOk = true;
    try {
      await state.setShelfMembership(id, false);
    } catch (_) {
      cleanupOk = false;
    }
    try {
      await TagStore.shared.setTagsForBook(id, const {});
    } catch (_) {
      cleanupOk = false;
    }
    try {
      await state.clearBookProgress(id);
    } catch (_) {
      cleanupOk = false;
    }
    if (!mounted) return;
    // 文件已删，详情页无意义，返回上一页。
    // pop 前先取到 ScaffoldMessenger：pop 后再用 context 找 messenger，
    // 可能拿到正在退场路由的，反馈挂上去用户看不到；
    // 也不依赖"pop 后 context 仍 mounted"这一时序。
    final messenger =
        context.mounted ? ScaffoldMessenger.maybeOf(context) : null;
    if (context.mounted) Navigator.of(context).pop();
    messenger
      ?..hideCurrentSnackBar()
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            cleanupOk ? successText : '书籍已移除，但部分关联数据未清干净',
          ),
        ),
      );
  }

  Future<void> _openReader(BuildContext context, int chapter) async {
    if (_readerOpening || !mounted || !context.mounted) return;
    _readerOpening = true;
    try {
      final local = localLibraryOf(repository);
      final Widget page = local != null &&
              local.kindFor(novel.id) == LocalBookKind.pdf
          ? LocalPdfReaderPage(novel: novel, state: state, local: local)
          : ReaderPage(
              novel: novel,
              state: state,
              repository: repository,
              initialChapter: chapter,
            );
      await pushNovelPage<void>(
        context,
        page,
        reduceMotion: state.reduceMotion,
      );
    } finally {
      _readerOpening = false;
      // Reader exit persists its final anchor without broadcasting scroll
      // changes. Refresh the label and directory marker once, without replay.
      if (mounted) setState(() {});
    }
  }
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.novel,
    required this.state,
    required this.repository,
    required this.initialChapter,
  });
  final Novel novel;
  final LibraryState state;
  final NovelRepository repository;
  final int initialChapter;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late int _chapter = widget.novel.chapters.isEmpty
      ? 0
      : widget.initialChapter.clamp(0, widget.novel.chapters.length - 1);
  late Future<({ReaderContent? content, Object? error})> _content;
  ReaderContent? _currentContent;
  bool _illustrationsRefreshing = false;
  final _findMatch = ValueNotifier<ReaderMatch?>(null);
  final _bookmarkLanding = ValueNotifier<int?>(null);
  Timer? _bookmarkLandingTimer;
  bool _bookmarkLandingPending = false;
  Timer? _highlightTimer;
  // Stable chapter IDs/paragraph anchors own restoration; do not also walk
  // PageStorage and persist the viewport on every interrupted fling.
  final _scroll = ScrollController(keepScrollOffset: false);
  late final _followScroll = ReaderFollowScroll(_scroll);
  final _paragraphRegistry = ReaderParagraphRegistry();
  // 阅读进度条：章节字数权重 + 章内滚动比例。
  List<int> _chapterWeights = const [];
  int _totalWeight = 0;
  double _progressValue = 0;
  bool _progressDragging = false;
  double _dragValue = 0;
  // 拖拽 accepted 后底层指针取消可能走 onEnd 而非 onCancel，
  // 用该标记区分"取消却进了 onEnd"，避免误提交跳转。
  bool _progressPointerCancelled = false;
  ReadingPosition? _restorePending;
  bool _restoreQueued = false;
  bool _restoring = false;
  bool _ready = false;
  int _paragraphCount = 0;
  bool _saveQueued = false;
  Timer? _idleSave;
  bool _catalogueOpen = false;
  bool _toolsOpen = false;
  bool _findOpen = false;
  bool _listeningOpen = false;
  ListeningController? _listening;
  (int, int, int, int)? _listeningTarget;
  String? _listeningError;
  int _followTicket = 0;
  bool _followLocallyPaused = false;
  bool _followAutomatic = false;
  int _restoreTicket = 0;
  double _layoutWidth = 0;
  String _layoutFontId = 'system';
  bool _typographyPreviewing = false;
  double _layoutTextScale = 1;
  double _readingInset = 0;
  int _contentGeneration = 0;
  late final AnimationController _chapterReveal;
  bool _chapterRevealPending = false;
  int _chapterRevealFirst = 0;
  late final AnimationController _chrome;
  bool _chromeTarget = true;

  @override
  void initState() {
    super.initState();
    _computeChapterWeights();
    _scroll.addListener(_updateProgressFromScroll);
    _chapterReveal = AnimationController(
      vsync: this,
      duration: NovelMotion.enter,
      value: 1,
    );
    _chrome = AnimationController(
      vsync: this,
      duration: NovelMotion.contact,
      reverseDuration: NovelMotion.exit,
      value: 1,
    );
    WidgetsBinding.instance.addObserver(this);
    final saved = widget.state.positionFor(widget.novel.id);
    if (saved != null &&
        widget.novel.chapters.isNotEmpty &&
        (saved.chapterId > 0
            ? saved.chapterId == widget.novel.chapters[_chapter].id
            : saved.chapter == _chapter)) {
      _restorePending = saved;
    }
    _content = _loadContent();
  }

  @override
  void deactivate() {
    // The Scrollable child detaches its controller before this State's dispose.
    // Capture while it is still attached, also when idle-save is pending.
    _idleSave?.cancel();
    _followTicket++;
    _followScroll.cancel();
    _savePosition(notify: false, finalSave: true);
    super.deactivate();
  }

  @override
  void dispose() {
    _idleSave?.cancel();
    _savePosition(notify: false, finalSave: true);
    _highlightTimer?.cancel();
    _findMatch.dispose();
    _bookmarkLandingTimer?.cancel();
    _bookmarkLanding.dispose();
    _listening?.snapshot.removeListener(_listeningChanged);
    _followTicket++;
    _followScroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    _chapterReveal.dispose();
    _chrome.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final listening = ListeningScope.maybeOf(context);
    if (listening != _listening) {
      _listening?.snapshot.removeListener(_listeningChanged);
      _listening = listening;
      listening?.snapshot.addListener(_listeningChanged);
      _listeningTarget = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _listeningChanged();
      });
    } else if (listening != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _listeningChanged();
      });
    }
    if (!_ready || _restoring || _layoutWidth <= 0) return;
    final media = MediaQuery.of(context);
    final scale =
        media.textScaler.scale(widget.state.fontSize) / widget.state.fontSize;
    if ((media.size.width - _layoutWidth).abs() >= 1 ||
        (scale - _layoutTextScale).abs() >= .01 ||
        _layoutFontId != widget.state.appFontId) {
      final position = _currentPosition();
      if (position != null) _prepareRestore(position);
    }
  }

  Future<void> _listen() async {
    final listening = _listening;
    if (listening == null ||
        _listeningOpen ||
        _toolsOpen ||
        _catalogueOpen ||
        _findOpen) {
      return;
    }
    _listeningOpen = true;
    _followTicket++;
    _followScroll.cancel();
    try {
      await showListeningPanel(
        context,
        controller: listening,
        novel: widget.novel,
        chapter: _chapter,
        paragraph: _currentPosition()?.paragraphIndex ?? 0,
        reduceMotion: widget.state.reduceMotion,
      );
    } finally {
      _listeningOpen = false;
      _listeningTarget = null;
      if (mounted) _listeningChanged();
    }
  }

  void _suspendListeningFollow({bool userDrag = false}) {
    final listening = _listening;
    _followTicket++;
    _followScroll.cancel(userDrag: userDrag);
    if (listening != null &&
        listening.snapshot.value.active &&
        listening.snapshot.value.novel?.id == widget.novel.id &&
        listening.snapshot.value.follow) {
      _followLocallyPaused = true;
      unawaited(listening.setFollow(false).catchError((Object _) {}));
    }
  }

  void _listeningChanged() {
    final state = _listening?.snapshot.value;
    final current = state?.current;
    if (state?.error == null) _listeningError = null;
    if (mounted &&
        state?.novel?.id == widget.novel.id &&
        state?.error != null &&
        state!.error != _listeningError) {
      final error = _listeningError = state.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !_listeningOpen &&
            ModalRoute.of(context)?.isCurrent != false &&
            _listening?.snapshot.value.error == error) {
          showNovelFeedback(
            context,
            error!,
            actionLabel: '听书',
            action: _listen,
          );
        }
      });
    }
    if (state == null || !state.active || !state.follow) {
      _followLocallyPaused = false;
    }
    if (state == null ||
        !state.active ||
        state.novel?.id != widget.novel.id ||
        !_listeningScrollSceneActive) {
      _listeningTarget = null;
      _followTicket++;
      _followScroll.cancel();
      return;
    }
    if (!state.follow || _followLocallyPaused || current == null) {
      _listeningTarget = null;
      if (_followAutomatic) {
        _followTicket++;
        _followScroll.cancel();
        _followAutomatic = false;
      }
      return;
    }
    final target = (
      widget.novel.id,
      state.chapter,
      current.paragraph,
      current.start,
    );
    if (_listeningTarget == target) return;
    _listeningTarget = target;
    if (state.chapter != _chapter) _go(state.chapter, listeningFollow: true);
    _revealListeningFragment(
      state.chapter,
      current.paragraph,
      current.start,
      current.end,
      automatic: true,
    );
  }

  bool get _listeningScrollSceneActive =>
      mounted &&
      !_listeningOpen &&
      !_toolsOpen &&
      !_catalogueOpen &&
      !_findOpen &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) &&
      ModalRoute.of(context)?.isCurrent != false;

  void _revealListeningFragment(
    int chapter,
    int paragraph,
    int start,
    int end, {
    required bool automatic,
  }) {
    final ticket = ++_followTicket;
    _followAutomatic = automatic;
    _followScroll.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool allowed() =>
          _listeningScrollSceneActive &&
          ticket == _followTicket &&
          _chapter == chapter &&
          _listening?.snapshot.value.active == true &&
          _listening?.snapshot.value.novel?.id == widget.novel.id &&
          (!automatic ||
              (_listening?.snapshot.value.follow == true &&
                  !_followLocallyPaused));
      if (!allowed()) return;
      try {
        await _followScroll.reveal(
          allowed: allowed,
          reduceMotion:
              widget.state.reduceMotion ||
              MediaQuery.disableAnimationsOf(context),
          target: () =>
              !_ready ||
                  _restoring ||
                  _restorePending != null ||
                  !_scroll.hasClients
              ? null
              : _paragraphRegistry.speechTarget(
                  paragraph,
                  start,
                  end,
                  _readingInset,
                  viewportBottom:
                      _scroll.position.viewportDimension -
                      MediaQuery.paddingOf(context).bottom -
                      116,
                  trailingSpace: 12,
                ),
        );
      } finally {
        if (ticket == _followTicket) _followAutomatic = false;
      }
    });
    // Adding a post-frame callback alone does not request a frame. In a static
    // chapter or after resuming, explicitly wake the one requested landing.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _doubleTapListeningParagraph(int paragraph) async {
    final listening = _listening;
    if (listening == null) return;
    final state = listening.snapshot.value;
    final other =
        state.active &&
        state.novel?.id == widget.novel.id &&
        (state.chapter != _chapter || state.current?.paragraph != paragraph);
    final action = listening.paragraphDoubleTap(
      novelId: widget.novel.id,
      chapter: _chapter,
      paragraph: paragraph,
    );
    // An explicit double-tap is a one-off soft landing even after a manual
    // scroll suspended following. It never flips the user's follow preference.
    if (other &&
        (!state.follow || _followLocallyPaused) &&
        _currentContent != null) {
      final text = _currentContent!.paragraphs[paragraph];
      _revealListeningFragment(
        _chapter,
        paragraph,
        0,
        text.length.clamp(0, 240),
        automatic: false,
      );
    }
    await action;
  }

  /// 计算每章的字数权重（去空白字符数），用于全书进度。
  void _computeChapterWeights() {
    // 本地书的 NovelChapter.content 为空（正文懒加载），不能用它算字数：
    // TXT 用章节索引的 length 做权重，PDF 按页等权；在线书才用 content 长度。
    final local = localLibraryOf(widget.repository)?.bookFor(widget.novel.id);
    if (local != null) {
      if (local.kind == LocalBookKind.pdf) {
        _chapterWeights =
            List.filled(widget.novel.chapters.length, 1);
      } else {
        _chapterWeights = [for (final c in local.chapters) c.length];
      }
    } else {
      final chapters = widget.novel.chapters;
      _chapterWeights = [
        for (final c in chapters)
          c.content.replaceAll(RegExp(r'\s'), '').length,
      ];
    }
    _totalWeight = _chapterWeights.fold(0, (a, b) => a + b);
  }

  /// 章内滚动比例（0~1）。
  double get _chapterScrollRatio {
    if (!_scroll.hasClients) return 0;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return 0;
    return (_scroll.offset / max).clamp(0.0, 1.0);
  }

  /// 全书进度（0~1）：前面章节权重 + 当前章权重 × 章内比例。
  double _bookProgress() {
    if (_totalWeight <= 0 || _chapterWeights.isEmpty) return 0;
    var before = 0;
    for (var i = 0; i < _chapter && i < _chapterWeights.length; i++) {
      before += _chapterWeights[i];
    }
    final current = _chapter < _chapterWeights.length
        ? _chapterWeights[_chapter]
        : 0;
    return ((before + current * _chapterScrollRatio) / _totalWeight)
        .clamp(0.0, 1.0);
  }

  /// 滚动时更新进度条（拖动中不跟随，避免打架）。
  void _updateProgressFromScroll() {
    if (_progressDragging) return;
    final v = _bookProgress();
    if ((v - _progressValue).abs() > 0.0005) {
      setState(() => _progressValue = v);
    }
  }

  /// 进度条是否显示：多章，或单章可滚动时显示。
  bool get _showProgressBar {
    if (widget.novel.chapters.length > 1) return true;
    return _scroll.hasClients && _scroll.position.maxScrollExtent > 0;
  }

  /// 把全书进度换算为目标章节和章内比例。
  ({int chapter, double ratio}) _progressToTarget(double progress) {
    if (_chapterWeights.isEmpty || _totalWeight <= 0) {
      return (chapter: 0, ratio: 0);
    }
    var target = (progress * _totalWeight).clamp(0, _totalWeight.toDouble());
    for (var i = 0; i < _chapterWeights.length; i++) {
      final w = _chapterWeights[i];
      if (target <= w || i == _chapterWeights.length - 1) {
        final ratio = w > 0 ? (target / w).clamp(0.0, 1.0) : 0.0;
        return (chapter: i, ratio: ratio);
      }
      target -= w;
    }
    return (chapter: _chapterWeights.length - 1, ratio: 1);
  }

  /// 拖动结束：跳转到目标位置。
  Future<void> _jumpToProgress(double progress) async {
    final target = _progressToTarget(progress);
    if (target.chapter != _chapter) {
      _go(target.chapter);
      // 等新章节布局完成后再滚动：用 postFrame 回调链等待有内容尺寸。
      // 每次重试前 scheduleFrame 确保下一帧会被调度，避免回调链 stall；
      // 另有独立 Timer 兜底：应用暂停、无帧可调度时也能结束等待，
      // 不依赖"回调里检查 DateTime"这条本身就需要帧的路径。
      // Stopwatch 而非 DateTime，避免系统时间调整影响。
      final done = Completer<void>();
      final stopwatch = Stopwatch()..start();
      final watchdog = Timer(const Duration(seconds: 2), () {
        if (!done.isCompleted) done.complete();
      });
      void waitForLayout() {
        if (done.isCompleted) return;
        if (!mounted || stopwatch.elapsed >= const Duration(seconds: 2)) {
          if (!done.isCompleted) done.complete();
          return;
        }
        if (_scroll.hasClients && _scroll.position.hasContentDimensions) {
          done.complete();
          return;
        }
        // 确保下一帧被调度，否则回调链可能停住。
        SchedulerBinding.instance.scheduleFrame();
        WidgetsBinding.instance.addPostFrameCallback((_) => waitForLayout());
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => waitForLayout());
      try {
        await done.future;
      } finally {
        watchdog.cancel();
        stopwatch.stop();
      }
    }
    if (!mounted) return;
    // 超时/卸载也会结束等待，此时布局可能仍不可用，必须再检查。
    if (_scroll.hasClients && _scroll.position.hasContentDimensions) {
      final max = _scroll.position.maxScrollExtent;
      if (max > 0) {
        _scroll.jumpTo((target.ratio * max).clamp(0.0, max));
      }
    }
    _updateProgressFromScroll();
  }

  /// 拖动预览文字：第 N 章 · X%。
  String _dragPreviewText(double progress) {
    final target = _progressToTarget(progress);
    final pct = (progress * 100).round();
    return '第 ${target.chapter + 1} 章 · $pct%';
  }

  void _go(
    int index, {
    ReadingPosition? position,
    bool highlightBookmark = false,
    bool listeningFollow = false,
  }) {
    if (index < 0 || index >= widget.novel.chapters.length) {
      return;
    }
    if (!listeningFollow) _suspendListeningFollow();
    _clearBookmarkLanding();
    _bookmarkLandingPending = highlightBookmark;
    if (highlightBookmark) {
      _highlightTimer?.cancel();
      _findMatch.value = null;
    }
    if (index == _chapter) {
      if (position == null) return;
      _prepareRestore(position);
      setState(() {});
      return;
    }
    _idleSave?.cancel();
    _savePosition(notify: false);
    _highlightTimer?.cancel();
    _findMatch.value = null;
    _currentContent = null;
    _illustrationsRefreshing = false;
    _ready = false;
    _restorePending = position;
    _restoreQueued = false;
    _restoring = false;
    _restoreTicket++;
    setState(() {
      _chapter = index;
      _content = _loadContent();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    // 章节切换后刷新进度条（新章节从头开始）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _progressValue = _bookProgress());
    });
  }

  Future<void> _catalogue() async {
    if (_catalogueOpen ||
        _listeningOpen ||
        _toolsOpen ||
        _findOpen ||
        widget.novel.chapters.isEmpty) {
      return;
    }
    _catalogueOpen = true;
    _followTicket++;
    _followScroll.cancel();
    try {
      final index = await showJellySheet<int>(
        context: context,
        reduceMotion: widget.state.reduceMotion,
        builder: (context) => ReaderCatalogue(
          novel: widget.novel,
          currentChapter: _chapter,
          cache: widget.repository is OfflineNovelRepository
              ? (widget.repository as OfflineNovelRepository).cache
              : null,
        ),
      );
      if (mounted && index != null) _go(index);
    } finally {
      _catalogueOpen = false;
      _listeningTarget = null;
      if (mounted) _listeningChanged();
    }
  }

  Future<({ReaderContent? content, Object? error})> _loadContent({
    bool refresh = false,
  }) async {
    final index = _chapter;
    final generation = ++_contentGeneration;
    _chapterRevealPending = false;
    _chapterReveal.value = 1;
    // Picker results can arrive between frames. Carry expected request failure
    // as data, rather than an exceptional future awaiting the next UI listener.
    try {
      final content = await ReaderContent.parse(
        await _requestContent(index, refresh: refresh),
      );
      if (mounted && index == _chapter && generation == _contentGeneration) {
        _currentContent = content;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _contentGeneration) {
            _listeningTarget = null;
            _listeningChanged();
            if (content.paragraphs.any((p) => p.trim() == '[插图]') &&
                widget.repository is OfflineNovelRepository) {
              unawaited(_refreshIllustrations(automatic: true));
            }
          }
        });
        final reduce =
            widget.state.reduceMotion ||
            MediaQuery.disableAnimationsOf(context);
        if (reduce) {
          _chapterReveal.value = 1;
        } else {
          _chapterRevealPending = true;
          _chapterReveal.value = 0;
        }
      }
      return (content: content, error: null);
    } catch (error) {
      if (mounted && generation == _contentGeneration) _showChrome(true);
      return (content: null, error: error);
    }
  }

  void _showChrome(bool visible) {
    _chromeTarget = visible;
    if (widget.state.reduceMotion || MediaQuery.disableAnimationsOf(context)) {
      _chrome.value = visible ? 1 : 0;
    } else if (visible) {
      _chrome.forward();
    } else {
      _chrome.reverse();
    }
  }

  void _revealChapter() {
    if (!_chapterRevealPending || !_ready || !_scroll.hasClients) return;
    _chapterRevealPending = false;
    // Reveal the restored viewport, not offscreen paragraphs at chapter start.
    // The anchor render objects remain outside the visual transform so saving,
    // typography changes and lazy restoration keep the same coordinates.
    final first =
        _paragraphRegistry.capture(_scroll.offset + _readingInset)?.index ?? 0;
    if (_chapterRevealFirst != first) {
      setState(() => _chapterRevealFirst = first);
    }
    if (widget.state.reduceMotion || MediaQuery.disableAnimationsOf(context)) {
      _chapterReveal.value = 1;
    } else {
      _chapterReveal.forward(from: 0);
    }
  }

  void _toggleChrome() {
    if (_ready &&
        !_toolsOpen &&
        !_catalogueOpen &&
        !_findOpen &&
        !_listeningOpen) {
      _showChrome(!_chromeTarget);
    }
  }

  void _pageBy(int direction) {
    if (!_ready ||
        !_scroll.hasClients ||
        _toolsOpen ||
        _catalogueOpen ||
        _listeningOpen ||
        _findOpen) {
      return;
    }
    _suspendListeningFollow();
    final position = _scroll.position;
    final target =
        (position.pixels +
                direction *
                    (position.viewportDimension - _readingInset - 100).clamp(
                      80.0,
                      double.infinity,
                    ))
            .clamp(0.0, position.maxScrollExtent);
    if (widget.state.reduceMotion || MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: NovelMotion.contact,
        curve: NovelMotion.ease,
      );
    }
  }

  Future<String> _requestContent(int index, {bool refresh = false}) async {
    if (widget.novel.chapters.isEmpty) throw const FormatException('目录为空');
    if (widget.repository case final OfflineNovelRepository offline) {
      await offline.rememberDirectory(widget.novel);
      if (refresh) {
        return offline.refreshChapterContent(
          widget.novel.id,
          widget.novel.chapters[index],
        );
      }
    }
    return widget.repository.chapterContent(
      widget.novel.id,
      widget.novel.chapters[index],
    );
  }

  Future<void> _refreshIllustrations({bool automatic = false}) async {
    if (_illustrationsRefreshing) return;
    final chapter = _chapter;
    final generation = _contentGeneration;
    setState(() => _illustrationsRefreshing = true);
    try {
      final body = automatic
          ? await (widget.repository as OfflineNovelRepository)
                .repairChapterIllustrations(
                  widget.novel.id,
                  widget.novel.chapters[chapter],
                )
          : await _requestContent(chapter, refresh: true);
      if (body == null) return;
      final content = await ReaderContent.parse(body);
      if (!mounted || chapter != _chapter || generation != _contentGeneration) {
        return;
      }
      final position = _currentPosition();
      if (position != null) _prepareRestore(position);
      setState(() {
        _currentContent = content;
        _content = Future.value((content: content, error: null));
      });
    } catch (_) {
      if (!automatic && mounted && chapter == _chapter) {
        showNovelFeedback(context, '插图暂未更新成功，正文已保留，可稍后重试');
      }
    } finally {
      if (mounted && generation == _contentGeneration) {
        setState(() => _illustrationsRefreshing = false);
      }
    }
  }

  Widget _paragraphContent(
    List<String> paragraphs,
    int index,
    TextStyle style,
  ) {
    final url = readerIllustrationUrl(paragraphs[index]);
    if (url != null) {
      return ReaderIllustration(
        url: url,
        onOpen: () => pushNovelPage<void>(
          context,
          ReaderIllustrationGallery(
            urls: _currentContent!.illustrations,
            initialUrl: url,
          ),
          reduceMotion: widget.state.reduceMotion,
        ),
      );
    }
    if (paragraphs[index].trim() == '[插图]') {
      // Match the loaded image's extent: replacing a URL-less slot must not
      // collapse/expand the article while the user keeps reading below it.
      return SizedBox(
        height: (MediaQuery.sizeOf(context).width - 52) * 4 / 3,
        child: _illustrationsRefreshing
            ? const LoadingSkeleton(
                layout: SkeletonLayout.cover,
                label: '正在补全插图',
              )
            : ContentPanel(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(CupertinoIcons.photo),
                      const SizedBox(height: 10),
                      const Text('暂未取得本章插图地址'),
                      GlassTextButton(
                        onPressed: _refreshIllustrations,
                        child: const Text('重试本章插图'),
                      ),
                    ],
                  ),
                ),
              ),
      );
    }
    return ReaderHighlightText(
      text: paragraphs[index],
      index: index,
      match: _findMatch,
      style: style,
    );
  }

  @override
  void didChangeMetrics() {
    if (!mounted || !_ready || _restoring) return;
    final view = View.of(context);
    final width = view.physicalSize.width / view.devicePixelRatio;
    if ((width - _layoutWidth).abs() < 1) return;
    final position = _currentPosition();
    if (position != null) _prepareRestore(position);
  }

  @override
  void didChangeTextScaleFactor() {
    if (!mounted) return;
    final position = _currentPosition();
    if (position != null) _prepareRestore(position);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _idleSave?.cancel();
      _savePosition(notify: false);
    }
    _followTicket++;
    _followScroll.cancel();
    _listeningTarget = null;
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _listeningChanged();
      });
    }
  }

  void _saveWhenIdle() {
    _idleSave?.cancel();
    if (_restoring) return;
    final generation = _contentGeneration;
    _idleSave = Timer(const Duration(milliseconds: 160), () {
      _idleSave = null;
      if (mounted &&
          generation == _contentGeneration &&
          _scroll.hasClients &&
          !_scroll.position.isScrollingNotifier.value) {
        _savePosition(notify: false);
      }
    });
  }

  void _savePosition({bool notify = true, bool finalSave = false}) {
    // Explicit save/restore/exit supersedes any delayed copy of that position.
    _idleSave?.cancel();
    _idleSave = null;
    if (!_ready ||
        _restoring ||
        !_scroll.hasClients ||
        (_typographyPreviewing && !finalSave)) {
      return;
    }
    // Lazy slivers can emit a scroll-end while correcting their estimated
    // extent during layout. Persist after that frame, not from inside layout.
    final duringLayout =
        WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks;
    if (duringLayout && !finalSave) {
      if (!_saveQueued) {
        _saveQueued = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _saveQueued = false;
          if (mounted) _savePosition(notify: notify);
        });
      }
      return;
    }
    final position = _currentPosition(includeParagraph: !duringLayout);
    unawaited(
      widget.state
          .savePosition(
            novel: widget.novel,
            chapter: _chapter,
            offset: position?.offset ?? _scroll.offset,
            maximum: _scroll.position.maxScrollExtent,
            width: _layoutWidth,
            notify: notify,
            paragraphIndex: position?.paragraphIndex,
            paragraphFraction: position?.paragraphFraction ?? 0,
            textScale: _textScale,
            typeface: position?.typeface ?? _layoutFontId,
          )
          .catchError((Object _) {}),
    );
  }

  double get _textScale => _layoutTextScale;

  ReadingPosition? _currentPosition({
    bool includeParagraph = true,
    bool bookmark = false,
  }) {
    if (!_ready ||
        _restoring ||
        !_scroll.hasClients ||
        widget.novel.chapters.isEmpty) {
      return null;
    }
    final maximum = _scroll.position.maxScrollExtent;
    final offset = _scroll.offset.clamp(
      0.0,
      maximum.clamp(0.0, double.infinity),
    );
    var paragraph =
        includeParagraph && (bookmark || offset > .5 && offset < maximum - .5)
        ? _paragraphRegistry.capture(
            offset + _readingInset,
            clampToLast: bookmark,
          )
        : null;
    if (!includeParagraph) {
      // A route can be disposed inside layout, where reading RenderBox sizes
      // is invalid. Retain an already measured anchor only for the exact same
      // chapter, offset and geometry; otherwise keep the raw-offset fallback.
      final previous = widget.state.positionFor(widget.novel.id);
      if (previous != null &&
          previous.paragraphIndex != null &&
          previous.chapter == _chapter &&
          previous.chapterId == widget.novel.chapters[_chapter].id &&
          (previous.offset - offset).abs() < .5 &&
          previous.fontSize == widget.state.fontSize &&
          previous.lineHeight == widget.state.lineHeight &&
          previous.typeface == _layoutFontId &&
          (previous.width - _layoutWidth).abs() < .5 &&
          (previous.textScale - _textScale).abs() < .01) {
        paragraph = (
          index: previous.paragraphIndex!,
          fraction: previous.paragraphFraction,
        );
      }
    }
    return ReadingPosition(
      chapter: _chapter,
      chapterId: widget.novel.chapters[_chapter].id,
      offset: offset,
      fraction: maximum > 0 ? (offset / maximum).clamp(0, 1) : 0,
      fontSize: widget.state.fontSize,
      lineHeight: widget.state.lineHeight,
      width: _layoutWidth,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      paragraphIndex: paragraph?.index,
      paragraphFraction: paragraph?.fraction ?? 0,
      textScale: _textScale,
      typeface: _layoutFontId,
    );
  }

  void _prepareRestore(ReadingPosition position) {
    _restorePending = position;
    _restoreQueued = false;
    _restoring = true;
    _restoreTicket++;
  }

  void _clearBookmarkLanding() {
    _bookmarkLandingTimer?.cancel();
    _bookmarkLandingPending = false;
    _bookmarkLanding.value = null;
  }

  void _landBookmark(ReadingPosition? saved, {int? paragraphIndex}) {
    if (!_bookmarkLandingPending || !_scroll.hasClients) return;
    _bookmarkLandingPending = false;
    final savedIndex = paragraphIndex ?? saved?.paragraphIndex;
    final index =
        savedIndex != null && savedIndex >= 0 && savedIndex < _paragraphCount
        ? savedIndex
        : _paragraphRegistry.capture(_scroll.offset + _readingInset)?.index ??
              0;
    if (index >= _paragraphCount) return;
    _bookmarkLanding.value = index;
    _bookmarkLandingTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) _bookmarkLanding.value = null;
    });
  }

  void _applyTypography({
    double? fontSize,
    double? lineHeight,
    bool persist = true,
  }) {
    final font = fontSize ?? widget.state.fontSize;
    final spacing = lineHeight ?? widget.state.lineHeight;
    if (font == widget.state.fontSize && spacing == widget.state.lineHeight) {
      if (persist) {
        unawaited(
          widget.state
              .setTypography(fontSize: fontSize, lineHeight: lineHeight)
              .catchError((Object _) {
                if (mounted) showNovelFeedback(context, '排版设置保存失败，请重试');
              }),
        );
      }
      return;
    }
    final position = _currentPosition();
    if (position != null) _prepareRestore(position);
    unawaited(
      widget.state
          .setTypography(
            fontSize: fontSize,
            lineHeight: lineHeight,
            persist: persist,
          )
          .catchError((Object _) {
            if (mounted) showNovelFeedback(context, '排版设置保存失败，请重试');
          }),
    );
  }

  Future<ReaderBookmark?> _addBookmark() async {
    final position = _currentPosition(bookmark: true);
    if (position == null) return null;
    _savePosition(notify: false);
    return widget.state.addBookmark(novel: widget.novel, position: position);
  }

  Future<void> _seekProgress(double fraction) async {
    if (!_ready || !_scroll.hasClients) return;
    _clearBookmarkLanding();
    final value = fraction.clamp(0.0, 1.0);
    final generation = _contentGeneration;
    final ticket = ++_restoreTicket;
    _restoring = true;
    // A lazy sliver refines its estimate after a large jump. Follow that new
    // extent for a bounded number of frames, including an exact chapter end.
    for (var step = 0; step < 4; step++) {
      if (!mounted ||
          generation != _contentGeneration ||
          ticket != _restoreTicket ||
          !_scroll.hasClients) {
        return;
      }
      final maximum = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(value * maximum);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          generation != _contentGeneration ||
          ticket != _restoreTicket ||
          !_scroll.hasClients) {
        return;
      }
      if ((_scroll.position.maxScrollExtent - maximum).abs() < .5) break;
    }
    _restoring = false;
    _savePosition(notify: false);
  }

  void _restoreAfterLayout() {
    if (_restoreQueued) return;
    _restoreQueued = true;
    final generation = _contentGeneration;
    final ticket = ++_restoreTicket;
    _restoring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          generation != _contentGeneration ||
          ticket != _restoreTicket ||
          !_scroll.hasClients ||
          !_ready) {
        return;
      }
      final saved = _restorePending;
      _restorePending = null;
      int? landingParagraph;
      if (saved != null) {
        final centreBookmark = _bookmarkLandingPending;
        final viewportBottom = centreBookmark
            ? (_scroll.position.viewportDimension -
                      MediaQuery.paddingOf(context).bottom -
                      96)
                  .clamp(_readingInset + 1, double.infinity)
            : null;
        final sameLayout =
            (saved.fontSize - widget.state.fontSize).abs() < .01 &&
            (saved.lineHeight - widget.state.lineHeight).abs() < .01 &&
            (saved.width - _layoutWidth).abs() < 1 &&
            (saved.textScale - _textScale).abs() < .01 &&
            saved.typeface == widget.state.appFontId;
        var anchor =
            saved.paragraphIndex != null &&
                saved.paragraphIndex! >= 0 &&
                saved.paragraphIndex! < _paragraphCount
            ? (index: saved.paragraphIndex!, fraction: saved.paragraphFraction)
            : null;
        for (var step = 0; step < 10; step++) {
          if (!mounted ||
              generation != _contentGeneration ||
              ticket != _restoreTicket ||
              !_scroll.hasClients) {
            return;
          }
          final maximum = _scroll.position.maxScrollExtent;
          final paragraph = anchor == null
              ? null
              : _paragraphRegistry.target(
                  anchor,
                  _readingInset,
                  viewportBottom: viewportBottom,
                  trailingSpace: centreBookmark ? 12 : 0,
                );
          final target = sameLayout && step == 0 && !centreBookmark
              ? saved.offset
              : paragraph?.offset ??
                    (sameLayout && saved.fraction < .999
                        ? saved.offset
                        : saved.fraction * maximum);
          _scroll.jumpTo(
            target.clamp(
              0.0,
              centreBookmark && paragraph?.exact == true
                  ? maximum.clamp(0.0, double.infinity)
                  : double.infinity,
            ),
          );
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted ||
              generation != _contentGeneration ||
              ticket != _restoreTicket ||
              !_scroll.hasClients) {
            return;
          }
          // Older bookmarks stored only pixels. Resolve that position once,
          // then use the same paragraph-centred refinement as newer bookmarks.
          if (centreBookmark && anchor == null) {
            anchor = _paragraphRegistry.capture(
              _scroll.offset + _readingInset,
              clampToLast: true,
            );
          }
          final refined = anchor == null
              ? null
              : _paragraphRegistry.target(
                  anchor,
                  _readingInset,
                  viewportBottom: viewportBottom,
                  trailingSpace: centreBookmark ? 12 : 0,
                );
          if (refined?.exact == true &&
              (_scroll.offset -
                          refined!.offset.clamp(
                            0.0,
                            centreBookmark
                                ? _scroll.position.maxScrollExtent.clamp(
                                    0.0,
                                    double.infinity,
                                  )
                                : double.infinity,
                          ))
                      .abs() <
                  .5) {
            break;
          }
          if (anchor == null &&
              (_scroll.position.maxScrollExtent - maximum).abs() < .5) {
            break;
          }
        }
        landingParagraph = anchor?.index;
      }
      if (!mounted ||
          generation != _contentGeneration ||
          ticket != _restoreTicket) {
        return;
      }
      _restoring = false;
      _revealChapter();
      _landBookmark(saved, paragraphIndex: landingParagraph);
      _savePosition();
    });
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.novel.chapters.isEmpty
        ? const NovelChapter('目录为空', '')
        : widget.novel.chapters[_chapter];
    _layoutWidth = MediaQuery.sizeOf(context).width;
    _layoutFontId = widget.state.appFontId;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      // The catalogue owns the keyboard inset; keep the obscured article and
      // its saved scroll geometry fixed while searching in the drawer.
      resizeToAvoidBottomInset: false,
      body: Atmosphere(
        shareGlass: true,
        archiveBackdrop: false,
        child: Stack(
          children: [
            ReaderScreenBinding(state: widget.state),
            Positioned.fill(
              child: NativeGlassGroup(
                enabled: false,
                inherit: false,
                child: RepaintBoundary(
                  key: const ValueKey('reader-article-boundary'),
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.surface,
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(
                          LogicalKeyboardKey.pageDown,
                        ): () =>
                            _pageBy(1),
                        const SingleActivator(LogicalKeyboardKey.space): () =>
                            _pageBy(1),
                        const SingleActivator(LogicalKeyboardKey.pageUp): () =>
                            _pageBy(-1),
                        const SingleActivator(LogicalKeyboardKey.home): () =>
                            _seekProgress(0),
                        const SingleActivator(LogicalKeyboardKey.end): () =>
                            _seekProgress(1),
                        const SingleActivator(
                          LogicalKeyboardKey.keyF,
                          control: true,
                        ): _findInChapter,
                        const SingleActivator(
                          LogicalKeyboardKey.keyF,
                          meta: true,
                        ): _findInChapter,
                      },
                      child: Focus(
                        autofocus: true,
                        child: Semantics(
                          customSemanticsActions: {
                            const CustomSemanticsAction(label: '切换阅读控件'):
                                _toggleChrome,
                          },
                          child: GestureDetector(
                            key: const ValueKey('reader-content-tap'),
                            behavior: HitTestBehavior.translucent,
                            onTap: _toggleChrome,
                            child: _article(context, chapter, dark),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const Positioned.fill(child: ReaderEdgeBlur()),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: FrostedHeader(
                blurBackground: false,
                child: ReaderChromeLayer(
                  key: const ValueKey('reader-chrome-header'),
                  animation: _chrome,
                  slide: const Offset(0, -8),
                  child: Row(
                    children: [
                      GlassIconButton(
                        icon: CupertinoIcons.back,
                        label: '返回详情',
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: ArchiveRouteTitle(
                          title: widget.novel.title,
                          code:
                              'READ / ${ArchiveDesign.fileCode(widget.novel.id)}',
                        ),
                      ),
                      GlassIconButton(
                        key: const ValueKey('reader-bookmarks-entry'),
                        icon: CupertinoIcons.bookmark,
                        label: '阅读书签',
                        onPressed: () => _settings(bookmarks: true),
                      ),
                      if (_listening != null) ...[
                        const SizedBox(width: 4),
                        GlassIconButton(
                          key: const ValueKey('reader-listening-entry'),
                          icon: CupertinoIcons.headphones,
                          label: '听书',
                          onPressed: _listen,
                        ),
                      ],
                      const SizedBox(width: 4),
                      GlassIconButton(
                        icon: CupertinoIcons.textformat_size,
                        label: '阅读设置',
                        onPressed: _settings,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  22 + MediaQuery.paddingOf(context).left,
                  0,
                  22 + MediaQuery.paddingOf(context).right,
                  MediaQuery.paddingOf(context).bottom + 12,
                ),
                child: ReaderChromeLayer(
                  key: const ValueKey('reader-chrome-dock'),
                  animation: _chrome,
                  slide: const Offset(0, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 阅读进度条：显示全书进度，可拖动跳转。
                      if (_showProgressBar)
                        Padding(
                          padding: const EdgeInsets.only(
                              left: 56, right: 56, bottom: 8),
                          child: _ReaderProgressBar(
                            value: _progressDragging ? _dragValue : _progressValue,
                            dragging: _progressDragging,
                            previewText: _dragPreviewText(
                              _progressDragging ? _dragValue : _progressValue,
                            ),
                            onDragStart: () =>
                                setState(() {
                              _progressDragging = true;
                              _progressPointerCancelled = false;
                              _dragValue = _progressValue;
                            }),
                            onDragUpdate: (v) =>
                                setState(() => _dragValue = v),
                            onDragEnd: () async {
                              // 底层指针取消可能绕开 onCancel 直接进 onEnd：
                              // 此时只重置状态，不跳转。
                              final cancelled = _progressPointerCancelled;
                              final target = _dragValue;
                              setState(() {
                                _progressDragging = false;
                                _progressPointerCancelled = false;
                              });
                              if (!cancelled) {
                                await _jumpToProgress(target);
                              }
                            },
                            onPointerCancel: () =>
                                _progressPointerCancelled = true,
                            // 取消只重置状态，不跳转。
                            onDragCancel: () => setState(() {
                              _progressDragging = false;
                              _progressPointerCancelled = false;
                            }),
                          ),
                        ),
                      GlassDock(
                    key: const ValueKey('reader-liquid-dock'),
                    selectedIndex: 1,
                    reduceMotion: widget.state.reduceMotion,
                    items: [
                      GlassDockItem(
                        CupertinoIcons.arrow_left,
                        '上一章',
                        enabled: _chapter > 0,
                      ),
                      GlassDockItem(
                        CupertinoIcons.book,
                        '${widget.novel.chapters.isEmpty ? 0 : _chapter + 1} / ${widget.novel.chapters.length}',
                        enabled: widget.novel.chapters.isNotEmpty,
                        selectableOnDrag: false,
                        semanticLabel:
                            '目录，当前第 ${widget.novel.chapters.isEmpty ? 0 : _chapter + 1} 章，共 ${widget.novel.chapters.length} 章',
                      ),
                      GlassDockItem(
                        CupertinoIcons.arrow_right,
                        '下一章',
                        enabled: _chapter + 1 < widget.novel.chapters.length,
                      ),
                    ],
                    onSelected: (index) {
                      if (index == 1) {
                        _catalogue();
                      } else {
                        _go(_chapter + (index == 0 ? -1 : 1));
                      }
                    },
                  ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _article(
    BuildContext context,
    NovelChapter chapter,
    bool dark,
  ) => AnimatedBuilder(
    animation: widget.state.readerSettingsChanges,
    builder: (context, child) =>
        FutureBuilder<({ReaderContent? content, Object? error})>(
          future: _content,
          builder: (context, snapshot) {
            _layoutTextScale =
                MediaQuery.textScalerOf(context).scale(widget.state.fontSize) /
                widget.state.fontSize;
            _readingInset =
                MediaQuery.paddingOf(context).top +
                FrostedHeader.toolbarHeight +
                12;
            final content = snapshot.data?.content;
            final ready =
                snapshot.connectionState == ConnectionState.done &&
                content != null;
            final failed =
                snapshot.connectionState == ConnectionState.done &&
                (snapshot.hasError || snapshot.data?.error != null);
            _ready = ready;
            if (ready) _restoreAfterLayout();
            final paragraphs = ready ? content.paragraphs : const <String>[];
            _paragraphCount = paragraphs.length;
            final paragraphStyle = TextStyle(
              fontSize: widget.state.fontSize,
              height: widget.state.lineHeight,
              letterSpacing: .1,
              color: dark ? const Color(0xFFE8E8E8) : ink,
            );
            return NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.depth == 0) {
                  if (notification is ScrollStartNotification) {
                    _idleSave?.cancel();
                    if (notification.dragDetails != null) {
                      _suspendListeningFollow(userDrag: true);
                      _clearBookmarkLanding();
                      _restoreTicket++;
                      _restorePending = null;
                      _restoring = false;
                      _revealChapter();
                    }
                  } else if (notification is ScrollEndNotification) {
                    // A new drag stops the old fling and emits scroll-end
                    // inside its input callback. Do no anchor/storage work in
                    // that callback; save only after genuine, stable idle.
                    _saveWhenIdle();
                  }
                }
                return false;
              },
              child: CustomScrollView(
                key: const ValueKey('reader-scroll'),
                controller: _scroll,
                cacheExtent: (MediaQuery.sizeOf(context).height * .75).clamp(
                  250.0,
                  900.0,
                ),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      26,
                      MediaQuery.paddingOf(context).top +
                          FrostedHeader.toolbarHeight +
                          24,
                      26,
                      28,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                '第 ${_chapter + 1} 章',
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: ArchiveCode(
                                    'CH.${(_chapter + 1).toString().padLeft(3, '0')} / TEXT',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            chapter.title,
                            style: const TextStyle(
                              fontSize: 23,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (failed)
                    SliverToBoxAdapter(
                      child: Column(
                        children: [
                          const Text('章节加载失败'),
                          GlassTextButton(
                            onPressed: () => setState(() {
                              _content = _loadContent();
                            }),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  else if (!ready)
                    const SliverPadding(
                      padding: EdgeInsets.symmetric(horizontal: 26),
                      sliver: SliverToBoxAdapter(child: ReaderSkeleton()),
                    )
                  else ...[
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 26),
                      sliver: SliverList.builder(
                        addAutomaticKeepAlives: false,
                        itemCount: paragraphs.length,
                        itemBuilder: (context, index) => ReaderParagraph(
                          key: ValueKey(
                            'paragraph-anchor-$_contentGeneration-$index',
                          ),
                          registry: _paragraphRegistry,
                          index: index,
                          child: LoadedContentItem(
                            key: ValueKey('reader-paragraph-reveal-$index'),
                            index: index - _chapterRevealFirst,
                            animation: _chapterReveal,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: ValueListenableBuilder<int?>(
                                valueListenable: _bookmarkLanding,
                                child: _listening == null
                                    ? _paragraphContent(
                                        paragraphs,
                                        index,
                                        paragraphStyle,
                                      )
                                    : ListeningParagraphHighlight(
                                        controller: _listening!,
                                        novelId: widget.novel.id,
                                        chapter: _chapter,
                                        paragraph: index,
                                        onDoubleTap: () =>
                                            _doubleTapListeningParagraph(index),
                                        interactive:
                                            readerIllustrationUrl(
                                                  paragraphs[index],
                                                ) ==
                                                null &&
                                            paragraphs[index].trim() !=
                                                '[插图]' &&
                                            hasSpeechText(paragraphs[index]),
                                        child: _paragraphContent(
                                          paragraphs,
                                          index,
                                          paragraphStyle,
                                        ),
                                      ),
                                builder: (context, selected, child) =>
                                    selected == index
                                    ? ReaderLandingHighlight(
                                        key: ValueKey(
                                          'bookmark-landing-$index',
                                        ),
                                        reduceMotion: widget.state.reduceMotion,
                                        child: child!,
                                      )
                                    : child!,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.only(
                        top: 48,
                        bottom: MediaQuery.paddingOf(context).bottom + 116,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          children: [
                            SizedBox(
                              width: 30,
                              child: Divider(
                                color: Theme.of(context).dividerColor,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '本章完',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (_chapter + 1 < widget.novel.chapters.length)
                              GlassTextButton(
                                key: const ValueKey('reader-end-next'),
                                onPressed: () => _go(_chapter + 1),
                                child: const Text('继续下一章'),
                              )
                            else
                              Text(
                                '已读至当前目录末章',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
  );

  Future<void> _settings({bool bookmarks = false}) async {
    if (_toolsOpen || _catalogueOpen || _findOpen || _listeningOpen) return;
    _toolsOpen = true;
    _followTicket++;
    _followScroll.cancel();
    final position = _currentPosition();
    final preview = ValueNotifier(false);
    try {
      final action = await showJellySheet<ReaderToolAction>(
        context: context,
        reduceMotion: widget.state.reduceMotion,
        previewing: preview,
        builder: (context) => ReaderTools(
          novel: widget.novel,
          state: widget.state,
          position: position,
          onAddBookmark: _addBookmark,
          onFontSize: (value) => _applyTypography(fontSize: value),
          onLineHeight: (value) => _applyTypography(lineHeight: value),
          onFontPreview: (value) =>
              _applyTypography(fontSize: value, persist: false),
          onLineHeightPreview: (value) =>
              _applyTypography(lineHeight: value, persist: false),
          onPreviewChanged: (value) {
            _typographyPreviewing = value;
            preview.value = value;
          },
          onReset: () => _applyTypography(fontSize: 19, lineHeight: 1.72),
          initialBookmarks: bookmarks,
        ),
      );
      if (!mounted) return;
      switch (action) {
        case ReaderEnterFocus():
          _showChrome(false);
        case ReaderSeekProgress(:final fraction):
          await _seekProgress(fraction);
        case ReaderOpenBookmark(:final bookmark):
          final chapter = widget.state.chapterForPosition(
            widget.novel,
            bookmark.position,
          );
          if (chapter != null) {
            _go(chapter, position: bookmark.position, highlightBookmark: true);
          }
        case ReaderOpenFind():
          // The settings surface has fully collapsed before opening the next.
          _toolsOpen = false;
          await _findInChapter();
        case null:
          break;
      }
    } finally {
      _toolsOpen = false;
      _typographyPreviewing = false;
      preview.dispose();
      _savePosition(notify: false);
    }
  }

  Future<void> _findInChapter() async {
    final content = _currentContent;
    if (!_ready ||
        content == null ||
        _findOpen ||
        _toolsOpen ||
        _listeningOpen ||
        _catalogueOpen) {
      return;
    }
    _clearBookmarkLanding();
    _suspendListeningFollow();
    _findOpen = true;
    final generation = _contentGeneration;
    try {
      final match = await showJellySheet<ReaderMatch>(
        context: context,
        reduceMotion: widget.state.reduceMotion,
        builder: (_) => ReaderFindPanel(content: content),
      );
      if (!mounted || match == null || generation != _contentGeneration) return;
      _highlightTimer?.cancel();
      _findMatch.value = match;
      // A manual drag can interrupt lazy positioning before it completes.
      // Expiration belongs to selection, not to successful restoration.
      _highlightTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) _findMatch.value = null;
      });
      final ticket = ++_restoreTicket;
      _restoring = true;
      for (var step = 0; step < 20; step++) {
        if (!mounted ||
            generation != _contentGeneration ||
            ticket != _restoreTicket ||
            !_scroll.hasClients) {
          return;
        }
        final precise = _paragraphRegistry.matchOffset(
          match.paragraph,
          match.start,
          match.end,
          _readingInset + 8,
        );
        final estimate = _paragraphRegistry.target((
          index: match.paragraph,
          fraction: 0,
        ), _readingInset + 8);
        final target = precise ?? estimate?.offset;
        if (target == null) break;
        _scroll.jumpTo(target.clamp(0.0, double.infinity));
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted ||
            generation != _contentGeneration ||
            ticket != _restoreTicket ||
            !_scroll.hasClients) {
          return;
        }
        final refined = _paragraphRegistry.matchOffset(
          match.paragraph,
          match.start,
          match.end,
          _readingInset + 8,
        );
        if (refined != null &&
            (_scroll.offset -
                        refined.clamp(0.0, _scroll.position.maxScrollExtent))
                    .abs() <
                1) {
          break;
        }
      }
      if (!mounted ||
          generation != _contentGeneration ||
          ticket != _restoreTicket) {
        return;
      }
      _restoring = false;
      _savePosition(notify: false);
      _showChrome(true);
    } finally {
      _findOpen = false;
    }
  }
}

/// 阅读器底部进度条：显示全书阅读进度，支持拖动跳转。
/// 平时只显示纤细轨道；拖动时显示滑块和"第 N 章 · X%"预览。
class _ReaderProgressBar extends StatelessWidget {
  const _ReaderProgressBar({
    required this.value,
    required this.dragging,
    required this.previewText,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required this.onPointerCancel,
  });

  final double value;
  final bool dragging;
  final String previewText;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDragCancel;
  // 底层指针取消（PointerCancelEvent）：拖拽 accepted 后可能不走
  // onHorizontalDragCancel 而直接进 onEnd，父级用它做提交前的检查。
  final VoidCallback onPointerCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 拖动时显示预览文字。
        AnimatedOpacity(
          opacity: dragging ? 1 : 0,
          duration: const Duration(milliseconds: 150),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              previewText,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        // 36px 高的可触摸区域，轨道纤细居中。
        // 用 LayoutBuilder 拿宽度：details.localPosition 是相对手势区域的，
        // 必须与同一区域的宽度相除，不能用外层 context 的 RenderBox。
        LayoutBuilder(
          builder: (context, constraints) {
            final barWidth = constraints.maxWidth;
            double toRatio(double dx) => (dx / barWidth).clamp(0.0, 1.0);
            // Listener 捕获底层指针取消：拖拽 accepted 后，
            // 指针取消不一定触发 onHorizontalDragCancel，可能直接走 onEnd。
            return Listener(
              onPointerCancel: (_) => onPointerCancel(),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) => onDragStart(),
                onHorizontalDragUpdate: (details) =>
                    onDragUpdate(toRatio(details.localPosition.dx)),
                onHorizontalDragEnd: (_) => onDragEnd(),
                onHorizontalDragCancel: onDragCancel,
                onTapDown: (details) {
                  onDragStart();
                  onDragUpdate(toRatio(details.localPosition.dx));
                },
                onTapUp: (_) => onDragEnd(),
                onTapCancel: onDragCancel,
                child: SizedBox(
                  height: 36,
                  width: barWidth,
                  child: Center(
                    child: SizedBox(
                      height: 4,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final w = constraints.maxWidth;
                          return Stack(
                            children: [
                              // 轨道
                              Container(
                                width: w,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: scheme.onSurface.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              // 已读部分
                              Container(
                                width: w * value.clamp(0.0, 1.0),
                                height: 4,
                                decoration: BoxDecoration(
                                  color: scheme.primary,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              // 滑块（拖动时显示）
                              if (dragging)
                                Positioned(
                                  left: (w * value.clamp(0.0, 1.0) - 7)
                                      .clamp(0.0, w - 14),
                                  top: -5,
                                  child: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: scheme.primary,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.2),
                                          blurRadius: 4,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
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
      ],
    );
  }
}
