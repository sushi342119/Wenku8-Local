import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'reader_paper_geometry.dart';

/// All leaves share one frame's geometry. Only paint follows the page clock;
/// the retained text is neither rebuilt nor laid out on animation ticks.
class ReaderPaperClock extends ChangeNotifier {
  ReaderPaperClock(this.animation) {
    animation.addListener(_tick);
  }
  final Animation<double> animation;
  double _touchY = .5;
  set touchY(double value) {
    final next = value.clamp(0.0, 1.0);
    if (_touchY == next) return;
    _touchY = next;
    _tick();
  }

  ReaderPaperGeometry? _cached;
  void _tick() {
    _cached = null;
    notifyListeners();
  }

  ReaderPaperGeometry geometry(Size size, double gap) =>
      _cached?.size == size && _cached?.gap == gap
      ? _cached!
      : (_cached = ReaderPaperGeometry(
          size: size,
          gap: gap,
          progress: animation.value.clamp(0.0, 1.0),
          touchY: _touchY,
        ));
  @override
  void dispose() {
    animation.removeListener(_tick);
    super.dispose();
  }
}

/// Each visible face uses one texture-backed snapshot per turn at real display
/// density. Keeping all paper in the same canvas also clips independently
/// composited text/images reliably. The SDK releases textures when the turn ends.
class ReaderSpineTurn extends StatefulWidget {
  const ReaderSpineTurn({
    super.key,
    required this.animation,
    required this.active,
    required this.incoming,
    required this.left,
    required this.fromRight,
    required this.paper,
    required this.child,
    this.single = false,
    this.gap = 0,
    this.clock,
  });
  final Animation<double> animation;
  final ReaderPaperClock? clock;
  final bool active, incoming, left, fromRight, single;
  final double gap;
  final Color paper;
  final Widget child;
  @override
  State<ReaderSpineTurn> createState() => _ReaderSpineTurnState();
}

class _ReaderSpineTurnState extends State<ReaderSpineTurn> {
  final _snapshot = SnapshotController();
  late ReaderPaperClock _clock;
  late ReaderPaperPainter _painter;
  void _setup() {
    _clock = widget.clock ?? ReaderPaperClock(widget.animation);
    _painter = ReaderPaperPainter(widget, _clock);
    _snapshot.allowSnapshotting = widget.active;
  }

  @override
  void initState() {
    super.initState();
    _setup();
  }

  @override
  void didUpdateWidget(ReaderSpineTurn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clock != widget.clock ||
        oldWidget.animation != widget.animation) {
      _painter.dispose();
      if (oldWidget.clock == null) _clock.dispose();
      _setup();
      _snapshot.clear();
    } else {
      _painter.update(widget);
      _snapshot.allowSnapshotting = widget.active;
    }
  }

  @override
  void dispose() {
    _painter.dispose();
    if (widget.clock == null) _clock.dispose();
    _snapshot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: widget.active,
    child: SnapshotWidget(
      controller: _snapshot,
      autoresize: true,
      painter: _painter,
      child: widget.child,
    ),
  );
}

class ReaderPaperPainter extends SnapshotPainter {
  ReaderPaperPainter(this.config, this.clock) {
    if (config.active) clock.addListener(notifyListeners);
  }
  ReaderSpineTurn config;
  final ReaderPaperClock clock;
  bool get moving => config.single
      ? !config.incoming
      : (config.incoming
            ? config.left == config.fromRight
            : config.left != config.fromRight);
  bool get _back => config.incoming && !config.single;
  double get _sign => config.fromRight ? 1 : -1;
  @visibleForTesting
  int snapshotCount = 0;
  int? _lastImage;
  ui.ImageShader? _texture;
  void update(ReaderSpineTurn next) {
    if (config.active != next.active) {
      if (next.active) {
        clock.addListener(notifyListeners);
      } else {
        clock.removeListener(notifyListeners);
      }
    }
    config = next;
    if (!next.active) {
      _texture?.dispose();
      _texture = null;
    }
    notifyListeners();
  }

  double _hinge(Size size) => config.single
      ? (config.fromRight ? 0 : size.width)
      : (config.left ? size.width + config.gap : -config.gap);
  Matrix4 _matrix(Size size) => Matrix4.identity()
    ..translateByDouble(_hinge(size), 0, 0, 1)
    ..scaleByDouble(_sign, 1, 1, 1);
  Path _path(Path canonical, Size size) =>
      canonical.transform(_matrix(size).storage);

