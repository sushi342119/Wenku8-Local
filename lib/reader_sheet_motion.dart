import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'reader_preferences.dart';

/// Retains the live leaf once. A fold is two complementary clips and a paper
/// crease, not two fading text planes or a screenshot captured on every frame.
class ReaderSheetMotion extends SingleChildRenderObjectWidget {
  ReaderSheetMotion({
    super.key,
    required this.animation,
    required this.effect,
    required this.direction,
    required this.incoming,
    required this.front,
    required this.active,
    required this.paper,
    required Widget child,
  }) : super(child: RepaintBoundary(child: child));
  final Animation<double> animation;
  final ReaderPageEffect effect;
  final double direction;
  final bool incoming, front, active;
  final Color paper;
  @override
  ReaderSheetMotionRender createRenderObject(BuildContext context) =>
      ReaderSheetMotionRender(this);
  @override
  void updateRenderObject(
    BuildContext context,
    ReaderSheetMotionRender renderObject,
  ) => renderObject.update(this);
}

class ReaderSheetMotionRender extends RenderProxyBox {
  ReaderSheetMotionRender(this.config);
  ReaderSheetMotion config;
  final _clip = LayerHandle<ClipPathLayer>();
  final _move = LayerHandle<TransformLayer>();
  final _opacity = LayerHandle<OpacityLayer>();
  int debugLayoutCount = 0;
  double get progress => config.animation.value.clamp(0.0, 1.0);
  double get opacity =>
      config.active && config.effect == ReaderPageEffect.fade && config.front
      ? (config.incoming ? progress : 1 - progress)
      : 1;
  double get _sign => config.direction < 0 ? -1 : 1;
  double get _envelope => math.sin(progress * math.pi);
  double get _edge => size.width * (_sign > 0 ? 1 - progress : progress);
  double get _bend => config.effect == ReaderPageEffect.paper
      ? _sign * math.min(24.0, size.width * .045) * _envelope
      : 0;
  double get _fold => config.effect == ReaderPageEffect.paper
      ? _sign * math.min(28.0, size.width * .065) * _envelope
      : 0;
  Offset get displacement =>
      config.active && config.effect == ReaderPageEffect.cover && config.front
      ? Offset(
          _sign * size.width * (config.incoming ? 1 - progress : -progress),
          0,
        )
      : Offset.zero;
  Matrix4 get _transform => Matrix4.translationValues(displacement.dx, 0, 0);

  Path _side(bool left, double shift) {
    final x = _edge + shift, height = size.height;
    final path = Path()
      ..moveTo(left ? 0 : size.width, 0)
      ..lineTo(x, 0)
      ..cubicTo(x + _bend, height * .25, x + _bend, height * .75, x, height)
      ..lineTo(left ? 0 : size.width, height)
      ..close();
    return path;
  }

  Path get visiblePath => config.effect == ReaderPageEffect.fade
      ? (Path()..addRect(Offset.zero & size))
      : config.effect == ReaderPageEffect.cover
      ? (Path()..addRect(
          (Offset.zero & size)
              .shift(displacement)
              .intersect(Offset.zero & size),
        ))
      : _side(
          config.incoming ? _sign < 0 : _sign > 0,
          config.incoming ? _fold : 0,
        );
  void _tick() {
    markNeedsPaint();
    if (config.effect == ReaderPageEffect.cover ||
        config.effect == ReaderPageEffect.fade) {
      markNeedsSemanticsUpdate();
    }
  }

  void update(ReaderSheetMotion next) {
    if (attached && next.animation != config.animation) {
      config.animation.removeListener(_tick);
      next.animation.addListener(_tick);
    }
    config = next;
    _tick();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    config.animation.addListener(_tick);
  }

