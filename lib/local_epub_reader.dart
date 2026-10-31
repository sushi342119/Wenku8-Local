import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'glass_dock.dart';
import 'library_state.dart';
import 'local_epub.dart';
import 'local_epub_reader_tools.dart';
import 'local_library.dart';
import 'reader_catalogue.dart';
import 'reader_chrome.dart';
import 'reader_tools.dart';

class LocalEpubReaderPage extends StatefulWidget {
  const LocalEpubReaderPage({
    super.key,
    required this.novel,
    required this.state,
    required this.local,
    required this.initialChapter,
  });

  final Novel novel;
  final LibraryState state;
  final LocalLibraryStore local;
  final int initialChapter;

  @override
  State<LocalEpubReaderPage> createState() => _LocalEpubReaderPageState();
}

class _LocalEpubReaderPageState extends State<LocalEpubReaderPage>
    with SingleTickerProviderStateMixin {
  late final Novel _novel;
  late final AnimationController _chrome;
  late int _chapter;
  int _chapterVisit = 0;
  bool _chromeTarget = true;
  bool _sheetOpen = false;
  Future<({List<EpubBlock> blocks, Map<String, Uint8List> images})>? _future;
  int? _futureChapter;

  // keepScrollOffset: false —— 每章换新 ListView，不能让 PageStorage 把上一章偏移带过来。
  final ScrollController _scroll = ScrollController(keepScrollOffset: false);
  final ValueNotifier<double> _progressValue = ValueNotifier(0);
  bool _progressDragging = false;
  bool _progressPointerCancelled = false;
  double _dragValue = 0;
  bool _singleScrollable = false;
  // 恢复旧章内位置完成前不保存滚动，避免 offset 0 覆盖旧位置。
  bool _tracking = false;
  int _jumpTicket = 0;
  Timer? _idleSave;
  double _width = 0;
  double _lastOffset = 0;
  double _lastMax = 0;

  int get _total => _novel.chapters.length;

  bool get _hasLayout =>
      _scroll.positions.length == 1 && _scroll.position.hasContentDimensions;

  /// 章内滚动比例（0~1），不可滚动时为 0。
  double get _chapterRatio {
    if (!_hasLayout) return 0;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return 0;
    return (_scroll.offset / max).clamp(0.0, 1.0);
  }

  /// 全书进度：章权重一律按 1，(之前章节数 + 本章滚动比例) / 总章数。
  double _bookProgress() {
    if (_total <= 0) return 0;
    return ((_chapter + _chapterRatio) / _total).clamp(0.0, 1.0);
  }

  /// 把全书进度换算为目标章节和章内比例（边界归前一章末尾，与 TXT 一致）。
  ({int chapter, double ratio}) _progressToTarget(double progress) {
    if (_total <= 0) return (chapter: 0, ratio: 0);
    var target = (progress * _total).clamp(0.0, _total.toDouble());
    for (var i = 0; i < _total; i++) {
      if (target <= 1 || i == _total - 1) {
        return (chapter: i, ratio: target.clamp(0.0, 1.0));
      }
      target -= 1;
    }
    return (chapter: _total - 1, ratio: 1);
  }

  /// 进度条是否显示：多章，或单章可滚动时显示。
  bool get _showProgressBar => _total > 1 || (_total == 1 && _singleScrollable);

  String _dragPreviewText(double progress) {
    final target = _progressToTarget(progress);
    return '第 ${target.chapter + 1} 章 · ${(progress * 100).round()}%';
  }

  void _updateProgress() {
    if (_progressDragging || !mounted) return;
    final v = _bookProgress();
    if ((v - _progressValue.value).abs() > 0.0005) _progressValue.value = v;
  }

  void _onScroll() {
    if (_hasLayout) {
      _lastOffset = _scroll.offset;
      _lastMax = _scroll.position.maxScrollExtent;
    }
    _updateProgress();
    if (!_tracking) return;
    _idleSave?.cancel();
    _idleSave = Timer(const Duration(milliseconds: 600), () {
      if (mounted) unawaited(_savePosition());
    });
  }

  @override
  void initState() {
    super.initState();
    final book = widget.local.bookFor(widget.novel.id);
    _novel = book == null
        ? widget.novel
        : widget.novel.withChapters([
            for (var index = 0; index < book.chapters.length; index++)
              NovelChapter(
                book.chapters[index].title,
                '',
                id: index,
                revision: book.revision,
                volume: book.chapters[index].volume,
              ),
          ]);
    _chrome = AnimationController(
      vsync: this,
      duration: NovelMotion.contact,
      reverseDuration: NovelMotion.exit,
      value: 1,
    );
    if (_total <= 0) {
      _chapter = 0;
    } else if (widget.initialChapter >= 0 && widget.initialChapter < _total) {
      _chapter = widget.initialChapter;
    } else {
      _chapter = widget.state.chapterForNovel(_novel).clamp(0, _total - 1);
    }
    _scroll.addListener(_onScroll);
    _progressValue.value = _total == 0 ? 0 : _chapter / _total;
    // 先读旧的章内位置；必须在恢复滚动之后才开始保存，否则旧位置被 0 覆盖。
    double? restoreRatio;
    final saved = widget.state.positionFor(_novel.id);
    if (_total > 0 &&
        saved != null &&
        widget.state.chapterForPosition(_novel, saved) == _chapter &&
        saved.fraction > 0) {
      restoreRatio = saved.fraction.clamp(0.0, 1.0);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _total <= 0) return;
      if (restoreRatio != null) {
        unawaited(_restore(restoreRatio));
      } else {
        _tracking = true;
        unawaited(_saveChapter(_chapter));
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _width = MediaQuery.sizeOf(context).width;
  }

  /// 等当前章（[chapter]）加载并布局完成；postFrame 回调链 + 2 秒 watchdog，
  /// 超时、卸载或被新跳转取代时也结束等待。返回 false 表示已被取代/卸载。
  Future<bool> _waitForChapterLayout(int ticket, int chapter) async {
    try {
      await _load();
    } catch (_) {
      return mounted && ticket == _jumpTicket && chapter == _chapter;
    }
    bool stale() => !mounted || ticket != _jumpTicket || chapter != _chapter;
    if (stale()) return false;
    final done = Completer<void>();
    final stopwatch = Stopwatch()..start();
    final watchdog = Timer(const Duration(seconds: 2), () {
      if (!done.isCompleted) done.complete();
    });
    void waitForLayout() {
      if (done.isCompleted) return;
      if (stale() ||
          stopwatch.elapsed >= const Duration(seconds: 2) ||
          _hasLayout) {
        done.complete();
        return;
      }
      SchedulerBinding.instance.scheduleFrame();
      WidgetsBinding.instance.addPostFrameCallback((_) => waitForLayout());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => waitForLayout());
    SchedulerBinding.instance.scheduleFrame();
    try {
      await done.future;
    } finally {
      watchdog.cancel();
      stopwatch.stop();
    }
    return !stale();
  }

  /// 按比例滚动；懒加载列表的 maxScrollExtent 是估算值，跳转后再校正几帧。
  Future<void> _scrollToRatio(int ticket, double ratio) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!mounted || ticket != _jumpTicket || !_hasLayout) return;
      final max = _scroll.position.maxScrollExtent;
      if (max <= 0) return;
      final target = (ratio * max).clamp(0.0, max);
      if ((_scroll.offset - target).abs() < 1) return;
      _scroll.jumpTo(target);
      final frame = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) => frame.complete());
      SchedulerBinding.instance.scheduleFrame();
      await frame.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    }
  }

  Future<void> _restore(double ratio) async {
    final ticket = ++_jumpTicket;
    final chapter = _chapter;
    var current = false;
    try {
      current = await _waitForChapterLayout(ticket, chapter);
      if (current) await _scrollToRatio(ticket, ratio);
    } finally {
      // 被跳章取代时由 _goTo 或 _jumpToProgress 负责保存；否则恢复结束（含超时）后开始跟踪并保存真实位置。
      if (mounted && ticket == _jumpTicket) {
        _tracking = true;
        _updateProgress();
        if (_hasLayout && _scroll.offset > 0) {
          unawaited(_savePosition());
        }
      }
    }
  }

  Future<({List<EpubBlock> blocks, Map<String, Uint8List> images})> _load() {
    if (_future == null || _futureChapter != _chapter) {
      _futureChapter = _chapter;
      _future = widget.local.epubChapter(widget.novel.id, _chapter);
    }
    return _future!;
  }

  /// 切章时保存：章序号 + 章首位置（新章从头开始）。
  Future<void> _saveChapter(int chapter) async {
    final width = _width;
    try {
      await widget.state.setChapter(_novel.id, chapter);
    } catch (_) {
      if (mounted) showNovelFeedback(context, '阅读进度保存失败，请重试');
      return;
    }
    try {
      await widget.state.savePosition(
        novel: _novel,
        chapter: chapter,
        offset: 0,
        maximum: 0,
        width: width,
      );
    } catch (_) {}
  }

  /// 保存当前章真实的滚动 offset/maximum（章内进度）。
  Future<void> _savePosition({bool notify = true}) async {
    _idleSave?.cancel();
    _idleSave = null;
    if (!_tracking || _total <= 0 || !_hasLayout) return;
    try {
      await widget.state.savePosition(
        novel: _novel,
        chapter: _chapter,
        offset: _scroll.offset,
        maximum: _scroll.position.maxScrollExtent,
        width: _width,
        notify: notify,
      );
    } catch (_) {}
  }

  void _goTo(int chapter, {bool restart = false}) {
    if (chapter < 0 || chapter >= _total) return;
    if (chapter == _chapter && !restart) return;
    _jumpTicket++;
    _idleSave?.cancel();
    _idleSave = null;
    _tracking = true;
    unawaited(_saveChapter(chapter));
    setState(() {
      if (_chapter != chapter) {
        _future = null;
        _futureChapter = null;
      }
      _chapter = chapter;
      _chapterVisit++;
    });
    if (!_progressDragging) _progressValue.value = _chapter / _total;
    _showChrome(true);
  }

  /// 拖动结束：跳到目标章，待新章布局完成后按比例滚动。
  Future<void> _jumpToProgress(double progress) async {
    final target = _progressToTarget(progress);
    if (target.chapter != _chapter) _goTo(target.chapter);
    final ticket = ++_jumpTicket;
    // 恢复进行中被进度条打断时，恢复的 finally 不会再设 tracking；
    // 此次跳转接管保存，否则之后滚动将一直不保存。
    _tracking = true;
    final chapter = _chapter;
    if (!await _waitForChapterLayout(ticket, chapter)) return;
    await _scrollToRatio(ticket, target.ratio);
    _updateProgress();
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

  void _toggleChrome() {
    if (_total > 0 && !_sheetOpen) _showChrome(!_chromeTarget);
  }

  Future<void> _catalogue() async {
    if (_sheetOpen || _total == 0) return;
    _sheetOpen = true;
    try {
      final index = await showJellySheet<int>(
        context: context,
        reduceMotion: widget.state.reduceMotion,
        builder: (context) => ReaderCatalogue(
          novel: _novel,
          currentChapter: _chapter,
          cache: null,
        ),
      );
      if (mounted && index != null) _goTo(index, restart: true);
    } finally {
      _sheetOpen = false;
    }
  }

  Future<ReaderBookmark?> _addBookmark() async {
    if (_total == 0) return null;
    final chapter = _novel.chapters[_chapter];
    return widget.state.addBookmark(
      novel: _novel,
      position: ReadingPosition(
        chapter: _chapter,
        chapterId: chapter.id,
        revision: chapter.revision,
        offset: 0,
        fraction: 0,
        fontSize: widget.state.fontSize,
        lineHeight: widget.state.lineHeight,
        width: MediaQuery.sizeOf(context).width,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _settings({bool bookmarks = false}) async {
    if (_sheetOpen || _total == 0) return;
    _sheetOpen = true;
    try {
      final action = await showJellySheet<ReaderToolAction>(
        context: context,
        reduceMotion: widget.state.reduceMotion,
        builder: (context) => LocalEpubReaderTools(
          novel: _novel,
          state: widget.state,
          chapter: _chapter,
          chapterProgress: _chapterRatio,
          onAddBookmark: _addBookmark,
          initialBookmarks: bookmarks,
        ),
      );
      if (!mounted) return;
      if (action is ReaderEnterFocus) {
        _showChrome(false);
      } else if (action is ReaderOpenBookmark) {
        final chapter = widget.state.chapterForPosition(
          _novel,
          action.bookmark.position,
        );
        if (chapter != null) _goTo(chapter, restart: true);
      }
    } finally {
      _sheetOpen = false;
    }
  }

  @override
  void dispose() {
    // 页面不持有 EpubPackage；epubChapter() 完成时会在 finally 中关闭包。
    // 清引用不会取消尚未完成的加载；ImageCache 可能继续持有图片字节，
    // 因此 dispose 不保证立即释放全部图片内存。
    _future = null;
    _futureChapter = null;
    _jumpTicket++;
    // 有未落盘的滚动时补存一次（与 TXT 退出时 finalSave 一致，不通知监听者）。
    // dispose 时列表可能已先卸载，用滚动监听里缓存的 offset/maximum。
    if (_idleSave != null && _tracking && _total > 0 && _lastMax > 0) {
      unawaited(
        widget.state
            .savePosition(
              novel: _novel,
              chapter: _chapter,
              offset: _lastOffset,
              maximum: _lastMax,
              width: _width,
              notify: false,
            )
            .catchError((_) {}),
      );
    }
    _idleSave?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _progressValue.dispose();
    _chrome.dispose();
    super.dispose();
  }

  void _retry() {
    _tracking = true;
    setState(() {
      _future = null;
      _futureChapter = null;
    });
  }

  String _chapterTitle() => _total == 0 ? '' : _novel.chapters[_chapter].title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Atmosphere(
        shareGlass: true,
        archiveBackdrop: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('reader-content-tap'),
                behavior: HitTestBehavior.translucent,
                onTap: _toggleChrome,
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: _total == 0
                      ? _message('暂无章节')
                      : AnimatedBuilder(
                          animation: widget.state.readerSettingsChanges,
                          builder: (context, _) => _content(context),
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
                          title: _novel.title,
                          code: 'READ / ${ArchiveDesign.fileCode(_novel.id)}',
                        ),
                      ),
                      GlassIconButton(
                        key: const ValueKey('reader-bookmarks-entry'),
                        icon: CupertinoIcons.bookmark,
                        label: '阅读书签',
                        onPressed: _total == 0
                            ? null
                            : () => _settings(bookmarks: true),
                      ),
                      const SizedBox(width: 4),
                      GlassIconButton(
                        icon: CupertinoIcons.textformat_size,
                        label: '阅读设置',
                        onPressed: _total == 0 ? null : _settings,
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
                      // 全书进度条：与 Dock 一起随控件显隐，可拖动跳转。
                      if (_showProgressBar)
                        Padding(
                          padding: const EdgeInsets.only(
                            left: 56,
                            right: 56,
                            bottom: 8,
                          ),
                          child: ValueListenableBuilder<double>(
                            valueListenable: _progressValue,
                            builder: (context, progress, _) => _EpubProgressBar(
                              key: const ValueKey('epub-book-progress'),
                              value: _progressDragging ? _dragValue : progress,
                              dragging: _progressDragging,
                              previewText: _dragPreviewText(
                                _progressDragging ? _dragValue : progress,
                              ),
                              onDragStart: () => setState(() {
                                _progressDragging = true;
                                _progressPointerCancelled = false;
                                _dragValue = _progressValue.value;
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
                                if (!cancelled) await _jumpToProgress(target);
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
                        ),
                      GlassDock(
                        key: const ValueKey('reader-liquid-dock'),
                        selectedIndex: 1,
                        reduceMotion: widget.state.reduceMotion,
                        items: [
                          GlassDockItem(
                            CupertinoIcons.arrow_left,
                            '上一章',
                            enabled: _total > 0 && _chapter > 0,
                          ),
                          GlassDockItem(
                            CupertinoIcons.book,
                            '${_total == 0 ? 0 : _chapter + 1} / $_total',
                            enabled: _total > 0,
                            selectableOnDrag: false,
                            semanticLabel:
                                '目录，当前第 ${_total == 0 ? 0 : _chapter + 1} 章，共 $_total 章',
                          ),
                          GlassDockItem(
                            CupertinoIcons.arrow_right,
                            '下一章',
                            enabled: _chapter + 1 < _total,
                          ),
                        ],
                        onSelected: (index) {
                          if (index == 1) {
                            _catalogue();
                          } else {
                            _goTo(_chapter + (index == 0 ? -1 : 1));
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

  Widget _message(String text) => Center(child: Text(text));

  Widget _content(BuildContext context) {
    final media = MediaQuery.of(context);
    final cacheWidth = (media.size.width * media.devicePixelRatio)
        .clamp(800, 2400)
        .round();
    return FutureBuilder<
      ({List<EpubBlock> blocks, Map<String, Uint8List> images})
    >(
      future: _load(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('章节加载失败'),
                const SizedBox(height: 12),
                TextButton(onPressed: _retry, child: const Text('重试')),
              ],
            ),
          );
        }
        final data = snapshot.data!;
        // 懒加载：只构建可见块，不是一次性把整章所有块（含图片 widget）
        // 全部建出来；每次只加载一章图片。切换章节时 connectionState != done，
        // 上方分支返回加载指示，不会把旧章正文当成新章显示；旧 snapshot
        // 是否保留取决于 FutureBuilder 内部，不作为保证。
        return NotificationListener<ScrollMetricsNotification>(
          onNotification: (notification) {
            // 内容尺寸变化（图片解码、字号）后刷新进度与单章可滚动状态。
            if (_hasLayout) {
              _lastOffset = _scroll.offset;
              _lastMax = _scroll.position.maxScrollExtent;
            }
            _updateProgress();
            if (_total == 1) {
              final scrollable = notification.metrics.maxScrollExtent > 0;
              if (scrollable != _singleScrollable) {
                setState(() => _singleScrollable = scrollable);
              }
            }
            return false;
          },
          child: ListView.builder(
            key: ValueKey('epub-chapter-$_chapter-$_chapterVisit'),
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
              20 + media.padding.left,
              media.padding.top + FrostedHeader.toolbarHeight + 16,
              20 + media.padding.right,
              media.padding.bottom + 108,
            ),
            itemCount: data.blocks.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Text(
                    _chapterTitle(),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              }
              return _block(data.blocks[index - 1], data.images, cacheWidth);
            },
          ),
        );
      },
    );
  }

  Widget _block(
    EpubBlock block,
    Map<String, Uint8List> images,
    int cacheWidth,
  ) {
    if (block.kind == EpubBlockKind.image) {
      final bytes = images[block.entryPath];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: bytes == null
            ? _brokenImage()
            : Image.memory(
                bytes,
                fit: BoxFit.fitWidth,
                width: double.infinity,
                cacheWidth: cacheWidth,
                errorBuilder: (_, _, _) => _brokenImage(),
              ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(
        block.text ?? '',
        style: TextStyle(
          fontSize: widget.state.fontSize,
          height: widget.state.lineHeight,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .87),
        ),
      ),
    );
  }

  Widget _brokenImage() {
    return const Center(child: Icon(Icons.broken_image, size: 48));
  }
}

/// 底部全书进度条：样式与行为同 TXT 阅读器的 _ReaderProgressBar（pages.dart）。
/// 平时只显示纤细轨道；拖动时显示滑块和"第 N 章 · X%"预览。
class _EpubProgressBar extends StatelessWidget {
  const _EpubProgressBar({
    super.key,
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
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
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
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.15,
                                  ),
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
                                  left: (w * value.clamp(0.0, 1.0) - 7).clamp(
                                    0.0,
                                    math.max(0.0, w - 14),
                                  ),
                                  top: -5,
                                  child: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: scheme.primary,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.2,
                                          ),
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
