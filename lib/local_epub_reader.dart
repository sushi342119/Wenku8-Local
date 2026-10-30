import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

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

  int get _total => _novel.chapters.length;

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _total > 0) unawaited(_saveChapter(_chapter));
    });
  }

  Future<({List<EpubBlock> blocks, Map<String, Uint8List> images})> _load() {
    if (_future == null || _futureChapter != _chapter) {
      _futureChapter = _chapter;
      _future = widget.local.epubChapter(widget.novel.id, _chapter);
    }
    return _future!;
  }

  Future<void> _saveChapter(int chapter) async {
    final width = MediaQuery.sizeOf(context).width;
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

  void _goTo(int chapter, {bool restart = false}) {
    if (chapter < 0 || chapter >= _total) return;
    if (chapter == _chapter && !restart) return;
    unawaited(_saveChapter(chapter));
    setState(() {
      if (_chapter != chapter) {
        _future = null;
        _futureChapter = null;
      }
      _chapter = chapter;
      _chapterVisit++;
    });
    _showChrome(true);
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
    _chrome.dispose();
    super.dispose();
  }

  void _retry() {
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
                  child: GlassDock(
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
        return ListView.builder(
          key: ValueKey('epub-chapter-$_chapter-$_chapterVisit'),
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
