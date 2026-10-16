import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

List<String> _splitParagraphs(String source) => source.split('\n\n');

class ReaderContent {
  const ReaderContent(this.paragraphs);
  final List<String> paragraphs;
  List<String> get illustrations => List.unmodifiable([
    for (final paragraph in paragraphs) ?readerIllustrationUrl(paragraph),
  ]);

  static Future<ReaderContent> parse(String source) async {
    if (source.trim().isEmpty) throw const FormatException('章节正文为空');
    final paragraphs = source.length > 64 * 1024
        ? await compute(_splitParagraphs, source)
        : _splitParagraphs(source);
    return ReaderContent(List.unmodifiable(paragraphs));
  }
}

/// Standalone paired markers from the original text API. Images keep their
/// paragraph index, so bookmarks and lazy restoration share one coordinate map.
String? readerIllustrationUrl(String paragraph) {
  const marker = '<!--image-->';
  final text = paragraph.trim();
  if (!text.startsWith(marker) ||
      !text.endsWith(marker) ||
      text.length <= marker.length * 2) {
    return null;
  }
  final raw = text.substring(marker.length, text.length - marker.length).trim();
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && ![80, 443].contains(uri.port)) ||
      !(uri.host == 'wenku8.com' ||
          uri.host.endsWith('.wenku8.com') ||
          uri.host == 'wenku8.net' ||
          uri.host.endsWith('.wenku8.net') ||
          uri.host == 'wenku8.cn' ||
          uri.host.endsWith('.wenku8.cn') ||
          uri.host == 'pic.777743.xyz')) {
    return null;
  }
  return uri.replace(scheme: 'https', port: 443).toString();
}

final _missingIllustration = RegExp(r'(^|\n)[ \t]*\[插图\][ \t]*(\n|$)');

/// Old bodies lost the URL at these stand-alone image paragraphs. Ordinary
/// prose containing the same words does not trigger a network refresh.
bool readerHasMissingIllustrations(String body) =>
    body.contains('[插图]') && _missingIllustration.hasMatch(body);

typedef ParagraphPosition = ({int index, double fraction});
typedef ParagraphTarget = ({double offset, bool exact});
typedef _MeasuredParagraph = ({int index, double top, double height});

/// Only laid-out paragraphs are registered: no global key or upfront text
/// layout per paragraph, and no work on each scroll tick. Capture occurs when
/// saving or explicitly changing the reading layout.
class ReaderParagraphRegistry {
  final Map<int, _ReaderParagraphRender> _rows = {};

  List<_MeasuredParagraph> _measure() {
    final result = <_MeasuredParagraph>[];
    for (final entry in _rows.entries) {
      final row = entry.value;
      if (!row.attached || !row.hasSize || row.size.height <= 0) continue;
      final viewport = RenderAbstractViewport.maybeOf(row);
      if (viewport == null) continue;
      final top = viewport.getOffsetToReveal(row, 0).offset;
      if (top.isFinite) {
        result.add((index: entry.key, top: top, height: row.size.height));
      }
    }
    result.sort((a, b) => a.index.compareTo(b.index));
    return result;
  }

  ParagraphPosition? capture(double readingOffset, {bool clampToLast = false}) {
    final rows = _measure();
    for (final row in rows) {
      if (readingOffset >= row.top && readingOffset < row.top + row.height) {
        return (
          index: row.index,
          fraction: (readingOffset - row.top) / row.height,
        );
      }
      if (readingOffset < row.top) return (index: row.index, fraction: 0);
    }
    return clampToLast && rows.isNotEmpty
        ? (index: rows.last.index, fraction: 1)
        : null;
  }

