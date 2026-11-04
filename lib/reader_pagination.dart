import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:tategaki/tategaki.dart'
    show CharacterClassifier, RotationRules, KinsokuProcessor;
import 'reader_content.dart';
import 'reader_text.dart';
import 'reader_preferences.dart';
import 'local_image_layout.dart';
import 'reader_rich_content.dart';

// A vertical typographic substitution only. Source text, selection offsets,
// copied quotations and bookmarks retain the original characters.
String _verticalCluster(String source) => switch (source) {
  '“' => '「',
  '”' => '」',
  '‘' => '『',
  '’' => '』',
  _ => source,
};

class ReaderTextAnchor {
  const ReaderTextAnchor(this.paragraph, this.offset);
  final int paragraph, offset;
}

class ReaderPageFragment {
  const ReaderPageFragment({
    required this.paragraph,
    required this.start,
    required this.end,
    required this.text,
    required this.rect,
    this.indent = false,
    this.image = false,
    this.rule = false,
    this.lineMetrics,
  });
  final int paragraph, start, end;
  final String text;
  final Rect rect;
  final bool indent, image;
  final bool rule;
  final ReaderFragmentLines? lineMetrics;
  int get lineCount => lineMetrics?.count ?? 1;
  Iterable<ReaderPageLine> get lines =>
      lineMetrics?.values ?? [ReaderPageLine(start, end, 0, rect.height)];
}

/// Source boundaries and local line boxes reuse the compact shaping metrics.
/// Only visible reflow builds line objects; pagination does not retain a widget
/// or a native LineMetrics object for every line in a chapter.
class ReaderPageLine {
  const ReaderPageLine(this.start, this.end, this.top, this.height);
  final int start, end;
  final double top, height;
}

class ReaderFragmentLines {
  const ReaderFragmentLines._(
    this._metrics,
    this._first,
    this._end,
    this._prefix,
    this._sourceLength,
  );
  final _HorizontalMetrics _metrics;
  final int _first, _end, _prefix, _sourceLength;
  int get count => _end - _first;
  Iterable<ReaderPageLine> get values sync* {
    var top = 0.0;
    for (var i = _first; i < _end; i++) {
      final start = (_metrics.starts[i] - _prefix).clamp(0, _sourceLength);
      final end = (_metrics.starts[i + 1] - _prefix).clamp(
        start,
        _sourceLength,
      );
      final height = _metrics.heights[i];
      yield ReaderPageLine(start, end, top, height);
      top += height;
    }
  }
}

class ReaderVerticalGlyph {
  const ReaderVerticalGlyph({
    required this.text,
    required this.start,
    required this.end,
    required this.paragraph,
    required this.sourceStart,
    required this.sourceEnd,
    required this.rect,
    required this.rotation,
    this.ruby = '',
    this.note,
    this.emphasis = 0,
    this.opacity = 1,
  });
  final String text;
  final int start, end, paragraph, sourceStart, sourceEnd;
  final Rect rect;
  final double rotation;
  final String ruby;
  final String? note;
  final int emphasis;
  final double opacity;
}

class ReaderLeaf {
  ReaderLeaf(
    List<ReaderPageFragment> fragments, {
    this.text = '',
    List<ReaderVerticalGlyph> glyphs = const [],
    this.vertical = false,
  }) : fragments = List.unmodifiable(fragments),
       _glyphs = List.unmodifiable(glyphs),
       _columns = const [],
       _glyphCache = null;
  ReaderLeaf._vertical(
    List<ReaderPageFragment> fragments,
    this.text,
    List<_VerticalColumn> columns,
    this._glyphCache,
  ) : vertical = true,
      fragments = List.unmodifiable(fragments),
      _columns = List.unmodifiable(columns),
      _glyphs = const [];
  final List<ReaderPageFragment> fragments;
  final bool vertical;
  final String text;
  final List<ReaderVerticalGlyph> _glyphs;
  final List<_VerticalColumn> _columns;
  final _ReaderVerticalPageCache? _glyphCache;
  List<ReaderVerticalGlyph> get glyphs => _glyphCache?.forPage(this) ?? _glyphs;
  ReaderTextAnchor get anchor => fragments.isEmpty
      ? const ReaderTextAnchor(0, 0)
      : ReaderTextAnchor(fragments.first.paragraph, fragments.first.start);
}

