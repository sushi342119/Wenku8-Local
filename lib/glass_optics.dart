import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Shared, theme-independent optics for transparent control surfaces.
/// This is a thin-lens UI approximation, not a second opaque border material.
abstract final class GlassOptics {
  // A subtler meniscus keeps small controls readable while still refracting
  // the live background. Shared by controls and their expanding overlays.
  static const refractiveIndex = 1.33;
  static const lightDirection = Offset(-.70710678118, -.70710678118);

  /// Unpolarized Fresnel reflectance at an air/glass interface.
  /// Reflection replaces transmission; it is not added to the backdrop RGB.
  static double fresnel(double cosIncident) {
    final cosI = cosIncident.clamp(0.0, 1.0);
    final sinT2 = (1 - cosI * cosI) / (refractiveIndex * refractiveIndex);
    final cosT = math.sqrt(1 - sinT2);
    final rs =
        (cosI - refractiveIndex * cosT) / (cosI + refractiveIndex * cosT);
    final rp =
        (refractiveIndex * cosI - cosT) / (refractiveIndex * cosI + cosT);
    return (rs * rs + rp * rp) / 2;
  }

  /// A neutral upper-left area light reflected by a rounded meniscus.
  /// The unlit side transmits its surroundings instead of receiving a gray
  /// outline or an equally strong, fabricated opposite light.
  static double reflectionAlpha({
    required Offset outwardNormal,
    required double depth,
    required double bevel,
    double strength = 1,
  }) {
    final slope = (1 - depth / bevel).clamp(0.0, 1.0);
    final cosIncident = math.sqrt(1 - slope * slope);
    final alignment = math.max(
      0.0,
      outwardNormal.dx * lightDirection.dx +
          outwardNormal.dy * lightDirection.dy,
    );
    final edgeFade = (1 - depth / bevel).clamp(0.0, 1.0);
    return (fresnel(cosIncident) *
            (.025 + .975 * alignment * alignment) *
            edgeFade *
            strength)
        .clamp(0.0, 1.0);
  }
}

/// Interpolated white reflection over the actual refracted backdrop. Vertex
/// normals follow the perimeter, so corners do not inherit a screen gradient.
class GlassReflectionPainter extends CustomPainter {
  const GlassReflectionPainter({required this.radius, this.strength = 1});

  final double radius;
  final double strength;
  static final _pictures = <(Size, double, double), ui.Picture>{};

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final key = (size, radius, strength);
    var picture = _pictures.remove(key);
    if (picture == null) {
      final recorder = ui.PictureRecorder();
      _paintReflection(Canvas(recorder), size);
      picture = recorder.endRecording();
    }
    _pictures[key] = picture;
    if (_pictures.length > 32) {
      _pictures.remove(_pictures.keys.first)!.dispose();
    }
    canvas.drawPicture(picture);
  }

  void _paintReflection(Canvas canvas, Size size) {
    final effectiveRadius = math.min(radius, size.shortestSide / 2);
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(effectiveRadius),
        ),
      );
    final metric = path.computeMetrics().single;
    final count = (metric.length / 2).ceil().clamp(40, 600);
    final bevel = math.min(5.0, size.shortestSide / 5);
    final depths = [
      0.0,
      .05,
      .12,
      .24,
      .44,
      .70,
      1.0,
    ].map((fraction) => fraction * bevel).toList(growable: false);
    final positions = <Offset>[];
    final normals = <Offset>[];
    for (var step = 0; step <= count; step++) {
      final tangent = metric.getTangentForOffset(
        metric.length * (step % count) / count,
      )!;
      positions.add(tangent.position);
      normals.add(Offset(tangent.vector.dy, -tangent.vector.dx));
    }

    canvas.save();
    canvas.clipPath(path, doAntiAlias: true);
    for (var ring = 0; ring < depths.length - 1; ring++) {
      final vertices = <Offset>[];
      final colors = <Color>[];
      for (var step = 0; step <= count; step++) {
        final normal = normals[step];
        for (final depth in [depths[ring], depths[ring + 1]]) {
          vertices.add(positions[step] - normal * depth);
          colors.add(
            Colors.white.withValues(
              alpha: GlassOptics.reflectionAlpha(
                outwardNormal: normal,
                depth: depth,
                bevel: bevel,
                strength: strength,
              ),
            ),
          );
        }
      }
      final mesh = ui.Vertices(
        ui.VertexMode.triangleStrip,
        vertices,
        colors: colors,
      );
      canvas.drawVertices(mesh, BlendMode.srcOver, Paint());
      mesh.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(GlassReflectionPainter oldDelegate) =>
      radius != oldDelegate.radius || strength != oldDelegate.strength;
}

/// Painted AFTER the glass, outside its silhouette. A backdrop filter must
/// never refract its own cast shadow into a metallic-looking dark rim.
class GlassShadowPainter extends CustomPainter {
  const GlassShadowPainter({required this.radius, required this.alpha});

  final double radius;
  final double alpha;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final silhouette = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(30))
      ..addRRect(silhouette);
    canvas.save();
    canvas.clipPath(outside, doAntiAlias: true);
    canvas.drawRRect(
      silhouette.shift(const Offset(0, 4)),
      Paint()
        ..color = Colors.black.withValues(alpha: alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(GlassShadowPainter oldDelegate) =>
      radius != oldDelegate.radius || alpha != oldDelegate.alpha;
}
