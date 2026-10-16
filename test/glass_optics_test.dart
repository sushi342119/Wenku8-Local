import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/glass_optics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Fresnel reflectance is bounded and grows toward grazing angles', () {
    final n = GlassOptics.refractiveIndex;
    expect(
      GlassOptics.fresnel(1),
      closeTo(math.pow((n - 1) / (n + 1), 2), 1e-9),
    );
    expect(GlassOptics.fresnel(0), 1);
    var previous = 0.0;
    for (var step = 100; step >= 0; step--) {
      final reflectance = GlassOptics.fresnel(step / 100);
      expect(reflectance, inInclusiveRange(0.0, 1.0));
      expect(reflectance, greaterThanOrEqualTo(previous - 1e-10));
      previous = reflectance;
    }
  });

  test('the edge follows its outward normal, not a screen-space gradient', () {
    double reflect(Offset normal, double depth) => GlassOptics.reflectionAlpha(
      outwardNormal: normal,
      depth: depth,
      bevel: 5,
    );
    final light = GlassOptics.lightDirection;
    expect(reflect(light, 0), greaterThan(reflect(-light, 0) * 30));
    expect(reflect(light, .25), lessThan(reflect(light, 0)));
    expect(reflect(light, 5), 0);
  });

  test('neutral reflection never paints a dark or colored outline', () async {
    const size = Size(160, 60);
    for (final background in [
      Colors.white,
      const Color(0xFF171717),
      const Color(0xFF8A264F),
    ]) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(background, BlendMode.src);
      const GlassReflectionPainter(radius: 30).paint(canvas, size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(160, 60);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final source = [
        (background.r * 255).round(),
        (background.g * 255).round(),
        (background.b * 255).round(),
      ];
      for (var pixel = 0; pixel < 160 * 60; pixel++) {
        for (var channel = 0; channel < 3; channel++) {
          expect(
            bytes.getUint8(pixel * 4 + channel),
            greaterThanOrEqualTo(source[channel] - 1),
          );
        }
      }
      // The flat center still transmits its original color exactly.
      for (var channel = 0; channel < 3; channel++) {
        expect(bytes.getUint8((30 * 160 + 80) * 4 + channel), source[channel]);
      }
      // On dark glass the upper-left light is stronger than the opposing rim.
      if (background != Colors.white) {
        expect(
          bytes.getUint8((0 * 160 + 80) * 4),
          greaterThan(bytes.getUint8((59 * 160 + 80) * 4)),
        );
      }
      image.dispose();
      picture.dispose();
    }
  });

  test('the cast shadow does not paint the transmitting surface', () async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    const GlassShadowPainter(
      radius: 30,
      alpha: .5,
    ).paint(canvas, const Size(160, 60));
    final picture = recorder.endRecording();
    final image = await picture.toImage(160, 60);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    for (var y = 1; y < 59; y++) {
      for (var x = 31; x < 129; x++) {
        expect(bytes.getUint8((y * 160 + x) * 4), 255);
      }
    }
    image.dispose();
    picture.dispose();
  });

  testWidgets('backdrop color is not normalized or saturated into rim light', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(
          body: Center(
            child: LiquidGlass(child: SizedBox(width: 160, height: 60)),
          ),
        ),
      ),
    );
    final glass = tester.widget<NativeBackdrop>(find.byType(NativeBackdrop));
    expect(glass.effect, NativeEffect.glass);
    expect(glass.tint.a, closeTo(.87, .001));
    expect(glass.radius, 28);
    expect(glass.thickness, 20);
    expect(glass.blur, 0, reason: 'Small controls add no optical-blur passes.');
    expect(glass.refractiveIndex, 1.33);
    expect(glass.emission, greaterThan(0));
  });

  testWidgets('lightweight glass keeps explicit overlay softening', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: GlassOverlaySurface(
              child: SizedBox(width: 200, height: 180),
            ),
          ),
        ),
      ),
    );
    final overlay = tester.widget<NativeBackdrop>(find.byType(NativeBackdrop));
    expect(overlay.blur, 8);
    expect(overlay.refractiveIndex, GlassOptics.refractiveIndex);
    expect(overlay.thickness, greaterThan(0));
    expect(overlay.emission, greaterThan(0));
  });
}
