import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('package optics retain pixels across shapes, blur and transforms', (
    tester,
  ) async {
    await LiquidGlassShaders.ensureLoaded();
    expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
    final key = GlobalKey();
    for (final (name, shape, blur, scale, angle, batch) in [
      (
        'clear',
        const LiquidGlassShape.roundedRectangle(cornerRadius: 28),
        0.0,
        1.0,
        0.0,
        false,
      ),
      (
        'frosted',
        const LiquidGlassShape.roundedRectangle(cornerRadius: 28),
        8.0,
        1.0,
        0.0,
        false,
      ),
      (
        'batched-frosted',
        const LiquidGlassShape.roundedRectangle(cornerRadius: 28),
        8.0,
        1.0,
        0.0,
        true,
      ),
      (
        'continuous',
        const LiquidGlassShape.continuousRoundedRectangle(cornerRadius: 32),
        0.0,
        1.0,
        0.0,
        false,
      ),
      (
        'squircle-moving',
        const LiquidGlassShape.squircle(cornerRadius: 36),
        3.0,
        .53,
        .18,
        false,
      ),
      (
        'small-morph',
        const LiquidGlassShape.roundedRectangle(cornerRadius: 36),
        1.0,
        .12,
        0.0,
        false,
      ),
    ]) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: LiquidGlassBatch(
                enabled: batch,
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: CustomPaint(painter: _Pattern()),
                    ),
                    Positioned(
                      left: 35.17,
                      top: 170.29,
                      child: Transform.rotate(
                        angle: angle,
                        child: Transform.scale(
                          scale: scale,
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            width: 270,
                            height: 164,
                            child: LiquidGlassLens(
                              key: ValueKey(name),
                              style: LiquidGlassStyle(
                                shape: shape,
                                blur: blur,
                                refractionIndex: 1.022,
                                refractionWidth: 20,
                                color: const Color(0x0afffdf8),
                                specular: const LiquidGlassLight.specular(
                                  thickness: 1.5,
                                  intensity: .12,
                                  oppositeIntensity: 0,
                                ),
                                glow: const LiquidGlassLight.glow(intensity: 0),
                              ),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
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
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(
        pixelRatio: tester.view.devicePixelRatio,
      );
      final file = File(
        '${(await getTemporaryDirectory()).path}/ui-refinement/easy-glass-$name.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List(),
      );
      debugPrint('UI_REFINEMENT_CAPTURE=${file.path}');
      image.dispose();
      expect(tester.takeException(), isNull);
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'Resting glass must not keep a ticker alive.',
      );
    }
  });
}

class _Pattern extends CustomPainter {
  const _Pattern();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xffe7e5df), BlendMode.src);
    const colors = [
      Color(0xff173044),
      Color(0xffdb5471),
      Color(0xff639d83),
      Color(0xffead194),
    ];
    for (var y = 0.0; y < size.height; y += 11) {
      for (var x = 0.0; x < size.width; x += 14) {
        canvas.drawRect(
          Rect.fromLTWH(x, y, 6, 7),
          Paint()..color = colors[((x / 14).floor() + (y / 11).floor()) % 4],
        );
      }
    }
  }

  @override
  bool shouldRepaint(_Pattern oldDelegate) => false;
}
