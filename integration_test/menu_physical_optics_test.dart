import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/native_effects.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('package menu grows from a physically circular source', (
    tester,
  ) async {
    await NativeEffects.prepare();
    final key = GlobalKey();
    final phase = AnimationController(
      vsync: tester,
      duration: NovelMotion.enter,
    );
    addTearDown(phase.dispose);
    const anchor = Rect.fromLTWH(330, 96, 46, 46);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: GlassAppearance(
            blur: 8,
            opacity: .6,
            child: Scaffold(
              backgroundColor: const Color(0xff121212),
              body: Stack(
                children: [
                  Positioned(
                    right: 24,
                    top: 96,
                    child: GlassOverlayTransition(
                      animation: phase,
                      kind: GlassOverlayKind.menu,
                      anchor: anchor,
                      child: GlassMenuSurface(
                        animation: phase,
                        anchor: anchor,
                        source: const GlassMenuSource(
                          foreground: SizedBox.shrink(),
                        ),
                        child: const SizedBox(width: 248, height: 432),
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
    for (final value in [0.0, .3, 1.0]) {
      phase.value = value;
      await tester.pumpAndSettle();
      final render = tester.renderObject<GlassMenuStretchRender>(
        find.byType(GlassMenuStretch),
      );
      final rect = render.currentRect;
      final resolved = ui.lerpDouble(
        24,
        28,
        Curves.easeOutCubic.transform(value),
      )!;
      final expected = RRect.fromRectAndRadius(
        rect,
        Radius.circular(resolved.clamp(0, rect.shortestSide / 2)),
      );
      final dpr = tester.view.devicePixelRatio;
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: dpr);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var missing = 0, excess = 0;
      for (
        var y = (rect.top * dpr).floor() - 2;
        y < (rect.bottom * dpr).ceil() + 2;
        y++
      ) {
        for (
          var x = (rect.left * dpr).floor() - 2;
          x < (rect.right * dpr).ceil() + 2;
          x++
        ) {
          if (x < 0 || y < 0 || x >= image.width || y >= image.height) continue;
          final point = Offset((x + .5) / dpr, (y + .5) / dpr);
          final lit = bytes.getUint8((y * image.width + x) * 4) > 65;
          if (expected.deflate(2 / dpr).contains(point) && !lit) missing++;
          if (!expected.inflate(2 / dpr).contains(point) && lit) excess++;
        }
      }
      image.dispose();
      expect(
        missing,
        0,
        reason:
            'The physical menu silhouette must stay filled at phase $value.',
      );
      expect(
        excess,
        0,
        reason:
            'The source must not turn into a stretched square at phase $value.',
      );
    }
    expect(tester.takeException(), isNull);
  });
}
