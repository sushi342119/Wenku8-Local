import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'feature_pages.dart';
import 'gallery_save_button.dart';
import 'local_platform.dart';
import 'reading_export_theme.dart';
import 'reading_keepsake_theme.dart';
import 'reading_visual_theme.dart';
import 'reading_visual_theme_picker.dart';

enum QuoteCardStyle { paper, night }

class QuoteCardData {
  const QuoteCardData({
    required this.text,
    required this.book,
    required this.chapter,
    this.author = '',
    this.recordedAt,
  });
  final String text, book, author, chapter;

  /// Recording-zone civil clock. Legacy excerpts may not have a known date.
  final DateTime? recordedAt;
}

/// The preview and PNG use the same laid-out drawing, not a screen capture.
/// Long excerpts paginate into complete cards; neither text nor attribution is
/// silently cropped to fit an arbitrary phone viewport.
class QuoteCardLayout {
  QuoteCardLayout._(
    this.data,
    this.style,
    this.theme,
    this.artAt,
    this.serifFamily,
    this._geometry,
    this.body,
    this.title,
    this.source,
  );
  static const width = 480.0;
  final QuoteCardData data;
  final QuoteCardStyle style;
  final ReadingVisualTheme theme;

  /// One artwork date per composition; it is not a fabricated recording date.
  final DateTime artAt;
  final String? serifFamily;
  final _QuoteGeometry _geometry;
  final TextPainter body, title, source;
  double get height => math.max(
    _geometry.minimumHeight,
    _geometry.top +
        body.height +
        92 +
        title.height +
        source.height +
        88 +
        _geometry.artFooter,
  );
  ReadingExportTheme get edition => readingExportTheme(theme);
  Color get background => edition.background;
  Color get ink => theme == ReadingVisualTheme.signal
      ? const Color(0xff272727)
      : edition.foreground;
  Color get muted => theme == ReadingVisualTheme.signal
      ? const Color(0xff6f7169)
      : edition.muted;
  String get artAsset => readingKeepsakeArt(theme, artAt: artAt);
  Rect get bodyBounds => Rect.fromLTWH(
    _geometry.left,
    _geometry.top,
    _geometry.bodyWidth,
    body.height,
  );
  double get _footerTop =>
      height - _geometry.artFooter - 88 - source.height - title.height;

  static List<QuoteCardLayout> prepare(
    QuoteCardData data,
    QuoteCardStyle style, {
    ReadingVisualTheme? theme,
    String? serifFamily,
    DateTime? artAt,
  }) {
    final artworkDate = data.recordedAt ?? artAt ?? DateTime.now();
    final visual =
        theme ??
        (style == QuoteCardStyle.paper
            ? ReadingVisualTheme.editorial
            : ReadingVisualTheme.constellation);
    final spec = _QuoteGeometry.forTheme(visual);
    final appearance = readingExportTheme(visual);
    final ink = visual == ReadingVisualTheme.signal
        ? const Color(0xff272727)
        : appearance.foreground;
    final muted = visual == ReadingVisualTheme.signal
        ? const Color(0xff6f7169)
        : appearance.muted;
    TextPainter text(
      String value,
      double size,
      Color color, {
      double height = 1.7,
      FontWeight weight = FontWeight.w400,
    }) =>
        TextPainter(
          text: TextSpan(
            text: value,
            style: TextStyle(
              fontFamily: appearance.prefersSerif
                  ? (serifFamily ?? 'CupertinoSystemText')
                  : 'CupertinoSystemText',
              fontFamilyFallback: const ['CupertinoSystemText'],
              fontSize: size,
              height: height,
              color: color,
              fontWeight: weight,
            ),
          ),
          textAlign: visual == ReadingVisualTheme.score
              ? TextAlign.center
              : TextAlign.left,
          textDirection: TextDirection.ltr,
        )..layout(
          minWidth: visual == ReadingVisualTheme.score ? spec.bodyWidth : 0,
          maxWidth: spec.bodyWidth,
        );
    var remaining = data.text.trim();
    final result = <QuoteCardLayout>[];
    while (remaining.isNotEmpty) {
      var body = text(remaining, spec.fontSize, ink, height: 1.85);
      if (body.height > 880) {
        final last = body.computeLineMetrics().lastWhere(
          (line) => line.baseline + line.descent <= 880,
        );
        final boundary = body.getLineBoundary(
          body.getPositionForOffset(Offset(0, last.baseline)),
        );
        final end = boundary.end.clamp(1, remaining.length);
        body.dispose();
        body = text(
          remaining.substring(0, end).trimRight(),
          spec.fontSize,
          ink,
          height: 1.85,
        );
        remaining = remaining.substring(end).trimLeft();
      } else {
        remaining = '';
      }
      result.add(
        QuoteCardLayout._(
          data,
          style,
          visual,
          artworkDate,
          serifFamily,
          spec,
          body,
          text(
            data.book.trim().isEmpty ? '' : '《${data.book.trim()}》',
            15,
            ink,
            height: 1.65,
            weight: FontWeight.w700,
          ),
          text(
            [
              if (data.author.trim().isNotEmpty) data.author.trim(),
              if (data.chapter.trim().isNotEmpty) data.chapter.trim(),
            ].where((v) => v.isNotEmpty).join(' · '),
            11.5,
            muted,
          ),
        ),
      );
    }
    return result;
  }

