import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('dead-output culling preserves blur and active glass optics', (
    tester,
  ) async {
    await NativeEffects.prepare();
    final capture = GlobalKey();
    for (final effect in [NativeEffect.glass, NativeEffect.progressive]) {
      for (final (sigma, kernelName) in const [
        (1.05, 'small'),
        (1.4, 'boundary'),
        (3.4, 'strong'),
        (19.5, 'wide'),
      ]) {
        for (final activation
            in effect == NativeEffect.glass ? [0.0, .8] : [0.0]) {
          Future<(ByteData, ui.Rect, int, int)> render(bool compact) async {
            await tester.pumpWidget(
              RepaintBoundary(
                key: capture,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  home: Scaffold(
                    body: Stack(
                      children: [
                        const Positioned.fill(
                          child: CustomPaint(painter: _Source()),
                        ),
                        Positioned(
                          left: 76.17,
                          top: 150.29,
                          child: NativeBackdrop(
                            key: ValueKey(compact),
                            effect: effect,
                            radius: 27,
                            thickness: 16,
                            blur: sigma / tester.view.devicePixelRatio,
                            activation: activation,
                            touchPosition: .3,
                            emission: .024,
                            tint: Colors.transparent,
                            cullUnusedPixels: compact,
                            child: const SizedBox(width: 196, height: 54),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final rect = tester.getRect(find.byKey(ValueKey(compact)));
            final dynamic object = tester.renderObject(
              find.byKey(ValueKey(compact)),
            );
            expect(object.debugPixelCulling, compact ? greaterThan(0) : 0);
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: tester.view.devicePixelRatio);
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final width = image.width;
            final height = image.height;
            final output = Directory(
              '${(await getTemporaryDirectory()).path}/ui-refinement',
            );
            await output.create(recursive: true);
            final path =
                '${output.path}/culling-${effect.name}-${compact ? 'optimized' : 'reference'}-$kernelName-${activation == 0 ? 'still' : 'touch'}.png';
            await File(path).writeAsBytes(
              (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!.buffer.asUint8List(),
            );
            // ignore: avoid_print
            print('UI_REFINEMENT_CAPTURE=$path');
            image.dispose();
            return (bytes, rect, width, height);
          }

          final (before, rect, width, height) = await render(false);
          final (after, _, newWidth, newHeight) = await render(true);
          expect((newWidth, newHeight), (width, height));
          final dpr = tester.view.devicePixelRatio;
          var maximum = 0;
          var total = 0;
          var count = 0;
          var worst = '';
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
              for (var c = 0; c < 3; c++) {
                final i = (y * width + x) * 4 + c;
                final difference = (before.getUint8(i) - after.getUint8(i))
                    .abs();
                if (difference > maximum) {
                  maximum = difference;
                  worst =
                      '$x,$y channel=$c before=${before.getUint8(i)} after=${after.getUint8(i)}';
                }
                total += difference;
                count++;
              }
            }
          }
          // ignore: avoid_print
          print(
            'GLASS_CULL_PARITY effect=${effect.name} sigma=$sigma activation=$activation max_rgb_error=$maximum mean_rgb_error=${total / count} worst=$worst',
          );
          expect(maximum, lessThanOrEqualTo(2));
          expect(total / count, lessThan(.15));
        }
      }
    }
  });
}

class _Source extends CustomPainter {
  const _Source();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.white, BlendMode.src);
    const colors = [
      Color(0xff171717),
      Color(0xff404040),
      Color(0xff9a285f),
      Color(0xff398dbd),
      Color(0xfff0d287),
    ];
    for (var y = 0.0; y < size.height; y += 7) {
      for (var x = 0.0; x < size.width; x += 7) {
        final color =
            colors[((x / 7).floor() + (y / 7).floor()) % colors.length];
        canvas.drawRect(Rect.fromLTWH(x, y, 4, 5), Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(_Source oldDelegate) => false;
}
