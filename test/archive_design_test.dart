import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/archive_carousel.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_chrome.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + .05) / (math.min(x, y) + .05);
}

void main() {
  test('archive foreground and metadata remain readable in both themes', () {
    for (final brightness in Brightness.values) {
      final scheme = novelTheme(brightness).colorScheme;
      expect(contrast(scheme.surface, scheme.onSurface), greaterThan(12));
      expect(
        contrast(scheme.surface, scheme.onSurfaceVariant),
        greaterThan(4.5),
      );
    }
    expect(ArchiveDesign.fileCode(42), 'WK-00042');
    expect(ArchiveDesign.fileCode(123456), 'WK-123456');
  });

  for (final brightness in Brightness.values) {
    testWidgets('archive chrome is static and fits large text in $brightness', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final size in [const Size(320, 640), const Size(780, 260)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(3)),
              child: child!,
            ),
            home: Scaffold(
              body: Atmosphere(
                child: GlassHeaderLayout(
                  header: Row(
                    children: [
                      const Expanded(
                        child: ArchiveMasthead(
                          title: '轻小说文库',
                          code: 'WENKU8 / READING ARCHIVE',
                          brand: true,
                        ),
                      ),
                      GlassIconButton(
                        icon: CupertinoIcons.search,
                        label: '搜索',
                        onPressed: () {},
                      ),
                    ],
                  ),
                  body: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 90, 24, 24),
                    children: const [
                      ArchiveSection(
                        title: '简介',
                        code: '01 / SYNOPSIS',
                        subtitle: '清晰的阅读与档案信息',
                      ),
                      SizedBox(height: 16),
                      ContentPanel(child: Text('内容保持清晰，纹样只在页边。')),
                      SizedBox(
                        height: 56,
                        child: ArchiveRouteTitle(
                          title: '很长的图书名称也保留返回和设置按钮',
                          code: 'WK-00042',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.binding.transientCallbackCount, 0);
        expect(find.byType(ArchiveBackdrop), findsOneWidget);
        expect(
          tester
              .getSize(
                find.descendant(
                  of: find.byType(ArchiveBackdrop),
                  matching: find.byType(CustomPaint),
                ),
              )
              .height,
          lessThanOrEqualTo(240),
        );
        expect(find.byTooltip('搜索'), findsOneWidget);
      }
    });

    testWidgets(
      'reader keeps a plain canvas and permanent edge blur in $brightness',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final state = await LibraryState.load();
        addTearDown(state.dispose);
        const repository = DemoNovelRepository();
        final book = (await repository.list()).first;
        await tester.pumpWidget(
          MaterialApp(
            theme: novelTheme(brightness),
            home: ReaderPage(
              novel: book,
              state: state,
              repository: repository,
              initialChapter: 0,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ArchiveBackdrop), findsNothing);
        expect(find.byType(ReaderEdgeBlur), findsOneWidget);
        expect(find.byType(ArchiveRouteTitle), findsOneWidget);
        await tester.tapAt(const Offset(400, 260));
        await tester.pumpAndSettle();
        expect(find.byType(ReaderEdgeBlur), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('detail ID plaque initially stays outside the header blur', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    final book = demoNovels.first;
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.dark),
        home: DetailPage(
          novel: book,
          state: state,
          repository: const DemoNovelRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final plaque = find.byWidgetPredicate(
      (widget) =>
          widget is ArchiveCode &&
          widget.inverse &&
          widget.text == ArchiveDesign.fileCode(book.id),
    );
    expect(plaque, findsOneWidget);
    expect(
      tester.getRect(plaque).top,
      greaterThan(tester.getRect(find.byType(FrostedHeader)).bottom),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('archive style retains discovery search and shelf navigation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      NovelApp(state: state, repository: const DemoNovelRepository()),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ArchiveFileCarousel), findsOneWidget);
    expect(
      tester
          .widget<ArchiveFileCarousel>(find.byType(ArchiveFileCarousel))
          .books
          .map((book) => book.id),
      demoNovels.take(5).map((book) => book.id),
    );
    expect(
      find.text('01 / ${demoNovels.take(5).length.toString().padLeft(2, '0')}'),
      findsOneWidget,
    );
    expect(find.text('WENKU8 / READING ARCHIVE'), findsOneWidget);
    expect(find.byType(ArchiveBackdrop), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('dock-tab-1'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('02 / PERSONAL ARCHIVE'), findsOneWidget);
    expect(find.byType(ArchiveBackdrop), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('dock-tab-0'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('expanded-search-input')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('inline-search-close')));
    await tester.pumpAndSettle();
    expect(find.text('WENKU8 / READING ARCHIVE'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
