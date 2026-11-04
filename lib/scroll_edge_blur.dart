import 'package:flutter/material.dart';

import 'native_effects.dart';
import 'dock_layout.dart';

/// Reference radius profile for the continuous-kernel renderer. The default
/// renderer feathers a live native Gaussian, without an opaque gradient fill.
abstract final class ScrollEdgeProfile {
  static double sigma(double progress, {double maximum = 20}) {
    final depth = 1 - progress.clamp(0.0, 1.0);
    // Zero radius and zero slope where clear content first enters the feather.
    return maximum * depth * depth;
  }
}

class ProgressiveBlur extends StatelessWidget {
  const ProgressiveBlur({
    super.key,
    this.maxSigma = 8,
    this.plateauHeight = 0,
    this.fromBottom = false,
    this.shadeOpacity = DockLayout.edgeShadeOpacity,
  });

  final double maxSigma;
  final double plateauHeight;
  final bool fromBottom;
  final double shadeOpacity;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: maxSigma <= 0
        ? const SizedBox.expand()
        : LayoutBuilder(
            builder: (context, constraints) => Stack(
              fit: StackFit.expand,
              children: [
                NativeBackdrop(
                  effect: NativeEffect.progressive,
                  blur: maxSigma,
                  plateau: plateauHeight,
                  fromBottom: fromBottom,
                  child: const SizedBox.expand(),
                ),
                if (shadeOpacity > 0)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: fromBottom
                            ? Alignment.bottomCenter
                            : Alignment.topCenter,
                        end: fromBottom
                            ? Alignment.topCenter
                            : Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: shadeOpacity),
                          Colors.black.withValues(alpha: shadeOpacity),
                          Colors.transparent,
                        ],
                        stops: [
                          0,
                          (plateauHeight / constraints.maxHeight).clamp(
                            0.0,
                            1.0,
                          ),
                          1,
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
  );
}
