import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Page turns share the archive's finite, staggered arrival clock. A drag
/// scrubs this same clock; releasing it never replays an entrance animation.
class ReaderTurnScope extends InheritedWidget {
  static const duration = Duration(milliseconds: 620);
  const ReaderTurnScope({
    super.key,
    required this.animation,
    required this.direction,
    required super.child,
    this.outgoing = false,
    this.enabled = true,
    this.slot = 0,
    this.slots = 1,
    this.relay = false,
    this.vertical = false,
    this.leafSize = Size.zero,
    this.travelWidth,
  });

  final Animation<double> animation;
  final double direction;
  final bool outgoing, enabled;
  final int slot, slots;
  final bool relay, vertical;
  final Size leafSize;

  /// Motion crosses the complete sheet, including the resting text margins.
  /// Keep leafSize local to the ink for paragraph/column ordering.
  final double? travelWidth;

  double relayProgress(double rank) {
    final start = (slot + .02 + .18 * rank.clamp(0.0, 1.0)) / slots;
    return Interval(
      start,
      (start + .80 / slots).clamp(0.0, 1.0),
      curve: Curves.easeInOutSine,
    ).transform(animation.value.clamp(0.0, 1.0));
  }

  double progressFor(int index, int count, {Rect? bounds}) {
    if (!enabled) return 1;
    if (relay) {
      final order = count < 2 ? 0.0 : index / (count - 1);
      final double rank;
      if (vertical) {
        // Columns travel horizontally too. Treat both leaves as one continuous
        // strip: outgoing columns lead, incoming columns follow. The wave runs
        // right-to-left going forward and reverses with a backward swipe, so
        // moving columns never catch stationary neighbours or the other leaf.
        final column = bounds == null
            ? (direction < 0 ? order : 1 - order)
            : direction < 0
            ? 1 - (outgoing ? bounds.right : bounds.left) / leafSize.width
            : (outgoing ? bounds.left : bounds.right) / leafSize.width;
        rank = (outgoing ? 0 : .5) + .5 * column.clamp(0.0, 1.0);
      } else {
        // At every shared row the old paragraph leads the new one. Use spatial
        // bounds, not paragraph counts, to keep unequal paragraphs separate.
        rank = bounds == null
            ? order
            : (outgoing ? bounds.top : bounds.bottom) / leafSize.height;
      }
      return relayProgress(rank);
    }
    if (outgoing) {
      return const Interval(
        0,
        .06,
        curve: Curves.easeInCubic,
      ).transform(animation.value.clamp(0.0, 1.0));
    }
    // Bound the stagger even on a page of many short dialogue paragraphs.
    final rank = count < 2 ? 0.0 : index / (count - 1);
    // Slots are in reading order: left then right for horizontal text, right
    // then left for tategaki. Finish a leaf before starting the next one.
    final start = (slot + .06 + .56 * rank) / slots;
    return Interval(
      start,
      start + .38 / slots,
      curve: Curves.easeOutCubic,
    ).transform(animation.value.clamp(0.0, 1.0));
  }

  Offset displacementFor(int index, int count, {Rect? bounds}) {
    if (!enabled) return Offset.zero;
    final t = progressFor(index, count, bounds: bounds);
    if (relay) {
      // Translate complete paragraphs/columns, rather than wiping a diagonal
      // through stationary glyphs. Both layers keep their original opacity.
      final distance = outgoing ? -t : 1 - t;
      return Offset((travelWidth ?? leafSize.width) * direction * distance, 0);
    }
    return outgoing
        ? Offset(-16 * direction, -4) * t
        : Offset(36 * direction, 8) * (1 - t);
  }

  double opacityFor(int index, int count) {
    // Page turns move intact ink, not two fading text planes.
    // Initial loading and mode changes keep their existing arrival behavior.
    if (relay) return 1;
    final t = progressFor(index, count);
    return outgoing
        ? 1 - t
        : const Interval(0, .35, curve: Curves.easeOutCubic).transform(t);
  }