class ReaderPagination {
  ReaderPagination(this.pages, this.size) : _glyphCache = null;
  ReaderPagination._measured(this.pages, this.size, this._glyphCache);
  final List<ReaderLeaf> pages;
  final Size size;
  final _ReaderVerticalPageCache? _glyphCache;
  @visibleForTesting
  int get debugGlyphPageBuilds => _glyphCache?.pageBuilds ?? 0;
  @visibleForTesting
  int get debugResidentGlyphPages => _glyphCache?._pages.length ?? 0;
  @visibleForTesting
  int get debugResidentGlyphCount =>
      _glyphCache?._pages.values.fold<int>(
        0,
        (count, glyphs) => count + glyphs.length,
      ) ??
      0;
  int pageFor(ReaderTextAnchor anchor) {
    var nearest = 0;
    for (var p = 0; p < pages.length; p++) {
      for (final f in pages[p].fragments) {
        if (f.paragraph == anchor.paragraph &&
            (f.image || anchor.offset >= f.start && anchor.offset < f.end)) {
          return p;
        }
        if (f.paragraph < anchor.paragraph ||
            f.paragraph == anchor.paragraph && f.start <= anchor.offset) {
          nearest = p;
        }
      }
    }
    return nearest;
  }
}

class _HorizontalMetrics {
  _HorizontalMetrics(List<ui.LineMetrics> lines, List<int> starts)
    : heights = Float64List(lines.length),
      starts = Uint32List.fromList(starts) {
    for (var i = 0; i < lines.length; i++) {
      heights[i] = lines[i].height;
    }
  }
  // Repacking only needs exact line heights and source boundaries. Do not keep
  // every native line descriptor's baseline, width, ascent and other fields.
  final Float64List heights;
  final Uint32List starts;
}

class _VerticalMetrics {
  _VerticalMetrics(
    this.clusters,
    this.offsets,
    this.advances,
    this.rotations,
    this.annotations,
  );
  final List<String> clusters;
  final Uint32List offsets;
  // Repeated glyphs share their boxed advances/rotations from the metric map.
  // Tight reference lists are smaller than duplicating a double per position
  // on pointer-compressed Android runtimes, and retain the same exact values.
  final List<double> advances, rotations;
  final ReaderRichParagraphIndex? annotations;
}

class _VerticalColumn {
  const _VerticalColumn({
    required this.metrics,
    required this.paragraph,
    required this.first,
    required this.end,
    required this.pageStart,
    required this.left,
    required this.indent,
    required this.font,
    required this.extra,
    required this.format,
  });
  final _VerticalMetrics metrics;
  final int paragraph, first, end, pageStart;
  final double left, indent, font, extra;
  final ReaderRichParagraph format;
}

/// Keep complete page boundaries for progress, seeking and bookmarks, but build
/// per-character drawing objects only when a leaf is used. Six leaves cover the
/// current and neighbouring two-page spreads; reading a long chapter does not
/// accumulate every visited page's glyph rectangles.
class _ReaderVerticalPageCache {
  final _pages = <ReaderLeaf, List<ReaderVerticalGlyph>>{};
  int pageBuilds = 0;

  List<ReaderVerticalGlyph> forPage(ReaderLeaf page) {
    final cached = _pages.remove(page);
    if (cached != null) {
      _pages[page] = cached;
      return cached;
    }
    final glyphs = <ReaderVerticalGlyph>[];
    for (final column in page._columns) {
      final metrics = column.metrics;
      final annotations = metrics.annotations;
      final sourceStart = metrics.offsets[column.first];
      var y = column.indent;
      for (var c = column.first; c < column.end; c++) {
        if (metrics.clusters[c] == '\n') continue;
        glyphs.add(
          ReaderVerticalGlyph(
            text: _verticalCluster(metrics.clusters[c]),
            start: column.pageStart + metrics.offsets[c] - sourceStart,
            end: column.pageStart + metrics.offsets[c + 1] - sourceStart,
            paragraph: column.paragraph,
            sourceStart: metrics.offsets[c],
            sourceEnd: metrics.offsets[c + 1],
            rect: Rect.fromLTWH(
              column.left,
              y,
              column.font,
              metrics.advances[c],
            ),
            rotation: metrics.rotations[c],
            emphasis: annotations?.emphasisAt(metrics.offsets[c]) ?? 0,
            opacity: column.format.opacity,
            ruby:
                annotations?.rubyAt(
                  metrics.offsets[c],
                  metrics.offsets[c + 1],
                ) ??
                '',
            note: annotations?.noteAt(
              metrics.offsets[c],
              metrics.offsets[c + 1],
            ),
          ),
        );
        y += metrics.advances[c] + column.extra;
      }
    }
    final result = List<ReaderVerticalGlyph>.unmodifiable(glyphs);
    _pages[page] = result;
    if (_pages.length > 6) _pages.remove(_pages.keys.first);
    pageBuilds++;
    return result;
  }
}

