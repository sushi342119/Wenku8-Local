import 'package:flutter/material.dart';

import 'archive_design.dart';

/// Shared archive frame used for both bookmark landing and saved outlines.
/// These are paint outsets, so marking never changes reading line breaks.
Rect readerRegistrationBounds(Rect textBounds) => Rect.fromLTRB(
  textBounds.left - 8,
  textBounds.top - 3,
  textBounds.right + 8,
  textBounds.bottom + 3,
);

/// Draws the same restrained corner rule without adding another UI surface.
void paintReaderRegistrationFrame(
  Canvas canvas,
  Rect rect, {
  required Color ink,
  Color? fill,
}) {
  if (fill != null) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        const Radius.circular(ArchiveDesign.panelRadius),
      ),
      Paint()..color = fill,
    );
  }
  final rule = Paint()
    ..color = ink
    ..strokeWidth = 1.3
    ..style = PaintingStyle.stroke;
  canvas.drawLine(rect.topLeft, rect.bottomLeft, rule);
  canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(7, 0), rule);
  canvas.drawLine(
    rect.bottomRight - const Offset(7, 0),
    rect.bottomRight,
    rule,
  );
}

/// A temporary archive registration plane, never a text glow or blur layer.
class ReaderLandingHighlight extends StatefulWidget {
  const ReaderLandingHighlight({
    super.key,
    required this.child,
    this.reduceMotion = false,
  });
  final Widget child;
  final bool reduceMotion;

  @override
  State<ReaderLandingHighlight> createState() => _ReaderLandingHighlightState();
}

class _ReaderLandingHighlightState extends State<ReaderLandingHighlight>
    with SingleTickerProviderStateMixin {
  AnimationController? _clock;
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncClock();
  }

  @override
  void didUpdateWidget(ReaderLandingHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncClock();
  }

  void _syncClock() {
    _reduced = widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
    if (_reduced) {
      _clock?.stop();
    } else {
      _clock ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2000),
      );
      if (_clock!.value < 1 && !_clock!.isAnimating) _clock!.forward();
    }
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _LandingPlane(
      clock: _reduced ? null : _clock,
      dark: Theme.of(context).brightness == Brightness.dark,
    ),
    child: widget.child,
  );

  @override
  void dispose() {
    _clock?.dispose();
    super.dispose();
  }
}

class _LandingPlane extends CustomPainter {
  _LandingPlane({required this.clock, required this.dark})
    : super(repaint: clock);
  final Animation<double>? clock;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock?.value;
    final strength = t == null
        ? 1.0
        : t < .14
        ? Curves.easeOut.transform(t / .14)
        : t < .7
        ? 1.0
        : 1 - Curves.easeInOut.transform(((t - .7) / .3).clamp(0.0, 1.0));
    if (strength <= 0) return;
    final rect = readerRegistrationBounds(Offset.zero & size);
    paintReaderRegistrationFrame(
      canvas,
      rect,
      fill:
          (dark
                  ? ArchiveDesign.milk
                  : Color.lerp(
                      ArchiveDesign.milk,
                      ArchiveDesign.darkSurface,
                      .065,
                    )!)
              .withValues(alpha: strength * (dark ? .13 : .92)),
      ink: (dark ? ArchiveDesign.milk : ArchiveDesign.darkSurface).withValues(
        alpha: strength * (dark ? .65 : .42),
      ),
    );
  }

  @override
  bool shouldRepaint(_LandingPlane oldDelegate) =>
      clock != oldDelegate.clock || dark != oldDelegate.dark;
}
