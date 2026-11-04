import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// One pagination width for both leaves, including off-centre hardware hinges.
/// Rectangles are viewport-local; reading order is applied by ReaderBookSpread.
class ReaderBookLayout {
  const ReaderBookLayout._(this.viewport, this.pages, this.spine);
  final Size viewport;
  final List<Rect> pages;
  final Rect? spine;
  int get count => pages.length;
  Size get pageSize => pages.first.size;
  Object get key => (viewport, pages.first, pages.last, count, spine);

  /// Paper reaches the screen edges while pagination keeps its text rectangle.
  Rect frameFor(int index, EdgeInsets insets) {
    final body = pages[index].shift(Offset(insets.left, insets.top));
    return Rect.fromLTRB(
      index == 0 ? 0 : body.left,
      0,
      index == count - 1 ? viewport.width + insets.horizontal : body.right,
      viewport.height + insets.vertical,
    );
  }

  factory ReaderBookLayout.resolve({
    required Size viewport,
    required double margin,
    List<DisplayFeature> features = const [],
    Offset origin = Offset.zero,
  }) {
    var area = Offset.zero & viewport;
    Rect? hinge;
    for (final feature in features) {
      if (feature.type != DisplayFeatureType.hinge &&
          feature.type != DisplayFeatureType.fold) {
        continue;
      }
      final bounds = feature.bounds.shift(-origin);
      final vertical = bounds.height > bounds.width;
      // A fully opened flexible display has a crease, not two separate panes.
      // Treating its zero-width fold as a hinge made compact inner screens fall
      // below the two-page threshold and render only the left half of the book.
      final occludes = vertical ? bounds.width > 0 : bounds.height > 0;
      if (feature.type == DisplayFeatureType.fold &&
          !occludes &&
          feature.state != DisplayFeatureState.postureHalfOpened) {
        continue;
      }
      if (vertical &&
          bounds.left > area.left &&
          bounds.right < area.right &&
          bounds.bottom > area.top &&
          bounds.top < area.bottom) {
        hinge = bounds;
      } else if (!vertical &&
          bounds.width > area.width / 2 &&
          bounds.top > area.top &&
          bounds.bottom < area.bottom &&
          (bounds.height > 0 ||
              feature.state == DisplayFeatureState.postureHalfOpened)) {
        // A tabletop fold uses the larger unobstructed pane, never text across
        // the physical hinge. Flat, zero-width crease metadata costs no space.
        area = bounds.top - area.top >= area.bottom - bounds.bottom
            ? Rect.fromLTRB(area.left, area.top, area.right, bounds.top - 12)
            : Rect.fromLTRB(
                area.left,
                bounds.bottom + 12,
                area.right,
                area.bottom,
              );
      }
    }
    final gutter = math.max(40.0, margin * 2);
    final leftEnd = hinge == null
        ? area.center.dx - gutter / 2
        : hinge.left - margin;
    final rightStart = hinge == null
        ? area.center.dx + gutter / 2
        : hinge.right + margin;
    final width = math.min(leftEnd - area.left, area.right - rightStart);
    if (area.width + margin * 2 >= 720 && area.height >= 220 && width >= 300) {
      return ReaderBookLayout._(
        viewport,
        [
          Rect.fromLTWH(leftEnd - width, area.top, width, area.height),
          Rect.fromLTWH(rightStart, area.top, width, area.height),
        ],
        hinge == null
            ? Rect.fromLTWH(area.center.dx - 12, area.top, 24, area.height)
            : null,
      );
    }
    if (hinge != null) {
      area = leftEnd - area.left >= area.right - rightStart
          ? Rect.fromLTRB(area.left, area.top, leftEnd, area.bottom)
          : Rect.fromLTRB(rightStart, area.top, area.right, area.bottom);
    }
    return ReaderBookLayout._(viewport, [area], null);
  }
}

class ReaderBookSpread extends StatelessWidget {
  const ReaderBookSpread({
    super.key,
    required this.layout,
    required this.pages,
    this.rightToLeft = false,
    this.edgeOverflow = 0,
    this.verticalOverflow = 0,
    this.clipLeaves = true,
    this.frameInsets,
  });
  final ReaderBookLayout layout;
  final List<Widget> pages;
  final bool rightToLeft;
  final double edgeOverflow;
  final double verticalOverflow;
  final bool clipLeaves;
  final EdgeInsets? frameInsets;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      if (layout.spine case final spine?)
        Positioned.fromRect(
          rect: frameInsets == null
              ? spine
              : Rect.fromLTWH(
                  spine.left + frameInsets!.left,
                  0,
                  spine.width,
                  layout.viewport.height + frameInsets!.vertical,
                ),
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: .045),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
      for (var index = 0; index < pages.length; index++)
        Positioned.fromRect(
          rect: frameInsets == null
              ? layout.pages[rightToLeft ? layout.count - 1 - index : index]
              : layout.frameFor(
                  rightToLeft ? layout.count - 1 - index : index,
                  frameInsets!,
                ),
          child: Semantics(
            sortKey: OrdinalSortKey(index.toDouble()),
            child: ClipRect(
              clipBehavior: clipLeaves ? Clip.hardEdge : Clip.none,
              clipper: edgeOverflow == 0 && verticalOverflow == 0
                  ? null
                  : _BookTurnClip(
                      vertical: verticalOverflow,
                      left:
                          (rightToLeft ? layout.count - 1 - index : index) == 0
                          ? edgeOverflow
                          : 0,
                      right:
                          (rightToLeft ? layout.count - 1 - index : index) ==
                              layout.count - 1
                          ? edgeOverflow
                          : 0,
                    ),
              child: pages[index],
            ),
          ),
        ),
    ],
  );
}

class _BookTurnClip extends CustomClipper<Rect> {
  const _BookTurnClip({
    required this.left,
    required this.right,
    this.vertical = 0,
  });
  final double left, right, vertical;
  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    -left,
    -vertical,
    size.width + right,
    size.height + vertical,
  );
  @override
  bool shouldReclip(_BookTurnClip oldClipper) =>
      left != oldClipper.left ||
      right != oldClipper.right ||
      vertical != oldClipper.vertical;
}
