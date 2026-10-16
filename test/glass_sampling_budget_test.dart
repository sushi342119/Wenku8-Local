import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/glass_sampling_budget.dart';

void main() {
  test(
    'cached optical proof exactly matches uncached bounds at every size',
    () {
      final cached = GlassSamplingBudgetCache();
      final uncached = GlassSamplingBudgetCache(enabled: false);
      for (final thickness in [4.0, 16.0, 20.0, 56.0]) {
        for (final index in [1.0, 1.2, 1.45, 2.0]) {
          for (var width = 200.0; width <= 700; width += 7) {
            final size = Size(width, 200);
            expect(
              cached.halo(
                size: size,
                radius: 90,
                thickness: thickness,
                refractiveIndex: index,
              ),
              uncached.halo(
                size: size,
                radius: 90,
                thickness: thickness,
                refractiveIndex: index,
              ),
            );
          }
        }
      }
      expect(cached.kernelCalculations, 16);
      expect(cached.cachedKernels, 16);
      expect(uncached.kernelCalculations, greaterThan(1000));
    },
  );

  test('optical proof cache is LRU bounded and invalidates changed optics', () {
    final cache = GlassSamplingBudgetCache(maxEntries: 2);
    Offset halo(double index) => cache.halo(
      size: const Size(196, 70),
      radius: 30,
      thickness: 16,
      refractiveIndex: index,
    );
    halo(1.2);
    halo(1.45);
    halo(1.2);
    halo(2);
    expect(cache.kernelCalculations, 3);
    expect(cache.cachedKernels, 2);
    halo(1.45);
    expect(cache.kernelCalculations, 4);
    expect(cache.cachedKernels, 2);
  });

  test('tight halo contains all fine and coarse quad refraction samples', () {
    for (final scale in [1.0, 2.625, 3.5]) {
      for (final dock in [false, true]) {
        final rect = Rect.fromLTWH(
          24.17 * scale,
          54.29 * scale,
          (dock ? 196 : 46) * scale,
          (dock ? 54 : 46) * scale,
        );
        final radius = math.min(
          (dock ? 27 : 24) * scale,
          rect.shortestSide / 2,
        );
        final thickness = (dock ? 16 : 20) * scale;
        for (final index in [1.0, 1.2, 1.45, 2.0]) {
          final halo = glassSamplingHalo(
            size: rect.size,
            radius: radius,
            thickness: thickness,
            refractiveIndex: index,
          );
          final source = Rect.fromLTRB(
            rect.left - halo.dx,
            rect.top - halo.dy,
            rect.right + halo.dx,
            rect.bottom + halo.dy,
          );
          for (var y = rect.top.floor(); y <= rect.bottom.ceil(); y += 2) {
            for (var x = rect.left.floor(); x <= rect.right.ceil(); x += 2) {
              final p = Offset(x + .5, y + .5);
              final center = _ray(p, rect, radius, thickness, index);
              if (center.$2 >= 0) continue;
              if (center.$2 < -thickness - 2) {
                expect(source.contains(p), true);
                continue;
              }
              final origin = Offset((x ~/ 2) * 2 + .5, (y ~/ 2) * 2 + .5);
              final a = _ray(origin, rect, radius, thickness, index).$1;
              final b = _ray(
                origin + const Offset(1, 0),
                rect,
                radius,
                thickness,
                index,
              ).$1;
              final c = _ray(
                origin + const Offset(0, 1),
                rect,
                radius,
                thickness,
                index,
              ).$1;
              final d = _ray(
                origin + const Offset(1, 1),
                rect,
                radius,
                thickness,
                index,
              ).$1;
              for (final dx in [(b - a) * .25, (d - c) * .25]) {
                for (final dy in [(c - a) * .25, (d - b) * .25]) {
                  for (final sample in [
                    center.$1 - dx - dy,
                    center.$1 + dx - dy,
                    center.$1 - dx + dy,
                    center.$1 + dx + dy,
                  ]) {
                    if (!source.contains(sample)) {
                      fail(
                        'sample $sample outside $source; dock=$dock scale=$scale index=$index',
                      );
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  });

  test('navigation and dock budgets remove unused convolution area', () {
    for (final dock in [false, true]) {
      const scale = 3.5;
      final size = Size((dock ? 196 : 46) * scale, (dock ? 54 : 46) * scale);
      final thickness = (dock ? 16 : 20) * scale;
      final halo = glassSamplingHalo(
        size: size,
        radius: (dock ? 27 : 24) * scale,
        thickness: thickness,
        refractiveIndex: 1.45,
      );
      final previous = thickness * 4 + 2;
      final oldArea =
          (size.width + 2 * previous) * (size.height + 2 * previous);
      final area = (size.width + 2 * halo.dx) * (size.height + 2 * halo.dy);
      expect(area / oldArea, lessThan(.65));
    }
  });

  test(
    'thin corner and unsupported optics keep the established wide budget',
    () {
      for (final index in [.9, 2.1]) {
        expect(
          glassSamplingHalo(
            size: const Size(46, 46),
            radius: 24,
            thickness: 20,
            refractiveIndex: index,
          ),
          const Offset(82, 82),
        );
      }
      expect(
        glassSamplingHalo(
          size: const Size(46, 46),
          radius: 8,
          thickness: 20,
          refractiveIndex: 1.45,
        ),
        const Offset(82, 82),
      );
    },
  );
}

(Offset, double) _ray(
  Offset point,
  Rect rect,
  double radius,
  double thickness,
  double index,
) {
  final p = point - rect.center;
  final q = Offset(
    p.dx.abs() - rect.width / 2 + radius,
    p.dy.abs() - rect.height / 2 + radius,
  );
  final outside = Offset(math.max(0, q.dx), math.max(0, q.dy));
  final length = outside.distance;
  final sd = length + math.min(math.max(q.dx, q.dy), 0) - radius;
  final gradient = length > .0001
      ? Offset(outside.dx / length * p.dx.sign, outside.dy / length * p.dy.sign)
      : q.dx > q.dy
      ? Offset(p.dx.sign, 0)
      : Offset(0, p.dy.sign);
  final u = ((thickness + sd) / thickness).clamp(0.0, 1.0);
  final eta = 1 / index;
  final z = math.sqrt(math.max(0, 1 - u * u));
  final a = math.sqrt(math.max(0, 1 - eta * eta * u * u));
  final slope = u * (a - eta * z) / (eta * u * u + z * a);
  final height = math.sqrt(
    math.max(
      0,
      thickness * thickness - math.pow(math.max(thickness + sd, 0), 2),
    ),
  );
  return (point - gradient * ((height + 3 * thickness) * slope), sd);
}
