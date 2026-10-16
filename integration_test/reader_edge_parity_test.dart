import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/reader_chrome.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'retained reader plane preserves both existing continuous blur regions',
    (tester) async {
      await NativeEffects.prepare();
      expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
      final boundary = GlobalKey();
      for (final dark in [false, true]) {
        for (final (blur, label) in const [
          (1.2, 'small'),
          (8.0, 'normal'),
          (18.0, 'large'),
          (24.0, 'maximum'),
        ]) {
          final top = tester.view.padding.top / tester.view.devicePixelRatio;
          final bottom =
              tester.view.viewPadding.bottom / tester.view.devicePixelRatio;
          final topHeight = top + 112;
          final bottomHeight = bottom + 52;
          final bottomBlur = math.min(3.0, blur * .16);
          Future<(ByteData, int, int)> capture(bool shared) async {
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  home: GlassAppearance(
                    blur: blur,
                    opacity: .84,
                    child: Scaffold(
                      body: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(painter: _Source(dark)),
                          ),
                          if (shared)
                            const Positioned.fill(child: ReaderEdgeBlur())
                          else ...[
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              height: topHeight,
                              child: NativeBackdrop(
                                effect: NativeEffect.progressive,
                                blur: blur,
                                plateau: top,
                                child: const SizedBox.expand(),
                              ),
                            ),
                            Positioned(
                              bottom: 0,
                              left: 0,
                              right: 0,
                              height: bottomHeight,
                              child: NativeBackdrop(
                                effect: NativeEffect.progressive,
                                blur: bottomBlur,
                                plateau: bottom,
                                fromBottom: true,
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.byType(NativeBackdrop), findsNWidgets(2));
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: tester.view.devicePixelRatio);
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final directory = Directory(
              '${Directory.systemTemp.path}/ui-refinement',
            );
            await directory.create(recursive: true);
            final path =
                '${directory.path}/edge-${dark ? 'dark' : 'light'}-$label-${shared ? 'retained' : 'separate'}.png';
            await File(path).writeAsBytes(
              (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!.buffer.asUint8List(),
            );
            // ignore: avoid_print
            print('UI_REFINEMENT_CAPTURE=$path');
            final size = (image.width, image.height);
            image.dispose();
            return (bytes, size.$1, size.$2);
          }

          final (before, width, height) = await capture(false);
          final (after, nextWidth, nextHeight) = await capture(true);
          expect((width, height), (nextWidth, nextHeight));
          var maximum = 0;
          var total = 0;
          for (var i = 0; i < before.lengthInBytes; i += 4) {
            for (var c = 0; c < 3; c++) {
              final error = (before.getUint8(i + c) - after.getUint8(i + c))
                  .abs();
              maximum = math.max(maximum, error);
              total += error;
            }
          }
          final mean = total / (width * height * 3);
          // ignore: avoid_print
          print(
            'READER_EDGE_PARITY dark=$dark blur=$blur max_rgb=$maximum mean_rgb=$mean',
          );
          expect(maximum, lessThanOrEqualTo(2));
          expect(mean, lessThan(.02));
        }
      }
    },
  );
}

class _Source extends CustomPainter {
  const _Source(this.dark);
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(
      dark ? const Color(0xff171717) : Colors.white,
      BlendMode.src,
    );
    final text = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: '阅读器上下连续滚动 · ABC 123 😀',
        style: TextStyle(
          fontSize: 18,
          color: dark ? const Color(0xffe8e8e8) : const Color(0xff171717),
        ),
      ),
    );
    text.layout(maxWidth: size.width - 32);
    for (var y = 0.0; y < size.height; y += 31) {
      final paint = Paint()
        ..color = y % 62 == 0
            ? const Color(0xff287293)
            : const Color(0xff984273);
      canvas.drawRect(Rect.fromLTWH(0, y + 17, size.width, 3), paint);
      text.paint(canvas, Offset(16, y));
    }
    text.dispose();
  }

  @override
  bool shouldRepaint(covariant _Source oldDelegate) => dark != oldDelegate.dark;
}
