import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/novel_feed_controller.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/ui_notifiers.dart';

import 'support/offline_fixture.dart';

class _Search extends DemoNovelRepository {
  final calls = <String>[];
  final replies = <String, Completer<NovelPage>>{};
  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) {
    calls.add(query);
    return replies.putIfAbsent(query, Completer<NovelPage>.new).future;
  }
}

class _DelayedDeletionCache extends OfflineCacheStore {
  _DelayedDeletionCache(super.directory);
  final removed = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> clear() async {
    await super.clear();
    removed.complete();
    await release.future;
  }

  @override
  Future<void> removeBook(int id) async {
    await super.removeBook(id);
    removed.complete();
    await release.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '120 input edits request one final query and isolate stale responses',
    (tester) async {
      final repository = _Search();
      final feed = NovelFeedController(repository, search: true);
      addTearDown(feed.dispose);
      final old = feed.searchFor('old');
      for (var index = 0; index < 120; index++) {
        feed.scheduleSearch('query-$index');
        await tester.pump(const Duration(milliseconds: 2));
      }
      expect(repository.calls, ['old']);
      repository.replies['old']!.complete(
        NovelPage(items: [demoNovels.first], page: 1),
      );
      await old;
      expect(feed.items, isEmpty);
      expect(feed.loading, isTrue);
      await feed.loadMore();
      expect(repository.calls, ['old']);
      await tester.pump(const Duration(milliseconds: 300));
      expect(repository.calls, ['old', 'query-119']);
      repository.replies['query-119']!.complete(
        NovelPage(items: [demoNovels.last], page: 1, totalPages: 1),
      );
      await tester.pump();
      expect(feed.items.single, demoNovels.last);
      expect(feed.loading, isFalse);
    },
  );