  static ReaderTurnScope? maybeOf(BuildContext context) {
    final nearest = context
        .dependOnInheritedWidgetOfExactType<ReaderTurnScope>();
    if (nearest == null || nearest.enabled) return nearest;
    ReaderTurnScope? active;
    // A stable idle slot must not hide a surrounding mode-change animation.
    context.visitAncestorElements((element) {
      if (element is InheritedElement && element.widget is ReaderTurnScope) {
        final scope = element.widget as ReaderTurnScope;
        context.dependOnInheritedElement(element);
        if (scope.enabled) {
          active = scope;
          return false;
        }
      }
      return true;
    });
    return active;
  }

  static const idle = ReaderTurnScope(
    animation: AlwaysStoppedAnimation(1),
    direction: 1,
    enabled: false,
    child: SizedBox(),
  );

  @override
  bool updateShouldNotify(ReaderTurnScope oldWidget) =>
      animation != oldWidget.animation ||
      direction != oldWidget.direction ||
      outgoing != oldWidget.outgoing ||
      enabled != oldWidget.enabled ||
      relay != oldWidget.relay ||
      vertical != oldWidget.vertical ||
      leafSize != oldWidget.leafSize ||
      travelWidth != oldWidget.travelWidth ||
      slot != oldWidget.slot ||
      slots != oldWidget.slots;
}

/// Translates retained paragraph layers, without a page-sized mask, repainting
/// text, or asking pagination to lay out again on animation ticks.
class ReaderTurnPart extends StatelessWidget {
  const ReaderTurnPart({
    super.key,
    this.index = 0,
    this.count = 1,
    this.bounds,
    this.motion,
    required this.child,
  });
  final int index, count;
  final Rect? bounds;
  final ReaderTurnScope? motion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = motion ?? ReaderTurnScope.maybeOf(context);
    return _TurnPart(
      scope: scope ?? ReaderTurnScope.idle,
      index: index,
      count: count,
      bounds: bounds,
      child: child,
    );
  }
}

/// The skeleton recedes in the same paragraph/column order as the text, without
/// a second page-wide reveal masking the right leaf or tategaki columns.
class ReaderTurnPlaceholder extends StatelessWidget {
  const ReaderTurnPlaceholder({
    super.key,
    required this.divisions,
    required this.vertical,
    required this.child,
  });
  final List<double> divisions;
  final bool vertical;
  final Widget child;
  @override
  Widget build(BuildContext context) => _TurnPlaceholder(
    scope: ReaderTurnScope.maybeOf(context) ?? ReaderTurnScope.idle,
    divisions: divisions,
    vertical: vertical,
    child: RepaintBoundary(child: child),
  );
}

class _TurnPlaceholder extends SingleChildRenderObjectWidget {
  const _TurnPlaceholder({
    required this.scope,
    required this.divisions,
    required this.vertical,
    required super.child,
  });
  final ReaderTurnScope scope;
  final List<double> divisions;
  final bool vertical;
  @override
  _TurnPlaceholderRender createRenderObject(BuildContext context) =>
      _TurnPlaceholderRender(scope, divisions, vertical);
  @override
  void updateRenderObject(
    BuildContext context,
    _TurnPlaceholderRender render,
  ) => render.update(scope, divisions, vertical);
}

