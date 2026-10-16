import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_shelf.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/legacy_cover.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/novel_feed_controller.dart';
import 'package:wenku8_flutter/pages.dart';

import 'support/cover_fixture.dart';

typedef Capture = Future<void> Function(WidgetTester, GlobalKey, String);
const _railKey = ValueKey('archive-file-carousel');
ArchiveShelfSceneRender _scene(WidgetTester tester) =>
    tester.renderObject<ArchiveShelfSceneRender>(
      find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ShelfRow'),
    );
AnimationController _clock(WidgetTester tester) =>
    (tester.state(find.byType(ArchiveFileCarousel)) as dynamic)
            .debugEntranceClock
        as AnimationController;
void _view(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

List<Novel> _books(int start, int count) => [
  for (var i = 0; i < count; i++)
    Novel(
      id: start + i,
      title: '档案书籍 ${i + 1}',
      author: '档案作者',
      genre: '轻小说',
      summary: '',
      coverUrl: 'fixture://cover/${start + i}',
      colors: demoNovels.first.colors,
    ),
];

class _Pending extends DemoNovelRepository {
  final requests = <(NovelSort, int), Completer<NovelPage>>{};
  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) => (requests[(sort, page)] = Completer<NovelPage>()).future;
}

Widget _app(
  LibraryState state,
  NovelFeedController feed,
  GlobalKey key,
  Brightness brightness,
) => RepaintBoundary(
  key: key,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: novelTheme(brightness),
    home: Scaffold(
      body: Atmosphere(
        child: DiscoverPage(
          books: const [],
          feed: feed,
          state: state,
          repository: feed.repository,
          onSearch: () {},
        ),
      ),
    ),
  ),
);

