import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/cover_arrival.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/native_effects.dart';
import 'package:wenku8_flutter/pages.dart';

import 'effects_test.dart' as effects;
import '../test/detail_loading_test.dart' as detail_loading;
import '../test/archive_carousel_test.dart' as archive_carousel;
import '../test/archive_cover_flight_test.dart' as archive_cover;
import '../test/archive_discovery_polish_test.dart' as archive_discovery;
import '../test/archive_shelf_interactions_test.dart'
    as archive_shelf_interactions;
import '../test/reader_tools_features_test.dart' as reader_tools;
import '../test/support/cover_fixture.dart';

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(
    pixelRatio: tester.view.devicePixelRatio,
  );
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final directory = Directory('${Directory.systemTemp.path}/ui-refinement');
  await directory.create(recursive: true);
  final file = File('${directory.path}/$name.png');
  await file.writeAsBytes(bytes.buffer.asUint8List());
  // ignore: avoid_print
  print('UI_REFINEMENT_CAPTURE=${file.path}');
  image.dispose();
}

Finder _glassControl(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is GlassIconButton && widget.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;

void main() {
  effects.main();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('native detail loading polish', () {
    detail_loading.main(capture: _capture);
  });
  group('native archive shelf', () {
    archive_carousel.main(capture: _capture);
    archive_shelf_interactions.main();
  });
  group('native reader bookmarks', () {
    reader_tools.main(capture: _capture);
  });
  group('native loop cover', () {
    archive_cover.main(capture: _capture);
  });
  group('native archive inertia discovery', () {
    archive_discovery.main(capture: _capture);
  });

  for (final brightness in Brightness.values) {
    final mode = brightness.name;
    testWidgets('native cached cover $mode cuts into a milky skeleton once', (
      tester,
    ) async {
      await NativeEffects.prepare();
      final bytes = await coverFixtureBytes();
      final id = 920001 + brightness.index;
      LegacyCover.seedLocalBytes(id, bytes);
      final capture = GlobalKey();
      Widget app() => RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: novelTheme(brightness),
          home: Scaffold(
            body: Atmosphere(
              child: Center(
                child: ArchiveRegistration(
                  child: NovelCover(
                    coverFixtureBook(id),
                    width: 118,
                    height: 166,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app());
      final plane = find.byKey(const ValueKey('cover-arrival-plane'));
      for (var i = 0; i < 30 && plane.evaluate().isEmpty; i++) {
        await tester.pump();
      }
      expect(plane, findsOneWidget);
      final clock =
          tester.widget<ArchivePlaneTransition>(plane).animation
              as AnimationController;
      clock.stop();
      clock.value = 0;
      await tester.pumpAndSettle();
      await _capture(tester, capture, 'cover-$mode-skeleton');
      final render = tester.renderObject<ArchivePlaneRender>(plane);
      final layouts = render.debugLayoutCount;
      clock.value = .24;
      await tester.pumpAndSettle();
      await _capture(tester, capture, 'cover-$mode-cut-in');
      expect(render.debugLayoutCount, layouts);
      clock.value = 1;
      await tester.pumpAndSettle();
      await _capture(tester, capture, 'cover-$mode-ready');
      expect(find.byType(LoadingSkeleton), findsNothing);
      expect(CoverArrival.wasPresented(LegacyCover.peek(id)!), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(plane, findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets('native archive motion $mode has retained diagonal tab poses', (
      tester,
    ) async {
      await NativeEffects.prepare();
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      await state.setTheme(
        brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      );
      for (final novel in demoNovels.take(2)) {
        await state.setShelfMembership(novel.id, true, novel: novel);
      }
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: NovelApp(
            state: state,
            repository: const DemoNovelRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final header = tester.getRect(find.byType(FrostedHeader));
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('dock-tab-1'))),
      );
      await tester.pump();
      final plane = find.byKey(const ValueKey('home-archive-plane-1'));
      final clock =
          tester.widget<ArchivePlaneTransition>(plane).animation
              as AnimationController;
      clock.stop();
      clock.value = 0;
      await tester.pumpAndSettle();
      final render = tester.renderObject<ArchivePlaneRender>(plane);
      final layouts = render.debugLayoutCount;
      // Fixed poses inspect the native render path. These are deliberately not
      // treated as real-time frame pacing or device FPS samples.
      for (final (name, value) in [
        ('a', 0.0),
        ('b', .06),
        ('c', .12),
        ('d', .18),
        ('e', .24),
        ('f', .30),
        ('g', .38),
        ('h', .46),
        ('i', .56),
        ('j', .66),
        ('k', .78),
        ('l', .90),
        ('m', 1.0),
      ]) {
        clock.value = value;
        await tester.pump();
        expect(tester.getRect(find.byType(FrostedHeader)), header);
        expect(render.debugLayoutCount, layouts);
        await _capture(tester, capture, 'motion-$mode-tab-$name');
      }
      await tester.pumpAndSettle();
      expect(find.text('02 / PERSONAL ARCHIVE'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      state.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    final mode = brightness.name;
    testWidgets(
      'native archive design $mode keeps navigation and reader glass',
      (tester) async {
        await NativeEffects.prepare();
        SharedPreferences.setMockInitialValues({});
        final state = await LibraryState.load();
        await state.setTheme(
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        );
        for (final novel in demoNovels.take(2)) {
          await state.setShelfMembership(novel.id, true, novel: novel);
        }
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: NovelApp(
              state: state,
              repository: const DemoNovelRepository(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('WENKU8 / READING ARCHIVE'), findsOneWidget);
        await _capture(tester, capture, 'archive-$mode-discovery');

        Future<void> selectTab(int index) async {
          await tester.tapAt(
            tester.getCenter(find.byKey(ValueKey('dock-tab-$index'))),
          );
          await tester.pumpAndSettle();
        }

        await selectTab(1);
        expect(find.text('02 / PERSONAL ARCHIVE'), findsOneWidget);
        await _capture(tester, capture, 'archive-$mode-shelf');
        await selectTab(2);
        expect(find.text('03 / SYSTEM PROFILE'), findsOneWidget);
        await _capture(tester, capture, 'archive-$mode-settings');
        await selectTab(0);
        await tester.tap(find.text(demoNovels.first.title).last);
        await tester.pumpAndSettle();
        expect(find.byType(DetailPage), findsOneWidget);
        await _capture(tester, capture, 'archive-$mode-detail');

        await tester.tap(find.byKey(const ValueKey('detail-read-button')));
        await tester.pumpAndSettle();
        expect(find.byType(ReaderPage), findsOneWidget);
        expect(find.byType(ArchiveBackdrop), findsNothing);
        await _capture(tester, capture, 'archive-$mode-reader');
        await tester.tap(_glassControl('阅读设置'));
        await tester.pumpAndSettle();
        expect(find.text('READER / CONTROL PANEL'), findsOneWidget);
        await _capture(tester, capture, 'archive-$mode-reader-settings');
        await tester.tap(_glassControl('关闭阅读设置'));
        await tester.pumpAndSettle();
        await selectTab(1);
        expect(find.text('READER / CONTENTS'), findsOneWidget);
        await _capture(tester, capture, 'archive-$mode-reader-catalogue');
        await tester.tap(_glassControl('关闭目录'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        state.dispose();
      },
    );
  }

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('native jelly menu $mode keeps live glass through its stretch', (
      tester,
    ) async {
      await NativeEffects.prepare();
      final phase = AnimationController(
        vsync: tester,
        duration: NovelMotion.enter,
      );
      final source = ValueNotifier<int>(
        brightness == Brightness.dark ? 48 : 196,
      );
      final showMorph = ValueNotifier<bool>(true);
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: novelTheme(brightness),
            home: LayoutBuilder(
              builder: (context, constraints) {
                final top = MediaQuery.viewPaddingOf(context).top + 100;
                final anchor = Rect.fromLTWH(
                  constraints.maxWidth - 70,
                  top,
                  46,
                  46,
                );
                return Stack(
                  children: [
                    Positioned.fill(
                      child: ValueListenableBuilder<int>(
                        valueListenable: source,
                        builder: (context, level, child) =>
                            CustomPaint(painter: _MenuBackdrop(level)),
                      ),
                    ),
                    Positioned(
                      right: 24,
                      top: top,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: showMorph,
                        builder: (context, morph, child) => !morph
                            ? GlassIconButton(
                                icon: Icons.more_horiz,
                                label: '菜单',
                                onPressed: () {},
                              )
                            : GlassOverlayTransition(
                                animation: phase,
                                kind: GlassOverlayKind.menu,
                                anchor: anchor,
                                child: GlassMenuSurface(
                                  animation: phase,
                                  anchor: anchor,
                                  source: const GlassMenuSource(
                                    foreground: Center(
                                      child: Icon(Icons.more_horiz, size: 21),
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: SizedBox(
                                      width: 232,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: List.generate(
                                          6,
                                          (index) => GlassMenuItem(
                                            label: '菜单项目 ${index + 1}',
                                            onPressed: () {},
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<Uint8List> frame() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(
          pixelRatio: tester.view.devicePixelRatio,
        );
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        image.dispose();
        return bytes;
      }

      final sourceFrame = await frame();
      final initialStretch = tester.renderObject<GlassMenuStretchRender>(
        find.byType(GlassMenuStretch),
      );
      final sourceRect = initialStretch.currentRect;
      showMorph.value = false;
      await tester.pumpAndSettle();
      final buttonFrame = await frame();
      final dpr = tester.view.devicePixelRatio;
      final imageWidth = tester.view.physicalSize.width.round();
      var difference = 0;
      var samples = 0;
      for (
        var y = (sourceRect.top * dpr).ceil();
        y < (sourceRect.bottom * dpr).floor();
        y++
      ) {
        for (
          var x = (sourceRect.left * dpr).ceil();
          x < (sourceRect.right * dpr).floor();
          x++
        ) {
          for (var channel = 0; channel < 3; channel++) {
            final index = (y * imageWidth + x) * 4 + channel;
            difference += (sourceFrame[index] - buttonFrame[index]).abs();
            samples++;
          }
        }
      }
      final sourceError = difference / samples;
      expect(sourceError, lessThan(1));
      // ignore: avoid_print
      print('NATIVE_MENU_SOURCE mode=$mode mean_rgb_error=$sourceError');
      showMorph.value = true;
      await tester.pumpAndSettle();
      final stretch = tester.renderObject<GlassMenuStretchRender>(
        find.byType(GlassMenuStretch),
      );
      final layouts = stretch.debugLayoutCount;
      final foreground = tester.renderObject<GlassMenuContentsRender>(
        find.byType(GlassMenuContents),
      );
      final foregroundLayouts = foreground.debugLayoutCount;
      final labelSize = tester.getSize(find.text('菜单项目 1'));
      final optics = tester.widget<NativeBackdrop>(find.byType(NativeBackdrop));
      expect(optics.preserveOptics, isTrue);
      expect(optics.emission, greaterThan(0));
      expect(
        find.ancestor(
          of: find.byType(GlassOverlaySurface),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
      for (final (value, name) in [
        (0.0, 'source'),
        (.15, 'contact'),
        (.38, 'stretch'),
        (.65, 'settle'),
        (1.0, 'open'),
        (.45, 'fold'),
        (0.0, 'closed'),
      ]) {
        phase.value = value;
        await tester.pump();
        expect(
          tester.getRect(find.byType(GlassOverlaySurface)),
          stretch.currentRect,
        );
        expect(stretch.debugLayoutCount, layouts);
        expect(foreground.debugLayoutCount, foregroundLayouts);
        final label = tester.getRect(find.text('菜单项目 1'));
        expect(label.width, closeTo(labelSize.width, .0001));
        expect(label.height, closeTo(labelSize.height, .0001));
        expect(label.left, greaterThan(stretch.currentRect.left));
        await _capture(tester, capture, 'menu-$mode-$name');
      }
      phase.value = .65;
      await tester.pump();
      Future<int> sample() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(
          pixelRatio: tester.view.devicePixelRatio,
        );
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final rect = stretch.currentRect;
        final point = Offset(rect.right - 24, rect.center.dy);
        final x = (point.dx * tester.view.devicePixelRatio).round();
        final y = (point.dy * tester.view.devicePixelRatio).round();
        final level = pixels.getUint8((y * image.width + x) * 4);
        image.dispose();
        return level;
      }

      final before = await sample();
      source.value += 32;
      await tester.pump();
      final after = await sample();
      expect(after, greaterThan(before + 18));
      expect(stretch.debugLayoutCount, layouts);
      // ignore: avoid_print
      print(
        'NATIVE_JELLY_MENU mode=$mode layouts=$layouts paints=${stretch.debugPaintCount} live_before=$before live_after=$after',
      );
      await _capture(tester, capture, 'menu-$mode-live-backdrop');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      phase.dispose();
      source.dispose();
      showMorph.dispose();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('native detail scroll keeps a lazy directory and pinned controls', (
    tester,
  ) async {
    await NativeEffects.prepare();
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    await state.setReduceMotion(true);
    final novel = demoNovels.first.withChapters(
      List.generate(
        1000,
        (index) => NovelChapter('滚动目录 ${index + 1}', '目录测试正文。', id: index + 1),
      ),
    );
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(Brightness.dark),
          scrollBehavior: const NovelScrollBehavior(),
          home: DetailPage(
            novel: novel,
            state: state,
            repository: const DemoNovelRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final titles = find.byWidgetPredicate(
      (widget) => widget is Text && (widget.data?.startsWith('滚动目录 ') ?? false),
    );
    final firstCount = titles.evaluate().length;
    expect(firstCount, inInclusiveRange(1, 40));
    final header = tester.getRect(find.byType(FrostedHeader));
    final footer = tester.getRect(
      find.byKey(const ValueKey('detail-read-button')),
    );
    await _capture(tester, capture, 'detail-scroll-top');
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(DetailPage),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    position.jumpTo(18000);
    await tester.pumpAndSettle();
    final scrolledCount = titles.evaluate().length;
    expect(scrolledCount, inInclusiveRange(1, 40));
    expect(find.text('滚动目录 1'), findsNothing);
    expect(tester.getRect(find.byType(FrostedHeader)), header);
    expect(
      tester.getRect(find.byKey(const ValueKey('detail-read-button'))),
      footer,
    );
    // ignore: avoid_print
    print(
      'NATIVE_DETAIL_SCROLL total=1000 first=$firstCount scrolled=$scrolledCount offset=${position.pixels}',
    );
    await _capture(tester, capture, 'detail-scroll-middle');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'native inline search, detail and loading layouts render together',
    (tester) async {
      await NativeEffects.prepare();
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      await state.setGlassOpacity(.3);
      final repository = _StagedRepository();
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: NovelApp(state: state, repository: repository),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(LibrarySkeleton), findsOneWidget);
      await _capture(tester, capture, 'light-library-loading');
      repository.books.complete(demoNovels);
      await tester.pumpAndSettle();

      final route = ModalRoute.of(tester.element(find.byType(HomeShell)));
      await tester.tap(_glassControl('搜索'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('expanded-search-input'));
      expect(ModalRoute.of(tester.element(input)), same(route));
      expect(find.byType(FrostedHeader), findsOneWidget);
      await tester.enterText(input, demoNovels.first.title);
      await tester.pumpAndSettle();
      await _capture(tester, capture, 'light-inline-search-open');
      await tester.tap(
        find
            .descendant(
              of: find.byType(InlineSearchResults),
              matching: find.text(demoNovels.first.title),
            )
            .last,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(DetailSkeleton), findsOneWidget);
      expect(find.byType(CoverGlow), findsNothing);
      await _capture(tester, capture, 'light-detail-loading');
      repository.detailData.complete(demoNovels.first);
      await tester.pump();
      repository.chapterData.complete(demoNovels.first.chapters);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(DetailSkeleton), findsNothing);
      expect(find.byType(PaperCoverFlight), findsNothing);
      await _capture(tester, capture, 'light-detail-ready');
      await state.setTheme(ThemeMode.dark);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Theme and Material's inherited text styles have separate timelines.
      // Capture the settled palette, not the first dark background frame.
      await tester.pump(const Duration(milliseconds: 300));
      for (final text in ['图书详情', '简介', '目录']) {
        final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
        expect(
          paragraph.text.style!.color!.computeLuminance(),
          greaterThan(.7),
        );
      }
      await _capture(tester, capture, 'dark-detail-ready');
      await tester.tap(find.byKey(const ValueKey('detail-read-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ReaderSkeleton), findsOneWidget);
      await _capture(tester, capture, 'dark-reader-loading');
      repository.content.complete(demoNovels.first.chapters.first.content);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ReaderSkeleton), findsNothing);
      await _capture(tester, capture, 'dark-reader-ready');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('static skeletons match both monochrome themes', (tester) async {
    final capture = GlobalKey();
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: novelTheme(brightness),
            home: Scaffold(
              body: Atmosphere(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: BookRowSkeleton(label: '正在找故事'),
                      ),
                      const SizedBox(height: 28),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: DetailSkeleton(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await _capture(tester, capture, 'static-skeletons-${brightness.name}');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('native paper peel and diagonal contact render cleanly', (
    tester,
  ) async {
    await NativeEffects.prepare();
    final capture = GlobalKey();
    final phase = ValueNotifier<double>(0);
    const source = Rect.fromLTWH(26, 316, 56, 76);
    const target = Rect.fromLTWH(26, 126, 118, 166);
    final path = PaperCoverRectTween(
      begin: source,
      end: target,
      returning: false,
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: Atmosphere(
              child: Stack(
                children: [
                  const Positioned(
                    top: 70,
                    left: 26,
                    child: Text(
                      '封面串场',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Positioned(
                    top: 440,
                    left: 26,
                    right: 26,
                    child: Text(
                      '上沿先被风托起，移动后从左下角向右上角贴合。',
                      style: TextStyle(color: Color(0xFF666666), fontSize: 13),
                    ),
                  ),
                  ValueListenableBuilder<double>(
                    valueListenable: phase,
                    builder: (context, value, child) => Positioned.fromRect(
                      rect: path.lerp(value),
                      child: PaperCoverFlight(
                        animation: AlwaysStoppedAnimation(value),
                        faceSize: const Size(118, 166),
                        child: FittedBox(
                          fit: BoxFit.fill,
                          child: NovelCover(
                            demoNovels.first,
                            width: 118,
                            height: 166,
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
    for (final (value, name) in [
      (0.0, 'paper-source'),
      (.10, 'paper-peel'),
      (.45, 'paper-wind'),
      (.78, 'paper-bottom-left-contact'),
      (.93, 'paper-top-right-contact'),
      (1.0, 'paper-flat'),
    ]) {
      phase.value = value;
      await tester.pump();
      await tester.pump();
      final bend = tester.renderObject<PaperCoverRender>(
        find.byType(PaperCoverBend),
      );
      expect(bend.config.image, isNotNull);
      expect(bend.debugMeshDraws, greaterThan(0));
      expect(bend.debugChildPaints, lessThanOrEqualTo(1));
      if (value == .78) {
        final pose = PaperFlightPose(value);
        expect(pose.depthAt(1, column: 0), 0);
        expect(pose.depthAt(1, column: 1), greaterThan(0));
      }
      if (value == .93) {
        final pose = PaperFlightPose(value);
        expect(pose.depthAt(0, column: 0), 0);
        expect(pose.depthAt(0, column: 1), greaterThan(0));
      }
      await _capture(tester, capture, name);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    phase.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('native paper cached cover uses one mesh and keeps its backing', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 118, 166),
      Paint()..color = const Color(0xFFB24A42),
    );
    canvas.drawRect(
      const Rect.fromLTWH(84, 0, 34, 166),
      Paint()..color = const Color(0xFF6F9985),
    );
    canvas.drawCircle(
      const Offset(59, 83),
      12,
      Paint()..blendMode = BlendMode.clear,
    );
    final picture = recorder.endRecording();
    final original = await picture.toImage(118, 166);
    picture.dispose();
    final encoded = (await original.toByteData(
      format: ui.ImageByteFormat.png,
    ))!;
    original.dispose();
    final provider = MemoryImage(encoded.buffer.asUint8List());
    final ready = Completer<ImageInfo>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => ready.complete(info));
    stream.addListener(listener);
    final info = await ready.future;
    stream.removeListener(listener);
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: capture,
              child: SizedBox(
                width: 118,
                height: 166,
                child: PaperCoverFlight(
                  animation: const AlwaysStoppedAnimation(0.0),
                  imageProvider: provider,
                  faceSize: const Size(118, 166),
                  child: ColoredBox(
                    color: accent,
                    child: RawImage(image: info.image, fit: BoxFit.cover),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final render = tester.renderObject<PaperCoverRender>(
      find.byType(PaperCoverBend),
    );
    expect(render.config.imageIsFitted, isFalse);
    expect(render.config.image, isNotNull);
    expect(render.debugMeshDraws, greaterThan(0));
    expect(render.debugChildPaints, 0);
    final image =
        await (capture.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: tester.view.devicePixelRatio);
    final pixels = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    final x = image.width ~/ 2;
    final y = image.height ~/ 2;
    final offset = (y * image.width + x) * 4;
    for (var channel = 0; channel < 3; channel++) {
      expect(pixels.getUint8(offset + channel), closeTo(32, 1));
    }
    image.dispose();
    await _capture(tester, capture, 'paper-cached-image');
    await tester.pumpWidget(const SizedBox.shrink());
    info.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'native shared glass controls and panels move as complete surfaces',
    (tester) async {
      await NativeEffects.prepare();
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      await state.setTheme(ThemeMode.dark);
      await state.setGlassOpacity(.3);
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: NovelApp(
            state: state,
            repository: const DemoNovelRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _capture(tester, capture, 'dark-glass-home');
      final surface = find.byKey(const ValueKey('dock-fluid-surface'));
      final tab = find.byKey(const ValueKey('dock-tab-0'));
      final glyph = find.descendant(of: tab, matching: find.byType(Icon));
      final originalSurface = tester.getRect(surface);
      final originalGlyph = tester.getRect(glyph);
      final held = await tester.startGesture(tester.getCenter(tab));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final sy = tester.getRect(surface).height / originalSurface.height;
      expect(sy, greaterThan(1));
      expect(
        tester.getRect(glyph).height,
        closeTo(originalGlyph.height * sy, .001),
      );
      await _capture(tester, capture, 'dark-glass-dock-held');
      await held.cancel();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dock-tab-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(find.byType(GlassMenuItem), findsNWidgets(3));
      await _capture(tester, capture, 'dark-glass-dropdown');
      Navigator.of(tester.element(find.byType(GlassMenuItem).first)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dock-tab-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(demoNovels.first.title).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('detail-read-button')));
      await tester.pumpAndSettle();
      await tester.tap(_glassControl('阅读设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await _capture(tester, capture, 'dark-glass-drawer-opening');
      await tester.pumpAndSettle();
      await _capture(tester, capture, 'dark-glass-drawer');
      final drawer = find.byType(GlassOverlaySurface);
      final title = find.text('阅读设置');
      final before = tester.getRect(drawer);
      final titleBefore = tester.getRect(title);
      final drag = await tester.startGesture(
        Offset(before.center.dx, before.top + 10),
      );
      await drag.moveBy(const Offset(0, 32));
      await tester.pump();
      await drag.moveBy(const Offset(0, 18));
      await tester.pump();
      expect(
        tester.getRect(title).top - titleBefore.top,
        closeTo(tester.getRect(drawer).top - before.top, .001),
      );
      await _capture(tester, capture, 'dark-glass-drawer-drag');
      await drag.cancel();
      await tester.pumpAndSettle();
      expect(drawer, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}

class _MenuBackdrop extends CustomPainter {
  const _MenuBackdrop(this.level);
  final int level;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Color.fromARGB(255, level, level, level),
    );
    // A fine live pattern distinguishes real softening/refraction from a
    // flat tinted popup, throughout the source/contact/stretch poses.
    final paint = Paint()
      ..color = Color.fromARGB(255, level + 20, level + 20, level + 20);
    for (var x = 0.0; x < size.width; x += 6) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 2, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_MenuBackdrop oldDelegate) => oldDelegate.level != level;
}

class _StagedRepository extends DemoNovelRepository {
  final books = Completer<List<Novel>>();
  final detailData = Completer<Novel>();
  final chapterData = Completer<List<NovelChapter>>();
  final content = Completer<String>();
  @override
  Future<List<Novel>> list() => books.future;
  @override
  Future<Novel> detail(Novel novel) => detailData.future;
  @override
  Future<List<NovelChapter>> chapters(int id) => chapterData.future;
  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) =>
      content.future;
}
