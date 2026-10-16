import 'dart:math' as math;
import 'dart:ui' as ui;

final _samplingCache = GlassSamplingBudgetCache(
  enabled: const bool.fromEnvironment('GLASS_HALO_CACHE', defaultValue: true),
);

/// Bounds every source sample of an inactive rounded glass plane, including
/// the quarter-quad antialiasing footprint. All values are physical pixels.
/// Interval bounds, not sampled extrema, keep the blur's source halo complete.
ui.Offset glassSamplingHalo({
  required ui.Size size,
  required double radius,
  required double thickness,
  required double refractiveIndex,
}) => _samplingCache.halo(
  size: size,
  radius: radius,
  thickness: thickness,
  refractiveIndex: refractiveIndex,
);

/// Cache the interval proof, not the sampled backdrop or screen coordinates.
/// Scrolling changes a plane's origin but not its optical geometry. Width and
/// height are applied after the proof, retaining the exact original bounds.
class GlassSamplingBudgetCache {
  GlassSamplingBudgetCache({this.maxEntries = 64, this.enabled = true})
    : assert(maxEntries > 0);
  final int maxEntries;
  final bool enabled;
  final _kernels = <(double, double, double), (double, double)>{};
  int _calculations = 0;
  int get kernelCalculations => _calculations;
  int get cachedKernels => _kernels.length;

  ui.Offset halo({
    required ui.Size size,
    required double radius,
    required double thickness,
    required double refractiveIndex,
  }) {
    final conservative = thickness * 4 + 2;
    const quadDistance = 2.0;
    final corner = math.min(radius, size.shortestSide / 2);
    if (!size.isFinite ||
        !radius.isFinite ||
        !thickness.isFinite ||
        !refractiveIndex.isFinite ||
        thickness <= quadDistance ||
        corner <= thickness + quadDistance ||
        refractiveIndex < 1 ||
        refractiveIndex > 2) {
      return ui.Offset(conservative, conservative);
    }
    final key = (corner, thickness, refractiveIndex);
    var kernel = enabled ? _kernels.remove(key) : null;
    if (kernel == null) {
      _calculations++;
      kernel = _proveKernel(corner, thickness, refractiveIndex);
    }
    if (enabled) {
      _kernels[key] = kernel;
      if (_kernels.length > maxEntries) _kernels.remove(_kernels.keys.first);
    }
    final (reach, footprint) = kernel;
    return ui.Offset(
      math.min(conservative, math.max(0, reach - size.width) + footprint),
      math.min(conservative, math.max(0, reach - size.height) + footprint),
    );
  }

  static (double, double) _proveKernel(
    double corner,
    double thickness,
    double refractiveIndex,
  ) {
    const quadDistance = 2.0;
    const intervals = 128;
    final upper = List<double>.filled(intervals, 0);
    final lower = List<double>.filled(intervals, 0);
    final eta = 1 / refractiveIndex;
    double slope(double u) => math.tan(math.asin(u) - math.asin(eta * u));
    var reach = 0.0;
    var curvature = 0.0;
    for (var i = 0; i < intervals; i++) {
      final lo = i / intervals;
      final hi = (i + 1) / intervals;
      final zLo = math.sqrt(math.max(0, 1 - lo * lo));
      final zHi = math.sqrt(math.max(0, 1 - hi * hi));
      // Ray slope increases with u; height decreases. Opposite interval ends
      // bound their product without assuming that its maximum is at an edge.
      upper[i] = thickness * (3 + zLo) * slope(hi);
      lower[i] = thickness * (3 + zHi) * slope(lo);
      reach = math.max(reach, upper[i] + thickness * (1 - lo));
      curvature = math.max(
        curvature,
        upper[i] / (corner - thickness - quadDistance + thickness * lo),
      );
    }
    // SDF is 1-Lipschitz. Quad neighbours can only visit these adjacent u
    // intervals. Bound their ray-length difference before the 1/4 weighting.
    final adjacent = (quadDistance / thickness * intervals).ceil() + 1;
    var rayDifference = 0.0;
    for (var i = 0; i < intervals; i++) {
      final first = math.max(0, i - adjacent);
      final last = math.min(intervals - 1, i + adjacent);
      for (var j = first; j <= last; j++) {
        rayDifference = math.max(rayDifference, upper[i] - lower[j]);
      }
    }
    // Two weighted derivative axes plus padding/rounding guards. Refraction is
    // inward: only rays crossing the opposite side need an additional halo.
    final footprint =
        .5 * (quadDistance * (1 + 2 * curvature) + rayDifference) + 8;
    return (reach, footprint);
  }
}
