import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

class ReaderPaperMesh {
  const ReaderPaperMesh({
    required this.outline,
    required this.positions,
    required this.uv,
    required this.normals,
    required this.indices,
  });

  final Path outline;
  final Float32List positions;
  final Float32List uv;
  final List<double> normals;
  final Uint16List indices;
}

class ReaderPaperGeometry {
  ReaderPaperGeometry({
    required this.size,
    required this.gap,
    required this.progress,
    required this.touchY,
  }) : lift = math.sin(progress.clamp(0.0, 1.0) * math.pi) {
    final t = progress.clamp(0.0, 1.0);
    final w = size.width;
    final h = size.height;
    final creaseX = w * (1 - t);
    final curlWidth = math.max(1.0, w * 0.14 * lift);
    final frontLeft = 0.0;
    final frontRight = creaseX.clamp(0.0, w);
    final backLeft = (creaseX - curlWidth * (1 + t)).clamp(-w - gap * 2, w);
    final backRight = frontRight;

    front = _buildQuadMesh(
      left: frontLeft,
      right: frontRight,
      height: h,
      uStart: 0,
      uEnd: frontRight,
      normalStart: 1.0,
      normalEnd: 1.0 - 0.35 * lift,
    );
    frontInk = front;

    back = _buildQuadMesh(
      left: backLeft,
      right: backRight,
      height: h,
      uStart: (w - (backRight - backLeft)).clamp(0.0, w),
      uEnd: w,
      normalStart: -0.95,
      normalEnd: -0.55,
    );
    backInk = back;

    sheet = Path.combine(PathOperation.union, front.outline, back.outline);
  }

  final Size size;
  final double gap;
  final double progress;
  final double touchY;
  final double lift;
  late final Path sheet;
  late final ReaderPaperMesh front;
  late final ReaderPaperMesh frontInk;
  late final ReaderPaperMesh back;
  late final ReaderPaperMesh backInk;

  static ReaderPaperMesh _buildQuadMesh({
    required double left,
    required double right,
    required double height,
    required double uStart,
    required double uEnd,
    required double normalStart,
    required double normalEnd,
  }) {
    const columns = 8;
    final vertexCount = (columns + 1) * 2;
    final positions = Float32List(vertexCount * 2);
    final uv = Float32List(vertexCount * 2);
    final normals = List<double>.filled(vertexCount, 1.0);
    final indices = Uint16List(columns * 6);

    for (var i = 0; i <= columns; i++) {
      final frac = i / columns;
      final x = left + (right - left) * frac;
      final u = uStart + (uEnd - uStart) * frac;
      final normal = normalStart + (normalEnd - normalStart) * frac;
      final topIdx = i * 2;
      final botIdx = topIdx + 1;

      positions[topIdx * 2] = x;
      positions[topIdx * 2 + 1] = 0;
      positions[botIdx * 2] = x;
      positions[botIdx * 2 + 1] = height;

      uv[topIdx * 2] = u;
      uv[topIdx * 2 + 1] = 0;
      uv[botIdx * 2] = u;
      uv[botIdx * 2 + 1] = height;

      normals[topIdx] = normal;
      normals[botIdx] = normal;
    }

    var k = 0;
    for (var i = 0; i < columns; i++) {
      final v0 = i * 2;
      final v1 = v0 + 1;
      final v2 = v0 + 2;
      final v3 = v0 + 3;
      indices[k++] = v0;
      indices[k++] = v1;
      indices[k++] = v2;
      indices[k++] = v2;
      indices[k++] = v1;
      indices[k++] = v3;
    }

    final outline = Path()
      ..addRect(Rect.fromLTRB(math.min(left, right), 0, math.max(left, right), height));

    return ReaderPaperMesh(
      outline: outline,
      positions: positions,
      uv: uv,
      normals: normals,
      indices: indices,
    );
  }
}
