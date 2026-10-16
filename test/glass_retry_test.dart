import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/pages.dart';

void main() {
  testWidgets(
    'glass library retry replaces the failed future with a real result',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      final repository = _RetryLibrary();
      await tester.pumpWidget(NovelApp(state: state, repository: repository));
      await tester.pumpAndSettle();
      expect(find.text('书籍加载失败'), findsOneWidget);
      expect(find.byType(GlassTextButton), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('书籍加载失败'), findsNothing);
      expect(find.text('轻小说文库'), findsOneWidget);
      expect(repository.attempts, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'glass detail retry keeps its cover and replaces failed metadata',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      final repository = _RetryDetail();
      await tester.pumpWidget(NovelApp(state: state, repository: repository));
      await tester.pumpAndSettle();
      await tester.tap(find.text(demoNovels.first.title).last);
      await tester.pumpAndSettle();
      expect(find.text('书籍详情加载失败'), findsOneWidget);
      final cover = find.descendant(
        of: find.byType(DetailPage),
        matching: find.byType(NovelCover),
      );
      final coverElement = tester.element(cover);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('书籍详情加载失败'), findsNothing);
      expect(find.text('简介'), findsOneWidget);
      expect(tester.element(cover), same(coverElement));
      expect(repository.attempts, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('glass chapter retry swaps the failed content future safely', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = await LibraryState.load();
    final repository = _RetryContent();
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
    await tester.pumpAndSettle();
    expect(find.text('章节加载失败'), findsOneWidget);
    expect(find.byType(GlassTextButton), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('章节加载失败'), findsNothing);
    expect(find.text('恢复的正文。'), findsOneWidget);
    expect(repository.attempts, 2);
    expect(tester.takeException(), isNull);
  });
}

class _RetryLibrary extends DemoNovelRepository {
  int attempts = 0;
  @override
  Future<List<Novel>> list() async {
    if (attempts++ == 0) throw StateError('fixture list failure');
    return demoNovels;
  }
}

class _RetryDetail extends DemoNovelRepository {
  int attempts = 0;
  @override
  Future<Novel> detail(Novel novel) async {
    if (attempts++ == 0) throw StateError('fixture detail failure');
    return novel;
  }
}

class _RetryContent extends DemoNovelRepository {
  int attempts = 0;
  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    if (attempts++ == 0) throw StateError('fixture content failure');
    return '恢复的正文。';
  }
}