class _ReaderMeasurements {
  final horizontal = <int, _HorizontalMetrics>{};
  final vertical = <int, _VerticalMetrics>{};
  final glyphs = <(String, int), ({double advance, double rotation})>{};
  final complexGraphemes = <String, String>{};
}

/// A height change re-packs measured lines/columns; it must not shape an entire
/// chapter again. Two typography/width configurations are retained per reader.
class ReaderTextLayoutCache {
  final _layouts = <Object, _ReaderMeasurements>{};
  int paragraphMeasurements = 0;
  _ReaderMeasurements _for(Object key) {
    final cached = _layouts.remove(key);
    if (cached != null) {
      _layouts[key] = cached;
      return cached;
    }
    if (_layouts.length == 2) _layouts.remove(_layouts.keys.first);
    return _layouts[key] = _ReaderMeasurements();
  }
}

/// Actual line/glyph boundaries, not viewport-sized scroll jumps. Only the
/// current chapter is measured, yielding between bounded chunks of work.
Future<ReaderPagination?> paginateReader({
  required ReaderContent content,
  required Size size,
  required TextStyle style,
  required ReaderPreferences preferences,
  required TextScaler scaler,
  required bool Function() current,
  ReaderTextAnchor? pageBreak,
  ReaderTextLayoutCache? cache,
  Map<String, Size> localImageSizes = const {},
}) async {
  final pages = <ReaderLeaf>[];
  var fragments = <ReaderPageFragment>[];
  var columns = <_VerticalColumn>[];
  var pageText = StringBuffer();
  var previousParagraph = -1;
  var y = 0.0;
  var right = size.width;
  final clock = Stopwatch()..start();
  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    textAlign: preferences.justify ? TextAlign.justify : TextAlign.start,
  );
  final baseVertical = preferences.mode == ReaderMode.vertical;
  final latinOrientation = baseVertical
      ? preferences.verticalLatinOrientation
      : ReaderVerticalLatinOrientation.rotated;
  var vertical = baseVertical;
  var forcePageBreak = false;
  ReaderRichParagraph? previousFormat;
  final glyphCache =
      baseVertical || content.formats.values.any((f) => f.writing == 'vertical')
      ? _ReaderVerticalPageCache()
      : null;
  final font = scaler.scale(style.fontSize ?? 19);
  final columnWidth = font * (style.height ?? 1.72);
  final verticalStyle = style.copyWith(
    fontSize: font,
    height: 1,
    letterSpacing: 0,
  );
  final measured =
      cache?._for((
        content,
        !baseVertical ||
                content.formats.values.any((f) => f.writing == 'horizontal')
            ? size.width
            : null,
        vertical ? verticalStyle : style,
        preferences.mode,
        baseVertical ? latinOrientation : null,
        vertical ? null : preferences.indent,
        vertical ? null : preferences.justify,
        vertical ? preferences.letterSpacing : null,
        scaler.scale(style.fontSize ?? 19),
      )) ??
      _ReaderMeasurements();
  final glyphMetrics = measured.glyphs;
  void flush() {
    if (fragments.isEmpty) return;
    final text = pageText.toString();
    pages.add(
      columns.isEmpty
          ? ReaderLeaf(fragments, text: text, vertical: vertical)
          : ReaderLeaf._vertical(fragments, text, columns, glyphCache),
    );
    fragments = [];
    columns = [];
    pageText = StringBuffer();
    previousParagraph = -1;
    y = 0;
    right = size.width;
  }

  try {
    for (final index in content.order) {
      if (!current()) return null;
      final text = content.paragraphs[index];
      final format = content.formats[index] ?? const ReaderRichParagraph();
      if (forcePageBreak || format.breakBefore) {
        flush();
        previousFormat = null;
      }
      forcePageBreak = format.breakAfter;
      final nextVertical = switch (format.writing) {
        'vertical' => true,
        'horizontal' => false,
        _ => baseVertical,
      };
      if (nextVertical != vertical) {
        flush();
        vertical = nextVertical;
        previousFormat = null;
      }
      final gap = format.gapBefore(
        previousFormat,
        font: font,
        lineHeight: style.height ?? 1.72,
        width: vertical ? size.height : size.width,
        defaultGap: preferences.paragraphGap,
        overrideGap: preferences.paragraphGapOverride,
      );
      previousFormat = format;
      if (vertical) {
        right -= math.min(gap, math.max(0.0, size.width - columnWidth));
      } else {
        y += math.min(
          gap,
          math.max(
            0.0,
            size.height - font * math.max(style.height ?? 1.72, 2.15),
          ),
        );
      }
      if (format.rule) {
        final extent = font * 1.25;
        if ((!vertical && y + extent > size.height ||
                vertical && right < extent) &&
            fragments.isNotEmpty) {
          flush();
        }
        fragments.add(
          ReaderPageFragment(
            paragraph: index,
            start: 0,
            end: text.length,
            text: text,
            rect: vertical
                ? Rect.fromLTWH(right - extent, 0, extent, size.height)
                : Rect.fromLTWH(0, y, size.width, extent),
            rule: true,
          ),
        );
        if (vertical) {
          right -= extent;
        } else {
          y += extent;
        }
        continue;
      }
      final imageUrl = readerIllustrationUrl(text);
      if (imageUrl?.startsWith('wenku-local:') == true &&
          localImageSizes.containsKey(imageUrl)) {
        final natural = localImageSizes[imageUrl]!;
        final imageSize = LocalImageLayout.fromParagraph(
          text,
        ).resolve(natural: natural, available: size, fontSize: font);
        if (!vertical) {
          if (y + imageSize.height > size.height + .1 && fragments.isNotEmpty) {
            flush();
          }
          fragments.add(
            ReaderPageFragment(
              paragraph: index,
              start: 0,
              end: text.length,
              text: text,
              rect: Rect.fromLTWH(
                switch (format.alignment) {
                  'left' || 'start' => 0,
                  'right' || 'end' => size.width - imageSize.width,
                  _ => (size.width - imageSize.width) / 2,
                },
                y,
                imageSize.width,
                imageSize.height,
              ),
              image: true,
            ),
          );
          y += imageSize.height;
        } else {
          final width = math.max(
            math.min(columnWidth, size.width),
            imageSize.width,
          );
          if (right < width - .1 && fragments.isNotEmpty) flush();
          fragments.add(
            ReaderPageFragment(
              paragraph: index,
              start: 0,
              end: text.length,
              text: text,
              rect: Rect.fromLTWH(
                right - width + (width - imageSize.width) / 2,
                0,
                imageSize.width,
                imageSize.height,
              ),
              image: true,
            ),
          );
          right -= width;
        }
        continue;
      }
      if (imageUrl != null || text.trim() == '[插图]') {
        flush();
        fragments.add(
          ReaderPageFragment(
            paragraph: index,
            start: 0,
            end: text.length,
            text: text,
            rect: Offset.zero & size,
            image: true,
          ),
        );
        flush();
        continue;
      }
      if (text.isEmpty) continue;
      if (!vertical) {
        final indent = preferences.indent && format.allowsIndent;
        final prefix = indent ? readerIndentPlaceholder : '';
        final display = '$prefix$text';
        var metrics = measured.horizontal[index];
        if (metrics == null) {
          if (cache != null) cache.paragraphMeasurements++;
          final paragraphStyle = format.textStyle(style);
          final span = readerParagraphSpan(
            children: format.spans(text),
            style: paragraphStyle,
            indent: indent,
          );
          final builder = ui.ParagraphBuilder(
            paragraphStyle.getParagraphStyle(
              textDirection: TextDirection.ltr,
              textAlign: format.textAlign(
                preferences.justify ? TextAlign.justify : TextAlign.start,
              ),
              textScaler: scaler,
            ),
          );
          span.build(
            builder,
            textScaler: scaler,
            dimensions: readerIndentDimensions(indent, font),
          );
          final paragraph = builder.build();
          try {
            paragraph.layout(ui.ParagraphConstraints(width: size.width));
            final lines = paragraph.computeLineMetrics();
            final starts = <int>[0];
            // getLineBoundary copies the whole native line-metrics vector on
            // every query. Search the native logical line index instead: this
            // also handles bidi text and oversized graphemes without a visual
            // left-edge hit being mistaken for a source-text boundary.
            for (var line = 1; line < lines.length; line++) {
              var low = starts.last, high = display.length;
              while (low < high) {
                final middle = (low + high) ~/ 2;
                final at = paragraph.getLineNumberAt(middle);
                if (at != null && at < line) {
                  low = middle + 1;
                } else {
                  high = middle;
                }
              }
              starts.add(low);
              if (clock.elapsedMilliseconds >= 4) {
                await Future<void>.delayed(Duration.zero);
                if (!current()) return null;
                clock.reset();
              }
            }
            starts.add(display.length);
            metrics = measured.horizontal[index] = _HorizontalMetrics(
              lines,
              starts,
            );
          } finally {
            paragraph.dispose();
          }
        }
        final heights = metrics.heights, starts = metrics.starts;
        // A typography change can move the source anchor into the middle of
        // a newly shaped line. Keep that line at top, rather than silently
        // ignoring the break and jumping back an entire page.
        var breakLine = -1;
        if (pageBreak?.paragraph == index) {
          final target = pageBreak!.offset + prefix.length;
          var low = 0, high = heights.length;
          while (low < high) {
            final middle = (low + high) ~/ 2;
            if (starts[middle] <= target) {
              low = middle + 1;
            } else {
              high = middle;
            }
          }
          breakLine = (low - 1).clamp(0, heights.length - 1);
        }
        var line = 0;
        while (line < heights.length) {
          if (line == breakLine) flush();
          if (y + heights[line] > size.height + .1 && fragments.isNotEmpty) {
            flush();
          }
          final first = line;
          var height = 0.0;
          while (line < heights.length &&
              (line == first || line != breakLine) &&
              (height == 0 || y + height + heights[line] <= size.height + .1)) {
            height += heights[line++];
          }
          final start = (starts[first] - prefix.length).clamp(0, text.length);
          final end = (starts[line] - prefix.length).clamp(start, text.length);
          if (end > start) {
            fragments.add(
              ReaderPageFragment(
                paragraph: index,
                start: start,
                end: end,
                text: text.substring(start, end),
                rect: Rect.fromLTWH(0, y, size.width, height),
                indent: start == 0 && indent,
                lineMetrics: ReaderFragmentLines._(
                  metrics,
                  first,
                  line,
                  prefix.length,
                  text.length,
                ),
              ),
            );
            y += height;
          }
          if (line < heights.length) flush();
        }
      } else {
        var metrics = measured.vertical[index];
        final paragraphColumnWidth = format.ruby.isEmpty
            ? columnWidth
            : math.max(columnWidth, font * 1.6);
        if (metrics == null) {
          if (cache != null) cache.paragraphMeasurements++;
          // Simple characters already use the runtime's single-character
          // strings. Share only complex graphemes, within this layout cache.
          final clusters = text.characters
              .map(
                (cluster) => cluster.length == 1
                    ? cluster
                    : measured.complexGraphemes.putIfAbsent(
                        cluster,
                        () => cluster,
                      ),
              )
              .toList(growable: false);
          final offsets = Uint32List(clusters.length + 1);
          final advances = List<double>.filled(clusters.length, 0);
          final rotations = List<double>.filled(clusters.length, 0);
          final annotations =
              format.emphasis.isEmpty &&
                  format.ruby.isEmpty &&
                  format.references.isEmpty
              ? null
              : ReaderRichParagraphIndex(format);
          painter.textScaler = TextScaler.noScaling;
          var c = 0;
          for (final cluster in clusters) {
            offsets[c + 1] = offsets[c] + cluster.length;
            final emphasis = annotations?.emphasisAt(offsets[c]) ?? 0;
            final metric = glyphMetrics.putIfAbsent((cluster, emphasis), () {
              final display = _verticalCluster(cluster);
              final rotation = RotationRules.getRotationAngle(
                display,
                CharacterClassifier.classify(display),
                latinOrientation == ReaderVerticalLatinOrientation.rotated,
              );
              if (rotation == 0) {
                return (
                  advance:
                      font + 1 + scaler.scale(preferences.letterSpacing - .1),
                  rotation: rotation,
                );
              }
              painter.text = TextSpan(
                text: display,
                style: ReaderRichParagraph.emphasized(verticalStyle, emphasis),
              );
              painter.layout();
              return (
                advance:
                    painter.width +
                    1 +
                    scaler.scale(preferences.letterSpacing - .1),
                rotation: rotation,
              );
            });
            rotations[c] = metric.rotation;
            advances[c] = metric.advance;
            c++;
            if (c % 128 == 0 && clock.elapsedMilliseconds >= 4) {
              await Future<void>.delayed(Duration.zero);
              if (!current()) return null;
              clock.reset();
            }
          }
          metrics = measured.vertical[index] = _VerticalMetrics(
            clusters,
            offsets,
            advances,
            rotations,
            annotations,
          );
        }
        final clusters = metrics.clusters, offsets = metrics.offsets;
        final advances = metrics.advances;
        var first = 0;
        final breakCluster = pageBreak?.paragraph == index
            ? offsets.indexOf(pageBreak!.offset)
            : -1;
        while (first < clusters.length) {
          if (first == breakCluster) flush();
          if (right < paragraphColumnWidth - .1 && fragments.isNotEmpty) {
            flush();
          }
          final indent = first == 0 && preferences.indent && format.allowsIndent
              ? font * 2
              : 0.0;
          var height = indent;
          var end = first;
          while (end < clusters.length &&
              (end == first || end != breakCluster) &&
              (end == first || height + advances[end] <= size.height)) {
            if (clusters[end] == '\n') {
              end++;
              break;
            }
            height += advances[end++];
          }
          // Backtrack on grapheme boundaries. Never split emoji/combining text.
          if (end < clusters.length &&
              end != breakCluster &&
              clusters[end - 1] != '\n') {
            var adjusted = end;
            while (adjusted > first + 1 &&
                !_canBreakVertical(
                  clusters[adjusted - 1],
                  clusters[adjusted],
                )) {
              adjusted--;
            }
            end = adjusted;
          }
          final sourceStart = offsets[first], sourceEnd = offsets[end];
          if (previousParagraph != -1 && previousParagraph != index) {
            pageText.write('\n\n');
          }
          final pageStart = pageText.length;
          pageText.write(text.substring(sourceStart, sourceEnd));
          previousParagraph = index;
          final width = math.min(paragraphColumnWidth, size.width);
          final left = right - width;
          final used = advances
              .getRange(first, end)
              .fold(0.0, (sum, value) => sum + value);
          final extra =
              format.textAlign(
                        preferences.justify
                            ? TextAlign.justify
                            : TextAlign.start,
                      ) ==
                      TextAlign.justify &&
                  end < clusters.length &&
                  end - first > 1 &&
                  clusters[end - 1] != '\n'
              ? math.max(0.0, (size.height - indent - used) / (end - first - 1))
              : 0.0;
          final alignmentOffset = switch (format.alignment) {
            'right' || 'end' => math.max(0.0, size.height - indent - used),
            'center' => math.max(0.0, size.height - indent - used) / 2,
            _ => 0.0,
          };
          var glyphY = indent + alignmentOffset;
          for (var c = first; c < end; c++) {
            if (clusters[c] == '\n') continue;
            glyphY += advances[c] + extra;
          }
          columns.add(
            _VerticalColumn(
              metrics: metrics,
              paragraph: index,
              first: first,
              end: end,
              pageStart: pageStart,
              left:
                  left +
                  (width - font - (format.ruby.isEmpty ? 0 : font * .52)) / 2,
              indent: indent + alignmentOffset,
              font: font,
              extra: extra,
              format: format,
            ),
          );
          fragments.add(
            ReaderPageFragment(
              paragraph: index,
              start: sourceStart,
              end: sourceEnd,
              text: text.substring(sourceStart, sourceEnd),
              rect: Rect.fromLTWH(left, 0, width, glyphY - extra),
            ),
          );
          right -= width;
          first = end;
          if (clock.elapsedMilliseconds >= 4) {
            await Future<void>.delayed(Duration.zero);
            if (!current()) return null;
            clock.reset();
          }
        }
        painter.textScaler = scaler;
      }
      if (clock.elapsedMilliseconds >= 4) {
        await Future<void>.delayed(Duration.zero);
        clock.reset();
      }
    }
    flush();
    if (pages.isEmpty) pages.add(ReaderLeaf(const []));
    return current()
        ? ReaderPagination._measured(List.unmodifiable(pages), size, glyphCache)
        : null;
  } finally {
    painter.dispose();
  }
}

bool _canBreakVertical(String before, String after) {
  const closing = '，。！？、；：）》」』】〕］｝’”';
  const opening = '（《「『【〔［｛‘“';
  return !closing.contains(after) &&
      !opening.contains(before) &&
      KinsokuProcessor.canBreakAt('$before$after', before.length);
}
