import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';
import 'reader_pagination.dart';
import 'reader_reflow.dart';
import 'reader_speech_highlight.dart';
import 'reader_underline.dart';
import 'reader_mark_style.dart';
import 'reader_landing_highlight.dart';
import 'reader_turn_motion.dart';
import 'reader_rich_content.dart';

/// Adjacent pages use the same glyphs. Share their shaped paragraphs instead of
/// paying for hundreds of native TextPainter layouts at every page boundary.
/// The LRU is bounded even when a chapter contains many distinct characters.
class ReaderGlyphCache {
  ReaderGlyphCache({this.capacity = 1024});
  final int capacity;
  final _painters = <(String, int, double, bool), TextPainter>{};
  TextStyle? _style;
  int debugShapeCount = 0;

  TextPainter painter(
    String text,
    TextStyle style, {
    int emphasis = 0,
    double opacity = 1,
  }) => _painter(text, style, emphasis, opacity, false);

  /// Ruby uses the same bounded LRU without changing the base text style.
  TextPainter rubyPainter(String text, TextStyle style, {double opacity = 1}) =>
      _painter(text, style, 0, opacity, true);

  TextPainter _painter(
    String text,
    TextStyle style,
    int emphasis,
    double opacity,
    bool ruby,
  ) {
    if (_style != style) {
      clear();
      _style = style;
    }
    final key = (text, emphasis, opacity, ruby);
    final cached = _painters.remove(key);
    if (cached != null) {
      _painters[key] = cached;
      return cached;
    }
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: ReaderRichParagraph.emphasized(
          style.copyWith(
            fontSize: ruby ? (style.fontSize ?? 19) * .48 : style.fontSize,
            height: 1,
            letterSpacing: 0,
            color: style.color?.withValues(alpha: style.color!.a * opacity),
          ),
          emphasis,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    assert(() {
      debugShapeCount++;
      return true;
    }());
    _painters[key] = painter;
    if (_painters.length > capacity) {
      _painters.remove(_painters.keys.first)!.dispose();
    }
    return painter;
  }

  void clear() {
    for (final painter in _painters.values) {
      painter.dispose();
    }
    _painters.clear();
    _style = null;
  }

  void dispose() => clear();
}

/// A whole page is one selectable in logical reading order, including when its
/// visual columns run right-to-left. Layout is already cached by pagination.
class ReaderVerticalText extends LeafRenderObjectWidget {
  const ReaderVerticalText({
    super.key,
    required this.page,
    required this.style,
    this.highlightParagraph,
    this.listeningParagraph,
    this.match,
    this.onDoubleTapParagraph,
    this.glyphCache,
    this.underlines = const [],
    this.annotations,
  });
  final ReaderLeaf page;
  final TextStyle style;
  final int? highlightParagraph;
  final int? listeningParagraph;
  final ({int paragraph, int start, int end})? match;
  final ValueChanged<int>? onDoubleTapParagraph;
  final ReaderGlyphCache? glyphCache;
  final List<ReaderUnderlineRange> underlines;
  final List<ReaderAnnotationRange>? annotations;
  @override
  RenderReaderVerticalText createRenderObject(BuildContext context) =>
      RenderReaderVerticalText(
        page,
        style,
        Theme.of(context).colorScheme.onSurface.withValues(alpha: .14),
        SelectionContainer.maybeOf(context),
        highlightParagraph,
        match,
        glyphCache,
        ReaderReflowScope.maybeOf(context),
        ReaderTurnScope.maybeOf(context),
        listeningParagraph,
        ReaderSpeechHighlightStyle.of(context),
        underlines,
        DefaultSelectionStyle.of(context).selectionColor,
        annotations,
        Theme.of(context).brightness == Brightness.dark,
      );
  @override
  void updateRenderObject(
    BuildContext context,
    RenderReaderVerticalText renderObject,
  ) => renderObject.update(
    page,
    style,
    Theme.of(context).colorScheme.onSurface.withValues(alpha: .14),
    SelectionContainer.maybeOf(context),
    highlightParagraph,
    match,
    glyphCache,
    ReaderReflowScope.maybeOf(context),
    ReaderTurnScope.maybeOf(context),
    listeningParagraph,
    ReaderSpeechHighlightStyle.of(context),
    underlines,
    DefaultSelectionStyle.of(context).selectionColor,
    annotations,
    Theme.of(context).brightness == Brightness.dark,
  );
}

class _ReaderReflowColumn {
  const _ReaderReflowColumn(
    this.bounds,
    this.previous,
    this.current,
    this.stable,
  );
  final Rect bounds;
  final List<ReaderVerticalGlyph> previous, current, stable;
}

class RenderReaderVerticalText extends RenderBox
    with Selectable, SelectionRegistrant {
  RenderReaderVerticalText(
    this._page,
    this._style,
    this._color,
    SelectionRegistrar? owner,
    this._highlight,
    this._match,
    ReaderGlyphCache? glyphCache,
    ReaderReflowScope? motion,
    ReaderTurnScope? turn,
    this._listening,
    this._speechStyle, [
    this._underlines = const [],
    this._selectionColor,
    this._annotations,
    this._annotationsDark = false,
  ]) {
    registrar = owner;
    _cache = glyphCache ?? ReaderGlyphCache();
    _ownsCache = glyphCache == null;
    _setMotion(motion);
    _setTurn(turn);
    if (turn != null) _warmGlyphs();
    _refreshSpeechBands();
  }
  ReaderLeaf _page;
  TextStyle _style;
  Color _color;
  Color? _selectionColor;
  int? _highlight;
  int? _listening;
  ReaderSpeechHighlightStyle _speechStyle;
  List<ReaderUnderlineRange> _underlines;
  List<ReaderAnnotationRange>? _annotations;
  bool _annotationsDark;
  Map<double, Rect> _speechBands = const {}, _previousSpeechBands = const {};

  Map<double, Rect> _bands(Iterable<ReaderVerticalGlyph> glyphs) {
    if (_listening == null) return const {};
    final bands = <double, Rect>{};
    var right = 0.0;
    for (final glyph in glyphs) {
      right = math.max(right, glyph.rect.right);
      if (glyph.paragraph != _listening) continue;
      final x = glyph.rect.center.dx;
      bands[x] = bands[x]?.expandToInclude(glyph.rect) ?? glyph.rect;
    }
    return bands.map(
      (x, rect) => MapEntry(
        x,
        Rect.fromLTRB(
          rect.left - 3,
          rect.top - 2,
          math.min(right, rect.right + 3),
          rect.bottom + 2,
        ),
      ),
    );
  }

  void _refreshSpeechBands() {
    _speechBands = _bands(_page.glyphs);
    _previousSpeechBands = _bands(_oldGlyphs.values);
  }

  @visibleForTesting
  List<Rect> get debugSpeechBands => _speechBands.values.toList();
  @visibleForTesting
  List<Rect> get debugUnderlineRects => [
    for (final glyph in _page.glyphs)
      if (_isUnderlined(glyph))
        Rect.fromLTWH(
          glyph.rect.left + 1,
          glyph.rect.top,
          1.3,
          glyph.rect.height,
        ),
  ];

  @visibleForTesting
  List<Rect> get debugOutlineRects =>
      _outlineBands(_page.glyphs).map((band) => band.rect).toList();

  List<({Rect rect, ReaderMarkColor color})> _outlineBands(
    Iterable<ReaderVerticalGlyph> glyphs,
  ) {
    final bands = <({Rect rect, ReaderMarkColor color})>[];
    for (final mark in _annotations ?? const <ReaderAnnotationRange>[]) {
      if (mark.style != ReaderMarkStyle.outline) continue;
      final columns = <double, Rect>{};
      for (final glyph in glyphs) {
        if (!_containsGlyph(mark.range, glyph)) continue;
        final x = glyph.rect.center.dx;
        columns[x] = columns[x]?.expandToInclude(glyph.rect) ?? glyph.rect;
      }
      for (final rect in columns.values) {
        bands.add((rect: readerRegistrationBounds(rect), color: mark.color));
      }
    }
    return bands;
  }

  void _paintOutlines(Canvas canvas, Iterable<ReaderVerticalGlyph> glyphs) {
    for (final band in _outlineBands(glyphs).reversed) {
      paintReaderRegistrationFrame(
        canvas,
        band.rect,
        ink: readerMarkInk(
          band.color,
          _style.color ?? Colors.grey,
          dark: _annotationsDark,
        ).withValues(alpha: _annotationsDark ? .65 : .42),
      );
    }
  }

  bool _containsGlyph(ReaderUnderlineRange range, ReaderVerticalGlyph glyph) {
    if (glyph.paragraph < range.startParagraph ||
        glyph.paragraph > range.endParagraph) {
      return false;
    }
    final start = glyph.paragraph == range.startParagraph
        ? range.startOffset
        : 0;
    final end = glyph.paragraph == range.endParagraph
        ? range.endOffset
        : glyph.sourceEnd;
    return glyph.sourceEnd > start && glyph.sourceStart < end;
  }

  ReaderAnnotationRange? _mark(
    ReaderVerticalGlyph glyph,
    ReaderMarkStyle style,
  ) => _annotations
      ?.where(
        (mark) => mark.style == style && _containsGlyph(mark.range, glyph),
      )
      .firstOrNull;

  bool _isUnderlined(ReaderVerticalGlyph glyph) => _annotations != null
      ? _mark(glyph, ReaderMarkStyle.underline) != null
      : _underlines.any((range) => _containsGlyph(range, glyph));
  ({int paragraph, int start, int end})? _match;
  late ReaderGlyphCache _cache;
  late bool _ownsCache;
  int _start = -1, _end = -1;
  LayerLink? _startLink, _endLink;
  SelectionGeometry _geometry = const SelectionGeometry(
    status: SelectionStatus.none,
    hasContent: true,
  );
  final _listeners = <VoidCallback>[];
  ReaderReflowScope? _motion;
  ReaderTurnScope? _turn;
  List<List<ReaderVerticalGlyph>> _turnColumns = const [];
  List<Rect> _turnBounds = const [];
  final _pictures = <(Object, int), ui.Picture>{};
  int debugGlyphPaintCalls = 0, debugPictureBuilds = 0;
  void _clearPictures() {
    for (final picture in _pictures.values) {
      picture.dispose();
    }
    _pictures.clear();
  }

  ui.Picture _picture(Object key, int part, void Function(Canvas) draw) =>
      _pictures.putIfAbsent((key, part), () {
        final recorder = ui.PictureRecorder();
        draw(Canvas(recorder));
        assert(() {
          debugPictureBuilds++;
          return true;
        }());
        return recorder.endRecording();
      });
  void _setTurn(ReaderTurnScope? value) {
    if (_turn == value) return;
    final availabilityChanged = (_turn == null) != (value == null);
    if (_turn?.animation != value?.animation) {
      _turn?.animation.removeListener(markNeedsPaint);
      value?.animation.addListener(markNeedsPaint);
    }
    _turn = value;
    if (availabilityChanged) {
      _clearPictures();
      _buildTurnColumns();
    }
  }

  void _buildTurnColumns() {
    if (_turn == null) {
      _turnColumns = const [];
      _turnBounds = const [];
      return;
    }
    final columns = <double, List<ReaderVerticalGlyph>>{};
    for (final glyph in _page.glyphs) {
      (columns[glyph.rect.center.dx] ??= []).add(glyph);
    }
    final centers = columns.keys.toList()..sort((a, b) => b.compareTo(a));
    _turnColumns = [for (final center in centers) columns[center]!];
    _turnBounds = [
      for (final column in _turnColumns)
        column
            .skip(1)
            .fold(
              _inkRect(column.first),
              (bounds, g) => bounds.expandToInclude(_inkRect(g)),
            ),
    ];
  }

  void _warmGlyphs() {
    final base = <(String, int, double)>{};
    final ruby = <(String, double)>{};
    for (final glyph in _page.glyphs) {
      if (base.add((glyph.text, glyph.emphasis, glyph.opacity))) {
        _cache.painter(
          glyph.text,
          _style,
          emphasis: glyph.emphasis,
          opacity: glyph.opacity,
        );
      }
      for (final letter in glyph.ruby.characters) {
        if (ruby.add((letter, glyph.opacity))) {
          _cache.rubyPainter(letter, _style, opacity: glyph.opacity);
        }
      }
    }
  }

  Rect _inkRect(ReaderVerticalGlyph glyph) => glyph.ruby.isEmpty
      ? glyph.rect
      : Rect.fromLTRB(
          glyph.rect.left,
          glyph.rect.top,
          glyph.rect.right + (_style.fontSize ?? 19) * .55,
          glyph.rect.bottom,
        );

  @visibleForTesting
  int get debugTurnColumnCount => _turnColumns.length;
  @visibleForTesting
  double debugTurnColumnProgress(int index) =>
      _turn?.progressFor(
        index,
        _turnColumns.length,
        bounds: _turnBounds[index],
      ) ??
      1;
  @visibleForTesting
  Offset debugTurnColumnDisplacement(int index) =>
      _turn?.displacementFor(
        index,
        _turnColumns.length,
        bounds: _turnBounds[index],
      ) ??
      Offset.zero;
  Map<(int, int, int), ReaderVerticalGlyph> _oldGlyphs = const {};
  List<_ReaderReflowColumn> _columns = const [];
  static (int, int, int) _identity(ReaderVerticalGlyph glyph) =>
      (glyph.paragraph, glyph.sourceStart, glyph.sourceEnd);
  void _setMotion(ReaderReflowScope? value) {
    if (_motion == value) return;
    _motion?.animation.removeListener(markNeedsPaint);
    _motion = value;
    _oldGlyphs = {
      for (final glyph in value?.previous.glyphs ?? <ReaderVerticalGlyph>[])
        _identity(glyph): glyph,
    };
    _motion?.animation.addListener(markNeedsPaint);
    _buildColumns();
  }

  @visibleForTesting
  int get debugColumnCount => _columns.length;
  @visibleForTesting
  double debugColumnProgress(int index) =>
      _motion?.progressFor(index, _columns.length) ?? 1;
  @visibleForTesting
  Offset debugColumnDisplacement(int index) =>
      _motion?.displacementFor(index, _columns.length) ?? Offset.zero;

  void _buildColumns() {
    final motion = _motion;
    if (motion == null || _page.glyphs.isEmpty) {
      _columns = const [];
      return;
    }
    final centers = _page.glyphs.map((g) => g.rect.center.dx).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    final stable = {
      for (final glyph in _page.glyphs)
        if (_oldGlyphs[_identity(glyph)]?.rect == glyph.rect) _identity(glyph),
    };
    _columns = [
      for (var i = 0; i < centers.length; i++)
        (() {
          final left = i == centers.length - 1
              ? 0.0
              : (centers[i] + centers[i + 1]) / 2;
          final right = i == 0
              ? motion.size.width
              : (centers[i - 1] + centers[i]) / 2;
          bool inside(ReaderVerticalGlyph g) =>
              g.rect.center.dx >= left && g.rect.center.dx < right;
          final after = _page.glyphs.where(inside).toList();
          return _ReaderReflowColumn(
            Rect.fromLTRB(
              left,
              0,
              right,
              math.max(motion.size.height, motion.previousSize.height),
            ),
            _oldGlyphs.values
                .where((g) => inside(g) && !stable.contains(_identity(g)))
                .toList(),
            after.where((g) => !stable.contains(_identity(g))).toList(),
            after.where((g) => stable.contains(_identity(g))).toList(),
          );
        })(),
    ];
  }

  double get _reflowProgress => _motion == null
      ? 1
      : Curves.easeOutCubic.transform(_motion!.animation.value);

  void update(
    ReaderLeaf page,
    TextStyle style,
    Color color,
    SelectionRegistrar? owner,
    int? highlight,
    ({int paragraph, int start, int end})? match,
    ReaderGlyphCache? glyphCache,
    ReaderReflowScope? motion,
    ReaderTurnScope? turn,
    int? listening,
    ReaderSpeechHighlightStyle speechStyle, [
    List<ReaderUnderlineRange> underlines = const [],
    Color? selectionColor,
    List<ReaderAnnotationRange>? annotations,
    bool annotationsDark = false,
  ]) {
    final motionChanged = motion != _motion;
    final turnChanged = turn != _turn;
    final speechChanged =
        listening != _listening || !identical(page, _page) || motionChanged;
    _setMotion(motion);
    _setTurn(turn);
    registrar = owner;
    final cacheChanged =
        glyphCache != null && !identical(_cache, glyphCache) ||
        glyphCache == null && !_ownsCache;
    if (cacheChanged) {
      if (_ownsCache) _cache.dispose();
      _cache = glyphCache ?? ReaderGlyphCache();
      _ownsCache = glyphCache == null;
    }
    final pixelsChanged =
        !identical(page, _page) ||
        style != _style ||
        color != _color ||
        selectionColor != _selectionColor ||
        highlight != _highlight ||
        listening != _listening ||
        speechStyle != _speechStyle ||
        match != _match ||
        !listEquals(underlines, _underlines) ||
        !listEquals(annotations, _annotations) ||
        annotationsDark != _annotationsDark ||
        cacheChanged ||
        motionChanged;
    final changed = pixelsChanged || turnChanged;
    if (!identical(page, _page) || style != _style) {
      _page = page;
      _style = style;
      _buildColumns();
      _buildTurnColumns();
      _start = _end = -1;
      _updateGeometry();
      markNeedsSemanticsUpdate();
    }
    _color = color;
    _selectionColor = selectionColor;
    _highlight = highlight;
    _listening = listening;
    _speechStyle = speechStyle;
    if (speechChanged) _refreshSpeechBands();
    _match = match;
    _underlines = underlines;
    _annotations = annotations;
    _annotationsDark = annotationsDark;
    if (pixelsChanged) _clearPictures();
    if (_turn != null && changed) _warmGlyphs();
    if (changed) markNeedsPaint();
  }

  @override
  SelectionGeometry get value => _geometry;
  @override
  int get contentLength => _page.text.length;
  @override
  List<Rect> get boundingBoxes => [paintBounds];
  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;
  @override
  void performLayout() {
    size = constraints.biggest;
    _updateGeometry();
  }

  @override
  bool hitTestSelf(Offset position) => true;
  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.isSemanticBoundary = true;
    config.label = _page.text;
    config.textDirection = TextDirection.ltr;
  }

