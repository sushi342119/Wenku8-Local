import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wenku8_flutter/native_effects.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('optimized kernels retain native pixels in flat cores and blur', (
    tester,
  ) async {
    await NativeEffects.prepare();
    expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
    final key = GlobalKey();
    for (final (effect, blur, activation) in [
      (NativeEffect.glass, 0.0, 0.0),
      (NativeEffect.glass, .9, 0.0),
      (NativeEffect.glass, .9, .8),
      (NativeEffect.progressive, 8.0, 0.0),
      (NativeEffect.progressive, 24.0, 0.0),
    ]) {
      Future<ByteData> draw(bool optimized) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              home: Scaffold(
                body: Stack(
                  children: [
                    const Positioned.fill(
                      child: CustomPaint(painter: _Source()),
                    ),
                    Positioned(
                      left: 26.17,
                      top: 62.29,
                      right: 26,
                      child: NativeBackdrop(
                        key: ValueKey(optimized),
                        effect: effect,
                        blur: blur,
                        plateau: 32,
                        thickness: 20,
                        radius: 28,
                        activation: activation,
                        touchPosition: .3,
                        tint: const Color(0x0afffdf8),
                        emission: .024,
                        optimizedSampling: optimized,
                        nativeEdgeBlur: false,
                        child: const SizedBox(height: 280),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return _capture(key, '${effect.name}-$blur-$activation-$optimized');
      }

      final before = await draw(false), after = await draw(true);
      _compare(before, after, '${effect.name}/$blur/$activation');
    }
  });

  testWidgets(
    'reference continuous edges share their live source without sharing control input',
    (tester) async {
      await NativeEffects.prepare();
      final key = GlobalKey();
      final source = ValueNotifier(false);
      addTearDown(source.dispose);
      Future<ByteData> draw(bool grouped) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              home: Scaffold(
                body: NativeScrollEdgeGroup(
                  enabled: grouped,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ValueListenableBuilder<bool>(
                          valueListenable: source,
                          builder: (_, changed, _) =>
                              CustomPaint(painter: _Source(invert: changed)),
                        ),
                      ),
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: NativeBackdrop(
                          key: ValueKey('top'),
                          effect: NativeEffect.progressive,
                          blur: 8,
                          plateau: 32,
                          nativeEdgeBlur: false,
                          child: SizedBox(height: 144),
                        ),
                      ),
                      const Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: NativeBackdrop(
                          key: ValueKey('bottom'),
                          effect: NativeEffect.progressive,
                          blur: 1.28,
                          fromBottom: true,
                          plateau: 20,
                          nativeEdgeBlur: false,
                          child: SizedBox(height: 84),
                        ),
                      ),
                      const Positioned(top: 50, left: 30, child: Text('清晰导航')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final objects = [
          for (final name in ['top', 'bottom'])
            tester.renderObject(find.byKey(ValueKey(name))) as dynamic,
        ];
        expect(objects.first.debugUsesSharedGlass, grouped);
        expect(objects.first.debugShaderCount, 4);
        expect(objects.last.debugShaderCount, 2);
        if (grouped) {
          expect(
            objects.first.debugSharedGlassKey,
            same(objects.last.debugSharedGlassKey),
          );
        }
        return _capture(key, 'edges-$grouped-${source.value}');
      }

      final before = await draw(false), grouped = await draw(true);
      _compare(before, grouped, 'edge-group');
      source.value = true;
      await tester.pump();
      final live = await _capture(key, 'edges-live');
      expect(
        _meanDifference(grouped, live),
        greaterThan(10),
        reason: 'The blur must not freeze its source.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('native edge feather softens the plateau and lands clear', (
    tester,
  ) async {
    await NativeEffects.prepare();
    final key = GlobalKey();
    Future<ByteData> draw(bool blur) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  const Positioned.fill(child: CustomPaint(painter: _Source())),
                  if (blur)
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: NativeBackdrop(
                        effect: NativeEffect.progressive,
                        blur: 8,
                        plateau: 32,
                        child: SizedBox(height: 144),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return _capture(key, 'native-feather-$blur');
    }

    final plain = await draw(false), softened = await draw(true);
    final dpr = tester.view.devicePixelRatio;
    double difference(double top, double bottom) {
      var total = 0, count = 0;
      final width = tester.view.physicalSize.width.round();
      for (var y = (top * dpr).ceil(); y < (bottom * dpr).floor(); y++) {
        for (var x = (20 * dpr).ceil(); x < width - 20 * dpr; x++) {
          for (var c = 0; c < 3; c++) {
            final i = (y * width + x) * 4 + c;
            total += (plain.getUint8(i) - softened.getUint8(i)).abs();
            count++;
          }
        }
      }
      return total / count;
    }

    expect(
      difference(4, 28),
      greaterThan(8),
      reason: 'The native Gaussian must really soften the live source.',
    );
    expect(
      difference(142, 144),
      lessThan(1),
      reason: 'The feather must meet sharp content without a seam.',
    );
    expect(difference(150, 180), 0);
  });

  testWidgets('both screen edges remain stable as backdrop damage changes', (
    tester,
  ) async {
    final key = GlobalKey();
    final motion = ValueNotifier(0);
    addTearDown(motion.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          home: Scaffold(
            body: NativeGlassGroup(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ValueListenableBuilder<int>(
                      valueListenable: motion,
                      builder: (_, value, _) => RepaintBoundary(
                        child: CustomPaint(painter: _DamageSource(value)),
                      ),
                    ),
                  ),
                  for (final bottom in [false, true])
                    Positioned(
                      top: bottom ? null : 0,
                      bottom: bottom ? 0 : null,
                      left: 0,
                      right: 0,
                      height: 120,
                      child: NativeBackdrop(
                        effect: NativeEffect.progressive,
                        blur: 8,
                        plateau: 24,
                        fromBottom: bottom,
                        child: const SizedBox.expand(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final reference = await _capture(key, 'stable-edges-reference');
    final width = tester.view.physicalSize.width.round();
    final height = tester.view.physicalSize.height.round();
    final band = (100 * tester.view.devicePixelRatio).round();
    for (var frame = 1; frame <= 5; frame++) {
      motion.value = frame;
      await tester.pump();
      final image = await _capture(key, 'stable-edges-$frame');
      var maximum = 0;
      for (final start in [0, height - band]) {
        for (var y = start; y < start + band; y++) {
          for (var x = 0; x < width; x++) {
            for (var c = 0; c < 3; c++) {
              final i = (y * width + x) * 4 + c;
              final delta = (reference.getUint8(i) - image.getUint8(i)).abs();
              if (delta > maximum) maximum = delta;
            }
          }
        }
      }
      expect(
        maximum,
        lessThanOrEqualTo(1),
        reason: 'Damage below the blur input halo must not flash either edge.',
      );
    }
    expect(tester.takeException(), isNull);
  });
  tearDownAll(() async {
    if (const bool.fromEnvironment('EXPORT_NATIVE_CAPTURES')) {
      debugPrint('NATIVE_CAPTURES_READY');
      await Future<void>.delayed(const Duration(seconds: 8));
    }
  });
}

Future<ByteData> _capture(GlobalKey key, String label) async {
  final image =
      await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
          .toImage(
            pixelRatio:
                ui.PlatformDispatcher.instance.views.first.devicePixelRatio,
          );
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final dir = Directory(
      '${(await getTemporaryDirectory()).path}/ui-refinement',
    );
    await dir.create(recursive: true);
    final path = '${dir.path}/scroll-surface-$label.png';
    await File(path).writeAsBytes(
      (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List(),
    );
    // ignore: avoid_print
    print('UI_REFINEMENT_CAPTURE=$path');
    return data;
  } finally {
    image.dispose();
  }
}

double _meanDifference(ByteData a, ByteData b) {
  var total = 0;
  for (var i = 0; i < a.lengthInBytes; i++) {
    if (i % 4 != 3) total += (a.getUint8(i) - b.getUint8(i)).abs();
  }
  return total / (a.lengthInBytes / 4 * 3);
}

void _compare(ByteData a, ByteData b, String label) {
  expect(b.lengthInBytes, a.lengthInBytes);
  var maximum = 0;
  for (var i = 0; i < a.lengthInBytes; i++) {
    if (i % 4 != 3) {
      final d = (a.getUint8(i) - b.getUint8(i)).abs();
      if (d > maximum) maximum = d;
    }
  }
  final mean = _meanDifference(a, b);
  // ignore: avoid_print
  print('SCROLL_SURFACE_PARITY $label max=$maximum mean=$mean');
  expect(maximum, lessThanOrEqualTo(2));
  expect(mean, lessThan(.15));
}

class _Source extends CustomPainter {
  const _Source({this.invert = false});
  final bool invert;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(
      invert ? const Color(0xff171717) : const Color(0xfffdfbf7),
      BlendMode.src,
    );
    const colors = [
      Color(0xff171717),
      Color(0xff9a285f),
      Color(0xff398dbd),
      Color(0xfff0d287),
    ];
    for (var y = 0.0; y < size.height; y += 9) {
      for (var x = 0.0; x < size.width; x += 8) {
        canvas.drawRect(
          Rect.fromLTWH(x, y, 4, 5),
          Paint()
            ..color =
                colors[((x / 8).floor() + (y / 9).floor() + (invert ? 1 : 0)) %
                    4],
        );
      }
    }
  }

  @override
  bool shouldRepaint(_Source oldDelegate) => invert != oldDelegate.invert;
}

class _DamageSource extends CustomPainter {
  const _DamageSource(this.frame);
  final int frame;
  @override
  void paint(Canvas canvas, Size size) {
    const _Source().paint(canvas, size);
    canvas.drawRect(
      Rect.fromLTWH(
        20 + frame * 5,
        size.height * .4,
        size.width - 80,
        size.height * .15,
      ),
      Paint()..color = frame.isEven ? Colors.black : Colors.white,
    );
  }

  @override
  bool shouldRepaint(_DamageSource oldDelegate) => frame != oldDelegate.frame;
}
