import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/pages.dart';

Finder _control(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (w) => w is GlassIconButton && w.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;

void main() {
  testWidgets('120 menu paint samples never rebuild or relayout its contents', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AnimationController(
      vsync: tester,
      duration: NovelMotion.enter,
    );
    addTearDown(controller.dispose);
    var builds = 0;
    final paintCounter = _PaintCounter();
    const anchor = Rect.fromLTWH(330, 96, 46, 46);
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              right: 24,
              top: 96,
              child: GlassOverlayTransition(
                animation: controller,
                kind: GlassOverlayKind.menu,
                anchor: anchor,
                child: GlassMenuContents(
                  animation: controller,
                  sourceSize: anchor.size,
                  sourceRadius: 24,
                  source: const Center(
                    child: Icon(Icons.more_horiz, key: ValueKey('source-icon')),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      builds++;
                      return SizedBox(
                        width: 248,
                        height: 432,
                        child: CustomPaint(
                          painter: paintCounter,
                          child: const Center(child: Text('菜单正文')),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final render = tester.renderObject<GlassMenuStretchRender>(
      find.byType(GlassMenuStretch),
    );
    final child = tester.widget(find.text('菜单正文'));
    final foreground = tester.renderObject<GlassMenuContentsRender>(
      find.byType(GlassMenuContents),
    );
    final glyphSize = tester.getRect(find.text('菜单正文')).size;
    final glyphLocal = tester.renderObject<RenderBox>(find.text('菜单正文')).size;
    final foregroundLayouts = foreground.debugLayoutCount;
    expect(render.currentRect, anchor);
    expect(foreground.debugSourceOpacity, 1);
    expect(foreground.debugMenuOpacity, 0);
    expect(
      tester.getRect(find.byKey(const ValueKey('source-icon'))).center,
      anchor.center,
    );
    final layouts = render.debugLayoutCount;
    final initialBuilds = builds;
    final initialChildPaints = paintCounter.paints;
    double? middleHeight;
    for (var i = 1; i <= 120; i++) {
      controller.value = i / 120;
      await tester.pump();
      expect(render.currentRect.top, closeTo(anchor.top, .0001));
      expect(render.currentRect.right, closeTo(anchor.right, .0001));
      final glyphRect = tester.getRect(find.text('菜单正文'));
      expect(glyphRect.width, closeTo(glyphSize.width, .0001));
      expect(glyphRect.height, closeTo(glyphSize.height, .0001));
      expect(
        glyphRect.center.dx,
        closeTo(render.currentRect.left + render.size.width / 2, .0001),
      );
      expect(glyphRect.center.dy, closeTo(render.currentRect.center.dy, .0001));
      if (i == 60) middleHeight = render.currentRect.height;
    }
    expect(middleHeight, greaterThan(anchor.height * 2));
    expect(middleHeight, lessThan(render.size.height));
    expect(render.currentRect, render.targetRect);
    expect(builds, initialBuilds);
    expect(paintCounter.paints, lessThanOrEqualTo(initialChildPaints + 1));
    expect(render.debugLayoutCount, layouts);
    expect(foreground.debugLayoutCount, foregroundLayouts);
    expect(foreground.debugSourceOpacity, 0);
    expect(foreground.debugMenuOpacity, 1);
    expect(render.debugPaintCount, greaterThanOrEqualTo(120));
    expect(tester.widget(find.text('菜单正文')), same(child));
    expect(glyphSize.width, closeTo(glyphLocal.width, .0001));
    expect(glyphSize.height, closeTo(glyphLocal.height, .0001));
    expect(
      find.ancestor(
        of: find.byType(GlassMenuStretch),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    controller.value = .5;
    await tester.pump();
    final center = render.currentRect.center - render.targetRect.topLeft;
    expect(render.hitTest(BoxHitTestResult(), position: center), isTrue);
    controller.value = 0;
    await tester.pump();
    expect(render.currentRect, anchor);
    expect(
      render.hitTest(
        BoxHitTestResult(),
        position: anchor.center - render.targetRect.topLeft,
      ),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('bottom menu grows upward while keeping its attachment edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AnimationController(
      vsync: tester,
      duration: NovelMotion.enter,
    );
    addTearDown(controller.dispose);
    const anchor = Rect.fromLTWH(330, 720, 46, 46);
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              right: 24,
              bottom: 34,
              child: GlassMenuStretch(
                animation: controller,
                anchor: anchor,
                child: const SizedBox(width: 248, height: 432),
              ),
            ),
          ],
        ),
      ),
    );
    final render = tester.renderObject<GlassMenuStretchRender>(
      find.byType(GlassMenuStretch),
    );
    for (final value in [0.0, .1, .25, .5, .75, 1.0]) {
      controller.value = value;
      await tester.pump();
      expect(render.currentRect.bottom, closeTo(anchor.bottom, .0001));
      expect(render.currentRect.right, closeTo(anchor.right, .0001));
    }
    expect(render.currentRect, render.targetRect);
    expect(tester.takeException(), isNull);
  });

  for (final highContrast in [false, true]) {
    testWidgets(
      'fallback source remains circular, high contrast $highContrast',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final phase = AnimationController(
          vsync: tester,
          duration: NovelMotion.enter,
        );
        addTearDown(phase.dispose);
        const anchor = Rect.fromLTWH(330, 96, 46, 46);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(400, 800),
                highContrast: highContrast,
              ),
              child: Stack(
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
                          foreground: Center(child: Icon(Icons.more_horiz)),
                        ),
                        child: const SizedBox(
                          width: 248,
                          height: 432,
                          child: Text('清晰菜单'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        final stretch = tester.renderObject<GlassMenuStretchRender>(
          find.byType(GlassMenuStretch),
        );
        final clipFinder = find.descendant(
          of: find.byType(NativeBackdrop),
          matching: find.byWidgetPredicate(
            (w) => w is ClipRRect && w.clipper != null,
          ),
        );
        final clip = tester.widget<ClipRRect>(clipFinder);
        final clipSize = tester.getSize(clipFinder);
        final rrect = clip.clipper!.getClip(clipSize);
        expect(
          rrect.tlRadiusX * stretch.currentRect.width / clipSize.width,
          closeTo(23, .0001),
        );
        expect(
          rrect.tlRadiusY * stretch.currentRect.height / clipSize.height,
          closeTo(23, .0001),
        );
        final glyphSize = tester.getSize(find.text('清晰菜单'));
        for (final value in [.08, .2, .45, 1.0]) {
          phase.value = value;
          await tester.pump();
          final glyph = tester.getRect(find.text('清晰菜单'));
          expect(glyph.width, closeTo(glyphSize.width, .0001));
          expect(glyph.height, closeTo(glyphSize.height, .0001));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('menu keeps live optics and folds before restoring its trigger', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dock-tab-2')));
    await tester.pumpAndSettle();
    final trigger = find.text('跟随系统');
    final anchorOpacity = find
        .descendant(
          of: find.ancestor(
            of: trigger,
            matching: find.byType(GlassMenuAnchor),
          ),
          matching: find.byType(Opacity),
        )
        .first;
    await tester.tap(trigger);
    await tester.pump();
    final render = tester.renderObject<GlassMenuStretchRender>(
      find.byType(GlassMenuStretch),
    );
    final start = render.currentRect;
    expect(tester.widget<Opacity>(anchorOpacity).opacity, 0);
    await tester.pump(const Duration(milliseconds: 140));
    expect(render.currentRect.height, greaterThan(start.height));
    final optics = tester.widget<NativeBackdrop>(
      find.descendant(
        of: find.byType(GlassOverlaySurface),
        matching: find.byType(NativeBackdrop),
      ),
    );
    expect(optics.preserveOptics, isTrue);
    expect(optics.thickness, 20);
    expect(optics.blur, state.glassBlur);
    expect(optics.morph!.radius, 20);
    expect(optics.morph!.blur, 0);
    expect(optics.morph!.progress, inExclusiveRange(0, 1));
    expect(optics.emission, greaterThan(0));
    expect(
      find.ancestor(
        of: find.byType(GlassOverlaySurface),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    final route = ModalRoute.of(
      tester.element(find.byType(GlassMenuItem).first),
    )!;
    expect(route.barrierColor, Colors.transparent);
    await tester.pumpAndSettle();
    final end = render.currentRect;
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(render.currentRect.height, lessThan(end.height));
    expect(render.currentRect.height, greaterThan(start.height));
    expect(tester.widget<Opacity>(anchorOpacity).opacity, 0);
    await tester.pumpAndSettle();
    expect(find.byType(GlassOverlaySurface), findsNothing);
    expect(tester.widget<Opacity>(anchorOpacity).opacity, 1);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a menu reverses in place and restores a reusable trigger', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dock-tab-2')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('跟随系统'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      final stretch = tester.renderObject<GlassMenuStretchRender>(
        find.byType(GlassMenuStretch),
      );
      final before = stretch.currentRect;
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(stretch.currentRect, before);
      await tester.pumpAndSettle();
      expect(find.byType(GlassMenuSurface), findsNothing);
      expect(find.text('跟随系统'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reading progress leaves the app and article widget trees intact',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      await tester.pumpWidget(
        NovelApp(state: state, repository: const DemoNovelRepository()),
      );
      await tester.pumpAndSettle();
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      final novel = demoNovels.first;
      await state.toggleShelf(novel.id, novel: novel);
      await tester.pump();
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(app));
      Navigator.of(tester.element(find.byType(HomeShell))).push(
        softRoute(
          ReaderPage(
            novel: novel,
            state: state,
            repository: const DemoNovelRepository(),
            initialChapter: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final article = tester.widget(
        find.byKey(const ValueKey('reader-scroll')),
      );
      final paragraph = tester.widget<Text>(
        find.byKey(const ValueKey('paragraph-0')),
      );
      for (var i = 0; i < 12; i++) {
        await state.savePosition(
          novel: novel,
          chapter: 0,
          offset: i * 25,
          maximum: 3000,
          width: 800,
        );
        await tester.pump();
        expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(app));
        expect(
          tester.widget(find.byKey(const ValueKey('reader-scroll'))),
          same(article),
        );
        expect(
          tester.widget(find.byKey(const ValueKey('paragraph-0'))),
          same(paragraph),
        );
      }
      await state.setFontSize(23);
      await tester.pumpAndSettle();
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(app));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('paragraph-0')))
            .style!
            .fontSize,
        23,
      );
      await state.setTheme(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)),
        isNot(same(app)),
      );
      expect(
        Theme.of(tester.element(find.byType(ReaderPage))).brightness,
        Brightness.dark,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'opaque search stops covered discovery painting but keeps its state',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      await tester.pumpWidget(
        NovelApp(state: state, repository: const DemoNovelRepository()),
      );
      await tester.pumpAndSettle();
      final page = tester.element(find.byType(DiscoverPage));
      await tester.tap(_control('搜索'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Offstage>(
              find.byKey(const ValueKey('home-tab-0'), skipOffstage: false),
            )
            .offstage,
        isTrue,
      );
      expect(find.byType(DiscoverPage), findsNothing);
      expect(find.byType(InlineSearchResults), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inline-search-close')));
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(DiscoverPage)), same(page));
      expect(
        tester
            .widget<Offstage>(find.byKey(const ValueKey('home-tab-0')))
            .offstage,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _PaintCounter extends CustomPainter {
  int paints = 0;
  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}
