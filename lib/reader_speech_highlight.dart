import 'package:flutter/material.dart';

/// A persistent, clearly visible paragraph marker. No blur, glow or ticker.
@immutable
class ReaderSpeechHighlightStyle {
  const ReaderSpeechHighlightStyle({required this.fill, required this.rule});
  factory ReaderSpeechHighlightStyle.of(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return ReaderSpeechHighlightStyle(
      fill: theme.colorScheme.onSurface.withValues(alpha: dark ? .22 : .12),
      rule: theme.colorScheme.onSurface.withValues(alpha: dark ? .8 : .65),
    );
  }
  final Color fill, rule;

  void paint(Canvas canvas, Rect rect, {bool vertical = false}) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = fill,
    );
    final x = vertical ? rect.right - 1.2 : rect.left + 1.2;
    canvas.drawLine(
      Offset(x, rect.top + 2),
      Offset(x, rect.bottom - 2),
      Paint()
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..color = rule,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderSpeechHighlightStyle &&
      fill == other.fill &&
      rule == other.rule;
  @override
  int get hashCode => Object.hash(fill, rule);
}
