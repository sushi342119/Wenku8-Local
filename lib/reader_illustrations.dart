import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_ui.dart';
import 'cover_arrival.dart';
import 'legacy_transport.dart';

typedef IllustrationRequest = Future<Uint8List> Function(String url);

/// Decoded images are bounded by Flutter's image cache; encoded images by bytes,
/// not by chapter count. Completed futures are not retained after eviction.
class ReaderIllustrationCache {
  ReaderIllustrationCache({
    IllustrationRequest? request,
    this.maxBytes = 16 * 1024 * 1024,
  }) : _request = request ?? LegacyTransport.illustration;
  static final shared = ReaderIllustrationCache();
  final IllustrationRequest _request;
  final int maxBytes;
  final _pending = <String, Future<Uint8List>>{};
  final _cache = <String, Uint8List>{};
  int _bytes = 0;
  int _epoch = 0;
  int get encodedBytes => _bytes;
  Uint8List? peek(String url) => _cache[url];
  Future<Uint8List> load(String url) {
    final cached = _cache.remove(url);
    if (cached != null) {
      _cache[url] = cached;
      return Future.value(cached);
    }
    return _pending.putIfAbsent(url, () async {
      final epoch = _epoch;
      try {
        final bytes = await _request(url);
        if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
          throw const FormatException('插图大小无效');
        }
        if (epoch == _epoch && bytes.length <= maxBytes) {
          while (_bytes + bytes.length > maxBytes && _cache.isNotEmpty) {
            _bytes -= _cache.remove(_cache.keys.first)!.length;
          }
          _cache[url] = bytes;
          _bytes += bytes.length;
        }
        return bytes;
      } finally {
        if (epoch == _epoch) _pending.remove(url);
      }
    });
  }

  void clearMemory() {
    _epoch++;
    _cache.clear();
    _pending.clear();
    _bytes = 0;
  }
}

class ReaderIllustration extends StatefulWidget {
  const ReaderIllustration({
    super.key,
    required this.url,
    this.onOpen,
    this.cache,
    this.fullScreen = false,
  });
  final String url;
  final VoidCallback? onOpen;
  final ReaderIllustrationCache? cache;
  final bool fullScreen;
  @override
  State<ReaderIllustration> createState() => _ReaderIllustrationState();
}

class _ReaderIllustrationState extends State<ReaderIllustration> {
  late Future<({Uint8List? bytes, Object? error})> _future = _load();
  Future<({Uint8List? bytes, Object? error})> _load() async {
    try {
      return (
        bytes: await (widget.cache ?? ReaderIllustrationCache.shared).load(
          widget.url,
        ),
        error: null,
      );
    } catch (error) {
      return (bytes: null, error: error);
    }
  }

  @override
  void didUpdateWidget(ReaderIllustration old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.cache != widget.cache) _future = _load();
  }

  @override
  Widget build(BuildContext context) {
    final content = FutureBuilder<({Uint8List? bytes, Object? error})>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data?.bytes;
        if (snapshot.data?.error != null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(CupertinoIcons.photo, size: 28),
                const SizedBox(height: 12),
                const Text('插图加载失败'),
                GlassTextButton(
                  onPressed: () => setState(() => _future = _load()),
                  child: const Text('重试插图'),
                ),
              ],
            ),
          );
        }
        if (bytes == null) {
          return const LoadingSkeleton(
            layout: SkeletonLayout.cover,
            label: '正在载入插图',
          );
        }
        return GestureDetector(
          onTap: widget.onOpen,
          child: Semantics(
            label: '章节插图，点击查看大图',
            image: true,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              cacheWidth: widget.fullScreen
                  ? 2400
                  : (MediaQuery.sizeOf(context).width *
                            MediaQuery.devicePixelRatioOf(context))
                        .round()
                        .clamp(1, 1600),
              frameBuilder: (context, child, frame, sync) => CoverArrival(
                bytes: bytes,
                ready: frame != null,
                placeholder: const LoadingSkeleton(
                  layout: SkeletonLayout.cover,
                  label: '正在解码插图',
                ),
                child: child,
              ),
              errorBuilder: (context, error, stack) => Center(
                child: GlassTextButton(
                  onPressed: () {
                    (widget.cache ?? ReaderIllustrationCache.shared)
                        .clearMemory();
                    setState(() => _future = _load());
                  },
                  child: const Text('重新读取插图'),
                ),
              ),
            ),
          ),
        );
      },
    );
    return RepaintBoundary(
      child: widget.fullScreen
          ? content
          : SizedBox(
              height: (MediaQuery.sizeOf(context).width - 52) * 4 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
                child: content,
              ),
            ),
    );
  }
}

class ReaderIllustrationGallery extends StatefulWidget {
  const ReaderIllustrationGallery({
    super.key,
    required this.urls,
    required this.initialUrl,
    this.cache,
  }) : assert(urls.length > 0);
  final List<String> urls;
  final String initialUrl;
  final ReaderIllustrationCache? cache;
  @override
  State<ReaderIllustrationGallery> createState() =>
      _ReaderIllustrationGalleryState();
}

class _ReaderIllustrationGalleryState extends State<ReaderIllustrationGallery> {
  late int _page = widget.urls
      .indexOf(widget.initialUrl)
      .clamp(0, widget.urls.length - 1);
  late final _pages = PageController(initialPage: _page);
  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Atmosphere(
      child: GlassHeaderLayout(
        header: Row(
          children: [
            GlassIconButton(
              icon: CupertinoIcons.back,
              label: '返回阅读',
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: ArchiveRouteTitle(
                title: '章节插图',
                code: 'IMAGE / ${_page + 1} OF ${widget.urls.length}',
              ),
            ),
          ],
        ),
        body: Padding(
          padding: EdgeInsets.only(
            top:
                MediaQuery.paddingOf(context).top + FrostedHeader.toolbarHeight,
            bottom: MediaQuery.paddingOf(context).bottom,
          ),
          child: PageView.builder(
            controller: _pages,
            itemCount: widget.urls.length,
            onPageChanged: (page) => setState(() => _page = page),
            itemBuilder: (context, index) => InteractiveViewer(
              key: ValueKey(widget.urls[index]),
              minScale: 1,
              maxScale: 5,
              child: SizedBox.expand(
                child: ReaderIllustration(
                  url: widget.urls[index],
                  cache: widget.cache,
                  fullScreen: true,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
