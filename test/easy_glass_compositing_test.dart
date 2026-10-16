import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/easy_glass.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/native_effects.dart';

EasyGlassSurface _glass(Widget child) => EasyGlassSurface(
  radius: 24,
  thickness: 20,
  blur: 8,
  refractiveIndex: 1.45,
  tint: const Color(0xddfffdf8),
  emission: .01,
  activation: 0,
  child: child,
);

void main() {
  testWidgets('sheet buttons share the finished parent glass, not its input', (
    tester,
  ) async {
    int? page, first, second, foreground;
    await tester.pumpWidget(
      MaterialApp(
        home: LiquidGlassBatch(
          child: Builder(
            builder: (context) {
              page = LiquidGlassBatch.backdropIdOf(context);
              return Center(
                child: _glass(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Builder(
                        builder: (context) {
                          first = LiquidGlassBatch.backdropIdOf(context);
                          return _glass(
                            Builder(
                              builder: (context) {
                                foreground = LiquidGlassBatch.backdropIdOf(
                                  context,
                                );
                                return const Text('播放');
                              },
                            ),
                          );
                        },
                      ),
                      Builder(
                        builder: (context) {
                          second = LiquidGlassBatch.backdropIdOf(context);
                          return _glass(const Text('下一段'));
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(first, isNotNull);
    expect(second, first);
    expect(first, isNot(page));
    expect(foreground, isNot(first));
    expect(find.byType(LiquidGlassLens), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('opposite scroll edges stay off the page glass batch', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LiquidGlassBatch(
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Colors.white)),
              for (final bottom in [false, true])
                Positioned(
                  top: bottom ? null : 0,
                  bottom: bottom ? 0 : null,
                  left: 0,
                  right: 0,
                  height: 100,
                  child: NativeBackdrop(
                    effect: NativeEffect.progressive,
                    blur: 8,
                    plateau: 20,
                    fromBottom: bottom,
                    child: const SizedBox.expand(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final edges = find.byType(LiquidGlassScrollEdge);
    expect(edges, findsNWidgets(2));
    for (final element in edges.evaluate()) {
      expect(LiquidGlassBatch.backdropIdOf(element), isNull);
    }
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'opacity defaults to 87 percent without replacing a saved choice',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fresh = await LibraryState.load();
      expect(fresh.glassOpacity, .87);
      await fresh.setGlassOpacity(.42);
      fresh.dispose();
      final restored = await LibraryState.load();
      expect(restored.glassOpacity, .42);
      restored.dispose();
    },
  );
}
