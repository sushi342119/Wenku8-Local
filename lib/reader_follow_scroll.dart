import 'package:flutter/widgets.dart';

import 'reader_content.dart';

/// Owns only explicitly requested reader motion. Uses Scrollable's native
/// driven activity, not a per-frame setState, position listener or text relayout.
class ReaderFollowScroll {
  ReaderFollowScroll(this.controller);
  final ScrollController controller;
  static const curve = Curves.easeInOutCubic;
  int _ticket = 0;
  bool _disposed = false, _driving = false;
  ScrollPosition? _position;

  static Duration durationFor(double distance, double viewport) {
    if (distance.abs() < 12) return const Duration(milliseconds: 180);
    final screens = distance.abs() / viewport.clamp(1.0, double.infinity);
    return Duration(
      milliseconds: (380 + screens * 140).round().clamp(380, 660),
    );
  }

  void cancel({bool userDrag = false}) {
    _ticket++;
    final position = _position;
    final driving = _driving;
    _driving = false;
    _position = null;
    // A user drag has already replaced our activity. Never hold/cancel that
    // new drag or its inertia when the reader suspends automatic following.
    if (!userDrag &&
        driving &&
        position != null &&
        controller.positions.contains(position)) {
      position.hold(() {}).cancel();
    }
  }

  Future<void> reveal({
    required ParagraphTarget? Function() target,
    required bool Function() allowed,
    required bool reduceMotion,
  }) async {
    cancel();
    final ticket = _ticket;
    bool valid() => !_disposed && ticket == _ticket && allowed();
    // Lazy rows are approached with an animated estimate and then refined
    // after layout. Offscreen text is never eagerly laid out to find a target.
    for (var pass = 0; pass < 12 && valid(); pass++) {
      final anchor = controller.hasClients ? target() : null;
      if (anchor == null || !anchor.offset.isFinite) {
        await _nextLayout();
        continue;
      }
      if (!valid() || !controller.hasClients) return;
      final position = controller.position;
      final offset = anchor.offset.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      final distance = offset - position.pixels;
      if (distance.abs() < 1) {
        if (anchor.exact) return;
        await _nextLayout();
        continue;
      }
      if (reduceMotion) {
        position.jumpTo(offset);
      } else {
        _driving = true;
        _position = position;
        try {
          await position.animateTo(
            offset,
            duration: durationFor(distance, position.viewportDimension),
            curve: curve,
          );
          // animateTo also completes when a touch/hold interrupts it. Do not
          // restart a refinement underneath that finger. A changed lazy extent
          // is different: the next pass still needs to refine its estimate.
          if (valid() && (position.pixels - offset).abs() > 2) {
            final clippedByNewExtent =
                (offset > position.maxScrollExtent &&
                    position.pixels >= position.maxScrollExtent - 1) ||
                (offset < position.minScrollExtent &&
                    position.pixels <= position.minScrollExtent + 1);
            if (!clippedByNewExtent) return;
          }
        } finally {
          if (ticket == _ticket) {
            _driving = false;
            _position = null;
          }
        }
      }
      if (!valid()) return;
      await _nextLayout();
    }
  }

  void dispose() {
    cancel();
    _disposed = true;
  }

  Future<void> _nextLayout() {
    final frame = WidgetsBinding.instance.endOfFrame;
    // endOfFrame called from a post-frame callback also needs a fresh frame.
    // This is bounded to this reveal, never a persistent render loop.
    WidgetsBinding.instance.ensureVisualUpdate();
    return frame;
  }
}
