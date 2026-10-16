import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/offline_cache.dart';
import 'package:wenku8_flutter/offline_repository.dart';
import 'package:wenku8_flutter/offline_widgets.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_illustrations.dart';

import 'support/offline_fixture.dart';

Finder _control(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (w) => w is GlassIconButton && w.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;

Widget _app(
  Widget home,
  GlobalKey capture, {
  Brightness brightness = Brightness.light,
}) => RepaintBoundary(
  key: capture,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: novelTheme(brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: home,
  ),
);

Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 12)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

Future<void> _tapIo(
  WidgetTester tester,
  Finder finder, {
  bool Function()? until,
}) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
  if (until != null) {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    // Route futures and widget callbacks live in the test's fake zone. Pump
    // their microtasks between real file-system turns instead of blocking that
    // zone inside runAsync while waiting for the application to make progress.
    while (!until() && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(until(), isTrue, reason: 'offline UI operation did not complete');
    await tester.pumpAndSettle();
  }
}

class _HeldDetail extends OfflineFixtureRepository {
  final reply = Completer<Novel>();
  @override
  Future<Novel> detail(Novel novel) => reply.future;
}

void main({
  Future<void> Function(WidgetTester tester, GlobalKey key, String name)?
  capture,
}) {
  late Directory directory;
  late OfflineCacheStore cache;
  late OfflineFixtureRepository remote;
  late OfflineNovelRepository repository;
  late LibraryState state;
  final novel = offlineFixtureBook(71);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    state = await LibraryState.load();
    await state.setReduceMotion(true);
    directory = await Directory.systemTemp.createTemp('novel8-offline-ui-');
    cache = OfflineCacheStore(directory);
    remote = OfflineFixtureRepository();
    repository = OfflineNovelRepository(remote: remote, cache: cache);
    await repository.loadCache();
  });
  tearDown(() async {
    repository.dispose();
    cache.dispose();
    state.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  testWidgets(
    'old image slots repair after text appears and keep text on failure',
    (tester) async {
      const old = '前文。\n\n[插图]\n\n后文。';
      const fresh =
          '前文。\n\n<!--image-->https://pic.777743.xyz/1/a.jpg<!--image-->\n\n后文。';
      final held = remote.held[71001] = Completer<String>();
      await tester.runAsync(() async {
        await repository.rememberDirectory(novel);
        await cache.saveChapter(71, 71001, old, epoch: cache.epochFor(71));
      });
      await tester.pumpWidget(
        _app(
          ReaderPage(
            novel: novel,
            state: state,
            repository: repository,
            initialChapter: 0,
          ),
          GlobalKey(),
        ),
      );
      await _settleIo(tester);
      expect(find.text('前文。'), findsOneWidget);
      expect(remote.activeReads, 1);
      final slot = find.byWidgetPredicate(
        (w) => w is LoadingSkeleton && w.label == '正在补全插图',
      );
      expect(slot, findsOneWidget);
      final height = tester.getSize(slot).height;
      held.completeError(StateError('fixture offline'));
      await _settleIo(tester);
      expect(find.text('前文。'), findsOneWidget);
      expect(find.text('重试本章插图'), findsOneWidget);
      expect(await tester.runAsync(() => cache.readChapter(71, 71001)), old);
      remote.held.remove(71001);
      remote.books[71] = novel.withChapters([
        const NovelChapter('插图', fresh, id: 71001),
      ]);
      await tester.drag(
        find.byKey(const ValueKey('reader-scroll')),
        const Offset(0, -360),
      );
      await tester.pumpAndSettle();
      expect(find.text('重试本章插图').hitTestable(), findsOneWidget);
      await _tapIo(
        tester,
        find.text('重试本章插图').hitTestable(),
        until: () =>
            remote.calls.where((call) => call == 'text:71:71001').length == 2,
      );
      await _settleIo(tester);
      expect(await tester.runAsync(() => cache.readChapter(71, 71001)), fresh);
      expect(find.byType(ReaderIllustration), findsOneWidget);
      expect(
        tester.getSize(find.byType(ReaderIllustration)).height,
        closeTo(height, .01),
      );
      expect(find.text('暂未取得本章插图地址'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleIo(tester);
    },
  );

  testWidgets('download menu reuses glass and downloaded body reads offline', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      _app(DetailPage(novel: novel, state: state, repository: repository), key),
    );
    await tester.pumpAndSettle();
    await _tapIo(tester, _control('下载与缓存'));
    expect(find.byType(GlassOverlaySurface), findsOneWidget);
    expect(find.byType(LiquidGlass), findsWidgets);
    if (capture != null) await capture(tester, key, 'offline-detail-menu');
    await _tapIo(
      tester,
      find.text('下载全部章节'),
      until: () => repository.jobFor(71)?.phase == DownloadPhase.completed,
    );
    expect(cache.book(71)!.cachedCount, 3);
    expect(find.text('缓存 3 / 3 章'), findsOneWidget);
    if (capture != null) await capture(tester, key, 'offline-detail-ready');
    remote.disconnected = true;
    final before = remote.calls.length;
    await _tapIo(tester, find.byKey(const ValueKey('detail-read-button')));
    await _settleIo(tester);
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(find.textContaining('正文 71-1'), findsWidgets);
    expect(remote.calls.length, before);
    if (capture != null) await capture(tester, key, 'offline-reader');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'cached directory enables reading without waiting for a stalled remote detail',
    (tester) async {
      repository.dispose();
      remote = _HeldDetail();
      repository = OfflineNovelRepository(remote: remote, cache: cache);
      await tester.runAsync(() async {
        await repository.rememberDirectory(novel);
        await repository.chapterContent(71, novel.chapters.first);
      });
      final key = GlobalKey();
      await tester.pumpWidget(
        _app(
          DetailLoaderPage(
            novel: novel.withChapters(const []),
            state: state,
            repository: repository,
          ),
          key,
          brightness: Brightness.dark,
        ),
      );
      await _settleIo(tester);
      final detail = tester.widget<DetailPage>(find.byType(DetailPage));
      expect(detail.isLoading, isFalse);
      expect(detail.fromCache, isTrue);
      expect(detail.novel.chapters.length, 3);
      expect((remote as _HeldDetail).reply.isCompleted, isFalse);
      if (capture != null) await capture(tester, key, 'offline-directory-seed');
      await _tapIo(tester, find.byKey(const ValueKey('detail-read-button')));
      await _settleIo(tester);
      expect(find.textContaining('正文 71-1'), findsWidgets);
      (remote as _HeldDetail).reply.complete(novel);
      await _settleIo(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'settings cache management clears files but preserves shelf and reading position',
    (tester) async {
      await tester.runAsync(() async {
        await repository.rememberDirectory(novel);
        await repository.chapterContent(71, novel.chapters.first);
        await state.toggleShelf(71, novel: novel);
        await state.savePosition(
          novel: novel,
          chapter: 0,
          offset: 80,
          maximum: 320,
          width: 400,
        );
      });
      final key = GlobalKey();
      await tester.pumpWidget(
        _app(SettingsPage(state: state, repository: repository), key),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('缓存管理'),
        180,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('settings')),
          matching: find.byType(Scrollable),
        ),
      );
      await _tapIo(tester, find.text('缓存管理'));
      await _settleIo(tester);
      expect(find.byType(OfflineCachePage), findsOneWidget);
      expect(find.text('离线作品 71'), findsOneWidget);
      if (capture != null) await capture(tester, key, 'offline-cache-manager');
      await _tapIo(tester, _control('清空缓存'));
      await _tapIo(
        tester,
        find.text('清空全部缓存'),
        until: () => cache.books.isEmpty,
      );
      expect(state.contains(71), isTrue);
      expect(state.positionFor(71)!.chapterId, 71001);
      expect(state.positionFor(71)!.offset, 80);
      expect(find.textContaining('暂无离线缓存'), findsOneWidget);
      final reloaded = await LibraryState.load();
      expect(reloaded.contains(71), isTrue);
      expect(reloaded.positionFor(71)!.chapterId, 71001);
      reloaded.dispose();
      if (capture != null) await capture(tester, key, 'offline-cache-empty');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed download has a working continue action and keeps previous bodies',
    (tester) async {
      remote.failChapter = 71002;
      final key = GlobalKey();
      await tester.pumpWidget(
        _app(
          DetailPage(novel: novel, state: state, repository: repository),
          key,
        ),
      );
      await tester.pumpAndSettle();
      await _tapIo(tester, _control('下载与缓存'));
      await _tapIo(
        tester,
        find.text('下载全部章节'),
        until: () => repository.jobFor(71)?.phase == DownloadPhase.failed,
      );
      expect(find.textContaining('下载失败，可重试'), findsOneWidget);
      expect(cache.book(71)!.cachedCount, 1);
      if (capture != null) {
        await capture(tester, key, 'offline-download-failed');
      }
      remote.failChapter = null;
      await _tapIo(tester, _control('下载与缓存'));
      await _tapIo(
        tester,
        find.text('继续下载'),
        until: () => repository.jobFor(71)?.phase == DownloadPhase.completed,
      );
      expect(cache.book(71)!.cachedCount, 3);
      expect(remote.calls.where((c) => c == 'text:71:71001').length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cancel download preserves its subset and the menu can resume it',
    (tester) async {
      final reply = Completer<String>();
      remote.held[71001] = reply;
      final key = GlobalKey();
      await tester.pumpWidget(
        _app(
          DetailPage(novel: novel, state: state, repository: repository),
          key,
        ),
      );
      await tester.pumpAndSettle();
      await _tapIo(tester, _control('下载与缓存'));
      await _tapIo(
        tester,
        find.text('下载全部章节'),
        until: () => remote.activeReads == 1,
      );
      await _tapIo(tester, _control('下载与缓存'));
      await _tapIo(tester, find.text('取消下载'));
      reply.complete(novel.chapters.first.content);
      await _settleIo(tester);
      expect(repository.jobFor(71)!.phase, DownloadPhase.cancelled);
      expect(cache.book(71)!.cachedCount, 0);
      expect(find.text('已取消 · 保留已缓存章节'), findsOneWidget);
      if (capture != null) await capture(tester, key, 'offline-cancelled');
      await _tapIo(tester, _control('下载与缓存'));
      await _tapIo(
        tester,
        find.text('继续下载'),
        until: () => repository.jobFor(71)?.phase == DownloadPhase.completed,
      );
      expect(cache.book(71)!.cachedCount, 3);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'subsequent twenty-chapter download stops at the directory boundary',
    (tester) async {
      final book = offlineFixtureBook(71, chapters: 24);
      remote.books[71] = book;
      final key = GlobalKey();
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Center(
              child: OfflineBookMenu(
                repository: repository,
                novel: book,
                startChapter: 21,
              ),
            ),
          ),
          key,
        ),
      );
      await tester.pumpAndSettle();
      await _tapIo(tester, _control('下载与缓存'));
      await _tapIo(
        tester,
        find.text('下载后续 20 章'),
        until: () => repository.jobFor(71)?.phase == DownloadPhase.completed,
      );
      expect(repository.jobFor(71)!.total, 3);
      expect(cache.book(71)!.chapterBytes.keys, {71022, 71023, 71024});
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