  testWidgets(
    'search submit flushes the timer and disposal cancels pending work',
    (tester) async {
      final repository = _Search();
      final feed = NovelFeedController(repository, search: true);
      feed.scheduleSearch('submitted');
      final submitted = feed.searchFor('submitted');
      expect(repository.calls, ['submitted']);
      repository.replies['submitted']!.complete(
        const NovelPage(items: [], page: 1, totalPages: 0),
      );
      await submitted;
      await tester.pump(const Duration(milliseconds: 500));
      expect(repository.calls, ['submitted']);
      feed.scheduleSearch('closed');
      feed.cancelScheduledSearch();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repository.calls, ['submitted']);
      feed.scheduleSearch('disposed');
      feed.dispose();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repository.calls, ['submitted']);
    },
  );

  testWidgets(
    'repeated submit shares in-flight work and a failed page can restart the same query',
    (tester) async {
      final repository = _Search();
      final feed = NovelFeedController(repository, search: true);
      addTearDown(feed.dispose);
      final initial = feed.searchFor('same');
      await feed.searchFor('same');
      expect(repository.calls, ['same']);
      repository.replies['same']!.complete(
        NovelPage(items: [demoNovels.first], page: 1, totalPages: 2),
      );
      await initial;
      final next = repository.replies['same'] = Completer<NovelPage>();
      final more = feed.loadMore();
      next.completeError(StateError('page two failed'));
      await more;
      expect(feed.page, 1);
      expect(feed.error, isNotNull);
      final retry = repository.replies['same'] = Completer<NovelPage>();
      feed.scheduleSearch('same');
      await tester.pump(const Duration(milliseconds: 300));
      expect(repository.calls, ['same', 'same', 'same']);
      retry.complete(
        NovelPage(items: [demoNovels.last], page: 1, totalPages: 1),
      );
      await tester.pump();
      expect(feed.error, isNull);
      expect(feed.items.single, demoNovels.last);
    },
  );

  testWidgets(
    'visual notifications are coalesced once per frame and disposed callbacks stay quiet',
    (tester) async {
      final notifier = FrameChangeNotifier();
      var notifications = 0;
      notifier.addListener(() => notifications++);
      for (var index = 0; index < 120; index++) {
        notifier.notifyListeners();
      }
      expect(notifications, 0);
      await tester.pump();
      expect(notifications, 1);
      notifier.notifyListeners();
      notifier.dispose();
      await tester.pump();
      expect(notifications, 1);
    },
  );

  testWidgets(
    'retained inactive tabs do not rebuild and catch up on activation',
    (tester) async {
      final value = ValueNotifier(0);
      addTearDown(value.dispose);
      var builds = 0;
      Widget tree(bool active) => Directionality(
        textDirection: TextDirection.ltr,
        child: TickerMode(
          enabled: active,
          child: ActiveListenableBuilder(
            listenable: value,
            builder: (_) {
              builds++;
              return Text('${value.value}');
            },
          ),
        ),
      );
      await tester.pumpWidget(tree(false));
      final baseline = builds;
      for (var index = 1; index <= 120; index++) {
        value.value = index;
        await tester.pump();
      }
      expect(builds, baseline);
      await tester.pumpWidget(tree(true));
      expect(builds, baseline + 1);
      expect(find.text('120'), findsOneWidget);
    },
  );

  test(
    'bad appearance preferences fall back and a typography transaction notifies once',
    () async {
      SharedPreferences.setMockInitialValues({
        'theme': 3,
        'reduceMotion': 'bad',
        'glassBlur': double.nan,
        'glassOpacity': 'bad',
      });
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      expect(state.theme, ThemeMode.system);
      expect(state.reduceMotion, isFalse);
      expect(state.glassBlur, 8);
      expect(state.glassOpacity, .87);
      var typography = 0;
      var appearance = 0;
      state.readerSettingsChanges.addListener(() => typography++);
      state.appearanceChanges.addListener(() => appearance++);
      await state.setTypography(fontSize: 23, lineHeight: 1.95);
      expect(typography, 1);
      await state.setTypography(fontSize: 23, lineHeight: 1.95);
      await state.setGlassBlur(double.nan);
      await state.setGlassOpacity(double.infinity);
      await state.setTheme(ThemeMode.system);
      await state.setReduceMotion(false);
      expect(typography, 1);
      expect(appearance, 0);
      final restored = await LibraryState.load();
      addTearDown(restored.dispose);
      expect(restored.fontSize, 23);
      expect(restored.lineHeight, 1.95);
    },
  );

  test(
    'paragraph anchors and text scale survive resume and bookmark persistence',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final book = offlineFixtureBook(71);
      await state.savePosition(
        novel: book,
        chapter: 0,
        offset: 1500,
        maximum: 5000,
        width: 400,
        paragraphIndex: 19,
        paragraphFraction: .37,
        textScale: 1.3,
      );
      await state.addBookmark(novel: book, position: state.positionFor(71)!);
      final restored = await LibraryState.load();
      addTearDown(restored.dispose);
      expect(restored.positionFor(71)!.paragraphIndex, 19);
      expect(restored.bookmarksFor(71).single.position.paragraphFraction, .37);
      expect(restored.positionFor(71)!.textScale, 1.3);
      final legacy = ReadingPosition.fromJson({
        'chapter': 0,
        'paragraphIndex': -2,
        'paragraphFraction': double.nan,
        'textScale': 'bad',
      });
      expect(legacy.paragraphIndex, isNull);
      expect(legacy.paragraphFraction, 0);
      expect(legacy.textScale, 1);
    },
  );

  test(
    'rapid shelf toggles serialize snapshots without changing final membership',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final book = offlineFixtureBook(71);
      await Future.wait(
        List.generate(41, (_) => state.toggleShelf(71, novel: book)),
      );
      final restored = await LibraryState.load();
      addTearDown(restored.dispose);
      expect(restored.contains(71), isTrue);
      expect(restored.cachedNovel(71)!.title, book.title);
      expect(state.debugMetadataEncodeCount, 1);
    },
  );

  test(
    'directory requests coalesce and pre-refresh results never overwrite newer chapters',
    () async {
      final replies = <Completer<String>>[];
      final actions = <String>[];
      final repository = LegacyWenkuRepository(
        request: (action) async {
          actions.add(action);
          if (action.contains('do=list')) {
            final reply = Completer<String>();
            replies.add(reply);
            return reply.future;
          }
          if (action.contains('do=intro')) return '<intro>介绍</intro>';
          return '<metadata><data name="Title" value="作品"/></metadata>';
        },
      );
      final old = repository.chapters(71);
      final duplicate = repository.chapters(71);
      expect(replies.length, 1);
      await Future.wait([
        repository.detail(offlineFixtureBook(71)),
        repository.detail(offlineFixtureBook(71)),
      ]);
      expect(actions.where((action) => action.contains('do=intro')).length, 1);
      final fresh = repository.chapters(71);
      replies[1].complete('<book><chapter cid="72">新章</chapter></book>');
      expect((await fresh).single.id, 72);
      replies[0].complete('<book><chapter cid="71">旧章</chapter></book>');
      await old;
      await duplicate;
      expect((await repository.chapters(71)).single.id, 72);
    },
  );

  test(
    'large directory/body decoding preserves protocol and immutable ordered paragraphs',
    () async {
      final source =
          ' 第一行 \r\n${'超长正文 😀 ' * 12000}\r\n<!--image-->图像<!--image-->\r\n末行';
      final repository = LegacyWenkuRepository(
        request: (action) async {
          if (action.contains('do=list')) {
            return '<book>${List.generate(1200, (i) => '<chapter cid="${i + 1}">章节 $i ${'标题' * 30}</chapter>').join()}</book>';
          }
          return source;
        },
      );
      final chapters = await repository.chapters(71);
      expect(chapters.length, 1200);
      expect(chapters.last.id, 1200);
      final normalized = await repository.chapterContent(71, chapters.first);
      final content = await ReaderContent.parse(normalized);
      expect(content.paragraphs, [
        '第一行',
        '超长正文 😀 ' * 11999 + '超长正文 😀',
        '[插图]',
        '末行',
      ]);
      expect(() => content.paragraphs.add('extra'), throwsUnsupportedError);
      await expectLater(ReaderContent.parse(' \n '), throwsFormatException);
    },
  );

  testWidgets('cache changes update only the affected book visual observers', (
    tester,
  ) async {
    final folder = await tester.runAsync(
      () => Directory.systemTemp.createTemp('novel8-polish-notify-'),
    );
    final cache = OfflineCacheStore(folder!);
    final remote = OfflineFixtureRepository(
      books: [offlineFixtureBook(71), offlineFixtureBook(72)],
    );
    final repository = OfflineNovelRepository(remote: remote, cache: cache);
    addTearDown(() async {
      repository.dispose();
      cache.dispose();
      await folder.delete(recursive: true);
    });
    var first = 0;
    var second = 0;
    repository.bookChanges(71).addListener(() => first++);
    repository.bookChanges(72).addListener(() => second++);
    await tester.runAsync(() async {
      await cache.saveBook(remote.books[71]!, epoch: cache.epochFor(71));
      await cache.saveBook(remote.books[72]!, epoch: cache.epochFor(72));
    });
    await tester.pump();
    first = second = 0;
    await tester.runAsync(
      () => cache.saveChapter(71, 71001, '正文', epoch: cache.epochFor(71)),
    );
    await tester.pump();
    expect(first, 1);
    expect(second, 0);
    expect(cache.book(71)!.cachedCount, 1);
    expect(cache.book(71)!.bytes, 6);
    final directoryIndex = cache.book(71)!.chapterIds;
    await tester.runAsync(
      () => cache.saveChapter(71, 71001, '新正文', epoch: cache.epochFor(71)),
    );
    expect(cache.book(71)!.chapterIds, same(directoryIndex));
    expect(cache.book(71)!.cachedCount, 1);
    expect(cache.book(71)!.bytes, 9);
  });

  for (final all in [false, true]) {
    test(
      'a new download remains tracked when ${all ? 'all-cache' : 'book'} deletion completes later',
      () async {
        final folder = await Directory.systemTemp.createTemp(
          'novel8-delete-order-',
        );
        final cache = _DelayedDeletionCache(folder);
        final remote = OfflineFixtureRepository();
        final repository = OfflineNovelRepository(remote: remote, cache: cache);
        addTearDown(() async {
          repository.dispose();
          cache.dispose();
          await folder.delete(recursive: true);
        });
        await cache.load();
        final deletion = all
            ? repository.clearCache()
            : repository.removeCachedBook(71);
        await cache.removed.future;
        repository.download(remote.books[71]!);
        final newer = repository.jobFor(71)!;
        cache.release.complete();
        await deletion;
        expect(repository.jobFor(71), same(newer));
        await offlineWaitUntil(() => !newer.active);
        expect(newer.phase, DownloadPhase.completed);
        expect(cache.book(71)!.cachedCount, 3);
      },
    );
  }
}
