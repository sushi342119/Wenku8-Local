import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_landing_highlight.dart';

import 'support/offline_fixture.dart';

Finder _control(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is GlassIconButton && widget.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;

ScrollableState _article(WidgetTester tester) => tester.state<ScrollableState>(
  find
      .descendant(
        of: find.byKey(const ValueKey('reader-scroll')),
        matching: find.byType(Scrollable),
      )
      .first,
);

void _expectBookmarkCentred(WidgetTester tester, ReadingPosition saved) {
  final paragraph = find.byKey(ValueKey('paragraph-${saved.paragraphIndex}'));
  expect(paragraph, findsOneWidget);
  final rect = tester.getRect(paragraph);
  final viewport = tester.getRect(find.byKey(const ValueKey('reader-scroll')));
  final media = MediaQuery.of(tester.element(paragraph));
  final top = media.padding.top + FrostedHeader.toolbarHeight + 12;
  final bottom =
      _article(tester).position.viewportDimension - media.padding.bottom - 96;
  final point = rect.height <= bottom - top
      ? rect.center.dy
      : rect.top + rect.height * saved.paragraphFraction;
  expect(point, closeTo(viewport.top + (top + bottom) / 2, 1));
}

Future<void> _io(WidgetTester tester) async {
  for (var step = 0; step < 8; step++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

void main({
  Future<void> Function(WidgetTester tester, GlobalKey key, String name)?
  capture,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibraryState state;
  late OfflineFixtureRepository remote;
  late GlobalKey boundary;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    state = await LibraryState.load();
    remote = OfflineFixtureRepository();
    boundary = GlobalKey();
  });
  tearDown(() {
    state.dispose();
  });

  Future<void> reader(
    WidgetTester tester, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: novelTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: ReaderPage(
            novel: remote.books[71]!,
            state: state,
            repository: remote,
            initialChapter: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settings(WidgetTester tester, {bool bookmarks = false}) async {
    await tester.tap(_control('阅读设置'));
    await tester.pumpAndSettle();
    if (bookmarks) {
      await tester.tap(find.text('书签'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (capture != null) await capture(tester, boundary, name);
  }

  testWidgets(
    'typography previews live through a clear sheet and persists only on release',
    (tester) async {
      await reader(tester);
      final original = tester.widget(find.byKey(const ValueKey('paragraph-0')));
      final calls = remote.calls.length;
      var notifications = 0;
      state.readerSettingsChanges.addListener(() => notifications++);
      await settings(tester);
      tester
          .widget<CupertinoSlider>(
            find.byKey(const ValueKey('reader-font-slider')),
          )
          .onChangeStart!(19);
      for (var index = 0; index < 120; index++) {
        final slider = tester.widget<CupertinoSlider>(
          find.byKey(const ValueKey('reader-font-slider')),
        );
        slider.onChanged!(15 + index % 13);
        await tester.pump();
      }
      expect(
        tester.widget(find.byKey(const ValueKey('paragraph-0'))),
        isNot(same(original)),
      );
      expect(notifications, greaterThan(0));
      expect(state.fontSize, 17);
      expect(
        tester
            .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
            .transparent,
        isTrue,
      );
      expect(remote.calls.length, calls);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('readerFontSize'), isFalse);
      tester
          .widget<CupertinoSlider>(
            find.byKey(const ValueKey('reader-font-slider')),
          )
          .onChanged!(23);
      await tester.pump();
      await shot(tester, 'reader-font-live-preview');
      tester
          .widget<CupertinoSlider>(
            find.byKey(const ValueKey('reader-font-slider')),
          )
          .onChangeEnd!(23);
      await _io(tester);
      expect(state.fontSize, 23);
      expect(prefs.getDouble('readerFontSize'), 23);
      expect(
        tester
            .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
            .transparent,
        isFalse,
      );
      final line = tester.widget<CupertinoSlider>(
        find.byKey(const ValueKey('reader-line-height-slider')),
      );
      line.onChangeStart!(line.value);
      line.onChanged!(1.95);
      await tester.pump();
      expect(state.lineHeight, 1.95);
      expect(prefs.containsKey('readerLineHeight'), isFalse);
      expect(
        tester
            .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
            .transparent,
        isTrue,
      );
      await shot(tester, 'reader-line-live-preview');
      line.onChangeEnd!(1.95);
      await _io(tester);
      expect(state.lineHeight, 1.95);
      expect(prefs.getDouble('readerLineHeight'), 1.95);
      await shot(tester, 'reader-tools-layout');
      await tester.tap(find.text('恢复默认排版'));
      await _io(tester);
      expect(state.fontSize, 19);
      expect(state.lineHeight, 1.72);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader accessibility increments commit without waiting for pointer release',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await reader(tester);
      await settings(tester);
      final key = find.byKey(const ValueKey('reader-slider-semantics-字体大小'));
      final node = tester.getSemantics(key);
      expect(node.getSemanticsData().value, '19 pt');
      node.owner!.performAction(node.id, ui.SemanticsAction.increase);
      await _io(tester);
      expect(state.fontSize, 20);
      expect(
        (await SharedPreferences.getInstance()).getDouble('readerFontSize'),
        20,
      );
      await state.setFontSize(27);
      await tester.pumpAndSettle();
      expect(
        tester
            .getSemantics(key)
            .getSemanticsData()
            .hasAction(ui.SemanticsAction.increase),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'bookmark captures position, restores without body refetch, and persists removal',
    (tester) async {
      await reader(tester);
      _article(tester).position.jumpTo(960);
      await tester.pumpAndSettle();
      final position = _article(tester).position.pixels;
      await settings(tester, bookmarks: true);
      await tester.tap(find.text('添加当前位置书签'));
      await _io(tester);
      expect(find.text('已添加书签'), findsOneWidget);
      final mark = state.bookmarksFor(71).single;
      expect(mark.position.offset, closeTo(position, 1));
      expect((await LibraryState.load()).bookmarksFor(71).single.id, mark.id);
      await shot(tester, 'reader-tools-bookmarks');
      await tester.tap(_control('关闭阅读设置'));
      await tester.pumpAndSettle();
      _article(tester).position.jumpTo(0);
      await tester.pumpAndSettle();
      final requests = remote.calls.length;
      await settings(tester, bookmarks: true);
      await tester.tap(
        find
            .descendant(
              of: find.byKey(ValueKey('reader-bookmark-${mark.id}')),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      _expectBookmarkCentred(tester, mark.position);
      final landing = _article(tester).position.pixels;
      expect(landing, lessThan(position));
      expect(remote.calls.length, requests);
      expect(find.byType(ReaderLandingHighlight), findsOneWidget);
      await shot(tester, 'reader-bookmark-landing');
      await tester.pump(const Duration(milliseconds: 2250));
      expect(find.byType(ReaderLandingHighlight), findsNothing);
      expect(_article(tester).position.pixels, closeTo(landing, 1));
      final resume = state.positionFor(71)!.toJson();
      await settings(tester, bookmarks: true);
      await tester.tap(_control('删除书签 ${mark.id}'));
      await _io(tester);
      expect(state.bookmarksFor(71), isEmpty);
      expect(state.positionFor(71)!.toJson(), resume);
      expect((await LibraryState.load()).bookmarksFor(71), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bookmark switches to its chapter and restores after a pending request',
    (tester) async {
      await reader(tester);
      _article(tester).position.jumpTo(850);
      await tester.pumpAndSettle();
      await settings(tester, bookmarks: true);
      await tester.tap(find.text('添加当前位置书签'));
      await _io(tester);
      final mark = state.bookmarksFor(71).single;
      await tester.tap(_control('关闭阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dock-tab-2')));
      await tester.pumpAndSettle();
      expect(
        state.positionFor(71)!.chapterId,
        remote.books[71]!.chapters[1].id,
      );
      await settings(tester, bookmarks: true);
      await tester.tap(
        find
            .descendant(
              of: find.byKey(ValueKey('reader-bookmark-${mark.id}')),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(state.positionFor(71)!.chapterId, mark.position.chapterId);
      _expectBookmarkCentred(tester, mark.position);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bookmark entry opens saved positions directly with an explicit guide',
    (tester) async {
      await reader(tester);
      await tester.tap(_control('阅读书签'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-add-bookmark')), findsOneWidget);
      expect(find.text('先添加当前位置，再点按下方书签即可回到这里。'), findsOneWidget);
      await shot(tester, 'reader-bookmark-entry');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'bookmark stays centred after larger typography and includes safe insets',
    (tester) async {
      tester.view.physicalSize = const Size(390, 760);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      await reader(tester);
      _article(tester).position.jumpTo(1600);
      await tester.pumpAndSettle();
      await settings(tester, bookmarks: true);
      await tester.tap(find.text('添加当前位置书签'));
      await _io(tester);
      final mark = state.bookmarksFor(71).single;
      await tester.tap(_control('关闭阅读设置'));
      await tester.pumpAndSettle();
      await state.setFontSize(27);
      await state.setLineHeight(1.95);
      await tester.pumpAndSettle();
      _article(tester).position.jumpTo(0);
      await tester.pumpAndSettle();
      await settings(tester, bookmarks: true);
      await tester.tap(
        find
            .descendant(
              of: find.byKey(ValueKey('reader-bookmark-${mark.id}')),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      _expectBookmarkCentred(tester, mark.position);
      expect(find.byType(ReaderLandingHighlight), findsOneWidget);
      await shot(tester, 'reader-bookmark-centred-large');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'progress applies only on release, reaches chapter end and continues with the existing Dock',
    (tester) async {
      await reader(tester);
      await settings(tester);
      final progress = tester.widget<CupertinoSlider>(
        find.byKey(const ValueKey('reader-progress-slider')),
      );
      progress.onChangeStart!(progress.value);
      progress.onChanged!(.65);
      await tester.pump();
      expect(_article(tester).position.pixels, 0);
      progress.onChangeEnd!(.65);
      await tester.pumpAndSettle();
      expect(find.byType(GlassOverlaySurface), findsNothing);
      expect(_article(tester).position.pixels, greaterThan(0));
      expect(state.positionFor(71)!.fraction, closeTo(.65, .02));
      await settings(tester);
      await tester.tap(find.text('跳至章末'));
      await tester.pumpAndSettle();
      final scroll = _article(tester).position;
      expect(scroll.pixels, closeTo(scroll.maxScrollExtent, 1));
      expect(find.byKey(const ValueKey('reader-end-next')), findsOneWidget);
      await tester.tap(find.text('继续下一章'));
      await tester.pumpAndSettle();
      expect(state.positionFor(71)!.chapter, 1);
      expect(_article(tester).position.pixels, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader tools remain scrollable with large text and a small keyboard viewport',
    (tester) async {
      tester.view.physicalSize = const Size(390, 440);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await reader(tester, scale: 2, brightness: Brightness.dark);
      await settings(tester);
      expect(tester.takeException(), isNull);
      final scroll = find.descendant(
        of: find.byKey(const ValueKey('reader-settings-scroll')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text('跳至章末'),
        160,
        scrollable: scroll,
      );
      await shot(tester, 'reader-tools-small-dark');
      await tester.tap(find.text('跳至章末'));
      await tester.pumpAndSettle();
      expect(
        _article(tester).position.pixels,
        closeTo(_article(tester).position.maxScrollExtent, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
