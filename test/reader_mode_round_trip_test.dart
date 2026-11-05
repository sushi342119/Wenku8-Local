import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_paged_view.dart';
import 'package:wenku8_flutter/reader_preferences.dart';

import 'support/offline_fixture.dart';

/// Review §4 items 1–3: switching 阅读方式 and restarting must keep the
/// reading paragraph. Scroll checks look at the laid-out view (offset and the
/// visible paragraph), not only the stored record, because a skipped restore
/// leaves the older, correct record in storage until the next idle save.
void main() {
  late LibraryState state;
  late OfflineFixtureRepository repository;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    state = await LibraryState.load();
    repository = OfflineFixtureRepository();
    final paragraphs = List.generate(
      180,
      (i) => '第 $i 段 · 阅读方式往返 ${'文字内容' * (12 + i % 7 * 9)}',
    );
    repository.books[71] = offlineFixtureBook(71).withChapters([
      NovelChapter('阅读方式样本', paragraphs.join('\n\n'), id: 71001),
    ]);
  });
  tearDown(() => state.dispose());

  Finder scrollView() => find.byKey(const ValueKey('reader-scroll'));
  ScrollableState scroll(WidgetTester tester) => tester.state<ScrollableState>(
    find.descendant(of: scrollView(), matching: find.byType(Scrollable)).first,
  );

  // Paged layout and restore run across async gaps and post-frame callbacks;
  // pump real time in small steps instead of pumpAndSettle.
  Future<void> flush(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> mount(WidgetTester tester, LibraryState library) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        scrollBehavior: const NovelScrollBehavior(),
        theme: novelTheme(
          Brightness.light,
        ).copyWith(platform: TargetPlatform.android),
        home: ReaderPage(
          novel: repository.books[71]!,
          state: library,
          repository: repository,
          initialChapter: 0,
        ),
      ),
    );
    await flush(tester);
  }

  Future<void> setMode(
    WidgetTester tester,
    LibraryState library,
    ReaderMode mode,
  ) async {
    await tester.runAsync(
      () => library.setReaderPreferences(
        library.readerPreferences.copyWith(mode: mode),
      ),
    );
    await flush(tester);
  }

  void expectPagedAt(WidgetTester tester, int paragraph) {
    final view = tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));
    expect(view.controller.ready, isTrue);
    expect(view.controller.anchor?.paragraph, paragraph);
  }

  void expectScrollAt(WidgetTester tester, LibraryState library, int index) {
    expect(scrollView(), findsOneWidget);
    // A restore that never ran leaves a fresh scroll view at the chapter
    // start (keepScrollOffset is false).
    expect(scroll(tester).position.pixels, greaterThan(1000));
    final paragraph = find.descendant(
      of: scrollView(),
      matching: find.byWidgetPredicate(
        (widget) => widget is ReaderParagraph && widget.index == index,
      ),
    );
    expect(paragraph, findsWidgets);
    final rect = tester.getRect(paragraph.first);
    final height = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(rect.bottom, greaterThan(0));
    expect(rect.top, lessThan(height));
    expect(library.positionFor(71)?.paragraphIndex, index);
  }

  Future<int> scrollToMiddle(WidgetTester tester) async {
    scroll(tester).position.jumpTo(4500);
    await flush(tester);
    final saved = state.positionFor(71);
    expect(saved?.paragraphIndex, isNotNull);
    expect(saved!.paragraphIndex, greaterThan(0));
    return saved.paragraphIndex!;
  }

  testWidgets('滚动 → 横排 → 竖排 → 滚动 keeps the paragraph', (tester) async {
    await mount(tester, state);
    final expected = await scrollToMiddle(tester);

    await setMode(tester, state, ReaderMode.paged);
    expectPagedAt(tester, expected);

    await setMode(tester, state, ReaderMode.vertical);
    expectPagedAt(tester, expected);

    await setMode(tester, state, ReaderMode.scroll);
    expectScrollAt(tester, state, expected);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a paged save restores by paragraph after restart in 滚动', (
    tester,
  ) async {
    await mount(tester, state);
    final expected = await scrollToMiddle(tester);
    await setMode(tester, state, ReaderMode.paged);
    await setMode(tester, state, ReaderMode.vertical);
    expectPagedAt(tester, expected);

    // Leaving the reader flushes the paged position.
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester, rounds: 4);
    final pagedRecord = state.positionFor(71);
    expect(pagedRecord?.paragraphIndex, expected);
    // Fraction in `offset`, so the record must never match a real layout.
    expect(pagedRecord!.width, 0);
    expect(pagedRecord.offset, lessThanOrEqualTo(1));

    await tester.runAsync(
      () => state.setReaderPreferences(
        state.readerPreferences.copyWith(mode: ReaderMode.scroll),
      ),
    );
    final reloaded = (await tester.runAsync(LibraryState.load))!;
    expect(reloaded.readerPreferences.mode, ReaderMode.scroll);
    expect(reloaded.positionFor(71)?.paragraphIndex, expected);
    expect(reloaded.positionFor(71)!.width, 0);

    await mount(tester, reloaded);
    expectScrollAt(tester, reloaded, expected);
    expect(reloaded.positionFor(71)!.width, greaterThan(0));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester, rounds: 2);
    reloaded.dispose();
  });
}
