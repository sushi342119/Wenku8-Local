import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/glass_dock.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_epub.dart';
import 'package:wenku8_flutter/local_epub_reader.dart';
import 'package:wenku8_flutter/local_epub_reader_tools.dart';
import 'package:wenku8_flutter/local_library.dart';
import 'package:wenku8_flutter/reader_catalogue.dart';
import 'package:wenku8_flutter/reader_chrome.dart';
import 'package:wenku8_flutter/reader_tools.dart';

const _novel = Novel(
  id: localNovelIdBase + 21,
  title: 'EPUB 阅读样本',
  author: '测试',
  genre: '本地',
  summary: '',
  colors: [Colors.black, Colors.grey],
);

typedef _ChapterData = ({
  List<EpubBlock> blocks,
  Map<String, Uint8List> images,
});

class _EpubStore extends Fake implements LocalLibraryStore {
  _EpubStore({int count = 3, this.imageOnly = false})
    : book = LocalBook(
        id: _novel.id,
        title: _novel.title,
        author: _novel.author,
        fileUri: '',
        fileName: 'fixture.epub',
        kind: LocalBookKind.epub,
        size: 0,
        modified: 0,
        chapters: List.generate(
          count,
          (index) => LocalChapterIndex('章节 ${index + 1}', 0, 0),
        ),
        pageCount: 0,
      );

  final LocalBook book;
  final bool imageOnly;
  bool failNext = false;
  final loads = <int>[];
  final pending = <int, Completer<_ChapterData>>{};

  @override
  LocalBook? bookFor(int id) => id == book.id ? book : null;

  _ChapterData data(int chapter) => imageOnly
      ? (
          blocks: const [EpubBlock.image('image.png')],
          images: {
            'image.png': base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4AWMAAQAABQABDQottAAAAABJRU5ErkJggg==',
            ),
          },
        )
      : (
          blocks: List.generate(
            40,
            (index) => EpubBlock.text('正文 $chapter / $index：${'阅读测试文本。' * 8}'),
          ),
          images: <String, Uint8List>{},
        );

  @override
  Future<_ChapterData> epubChapter(int novelId, int chapterIndex) async {
    loads.add(chapterIndex);
    if (failNext) {
      failNext = false;
      throw StateError('测试加载失败');
    }
    return pending[chapterIndex]?.future ?? data(chapterIndex);
  }
}

Finder _control(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is GlassIconButton && widget.label == label,
  ),
  matching: find.byType(InkWell),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pumpAndSettle();
}

GlassDock _dock(WidgetTester tester) => tester.widget(find.byType(GlassDock));

