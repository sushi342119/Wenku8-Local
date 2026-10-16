import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/glass_optics.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/pages.dart';

void main() {
  test(
    'initial glass strength is lighter and saved choices are retained',
    () async {
      SharedPreferences.setMockInitialValues({});
      expect((await LibraryState.load()).glassBlur, 8);
      SharedPreferences.setMockInitialValues({'glassBlur': 18.0});
      expect((await LibraryState.load()).glassBlur, 18);
    },
  );
  testWidgets(
    'startup waits for real viewport before creating glass textures',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      tester.view.physicalSize = Size.zero;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        NovelApp(state: state, repository: const DemoNovelRepository()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HomeShell), findsNothing);
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(1080, 2400);
      await tester.pumpAndSettle();
      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byKey(const ValueKey('liquid-dock')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'glass preferences clamp, preview without I/O, then persist on release',
    () async {
      SharedPreferences.setMockInitialValues({
        'glassBlur': 40.0,
        'glassOpacity': -1.0,
      });
      final state = await LibraryState.load();
      expect(state.glassBlur, 24);
      expect(state.glassOpacity, 0);
      await state.setGlassBlur(12, persist: false);
      await state.setGlassOpacity(.35, persist: false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('glassBlur'), 40);
      expect(prefs.getDouble('glassOpacity'), -1);
      // End-of-drag must save even though preview already set the same value.
      await state.setGlassBlur(12);
      await state.setGlassOpacity(.35);
      final restored = await LibraryState.load();
      expect(restored.glassBlur, 12);
      expect(restored.glassOpacity, .35);
    },
  );

  testWidgets('status inset is blurred and header uses compact safe controls', (
    tester,
  ) async {
    tester.view.viewPadding = const FakeViewPadding(top: 96);
    addTearDown(tester.view.resetViewPadding);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(padding: EdgeInsets.zero),
            child: GlassAppearance(
              blur: 18,
              child: FrostedHeader(
                child: SizedBox(key: const ValueKey('header-controls')),
              ),
            ),
          ),
        ),
      ),
    );
    final physicalTop = 96 / tester.view.devicePixelRatio;
    final plane = tester.getRect(
      find.byKey(const ValueKey('frosted-navigation-plane')),
    );
    expect(plane.top, 0);
    expect(plane.height, physicalTop + 56 + 56);
    expect(
      tester.getRect(find.byKey(const ValueKey('header-controls'))).top,
      physicalTop,
    );
    final blur = tester.widget<ProgressiveBlur>(find.byType(ProgressiveBlur));
    expect(blur.plateauHeight, physicalTop);
    expect(blur.maxSigma, 18);
  });

  testWidgets(
    'clear controls skip optical blur while page and overlay blur follow settings',
    (tester) async {
      for (final strength in [0.0, 8.0, 18.0, 24.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: GlassAppearance(
              blur: strength,
              child: Column(
                children: [
                  const LiquidGlass(child: SizedBox(width: 160, height: 60)),
                  const GlassOverlaySurface(
                    child: SizedBox(width: 180, height: 120),
                  ),
                  SizedBox(
                    width: 200,
                    height: 80,
                    child: ProgressiveBlur(maxSigma: strength),
                  ),
                ],
              ),
            ),
          ),
        );
        final backdrop = tester.widget<NativeBackdrop>(
          find.descendant(
            of: find.byType(LiquidGlass).first,
            matching: find.byType(NativeBackdrop),
          ),
        );
        expect(backdrop.blur, 0);
        final overlay = tester.widget<NativeBackdrop>(
          find.descendant(
            of: find.byType(GlassOverlaySurface),
            matching: find.byType(NativeBackdrop),
          ),
        );
        expect(overlay.blur, strength.clamp(0, 12));
        expect(
          tester.widget<ProgressiveBlur>(find.byType(ProgressiveBlur)).maxSigma,
          strength,
        );
      }
    },
  );

  testWidgets('header adds neither a tint gradient nor a control shadow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassAppearance(
            opacity: 1,
            child: FrostedHeader(
              child: GlassIconButton(
                icon: CupertinoIcons.search,
                label: '搜索',
                onPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    final header = find.byType(FrostedHeader);
    expect(
      find.descendant(
        of: header,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).backgroundBlendMode !=
                  BlendMode.dstIn &&
              ((widget.decoration as BoxDecoration).gradient?.colors.any(
                    (c) => c.a > 0,
                  ) ??
                  false),
        ),
      ),
      findsNothing,
    );
    expect(
      tester.widget<LiquidGlass>(find.byType(LiquidGlass)).elevated,
      isFalse,
    );
  });

  testWidgets(
    'all controls share milk tint without extra blur or changed transparency',
    (tester) async {
      for (final brightness in Brightness.values) {
        final theme = novelTheme(brightness);
        for (final opacity in [0.0, .08, .3, 1.0]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: GlassAppearance(
                opacity: opacity,
                blur: 18,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GlassPillButton(
                        icon: CupertinoIcons.book,
                        label: '继续阅读',
                        onPressed: () {},
                      ),
                      GlassIconButton(
                        icon: CupertinoIcons.back,
                        label: '返回',
                        onPressed: () {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final pill = tester.widget<NativeBackdrop>(
            find.descendant(
              of: find.byType(GlassPillButton),
              matching: find.byType(NativeBackdrop),
            ),
          );
          final expected = ArchiveDesign.glassTint(
            brightness,
            opacity: opacity,
          );
          expect(pill.tint, expected.withValues(alpha: opacity));
          expect(pill.tint.a, opacity);
          if (brightness == Brightness.dark && opacity == 1) {
            expect(pill.tint.computeLuminance(), lessThan(.05));
          }
          expect(pill.blur, 0);
          expect(
            tester.getSize(find.byType(GlassPillButton)),
            const Size(196, 54),
          );
          final chrome = tester.widget<NativeBackdrop>(
            find.descendant(
              of: find.byType(GlassIconButton),
              matching: find.byType(NativeBackdrop),
            ),
          );
          expect(chrome.tint, expected.withValues(alpha: opacity));
          expect(pill.emission, brightness == Brightness.dark ? .024 : .010);
          expect(chrome.emission, pill.emission);
        }
      }
    },
  );

  testWidgets('read action keeps the opaque high-contrast surface unchanged', (
    tester,
  ) async {
    final theme = novelTheme(Brightness.dark);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: MediaQuery(
          data: const MediaQueryData(highContrast: true),
          child: GlassAppearance(
            opacity: .3,
            child: Center(
              child: GlassPillButton(
                icon: CupertinoIcons.book,
                label: '继续阅读',
                onPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    final backdrop = tester.widget<NativeBackdrop>(find.byType(NativeBackdrop));
    expect(backdrop.tint, theme.colorScheme.surface);
    expect(backdrop.blur, 0);
    expect(backdrop.thickness, 0);
  });

  testWidgets(
    'settings change shared material live and dock underlay stays light',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      await tester.pumpWidget(
        NovelApp(state: state, repository: const DemoNovelRepository()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      final blurFinder = find.byKey(const ValueKey('glass-blur-slider'));
      await tester.scrollUntilVisible(
        blurFinder,
        180,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('settings')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      final slider = tester.widget<CupertinoSlider>(blurFinder);
      slider.onChanged!(8);
      slider.onChangeEnd!(8);
      await tester.pumpAndSettle();
      final opacitySlider = tester.widget<CupertinoSlider>(
        find.byKey(const ValueKey('glass-opacity-slider')),
      );
      opacitySlider.onChanged!(.42);
      opacitySlider.onChangeEnd!(.42);
      await tester.pumpAndSettle();
      expect(state.glassBlur, 8);
      expect(state.glassOpacity, .42);
      final appearance = GlassAppearance.of(
        tester.element(find.byKey(const ValueKey('liquid-dock'))),
      );
      expect(appearance.blur, 8);
      expect(appearance.opacity, .42);
      final underlay = tester.widget<ProgressiveBlur>(
        find.descendant(
          of: find.byType(DockUnderlay),
          matching: find.byType(ProgressiveBlur),
        ),
      );
      expect(underlay.maxSigma, closeTo(1.28, .01));
      expect(underlay.fromBottom, isTrue);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is GlassReflectionPainter,
        ),
        findsNothing,
      );
      // Decorative scroll blur must not consume navigation taps.
      await tester.tap(find.text('发现').last);
      await tester.pumpAndSettle();
      expect(find.text('最近更新'), findsOneWidget);
    },
  );
}
