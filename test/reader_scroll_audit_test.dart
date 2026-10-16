import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_chrome.dart';
import 'package:wenku8_flutter/reader_content.dart';

import 'support/offline_fixture.dart';

void main({Future<void> Function(WidgetTester, GlobalKey, String)? capture}) {
  late LibraryState state;
  late OfflineFixtureRepository repository;
  late GlobalKey boundary;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    state = await LibraryState.load();
    repository = OfflineFixtureRepository();
    boundary = GlobalKey();
    final paragraphs = List.generate(
      180,
      (i) => '第 $i 段 · 正文上下连续滑动 ${'文字内容' * (12 + i % 7 * 9)}',
    );
    repository.books[71] = offlineFixtureBook(71).withChapters([
      NovelChapter('滚动定位样本', paragraphs.join('\n\n'), id: 71001),
    ]);
  });
  tearDown(() => state.dispose());
  ScrollableState scroll(WidgetTester tester) => tester.state<ScrollableState>(
    find
        .descendant(
          of: find.byKey(const ValueKey('reader-scroll')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  Future<void> mount(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          scrollBehavior: const NovelScrollBehavior(),
          theme: novelTheme(
            brightness,
          ).copyWith(platform: TargetPlatform.android),
          home: ReaderPage(
            novel: repository.books[71]!,
            state: state,
            repository: repository,
            initialChapter: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      '120 drag/reversal frames keep exact finger deltas with persistent ${brightness.name} blur',
      (tester) async {
        await mount(tester, brightness: brightness);
        scroll(tester).position.jumpTo(4500);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 200));
        final originalEdges = tester.element(find.byType(ReaderEdgeBlur));
        final paragraphs = find.byType(ReaderParagraph).evaluate().length;
        final requests = repository.calls.length;
        await tester.tapAt(const Offset(210, 280));
        await tester.pumpAndSettle();
        expect(find.byType(GlassIconButton), findsNothing);
        expect(
          tester.element(find.byType(ReaderEdgeBlur)),
          same(originalEdges),
        );
        expect(find.byType(ProgressiveBlur), findsNWidgets(2));
        if (capture != null) {
          await capture(
            tester,
            boundary,
            'focus-live-${brightness.name}-before',
          );
        }
        var historyChanges = 0;
        void changed() => historyChanges++;
        state.historyChanges.addListener(changed);
        final gesture = await tester.startGesture(const Offset(210, 280));
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump(const Duration(microseconds: 8333));
        for (var frame = 0; frame < 120; frame++) {
          final dy = frame < 60 ? -3.0 : 3.0;
          final before = scroll(tester).position.pixels;
          await gesture.moveBy(Offset(0, dy));
          await tester.pump(const Duration(microseconds: 8333));
          expect(scroll(tester).position.pixels - before, closeTo(-dy, .001));
        }
        expect(historyChanges, 0);
        expect(repository.calls.length, requests);
        expect(
          tester.element(find.byType(ReaderEdgeBlur)),
          same(originalEdges),
        );
        expect(
          find.byType(ReaderParagraph).evaluate().length,
          lessThan(paragraphs + 10),
        );
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 100));
        expect(historyChanges, 0);
        await tester.pump(const Duration(milliseconds: 90));
        expect(historyChanges, 1);
        expect(
          state.positionFor(71)!.offset,
          closeTo(scroll(tester).position.pixels, .5),
        );
        state.historyChanges.removeListener(changed);
        scroll(tester).position.jumpTo(4800);
        await tester.pumpAndSettle();
        if (capture != null) {
          await capture(
            tester,
            boundary,
            'focus-live-${brightness.name}-after',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Android tiny motion resumes immediately after a stationary contact',
    (tester) async {
      await mount(tester);
      scroll(tester).position.jumpTo(3000);
      await tester.pumpAndSettle();
      final contact = await tester.startGesture(const Offset(210, 300));
      await contact.moveBy(
        const Offset(0, -40),
        timeStamp: const Duration(milliseconds: 20),
      );
      await contact.moveBy(
        const Offset(0, -10),
        timeStamp: const Duration(milliseconds: 30),
      );
      await tester.pump();
      await contact.moveBy(
        Offset.zero,
        timeStamp: const Duration(milliseconds: 100),
      );
      await tester.pump();
      final before = scroll(tester).position.pixels;
      await contact.moveBy(
        const Offset(0, -1),
        timeStamp: const Duration(milliseconds: 110),
      );
      await tester.pump();
      expect(scroll(tester).position.pixels - before, closeTo(1, .001));
      await contact.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 180));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'interrupting a fling does no persistence work inside the new contact',
    (tester) async {
      await mount(tester);
      scroll(tester).position.jumpTo(3000);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      var notifications = 0;
      void changed() => notifications++;
      state.historyChanges.addListener(changed);
      await tester.fling(
        find.byKey(const ValueKey('reader-scroll')),
        const Offset(0, -240),
        1600,
      );
      await tester.pump(const Duration(milliseconds: 16));
      final contact = await tester.startGesture(const Offset(220, 330));
      await tester.pump(const Duration(milliseconds: 70));
      expect(notifications, 0);
      await contact.moveBy(const Offset(0, 32));
      await tester.pump(const Duration(milliseconds: 180));
      expect(notifications, 0);
      await contact.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 180));
      expect(notifications, 1);
      state.historyChanges.removeListener(changed);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving during deferred idle flushes progress and cancels the timer',
    (tester) async {
      await mount(tester);
      final controller = tester
          .widget<CustomScrollView>(find.byKey(const ValueKey('reader-scroll')))
          .controller!;
      expect(controller.keepScrollOffset, isFalse);
      controller.jumpTo(2100);
      await tester.pump();
      final expected = scroll(tester).position.pixels;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));
      expect(state.positionFor(71)!.offset, closeTo(expected, .5));
      expect(tester.takeException(), isNull);
    },
  );
}