  /// A visible anchor can be restored exactly. Otherwise use the nearest lazy
  /// row to bring it into view, then refine on the next layout; bounded by the
  /// caller so damaged/changed chapter content cannot cause a frame loop.
  ParagraphTarget? target(
    ParagraphPosition anchor,
    double inset, {
    double? viewportBottom,
    double trailingSpace = 0,
  }) {
    final rows = _measure();
    if (rows.isEmpty) return null;
    final landing = viewportBottom == null
        ? inset
        : (inset + viewportBottom) / 2;
    double fraction(double height) {
      final contentHeight = (height - trailingSpace).clamp(0.0, height);
      return viewportBottom != null && contentHeight <= viewportBottom - inset
          ? contentHeight / height / 2
          : anchor.fraction.clamp(0.0, 1.0);
    }

    var nearest = rows.first;
    var totalHeight = 0.0;
    for (final row in rows) {
      totalHeight += row.height;
      if (row.index == anchor.index) {
        return (
          // Short bookmarked paragraphs sit in the middle of the unobscured
          // article. For a screen-long paragraph keep its bookmarked portion
          // visible instead of jumping to a different part of the paragraph.
          offset: row.top + fraction(row.height) * row.height - landing,
          exact: true,
        );
      }
      if ((row.index - anchor.index).abs() <
          (nearest.index - anchor.index).abs()) {
        nearest = row;
      }
    }
    final estimate = totalHeight / rows.length;
    return (
      offset:
          nearest.top +
          (anchor.index - nearest.index + fraction(estimate)) * estimate -
          landing,
      exact: false,
    );
  }

  /// Short paragraphs stay centered as a whole. For a screen-long paragraph,
  /// follow the spoken fragment's glyph range rather than its unchanged index.
  ParagraphTarget? speechTarget(
    int index,
    int start,
    int end,
    double inset, {
    required double viewportBottom,
    double trailingSpace = 0,
  }) {
    final anchor = target(
      (index: index, fraction: 0),
      inset,
      viewportBottom: viewportBottom,
      trailingSpace: trailingSpace,
    );
    final row = _rows[index];
    if (anchor == null ||
        !anchor.exact ||
        row == null ||
        row.size.height - trailingSpace <= viewportBottom - inset) {
      return anchor;
    }
    final offset = matchOffset(
      index,
      start,
      end,
      inset,
      viewportBottom: viewportBottom,
    );
    return offset == null ? anchor : (offset: offset, exact: true);
  }

  /// Use laid-out glyph boxes to land on the occurrence, not merely the start
  /// of a long paragraph. No upfront layout of offscreen text is required.
  double? matchOffset(
    int index,
    int start,
    int end,
    double inset, {
    double? viewportBottom,
  }) {
    final row = _rows[index];
    if (row == null || !row.attached || !row.hasSize) return null;
    RenderParagraph? text;
    void visit(RenderObject node) {
      if (text != null) return;
      if (node is RenderParagraph) {
        text = node;
        return;
      }
      node.visitChildren(visit);
    }

    visit(row);
    final paragraph = text;
    final viewport = RenderAbstractViewport.maybeOf(row);
    if (paragraph == null || viewport == null) return null;
    final length = paragraph.text.toPlainText().length;
    if (start < 0 || start >= length || end <= start) return null;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end.clamp(start, length)),
    );
    if (boxes.isEmpty) return null;
    final local = paragraph.localToGlobal(
      Offset(0, boxes.first.top),
      ancestor: row,
    );
    final top = viewport.getOffsetToReveal(row, 0).offset + local.dy;
    if (viewportBottom == null) return top - inset;
    var bottom = boxes.first.bottom;
    for (final box in boxes.skip(1)) {
      if (box.bottom > bottom) bottom = box.bottom;
    }
    final height = bottom - boxes.first.top;
    return height <= viewportBottom - inset
        ? top + height / 2 - (inset + viewportBottom) / 2
        : top - inset;
  }
}

class ReaderParagraph extends SingleChildRenderObjectWidget {
  const ReaderParagraph({
    super.key,
    required this.registry,
    required this.index,
    required super.child,
  });
  final ReaderParagraphRegistry registry;
  final int index;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ReaderParagraphRender(registry, index);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProxyBox renderObject,
  ) {
    (renderObject as _ReaderParagraphRender).update(registry, index);
  }
}

class _ReaderParagraphRender extends RenderProxyBox {
  _ReaderParagraphRender(this.registry, this.index);
  ReaderParagraphRegistry registry;
  int index;

  void _remove() {
    if (identical(registry._rows[index], this)) registry._rows.remove(index);
  }

  void update(ReaderParagraphRegistry value, int number) {
    if (registry == value && index == number) return;
    _remove();
    registry = value;
    index = number;
    if (attached) registry._rows[index] = this;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    registry._rows[index] = this;
  }

  @override
  void detach() {
    _remove();
    super.detach();
  }
}
