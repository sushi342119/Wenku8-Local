import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/pages.dart';

double _revealProgress(WidgetTester tester, String key) => tester
    .renderObject<ArchiveRevealRender>(
      find
          .descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(ArchiveReveal),
          )
          .first,
    )
    .progress;

void main() {
  testWidgets('library loading is a static skeleton without a loader', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    final repository = _PendingLibrary();
    await tester.pumpWidget(NovelApp(state: state, repository: repository));
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.byType(LibrarySkeleton), findsOneWidget);
    expect(find.byType(LoadingSkeleton), findsWidgets);
    expect(find.byType(ArchiveShelfSkeleton), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('正在翻开文库'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(find.byType(FrostedHeader), findsOneWidget);
    repository.books.complete(demoNovels);
    await tester.pumpAndSettle();
    expect(find.byType(LoadingSkeleton), findsNothing);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.byType(DiscoverPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('reader uses paragraph skeletons until actual content arrives', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    final repository = _PendingContent();
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.dark),
        home: ReaderPage(
          novel: demoNovels.first,
          state: state,
          repository: repository,
          initialChapter: 0,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ReaderSkeleton), findsOneWidget);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('正在加载正文'), findsOneWidget);
    repository.content.complete('第一段正文。\n\n第二段正文。');
    for (
      var frame = 0;
      frame < 10 && find.byType(ReaderSkeleton).evaluate().isNotEmpty;
      frame++
    ) {
      await tester.pump();
    }
    expect(find.byType(ReaderSkeleton), findsNothing);
    // The clock starts after lazy layout/restoration, then receives its first
    // timestamp on the next frame. Measure elapsed reveal time after that.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      _revealProgress(tester, 'reader-paragraph-reveal-0'),
      greaterThan(_revealProgress(tester, 'reader-paragraph-reveal-1')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ReaderSkeleton), findsNothing);
    expect(find.text('第一段正文。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('detail reveals after the paper flight and then stays still', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(demoNovels.first.title).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_revealProgress(tester, 'detail-title-reveal'), 0);
    expect(_revealProgress(tester, 'detail-summary-reveal'), 0);
    await tester.pump(
      NovelMotion.coverFlight - const Duration(milliseconds: 80),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final title = _revealProgress(tester, 'detail-title-reveal');
    final author = _revealProgress(tester, 'detail-author-reveal');
    final summary = _revealProgress(tester, 'detail-summary-reveal');
    expect(title, greaterThan(author));
    expect(author, greaterThan(summary));
    expect(summary, 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      _revealProgress(tester, 'detail-summary-reveal'),
      greaterThan(_revealProgress(tester, 'detail-directory-reveal')),
    );
    await tester.pump(const Duration(milliseconds: 800));
    for (final part in ['title', 'author', 'meta', 'summary', 'directory']) {
      expect(_revealProgress(tester, 'detail-$part-reveal'), 1);
    }
    final hero = find.descendant(
      of: find.byType(DetailPage),
      matching: find.byType(Hero),
    );
    final rect = tester.getRect(hero);
    expect(find.byType(PaperCoverFlight), findsNothing);
    expect(find.byType(PaperCoverBend), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.getRect(hero), rect);
    await state.setReduceMotion(true);
    await tester.pumpAndSettle();
    expect(find.byType(PaperCoverBend), findsNothing);
    expect(find.byType(CoverGlow), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion leaves the skeleton fully static', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Stack(
              children: [
                const Positioned.fill(child: LibrarySkeleton()),
                Center(
                  child: NovelCover(
                    demoNovels.first,
                    width: 118,
                    height: 166,
                    isDetailCover: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PaperCoverBend), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('正在翻开文库'), findsOneWidget);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

class _PendingLibrary extends DemoNovelRepository {
  final books = Completer<List<Novel>>();
  @override
  Future<List<Novel>> list() => books.future;
}

class _PendingContent extends DemoNovelRepository {
  final content = Completer<String>();
  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) =>
      content.future;
}
