import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/novel_feed_controller.dart';
import 'package:wenku8_flutter/pages.dart';
import 'dart:async';

Widget _sample({
  int generation = 0,
  int first = 0,
  bool reduced = false,
  bool visible = true,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: TickerMode(
      enabled: visible,
      child: LoadedContentSequence(
        generation: generation,
        firstIndex: first,
        child: ListView.builder(
          key: const ValueKey('sample-scroll'),
          itemCount: 100,
          itemBuilder: (context, index) => LoadedContentItem(
            key: ValueKey('sample-$index'),
            index: index,
            child: SizedBox(height: 80, child: Text('第 $index 项')),
          ),
        ),
      ),
    ),
  ),
);

double _revealProgress(WidgetTester tester, int index) {
  final match = find.descendant(
    of: find.byKey(ValueKey('sample-$index')),
    matching: find.byType(ArchiveReveal),
  );
  return match.evaluate().isEmpty
      ? 1
      : tester.renderObject<ArchiveRevealRender>(match).progress;
}

void main() {
  testWidgets('one bounded clock reveals a loaded batch from top to bottom', (
    tester,
  ) async {
    await tester.pumpWidget(_sample());
    expect(
      _revealProgress(tester, 0),
      1,
    ); // An already loaded/cached mount is static.
    await tester.pumpWidget(_sample(generation: 1));
    await tester.pump(const Duration(milliseconds: 80));
    expect(_revealProgress(tester, 0), greaterThan(_revealProgress(tester, 1)));
    expect(_revealProgress(tester, 1), greaterThan(_revealProgress(tester, 2)));
    await tester.pumpAndSettle();
    expect(_revealProgress(tester, 0), 1);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(_sample(generation: 1));
    expect(_revealProgress(tester, 0), 1);
    await tester.drag(
      find.byKey(const ValueKey('sample-scroll')),
      const Offset(0, -1600),
    );
    await tester.pumpAndSettle();
    for (final item in find.byType(ArchiveReveal).evaluate()) {
      expect((item.renderObject! as ArchiveRevealRender).progress, 1);
    }
    await tester.drag(
      find.byKey(const ValueKey('sample-scroll')),
      const Offset(0, 1600),
    );
    await tester.pumpAndSettle();
    expect(_revealProgress(tester, 0), 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'pagination only reveals new rows; reduced and offstage loads stay static',
    (tester) async {
      await tester.pumpWidget(_sample());
      await tester.pumpWidget(_sample(generation: 1, first: 3));
      await tester.pump(const Duration(milliseconds: 70));
      expect(_revealProgress(tester, 0), 1);
      expect(_revealProgress(tester, 2), 1);
      expect(
        _revealProgress(tester, 3),
        greaterThan(_revealProgress(tester, 4)),
      );
      await tester.pumpWidget(_sample(generation: 2, reduced: true));
      await tester.pumpAndSettle();
      expect(find.byType(ArchiveReveal), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(_sample(generation: 3, visible: false));
      await tester.pumpWidget(_sample(generation: 3));
      expect(_revealProgress(tester, 0), 1);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'pagination and pull refresh use only skeletons and preserve scroll',
    (tester) async {
      final repo = _PendingPages();
      final feed = NovelFeedController(repo, search: true);
      addTearDown(feed.dispose);
      await feed.loadInitial();
      // No state actions are used by the results while loading.
      await tester.pumpWidget(
        MaterialApp(
          home: AnimatedBuilder(
            animation: feed,
            builder: (context, _) => FeedRefresh(
              feed: feed,
              child: ListView(
                key: const ValueKey('refresh-scroll'),
                children: [
                  for (var i = 0; i < 30; i++)
                    SizedBox(height: 60, child: Text('现有内容 $i')),
                  FeedFooter(feed: feed),
                ],
              ),
            ),
          ),
        ),
      );
      final load = feed.loadMore();
      await tester.pump();
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(find.byType(BookRowSkeleton), findsOneWidget);
      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      repo.page.complete(
        NovelPage(items: [demoNovels[1]], page: 2, totalPages: 2),
      );
      await load;
      await tester.pumpAndSettle();
      scroll.position.jumpTo(120);
      await tester.pump();
      final refresh = feed.refresh();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('feed-refresh-skeleton')),
        findsOneWidget,
      );
      expect(scroll.position.pixels, 120);
      repo.refresh.complete(
        NovelPage(items: [demoNovels.first], page: 1, totalPages: 2),
      );
      await refresh;
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, 120);
      expect(find.byKey(const ValueKey('feed-refresh-skeleton')), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}

class _PendingPages extends DemoNovelRepository {
  final page = Completer<NovelPage>();
  final refresh = Completer<NovelPage>();
  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) async {
    if (refresh) return this.refresh.future;
    if (page == 2) return this.page.future;
    return NovelPage(items: [demoNovels.first], page: 1, totalPages: 2);
  }
}
