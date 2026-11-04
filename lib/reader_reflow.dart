import 'dart:ui' show lerpDouble;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'archive_motion.dart';
import 'reader_pagination.dart';
import 'reader_turn_motion.dart';

part 'reader_line_reflow.dart';

/// Reflow retains source identities. Changed vertical columns are replaced in
/// reading order while unchanged glyphs stay painted in place.
class ReaderReflowScope extends InheritedWidget {
  ReaderReflowScope({
    super.key,
    required this.animation,
    required this.previous,
    this.current,
    required this.size,
    required this.previousSize,
    required this.originDelta,
    required super.child,
  });
  final Animation<double> animation;
  final ReaderLeaf previous;
  final ReaderLeaf? current;
  late final _LineReflowPlan _linePlan = _LineReflowPlan(this);
  final Size size, previousSize;
  final Offset originDelta;
  double get progress =>
      Curves.easeOutCubic.transform(animation.value.clamp(0, 1));
  double delayFor(int index, int count, {bool reverse = false}) {
    final rank = reverse ? count - 1 - index : index;
    return count < 2 ? 0 : .2 * rank.clamp(0, count - 1) / (count - 1);
  }

  double progressFor(int index, int count, {bool reverse = false}) {
    final start = delayFor(index, count, reverse: reverse);
    return Interval(
      start,
      start + .8,
      curve: Curves.easeOutCubic,
    ).transform(animation.value.clamp(0, 1));
  }

  Offset displacementFor(int index, int count, {bool reverse = false}) =>
      originDelta * (progress - progressFor(index, count, reverse: reverse));
  int lineCount({bool departing = false}) =>
      (departing ? previous : current ?? previous).fragments.fold<int>(
        0,
        (count, fragment) => count + fragment.lineCount,
      );
  int lineIndex(ReaderPageFragment fragment, {bool departing = false}) {
    var rank = 0;
    for (final part in (departing ? previous : current ?? previous).fragments) {
      if (identical(part, fragment) ||
          part.paragraph == fragment.paragraph &&
              part.start == fragment.start) {
        return rank;
      }
      rank += part.lineCount;
    }
    return rank;
  }

  static ReaderReflowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReaderReflowScope>();
  @override
  bool updateShouldNotify(ReaderReflowScope oldWidget) =>
      animation != oldWidget.animation ||
      previous != oldWidget.previous ||
      current != oldWidget.current ||
      size != oldWidget.size ||
      previousSize != oldWidget.previousSize ||
      originDelta != oldWidget.originDelta;
}

/// Horizontal reflow owns individual shaped lines, while images and rules
/// remain atomic. Text and selection still use one intact paragraph renderer.
class ReaderFragmentMotion extends StatelessWidget {
  const ReaderFragmentMotion({
    super.key,
    required this.fragment,
    required this.index,
    required this.count,
    required this.child,
    this.previousBuilder,
  });
  final ReaderPageFragment fragment;
  final int index, count;
  final Widget child;
  final Widget Function(ReaderPageFragment)? previousBuilder;
  @override
  Widget build(BuildContext context) {
    final scope = ReaderReflowScope.maybeOf(context);
    if (scope == null) {
      return ReaderTurnPart(
        index: index,
        count: count,
        bounds: fragment.rect,
        child: child,
      );
    }
    if (fragment.lineMetrics != null) {
      final old = scope.previous.fragments
          .where((before) => before.paragraph == fragment.paragraph)
          .firstOrNull;
      return _ReaderLineMotion(
        scope: scope,
        fragment: fragment,
        previous: old,
        previousChild:
            old == null ||
                previousBuilder == null ||
                old.text == fragment.text && old.rect.size == fragment.rect.size
            ? null
            : previousBuilder!(old),
        child: child,
      );
    }
    final reverse = scope.originDelta.dy < 0;
    ReaderPageFragment? previous;
    for (final before in scope.previous.fragments) {
      if (before.paragraph == fragment.paragraph &&
          before.start == fragment.start) {
        previous = before;
        break;
      }
    }
    final old = previous;
    final previousChild =
        old != null &&
            previousBuilder != null &&
            (old.text != fragment.text || old.rect.size != fragment.rect.size)
        ? previousBuilder!(old)
        : null;
    final start = scope.delayFor(index, count, reverse: reverse);
    return AnimatedBuilder(
      animation: scope.animation,
      child: old != null
          ? child
          : ArchiveReveal(
              animation: scope.animation,
              start: start,
              end: start + .8,
              travel: const Offset(-8, 10),
              child: child,
            ),
      builder: (context, child) {
        final progress = scope.progressFor(index, count, reverse: reverse);
        final correction = old == null
            ? Offset.zero
            : (old.rect.topLeft - fragment.rect.topLeft) * (1 - progress);
        final content = previousChild == null
            ? child!
            : _FragmentReplacement(
                progress: progress,
                previous: previousChild,
                previousSize: old!.rect.size,
                size: fragment.rect.size,
                child: child!,
              );
        return Transform.translate(
          offset:
              scope.displacementFor(index, count, reverse: reverse) +
              correction,
          child: content,
        );
      },
    );
  }
}

