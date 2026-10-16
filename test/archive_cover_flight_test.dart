import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_carousel.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';

import 'support/cover_fixture.dart';
import 'support/offline_fixture.dart';

void _samePlane(PaperCoverPlane actual, PaperCoverPlane expected) {
  for (final (a, b) in [
    (actual.origin, expected.origin),
    (actual.horizontal, expected.horizontal),
    (actual.vertical, expected.vertical),
  ]) {
    expect((a - b).distance, lessThan(.00001));
  }
}

void main({Future<void> Function(WidgetTester, GlobalKey, String)? capture}) {
  for (final mode in Brightness.values) {
    testWidgets(
      'archive cover ${mode.name} preserves projection, occlusion, portrait and loop identity in both flights',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final state = await LibraryState.load();
        final bytes = (await tester.runAsync(coverFixtureBytes))!;
        final books = [
          for (var i = 0; i < 5; i++) coverFixtureBook(970000 + i),
        ];
        for (final book in books) {
          LegacyCover.seedLocalBytes(book.id, bytes);
        }
        final repository = OfflineFixtureRepository(books: books);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              theme: novelTheme(mode),
              home: Builder(
                builder: (context) => Scaffold(
                  body: Atmosphere(
                    child: Center(
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: ArchiveFileCarousel(
                            books: books,
                            onOpen: (book, tag) => openDetail(
                              context,
                              book,
                              state,
                              repository,
                              coverHeroTag: tag,
                              fromCache: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => precacheImage(
            MemoryImage(LegacyCover.peek(books.first.id)!),
            tester.element(find.byType(ArchiveFileCarousel)),
          ),
        );
        await tester.pumpAndSettle();
        final scene = tester.renderObject<ArchiveShelfSceneRender>(
          find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_ShelfRow',
          ),
        );
        final scroll = tester
            .state<ScrollableState>(
              find.byKey(const ValueKey('archive-file-carousel')),
            )
            .position;
        // Open an actual repeated copy, not a special non-looping first item.
        scroll.jumpTo(scene.debugPitch * -1000);
        (scroll as ScrollPositionWithSingleContext).goIdle();
        await tester.pumpAndSettle();
        final source = find.byType(Hero).first;
        final sourceTag = tester.widget<Hero>(source).tag;
        final sourcePlane = PaperCoverPlane.fromHero(tester.element(source));
        expect(sourcePlane.horizontal.dy, lessThan(-.1));
        expect(sourcePlane.origin.dy, greaterThan(.1));
        final art = tester.widget<NovelCover>(
          find.ancestor(of: source, matching: find.byType(NovelCover)),
        );
        expect(art.height / art.width, closeTo(166 / 118, .00001));
        final mask = PaperCoverPlane.occlusionFromHero(tester.element(source));
        expect(mask, isNotNull);
        final faceBox = tester.renderObject<RenderBox>(source);
        var coveredSamples = 0;
        for (var x = 1; x < 10; x++) {
          for (var y = 1; y < 10; y++) {
            final point = faceBox.localToGlobal(
              Offset(faceBox.size.width * x / 10, faceBox.size.height * y / 10),
            );
            var foreground = false;
            for (final slot in scene.debugPaintOrder.where(
              (slot) => slot > scene.debugCentreSlot,
            )) {
              final box = tester.renderObject<ArchiveBoxDepthRender>(
                find.byKey(ValueKey('archive-slot-$slot')),
              );
              if (box.hitTest(
                BoxHitTestResult(),
                position: box.globalToLocal(point),
              )) {
                foreground = true;
                break;
              }
            }
            if (foreground) {
              coveredSamples++;
              expect(
                mask!.contains(point),
                isTrue,
                reason:
                    'Every foreground top/side/spine union must occlude the cover, even where face winding differs.',
              );
            }
          }
        }
        expect(coveredSamples, greaterThan(0));
        if (capture != null) {
          await capture(tester, boundary, 'loop-${mode.name}-cover-ready');
        }
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('archive-shelf-open')),
            matching: find.byType(InkWell),
          ),
        );
        await tester.pump();
        await tester.pump();
        final flight = tester.widget<PaperCoverFlight>(
          find.byType(PaperCoverFlight),
        );
        _samePlane(flight.beginPlane, sourcePlane);
        _samePlane(flight.endPlane, PaperCoverPlane.flat);
        expect(flight.beginOcclusion, isNotNull);
        expect(flight.endOcclusion, isNull);
        final render = tester.renderObject<PaperCoverRender>(
          find.byType(PaperCoverBend),
        );
        expect(render.config.image, isNotNull);
        expect(find.byType(PaperCoverFlight), findsOneWidget);
        if (capture != null) {
          await capture(tester, boundary, 'loop-${mode.name}-cover-takeoff');
        }
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          render.debugPlane.horizontal.dy.abs(),
          lessThan(sourcePlane.horizontal.dy.abs()),
        );
        if (capture != null) {
          await capture(tester, boundary, 'loop-${mode.name}-cover-flight');
        }
        await tester.pump(const Duration(milliseconds: 400));
        _samePlane(render.debugPlane, PaperCoverPlane.flat);
        if (capture != null) {
          await capture(tester, boundary, 'loop-${mode.name}-cover-contact');
        }
        await tester.pumpAndSettle();
        expect(find.byType(PaperCoverFlight), findsNothing);
        expect(tester.binding.transientCallbackCount, 0);
        final landed = find.descendant(
          of: find.byType(DetailPage),
          matching: find.byType(Hero),
        );
        expect(tester.widget<Hero>(landed).tag, sourceTag);
        var returnPlane = sourcePlane;
        // The source must remain discoverable after the bounded physical pool
        // changes size underneath an open detail route.
        if (mode == Brightness.light) {
          tester.view.physicalSize = const Size(844, 390);
          await tester.pumpAndSettle();
          final underlying = find.descendant(
            of: find.byType(ArchiveFileCarousel, skipOffstage: false),
            matching: find.byType(Hero, skipOffstage: false),
          );
          expect(underlying, findsOneWidget);
          expect(tester.widget<Hero>(underlying).tag, sourceTag);
          returnPlane = PaperCoverPlane.fromHero(tester.element(underlying));
        }
        final detailContext = tester.element(landed);
        Navigator.of(detailContext).pop();
        await tester.pump();
        await tester.pump();
        final returning = tester.widget<PaperCoverFlight>(
          find.byType(PaperCoverFlight),
        );
        _samePlane(returning.beginPlane, returnPlane);
        expect(returning.beginOcclusion, isNotNull);
        await tester.pump(const Duration(milliseconds: 690));
        if (capture != null) {
          await capture(tester, boundary, 'loop-${mode.name}-cover-return');
        }
        await tester.pumpAndSettle();
        expect(scene.debugFocus, closeTo(-1000, .0001));
        _samePlane(
          PaperCoverPlane.fromHero(tester.element(find.byType(Hero).first)),
          returnPlane,
        );
        expect(find.byType(PaperCoverFlight), findsNothing);
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }
}
