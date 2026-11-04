import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'reader_underline.dart';
import 'reader_landing_highlight.dart';

/// Keeps saved colors recognizable on both custom light and night paper.
Color readerMarkInk(
  ReaderMarkColor color,
  Color foreground, {
  bool dark = false,
}) {
  final value = color.argb;
  if (value == null) return foreground;
  final ink = Color(value);
  return dark ? Color.lerp(ink, Colors.white, .2)! : ink;
}

/// Saved marks are paint-only and never alter text shaping or line breaks.
Color readerMarkTint(
  ReaderMarkColor color,
  Color foreground, {
  bool dark = false,
}) => readerMarkInk(
  color,
  foreground,
  dark: dark,
).withValues(alpha: dark ? .28 : .22);

/// Uses the already laid-out paragraph for outlines; it never shapes text twice.
class ReaderAnnotationOutlines extends SingleChildRenderObjectWidget {
  const ReaderAnnotationOutlines({
    super.key,
    required this.marks,
    required this.foreground,
    required this.dark,
    this.prefix = 0,
    required super.child,
  });
  final List<ReaderTextMark> marks;
  final Color foreground;
  final bool dark;
  final int prefix;

  @override
  RenderReaderAnnotationOutlines createRenderObject(BuildContext context) =>
      RenderReaderAnnotationOutlines(marks, foreground, dark, prefix);
  @override
  void updateRenderObject(
    BuildContext context,
    RenderReaderAnnotationOutlines renderObject,
  ) => renderObject.update(marks, foreground, dark, prefix);
}

/// Paint-only source ranges share the bookmark landing frame and its outsets.
class RenderReaderAnnotationOutlines extends RenderProxyBox {
  RenderReaderAnnotationOutlines(
    this._marks,
    this._foreground,
    this._dark,
    this._prefix,
  );
  List<ReaderTextMark> _marks;
  Color _foreground;
  bool _dark;
  int _prefix;
  void update(
    List<ReaderTextMark> marks,
    Color foreground,
    bool dark,
    int prefix,
  ) {
    _marks = marks;
    _foreground = foreground;
    _dark = dark;
    _prefix = prefix;
    markNeedsPaint();
  }

  RenderParagraph? get _paragraph {
    RenderParagraph? found;
    void visit(RenderObject object) {
      if (found != null) return;
      if (object is RenderParagraph) {
        found = object;
        return;
      }
      object.visitChildren(visit);
    }

    visit(this);
    return found;
  }

  /// Actual render geometry is also useful when verifying paginated slices.
  List<({Rect rect, ReaderMarkColor color})> get outlineBounds {
    final paragraph = _paragraph;
    if (paragraph == null || !paragraph.hasSize) return const [];
    final transform = paragraph.getTransformTo(this);
    return [
      for (final mark in _marks)
        if (mark.style == ReaderMarkStyle.outline && mark.end > mark.start)
          ...() {
            final boxes = paragraph.getBoxesForSelection(
              TextSelection(
                baseOffset: mark.start + _prefix,
                extentOffset: mark.end + _prefix,
              ),
            );
            if (boxes.isEmpty) return <({Rect rect, ReaderMarkColor color})>[];
            var bounds = boxes.first.toRect();
            for (final box in boxes.skip(1)) {
              bounds = bounds.expandToInclude(box.toRect());
            }
            return [
              (
                rect: readerRegistrationBounds(
                  MatrixUtils.transformRect(transform, bounds),
                ),
                color: mark.color,
              ),
            ];
          }(),
    ];
  }

  @override
  Rect get paintBounds => super.paintBounds.inflate(8);

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    // Indexed marks are newest first; paint their rules last at intersections.
    for (final outline in outlineBounds.reversed) {
      paintReaderRegistrationFrame(
        context.canvas,
        outline.rect.shift(offset),
        ink: readerMarkInk(
          outline.color,
          _foreground,
          dark: _dark,
        ).withValues(alpha: _dark ? .65 : .42),
      );
    }
  }
}
