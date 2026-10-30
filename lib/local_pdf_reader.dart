import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_ui.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'local_library.dart';
import 'local_platform.dart';

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

class _LocalPdfReaderPageState extends State<LocalPdfReaderPage> {
  late final PageController _controller;
  late int _page;
  final Map<int, Future<String>> _pending = {};

  int get _pageCount {
    final book = widget.local.bookFor(widget.novel.id);
    return book?.pageCount ?? 0;
  }

  @override
  void initState() {
    super.initState();
    final count = _pageCount;
    _page = count == 0
        ? 0
        : widget.state.chapterForNovel(widget.novel).clamp(0, count - 1);
    _controller = PageController(initialPage: _page);
  }

  @override
  void dispose() {
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
            : PageView.builder(
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
                      child: CircularProgressIndicator(color: Colors.white54),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
