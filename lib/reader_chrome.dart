import 'dart:math' as math;
import 'package:flutter/widgets.dart';

import 'app_ui.dart';

/// A retained plane using the established continuous blur on both scroll edges.
/// Controls animate independently; backdrop pixels remain live during scrolling.
class ReaderEdgeBlur extends StatelessWidget {
  const ReaderEdgeBlur({super.key});

  @override
  Widget build(BuildContext context) {
    final view = View.of(context);
    final top = math.max(
      MediaQuery.paddingOf(context).top,
      view.viewPadding.top / view.devicePixelRatio,
    );
    final blur = GlassAppearance.of(context).blur;
    final topHeight =
        top + FrostedHeader.toolbarHeight + FrostedHeader.featherHeight;
    final highContrast = MediaQuery.highContrastOf(context);
    return IgnorePointer(
      child: Stack(
        children: [
          if (!highContrast)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: topHeight,
              child: ProgressiveBlur(maxSigma: blur, plateauHeight: top),
            ),
          const Positioned(bottom: 0, left: 0, right: 0, child: DockUnderlay()),
        ],
      ),
    );
  }
}

/// Only interactive chrome fades/slides. The pinned scroll-edge blur lives
/// outside this layer and keeps sampling the live article in focus mode.
/// At zero controls have no paint, hit targets or accessibility focus.
class ReaderChromeLayer extends StatelessWidget {
  const ReaderChromeLayer({
    super.key,
    required this.animation,
    required this.child,
    this.slide = Offset.zero,
  });
  final Animation<double> animation;
  final Widget child;
  final Offset slide;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) => Offstage(
      offstage: animation.value == 0,
      child: IgnorePointer(
        ignoring: animation.value < .95,
        child: ExcludeSemantics(
          excluding: animation.value < .95,
          child: Opacity(
            opacity: animation.value,
            child: Transform.translate(
              offset: slide * (1 - animation.value),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}
