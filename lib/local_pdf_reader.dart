import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_ui.dart';
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
  });

  final Novel novel;
  final LibraryState state;
  final LocalLibraryStore local;

  @override
  State<LocalPdfReaderPage> createState() => _LocalPdfReaderPageState();
}

class _LocalPdfReaderPageState extends State<LocalPdfReaderPage>
    with WidgetsBindingObserver {
  late final PageController _controller;
  late final ReadingActivitySession _readingActivity;
  late int _page;
  bool _activityAttached = true;
  bool _activityForeground = true;
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
        : widget.state.chapterForNovel(widget.novel).clamp(0, count - 1);
    _controller = PageController(initialPage: _page);
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
    super.dispose();
  }

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

  @override
  Widget build(BuildContext context) {
    final count = _pageCount;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: novelSystemUiStyle(Brightness.dark),
      child: Scaffold(
        backgroundColor: const Color(0xFF141414),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1E1E1E),
          foregroundColor: Colors.white,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.novel.title,
                style: const TextStyle(fontSize: 16),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                count == 0 ? '' : '第 ${_page + 1} 页 / 共 $count 页',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
        ),
        body: count == 0
            ? const Center(
                child: Text(
                  '无法读取该 PDF',
                  style: TextStyle(color: Colors.white70),
                ),
              )
            : Stack(
                children: [
                  Positioned.fill(
                    child: PageView.builder(
                      controller: _controller,
                      itemCount: count,
                      onPageChanged: _onPageChanged,
                      itemBuilder: (context, page) => FutureBuilder<String>(
                        future: _render(page),
                        builder: (context, snapshot) {
                          if (snapshot.hasData) {
                            return InteractiveViewer(
                              minScale: 1,
                              maxScale: 4,
                              child: Center(
                                child: Image.file(
                                  File(snapshot.data!),
                                  fit: BoxFit.contain,
                                  cacheWidth:
                                      (MediaQuery.devicePixelRatioOf(context) *
                                              MediaQuery.sizeOf(context).width)
                                          .round()
                                          .clamp(800, 2400),
                                  errorBuilder: (context, error, stack) {
                                    _pending.remove(page);
                                    return const Icon(
                                      Icons.broken_image_outlined,
                                      color: Colors.white38,
                                      size: 48,
                                    );
                                  },
                                ),
                              ),
                            );
                          }
                          if (snapshot.hasError) {
                            return Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.broken_image_outlined,
                                    color: Colors.white38,
                                    size: 48,
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    '页面加载失败',
                                    style: TextStyle(color: Colors.white70),
                                  ),
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
                          return const Center(
                            child: CircularProgressIndicator(
                              color: Colors.white54,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  if (count > 1)
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: MediaQuery.paddingOf(context).bottom + 16,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF222226,
                              ).withValues(alpha: .88),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: .12),
                                width: .8,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              child: Row(
                                children: [
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    color: Colors.white,
                                    disabledColor: Colors.white30,
                                    onPressed: _page > 0
                                        ? () => _controller.previousPage(
                                            duration: NovelMotion.enter,
                                            curve: NovelMotion.ease,
                                          )
                                        : null,
                                    icon: const Icon(
                                      Icons.chevron_left_rounded,
                                    ),
                                    tooltip: '上一页',
                                  ),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 3,
                                        thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 6,
                                        ),
                                        overlayShape:
                                            const RoundSliderOverlayShape(
                                              overlayRadius: 14,
                                            ),
                                      ),
                                      child: Slider(
                                        value: _page
                                            .clamp(0, count - 1)
                                            .toDouble(),
                                        min: 0,
                                        max: (count - 1).toDouble(),
                                        activeColor: Colors.white,
                                        inactiveColor: Colors.white24,
                                        onChanged: (value) =>
                                            _controller.jumpToPage(
                                              value.round().clamp(0, count - 1),
                                            ),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    color: Colors.white,
                                    disabledColor: Colors.white30,
                                    onPressed: _page + 1 < count
                                        ? () => _controller.nextPage(
                                            duration: NovelMotion.enter,
                                            curve: NovelMotion.ease,
                                          )
                                        : null,
                                    icon: const Icon(
                                      Icons.chevron_right_rounded,
                                    ),
                                    tooltip: '下一页',
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
