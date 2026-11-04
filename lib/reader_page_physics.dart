import 'dart:math' as math;
import 'package:flutter/widgets.dart';

/// A short deliberate stroke commits one page; a small adjustment returns to
/// its origin. Distance is bounded in logical pixels, not half a tablet screen.
class ReaderPagePhysics extends PageScrollPhysics {
  const ReaderPagePhysics({
    required this.origin,
    double durationScale = 1,
    this.liveDurationScale,
    this.pageBounds,
    this.onUserPageCommitted,
    super.parent,
  }) : _durationScale = durationScale;
  final int? Function() origin;
  final double _durationScale;
  // Scrollable retains physics when its runtime type does not change. Read a
  // live setting at gesture release instead of replacing its scroll position.
  final double Function()? liveDurationScale;

  /// Ready adjacent chapters extend the same page rail. Unprepared edges stay
  /// clamped so a slow request cannot expose an empty neighbouring sheet.
  final ({int first, int last}) Function()? pageBounds;

  /// A released gesture has selected another page, before its snap animation.
  /// A scroll position may recalculate ballistics; the owner deduplicates the
  /// accepted gesture rather than queuing feedback until ScrollEnd.
  final ValueChanged<int>? onUserPageCommitted;
  double get durationScale => liveDurationScale?.call() ?? _durationScale;
  static double commitDistance(double viewport) =>
      (viewport * .1).clamp(28, 48);

  @override
  ReaderPagePhysics applyTo(ScrollPhysics? ancestor) => ReaderPagePhysics(
    origin: origin,
    durationScale: _durationScale,
    liveDurationScale: liveDurationScale,
    pageBounds: pageBounds,
    onUserPageCommitted: onUserPageCommitted,
    parent: buildParent(ancestor),
  );

  ScrollMetrics _bounded(ScrollMetrics position) {
    final bounds = pageBounds?.call();
    if (bounds == null || position is! PageMetrics) return position;
    final width = position.viewportDimension * position.viewportFraction;
    return position.copyWith(
      minScrollExtent: bounds.first * width,
      maxScrollExtent: bounds.last * width,
    );
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) =>
      super.applyBoundaryConditions(_bounded(position), value);

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    position = _bounded(position);
    if (position is! PageMetrics ||
        position.pixels < position.minScrollExtent ||
        position.pixels > position.maxScrollExtent) {
      return super.createBallisticSimulation(position, velocity);
    }
    final outwardBoundary =
        position.pixels <= position.minScrollExtent && velocity <= 0 ||
        position.pixels >= position.maxScrollExtent && velocity >= 0;
    final gestureOrigin = origin();
    if (gestureOrigin == null) {
      return super.createBallisticSimulation(position, velocity);
    }
    final page = position.page ?? 0;
    final start = gestureOrigin.toDouble();
    final width = position.viewportDimension * position.viewportFraction;
    final distance = (page - start) * width;
    final reversing = velocity.abs() >= 360 && velocity.sign != distance.sign;
    final fast = !reversing && velocity.abs() >= 360 && distance.abs() >= 8;
    final commit =
        !reversing && (distance.abs() >= commitDistance(width) || fast);
    final direction = distance.sign;
    final destination = (commit ? start + direction : start).clamp(
      position.minScrollExtent / width,
      position.maxScrollExtent / width,
    );
    final pixels = destination * width;
    if (commit && destination != start) {
      onUserPageCommitted?.call(destination.round());
    }
    // Reaching the first/last page can finish the whole turn under the finger.
    // Acknowledge that accepted destination before preserving the parent's
    // existing outward-edge behavior; starting at that edge is still silent.
    if (outwardBoundary) {
      return super.createBallisticSimulation(position, velocity);
    }
    final durationScale = this.durationScale;
    final tolerance = toleranceFor(position);
    if ((pixels - position.pixels).abs() < tolerance.distance) return null;
    return _ReaderPageSnap(
      ScrollSpringSimulation(
        spring,
        position.pixels,
        pixels,
        math.max(-2400.0, math.min(2400.0, velocity)) * durationScale,
        tolerance: tolerance,
      ),
      from: position.pixels,
      to: pixels,
      durationScale: durationScale,
    );
  }
}

/// A fast release near the landing must not overshoot into the following page
/// and momentarily expose its text or illustration before bouncing back.
class _ReaderPageSnap extends Simulation {
  _ReaderPageSnap(
    this.spring, {
    required this.from,
    required this.to,
    required this.durationScale,
  }) : super(tolerance: spring.tolerance);
  final ScrollSpringSimulation spring;
  final double from, to;
  final double durationScale;
  @override
  bool isDone(double time) =>
      spring.isDone(time / durationScale) ||
      (to > from
          ? spring.x(time / durationScale) >= to
          : spring.x(time / durationScale) <= to);
  @override
  double x(double time) => isDone(time) ? to : spring.x(time / durationScale);
  @override
  double dx(double time) =>
      isDone(time) ? 0 : spring.dx(time / durationScale) / durationScale;
}