class _TurnPlaceholderRender extends RenderProxyBox {
  _TurnPlaceholderRender(this.scope, this.divisions, this.vertical);
  ReaderTurnScope scope;
  List<double> divisions;
  bool vertical;
  final _clip = LayerHandle<ClipPathLayer>();
  void update(ReaderTurnScope next, List<double> bands, bool columns) {
    if (attached && next.animation != scope.animation) {
      scope.animation.removeListener(markNeedsPaint);
      next.animation.addListener(markNeedsPaint);
    }
    scope = next;
    divisions = bands;
    vertical = columns;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    scope.animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    scope.animation.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    final path = Path();
    final count = divisions.isEmpty ? 1 : divisions.length;
    final extent = vertical ? size.width : size.height;
    for (var i = 0; i < count; i++) {
      final alpha = scope.opacityFor(i, count);
      if (alpha == 1) continue;
      final from = i == 0 ? 0.0 : divisions[i].clamp(0.0, extent);
      final to = i + 1 == count ? extent : divisions[i + 1].clamp(from, extent);
      final edge = from + (to - from) * alpha;
      path.addRect(
        vertical
            ? Rect.fromLTRB(size.width - to, 0, size.width - edge, size.height)
            : Rect.fromLTRB(0, edge, size.width, to),
      );
    }
    if (path.getBounds().isEmpty) return;
    _clip.layer = context.pushClipPath(
      needsCompositing,
      offset,
      Offset.zero & size,
      path,
      super.paint,
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}

class _TurnPart extends SingleChildRenderObjectWidget {
  _TurnPart({
    required this.scope,
    required this.index,
    required this.count,
    this.bounds,
    required Widget child,
  }) : super(child: RepaintBoundary(child: child));
  final ReaderTurnScope scope;
  final int index, count;
  final Rect? bounds;

  @override
  ReaderTurnPartRender createRenderObject(BuildContext context) =>
      ReaderTurnPartRender(scope, index, count, bounds);

  @override
  void updateRenderObject(BuildContext context, ReaderTurnPartRender render) =>
      render.update(scope, index, count, bounds);
}

class ReaderTurnPartRender extends RenderProxyBox {
  ReaderTurnPartRender(this.scope, this.index, this.count, this.bounds);
  ReaderTurnScope scope;
  int index, count;
  Rect? bounds;
  final _translation = LayerHandle<TransformLayer>();
  final _opacity = LayerHandle<OpacityLayer>();
  int debugLayoutCount = 0;
  double get progress => scope.progressFor(index, count, bounds: bounds);
  Offset get displacement =>
      scope.displacementFor(index, count, bounds: bounds);
  int get alpha => (scope.opacityFor(index, count) * 255).round();
  @override
  bool get alwaysNeedsCompositing => child != null;
  Matrix4 get _transform =>
      Matrix4.translationValues(displacement.dx, displacement.dy, 0);

  void _tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  void update(
    ReaderTurnScope next,
    int nextIndex,
    int nextCount,
    Rect? nextBounds,
  ) {
    if (attached && next.animation != scope.animation) {
      scope.animation.removeListener(_tick);
      next.animation.addListener(_tick);
    }
    scope = next;
    index = nextIndex;
    count = nextCount;
    bounds = nextBounds;
    _tick();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    scope.animation.addListener(_tick);
  }

  @override
  void detach() {
    scope.animation.removeListener(_tick);
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    assert(() {
      debugLayoutCount++;
      return true;
    }());
  }

  @override
  Rect get paintBounds => (Offset.zero & size).expandToInclude(
    (Offset.zero & size).shift(displacement),
  );

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || alpha == 0) return;
    if (alpha == 255 && displacement == Offset.zero) {
      _translation.layer = null;
      _opacity.layer = null;
      super.paint(context, offset);
      return;
    }
    _translation.layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (context, offset) {
        if (alpha == 255) {
          _opacity.layer = null;
          super.paint(context, offset);
          return;
        }
        _opacity.layer = context.pushOpacity(
          offset,
          alpha,
          super.paint,
          oldLayer: _opacity.layer,
        );
      },
      oldLayer: _translation.layer,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_transform);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      !scope.outgoing &&
      alpha > 12 &&
      result.addWithPaintTransform(
        transform: _transform,
        position: position,
        hitTest: (result, position) =>
            super.hitTest(result, position: position),
      );

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (!scope.outgoing && alpha > 12) super.visitChildrenForSemantics(visitor);
  }

  @override
  void dispose() {
    _translation.layer = null;
    _opacity.layer = null;
    super.dispose();
  }
}
