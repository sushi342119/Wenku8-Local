import 'dart:math' as math;
import 'dart:ui';

enum HalftoneFalloff {
  uniform,
  leftToRight,
  rightToLeft,
  topToBottom,
  bottomToTop,
  radial,
}

/// Static print texture for non-data regions. A 10 logical-pixel pitch maps to
/// 18 pixels in a 1080-wide/600-logical poster, keeping the sampling deliberate.
/// Directional falloffs fade toward their named destination; radial fades away
/// from [focus], expressed as a fraction of [bounds]. No animation or asset.
void paintCanvasHalftone(
  Canvas canvas,
  Rect bounds, {
  required Color color,
  HalftoneFalloff falloff = HalftoneFalloff.uniform,
  Offset focus = const Offset(.5, .5),
  double radialExtent = .7,
  double pitch = 10,
  double maxRadius = 1.6,
  Path? clipPath,
}) {
  if (bounds.isEmpty || pitch <= 0 || maxRadius <= 0 || color.a == 0) return;
  final paint = Paint()..color = color;
  canvas.save();
  canvas.clipRect(bounds);
  if (clipPath != null) canvas.clipPath(clipPath);
  final startX = (bounds.left / pitch).ceil() * pitch;
  final startY = (bounds.top / pitch).ceil() * pitch;
  for (var y = startY; y <= bounds.bottom; y += pitch) {
    for (var x = startX; x <= bounds.right; x += pitch) {
      final u = (x - bounds.left) / bounds.width;
      final v = (y - bounds.top) / bounds.height;
      final strength = switch (falloff) {
        HalftoneFalloff.uniform => 1.0,
        HalftoneFalloff.leftToRight => 1 - u,
        HalftoneFalloff.rightToLeft => u,
        HalftoneFalloff.topToBottom => 1 - v,
        HalftoneFalloff.bottomToTop => v,
        HalftoneFalloff.radial =>
          radialExtent <= 0
              ? 0.0
              : 1 -
                    math.sqrt(
                          math.pow(u - focus.dx, 2) + math.pow(v - focus.dy, 2),
                        ) /
                        radialExtent,
      }.clamp(0.0, 1.0);
      if (strength < .12) continue;
      final radius = (maxRadius * math.sqrt(strength) * 10).round() / 10;
      if (radius < .55) continue;
      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }
  canvas.restore();
}