  @override
  void detach() {
    config.animation.removeListener(_tick);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;
  @override
  void performLayout() {
    super.performLayout();
    assert(() {
      debugLayoutCount++;
      return true;
    }());
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    if (!config.active) {
      super.paint(context, offset);
      return;
    }
    if (config.effect == ReaderPageEffect.cover) {
      _paintCover(context, offset);
      return;
    }
    if (config.effect == ReaderPageEffect.fade) {
      final alpha = (opacity * 255).round();
      if (alpha == 0) return;
      void paintLeaf(PaintingContext context, Offset offset) {
        context.canvas.drawRect(offset & size, Paint()..color = config.paper);
        super.paint(context, offset);
      }

      if (alpha == 255) {
        paintLeaf(context, offset);
      } else {
        _opacity.layer = context.pushOpacity(
          offset,
          alpha,
          paintLeaf,
          oldLayer: _opacity.layer,
        );
      }
      return;
    }
    final t = progress;
    if (t <= 0 && config.incoming || t >= 1 && !config.incoming) return;
    if (t <= 0 || t >= 1) {
      super.paint(context, offset);
      return;
    }
    _clip.layer = context.pushClipPath(
      needsCompositing,
      offset,
      Offset.zero & size,
      visiblePath,
      (context, offset) {
        if (displacement == Offset.zero) {
          super.paint(context, offset);
        } else {
          _move.layer = context.pushTransform(
            needsCompositing,
            offset,
            _transform,
            super.paint,
            oldLayer: _move.layer,
          );
        }
      },
      oldLayer: _clip.layer,
    );
    if (!config.front) return;
    final canvas = context.canvas;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.clipRect(Offset.zero & size);
    final spread = math.min(26.0, size.width * .07) * _envelope;
    final shadow = Rect.fromLTWH(
      _edge + math.min(0, _fold) - spread,
      0,
      _fold.abs() + spread * 2,
      size.height,
    );
    final dark = config.paper.computeLuminance() < .15;
    canvas.drawRect(
      shadow,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: (dark ? .3 : .2) * _envelope),
            Colors.transparent,
          ],
          stops: const [0, .5, 1],
        ).createShader(shadow),
    );
    if (_fold.abs() > .01) {
      final x = _edge, end = _edge + _fold, h = size.height;
      final fold = Path()
        ..moveTo(x, 0)
        ..cubicTo(x + _bend, h * .25, x + _bend, h * .75, x, h)
        ..lineTo(end, h)
        ..cubicTo(end + _bend, h * .75, end + _bend, h * .25, end, 0)
        ..close();
      final rect = fold.getBounds();
      final colors = [
        Color.lerp(config.paper, Colors.black, dark ? .08 : .15)!,
        Color.lerp(config.paper, Colors.white, dark ? .14 : .3)!,
        config.paper,
      ];
      canvas.drawPath(
        fold,
        Paint()
          ..shader = LinearGradient(
            colors: _sign > 0 ? colors : colors.reversed.toList(),
            stops: const [0, .48, 1],
          ).createShader(rect),
      );
    }
    canvas.restore();
  }

  // Cover is one solid sheet sliding over a stationary leaf, not a paper
  // crease. Cast a shadow only onto the exposed lower leaf, never over ink on
  // both sides of a synthetic centre seam.
  void _paintCover(PaintingContext context, Offset offset) {
    if (config.front && _envelope > .001) {
      final movesFromRight = config.incoming ? _sign > 0 : _sign < 0;
      final edge = displacement.dx + (movesFromRight ? 0 : size.width);
      final width = math.min(22.0, size.width * .055) * _envelope;
      final rect = Rect.fromLTWH(
        movesFromRight ? edge - width : edge,
        0,
        width,
        size.height,
      );
      final canvas = context.canvas;
      canvas.save();
      canvas.translate(offset.dx, offset.dy);
      canvas.clipRect(Offset.zero & size);
      final ink = Colors.black.withValues(alpha: .16 * _envelope);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            colors: movesFromRight
                ? [Colors.transparent, ink]
                : [ink, Colors.transparent],
          ).createShader(rect),
      );
      canvas.restore();
    }
    _move.layer = context.pushTransform(needsCompositing, offset, _transform, (
      context,
      offset,
    ) {
      context.canvas.drawRect(offset & size, Paint()..color = config.paper);
      super.paint(context, offset);
    }, oldLayer: _move.layer);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_transform);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      opacity > 0 &&
      (!config.active || visiblePath.contains(position)) &&
      result.addWithPaintTransform(
        transform: _transform,
        position: position,
        hitTest: (result, position) =>
            super.hitTestChildren(result, position: position),
      );
  @override
  void dispose() {
    _clip.layer = null;
    _move.layer = null;
    _opacity.layer = null;
    super.dispose();
  }
}

class ReaderPageMarginClipper extends CustomClipper<Rect> {
  const ReaderPageMarginClipper(this.insets, {this.verticalOverflow = 0});
  final EdgeInsets insets;
  final double verticalOverflow;
  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    insets.left,
    -verticalOverflow,
    size.width - insets.right,
    size.height + verticalOverflow,
  );
  @override
  bool shouldReclip(ReaderPageMarginClipper oldClipper) =>
      oldClipper.insets != insets ||
      oldClipper.verticalOverflow != verticalOverflow;
}
