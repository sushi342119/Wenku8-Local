import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/native_effects.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final sheet in [false, true]) {
    for (final wide in [false, true]) {
      final name = '${sheet ? 'sheet' : 'menu'}-${wide ? 'wide' : 'small'}';
      testWidgets('actual popup $name aligns shader silhouette with layout', (
        tester,
      ) async {
        await NativeEffects.prepare();
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: novelTheme(Brightness.light),
              home: GlassAppearance(
                blur: wide ? 8 : .4,
                opacity: .6,
                child: Scaffold(
                  backgroundColor: const Color(0xff121212),
                  body: Stack(
                    children: [
                      Positioned(
                        right: 24,
                        top: 140,
                        child: GlassMenuAnchor(
                          child: Builder(
                            builder: (context) => GestureDetector(
                              key: const ValueKey('open-popup'),
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                Widget builder(BuildContext context) =>
                                    const SizedBox(height: 180);
                                if (sheet) {
                                  showJellySheet<void>(
                                    context: context,
                                    reduceMotion: true,
                                    builder: builder,
                                  );
                                } else {
                                  showGlassMenu<void>(
                                    context: context,
                                    reduceMotion: true,
                                    builder: builder,
                                  );
                                }
                              },
                              child: const SizedBox(width: 46, height: 46),
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
        await tester.tap(find.byKey(const ValueKey('open-popup')));
        await tester.pumpAndSettle();
        final native = find.descendant(
          of: find.byType(GlassOverlaySurface),
          matching: find.byType(NativeBackdrop),
        );
        final rect = tester.getRect(native);
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: tester.view.devicePixelRatio);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final dpr = tester.view.devicePixelRatio;
        final y = (rect.center.dy * dpr).floor();
        final xCenter = (rect.center.dx * dpr).floor();
        final lit = <int>[];
        for (var x = 0; x < image.width; x++) {
          if (bytes.getUint8((y * image.width + x) * 4) > 65) lit.add(x);
        }
        final vertical = <int>[];
        for (var y = 0; y < image.height; y++) {
          if (bytes.getUint8((y * image.width + xCenter) * 4) > 65) {
            vertical.add(y);
          }
        }
        final output = Directory('${Directory.systemTemp.path}/ui-refinement');
        await output.create(recursive: true);
        final file = File('${output.path}/popup-alignment-$name.png');
        await file.writeAsBytes(
          (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List(),
        );
        image.dispose();
        // ignore: avoid_print
        print('UI_REFINEMENT_CAPTURE=${file.path}');
        // ignore: avoid_print
        print(
          'POPUP_ALIGNMENT $name layout=$rect lit=${lit.isEmpty ? 'empty' : '${lit.first / dpr}..${(lit.last + 1) / dpr}'}',
        );
        expect(lit, isNotEmpty);
        expect(lit.first / dpr, closeTo(rect.left, 2));
        expect((lit.last + 1) / dpr, closeTo(rect.right, 2));
        expect(vertical, isNotEmpty);
        expect(vertical.first / dpr, closeTo(rect.top, 2));
        expect((vertical.last + 1) / dpr, closeTo(rect.bottom, 2));
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'composed glass sampling matches the native Gaussian without inferred snapshot padding',
    (tester) async {
      await NativeEffects.prepare();
      final capture = GlobalKey();
      final dpr = tester.view.devicePixelRatio;
      Future<(ui.Image, Rect)> render(bool glass) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              home: Scaffold(
                body: Stack(
                  children: [
                    const Positioned.fill(
                      child: CustomPaint(painter: _RampBackdrop()),
                    ),
                    Positioned(
                      left: 76,
                      top: 150,
                      child: glass
                          ? const NativeBackdrop(
                              effect: NativeEffect.glass,
                              blur: 8,
                              preserveOptics: true,
                              radius: 0,
                              thickness: 0,
                              refractiveIndex: 1,
                              child: SizedBox(width: 196, height: 180),
                            )
                          : ClipRect(
                              child: BackdropFilter(
                                filter: ui.ImageFilter.blur(
                                  sigmaX: 8 * dpr,
                                  sigmaY: 8 * dpr,
                                  tileMode: ui.TileMode.clamp,
                                ),
                                child: const SizedBox(width: 196, height: 180),
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
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: dpr);
        return (image, const Rect.fromLTWH(76, 150, 196, 180));
      }

      final (reference, rect) = await render(false);
      final (glass, _) = await render(true);
      final before = (await reference.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final after = (await glass.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var maximum = 0;
      var total = 0;
      var count = 0;
      for (
        var y = ((rect.top + 30) * dpr).ceil();
        y < ((rect.bottom - 30) * dpr).floor();
        y++
      ) {
        for (
          var x = ((rect.left + 30) * dpr).ceil();
          x < ((rect.right - 30) * dpr).floor();
          x++
        ) {
          for (var channel = 0; channel < 3; channel++) {
            final index = (y * glass.width + x) * 4 + channel;
            final difference = (before.getUint8(index) - after.getUint8(index))
                .abs();
            if (difference > maximum) maximum = difference;
            total += difference;
            count++;
          }
        }
      }
      reference.dispose();
      glass.dispose();
      // ignore: avoid_print
      print(
        'POPUP_SAMPLING max_rgb_error=$maximum mean_rgb_error=${total / count}',
      );
      expect(maximum, lessThanOrEqualTo(3));
      expect(total / count, lessThan(.5));
    },
  );
  for (final sheet in [false, true]) {
    for (final scale in [1.0, .8]) {
      final name =
          'nested-${sheet ? 'sheet' : 'menu'}-${scale == 1 ? 'full' : 'scaled'}';
      testWidgets(
        'actual $name keeps layout, sampling and visible bounds aligned',
        (tester) async {
          await NativeEffects.prepare();
          final capture = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                theme: novelTheme(Brightness.light),
                debugShowCheckedModeBanner: false,
                home: GlassAppearance(
                  blur: 8,
                  opacity: .6,
                  child: LayoutBuilder(
                    builder: (context, constraints) => Stack(
                      children: [
                        const Positioned.fill(
                          child: ColoredBox(color: Color(0xff121212)),
                        ),
                        Positioned(
                          left: 24,
                          top: 80,
                          width: constraints.maxWidth - 48,
                          height: constraints.maxHeight - 160,
                          child: Transform.scale(
                            scale: scale,
                            alignment: Alignment.topLeft,
                            child: Navigator(
                              onGenerateRoute: (_) => MaterialPageRoute<void>(
                                builder: (context) => Scaffold(
                                  backgroundColor: const Color(0xff121212),
                                  body: Stack(
                                    children: [
                                      Positioned(
                                        right: 24,
                                        top: 72,
                                        child: GlassMenuAnchor(
                                          child: Builder(
                                            builder: (context) =>
                                                GestureDetector(
                                                  key: const ValueKey(
                                                    'nested-popup-trigger',
                                                  ),
                                                  behavior:
                                                      HitTestBehavior.opaque,
                                                  onTap: () {
                                                    Widget content(
                                                      BuildContext context,
                                                    ) => const SizedBox(
                                                      height: 180,
                                                    );
                                                    if (sheet) {
                                                      showJellySheet<void>(
                                                        context: context,
                                                        reduceMotion: true,
                                                        builder: content,
                                                      );
                                                    } else {
                                                      showGlassMenu<void>(
                                                        context: context,
                                                        reduceMotion: true,
                                                        builder: content,
                                                      );
                                                    }
                                                  },
                                                  child: const SizedBox(
                                                    width: 46,
                                                    height: 46,
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
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final trigger = tester.getRect(
            find.byKey(const ValueKey('nested-popup-trigger')),
          );
          await tester.tap(find.byKey(const ValueKey('nested-popup-trigger')));
          await tester.pumpAndSettle();
          final rect = tester.getRect(find.byType(GlassOverlaySurface));
          if (!sheet) {
            expect(rect.right, closeTo(trigger.right, .001));
            expect(rect.top, closeTo(trigger.top, .001));
          }
          final dpr = tester.view.devicePixelRatio;
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: dpr);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final y = (rect.center.dy * dpr).floor();
          final x = (rect.center.dx * dpr).floor();
          final horizontal = <int>[];
          final vertical = <int>[];
          for (var column = 0; column < image.width; column++) {
            if (bytes.getUint8((y * image.width + column) * 4) > 65) {
              horizontal.add(column);
            }
          }
          for (var row = 0; row < image.height; row++) {
            if (bytes.getUint8((row * image.width + x) * 4) > 65) {
              vertical.add(row);
            }
          }
          final directory = Directory(
            '${Directory.systemTemp.path}/ui-refinement',
          );
          await directory.create(recursive: true);
          final file = File('${directory.path}/popup-alignment-$name.png');
          await file.writeAsBytes(
            (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!.buffer.asUint8List(),
          );
          image.dispose();
          // ignore: avoid_print
          print('UI_REFINEMENT_CAPTURE=${file.path}');
          expect(horizontal, isNotEmpty);
          expect(vertical, isNotEmpty);
          final pixels = Rect.fromLTRB(
            horizontal.first / dpr,
            vertical.first / dpr,
            (horizontal.last + 1) / dpr,
            (vertical.last + 1) / dpr,
          );
          // ignore: avoid_print
          print('POPUP_ALIGNMENT $name layout=$rect pixels=$pixels');
          expect(pixels.left, closeTo(rect.left, 2));
          expect(pixels.right, closeTo(rect.right, 2));
          expect(pixels.top, closeTo(rect.top, 2));
          expect(pixels.bottom, closeTo(rect.bottom, 2));
        },
      );
    }
  }
}

class _RampBackdrop extends CustomPainter {
  const _RampBackdrop();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.black, BlendMode.src);
    for (var y = 0.0; y < size.height; y += 1) {
      canvas.drawRect(
        Rect.fromLTWH(0, y, size.width, 1),
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, y), Offset(size.width, y), [
            Color.fromARGB(255, 30, (y / size.height * 180).round(), 200),
            Color.fromARGB(255, 220, (y / size.height * 180).round(), 40),
          ]),
      );
    }
  }

  @override
  bool shouldRepaint(_RampBackdrop oldDelegate) => false;
}