void main({Capture? capture}) {
  for (final brightness in Brightness.values) {
    testWidgets(
      'category skeleton and diagonal solid assembly share geometry ${brightness.name}',
      (tester) async {
        _view(tester);
        SharedPreferences.setMockInitialValues({});
        final state = await LibraryState.load();
        addTearDown(state.dispose);
        final repo = _Pending();
        final feed = NovelFeedController(repo);
        addTearDown(feed.dispose);
        final boundary = GlobalKey();
        final load = feed.loadInitial();
        await tester.pumpWidget(_app(state, feed, boundary, brightness));
        await tester.pumpAndSettle();
        final placeholder = find.byKey(
          const ValueKey('archive-shelf-skeleton'),
        );
        final skeletonSize = tester.getSize(placeholder);
        final skeletonTop = tester.getTopLeft(placeholder);
        expect(find.byType(ArchiveShelfSkeleton), findsOneWidget);
        expect(find.byKey(const ValueKey('skeleton-library')), findsNothing);
        expect(tester.binding.transientCallbackCount, 0);
        if (capture != null) {
          await capture(
            tester,
            boundary,
            'discovery-${brightness.name}-skeleton',
          );
        }

        final books = _books(970000 + brightness.index * 100, 20);
        final image = (await tester.runAsync(coverFixtureBytes))!;
        for (final book in books) {
          LegacyCover.seedLocalBytes(book.id, image);
        }
        await tester.runAsync(() async {
          for (final book in books.take(3)) {
            await precacheImage(
              MemoryImage(LegacyCover.peek(book.id)!),
              tester.element(placeholder),
            );
          }
        });
        repo.requests[(NovelSort.lastUpdate, 1)]!.complete(
          NovelPage(items: books, page: 1, totalPages: 4),
        );
        await load;
        await tester.pump();
        final clock = _clock(tester)..stop();
        clock.value = 0;
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byKey(_railKey)), skeletonSize);
        expect(tester.getTopLeft(find.byKey(_railKey)), skeletonTop);
        final scene = _scene(tester);
        final layouts = scene.debugLayoutCount;
        final centre = scene.debugCentreSlot;
        final box = tester.renderObject<ArchiveBoxDepthRender>(
          find.byKey(ValueKey('archive-slot-$centre')),
        );
        expect(box.debugOpenFraction, 0);
        for (final (name, value) in [
          ('assemble', .22),
          ('extract', .57),
          ('ready', 1.0),
        ]) {
          clock.value = value;
          await tester.pumpAndSettle();
          final left = scene.debugAssemblyOffset(centre - 2);
          final right = scene.debugAssemblyOffset(centre + 2);
          if (value < .4) {
            expect(left.dx, lessThan(right.dx));
            expect(right.dx, greaterThan(0));
            expect(right.dy / right.dx, closeTo(-.30 / .66, .00001));
          }
          expect(scene.debugLayoutCount, layouts);
          expect(
            scene.debugPaintOrder,
            orderedEquals([...scene.debugPaintOrder]..sort()),
          );
          if (capture != null) {
            await capture(
              tester,
              boundary,
              'discovery-${brightness.name}-$name',
            );
          }
        }
        expect(box.debugOpenFraction, 1);
        expect(scene.debugAssemblyOffset(centre), Offset.zero);
        expect(tester.binding.transientCallbackCount, 0);

        final switched = feed.selectSort(NovelSort.allVisit);
        await tester.pumpAndSettle();
        expect(find.text('总人气'), findsOneWidget);
        expect(find.text('最近更新'), findsNothing);
        expect(find.byType(ArchiveShelfSkeleton), findsOneWidget);
        expect(find.byKey(const ValueKey('skeleton-library')), findsNothing);
        if (capture != null) {
          await capture(
            tester,
            boundary,
            'discovery-${brightness.name}-category',
          );
        }
        repo.requests[(NovelSort.allVisit, 1)]!.complete(
          NovelPage(items: books.reversed.toList(), page: 1, totalPages: 1),
        );
        await switched;
        await tester.pumpAndSettle();
        expect(_scene(tester).debugEntranceProgress, 1);
        expect(find.byType(ArchiveShelfSkeleton), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'appending the warmed list neither replays nor truncates file assembly',
    (tester) async {
      _view(tester);
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final repo = _Pending();
      final feed = NovelFeedController(repo, initialItems: 60);
      addTearDown(feed.dispose);
      final first = _books(970500, 20);
      final load = feed.loadInitial();
      await tester.pumpWidget(_app(state, feed, GlobalKey(), Brightness.light));
      repo.requests[(NovelSort.lastUpdate, 1)]!.complete(
        NovelPage(items: first, page: 1, totalPages: 5),
      );
      await tester.pump();
      final clock = _clock(tester)..stop();
      clock.value = .3;
      await tester.pump();
      final scene = _scene(tester);
      final oldPool = scene.debugPoolCount;
      repo.requests[(NovelSort.lastUpdate, 2)]!.complete(
        NovelPage(items: _books(970600, 20), page: 2, totalPages: 5),
      );
      await tester.pump();
      expect(_clock(tester), same(clock));
      expect(_scene(tester), same(scene));
      expect(scene.debugEntranceProgress, .3);
      expect(scene.debugPoolCount, oldPool);
      repo.requests[(NovelSort.lastUpdate, 3)]!.complete(
        NovelPage(items: _books(970700, 20), page: 3, totalPages: 5),
      );
      await load;
      clock.value = 1;
      await tester.pumpAndSettle();
      expect(feed.items.length, 60);
      final list = tester.widget<SliverList>(find.byType(SliverList));
      expect(list.delegate.estimatedChildCount, 50);
      expect(_clock(tester), same(clock));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'the discovery list prefetches before its last viewport is visible',
    (tester) async {
      _view(tester);
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final repo = _Pending();
      final feed = NovelFeedController(repo);
      addTearDown(feed.dispose);
      final load = feed.loadInitial();
      await tester.pumpWidget(_app(state, feed, GlobalKey(), Brightness.light));
      repo.requests[(NovelSort.lastUpdate, 1)]!.complete(
        NovelPage(items: _books(971000, 40), page: 1, totalPages: 5),
      );
      await load;
      await tester.pumpAndSettle();
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      scroll.jumpTo(scroll.maxScrollExtent - 1000);
      await tester.pump();
      await tester.pump();
      expect(scroll.extentAfter, greaterThan(400));
      expect(repo.requests.containsKey((NovelSort.lastUpdate, 2)), isTrue);
      expect(feed.loading, isTrue);
      repo.requests[(NovelSort.lastUpdate, 2)]!.complete(
        NovelPage(items: _books(972000, 20), page: 2, totalPages: 5),
      );
      await tester.pumpAndSettle();
      expect(feed.items.length, 60);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reduced motion and a grabbed entrance never leave a background clock',
    (tester) async {
      _view(tester);
      Widget app(bool reduced) => MaterialApp(
        theme: novelTheme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ArchiveFileCarousel(
                books: _books(973000, 10),
                onOpen: (_, _) {},
                animateEntrance: true,
                reduceMotion: reduced,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(_scene(tester).debugEntranceProgress, 1);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app(false));
      _clock(tester).stop();
      _clock(tester).value = .15;
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_railKey)),
      );
      await gesture.moveBy(const Offset(-70, 0));
      await tester.pump();
      expect(_scene(tester).debugEntranceProgress, 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        _scene(tester).debugFocus,
        closeTo(_scene(tester).debugFocus.roundToDouble(), .00001),
      );
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
