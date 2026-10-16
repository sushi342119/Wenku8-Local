import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/native_effects.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('continuous native GPU scroll edge works away from the screen origin', (
    tester,
  ) async {
    await NativeEffects.prepare();
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const Positioned.fill(child: CustomPaint(painter: _Stripes())),
                const Positioned(
                  key: ValueKey('blur-probe'),
                  top: 90,
                  left: 20,
                  width: 200,
                  height: 240,
                  child: ProgressiveBlur(maxSigma: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dpr = tester.view.devicePixelRatio;
    final rect = tester.getRect(find.byKey(const ValueKey('blur-probe')));
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: dpr);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final upper = _contrast(
      bytes,
      image.width,
      dpr,
      rect.top + 30,
      left: rect.left + 30,
    );
    final middle = _contrast(
      bytes,
      image.width,
      dpr,
      rect.top + 150,
      left: rect.left + 30,
    );
    final lower = _contrast(
      bytes,
      image.width,
      dpr,
      rect.top + 233,
      left: rect.left + 30,
    );
    // ignore: avoid_print
    print(
      'SCROLL_EDGE_GAUSSIAN top_contrast=$upper middle_contrast=$middle bottom_contrast=$lower',
    );
    expect(upper, lessThan(80));
    var average = 0.0;
    var count = 0;
    final upperY = ((rect.top + 30) * dpr).floor();
    for (
      var x = ((rect.left + 30) * dpr).ceil();
      x < ((rect.left + 170) * dpr).floor();
      x++
    ) {
      average += bytes.getUint8((upperY * image.width + x) * 4);
      count++;
    }
    average /= count;
    // A 50/50 black-white signal averages to half linear light, roughly 188
    // sRGB levels, not the dim 128 produced by gamma-space convolution.
    // ignore: avoid_print
    print('LINEAR_LIGHT_BLUR upper_average=$average');
    expect(average, inInclusiveRange(177, 198));
    expect(middle, greaterThan(upper + 20));
    expect(middle, lessThan(lower - 20));
    expect(lower, greaterThan(150));
    var previous = _contrast(
      bytes,
      image.width,
      dpr,
      rect.top + 1,
      left: rect.left + 30,
    );
    var biggestJump = 0;
    var changingRows = 0;
    for (
      var y = ((rect.top + 2) * dpr).ceil();
      y < ((rect.bottom - 2) * dpr).floor();
      y++
    ) {
      final value = _contrast(
        bytes,
        image.width,
        dpr,
        y / dpr,
        left: rect.left + 30,
      );
      final jump = (value - previous).abs();
      if (jump > biggestJump) biggestJump = jump;
      if (jump > 0) changingRows++;
      previous = value;
    }
    // Reject horizontal radius bands, not merely "top more blurred than bottom".
    // ignore: avoid_print
    print(
      'CONTINUOUS_BLUR max_adjacent_row_jump=$biggestJump changing_rows=$changingRows',
    );
    expect(biggestJump, lessThanOrEqualTo(8));
    expect(changingRows, greaterThan(60));
    image.dispose();
  });

  testWidgets('status region is fully blurred and dock underlay stays subtle', (
    tester,
  ) async {
    await NativeEffects.prepare();
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const Positioned.fill(child: CustomPaint(painter: _Stripes())),
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: FrostedHeader(child: SizedBox()),
                ),
                const Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: DockUnderlay(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final dpr = tester.view.devicePixelRatio;
    final image = await boundary.toImage(pixelRatio: dpr);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final header = tester.getRect(find.byType(FrostedHeader));
    final bottom = tester.getRect(find.byType(DockUnderlay));
    final status = _contrast(bytes, image.width, dpr, 8);
    // ignore: avoid_print
    print(
      'HEADER_RECT=$header DPR=$dpr STATUS_PADDING=${tester.view.viewPadding.top}',
    );
    // ignore: avoid_print
    print(
      'HEADER_SCAN=${[0.0, 4.0, 8.0, 16.0, 24.0, 36.0, 48.0, 64.0, 80.0].map((y) => '$y:${_contrast(bytes, image.width, dpr, y)}').join(',')}',
    );
    final clear = _contrast(bytes, image.width, dpr, header.bottom + 12);
    final gentle = _contrast(bytes, image.width, dpr, bottom.bottom - 12);
    // ignore: avoid_print
    print('SCROLL_EDGE_REGIONS status=$status clear=$clear dock=$gentle');
    expect(status, lessThan(20));
    expect(_contrast(bytes, image.width, dpr, 0), lessThan(20));
    expect(clear, greaterThan(200));
    expect(gentle, greaterThan(status + 30));
    expect(gentle, lessThan(clear - 10));
    image.dispose();
  });

  testWidgets('raising header blur never darkens a uniform white backdrop', (
    tester,
  ) async {
    await NativeEffects.prepare();
    final capture = GlobalKey();
    final minimums = <int>[];
    for (final sigma in [0.0, 8.0, 24.0]) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              backgroundColor: Colors.white,
              body: GlassAppearance(
                blur: sigma,
                opacity: 0,
                child: const Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: FrostedHeader(child: SizedBox()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dpr = tester.view.devicePixelRatio;
      final rect = tester.getRect(find.byType(FrostedHeader));
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: dpr);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var minimum = 255;
      var minimumY = 0;
      var minimumX = 0;
      for (var y = 0; y < (rect.bottom * dpr).floor(); y++) {
        for (final fraction in [.1, .3, .5, .7, .9]) {
          final x = (image.width * fraction).floor();
          final value = bytes.getUint8((y * image.width + x) * 4);
          if (value < minimum) {
            minimum = value;
            minimumY = y;
            minimumX = x;
          }
        }
      }
      // ignore: avoid_print
      print(
        'HEADER_WHITE_PRESERVATION sigma=$sigma minimum=$minimum x=$minimumX y=$minimumY',
      );
      minimums.add(minimum);
      image.dispose();
    }
    expect(minimums, everyElement(greaterThanOrEqualTo(253)));
  });

  testWidgets(
    'header blur samples nearby content without pulling up distant rows',
    (tester) async {
      await NativeEffects.prepare();
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              backgroundColor: Colors.white,
              body: GlassAppearance(
                blur: 24,
                opacity: 0,
                child: Stack(
                  children: [
                    const Positioned(
                      top: 180,
                      left: 0,
                      right: 0,
                      height: 20,
                      child: ColoredBox(color: Colors.black),
                    ),
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: FrostedHeader(child: SizedBox()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byType(FrostedHeader));
      final dpr = tester.view.devicePixelRatio;
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: dpr);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var minimum = 255;
      var minimumY = 0;
      final x = (image.width * .5).floor();
      for (var y = 0; y < (rect.bottom * dpr).floor(); y++) {
        final value = bytes.getUint8((y * image.width + x) * 4);
        if (value < minimum) {
          minimum = value;
          minimumY = y;
        }
      }
      // ignore: avoid_print
      print(
        'HEADER_SOURCE_MAPPING minimum=$minimum y=$minimumY distant_band=180dp',
      );
      expect(minimum, greaterThanOrEqualTo(250));
      image.dispose();
    },
  );

  testWidgets('linear-light blur preserves dark tones without quantized bands', (
    tester,
  ) async {
    await NativeEffects.prepare();
    final capture = GlobalKey();
    for (final level in [16, 23, 32, 64]) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              backgroundColor: Color.fromARGB(255, level, level, level),
              body: const GlassAppearance(
                blur: 24,
                opacity: 0,
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: FrostedHeader(child: SizedBox()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byType(FrostedHeader));
      final dpr = tester.view.devicePixelRatio;
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: dpr);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var minimum = 255;
      var maximum = 0;
      final x = (image.width * .5).floor();
      for (var y = 0; y < (rect.bottom * dpr).floor(); y++) {
        final value = bytes.getUint8((y * image.width + x) * 4);
        if (value < minimum) minimum = value;
        if (value > maximum) maximum = value;
      }
      // ignore: avoid_print
      print(
        'DARK_TONE_PRESERVATION input=$level minimum=$minimum maximum=$maximum',
      );
      expect(minimum, greaterThanOrEqualTo(level - 1));
      expect(maximum, lessThanOrEqualTo(level + 1));
      image.dispose();
    }
  });
}

int _contrast(
  ByteData bytes,
  int width,
  double dpr,
  double y, {
  double left = 40,
}) {
  var minimum = 255;
  var maximum = 0;
  for (var x = (left * dpr).ceil(); x < ((left + 140) * dpr).floor(); x++) {
    final value = bytes.getUint8(((y * dpr).floor() * width + x) * 4);
    if (value < minimum) minimum = value;
    if (value > maximum) maximum = value;
  }
  return maximum - minimum;
}

class _Stripes extends CustomPainter {
  const _Stripes();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.white, BlendMode.src);
    for (var x = 0.0; x < size.width; x += 12) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 6, size.height),
        Paint()..color = Colors.black,
      );
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => false;
}