  void paint(
    Canvas canvas,
    Size size, {
    ui.Image? icon,
    ui.Image? artwork,
    bool watermark = true,
    int page = 0,
    int pages = 1,
  }) {
    canvas.save();
    canvas.scale(size.width / width, size.height / height);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, height),
      Paint()..color = background,
    );
    _paintComposition(canvas, artwork);
    body.paint(canvas, Offset(_geometry.left, _geometry.top));
    final footer = _footerTop;
    final ruleLeft = theme == ReadingVisualTheme.score
        ? (width - 32) / 2
        : _geometry.left;
    canvas.drawLine(
      Offset(ruleLeft, footer - 26),
      Offset(ruleLeft + 32, footer - 26),
      Paint()
        ..color = muted.withValues(alpha: .55)
        ..strokeWidth = 1.2,
    );
    title.paint(canvas, Offset(_geometry.left, footer));
    source.paint(canvas, Offset(_geometry.left, footer + title.height + 5));
    if (watermark && icon != null) {
      final rect = Rect.fromLTWH(
        width - 84,
        height - _geometry.artFooter - 57,
        30,
        30,
      );
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(9)));
      canvas.drawImageRect(
        icon,
        Rect.fromLTWH(0, 0, icon.width.toDouble(), icon.height.toDouble()),
        rect,
        Paint()..filterQuality = FilterQuality.high,
      );
      canvas.restore();
    }
    if (pages > 1) {
      final counter = TextPainter(
        text: TextSpan(
          text: '${page + 1} / $pages',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 9,
            letterSpacing: 1.4,
            color: muted,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      counter.paint(
        canvas,
        Offset(_geometry.left, height - _geometry.artFooter - 47),
      );
      counter.dispose();
    }
    canvas.restore();
  }

  void _label(
    Canvas canvas,
    String value,
    Offset offset, {
    double size = 10,
    Color? color,
    double maxWidth = 380,
    bool serif = false,
    FontWeight weight = FontWeight.w500,
    double spacing = 0,
    TextAlign align = TextAlign.left,
  }) {
    final text =
        TextPainter(
          text: TextSpan(
            text: value,
            style: TextStyle(
              color: color ?? muted,
              fontSize: size,
              height: 1.25,
              fontFamily: serif ? 'ReadingSerifDisplay' : 'ReadingDisplay',
              fontFamilyFallback: const ['CupertinoSystemText'],
              fontWeight: weight,
              letterSpacing: spacing,
            ),
          ),
          textAlign: align,
          textDirection: TextDirection.ltr,
        )..layout(
          minWidth: align == TextAlign.center ? maxWidth : 0,
          maxWidth: maxWidth,
        );
    text.paint(canvas, offset);
    text.dispose();
  }

  void _paintComposition(Canvas canvas, ui.Image? artwork) {
    final s = edition;
    void art(Rect bounds, {Alignment? alignment, bool full = false}) {
      if (artwork == null) return;
      paintImage(
        canvas: canvas,
        rect: bounds,
        image: artwork,
        fit: full ? BoxFit.contain : BoxFit.cover,
        alignment: alignment ?? s.previewAlignment,
        filterQuality: FilterQuality.high,
      );
    }

    void line(
      double x,
      double y,
      double length, {
      Color? color,
      double stroke = 1,
    }) => canvas.drawLine(
      Offset(x, y),
      Offset(x + length, y),
      Paint()
        ..color = color ?? s.muted.withValues(alpha: .35)
        ..strokeWidth = stroke,
    );
    void heading(
      String value,
      Offset offset, {
      Color? color,
      double size = 32,
      double maxWidth = 380,
    }) => _label(
      canvas,
      value,
      offset,
      size: size,
      color: color ?? s.foreground,
      maxWidth: maxWidth,
      serif: s.prefersSerif,
      weight: FontWeight.w700,
    );
    void filmHoles() {
      for (var y = 28.0; y < height - 28; y += 26) {
        for (final x in [13.0, 459.0]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x, y, 8, 12),
              const Radius.circular(1.5),
            ),
            Paint()..color = s.muted.withValues(alpha: .4),
          );
        }
      }
    }

    void sceneHeader() {
      art(const Rect.fromLTWH(0, 0, width, 270), alignment: Alignment.center);
      canvas.drawRect(
        const Rect.fromLTWH(0, 150, width, 145),
        Paint()
          ..shader = ui.Gradient.linear(
            const Offset(0, 150),
            const Offset(0, 295),
            [s.background.withValues(alpha: 0), s.background],
          ),
      );
    }

    void date(Offset offset, {Color? color, double maxWidth = 384}) {
      final at = data.recordedAt;
      if (at == null) return;
      _label(
        canvas,
        '${at.year}.${at.month.toString().padLeft(2, '0')}.${at.day.toString().padLeft(2, '0')}',
        offset,
        size: 10,
        color: color ?? s.muted,
        maxWidth: maxWidth,
      );
    }

    switch (theme) {
      case ReadingVisualTheme.archive:
        _label(
          canvas,
          '摘录',
          const Offset(48, 29),
          color: s.accent,
          size: 11,
          spacing: 1.6,
        );
        art(
          const Rect.fromLTWH(282, 44, 150, 200),
          alignment: Alignment.topRight,
          full: true,
        );
        canvas.drawRect(
          const Rect.fromLTWH(32, 250, 416, 7),
          Paint()..color = s.accent,
        );
        date(const Offset(48, 266));
      case ReadingVisualTheme.shelf:
        sceneHeader();
        date(const Offset(48, 270));
        canvas.drawLine(
          const Offset(27, 336),
          Offset(27, _footerTop + 20),
          Paint()
            ..color = s.accent.withValues(alpha: .5)
            ..strokeWidth = 1,
        );
      case ReadingVisualTheme.editorial:
        _label(
          canvas,
          '摘录',
          const Offset(32, 27),
          size: 10,
          spacing: 1.4,
          color: s.accent,
        );
        art(
          const Rect.fromLTWH(24, 91, 432, 243.2),
          alignment: Alignment.center,
          full: true,
        );
        line(32, 350, 416, color: s.accent);
        date(const Offset(32, 364));
      case ReadingVisualTheme.constellation:
        art(
          const Rect.fromLTWH(228, 24, 224, 392),
          alignment: s.previewAlignment,
        );
        _label(
          canvas,
          '摘录',
          const Offset(48, 31),
          size: 9.5,
          color: s.accent,
          maxWidth: 166,
          spacing: .6,
        );
        if (data.recordedAt case final at?) {
          heading(
            '${at.hour.toString().padLeft(2, '0')}:'
            '${at.minute.toString().padLeft(2, '0')}',
            const Offset(48, 78),
            size: 36,
            maxWidth: 170,
          );
        }
        date(const Offset(48, 202), maxWidth: 165);
        line(48, 238, 100, color: s.accent, stroke: 2);
        line(48, 424, 384, color: s.accent.withValues(alpha: .55));
      case ReadingVisualTheme.signal:
        _label(
          canvas,
          '摘录',
          const Offset(32, 38),
          color: s.muted,
          size: 9.5,
          maxWidth: 170,
          spacing: .5,
        );
        art(
          const Rect.fromLTWH(234, 18, 222, 296),
          full: true,
          alignment: Alignment.topRight,
        );
        final paper = Path()..moveTo(24, 350);
        for (var x = 24.0; x < 456; x += 18) {
          paper
            ..lineTo(x + 9, 345)
            ..lineTo(x + 18, 350);
        }
        paper
          ..lineTo(456, height - 20)
          ..lineTo(24, height - 20)
          ..close();
        canvas.drawPath(paper, Paint()..color = const Color(0xfff4f2e9));
      case ReadingVisualTheme.score:
        filmHoles();
        _label(
          canvas,
          '摘录',
          const Offset(38, 27),
          color: s.accent,
          size: 10,
          spacing: 1,
        );
        art(
          const Rect.fromLTWH(32, 104, 416, 234),
          full: true,
          alignment: Alignment.center,
        );
        line(38, 358, 404, color: s.accent);
        date(const Offset(38, 372));
      case ReadingVisualTheme.ink:
        sceneHeader();
        date(const Offset(48, 290));
        line(48, 315, 384, color: s.accent.withValues(alpha: .4));
      case ReadingVisualTheme.festival:
        canvas.drawRect(
          const Rect.fromLTWH(24, 26, 432, 285),
          Paint()..color = const Color(0xfffcfbf7),
        );
        art(
          const Rect.fromLTWH(32, 34, 416, 234),
          full: true,
          alignment: Alignment.center,
        );
        _label(
          canvas,
          '摘录',
          const Offset(44, 281),
          color: s.foreground,
          size: 13,
          spacing: 1,
        );
        date(const Offset(300, 282), maxWidth: 136);
        for (var x = 32.0; x < 448; x += 13) {
          line(x, 333, 5, color: s.muted.withValues(alpha: .55));
        }
    }
    _label(
      canvas,
      readingExportBrandName,
      Offset(_geometry.left, height - 30),
      size: 9,
      color: muted,
      maxWidth: 250,
      spacing: 1,
    );
  }

  Future<Uint8List> png({
    ui.Image? icon,
    ui.Image? artwork,
    bool watermark = true,
    int page = 0,
    int pages = 1,
  }) async {
    final ownedArtwork =
        artwork?.clone() ?? await loadQuoteThemeArt(theme, artAt: artAt);
    final ratio = [
      1080 / width,
      8192 / height,
      math.sqrt(12000000 / (width * height)),
    ].reduce(math.min);
    final pixels = (width * ratio).floor();
    final pixelHeight = (height * ratio).floor();
    final recorder = ui.PictureRecorder();
    paint(
      Canvas(recorder),
      Size(pixels.toDouble(), pixelHeight.toDouble()),
      icon: icon,
      artwork: ownedArtwork,
      watermark: watermark,
      page: page,
      pages: pages,
    );
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(pixels, pixelHeight);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw const FormatException('图片生成失败，请重试');
        final png = bytes.buffer.asUint8List();
        if (png.length > 12 * 1024 * 1024) {
          throw const FormatException('摘录内容过长，图片超过保存上限');
        }
        return png;
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
      ownedArtwork.dispose();
    }
  }

  void dispose() {
    body.dispose();
    title.dispose();
    source.dispose();
  }
}

