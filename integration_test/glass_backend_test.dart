import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/native_effects.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reports whether the device supports glass shaders', (
    tester,
  ) async {
    await NativeEffects.prepare();
    // A device-level probe keeps visual QA from silently using the fake blur path.
    // ignore: avoid_print
    print('GLASS_SHADER_SUPPORTED=${ui.ImageFilter.isShaderFilterSupported}');
    expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
  });

  testWidgets('pinned native filters reuse graphs but keep the backdrop live', (
    tester,
  ) async {
    await NativeEffects.prepare();
    for (final effect in NativeEffect.values) {
      final capture = GlobalKey();
      late StateSetter change;
      var source = const Color(0xFF171717);
      var left = 76.0;
      var emission = .024;
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  change = setState;
                  return Stack(
                    children: [
                      Positioned.fill(child: ColoredBox(color: source)),
                      Positioned(
                        left: left,
                        top: 150,
                        child: NativeBackdrop(
                          key: const ValueKey('retained-filter-probe'),
                          effect: effect,
                          blur: effect == NativeEffect.glass ? .9 : 8,
                          plateau: 70,
                          thickness: 16,
                          emission: emission,
                          child: const SizedBox(width: 196, height: 70),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final probe = find.byKey(const ValueKey('retained-filter-probe'));
      final dynamic render = tester.renderObject(probe);
      Future<void> checkCenter() async {
        final rect = tester.getRect(probe);
        final dpr = tester.view.devicePixelRatio;
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: dpr);
        try {
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final x = (rect.center.dx * dpr).floor();
          final y = (rect.center.dy * dpr).floor();
          final expected =
              (source.r * 255 +
                      (effect == NativeEffect.glass ? emission * 255 : 0))
                  .round();
          for (var channel = 0; channel < 3; channel++) {
            expect(
              pixels.getUint8((y * image.width + x) * 4 + channel),
              closeTo(expected, 1),
            );
          }
        } finally {
          image.dispose();
        }
      }

      await checkCenter();
      final int initialBuilds = render.debugFilterBuildCount;
      for (var frame = 0; frame < 12; frame++) {
        change(
          () => source = frame.isEven
              ? const Color(0xFF171717)
              : const Color(0xFF404040),
        );
        await tester.pump(const Duration(microseconds: 8334));
      }
      await checkCenter();
      expect(render.debugFilterBuildCount, initialBuilds);
      expect(render.debugFilterReuseCount, greaterThanOrEqualTo(12));
      // ignore: avoid_print
      print(
        'PINNED_FILTER_CACHE effect=$effect builds=${render.debugFilterBuildCount} reuses=${render.debugFilterReuseCount} live_source=64',
      );
      change(() => left += 20);
      await tester.pump();
      await checkCenter();
      expect(render.debugFilterBuildCount, initialBuilds + 1);
      change(() => emission = .035);
      await tester.pump();
      await checkCenter();
      expect(render.debugFilterBuildCount, initialBuilds + 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('native effects allocate only the convolution shaders they use', (
    tester,
  ) async {
    await NativeEffects.prepare();
    for (final (effect, blur, count) in [
      (NativeEffect.glass, 0.0, 1),
      (NativeEffect.glass, .9, 3),
      (NativeEffect.glass, 8.0, 1),
      (NativeEffect.progressive, 1.0, 1),
      (NativeEffect.progressive, 8.0, 1),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: NativeBackdrop(
                key: ValueKey('$effect/$blur'),
                effect: effect,
                blur: blur,
                thickness: 16,
                child: const SizedBox(width: 196, height: 70),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic render = tester.renderObject(find.byType(NativeBackdrop));
      expect(render.debugShaderCount, count);
      debugPrint(
        'LAZY_GLASS_SHADERS effect=$effect blur=$blur shaders=${render.debugShaderCount}',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('native glass keeps white, dark, and cover-colored rims neutral', (
    tester,
  ) async {
    final snapshotKey = GlobalKey();
    for (final background in [
      Colors.white,
      const Color(0xFF171717),
      const Color(0xFF8A264F),
    ]) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: snapshotKey,
          child: MaterialApp(
            theme: novelTheme(Brightness.light),
            home: Scaffold(
              backgroundColor: background,
              body: const Center(
                child: GlassAppearance(
                  opacity: 0,
                  blur: 0,
                  child: LiquidGlass(
                    key: ValueKey('optics-probe'),
                    child: SizedBox(width: 160, height: 60),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(const ValueKey('optics-probe')));
      final dpr = tester.view.devicePixelRatio;
      // Capture the full Flutter layer tree on the device. This includes the
      // backdrop source, shader and crisp foreground, without PixelCopy's
      // emulator-dependent SurfaceView-to-ImageView conversion.
      final boundary =
          snapshotKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: dpr);
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final source = [
        (background.r * 255).round(),
        (background.g * 255).round(),
        (background.b * 255).round(),
      ];
      final silhouette = RRect.fromRectAndRadius(
        rect.deflate(1),
        const Radius.circular(27),
      );
      final minimum = [255, 255, 255];
      for (
        var y = (rect.top * dpr).ceil();
        y < (rect.bottom * dpr).floor();
        y++
      ) {
        for (
          var x = (rect.left * dpr).ceil();
          x < (rect.right * dpr).floor();
          x++
        ) {
          if (!silhouette.contains(Offset((x + .5) / dpr, (y + .5) / dpr))) {
            continue;
          }
          for (var channel = 0; channel < 3; channel++) {
            final value = pixels.getUint8((y * image.width + x) * 4 + channel);
            if (value < minimum[channel]) {
              minimum[channel] = value;
            }
          }
        }
      }
      for (var channel = 0; channel < 3; channel++) {
        expect(
          minimum[channel],
          greaterThanOrEqualTo(source[channel] - 2),
          reason:
              'A uniform backdrop must not gain a dark or hue-shifted glass rim.',
        );
        final centerX = (rect.center.dx * dpr).floor();
        final centerY = (rect.center.dy * dpr).floor();
        // This fixture uses the light-theme material on every background.
        // Account for its uniform emission without relaxing the rim check.
        final expectedCenter = (source[channel] + .010 * 255)
            .clamp(0, 255)
            .round();
        expect(
          pixels.getUint8((centerY * image.width + centerX) * 4 + channel),
          closeTo(expectedCenter, 1),
        );
      }
      image.dispose();
    }
  });

  testWidgets('fractional-position glass has physical-pixel edge coverage', (
    tester,
  ) async {
    await NativeEffects.prepare();
    final capture = GlobalKey();
    for (final offset in [const Offset(.17, .29), const Offset(.43, .61)]) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                child: Transform.translate(
                  offset: offset,
                  child: const NativeBackdrop(
                    key: ValueKey('coverage-probe'),
                    effect: NativeEffect.glass,
                    radius: 26.5,
                    thickness: 20,
                    tint: Colors.white,
                    child: SizedBox(width: 180, height: 64),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(const ValueKey('coverage-probe')));
      final dpr = tester.view.devicePixelRatio;
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: dpr);
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var covered = 0;
      var fractional = 0;
      for (
        var y = (rect.top * dpr).floor();
        y < (rect.bottom * dpr).ceil();
        y++
      ) {
        for (
          var x = (rect.left * dpr).floor();
          x < (rect.right * dpr).ceil();
          x++
        ) {
          final red = pixels.getUint8((y * image.width + x) * 4);
          if (red > 0) covered++;
          if (red > 2 && red < 253) fractional++;
        }
      }
      final center =
          ((rect.center.dy * dpr).floor() * image.width +
              (rect.center.dx * dpr).floor()) *
          4;
      expect(pixels.getUint8(center), greaterThanOrEqualTo(254));
      expect(covered, greaterThan(180 * 64 * dpr * dpr * .75));
      expect(
        fractional,
        greaterThan(50),
        reason: 'Curved boundaries need graded coverage, not a binary matte.',
      );
      // ignore: avoid_print
      print(
        'GLASS_ANTIALIAS offset=$offset covered=$covered fractional_edge_pixels=$fractional',
      );
      image.dispose();
    }
  });

  testWidgets('dock glass keeps clear transmission without a second tint', (
    tester,
  ) async {
    await NativeEffects.prepare();
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: Stack(
              children: [
                const Positioned.fill(
                  child: CustomPaint(painter: _CoreStripes()),
                ),
                Center(
                  child: GlassAppearance(
                    opacity: .3,
                    blur: 18,
                    child: SizedBox(
                      key: const ValueKey('core-probe'),
                      width: 196,
                      height: 54,
                      child: const LiquidGlass(
                        radius: 27,
                        thickness: 16,
                        elevated: false,
                        child: SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const ValueKey('core-probe')));
    final dpr = tester.view.devicePixelRatio;
    final image =
        await (capture.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: dpr);
    final pixels = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    var low = 255;
    var high = 0;
    final y = (rect.center.dy * dpr).floor();
    for (
      var x = ((rect.center.dx - 40) * dpr).ceil();
      x < ((rect.center.dx + 40) * dpr).floor();
      x++
    ) {
      final value = pixels.getUint8((y * image.width + x) * 4);
      if (value < low) low = value;
      if (value > high) high = value;
    }
    // No added convolution: a single 30% white tint and 1% uniform emission
    // preserve roughly 255 * .70 * .99 = 176.7 of the source contrast.
    expect(high - low, inInclusiveRange(176, 179));
    // ignore: avoid_print
    print('GLASS_CLEAR_CORE contrast=${high - low} tint=0.30 sigma=0');
    image.dispose();
  });

  testWidgets(
    'shared glass emits uniformly across its whole surface without a ring',
    (tester) async {
      await NativeEffects.prepare();
      final capture = GlobalKey();
      for (final opacity in [0.0, .08, .3]) {
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: novelTheme(Brightness.dark),
              home: Scaffold(
                backgroundColor: const Color(0xFF171717),
                body: GlassAppearance(
                  opacity: opacity,
                  blur: 18,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const LiquidGlass(
                          key: ValueKey('unlifted-dark-glass'),
                          radius: 27,
                          thickness: 16,
                          elevated: false,
                          child: SizedBox(width: 196, height: 54),
                        ),
                        const SizedBox(height: 30),
                        GlassPillButton(
                          key: const ValueKey('lifted-dark-read-action'),
                          icon: Icons.menu_book,
                          label: '继续阅读',
                          onPressed: () {},
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final dpr = tester.view.devicePixelRatio;
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: dpr);
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final tint = ArchiveDesign.glassTint(Brightness.dark, opacity: opacity);
        final expected = [tint.r, tint.g, tint.b]
            // The shader tints the 23/255 source, then adds uniform emission.
            .map(
              (channel) =>
                  23 * (1 - opacity) + channel * 255 * opacity + 255 * .024,
            )
            .toList();
        int materialSample(String key) {
          final rect = tester.getRect(find.byKey(ValueKey(key)));
          // Inside the flat material, clear of the icon, label and curved rim.
          final x = ((rect.left + 24) * dpr).floor();
          final y = (rect.center.dy * dpr).floor();
          final offset = (y * image.width + x) * 4;
          final red = pixels.getUint8(offset);
          // The warm milk film intentionally has a slightly lower blue channel.
          // Keep emission/tint compositing analytical instead of assuming grey.
          for (var channel = 0; channel < 3; channel++) {
            expect(
              pixels.getUint8(offset + channel),
              closeTo(expected[channel], 2),
            );
          }
          return red;
        }

        final baseline = materialSample('unlifted-dark-glass');
        final lifted = materialSample('lifted-dark-read-action');
        if (opacity == 0) expect(baseline, closeTo(29, 1));
        expect(lifted - baseline, inInclusiveRange(-1, 1));
        final rim = tester.getRect(
          find.byKey(const ValueKey('unlifted-dark-glass')),
        );
        final rimX = (rim.center.dx * dpr).floor();
        final samples = <int>[];
        for (final dy in [2.0, 12.0, 27.0, 40.0, 52.0]) {
          final y = ((rim.top + dy) * dpr).floor();
          final value = pixels.getUint8((y * image.width + rimX) * 4);
          samples.add(value);
          expect(value, closeTo(baseline, 1));
        }
        final outsideY = ((rim.top - 3) * dpr).floor();
        final outside = pixels.getUint8((outsideY * image.width + rimX) * 4);
        expect(outside, closeTo(23, 1));
        // ignore: avoid_print
        print(
          'SHARED_GLASS_SURFACE opacity=$opacity core=$baseline action=$lifted samples=$samples outside=$outside',
        );
        image.dispose();
      }
    },
  );
  testWidgets(
    'wide glass overlays soften fine text with a uniform neutral surface lift',
    (tester) async {
      await NativeEffects.prepare();
      final capture = GlobalKey();
      for (final source in [Colors.white, const Color(0xFF171717), null]) {
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: novelTheme(
                source == const Color(0xFF171717)
                    ? Brightness.dark
                    : Brightness.light,
              ),
              home: Scaffold(
                backgroundColor: source ?? Colors.white,
                body: Stack(
                  children: [
                    if (source == null)
                      const Positioned.fill(
                        child: CustomPaint(painter: _CoreStripes()),
                      ),
                    const Center(
                      child: GlassAppearance(
                        blur: 24,
                        opacity: 0,
                        child: GlassOverlaySurface(
                          key: ValueKey('wide-glass-probe'),
                          child: SizedBox(width: 196, height: 70),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final rect = tester.getRect(
          find.byKey(const ValueKey('wide-glass-probe')),
        );
        final dpr = tester.view.devicePixelRatio;
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: dpr);
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        var low = 255;
        var high = 0;
        final y = (rect.center.dy * dpr).floor();
        for (
          var x = ((rect.center.dx - 35) * dpr).ceil();
          x < ((rect.center.dx + 35) * dpr).floor();
          x++
        ) {
          final offset = (y * image.width + x) * 4;
          final value = pixels.getUint8(offset);
          low = value < low ? value : low;
          high = value > high ? value : high;
          expect(pixels.getUint8(offset + 1), closeTo(value, 1));
          expect(pixels.getUint8(offset + 2), closeTo(value, 1));
        }
        if (source != null) {
          final emission = source == const Color(0xFF171717) ? .024 : .010;
          final expected = (source.r * 255 + emission * 255)
              .clamp(0, 255)
              .round();
          expect(low, closeTo(expected, 1));
          expect(high, closeTo(expected, 1));
        } else {
          expect(high - low, lessThanOrEqualTo(8));
        }
        // ignore: avoid_print
        print('WIDE_GLASS_CORE source=$source min=$low max=$high');
        image.dispose();
      }
    },
  );
  testWidgets('wide glass kernel handoff has no 3dp brightness step', (
    tester,
  ) async {
    await NativeEffects.prepare();
    final capture = GlobalKey();
    final phase = AnimationController(vsync: tester);
    final means = <double>[];
    for (final blur in [2.99, 3.0, 3.01]) {
      final progress = (blur - .4) / (8 - .4);
      var low = 0.0;
      var high = 1.0;
      for (var i = 0; i < 24; i++) {
        final middle = (low + high) / 2;
        if (Curves.easeOutCubic.transform(middle) < progress) {
          low = middle;
        } else {
          high = middle;
        }
      }
      phase.value = (low + high) / 2;
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  const Positioned.fill(
                    child: CustomPaint(painter: _CoreStripes()),
                  ),
                  Center(
                    child: NativeBackdrop(
                      key: const ValueKey('handoff-glass'),
                      effect: NativeEffect.glass,
                      blur: 8,
                      preserveOptics: true,
                      morph: NativeGlassMorph(
                        animation: phase,
                        radius: 28,
                        thickness: 20,
                        blur: .4,
                      ),
                      child: const SizedBox(width: 196, height: 70),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(const ValueKey('handoff-glass')));
      final dpr = tester.view.devicePixelRatio;
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: dpr);
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final y = (rect.center.dy * dpr).floor();
      var total = 0;
      var count = 0;
      for (
        var x = ((rect.center.dx - 30) * dpr).ceil();
        x < ((rect.center.dx + 30) * dpr).floor();
        x++
      ) {
        total += pixels.getUint8((y * image.width + x) * 4);
        count++;
      }
      means.add(total / count);
      image.dispose();
    }
    for (var i = 1; i < means.length; i++) {
      expect((means[i] - means[i - 1]).abs(), lessThanOrEqualTo(2));
    }
    // ignore: avoid_print
    print('GLASS_BLUR_HANDOFF blur=[2.99,3.0,3.01] mean_rgb=$means');
    await tester.pumpWidget(const SizedBox.shrink());
    phase.dispose();
    expect(tester.takeException(), isNull);
  });
}

class _CoreStripes extends CustomPainter {
  const _CoreStripes();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.white, BlendMode.src);
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 4, size.height),
        Paint()..color = Colors.black,
      );
    }
  }

  @override
  bool shouldRepaint(_CoreStripes oldDelegate) => false;
}