  ReaderVerticalGlyph? glyphAt(Offset point) {
    ReaderVerticalGlyph? nearest;
    var distance = double.infinity;
    for (final glyph in _page.glyphs) {
      if (glyph.rect.contains(point)) return glyph;
      final d = (glyph.rect.center - point).distanceSquared;
      if (d < distance) {
        distance = d;
        nearest = glyph;
      }
    }
    return nearest;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    final selected = _start >= 0 && _end >= 0 && _start != _end;
    final first = math.min(_start, _end), last = math.max(_start, _end);
    final tint = Paint()..color = _color;
    final selectionTint = Paint()..color = _selectionColor ?? _color;
    final t = _reflowProgress;
    void paintCurrent(Canvas target, ReaderVerticalGlyph glyph) {
      final rect = glyph.rect;
      final match = _match;
      final inSelection = selected && glyph.end > first && glyph.start < last;
      if (inSelection ||
          _highlight == glyph.paragraph ||
          match != null &&
              match.paragraph == glyph.paragraph &&
              match.end > glyph.sourceStart &&
              match.start < glyph.sourceEnd) {
        target.drawRRect(
          RRect.fromRectAndRadius(rect.inflate(1), const Radius.circular(3)),
          inSelection ? selectionTint : tint,
        );
      }
      _paintGlyph(target, glyph, rect);
    }

    if (_turn != null && (_turn!.outgoing || _turn!.animation.value < 1)) {
      // A column is one small paint layer, not a widget per glyph or a
      // page-wide edge mask. All columns reuse the existing glyph cache.
      for (var index = 0; index < _turnColumns.length; index++) {
        final column = _turnColumns[index];
        final opacity = _turn!.opacityFor(index, _turnColumns.length);
        if (opacity == 0) continue;
        final bounds = _turnBounds[index];
        final displacement = _turn!.displacementFor(
          index,
          _turnColumns.length,
          bounds: bounds,
        );
        if (opacity < 1) {
          canvas.saveLayer(
            bounds.shift(displacement).inflate(3),
            Paint()..color = Colors.white.withValues(alpha: opacity),
          );
        }
        canvas.save();
        canvas.translate(displacement.dx, displacement.dy);
        canvas.drawPicture(
          _picture(column, 0, (target) {
            final band = _speechBands[column.first.rect.center.dx];
            if (band != null) _speechStyle.paint(target, band, vertical: true);
            for (final glyph in column) {
              paintCurrent(target, glyph);
            }
            _paintOutlines(target, column);
          }),
        );
        canvas.restore();
        if (opacity < 1) canvas.restore();
      }
    } else if (_motion != null && t < 1) {
      // Each column has one delayed translation. Its old/new portions have
      // complementary clips, so columns move without crossing glyph paths.
      for (var index = 0; index < _columns.length; index++) {
        final column = _columns[index];
        final progress = _motion!.progressFor(index, _columns.length);
        final displacement = _motion!.displacementFor(index, _columns.length);
        final seam = column.bounds.height * progress;
        canvas.save();
        canvas.translate(displacement.dx, displacement.dy);
        // Paragraph gaps can shift the old column across a new column's
        // midpoint. Pictures already contain only their owned glyphs; clipping
        // them horizontally would slice the retained ink at publication.
        canvas.clipRect(Rect.fromLTRB(0, 0, size.width, column.bounds.bottom));
        canvas.drawPicture(
          _picture(column, 0, (target) {
            for (final band in _speechBands.entries) {
              if (band.key >= column.bounds.left &&
                  band.key < column.bounds.right) {
                _speechStyle.paint(target, band.value, vertical: true);
              }
            }
            for (final glyph in column.stable) {
              paintCurrent(target, glyph);
            }
            _paintOutlines(target, column.stable);
          }),
        );
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(0, 0, size.width, seam));
        canvas.translate(0, 10 * (1 - progress));
        canvas.drawPicture(
          _picture(column, 1, (target) {
            for (final glyph in column.current) {
              paintCurrent(target, glyph);
            }
            _paintOutlines(target, column.current);
          }),
        );
        canvas.restore();
        canvas.save();
        canvas.clipRect(
          Rect.fromLTRB(0, seam, size.width, column.bounds.bottom),
        );
        canvas.translate(0, -4 * progress);
        canvas.drawPicture(
          _picture(column, 2, (target) {
            for (final band in _previousSpeechBands.entries) {
              if (band.key >= column.bounds.left &&
                  band.key < column.bounds.right) {
                _speechStyle.paint(target, band.value, vertical: true);
              }
            }
            for (final glyph in column.previous) {
              _paintGlyph(target, glyph, glyph.rect);
            }
            _paintOutlines(target, column.previous);
          }),
        );
        canvas.restore();
        canvas.restore();
      }
    } else {
      canvas.drawPicture(
        _picture(_page, 0, (target) {
          for (final band in _speechBands.values) {
            _speechStyle.paint(target, band, vertical: true);
          }
          for (final glyph in _page.glyphs) {
            paintCurrent(target, glyph);
          }
          _paintOutlines(target, _page.glyphs);
        }),
      );
    }
    canvas.restore();
    if (selected) {
      final start = _glyphFor(first), end = _glyphFor(last, end: true);
      if (_startLink != null && start != null) {
        context.pushLayer(
          LeaderLayer(link: _startLink!, offset: offset + start.rect.topCenter),
          (c, o) {},
          Offset.zero,
        );
      }
      if (_endLink != null && end != null) {
        context.pushLayer(
          LeaderLayer(link: _endLink!, offset: offset + end.rect.bottomCenter),
          (c, o) {},
          Offset.zero,
        );
      }
    }
  }

  void _paintGlyph(Canvas canvas, ReaderVerticalGlyph glyph, Rect rect) {
    assert(() {
      debugGlyphPaintCalls++;
      return true;
    }());
    final mark = _mark(glyph, ReaderMarkStyle.highlight);
    if (mark != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.inflate(.5), const Radius.circular(2)),
        Paint()
          ..color = readerMarkTint(
            mark.color,
            _style.color ?? Colors.grey,
            dark: _annotationsDark,
          ),
      );
    }
    final painter = _cache.painter(
      glyph.text,
      _style,
      emphasis: glyph.emphasis,
      opacity: glyph.opacity,
    );
    var centre = rect.center;
    if ('，。、'.contains(glyph.text)) {
      centre += Offset(rect.width * .22, -rect.width * .22);
    }
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    if (glyph.rotation != 0) canvas.rotate(glyph.rotation);
    final available = glyph.rotation == 0 ? rect.width : rect.height;
    final scale = math.min(
      1.0,
      available / painter.width.clamp(1, double.infinity),
    );
    if (scale != 1) canvas.scale(scale);
    painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
    canvas.restore();
    final underline = _mark(glyph, ReaderMarkStyle.underline);
    if (underline != null || _annotations == null && _isUnderlined(glyph)) {
      final color = underline?.color ?? ReaderMarkColor.ink;
      canvas.drawLine(
        Offset(rect.left + 1, rect.top),
        Offset(rect.left + 1, rect.bottom),
        Paint()
          ..color = readerMarkInk(
            color,
            _style.color ?? Colors.grey,
            dark: _annotationsDark,
          ).withValues(alpha: color == ReaderMarkColor.ink ? .8 : .9)
          ..strokeWidth = 1.3,
      );
    }
    if (glyph.ruby.isNotEmpty) {
      final letters = glyph.ruby.characters.toList();
      final step = rect.height / letters.length;
      for (var i = 0; i < letters.length; i++) {
        final label = _cache.rubyPainter(
          letters[i],
          _style,
          opacity: glyph.opacity,
        );
        label.paint(
          canvas,
          Offset(
            rect.right + 1,
            rect.top + step * i + (step - label.height) / 2,
          ),
        );
      }
    }
  }

  ReaderVerticalGlyph? _glyphFor(int position, {bool end = false}) {
    for (final g in _page.glyphs) {
      if (end
          ? g.start < position && position <= g.end
          : g.start <= position && position < g.end) {
        return g;
      }
    }
    return _page.glyphs.isEmpty
        ? null
        : (end ? _page.glyphs.last : _page.glyphs.first);
  }

  void _updateGeometry() {
    final old = _geometry;
    final start = _glyphFor(math.min(_start, _end));
    final end = _glyphFor(math.max(_start, _end), end: true);
    _geometry = _start < 0 || _end < 0 || start == null || end == null
        ? SelectionGeometry(
            status: SelectionStatus.none,
            hasContent: _page.text.isNotEmpty,
          )
        : _start == _end
        ? const SelectionGeometry(
            status: SelectionStatus.collapsed,
            hasContent: true,
          )
        : SelectionGeometry(
            status: SelectionStatus.uncollapsed,
            hasContent: true,
            startSelectionPoint: SelectionPoint(
              localPosition: start.rect.topCenter,
              lineHeight: start.rect.width,
              handleType: TextSelectionHandleType.left,
            ),
            endSelectionPoint: SelectionPoint(
              localPosition: end.rect.bottomCenter,
              lineHeight: end.rect.width,
              handleType: TextSelectionHandleType.right,
            ),
          );
    if (old != _geometry) {
      for (final listener in List<VoidCallback>.of(_listeners)) {
        listener();
      }
    }
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    switch (event) {
      case ClearSelectionEvent():
        _start = _end = -1;
      case SelectAllSelectionEvent():
        _start = 0;
        _end = _page.text.length;
      case SelectWordSelectionEvent():
        final glyph = glyphAt(globalToLocal(event.globalPosition));
        if (glyph == null) return SelectionResult.none;
        _start = glyph.start;
        _end = glyph.end;
        for (final word in RegExp(r'[A-Za-z0-9]+').allMatches(_page.text)) {
          if (word.start <= glyph.start && glyph.start < word.end) {
            _start = word.start;
            _end = word.end;
            break;
          }
        }
      case SelectionEdgeUpdateEvent():
        final glyph = glyphAt(globalToLocal(event.globalPosition));
        if (glyph == null) return SelectionResult.none;
        if (event.type == SelectionEventType.startEdgeUpdate) {
          _start = glyph.start;
          if (_end < 0) _end = glyph.end;
        } else {
          _end = glyph.end;
          if (_start < 0) _start = glyph.start;
        }
      case GranularlyExtendSelectionEvent():
        final position = event.isEnd ? _end : _start;
        if (position >= 0) {
          final next = _selectionStep(position, event.forward);
          if (event.isEnd) {
            _end = next;
          } else {
            _start = next;
          }
        }
      case DirectionallyExtendSelectionEvent():
        final forward =
            event.direction == SelectionExtendDirection.forward ||
            event.direction == SelectionExtendDirection.nextLine;
        final position = event.isEnd ? _end : _start;
        if (position >= 0) {
          final next = _selectionStep(position, forward);
          if (event.isEnd) {
            _end = next;
          } else {
            _start = next;
          }
        }
      default:
        return SelectionResult.none;
    }
    _updateGeometry();
    _clearPictures();
    markNeedsPaint();
    return SelectionResult.end;
  }

  int _selectionStep(int position, bool forward) {
    // Selection edges are UTF-16 boundaries, not character indices. In
    // particular, stepping backward from 1 must reach 0, never the last glyph.
    // Reading-order glyphs also bridge unpainted paragraph separators and keep
    // multi-code-unit graphemes intact.
    if (forward) {
      for (final glyph in _page.glyphs) {
        if (glyph.end > position) return glyph.end;
      }
      return _page.text.length;
    }
    for (final glyph in _page.glyphs.reversed) {
      if (glyph.start < position) return glyph.start;
    }
    return 0;
  }

  @override
  SelectedContentRange? getSelection() =>
      _start < 0 || _end < 0 || _start == _end
      ? null
      : SelectedContentRange(
          startOffset: math.min(_start, _end),
          endOffset: math.max(_start, _end),
        );
  @override
  SelectedContent? getSelectedContent() => getSelection() == null
      ? null
      : SelectedContent(
          plainText: _page.text.substring(
            math.min(_start, _end),
            math.max(_start, _end),
          ),
        );
  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    _startLink = startHandle;
    _endLink = endHandle;
    if (attached) markNeedsPaint();
  }

  @override
  void dispose() {
    registrar = null;
    _clearPictures();
    _turn?.animation.removeListener(markNeedsPaint);
    _motion?.animation.removeListener(markNeedsPaint);
    if (_ownsCache) _cache.dispose();
    _listeners.clear();
    super.dispose();
  }
}
