import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';

Finder _chapterTitles() => find.byWidgetPredicate(
  (widget) => widget is Text && (widget.data?.startsWith('性能目录 ') ?? false),
);

Future<LibraryState> _mountDetail(
  WidgetTester tester,
  Novel novel, {
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  final state = await LibraryState.load();
  await state.setReduceMotion(true);
  await tester.pumpWidget(
    MaterialApp(
      theme: novelTheme(Brightness.dark),
      scrollBehavior: const NovelScrollBehavior(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: DetailPage(
        novel: novel,
        state: state,
        repository: const DemoNovelRepository(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets('detail directory only lays out nearby chapters while scrolling', (
    tester,
  ) async {
    final novel = demoNovels.first.withChapters(
      List.generate(
        1000,
        (index) => NovelChapter(
          '性能目录 ${index.toString().padLeft(4, '0')}',
          '目录回归正文。',
          id: index + 1,
        ),
      ),
    );
    await _mountDetail(tester, novel);
    final initialCount = _chapterTitles().evaluate().length;
    // ignore: avoid_print
    print(
      'DETAIL_SCROLL_LAYOUT initial_chapter_widgets=$initialCount total=1000',
    );
    expect(initialCount, inInclusiveRange(1, 30));
    expect(find.text('性能目录 0900'), findsNothing);
    final header = tester.getRect(find.byType(FrostedHeader));
    final footer = tester.getRect(
      find.byKey(const ValueKey('detail-read-button')),
    );
    final scrollable = find
        .descendant(
          of: find.byType(DetailPage),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(18000);
    await tester.pumpAndSettle();
    final scrolledCount = _chapterTitles().evaluate().length;
    // ignore: avoid_print
    print(
      'DETAIL_SCROLL_LAYOUT scrolled_chapter_widgets=$scrolledCount offset=${position.pixels}',
    );
    expect(scrolledCount, inInclusiveRange(1, 30));
    expect(find.text('性能目录 0000'), findsNothing);
    expect(tester.getRect(find.byType(FrostedHeader)), header);
    expect(
      tester.getRect(find.byKey(const ValueKey('detail-read-button'))),
      footer,
    );
    final visible = _chapterTitles()
        .evaluate()
        .map((element) => element.widget as Text)
        .firstWhere((text) {
          final rect = tester.getRect(find.text(text.data!));
          return rect.top > header.bottom && rect.bottom < footer.top;
        });
    final index = int.parse(visible.data!.substring('性能目录 '.length));
    await tester.tap(find.text(visible.data!));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ReaderPage>(find.byType(ReaderPage)).initialChapter,
      index,
    );
    await tester.tap(
      find
          .descendant(
            of: find.byWidgetPredicate(
              (widget) => widget is GlassIconButton && widget.label == '返回详情',
            ),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(18000, 1));
    expect(_chapterTitles().evaluate().length, lessThanOrEqualTo(30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lazy detail chapters keep natural height at large text scale', (
    tester,
  ) async {
    const title = '性能目录 0000：这是一个较长的章节标题，放大字号后应当完整换行';
    final novel = demoNovels.first.withChapters([
      const NovelChapter(title, '正文。'),
      ...List.generate(
        999,
        (index) => NovelChapter(
          '性能目录 ${(index + 1).toString().padLeft(4, '0')}',
          '正文。',
        ),
      ),
    ]);
    await _mountDetail(tester, novel, textScale: 2);
    final scrollable = find
        .descendant(
          of: find.byType(DetailPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text(title),
      200,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(find.text(title));
    expect(text.maxLines, isNull);
    expect(tester.getSize(find.text(title)).height, greaterThan(60));
    expect(_chapterTitles().evaluate().length, lessThanOrEqualTo(30));
    expect(tester.takeException(), isNull);
  });
}