class _QuoteGeometry {
  const _QuoteGeometry(
    this.left,
    this.top,
    this.bodyWidth,
    this.minimumHeight, {
    this.fontSize = 25,
  });
  final double left, top, bodyWidth, minimumHeight, fontSize;
  double get artFooter => 0;
  static _QuoteGeometry forTheme(ReadingVisualTheme theme) => switch (theme) {
    ReadingVisualTheme.archive => const _QuoteGeometry(48, 300, 384, 790),
    ReadingVisualTheme.shelf => const _QuoteGeometry(
      48,
      345,
      384,
      890,
      fontSize: 24,
    ),
    ReadingVisualTheme.editorial => const _QuoteGeometry(48, 407, 384, 940),
    ReadingVisualTheme.constellation => const _QuoteGeometry(48, 460, 384, 990),
    ReadingVisualTheme.signal => const _QuoteGeometry(
      52,
      398,
      376,
      950,
      fontSize: 24,
    ),
    ReadingVisualTheme.score => const _QuoteGeometry(
      52,
      418,
      376,
      970,
      fontSize: 24,
    ),
    ReadingVisualTheme.ink => const _QuoteGeometry(
      48,
      348,
      384,
      900,
      fontSize: 25,
    ),
    ReadingVisualTheme.festival => const _QuoteGeometry(48, 370, 384, 920),
  };
}

