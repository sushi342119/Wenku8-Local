import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/novel_feed_controller.dart';

List<Novel> _books(int page) => [
  for (var i = 0; i < 20; i++)
    Novel(
      id: page * 100 + i,
      title: '档案 $page-$i',
      author: '作者',
      genre: '轻小说',
      summary: '',
      colors: demoNovels.first.colors,
    ),
];

class _Pages extends DemoNovelRepository {
  _Pages(this.response);
  final Future<NovelPage> Function(NovelSort, int, bool) response;
  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) => response(sort, page, refresh);
}

void main() {
  test(
    'discovery publishes the first files while warming a 60-book list in order',
    () async {
      final calls = <int>[];
      final next = Completer<NovelPage>();
      final feed = NovelFeedController(
        _Pages((sort, page, refresh) async {
          calls.add(page);
          if (page == 2) return next.future;
          return NovelPage(items: _books(page), page: page, totalPages: 8);
        }),
        initialItems: 60,
      );
      addTearDown(feed.dispose);
      final firstPublished = Completer<void>();
      feed.addListener(() {
        if (feed.items.length == 20 && !firstPublished.isCompleted) {
          firstPublished.complete();
        }
      });
      final load = feed.loadInitial();
      await firstPublished.future;
      expect(feed.items.length, 20);
      expect(feed.loading, isTrue);
      expect(feed.resultStartIndex, 0);
      expect(calls, [1, 2]);
      next.complete(NovelPage(items: _books(2), page: 2, totalPages: 8));
      await load;
      expect(calls, [1, 2, 3]);
      expect(feed.items.length, 60);
      expect(feed.resultStartIndex, 40);
      expect(feed.resultRevision, 3);
      expect(feed.hasMore, isTrue);
      expect(feed.loading, isFalse);
      await feed.loadMore();
      expect(calls, [1, 2, 3, 4]);
      expect(feed.items.length, 80);
    },
  );

  test('a late warmed page cannot cross a category switch', () async {
    final pending = Completer<NovelPage>();
    final pageTwoRequested = Completer<void>();
    final calls = <(NovelSort, int)>[];
    final feed = NovelFeedController(
      _Pages((sort, page, refresh) async {
        calls.add((sort, page));
        if (sort == NovelSort.lastUpdate && page == 2) {
          pageTwoRequested.complete();
          return pending.future;
        }
        return NovelPage(
          items: _books(sort == NovelSort.lastUpdate ? page : page + 10),
          page: page,
          totalPages: 8,
        );
      }),
      initialItems: 60,
    );
    addTearDown(feed.dispose);
    final old = feed.loadInitial();
    await pageTwoRequested.future;
    await feed.selectSort(NovelSort.allVisit);
    pending.complete(NovelPage(items: _books(2), page: 2, totalPages: 8));
    await old;
    expect(feed.items.length, 60);
    expect(feed.items.first.id, 1100);
    expect(feed.sort, NovelSort.allVisit);
    expect(calls.where((c) => c.$1 == NovelSort.lastUpdate).map((c) => c.$2), [
      1,
      2,
    ]);
    expect(feed.error, isNull);
    expect(feed.loading, isFalse);
  });

  test(
    'warm-up failure keeps page one and resumes the failed cursor only on retry',
    () async {
      var fail = true;
      final calls = <(int, bool)>[];
      final feed = NovelFeedController(
        _Pages((sort, page, refresh) async {
          calls.add((page, refresh));
          if (page == 2 && fail) throw StateError('network');
          return NovelPage(items: _books(page), page: page, totalPages: 8);
        }),
        initialItems: 60,
      );
      addTearDown(feed.dispose);
      await feed.loadInitial();
      expect(feed.page, 1);
      expect(feed.items.length, 20);
      expect(feed.refreshFailed, isFalse);
      expect(feed.error, isNotNull);
      await feed.loadMore();
      expect(calls, [(1, false), (2, false)]);
      fail = false;
      await feed.retry();
      expect(calls, [(1, false), (2, false), (2, true), (3, true)]);
      expect(feed.items.length, 60);
      expect(feed.error, isNull);
    },
  );

  test(
    'short, empty and duplicate services cannot trigger an unbounded warm-up',
    () async {
      for (final (count, pages) in [(7, 1), (0, 9), (20, 9)]) {
        final calls = <int>[];
        final feed = NovelFeedController(
          _Pages((sort, page, refresh) async {
            calls.add(page);
            return NovelPage(
              items: _books(1).take(count).toList(),
              page: page,
              totalPages: pages,
            );
          }),
          initialItems: 60,
        );
        await feed.loadInitial();
        expect(calls.length, lessThanOrEqualTo(2));
        expect(feed.items.length, count);
        expect(feed.loading, isFalse);
        feed.dispose();
      }
    },
  );

  test(
    'disposing while warming never requests another page or notifies again',
    () async {
      final second = Completer<NovelPage>();
      final requested = Completer<void>();
      final calls = <int>[];
      final feed = NovelFeedController(
        _Pages((sort, page, refresh) async {
          calls.add(page);
          if (page == 2) {
            requested.complete();
            return second.future;
          }
          return NovelPage(items: _books(page), page: page, totalPages: 8);
        }),
        initialItems: 60,
      );
      var notices = 0;
      feed.addListener(() => notices++);
      final load = feed.loadInitial();
      await requested.future;
      final before = notices;
      feed.dispose();
      second.complete(NovelPage(items: _books(2), page: 2, totalPages: 8));
      await load;
      expect(notices, before);
      expect(calls, [1, 2]);
    },
  );
}
