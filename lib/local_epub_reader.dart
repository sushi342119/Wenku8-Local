import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'local_epub.dart';
import 'local_library.dart';

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

class _LocalEpubReaderPageState extends State<LocalEpubReaderPage> {
  static const _background = Color(0xFF121212);
  static const _barColor = Color(0xFF1E1E1E);

  late final int _total;
  late int _chapter;
  Future<({List<EpubBlock> blocks, Map<String, Uint8List> images})>? _future;
  int? _futureChapter;

  @override
  void initState() {
    super.initState();
    _total = widget.local.bookFor(widget.novel.id)?.chapters.length ??
        widget.novel.chapters.length;
    if (_total <= 0) {
      _chapter = 0;
    } else if (widget.initialChapter >= 0 && widget.initialChapter < _total) {
      _chapter = widget.initialChapter;
    } else {
      _chapter = widget.state.chapterForNovel(widget.novel).clamp(0, _total - 1);
    }
  }

  Future<({List<EpubBlock> blocks, Map<String, Uint8List> images})> _load() {
    if (_future == null || _futureChapter != _chapter) {
      _futureChapter = _chapter;
      _future = widget.local.epubChapter(widget.novel.id, _chapter);
    }
    return _future!;
  }

  void _goTo(int chapter) {
    if (chapter < 0 || chapter >= _total || chapter == _chapter) return;
    unawaited(widget.state.setChapter(widget.novel.id, chapter));
    setState(() {
      _chapter = chapter;
      _future = null;
      _futureChapter = null;
    });
  }

  @override
  void dispose() {
    // 页面不持有 EpubPackage；epubChapter() 完成时会在 finally 中关闭包。
    // 清引用不会取消尚未完成的加载；ImageCache 可能继续持有图片字节，
    // 因此 dispose 不保证立即释放全部图片内存。
    _future = null;
    _futureChapter = null;
    super.dispose();
  }

  void _retry() {
    setState(() {
      _future = null;
      _futureChapter = null;
    });
  }

  String _chapterTitle() {
    final bookChapters = widget.local.bookFor(widget.novel.id)?.chapters;
    if (bookChapters != null && _chapter < bookChapters.length) {
      return bookChapters[_chapter].title;
    }
    if (_chapter < widget.novel.chapters.length) {
      return widget.novel.chapters[_chapter].title;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _total > 0 ? '第 ${_chapter + 1} 章 / 共 $_total 章' : '';
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _barColor,
        foregroundColor: Colors.white,
        systemOverlayStyle: novelSystemUiStyle(Brightness.dark),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.novel.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '上一章',
            icon: const Icon(Icons.chevron_left),
            onPressed: _total > 0 && _chapter > 0 ? () => _goTo(_chapter - 1) : null,
          ),
          IconButton(
            tooltip: '下一章',
            icon: const Icon(Icons.chevron_right),
            onPressed:
                _total > 0 && _chapter < _total - 1 ? () => _goTo(_chapter + 1) : null,
          ),
        ],
      ),
      body: _total <= 0 ? _message('暂无章节') : _content(context),
    );
  }

  Widget _message(String text) {
    return Center(
      child: Text(text, style: const TextStyle(color: Colors.white70)),
    );
  }

  Widget _content(BuildContext context) {
    final media = MediaQuery.of(context);
    final cacheWidth =
        (media.size.width * media.devicePixelRatio).clamp(800, 2400).round();
    return FutureBuilder<({List<EpubBlock> blocks, Map<String, Uint8List> images})>(
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
                const Text('章节加载失败', style: TextStyle(color: Colors.white70)),
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
          key: ValueKey(_chapter),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
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
                    color: Colors.white,
                  ),
                ),
              );
            }
            return _block(
              data.blocks[index - 1],
              data.images,
              cacheWidth,
            );
          },
        );
      },
    );
  }

  Widget _block(EpubBlock block, Map<String, Uint8List> images, int cacheWidth) {
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
          fontSize: 17,
          height: 1.6,
          color: Colors.white.withValues(alpha: 0.87),
        ),
      ),
    );
  }

  Widget _brokenImage() {
    return const Center(
      child: Icon(Icons.broken_image, color: Colors.white38, size: 48),
    );
  }
}
