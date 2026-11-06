import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'reader_chrome.dart';
import 'reader_skeleton.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'local_library.dart';
import 'local_platform.dart';
import 'reading_activity.dart';

/// 本地 PDF 阅读器：逐页渲染为图片，左右滑动翻页，进度复用书架章节进度。
class LocalPdfReaderPage extends StatefulWidget {
  const LocalPdfReaderPage({
    super.key,
    required this.novel,
    required this.state,
    required this.local,
    this.initialPage,
  });

  final Novel novel;
  final LibraryState state;
  final LocalLibraryStore local;

  /// Opens at this 0-based page (e.g. from a page bookmark) instead of the
  /// last read page.
  final int? initialPage;

  @override
  State<LocalPdfReaderPage> createState() => _LocalPdfReaderPageState();
}

class _LocalPdfReaderPageState extends State<LocalPdfReaderPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _chrome;
  bool _chromeTarget = true;
  late final PageController _controller;
  late final ReadingActivitySession _readingActivity;
  late int _page;
  bool _activityAttached = true;
  bool _activityForeground = true;
  bool _addingBookmark = false;
  final Map<int, Future<String>> _pending = {};

  int get _pageCount {
    final book = widget.local.bookFor(widget.novel.id);
    return book?.pageCount ?? 0;
  }

  void _syncReadingActivity() {
    _readingActivity.setActive(
      _activityAttached && _activityForeground && _pageCount > 0,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readingActivity = ReadingActivitySession(
      store: widget.state.readingActivity,
      bookId: widget.novel.id,
    );
    final count = _pageCount;
    _page = count == 0
        ? 0
        : (widget.initialPage ?? widget.state.chapterForNovel(widget.novel))
              .clamp(0, count - 1);
    _controller = PageController(initialPage: _page);
    _chrome = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 140),
      value: 1,
    );
    _syncReadingActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _activityForeground = state == AppLifecycleState.resumed;
    _syncReadingActivity();
  }

  @override
  void deactivate() {
    _activityAttached = false;
    _readingActivity.setActive(false);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _activityAttached = true;
    _syncReadingActivity();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _readingActivity.dispose();
    final book = widget.local.bookFor(widget.novel.id);
    if (book != null) {
      unawaited(LocalPlatform.clearPdfCache(book.fileUri).catchError((_) {}));
    }
    _controller.dispose();
    _chrome.dispose();
    super.dispose();
  }

  void _toggleChrome() {
    _chromeTarget = !_chromeTarget;
    if (widget.state.effectiveReduceMotion ||
        MediaQuery.disableAnimationsOf(context)) {
      _chrome.value = _chromeTarget ? 1 : 0;
    } else if (_chromeTarget) {
      _chrome.forward();
    } else {
      _chrome.reverse();
    }
  }

  Future<void> _addBookmark() async {
    if (_addingBookmark || _pageCount <= 0) return;
    _addingBookmark = true;
    final page = _page;
    final existing = widget.state
        .bookmarksFor(widget.novel.id)
        .map((mark) => mark.id)
        .toSet();
    try {
      final mark = await widget.state.addPageBookmark(
        novel: widget.novel,
        page: page,
        pageCount: _pageCount,
      );
      if (mounted) {
        if (mark == null) {
          showNovelFeedback(context, '书签保存失败，请重试');
        } else if (existing.contains(mark.id)) {
          showNovelFeedback(context, '此页已有书签');
        } else {
          showNovelFeedback(context, '已添加第 ${page + 1} 页书签');
        }
      }
    } catch (error) {
      if (mounted) {
        showNovelFeedback(
          context,
          error is FormatException ? error.message : '书签保存失败，请重试',
        );
      }
    } finally {
      _addingBookmark = false;
    }
  }

  /// 目录 / 书签 sheet. PDFs rendered by Android's PdfRenderer expose no
  /// outline, so the 目录 tab is shown disabled with that reason.
  Future<void> _navigation() async {
    final page = await showJellySheet<int>(
      context: context,
      reduceMotion: widget.state.effectiveReduceMotion,
      builder: (sheet) => _PdfNavigationSheet(
        state: widget.state,
        novelId: widget.novel.id,
        pageCount: _pageCount,
        current: _page,
      ),
    );
    if (page != null && mounted) _controller.jumpToPage(page);
  }

  List<ReaderAction> _actions() => [
    ReaderAction(
      key: const ValueKey('reader-catalogue-entry'),
      icon: CupertinoIcons.list_bullet,
      caption: '目录',
      label: '目录与书签',
      onPressed: _pageCount == 0 ? null : _navigation,
      unavailable: _pageCount == 0 ? '无法读取该 PDF' : null,
    ),
    const ReaderAction(
      icon: CupertinoIcons.textformat_size,
      caption: '排版',
      label: '阅读设置',
      unavailable: 'PDF 不支持排版调节：页面按原版式渲染，可双指缩放',
    ),
    ReaderAction(
      key: const ValueKey('reader-appearance-entry'),
      icon: CupertinoIcons.sun_max,
      caption: '亮度',
      label: '亮度与纸色',
      onPressed: () =>
          showReaderAppearanceSheet(context, state: widget.state, pdf: true),
    ),
    const ReaderAction(
      key: ValueKey('reader-listening-entry'),
      icon: CupertinoIcons.headphones,
      caption: '听书',
      label: '听书',
      unavailable: 'PDF 不支持听书：页面是渲染图片，没有可朗读的文本',
    ),
  ];

  Future<String> _render(int page) {
    final book = widget.local.bookFor(widget.novel.id);
    if (book == null) return Future.error(StateError('书籍已移除'));
    return _pending.putIfAbsent(page, () async {
      final width =
          (MediaQuery.devicePixelRatioOf(context) *
                  MediaQuery.sizeOf(context).width)
              .round()
              .clamp(800, 2400);
      final path = await LocalPlatform.renderPdfPage(book.fileUri, page, width);
      if (path.isEmpty) throw StateError('页面渲染失败');
      return path;
    });
  }

  void _onPageChanged(int page) {
    _page = page;
    _pending.removeWhere((key, _) => (key - page).abs() > 4);
    widget.state.setChapter(widget.novel.id, page);
    if (mounted) setState(() {});
    // 首帧完成后优先预渲染下一页，避免翻页回调里同时启动多个解码任务。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || page + 1 >= _pageCount) return;
      _render(page + 1).catchError((Object _) => '');
    });
  }

  /// Colour matrix inversion keeps hue roughly stable by inverting luma
  /// only approximately; it is the common "night PDF" filter.
  static const _invert = ColorFilter.matrix(<double>[
    -1, 0, 0, 0, 255, //
    0, -1, 0, 0, 255, //
    0, 0, -1, 0, 255, //
    0, 0, 0, 1, 0, //
  ]);

  Widget _pageView(BuildContext context, int count, bool invert) {
    final width = (MediaQuery.devicePixelRatioOf(context) *
            MediaQuery.sizeOf(context).width)
        .round()
        .clamp(800, 2400);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return PageView.builder(
      controller: _controller,
      itemCount: count,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, page) => FutureBuilder<String>(
        future: _render(page),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            Widget image = Image.file(
              File(snapshot.data!),
              fit: BoxFit.contain,
              cacheWidth: width,
              errorBuilder: (context, error, stack) {
                _pending.remove(page);
                return Icon(Icons.broken_image_outlined, color: muted, size: 48);
              },
            );
            if (invert) {
              image = ColorFiltered(
                key: const ValueKey('pdf-night-invert'),
                colorFilter: _invert,
                child: image,
              );
            }
            return InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(child: image),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.broken_image_outlined, color: muted, size: 48),
                  const SizedBox(height: 12),
                  Text('页面加载失败', style: TextStyle(color: muted)),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () {
                      _pending.remove(page);
                      if (mounted) setState(() {});
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }
          return Center(child: CircularProgressIndicator(color: muted));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ReaderPaperScope(
    state: widget.state,
    child: Builder(builder: _readerScaffold),
  );

  Widget _readerScaffold(BuildContext context) {
    final count = _pageCount;
    final theme = Theme.of(context);
    final darkPaper = theme.brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: widget.state.readerSettingsChanges,
      builder: (context, _) {
        final invert = darkPaper && widget.state.pdfNightInvert;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: novelSystemUiStyle(theme.brightness),
          child: Scaffold(
            backgroundColor: theme.colorScheme.surface,
            body: Stack(
              children: [
                Positioned.fill(
                  child: count == 0
                      ? Center(
                          child: Text(
                            '无法读取该 PDF',
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : GestureDetector(
                          key: const ValueKey('reader-content-tap'),
                          behavior: HitTestBehavior.translucent,
                          onTap: _toggleChrome,
                          child: _pageView(context, count, invert),
                        ),
                ),
                Positioned.fill(child: ReaderEdgeBlur(animation: _chrome, blurBottom: false)),
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
                      fadeOffset: const Offset(0, -12),
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
                              code: ArchiveDesign.fileCode(widget.novel.id),
                            ),
                          ),
                          GlassIconButton(
                            key: const ValueKey('reader-bookmarks-entry'),
                            icon: CupertinoIcons.bookmark,
                            label: '添加书签',
                            onPressed: count == 0 ? null : _addBookmark,
                          ),
                          const SizedBox(width: 4),
                          GlassIconButton(
                            key: const ValueKey('reader-more-entry'),
                            icon: CupertinoIcons.ellipsis,
                            label: '更多',
                            onPressed: () => showNovelFeedback(
                              context,
                              'PDF 不支持查找与排版；可双指缩放页面',
                            ),
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
                      fadeOffset: const Offset(0, 12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: ReaderBottomPanel(
                          actions: _actions(),
                          progress: count > 1 ? _pageSlider(context, count) : null,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: MediaQuery.paddingOf(context).bottom + 6,
                  child: ReaderStatusLine(
                    chrome: _chrome,
                    text: count == 0 ? '' : '第 ${_page + 1} / $count 页',
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _pageSlider(BuildContext context, int count) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text('${_page + 1}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        Expanded(
          child: Slider(
            key: const ValueKey('pdf-page-slider'),
            value: _page.clamp(0, count - 1).toDouble(),
            min: 0,
            max: (count - 1).toDouble(),
            activeColor: scheme.secondary,
            inactiveColor: scheme.outlineVariant,
            label: '第 ${_page + 1} 页',
            divisions: count - 1,
            onChanged: (value) =>
                _controller.jumpToPage(value.round().clamp(0, count - 1)),
          ),
        ),
        Text('$count', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

class _PdfNavigationSheet extends StatelessWidget {
  const _PdfNavigationSheet({
    required this.state,
    required this.novelId,
    required this.pageCount,
    required this.current,
  });
  final LibraryState state;
  final int novelId, pageCount, current;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.bookmarkChanges,
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      final marks = [
        for (final mark in state.bookmarksFor(novelId))
          if (!mark.isUnderline &&
              mark.position.chapter >= 0 &&
              mark.position.chapter < pageCount)
            mark,
      ];
      return Padding(
        key: const ValueKey('pdf-navigation-sheet'),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ArchiveSection(title: '目录与书签', code: 'PDF / NAVIGATION'),
            const SizedBox(height: 8),
            Opacity(
              opacity: .5,
              child: Text(
                '目录：不可用。系统 PDF 渲染器不提供书内目录，请用页码书签跳转。',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            const Divider(height: 24),
            if (marks.isEmpty)
              Text('还没有书签。点顶栏书签按钮记录当前页。',
                  style: TextStyle(color: scheme.onSurfaceVariant))
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final mark in marks)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('第 ${mark.position.chapter + 1} 页'),
                        trailing: mark.position.chapter == current
                            ? Icon(Icons.circle, size: 8, color: scheme.primary)
                            : null,
                        onTap: () => Navigator.pop(context, mark.position.chapter),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}