/// Old and new ink occupy complementary clips on the same moving paragraph.
/// Publishing a taller fragment must not expose its extra lines immediately;
/// shrinking one must retain its old tail until that tail actually leaves.
class _FragmentReplacement extends StatelessWidget {
  const _FragmentReplacement({
    required this.progress,
    required this.previous,
    required this.previousSize,
    required this.size,
    required this.child,
  });
  final double progress;
  final Widget previous, child;
  final Size previousSize, size;
  @override
  Widget build(BuildContext context) {
    final height = previousSize.height > size.height
        ? previousSize.height
        : size.height;
    final seam = height * progress;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          top: 0,
          width: size.width,
          height: size.height,
          child: ClipRect(
            clipper: _ViewportClip(Rect.fromLTRB(0, 0, size.width, seam)),
            child: child,
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          width: previousSize.width,
          height: previousSize.height,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: SelectionContainer.disabled(
                child: ClipRect(
                  clipper: _ViewportClip(
                    Rect.fromLTRB(
                      0,
                      seam.clamp(0, previousSize.height),
                      previousSize.width,
                      previousSize.height,
                    ),
                  ),
                  child: previous,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Departing text leaves line by line on the same clock as retained text.
class ReaderLeavingFragment extends StatelessWidget {
  const ReaderLeavingFragment({
    super.key,
    required this.fragment,
    required this.index,
    required this.count,
    required this.child,
  });
  final ReaderPageFragment fragment;
  final int index, count;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final scope = ReaderReflowScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    if (fragment.lineMetrics != null) {
      return IgnorePointer(
        child: ExcludeSemantics(
          child: SelectionContainer.disabled(
            child: _ReaderLineMotion(
              scope: scope,
              fragment: fragment,
              leaving: true,
              child: child,
            ),
          ),
        ),
      );
    }
    final reverse = scope.originDelta.dy < 0;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: SelectionContainer.disabled(
          child: AnimatedBuilder(
            animation: scope.animation,
            child: child,
            builder: (context, child) => Transform.translate(
              offset: scope.displacementFor(index, count, reverse: reverse),
              child: ClipRect(
                clipper: _ViewportClip(
                  Rect.fromLTWH(
                    0,
                    0,
                    fragment.rect.width,
                    fragment.rect.height *
                        (1 - scope.progressFor(index, count, reverse: reverse)),
                  ),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paint-only viewport interpolation. Pagination always sees the final size,
/// so opening controls never shapes a chapter on every animation tick.
class ReaderIncrementalViewport extends StatelessWidget {
  const ReaderIncrementalViewport({
    super.key,
    required this.animation,
    required this.fromSize,
    required this.toSize,
    required this.originDelta,
    required this.child,
    this.horizontalOverflow = 0,
  });
  final Animation<double> animation;
  final Size fromSize, toSize;
  final Offset originDelta;
  final Widget child;
  final double horizontalOverflow;
  Rect viewportAt(double value) {
    final t = Curves.easeOutCubic.transform(value.clamp(0, 1));
    return Offset.lerp(originDelta, Offset.zero, t)! &
        Size(
          lerpDouble(fromSize.width, toSize.width, t)!,
          lerpDouble(fromSize.height, toSize.height, t)!,
        );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final viewport = viewportAt(animation.value);
      return ClipRect(
        clipper: _ViewportClip(
          Rect.fromLTRB(
            (viewport.left > 0 ? 0 : viewport.left) - horizontalOverflow,
            viewport.top > 0 ? 0 : viewport.top,
            viewport.right + horizontalOverflow,
            viewport.bottom,
          ),
        ),
        child: Transform.translate(offset: viewport.topLeft, child: child),
      );
    },
  );
}

class _ViewportClip extends CustomClipper<Rect> {
  const _ViewportClip(this.rect);
  final Rect rect;
  @override
  Rect getClip(Size size) => rect;
  @override
  bool shouldReclip(_ViewportClip oldClipper) => oldClipper.rect != rect;
}