/// The caller owns the decoded image. One full-width decode serves preview and
/// export; changing pages never decodes the same illustration again.
Future<ui.Image> loadQuoteThemeArt(
  ReadingVisualTheme theme, {
  DateTime? recordedAt,
  DateTime? artAt,
}) async {
  final bytes = await rootBundle.load(
    readingKeepsakeArt(theme, recordedAt: recordedAt, artAt: artAt),
  );
  final codec = await ui.instantiateImageCodec(
    bytes.buffer.asUint8List(),
    targetWidth: 1080,
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

class QuoteCardPage extends StatefulWidget {
  const QuoteCardPage({super.key, required this.data, this.serifFamily});
  final QuoteCardData data;
  final String? serifFamily;
  @override
  State<QuoteCardPage> createState() => _QuoteCardPageState();
}

class _QuoteCardPageState extends State<QuoteCardPage> {
  late final DateTime _artAt = widget.data.recordedAt ?? DateTime.now();
  ReadingVisualTheme _theme = ReadingVisualTheme.archive;
  ReadingVisualTheme _displayTheme = ReadingVisualTheme.archive;
  bool _artworkLoading = false;
  bool _choosingTheme = false;
  late List<QuoteCardLayout> _cards = QuoteCardLayout.prepare(
    widget.data,
    QuoteCardStyle.paper,
    theme: _theme,
    serifFamily: widget.serifFamily,
    artAt: _artAt,
  );
  int _page = 0;
  bool _watermark = true, _busy = false, _showBookDetails = true;
  ui.Image? _icon, _artwork;
  String? _error, _artworkError;
  int _artworkGeneration = 0;
  ReadingExportTheme get _appearance => readingExportTheme(_theme);
  bool get _previewReady =>
      !_artworkLoading &&
      _artworkError == null &&
      _displayTheme == _theme &&
      _artwork != null;
  QuoteCardData get _effectiveData => _showBookDetails
      ? widget.data
      : QuoteCardData(
          text: widget.data.text,
          book: '',
          chapter: '',
          recordedAt: widget.data.recordedAt,
        );
  @override
  void initState() {
    super.initState();
    _loadIcon();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    final selected = ReadingVisualTheme.fromId(
      preferences.getString('reading_quote_theme_v1'),
    );
    if (selected != _theme) {
      _changeTheme(selected, save: false);
    } else {
      await _loadArtwork();
    }
  }

  Future<void> _loadArtwork() async {
    final generation = ++_artworkGeneration;
    final theme = _theme;
    if (mounted) {
      setState(() {
        _artworkError = null;
        _artworkLoading = true;
      });
    }
    ui.Image? pendingImage;
    try {
      final image = await loadQuoteThemeArt(theme, artAt: _artAt);
      pendingImage = image;
      if (!mounted || generation != _artworkGeneration) {
        image.dispose();
        pendingImage = null;
        return;
      }
      final previous = _artwork;
      final previousCards = _cards;
      final nextCards = QuoteCardLayout.prepare(
        _effectiveData,
        readingExportTheme(theme).isDark
            ? QuoteCardStyle.night
            : QuoteCardStyle.paper,
        theme: theme,
        serifFamily: widget.serifFamily,
        artAt: _artAt,
      );
      setState(() {
        _artwork = image;
        _cards = nextCards;
        _displayTheme = theme;
        _artworkLoading = false;
        _page = _cards.isEmpty ? 0 : math.min(_page, _cards.length - 1);
      });
      pendingImage = null;
      previous?.dispose();
      for (final card in previousCards) {
        card.dispose();
      }
    } catch (_) {
      pendingImage?.dispose();
      if (mounted && generation == _artworkGeneration) {
        setState(() {
          _artworkLoading = false;
          _artworkError = '主题图片读取失败，请重试';
        });
      }
    }
  }

  Future<void> _loadIcon() async {
    try {
      final bytes = await rootBundle.load('assets/branding/app-icon.png');
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(),
        targetWidth: 96,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _icon = frame.image);
    } catch (_) {
      if (mounted) setState(() => _error = '图标读取失败，请重新打开分享卡片');
    }
  }

  void _changeTheme(ReadingVisualTheme value, {bool save = true}) {
    if (_theme == value || _busy) return;
    setState(() {
      _theme = value;
      _artworkError = null;
    });
    _loadArtwork();
    if (save) _saveTheme(value);
  }

  void _changeBookDetails(bool value) {
    if (_busy || value == _showBookDetails) return;
    for (final card in _cards) {
      card.dispose();
    }
    setState(() {
      _showBookDetails = value;
      _cards = QuoteCardLayout.prepare(
        _effectiveData,
        readingExportTheme(_displayTheme).isDark
            ? QuoteCardStyle.night
            : QuoteCardStyle.paper,
        theme: _displayTheme,
        serifFamily: widget.serifFamily,
        artAt: _artAt,
      );
      _page = _cards.isEmpty ? 0 : math.min(_page, _cards.length - 1);
    });
  }

  Future<void> _saveTheme(ReadingVisualTheme value) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        'reading_quote_theme_v1',
        value.id,
      );
    } catch (_) {
      if (mounted) showNovelFeedback(context, '主题未能保存，下次可重新选择');
    }
  }

  Future<void> _export(bool share, {String? authorizationToken}) async {
    if (_busy ||
        !_previewReady ||
        _cards.isEmpty ||
        _artwork == null ||
        (_watermark && _icon == null)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await _cards[_page].png(
        icon: _icon,
        artwork: _artwork,
        watermark: _watermark,
        page: _page,
        pages: _cards.length,
      );
      if (!mounted) return;
      final name =
          '文库摘录-${DateTime.now().millisecondsSinceEpoch}-${_page + 1}.png';
      if (share) {
        await LocalPlatform.shareImage(bytes, name);
      } else {
        await LocalPlatform.saveImageToGallery(
          bytes,
          name,
          authorizationToken: authorizationToken,
        );
        if (mounted) showNovelFeedback(context, '已保存到相册');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : share
              ? '图片未能分享，请重试'
              : gallerySaveFailureMessage(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _artworkGeneration++;
    _artwork?.dispose();
    _icon?.dispose();
    for (final card in _cards) {
      card.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '分享摘录',
    code: 'EXCERPT / EDITION',
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: ListView(
          padding: featurePadding(context),
          children: [
            if (_cards.isEmpty) const AppText('选取一段原文后，即可制作摘录图片。'),
            if (_cards.isNotEmpty)
              SizedBox(
                height: math.min(560, MediaQuery.sizeOf(context).height * .55),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: QuoteCardLayout.width / _cards[_page].height,
                    child: InteractiveViewer(
                      key: ValueKey(('quote-zoom', _displayTheme)),
                      minScale: 1,
                      maxScale: 3,
                      child: _artwork == null
                          ? Center(
                              child: _artworkError == null
                                  ? const CupertinoActivityIndicator()
                                  : GlassTextButton(
                                      key: const ValueKey(
                                        'quote-artwork-retry',
                                      ),
                                      onPressed: _loadArtwork,
                                      child: const AppText('重试主题图片'),
                                    ),
                            )
                          : TweenAnimationBuilder<double>(
                              key: ValueKey(('quote-arrival', _displayTheme)),
                              tween: Tween(begin: .8, end: 1),
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : NovelMotion.enter,
                              builder: (context, opacity, child) =>
                                  Opacity(opacity: opacity, child: child),
                              child: RepaintBoundary(
                                child: CustomPaint(
                                  key: const ValueKey('quote-card-preview'),
                                  painter: _QuotePainter(
                                    _cards[_page],
                                    _icon,
                                    _artwork,
                                    _watermark,
                                    _page,
                                    _cards.length,
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            SizedBox(
              height: 22,
              child: AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : NovelMotion.contact,
                child: _artworkLoading && _artwork != null
                    ? const Center(
                        key: ValueKey('quote-theme-loading'),
                        child: AppText(
                          '正在准备主题…',
                          style: TextStyle(fontSize: 12),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            GlassTextButton(
              key: const ValueKey('quote-theme-picker'),
              onPressed: _busy
                  ? null
                  : () => setState(() => _choosingTheme = !_choosingTheme),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppText('主题 · ${_appearance.label}'),
                  const SizedBox(width: 10),
                  Icon(
                    _choosingTheme
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    size: 13,
                  ),
                ],
              ),
            ),
            TweenAnimationBuilder<double>(
              tween: Tween(end: _choosingTheme ? 1 : 0),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : NovelMotion.enter,
              curve: NovelMotion.ease,
              builder: (context, value, _) => ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: value,
                  child: value == 0
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: ReadingVisualThemePicker(
                            value: _theme,
                            presentationFor: (theme) =>
                                readingKeepsakeThemePresentation(
                                  theme,
                                  recordedAt: widget.data.recordedAt,
                                  artAt: _artAt,
                                ),
                            onChanged: _busy
                                ? null
                                : (value) => _changeTheme(value),
                          ),
                        ),
                ),
              ),
            ),
            if (_cards.length > 1)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GlassIconButton(
                    icon: CupertinoIcons.chevron_left,
                    label: '上一张摘录',
                    onPressed: _busy || _page == 0
                        ? null
                        : () => setState(() => _page--),
                  ),
                  AppText('${_page + 1} / ${_cards.length}'),
                  GlassIconButton(
                    icon: CupertinoIcons.chevron_right,
                    label: '下一张摘录',
                    onPressed: _busy || _page + 1 == _cards.length
                        ? null
                        : () => setState(() => _page++),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(child: AppText('显示书籍信息')),
                AppControls.toggle(
                  context,
                  key: const ValueKey('quote-book-details'),
                  value: _showBookDetails,
                  onChanged: _busy ? null : _changeBookDetails,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(child: AppText('图标水印')),
                AppControls.toggle(
                  context,
                  key: const ValueKey('quote-watermark'),
                  value: _watermark,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _watermark = value),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: GallerySaveButton.minimumWidth,
                    minHeight: GallerySaveButton.height,
                    maxWidth: 180,
                  ),
                  child: GallerySaveButton(
                    enabled:
                        !_busy &&
                        _cards.isNotEmpty &&
                        _previewReady &&
                        (!_watermark || _icon != null),
                    foreground: Theme.of(context).colorScheme.surface,
                    background: Theme.of(context).colorScheme.onSurface,
                    onSave: (token) =>
                        _export(false, authorizationToken: token),
                    onError: (error) => setState(
                      () => _error = gallerySaveFailureMessage(error),
                    ),
                    builder: (onPressed) => GlassTextButton(
                      key: const ValueKey('quote-save-image'),
                      onPressed: onPressed,
                      child: AppText(
                        _busy
                            ? '正在生成…'
                            : _cards.length > 1
                            ? '保存此页图片'
                            : '保存图片',
                      ),
                    ),
                  ),
                ),
                GlassTextButton(
                  key: const ValueKey('quote-share-image'),
                  onPressed:
                      _busy ||
                          _cards.isEmpty ||
                          !_previewReady ||
                          (_watermark && _icon == null)
                      ? null
                      : () => _export(true),
                  child: AppText(_cards.length > 1 ? '分享此页' : '分享图片'),
                ),
              ],
            ),
            FeatureError(_artworkError ?? _error),
            if (_artworkError != null && _artwork != null)
              GlassTextButton(
                key: const ValueKey('quote-artwork-retry'),
                onPressed: _busy ? null : _loadArtwork,
                child: const AppText('重试主题图片'),
              ),
          ],
        ),
      ),
    ),
  );
}

class _QuotePainter extends CustomPainter {
  const _QuotePainter(
    this.card,
    this.icon,
    this.artwork,
    this.watermark,
    this.page,
    this.pages,
  );
  final QuoteCardLayout card;
  final ui.Image? icon, artwork;
  final bool watermark;
  final int page, pages;
  @override
  void paint(Canvas canvas, Size size) => card.paint(
    canvas,
    size,
    icon: icon,
    artwork: artwork,
    watermark: watermark,
    page: page,
    pages: pages,
  );
  @override
  bool shouldRepaint(_QuotePainter old) =>
      card != old.card ||
      icon != old.icon ||
      artwork != old.artwork ||
      watermark != old.watermark ||
      page != old.page;
}