ScrollableState _article(WidgetTester tester) => tester.state<ScrollableState>(
  find
      .descendant(
        of: find.byKey(const ValueKey('reader-content-tap')),
        matching: find.byType(Scrollable),
      )
      .first,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibraryState state;
  late _EpubStore local;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    state = await LibraryState.load();
    local = _EpubStore();
  });
  tearDown(() => state.dispose());

  Future<void> reader(WidgetTester tester, {int chapter = 0}) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        home: LocalEpubReaderPage(
          novel: _novel,
          state: state,
          local: local,
          initialChapter: chapter,
        ),
      ),
    );
    await _settle(tester);
  }

  Future<void> openTools(WidgetTester tester, {bool bookmarks = false}) async {
    await tester.tap(_control(bookmarks ? '阅读书签' : '阅读设置'));
    await tester.pumpAndSettle();
  }

  Future<void> closeTools(WidgetTester tester) async {
    await tester.tap(_control('关闭阅读设置'));
    await tester.pumpAndSettle();
  }

  Future<void> addBookmark(WidgetTester tester) async {
    await openTools(tester, bookmarks: true);
    await tester.tap(find.byKey(const ValueKey('reader-add-bookmark')));
    await _settle(tester);
  }

  void expectChrome(WidgetTester tester, bool visible) {
    for (final name in ['reader-chrome-header', 'reader-chrome-dock']) {
      final chrome = tester.widget<ReaderChromeLayer>(
        find.byKey(ValueKey(name)),
      );
      expect(chrome.animation.value, visible ? 1 : 0);
    }
    expect(
      _control('阅读设置').hitTestable(),
      visible ? findsOneWidget : findsNothing,
    );
  }

  testWidgets('EPUB 顶栏复用且没有未接通的听书入口', (tester) async {
    await reader(tester);
    expect(find.byType(FrostedHeader), findsOneWidget);
    expect(find.byType(ReaderChromeLayer), findsNWidgets(2));
    expect(find.byType(ArchiveRouteTitle), findsOneWidget);
    expect(find.text(_novel.title), findsOneWidget);
    expect(_control('返回详情').hitTestable(), findsOneWidget);
    expect(_control('阅读书签').hitTestable(), findsOneWidget);
    expect(_control('阅读设置').hitTestable(), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.headphones), findsNothing);
    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('EPUB 补全空目录并复用目录返回章节序号', (tester) async {
    await reader(tester);
    expect(_novel.chapters, isEmpty);
    await tester.tap(find.text('1 / 3'));
    await tester.pumpAndSettle();
    final catalogue = tester.widget<ReaderCatalogue>(
      find.byType(ReaderCatalogue),
    );
    expect(catalogue.novel.chapters.map((chapter) => chapter.id), [0, 1, 2]);
    expect(catalogue.novel.chapters.map((chapter) => chapter.title), [
      '章节 1',
      '章节 2',
      '章节 3',
    ]);
    expect(
      catalogue.novel.chapters.every(
        (chapter) => chapter.revision == local.book.revision,
      ),
      isTrue,
    );
    expect(catalogue.currentChapter, 0);
    expect(catalogue.cache, isNull);
    expect(find.text('正在阅读'), findsOneWidget);
    final row = find.byKey(const ValueKey('reader-chapter-0'));
    expect(
      tester
          .widget<Semantics>(
            find.ancestor(of: row, matching: find.byType(Semantics)).first,
          )
          .properties
          .selected,
      isTrue,
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('reader-chapter-2')),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ReaderCatalogue), findsNothing);
    expect(_dock(tester).items[1].label, '3 / 3');
    expect(state.chapterFor(_novel.id), 2);
    expect(local.loads, [0, 2]);
  });

  testWidgets('EPUB 目录搜索和定位当前章', (tester) async {
    await reader(tester, chapter: 1);
    await tester.tap(find.text('2 / 3'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('reader-chapter-search')),
      '章节 3',
    );
    await tester.pumpAndSettle();
    expect(find.text('找到 1 章'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-chapter-2')), findsOneWidget);
    await tester.tap(_control('定位当前章节'));
    await tester.pumpAndSettle();
    expect(find.text('正在阅读'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-chapter-1')), findsOneWidget);
    await tester.tap(_control('关闭目录'));
    await tester.pumpAndSettle();
    expect(state.chapterFor(_novel.id), 1);
  });

  testWidgets('EPUB 首末章禁用与逐章导航', (tester) async {
    await reader(tester);
    expect(_dock(tester).items.map((item) => item.enabled), [
      false,
      true,
      true,
    ]);
    await tester.tap(find.text('上一章'));
    await tester.pumpAndSettle();
    expect(local.loads, [0]);
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    expect(_dock(tester).items.map((item) => item.enabled), [true, true, true]);
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    expect(_dock(tester).items.map((item) => item.enabled), [
      true,
      true,
      false,
    ]);
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    expect(local.loads, [0, 1, 2]);
    await tester.tap(find.text('上一章'));
    await tester.pumpAndSettle();
    expect(state.chapterFor(_novel.id), 1);
  });

  for (final savedChapter in [0, 1]) {
    testWidgets('EPUB 遗留第 $savedChapter 章阅读位置在跳章后同步并可恢复', (tester) async {
      final seededNovel = _novel.withChapters([
        for (var index = 0; index < 3; index++)
          NovelChapter(
            '章节 ${index + 1}',
            '',
            id: index,
            revision: local.book.revision,
          ),
      ]);
      await tester.runAsync(() async {
        await state.setTypography(fontSize: 23, lineHeight: 1.9);
        await state.savePosition(
          novel: seededNovel,
          chapter: savedChapter,
          offset: 120,
          maximum: 240,
          width: 360,
        );
      });
      expect(state.positionFor(_novel.id)?.chapter, savedChapter);

      await reader(tester, chapter: -1);
      expect(_dock(tester).items[1].label, '${savedChapter + 1} / 3');
      await tester.tap(find.text('${savedChapter + 1} / 3'));
      await tester.pumpAndSettle();
      final catalogue = tester.widget<ReaderCatalogue>(
        find.byType(ReaderCatalogue),
      );
      expect(catalogue.novel.id, seededNovel.id);
      expect(
        catalogue.novel.chapters.map(
          (chapter) => (chapter.id, chapter.revision),
        ),
        seededNovel.chapters.map((chapter) => (chapter.id, chapter.revision)),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('reader-chapter-2')),
          matching: find.byType(InkWell),
        ),
      );
      await _settle(tester);
      expect(state.chapterFor(_novel.id), 2);
      expect(state.chapterForNovel(seededNovel), 2);
      final position = state.positionFor(_novel.id)!;
      expect(position.chapter, 2);
      expect(position.chapterId, seededNovel.chapters[2].id);
      expect(position.revision, seededNovel.chapters[2].revision);
      expect(position.offset, 0);
      expect(position.fraction, 0);
      expect(position.fontSize, 23);
      expect(position.lineHeight, 1.9);
      expect(position.width, 420);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        final previousState = state;
        state = await LibraryState.load();
        previousState.dispose();
      });
      expect(state.chapterForNovel(seededNovel), 2);
      expect(state.positionFor(_novel.id)?.chapter, 2);
      await reader(tester, chapter: -1);
      expect(_dock(tester).items[1].label, '3 / 3');
      expect(local.loads, [savedChapter, 2, 2]);
    });
  }

  testWidgets('EPUB 文字块点按显隐不改章节', (tester) async {
    await state.setReduceMotion(false);
    await reader(tester, chapter: 1);
    final text = find.text((local.data(1).blocks.first).text!);
    expectChrome(tester, true);
    await tester.tap(text);
    await tester.pumpAndSettle();
    expectChrome(tester, false);
    await tester.tap(text);
    await tester.pumpAndSettle();
    expectChrome(tester, true);
    expect(state.chapterFor(_novel.id), 1);
    expect(local.loads, [1]);
  });

  testWidgets('EPUB 纯图片章节可显隐和翻章', (tester) async {
    local = _EpubStore(imageOnly: true);
    await reader(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.broken_image), findsNothing);
    await tester.tapAt(tester.getCenter(find.byType(Image)));
    await tester.pumpAndSettle();
    expectChrome(tester, false);
    await tester.tapAt(tester.getCenter(find.byType(Image)));
    await tester.pumpAndSettle();
    expectChrome(tester, true);
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    expect(state.chapterFor(_novel.id), 1);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('EPUB 零章节空态禁用阅读按钮', (tester) async {
    local = _EpubStore(count: 0);
    await reader(tester);
    expect(find.text('暂无章节'), findsOneWidget);
    expect(_dock(tester).items.map((item) => item.enabled), [
      false,
      false,
      false,
    ]);
    expect(_dock(tester).items[1].label, '0 / 0');
    for (final label in ['阅读设置', '阅读书签']) {
      final button = tester.widget<GlassIconButton>(
        find.byWidgetPredicate(
          (widget) => widget is GlassIconButton && widget.label == label,
        ),
      );
      expect(button.onPressed, isNull);
    }
    await tester.tap(find.text('暂无章节'));
    await tester.pumpAndSettle();
    expect(find.byType(LocalEpubReaderTools), findsNothing);
    expect(local.loads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('EPUB 加载失败保留重试', (tester) async {
    local.failNext = true;
    await reader(tester);
    expect(find.text('章节加载失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('章节加载失败'), findsNothing);
    expect(find.text(local.data(0).blocks.first.text!), findsOneWidget);
    expect(local.loads, [0, 0]);
  });

  Finder progressBar() => find.byKey(const ValueKey('epub-book-progress'));

  Rect progressTrack(WidgetTester tester) => tester.getRect(
    find
        .descendant(of: progressBar(), matching: find.byType(GestureDetector))
        .first,
  );

  testWidgets('EPUB 全书进度条随控件显隐，单章不可滚动时不显示', (tester) async {
    await state.setReduceMotion(false);
    await reader(tester, chapter: 1);
    expect(progressBar().hitTestable(), findsOneWidget);
    await tester.tap(find.text(local.data(1).blocks.first.text!));
    await tester.pumpAndSettle();
    expectChrome(tester, false);
    expect(progressBar().hitTestable(), findsNothing);
    await tester.tap(find.text(local.data(1).blocks.first.text!));
    await tester.pumpAndSettle();
    expect(progressBar().hitTestable(), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    local = _EpubStore(count: 1, imageOnly: true);
    await reader(tester);
    expect(progressBar(), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    local = _EpubStore(count: 1);
    await reader(tester);
    expect(progressBar(), findsOneWidget);
  });

  testWidgets('EPUB 点按进度条跳到目标章并按比例滚动，取消拖动不跳转', (tester) async {
    await reader(tester);
    final track = progressTrack(tester);
    await tester.tapAt(Offset(track.left + track.width * .9, track.center.dy));
    await _settle(tester);
    expect(_dock(tester).items[1].label, '3 / 3');
    final position = _article(tester).position;
    expect(position.pixels / position.maxScrollExtent, closeTo(.7, .02));
    expect(find.text('第 3 章 · 90%'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    final saved = state.positionFor(_novel.id)!;
    expect(saved.chapter, 2);
    expect(saved.fraction, closeTo(.7, .02));

    final gesture = await tester.startGesture(
      Offset(track.left + track.width * .1, track.center.dy),
    );
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(4, 0));
    await tester.pump();
    expect(find.textContaining(RegExp(r'^第 1 章 · \d+%$')), findsOneWidget);
    await gesture.cancel();
    await _settle(tester);
    expect(_dock(tester).items[1].label, '3 / 3');
    expect(state.chapterFor(_novel.id), 2);
  });

  testWidgets('EPUB 恢复章内位置后才保存，滚动后保存真实 offset', (tester) async {
    final seededNovel = _novel.withChapters([
      for (var index = 0; index < 3; index++)
        NovelChapter(
          '章节 ${index + 1}',
          '',
          id: index,
          revision: local.book.revision,
        ),
    ]);
    await tester.runAsync(
      () => state.savePosition(
        novel: seededNovel,
        chapter: 1,
        offset: 120,
        maximum: 240,
        width: 420,
      ),
    );
    await reader(tester, chapter: -1);
    expect(_dock(tester).items[1].label, '2 / 3');
    var position = _article(tester).position;
    expect(position.pixels / position.maxScrollExtent, closeTo(.5, .02));
    expect(state.positionFor(_novel.id)!.chapter, 1);
    expect(state.positionFor(_novel.id)!.fraction, closeTo(.5, .02));

    position.jumpTo(100);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    position = _article(tester).position;
    expect(state.positionFor(_novel.id)!.offset, closeTo(100, .5));
    expect(
      state.positionFor(_novel.id)!.fraction,
      closeTo(100 / position.maxScrollExtent, .001),
    );

    await openTools(tester);
    final percent = (100 / position.maxScrollExtent * 100).round();
    expect(find.text('本章已读 $percent%'), findsOneWidget);
    expect(find.text('阅读进度按章节保存。'), findsNothing);
  });

  testWidgets('EPUB 快速切章不显示旧加载结果', (tester) async {
    await reader(tester);
    final delayed = Completer<_ChapterData>();
    local.pending[1] = delayed;
    await tester.tap(find.text('下一章'));
    await tester.pump();
    expect(find.text(local.data(0).blocks.first.text!), findsNothing);
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    delayed.complete(local.data(1));
    await tester.pumpAndSettle();
    expect(find.text(local.data(1).blocks.first.text!), findsNothing);
    expect(find.text(local.data(2).blocks.first.text!), findsOneWidget);
    expect(state.chapterFor(_novel.id), 2);
  });

  testWidgets('EPUB 书签增删保存当前章与修订', (tester) async {
    await state.setTypography(fontSize: 23, lineHeight: 1.9);
    await reader(tester, chapter: 1);
    final before = DateTime.now().millisecondsSinceEpoch;
    await addBookmark(tester);
    final mark = state.bookmarksFor(_novel.id).single;
    expect(mark.chapterTitle, '章节 2');
    expect(mark.position.chapter, 1);
    expect(mark.position.chapterId, 1);
    expect(mark.position.revision, local.book.revision);
    expect(mark.position.offset, 0);
    expect(mark.position.fraction, 0);
    expect(mark.position.paragraphIndex, isNull);
    expect(mark.position.textOffset, isNull);
    expect(mark.position.fontSize, 23);
    expect(mark.position.lineHeight, 1.9);
    expect(mark.position.updatedAt, greaterThanOrEqualTo(before));
    final reloaded = await LibraryState.load();
    expect(reloaded.bookmarksFor(_novel.id).single.id, mark.id);
    reloaded.dispose();
    await tester.tap(_control('删除书签 ${mark.id}'));
    await tester.pumpAndSettle();
    expect(state.bookmarksFor(_novel.id), isEmpty);
    expect(find.text('本书 0 个书签'), findsOneWidget);
    final afterRemoval = await LibraryState.load();
    expect(afterRemoval.bookmarksFor(_novel.id), isEmpty);
    afterRemoval.dispose();
  });

  testWidgets('EPUB 书签同章和跨章均跳到章首', (tester) async {
    await reader(tester);
    await addBookmark(tester);
    final mark = state.bookmarksFor(_novel.id).single;
    await closeTools(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(_article(tester).position.pixels, greaterThan(0));
    await openTools(tester, bookmarks: true);
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('reader-bookmark-${mark.id}')),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();
    expect(_article(tester).position.pixels, 0);
    expect(local.loads, [0]);
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    await openTools(tester, bookmarks: true);
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('reader-bookmark-${mark.id}')),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();
    expect(state.chapterFor(_novel.id), 0);
    expect(_article(tester).position.pixels, 0);
    expect(_dock(tester).items[1].label, '1 / 3');
  });

  testWidgets('EPUB 字号行距预览持久化并恢复章节', (tester) async {
    await reader(tester, chapter: 2);
    await openTools(tester);
    final preferences = await SharedPreferences.getInstance();
    for (final setting in [
      (key: 'reader-font-slider', value: 24.0),
      (key: 'reader-line-height-slider', value: 2.0),
    ]) {
      final slider = tester.widget<CupertinoSlider>(
        find.byKey(ValueKey(setting.key)),
      );
      slider.onChangeStart!(slider.value);
      slider.onChanged!(setting.value);
      await tester.pump();
      expect(
        preferences.getDouble(
          setting.key == 'reader-font-slider'
              ? 'readerFontSize'
              : 'readerLineHeight',
        ),
        isNull,
      );
      slider.onChangeEnd!(setting.value);
      await tester.pumpAndSettle();
    }
    expect(state.fontSize, 24);
    expect(state.lineHeight, 2);
    expect(state.chapterFor(_novel.id), 2);
    expect(preferences.getDouble('readerFontSize'), 24);
    expect(preferences.getDouble('readerLineHeight'), 2);
    await closeTools(tester);
    final text = tester.widget<Text>(
      find.text(local.data(2).blocks.first.text!),
    );
    expect(text.style!.fontSize, 24);
    expect(text.style!.height, 2);
    expect(local.loads, [2]);
    await tester.pumpWidget(const SizedBox.shrink());
    final previousState = state;
    state = await LibraryState.load();
    previousState.dispose();
    await reader(tester, chapter: -1);
    expect(_dock(tester).items[1].label, '3 / 3');
    final restored = tester.widget<Text>(
      find.text(local.data(2).blocks.first.text!),
    );
    expect(restored.style!.fontSize, 24);
    expect(restored.style!.height, 2);
  });

  testWidgets('EPUB 恢复默认排版与专注阅读无假按钮', (tester) async {
    await state.setTypography(fontSize: 27, lineHeight: 2.2);
    await reader(tester);
    await openTools(tester);
    expect(find.byType(ReaderTools), findsNothing);
    expect(find.byType(ReaderValueSlider), findsNWidgets(2));
    expect(find.byKey(const ValueKey('reader-progress-slider')), findsNothing);
    expect(find.byKey(const ValueKey('reader-open-find')), findsNothing);
    await tester.tap(find.text('恢复默认排版'));
    await tester.pumpAndSettle();
    expect(state.fontSize, 19);
    expect(state.lineHeight, 1.72);
    final focus = find.text('专注阅读 · 隐藏控件');
    await tester.ensureVisible(focus);
    await tester.tap(focus);
    await tester.pumpAndSettle();
    expectChrome(tester, false);
    await tester.tap(find.text(local.data(0).blocks.first.text!));
    await tester.pumpAndSettle();
    expectChrome(tester, true);
  });

  for (final throwsError in [false, true]) {
    testWidgets('EPUB 书签保存${throwsError ? '异常' : '返回空值'}明确报错', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: Scaffold(
            body: LocalEpubReaderTools(
              novel: _novel.withChapters([
                const NovelChapter('章节 1', '', id: 0),
              ]),
              state: state,
              chapter: 0,
              initialBookmarks: true,
              onAddBookmark: () async {
                if (throwsError) throw StateError('测试写入失败');
                return null;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('reader-add-bookmark')));
      await tester.pumpAndSettle();
      expect(find.text('书签保存失败，请重试'), findsOneWidget);
      expect(find.text('已添加书签'), findsNothing);
      expect(state.bookmarksFor(_novel.id), isEmpty);
    });
  }

  test('EPUB 复用字号行距钳制和持久化', () async {
    await state.setTypography(fontSize: 100, lineHeight: 10);
    expect(state.fontSize, 27);
    expect(state.lineHeight, 2.2);
    await state.setTypography(fontSize: 1, lineHeight: .1);
    expect(state.fontSize, 15);
    expect(state.lineHeight, 1.3);
    final restored = await LibraryState.load();
    expect(restored.fontSize, 15);
    expect(restored.lineHeight, 1.3);
    restored.dispose();
  });
}
