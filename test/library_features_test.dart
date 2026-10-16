import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/novel_feed_controller.dart';

Novel _book(int id, {List<NovelChapter> chapters = const []}) => Novel(
  id: id,
  title: '作品 $id',
  author: '作者',
  genre: '轻小说',
  summary: '介绍',
  colors: const [Colors.blue, Colors.black],
  chapters: chapters,
);

String _listXml(List<int> ids, {int pages = 3, String status = '连载中'}) =>
    '<result><page num="$pages"/>${ids.map((id) => '<item aid="$id"><data name="Title" value="作品 $id"/>'
        '<data name="Author" value="作者"/><data name="BookStatus" value="$status"/>'
        '<data name="LastUpdate" value="2026-10-01"/>'
        '<data name="IntroPreview"><![CDATA[介绍 $id]]></data></item>').join()}</result>';

class _PagedRepository extends DemoNovelRepository {
  _PagedRepository(this.fetch);
  final Future<NovelPage> Function(NovelSort, int, bool) fetch;
  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) => fetch(sort, page, refresh);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'all 13 catalogue modes use the original sort and page parameters',
    () async {
      final actions = <String>[];
      final repository = LegacyWenkuRepository(
        request: (action) async {
          actions.add(action);
          return _listXml([1, 2]);
        },
      );
      expect(NovelSort.values.map((v) => v.apiKey).toSet(), {
        'lastupdate',
        'postdate',
        'allvisit',
        'allvote',
        'monthvisit',
        'monthvote',
        'weekvisit',
        'weekvote',
        'dayvisit',
        'dayvote',
        'goodnum',
        'size',
        'fullflag',
      });
      for (final sort in NovelSort.values) {
        final result = await repository.browse(sort: sort, page: 2);
        expect(actions.last, 'action=novellist&sort=${sort.apiKey}&page=2&t=0');
        expect(result.page, 2);
        expect(result.totalPages, 3);
        expect(result.hasMore, isTrue);
        expect(result.items.first.summary, '介绍 1');
      }
    },
  );

  test(
    'pages are cached independently and refresh invalidates the whole sort',
    () async {
      final actions = <String>[];
      final repository = LegacyWenkuRepository(
        request: (action) async {
          actions.add(action);
          return _listXml([actions.length]);
        },
      );
      await repository.browse();
      await repository.browse(page: 2);
      await repository.browse(page: 2);
      expect(actions.length, 2);
      await repository.browse(refresh: true);
      await repository.browse(page: 2);
      expect(actions.length, 4);
    },
  );

  test(
    'duplicate in-flight pages coalesce and old refresh results do not poison cache',
    () async {
      final replies = <Completer<String>>[];
      final repository = LegacyWenkuRepository(
        request: (_) {
          final reply = Completer<String>();
          replies.add(reply);
          return reply.future;
        },
      );
      final old = repository.browse();
      final duplicate = repository.browse();
      expect(replies.length, 1);
      final fresh = repository.browse(refresh: true);
      replies[1].complete(_listXml([9]));
      expect((await fresh).items.single.id, 9);
      replies[0].complete(_listXml([1]));
      await old;
      await duplicate;
      expect((await repository.browse()).items.single.id, 9);
    },
  );

  test('invalid list XML is an error, a declared empty list is not', () async {
    var reply = '<error>failed</error>';
    final repository = LegacyWenkuRepository(request: (_) async => reply);
    await expectLater(repository.browse(), throwsFormatException);
    reply = '<result><page num="broken"/></result>';
    await expectLater(repository.browse(), throwsFormatException);
    reply = '<result><page num="0"/></result>';
    final result = await repository.browse();
    expect(result.items, isEmpty);
    expect(result.hasMore, isFalse);
  });

  test('unfinished status is never mistaken for complete', () async {
    var status = '未完结';
    final repository = LegacyWenkuRepository(
      request: (_) async => _listXml([1], status: status),
    );
    expect((await repository.browse()).items.single.isComplete, isFalse);
    status = '已完结';
    expect(
      (await repository.browse(refresh: true)).items.single.isComplete,
      isTrue,
    );
  });

  test(
    'search loads all matching IDs in bounded metadata pages without adding API parameters',
    () async {
      final actions = <String>[];
      var active = 0;
      var peak = 0;
      final repository = LegacyWenkuRepository(
        request: (action) async {
          actions.add(action);
          final params = Uri.splitQueryString(action);
          if (params['action'] == 'search') {
            expect(params['searchkey'], '名 & 作者');
            expect(params.containsKey('page'), isFalse);
            return _listXml(
              List.generate(
                30,
                (i) => i + (params['searchtype'] == 'author' ? 21 : 1),
              ),
            );
          }
          active++;
          peak = peak < active ? active : peak;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          active--;
          final id = int.parse(params['aid']!);
          return '<metadata><data name="Title" value="作品 $id"/></metadata>';
        },
      );
      final first = await repository.searchPage('名 & 作者');
      expect(first.items.map((b) => b.id), List.generate(20, (i) => i + 1));
      expect(first.totalItems, 50);
      final second = await repository.searchPage('名 & 作者', page: 2);
      final third = await repository.searchPage('名 & 作者', page: 3);
      expect(second.items.map((b) => b.id), List.generate(20, (i) => i + 21));
      expect(third.items.map((b) => b.id), List.generate(10, (i) => i + 41));
      expect(third.hasMore, isFalse);
      expect(actions.where((a) => a.startsWith('action=search')).length, 2);
      expect(peak, lessThanOrEqualTo(4));
    },
  );

  test(
    'malformed search responses are recoverable failures rather than no results',
    () async {
      var bad = true;
      final repository = LegacyWenkuRepository(
        request: (action) async => action.startsWith('action=search')
            ? (bad ? '<error>failed</error>' : '<result/>')
            : '<metadata/>',
      );
      await expectLater(repository.searchPage('作品'), throwsFormatException);
      bad = false;
      expect((await repository.searchPage('作品')).items, isEmpty);
    },
  );

  test('metadata requests for an old shelf ID coalesce', () async {
    final reply = Completer<String>();
    var calls = 0;
    final repository = LegacyWenkuRepository(
      request: (_) {
        calls++;
        return reply.future;
      },
    );
    final first = repository.find(9999);
    final second = repository.find(9999);
    reply.complete('<metadata><data name="Title" value="书架作品"/></metadata>');
    expect((await first)!.title, '书架作品');
    expect((await second)!.title, '书架作品');
    expect(calls, 1);
  });

  test('opening details refreshes a previously cached directory', () async {
    var chapterCalls = 0;
    final repository = LegacyWenkuRepository(
      request: (action) async {
        if (action.contains('do=list')) {
          chapterCalls++;
          return '<book><chapter cid="$chapterCalls">第一章</chapter></book>';
        }
        if (action.contains('do=intro')) return '<intro>简介</intro>';
        return '<metadata><data name="Title" value="作品"/></metadata>';
      },
    );
    await repository.chapters(1);
    await repository.chapters(1);
    expect(chapterCalls, 1);
    await repository.detail(_book(1));
    expect((await repository.chapters(1)).single.id, 2);
  });

  test(
    'failed next page retains items and cursor and requires explicit retry',
    () async {
      final calls = <(int, bool)>[];
      var fail = true;
      final feed = NovelFeedController(
        _PagedRepository((sort, page, refresh) async {
          calls.add((page, refresh));
          if (page == 2 && fail) throw StateError('network');
          return NovelPage(items: [_book(page)], page: page, totalPages: 2);
        }),
      );
      addTearDown(feed.dispose);
      await feed.loadInitial();
      expect(feed.resultRevision, 1);
      expect(feed.resultStartIndex, 0);
      await feed.loadMore();
      expect(feed.resultRevision, 1);
      expect(feed.items.single.id, 1);
      expect(feed.page, 1);
      await feed.loadMore();
      expect(calls.length, 2);
      fail = false;
      await feed.retry();
      expect(calls.last, (2, true));
      expect(feed.items.map((b) => b.id), [1, 2]);
      expect(feed.resultRevision, 2);
      expect(feed.resultStartIndex, 1);
      expect(feed.hasMore, isFalse);
    },
  );

  test(
    'refresh errors keep old content and retry starts from page one',
    () async {
      var fail = false;
      final calls = <int>[];
      final feed = NovelFeedController(
        _PagedRepository((sort, page, refresh) async {
          calls.add(page);
          if (fail) throw StateError('offline');
          return NovelPage(items: [_book(page)], page: page, totalPages: 3);
        }),
      );
      addTearDown(feed.dispose);
      await feed.loadInitial();
      await feed.loadMore();
      fail = true;
      await feed.refresh();
      expect(feed.page, 2);
      expect(feed.items.length, 2);
      expect(feed.refreshFailed, isTrue);
      fail = false;
      await feed.retry();
      expect(calls.last, 1);
      expect(feed.items.single.id, 1);
    },
  );

  test(
    'switching sort isolates late responses and duplicate books are merged',
    () async {
      final pending = Completer<NovelPage>();
      final feed = NovelFeedController(
        _PagedRepository((sort, page, refresh) async {
          if (sort == NovelSort.lastUpdate) return pending.future;
          return NovelPage(
            items: [_book(9), if (page > 1) _book(10)],
            page: page,
            totalPages: 2,
          );
        }),
      );
      addTearDown(feed.dispose);
      final old = feed.loadInitial();
      await feed.selectSort(NovelSort.allVisit);
      pending.complete(NovelPage(items: [_book(1)], page: 1, totalPages: 1));
      await old;
      expect(feed.items.single.id, 9);
      await feed.loadMore();
      expect(feed.items.map((b) => b.id), [9, 10]);
    },
  );

  test(
    'dispose ignores an outstanding page without notifying listeners',
    () async {
      final pending = Completer<NovelPage>();
      final feed = NovelFeedController(
        _PagedRepository((_, _, _) => pending.future),
      );
      var notifications = 0;
      feed.addListener(() => notifications++);
      final loading = feed.loadInitial();
      feed.dispose();
      pending.complete(const NovelPage(items: [], page: 1, totalPages: 0));
      await loading;
      expect(notifications, 1);
    },
  );

  test(
    'saved metadata is independent of recent results and excludes chapter bodies',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      final book = _book(
        5000,
        chapters: const [NovelChapter('标题', '正文不应写入快照', id: 50)],
      );
      await state.toggleShelf(book.id, novel: book);
      final reloaded = await LibraryState.load();
      expect(reloaded.shelf, {5000});
      expect(reloaded.cachedNovel(5000)!.title, book.title);
      expect(reloaded.cachedNovel(5000)!.chapterCount, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('novel_meta_5000'), isNot(contains('正文不应写入快照')));
    },
  );

  test(
    'legacy IDs and chapter records survive malformed cache records',
    () async {
      SharedPreferences.setMockInitialValues({
        'shelf': ['5000', 'oops', '0', '-1'],
        'chapter_5000': 7,
        'chapter_999': 'broken',
        'novel_meta_5000': '{broken',
        'reading_position_5000': '[]',
      });
      final state = await LibraryState.load();
      expect(state.shelf, {5000});
      expect(state.chapterFor(5000), 7);
      expect(state.cachedNovel(5000), isNull);
      expect(state.positionFor(5000), isNull);
    },
  );

  test(
    'positions persist in order and stable chapter IDs survive a reordered directory',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      final book = _book(
        99,
        chapters: const [
          NovelChapter('A', '', id: 100),
          NovelChapter('B', '', id: 200),
        ],
      );
      final first = state.savePosition(
        novel: book,
        chapter: 1,
        offset: 100,
        maximum: 1000,
        width: 400,
      );
      final last = state.savePosition(
        novel: book,
        chapter: 1,
        offset: 350,
        maximum: 1000,
        width: 400,
      );
      await Future.wait([first, last]);
      final reloaded = await LibraryState.load();
      expect(reloaded.positionFor(99)!.offset, 350);
      expect(reloaded.positionFor(99)!.fraction, .35);
      final changed = book.withChapters([
        const NovelChapter('新增', '', id: 50),
        ...book.chapters,
      ]);
      expect(reloaded.chapterForNovel(changed), 2);
      final cached = reloaded.cachedNovel(99)!;
      expect(reloaded.chapterForNovel(cached), 1);
    },
  );

  test(
    'removing a shelf book preserves progress and supports re-adding',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      await state.toggleShelf(1, novel: _book(1));
      await state.setChapter(1, 4);
      await state.toggleShelf(1);
      expect(state.contains(1), isFalse);
      expect(state.chapterFor(1), 4);
      await state.toggleShelf(1);
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('novel_meta_1')!)['title'], '作品 1');
      expect(state.addedAt(1), greaterThan(0));
    },
  );
}
