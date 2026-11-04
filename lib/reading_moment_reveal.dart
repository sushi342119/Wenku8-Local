import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One short reveal and a two-sided celebration. The owner starts it once; this
/// never creates a ticker, loops, or paints into the exported content boundary.
class ReadingMomentReveal extends StatelessWidget {
  const ReadingMomentReveal({
    super.key,
    required this.animation,
    required this.accent,
    required this.child,
  });

  final Animation<double> animation;
  final Color accent;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final progress = animation.value;
      // The static endpoint must be a genuine untransformed surface, including
      // Harmony's visible native photo-save control added after the reveal.
      if (progress >= 1) return child!;
      final arrival = Curves.easeInOutCubic.transform(
        (progress / .45).clamp(0.0, 1.0),
      );
      return Transform.translate(
        offset: Offset(0, 16 * (1 - arrival)),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipPath(clipper: _DossierRevealClipper(arrival), child: child),
            if (progress > 0 && progress < 1)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    key: const ValueKey('reading-moment-reveal-traces'),
                    painter: ReadingMomentRevealPainter(progress, accent),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _DossierRevealClipper extends CustomClipper<Path> {
  const _DossierRevealClipper(this.progress);
  final double progress;

  @override
  Path getClip(Size size) {
    if (progress >= 1) return Path()..addRect(Offset.zero & size);
    final edge = -20 + (size.width + 40) * progress;
    return Path()
      ..moveTo(0, 0)
      ..lineTo(edge + 18, 0)
      ..lineTo(edge, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(_DossierRevealClipper oldClipper) =>
      progress != oldClipper.progress;
}

/// A bright opening edge, then paper and short arcs travelling away from the
/// card. The burst stays outside the reading area and resolves in one event.
class ReadingMomentRevealPainter extends CustomPainter {
  const ReadingMomentRevealPainter(this.progress, this.accent);
  final double progress;
  final Color accent;
  static const _paper = Color(0xfffff5df);

  double _phase(double start, double end) =>
      ((progress - start) / (end - start)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final paint = Paint()..strokeCap = StrokeCap.round;
    final opening = Curves.easeInOutCubic.transform(_phase(0, .45));
    if (progress < .45) {
      final edge = -20 + (size.width + 40) * opening;
      final alpha = math.sin(_phase(0, .45) * math.pi);
      paint
        ..color = accent.withValues(alpha: alpha * .42)
        ..strokeWidth = 9;
      canvas.drawLine(
        Offset(edge + 18, 4),
        Offset(edge, size.height - 4),
        paint,
      );
      paint
        ..color = _paper.withValues(alpha: alpha)
        ..strokeWidth = 3;
      canvas.drawLine(
        Offset(edge + 18, 4),
        Offset(edge, size.height - 4),
        paint,
      );
    }

    for (var side = 0; side < 2; side++) {
      final direction = side == 0 ? -1.0 : 1.0;
      final origin = Offset(
        side == 0 ? 0 : size.width,
        math.min(size.height * .29, 134),
      );
      _paperBurst(canvas, paint, origin, direction);
      _arcBurst(canvas, paint, origin, direction);
    }

    final settle = _phase(.48, 1);
    if (settle > 0 && settle < 1) {
      final alpha = math.sin(settle * math.pi) * .85;
      paint
        ..color = accent.withValues(alpha: alpha)
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke;
      const inset = 7.0;
      final length = 20 + 9 * (1 - settle);
      canvas.drawPath(
        Path()
          ..moveTo(inset, inset + length)
          ..lineTo(inset, inset)
          ..lineTo(inset + length, inset),
        paint,
      );
      canvas.drawPath(
        Path()
          ..moveTo(size.width - inset - length, size.height - inset)
          ..lineTo(size.width - inset, size.height - inset)
          ..lineTo(size.width - inset, size.height - inset - length),
        paint,
      );
    }
  }

  void _paperBurst(
    Canvas canvas,
    Paint paint,
    Offset origin,
    double direction,
  ) {
    for (var index = 0; index < 12; index++) {
      final flight = _phase(.22 + (index % 4) * .018, .88 + (index % 3) * .035);
      if (flight <= 0 || flight >= 1) continue;
      final outward = Curves.easeOutCubic.transform(flight);
      final rise = -62.0 + (index % 6) * 23;
      final distance = 4 + (10 + (index % 4) * 6) * outward;
      final center =
          origin +
          Offset(
            direction * distance,
            rise * outward + 25 * flight * flight + (index ~/ 6) * 11,
          );
      // Stay fully visible through the impulse; only the settling tail fades.
      final opacity = (1 - ((flight - .52) / .48).clamp(0.0, 1.0)) * .98;
      final color = switch (index % 3) {
        0 => accent,
        1 => _paper,
        _ => Color.lerp(accent, _paper, .45)!,
      };
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(direction * (.35 * index + flight * 3.2));
      paint
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.fill;
      final length = 8.0 + (index % 3) * 2;
      final thickness = 3.5 + (index % 2) * 1.5;
      if (index % 4 == 0) {
        final half = length * .48;
        canvas.drawPath(
          Path()
            ..moveTo(0, -half)
            ..lineTo(half * .65, 0)
            ..lineTo(0, half)
            ..lineTo(-half * .65, 0)
            ..close(),
          paint,
        );
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset.zero,
              width: length,
              height: thickness,
            ),
            const Radius.circular(1),
          ),
          paint,
        );
      }
      canvas.restore();
    }
  }

  void _arcBurst(Canvas canvas, Paint paint, Offset origin, double direction) {
    final burst = _phase(.25, .74);
    if (burst <= 0 || burst >= 1) return;
    final travel = Curves.easeOutCubic.transform(burst);
    final opacity = math.sin(burst * math.pi) * .9;
    for (var index = 0; index < 2; index++) {
      final reach = 12 + travel * 20;
      final lift = index == 0 ? -1.0 : 1.0;
      final start = origin + Offset(direction * (reach - 11), lift * 28);
      final end = origin + Offset(direction * reach, lift * 48);
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = index == 0 ? 3 : 2.5
        ..color = (index == 0 ? _paper : accent).withValues(alpha: opacity);
      canvas.drawPath(
        Path()
          ..moveTo(start.dx, start.dy)
          ..quadraticBezierTo(end.dx + direction * 2, start.dy, end.dx, end.dy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(ReadingMomentRevealPainter oldDelegate) =>
      progress != oldDelegate.progress || accent != oldDelegate.accent;
}