  @override
  void paint(
    PaintingContext context,
    Offset offset,
    Size size,
    PaintingContextCallback painter,
  ) {
    if (!config.active) {
      painter(context, offset);
      return;
    }
    final geometry = clock.geometry(size, config.gap);
    final obstruction = config.incoming
        ? geometry.sheet
        : geometry.back.outline;
    final visible = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      _path(obstruction, size),
    );
    if (visible.getBounds().isEmpty) return;
    // Reader paragraphs and illustrations retain composited layers. A canvas-
    // only clip does not clip those layers and lets the lower page leak through.
    context.pushClipPath(true, offset, Offset.zero & size, visible, (
      context,
      offset,
    ) {
      painter(context, offset);
      if (geometry.lift < .001) return;
      final canvas = context.canvas;
      canvas.save();
      canvas.translate(offset.dx, offset.dy);
      canvas.drawPath(
        _path(obstruction, size).shift(Offset(_sign * geometry.lift * 3, 1)),
        Paint()
          ..color = const Color(
            0xff000000,
          ).withValues(alpha: .20 * geometry.lift)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            3 + geometry.lift * 5,
          ),
      );
      canvas.restore();
    });
  }

  @override
  void paintSnapshot(
    PaintingContext context,
    Offset offset,
    Size size,
    ui.Image image,
    Size sourceSize,
    double pixelRatio,
  ) {
    if (_lastImage != identityHashCode(image)) {
      _texture?.dispose();
      _texture = null;
      _lastImage = identityHashCode(image);
      snapshotCount++;
    }
    if (!config.active) {
      context.canvas.drawImageRect(
        image,
        Offset.zero & sourceSize,
        offset & size,
        Paint(),
      );
      return;
    }
    if (!moving) {
      paint(context, offset, size, (context, offset) {
        context.canvas.drawImageRect(
          image,
          Offset.zero & sourceSize,
          offset & size,
          Paint(),
        );
      });
      return;
    }
    final geometry = clock.geometry(size, config.gap), canvas = context.canvas;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.transform(_matrix(size).storage);
    if (!_back) {
      // Complementary ownership also works when a backwards PageView paints
      // its destination before the outgoing leaf. No overlapping ink planes.
      final visible = Path.combine(
        PathOperation.difference,
        geometry.front.outline,
        geometry.back.outline,
      );
      canvas.save();
      canvas.clipPath(visible);
      _paintFace(
        canvas,
        geometry.front,
        geometry.frontInk,
        image,
        pixelRatio,
        back: false,
        lift: geometry.lift,
        size: size,
      );
      canvas.restore();
    }
    if (_back || config.single) {
      _paintFace(
        canvas,
        geometry.back,
        geometry.backInk,
        image,
        pixelRatio,
        back: true,
        lift: geometry.lift,
        size: size,
      );
    }
    canvas.restore();
  }

  void _paintFace(
    Canvas canvas,
    ReaderPaperMesh paperMesh,
    ReaderPaperMesh inkMesh,
    ui.Image image,
    double ratio, {
    required bool back,
    required double lift,
    required Size size,
  }) {
    Int32List colors(ReaderPaperMesh mesh, bool ink) => Int32List.fromList([
      for (final normal in mesh.normals)
        if (ink)
          Color.lerp(
                const Color(0xffffffff),
                const Color(0xff000000),
                (1 - normal.abs()) * .18 * lift,
              )!
              .withValues(alpha: back && config.single ? .075 * lift : 1)
              .toARGB32()
        else
          Color.lerp(
            config.paper,
            const Color(0xff000000),
            (1 - normal.abs()) * .18 * lift,
          )!.toARGB32(),
    ]);
    final surface = ui.Vertices.raw(
      ui.VertexMode.triangles,
      paperMesh.positions,
      colors: colors(paperMesh, false),
      indices: paperMesh.indices,
    );
    canvas.drawVertices(surface, BlendMode.srcOver, Paint());
    surface.dispose();
    final uv = Float32List(inkMesh.uv.length);
    for (var i = 0; i < uv.length; i += 2) {
      final u = inkMesh.uv[i];
      final mirror = _back ? config.fromRight : !config.fromRight;
      uv[i] = (mirror ? size.width - u : u) * ratio;
      uv[i + 1] = inkMesh.uv[i + 1] * ratio;
    }
    final ink = ui.Vertices.raw(
      ui.VertexMode.triangles,
      inkMesh.positions,
      textureCoordinates: uv,
      colors: colors(inkMesh, true),
      indices: inkMesh.indices,
    );
    canvas.drawVertices(
      ink,
      BlendMode.modulate,
      Paint()
        ..shader = (_texture ??= ui.ImageShader(
          image,
          TileMode.clamp,
          TileMode.clamp,
          Matrix4.identity().storage,
        ))
        ..filterQuality = FilterQuality.medium,
    );
    ink.dispose();
  }

  @override
  bool shouldRepaint(covariant ReaderPaperPainter oldDelegate) => true;
  @override
  void dispose() {
    _texture?.dispose();
    clock.removeListener(notifyListeners);
    super.dispose();
  }
}
