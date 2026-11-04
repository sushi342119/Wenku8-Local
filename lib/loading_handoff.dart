import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The arriving content owns layout. Its static skeleton remains below the
/// unrevealed portion, so a delayed cut-in never exposes an empty page.
class LoadingHandoff extends StatefulWidget {
  const LoadingHandoff({
    super.key,
    required this.animation,
    required this.placeholder,
    required this.child,
    this.start = 0,
    this.end = 1,
    this.axis = Axis.vertical,
    this.travel = Offset.zero,
    this.crossfade = false,
  });
  final Animation<double> animation;
  final Widget placeholder, child;
  final double start, end;
  final Axis axis;
  final Offset travel;

  /// Replace ink in place when the placeholder already has the final geometry.
  final bool crossfade;

  @override
  State<LoadingHandoff> createState() => _LoadingHandoffState();
}

class _LoadingHandoffState extends State<LoadingHandoff> {
  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_status);
  }

  void _status(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.forward) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(LoadingHandoff oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_status);
      widget.animation.addStatusListener(_status);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_status);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    final opacity = widget.animation.drive(
      CurveTween(
        curve: Interval(widget.start, widget.end, curve: Curves.easeOutCubic),
      ),
    );
    return Stack(
      fit: StackFit.passthrough,
      children: [
        if (widget.animation.value < widget.end &&
            !MediaQuery.disableAnimationsOf(context))
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: widget.crossfade
                    ? FadeTransition(
                        opacity: ReverseAnimation(opacity),
                        child: RepaintBoundary(child: widget.placeholder),
                      )
                    : _SkeletonRemainder(
                        animation: widget.animation,
                        start: widget.start,
                        end: widget.end,
                        axis: widget.axis,
                        travel: widget.travel,
                        child: RepaintBoundary(child: widget.placeholder),
                      ),
              ),
            ),
          ),
        widget.crossfade
            ? FadeTransition(opacity: opacity, child: widget.child)
            : widget.child,
      ],
    );
  }
}

class _SkeletonRemainder extends SingleChildRenderObjectWidget {
  const _SkeletonRemainder({
    required this.animation,
    required this.start,
    required this.end,
    required this.axis,
    required this.travel,
    required super.child,
  });
  final Animation<double> animation;
  final double start, end;
  final Axis axis;
  final Offset travel;
  @override
  _SkeletonRemainderRender createRenderObject(BuildContext context) =>
      _SkeletonRemainderRender(animation, start, end, axis, travel);
  @override
  void updateRenderObject(
    BuildContext context,
    _SkeletonRemainderRender render,
  ) => render.update(animation, start, end, axis, travel);
}

class _SkeletonRemainderRender extends RenderProxyBox {
  _SkeletonRemainderRender(
    this.animation,
    this.start,
    this.end,
    this.axis,
    this.travel,
  );
  Animation<double> animation;
  double start, end;
  Axis axis;
  Offset travel;
  final _clip = LayerHandle<ClipPathLayer>();
  void _tick() => markNeedsPaint();
  void update(
    Animation<double> value,
    double from,
    double to,
    Axis direction,
    Offset displacement,
  ) {
    if (animation != value) {
      if (attached) animation.removeListener(_tick);
      animation = value;
      if (attached) animation.addListener(_tick);
    }
    start = from;
    end = to;
    axis = direction;
    travel = displacement;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    animation.addListener(_tick);
  }

  @override
  void detach() {
    animation.removeListener(_tick);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final progress = Interval(
      start,
      end,
      curve: Curves.easeOutCubic,
    ).transform(animation.value.clamp(0.0, 1.0));
    if (progress == 1 || child == null || size.isEmpty) return;
    if (progress == 0) {
      super.paint(context, offset);
      return;
    }
    final bounds = Offset.zero & size;
    final revealed = Rect.fromLTWH(
      0,
      0,
      size.width * (axis == Axis.horizontal ? progress : 1),
      size.height * (axis == Axis.vertical ? progress : 1),
    ).shift(travel * (1 - progress)).intersect(bounds);
    final remainder = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(bounds)
      ..addRect(revealed);
    _clip.layer = context.pushClipPath(
      needsCompositing,
      offset,
      bounds,
      remainder,
      super.paint,
      clipBehavior: Clip.hardEdge,
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}
