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

  testWidgets('shared glass matches individual planes on a common live source', (
    tester,
  ) async {
    await NativeEffects.prepare();
    final capture = GlobalKey();
    for (final (blur, index) in [(0.6, 1.45), (0.0, 1.33)]) {
      for (final dark in [false, true]) {
        for (final active in [false, true]) {
          Future<(ByteData, int, Map<String, Rect>)> render(
            bool shared, {
            double shift = 0,
            String? only,
          }) async {
            await tester.pumpWidget(
              RepaintBoundary(
                key: capture,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  home: Scaffold(
                    body: NativeGlassGroup(
                      enabled: shared,
                      child: _Scene(
                        dark: dark,
                        active: active,
                        shift: shift,
                        only: only,
                        tightSampling: shared,
                        blur: blur,
                        index: index,
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final keys = <Object?>[];
            final rects = <String, Rect>{};
            for (final name in ['dock', 'back', 'settings']) {
              if (only != null && name != only) continue;
              final dynamic object = tester.renderObject(
                find.byKey(ValueKey(name)),
              );
              expect(object.debugUsesSharedGlass, shared);
              keys.add(object.debugSharedGlassKey);
              rects[name] = tester.getRect(find.byKey(ValueKey(name)));
            }
            if (shared) {
              expect(keys[0], same(keys[1]));
              expect(keys[0], same(keys[2]));
            }
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: tester.view.devicePixelRatio);
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final output = Directory(
              '${(await getTemporaryDirectory()).path}/ui-refinement',
            );
            await output.create(recursive: true);
            final path =
                '${output.path}/glass-group-${blur == 0 ? 'clear' : 'soft'}-'
                '${dark ? 'dark' : 'light'}-'
                '${active ? 'touch' : 'still'}-${shared ? 'shared' : 'reference'}-'
                '${shift == 0 ? 'stationary' : 'moving'}-${only ?? 'all'}.png';
            await File(path).writeAsBytes(
              (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!.buffer.asUint8List(),
            );
            // ignore: avoid_print
            print('UI_REFINEMENT_CAPTURE=$path');
            final width = image.width;
            image.dispose();
            return (bytes, width, rects);
          }

          ByteData? stationary;
          for (final shift in [0.0, 12.5]) {
            final (grouped, width, rects) = await render(true, shift: shift);
            if (stationary != null) {
              for (final rect in rects.values) {
                var changed = 0;
                final dpr = tester.view.devicePixelRatio;
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
                    final offset = (y * width + x) * 4;
                    if (stationary.getUint8(offset) !=
                        grouped.getUint8(offset)) {
                      changed++;
                    }
                  }
                }
                expect(
                  changed,
                  greaterThan(64),
                  reason: 'glass must keep sampling the moving source',
                );
              }
            } else {
              stationary = grouped;
            }
            final (repeat, _, _) = await render(true, shift: shift);
            var repeatMax = 0;
            var repeatSum = 0;
            for (var i = 0; i < grouped.lengthInBytes; i++) {
              final difference = (grouped.getUint8(i) - repeat.getUint8(i))
                  .abs();
              if (difference > repeatMax) repeatMax = difference;
              repeatSum += difference;
            }
            // ignore: avoid_print
            print(
              'GLASS_GROUP_REFERENCE_REPEAT max=$repeatMax mean=${repeatSum / grouped.lengthInBytes}',
            );
            expect(repeatMax, lessThanOrEqualTo(2));
            for (final name in ['dock', 'back', 'settings']) {
              // A common source excludes earlier controls. Compare each material
              // against its individual render, not a recaptured foreground stack.
              final (reference, _, _) = await render(
                false,
                shift: shift,
                only: name,
              );
              expect(reference.lengthInBytes, grouped.lengthInBytes);
              var maximum = 0;
              var sum = 0;
              var count = 0;
              final rect = rects[name]!;
              final dpr = tester.view.devicePixelRatio;
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
                  for (var c = 0; c < 4; c++) {
                    final i = (y * width + x) * 4 + c;
                    final difference =
                        (reference.getUint8(i) - grouped.getUint8(i)).abs();
                    if (difference > maximum) maximum = difference;
                    sum += difference;
                    count++;
                  }
                }
              }
              // ignore: avoid_print
              print(
                'GLASS_GROUP_PARITY plane=$name dark=$dark active=$active shift=$shift '
                'blur=$blur index=$index '
                'max_rgba_error=$maximum mean_rgba_error=${sum / count}',
              );
              expect(maximum, lessThanOrEqualTo(2));
              expect(sum / count, lessThan(.01));
            }
          }
        }
      }
    }
  });

  testWidgets(
    'overlapping glass and opacity transitions keep independent sources',
    (tester) async {
      await NativeEffects.prepare();
      for (final overlaps in [false, true]) {
        for (final opacity in [1.0, .5, 0.0]) {
          await tester.pumpWidget(
            MaterialApp(
              home: NativeGlassGroup(
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: ColoredBox(color: Colors.white),
                    ),
                    Opacity(
                      opacity: opacity,
                      child: Stack(
                        children: [
                          Positioned(left: 24, top: 50, child: _plate('one')),
                          Positioned(
                            left: overlaps ? 35 : 110,
                            top: 50,
                            child: _plate('two'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final name in ['one', 'two']) {
            final dynamic object = tester.renderObject(
              find.byKey(ValueKey(name)),
            );
            expect(object.debugUsesSharedGlass, !overlaps && opacity == 1);
          }
        }
      }
    },
  );
}

Widget _plate(
  String name, {
  bool dark = false,
  bool active = false,
  bool dock = false,
  bool tightSampling = true,
  double blur = .6,
  double index = 1.45,
}) => NativeBackdrop(
  key: ValueKey(name),
  effect: NativeEffect.glass,
  blur: blur,
  refractiveIndex: index,
  tightSampling: tightSampling,
  radius: dock ? 27 : 24,
  thickness: dock ? 16 : 20,
  activation: active ? .8 : 0,
  touchPosition: .3,
  emission: dark ? .024 : .01,
  tint: (dark ? Colors.black : Colors.white).withValues(alpha: .08),
  child: SizedBox(
    width: dock ? 196 : 46,
    height: dock ? 54 : 46,
    child: Center(
      child: Text(
        dock
            ? '上一章       1 / 13       下一章'
            : name == 'back'
            ? '‹'
            : 'AA',
        style: TextStyle(
          color: dark ? Colors.white : Colors.black,
          fontSize: 16,
        ),
      ),
    ),
  ),
);

class _Scene extends StatelessWidget {
  const _Scene({
    required this.dark,
    required this.active,
    required this.shift,
    this.only,
    this.tightSampling = true,
    this.blur = .6,
    this.index = 1.45,
  });
  final bool dark;
  final bool active;
  final double shift;
  final String? only;
  final bool tightSampling;
  final double blur;
  final double index;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: CustomPaint(painter: _Source(dark, shift))),
      Positioned(
        left: 84,
        right: 84,
        top: 61,
        child: Text(
          '今宵，骗徒们拉起光的序幕',
          maxLines: 1,
          style: TextStyle(color: dark ? Colors.white : Colors.black),
        ),
      ),
      if (only == null || only == 'back')
        Positioned(
          left: 24.17,
          top: 54.29,
          child: _plate(
            'back',
            dark: dark,
            active: active,
            tightSampling: tightSampling,
            blur: blur,
            index: index,
          ),
        ),
      if (only == null || only == 'settings')
        Positioned(
          right: 24.17,
          top: 54.29,
          child: _plate(
            'settings',
            dark: dark,
            active: active,
            tightSampling: tightSampling,
            blur: blur,
            index: index,
          ),
        ),
      if (only == null || only == 'dock')
        Positioned(
          bottom: 28.17,
          left: (MediaQuery.sizeOf(context).width - 196) / 2,
          child: _plate(
            'dock',
            dark: dark,
            active: active,
            dock: true,
            tightSampling: tightSampling,
            blur: blur,
            index: index,
          ),
        ),
    ],
  );
}

class _Source extends CustomPainter {
  const _Source(this.dark, this.shift);
  final bool dark;
  final double shift;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(
      dark ? const Color(0xff151515) : Colors.white,
      BlendMode.src,
    );
    const colors = [
      Color(0xff171717),
      Color(0xff404040),
      Color(0xff9a285f),
      Color(0xff398dbd),
      Color(0xfff0d287),
    ];
    for (var y = -7.0 + shift; y < size.height; y += 7) {
      for (var x = 0.0; x < size.width; x += 7) {
        canvas.drawRect(
          Rect.fromLTWH(x, y, 4, 5),
          Paint()
            ..color =
                colors[((x / 7).floor() + (y / 7).floor()).abs() %
                    colors.length],
        );
      }
    }
  }

  @override
  bool shouldRepaint(_Source oldDelegate) =>
      dark != oldDelegate.dark || shift != oldDelegate.shift;
}
