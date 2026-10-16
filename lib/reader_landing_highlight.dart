import 'package:flutter/material.dart';

import 'archive_design.dart';

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
    final rect = Rect.fromLTWH(-8, -3, size.width + 16, size.height + 6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        const Radius.circular(ArchiveDesign.panelRadius),
      ),
      Paint()
        ..color =
            (dark
                    ? ArchiveDesign.milk
                    : Color.lerp(
                        ArchiveDesign.milk,
                        ArchiveDesign.darkSurface,
                        .065,
                      )!)
                .withValues(alpha: strength * (dark ? .13 : .92)),
    );
    final rule = Paint()
      ..color = (dark ? ArchiveDesign.milk : ArchiveDesign.darkSurface)
          .withValues(alpha: strength * (dark ? .65 : .42))
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(rect.left, rect.top),
      Offset(rect.left, rect.bottom),
      rule,
    );
    canvas.drawLine(
      Offset(rect.left, rect.top),
      Offset(rect.left + 7, rect.top),
      rule,
    );
    canvas.drawLine(
      Offset(rect.right - 7, rect.bottom),
      Offset(rect.right, rect.bottom),
      rule,
    );
  }

  @override
  bool shouldRepaint(_LandingPlane oldDelegate) =>
      clock != oldDelegate.clock || dark != oldDelegate.dark;
}
