import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shuyu/app_ui.dart';
import 'package:shuyu/book_tags.dart';
import 'package:shuyu/catalog.dart';
import 'package:shuyu/library_filter.dart';
import 'package:shuyu/library_state.dart';
import 'package:shuyu/local_library.dart';
import 'package:shuyu/local_library_page.dart';
import 'package:shuyu/local_pdf_reader.dart';
import 'package:shuyu/local_platform.dart';
import 'package:shuyu/pages.dart';
import 'package:shuyu/reader_preferences.dart';
import 'package:shuyu/reader_tools.dart';
import 'package:shuyu/ui_preferences.dart';

import 'support/offline_fixture.dart';

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();
  bool rejectBookmarks = false;
  Completer<void>? shelfWriteGate;
  Completer<void>? shelfWriteStarted;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (rejectBookmarks && key.contains('reader_bookmarks_')) return false;
    if (key.endsWith('shelfFilter') && shelfWriteGate != null) {
      final gate = shelfWriteGate!;
      shelfWriteGate = null;
      shelfWriteStarted!.complete();
      await gate.future;
    }
    return super.setValue(type, key, value);
  }
}

class _LocalLibrary extends Fake implements LocalLibraryStore {
  String? pickedFolder;
  int pickerCalls = 0;
  LocalBook? pdf;

  @override
  String? get folderUri => pickedFolder;

  @override
  List<LocalBook> get books => [?pdf];

  @override
  LocalBook? bookFor(int id) => pdf?.id == id ? pdf : null;

  @override
  LocalBookKind? kindFor(int id) => bookFor(id)?.kind;

  @override
  Future<void> Function(LocalChapterRemap)? migrateProgress;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  Future<String?> pickFolder({String? requiredFolder}) async {
    pickerCalls++;
    return pickedFolder;
  }
}

Finder _control(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is GlassIconButton && widget.label == label,
  ),
  matching: find.byType(InkWell),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibraryState state;
  late _Preferences preferences;
  late _LocalLibrary local;
  late OfflineFixtureRepository remote;
  late CompositeNovelRepository repository;

  setUp(() async {
    SharedPreferences.resetStatic();
    preferences = _Preferences();
    SharedPreferencesStorePlatform.instance = preferences;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('motionLevel', 'off');
    await TagStore.load();
    LibraryFilter.shared.resetForTesting();
    state = await LibraryState.load();
    local = _LocalLibrary();
    remote = OfflineFixtureRepository(
      books: [offlineFixtureBook(71), offlineFixtureBook(72)],
    );
    repository = CompositeNovelRepository(local: local, remote: remote);
  });

  tearDown(() {
    state.dispose();
    LibraryFilter.shared.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalPlatform.channel, null);
  });

  Future<void> mount(
    WidgetTester tester,
    Widget page, {
    EdgeInsets padding = EdgeInsets.zero,
  }) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: novelTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(padding: padding),
          child: child!,
        ),
        home: Scaffold(body: page),
      ),
    );
    await _settle(tester);
  }

  ShelfPage shelf() => ShelfPage(
    books: remote.books.values.toList(),
    state: state,
    repository: repository,
  );

  test('书名作者排除编号并按独立字段匹配，全部保留编号，标签仍可搜索', () async {
    const book = Novel(
      id: 71888,
      title: '星河',
      author: '子夜',
      genre: '',
      summary: '',
      colors: [Colors.black, Colors.grey],
    );
    final tag = await TagStore.shared.createTag('幻想');
    await TagStore.shared.setTagsForBook(book.id, [tag]);
    expect(
      matchesSearch(book, book.id, '71888', SearchScope.titleAuthor),
      isFalse,
    );
    expect(matchesSearch(book, book.id, '71888', SearchScope.all), isTrue);
    expect(matchesSearch(book, book.id, '星河', SearchScope.titleAuthor), isTrue);
    expect(matchesSearch(book, book.id, '子夜', SearchScope.titleAuthor), isTrue);
    expect(
      matchesSearch(book, book.id, '星河 子夜', SearchScope.titleAuthor),
      isFalse,
    );
    expect(matchesSearch(book, book.id, '幻想', SearchScope.tags), isTrue);
    expect(matchesSearch(book, book.id, '71888', SearchScope.tags), isFalse);
  });

  for (final conditions in ['query', 'status', 'combined']) {
    testWidgets('清除全部清理 $conditions 条件及待执行防抖，保留排序布局', (tester) async {
      for (final book in remote.books.values) {
        await state.setShelfMembership(book.id, true, novel: book);
      }
      await state.setChapter(71, 0);
      await state.setShelfView(
        sort: 'title',
        filter: conditions == 'query' ? 'all' : 'unread',
      );
      await state.setShelfLayout(ShelfLayout.grid);
      if (conditions == 'combined') {
        final tag = await TagStore.shared.createTag('测试标签');
        await TagStore.shared.setTagsForBook(71, [tag]);
        LibraryFilter.shared.toggleTag(tag);
        LibraryFilter.shared.toggleFormat(BookFormatFilter.txt);
      }
      await mount(tester, shelf());
      if (conditions != 'status') {
        await tester.enterText(
          find.byKey(const ValueKey('shelf-search')),
          '71',
        );
        await tester.pump(const Duration(milliseconds: 200));
        await _settle(tester);
      }
      expect(find.text('清除全部'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('shelf-active-filters')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('shelf-import-local')), findsNothing);
      if (conditions == 'combined') {
        expect(find.text('没有符合条件的书'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('shelf-empty-clear-filters')),
          findsOneWidget,
        );
      }
      await tester.enterText(find.byKey(const ValueKey('shelf-search')), '不存在');
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tap(find.text('清除全部'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester
            .widget<CupertinoSearchTextField>(
              find.byKey(const ValueKey('shelf-search')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(state.shelfFilter, 'all');
      expect(LibraryFilter.shared.isEmpty, isTrue);
      expect(find.text('2 本书'), findsOneWidget);
      expect(find.byKey(const ValueKey('shelf-active-filters')), findsNothing);
      expect(state.shelfSort, 'title');
      expect(state.shelfLayout, ShelfLayout.grid);
      final reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.shelfFilter, 'all');
      expect(reloaded.shelfSort, 'title');
      expect(reloaded.shelfLayout, ShelfLayout.grid);
      expect(tester.takeException(), isNull);
    });
  }

  test('清除覆盖尚未完成的阅读状态写入，最终仍为全部', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    preferences.shelfWriteGate = gate;
    preferences.shelfWriteStarted = started;
    final pending = state.setShelfView(filter: 'unread');
    await started.future;
    expect(state.shelfFilter, 'all');
    final clear = LibraryFilter.shared.clear(state: state);
    gate.complete();
    await pending;
    await clear;
    expect(state.shelfFilter, 'all');
    final reloaded = await LibraryState.load();
    addTearDown(reloaded.dispose);
    expect(reloaded.shelfFilter, 'all');
  });

  testWidgets('书名作者搜索提示不再声称查编号', (tester) async {
    await mount(tester, shelf());
    await tester.tap(find.text('书名作者'));
    await _settle(tester);
    expect(
      tester
          .widget<CupertinoSearchTextField>(
            find.byKey(const ValueKey('shelf-search')),
          )
          .placeholder,
      '查找书名、作者',
    );
  });

  for (final discovery in [false, true]) {
    testWidgets('${discovery ? '发现' : '书架'}真空库直接选目录，取消安静返回', (tester) async {
      await mount(
        tester,
        discovery
            ? DiscoverPage(
                books: const [],
                state: state,
                repository: repository,
                onSearch: () {},
              )
            : shelf(),
      );
      final entry = find.byKey(
        ValueKey(discovery ? 'discover-import-local' : 'shelf-import-local'),
      );
      expect(entry, findsOneWidget);
      await tester.ensureVisible(entry);
      await _settle(tester);
      await tester.tap(entry);
      await _settle(tester);
      expect(local.pickerCalls, 1);
      expect(find.byType(LocalLibraryPage), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('未选择文件夹'), findsNothing);
      expect(entry, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final empty in [false, true]) {
    testWidgets('发现页保留标签选择时区分${empty ? '真空库' : '筛选无结果'}', (tester) async {
      final tag = await TagStore.shared.createTag('未匹配标签');
      LibraryFilter.shared.toggleTag(tag);
      await mount(
        tester,
        DiscoverPage(
          books: empty ? const [] : remote.books.values.toList(),
          state: state,
          repository: repository,
          onSearch: () {},
        ),
      );
      expect(
        find.byKey(const ValueKey('discover-import-local')),
        empty ? findsOneWidget : findsNothing,
      );
      expect(find.text('该标签下暂无书籍'), empty ? findsNothing : findsOneWidget);
      if (!empty) expect(find.text('查看全部'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('空库选择目录后留在导入页并说明下一步扫描', (tester) async {
    local.pickedFolder = 'content://phase1-test/tree/disposable';
    await mount(tester, shelf());
    await tester.tap(find.byKey(const ValueKey('shelf-import-local')));
    await _settle(tester);
    expect(local.pickerCalls, 1);
    expect(find.byType(LocalLibraryPage), findsOneWidget);
    expect(find.text('已选择文件夹，可开始扫描'), findsOneWidget);
    expect(find.byKey(const ValueKey('local-library-scan')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('从本地书库手动选目录取消时保留当前页', (tester) async {
    await mount(
      tester,
      LocalLibraryPage(state: state, local: local, repository: repository),
    );
    await tester.tap(find.text('尚未选择，点击选择'));
    await _settle(tester);
    expect(local.pickerCalls, 1);
    expect(find.byType(LocalLibraryPage), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('未选择文件夹'), findsNothing);
  });

  for (final fontSize in [19.0, 30.0]) {
    testWidgets('TXT $fontSize 字号前后翻屏保留48逻辑像素且不越界', (tester) async {
      await state.setTypography(fontSize: fontSize);
      await state.setReaderPreferences(
        const ReaderPreferences(tapPaging: true),
      );
      await mount(
        tester,
        ReaderPage(
          novel: remote.books[71]!,
          state: state,
          repository: remote,
          initialChapter: 0,
        ),
        padding: const EdgeInsets.only(top: 24, bottom: 20),
      );
      final scroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('reader-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      final readableHeight =
          scroll.viewportDimension - 24 - FrostedHeader.toolbarHeight - 12 - 20;
      final distance = readableHeight - 48;
      await tester.tapAt(const Offset(210, 400));
      await _settle(tester);
      expect(scroll.pixels, 0);
      for (var step = 1; step <= 3; step++) {
        await tester.tapAt(const Offset(390, 400));
        await _settle(tester);
        expect(scroll.pixels, closeTo(distance * step, .01));
        expect(readableHeight - distance, 48);
      }
      for (var step = 2; step >= 0; step--) {
        await tester.tapAt(const Offset(30, 400));
        await _settle(tester);
        expect(scroll.pixels, closeTo(distance * step, .01));
      }
      await tester.tapAt(const Offset(30, 400));
      await _settle(tester);
      expect(scroll.pixels, scroll.minScrollExtent);
      scroll.jumpTo(scroll.maxScrollExtent - 10);
      await _settle(tester);
      await tester.tapAt(const Offset(390, 400));
      await _settle(tester);
      expect(scroll.pixels, scroll.maxScrollExtent);
      expect(state.chapterFor(71), 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final pdf in [false, true]) {
    for (final failSave in [false, true]) {
      testWidgets(
        '${pdf ? 'PDF' : 'TXT'} 顶栏快速书签 ${failSave ? '存储失败不报成功' : '去重、持久化及列表入口'}',
        (tester) async {
          final book = remote.books[71]!;
          if (pdf) {
            local.pdf = LocalBook(
              id: book.id,
              title: book.title,
              author: book.author,
              fileUri: 'content://phase1-test/sample.pdf',
              fileName: 'sample.pdf',
              kind: LocalBookKind.pdf,
              size: 1,
              modified: 0,
              chapters: const [],
              pageCount: 3,
            );
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  LocalPlatform.channel,
                  (call) async => call.method == 'renderPdfPage' ? '' : null,
                );
          }
          await mount(
            tester,
            pdf
                ? LocalPdfReaderPage(novel: book, state: state, local: local)
                : ReaderPage(
                    novel: book,
                    state: state,
                    repository: remote,
                    initialChapter: 0,
                  ),
          );
          preferences.rejectBookmarks = failSave;
          await tester.tap(_control('添加书签'));
          await _settle(tester);
          expect(find.byType(ReaderTools), findsNothing);
          if (failSave) {
            expect(find.text('书签保存失败，请重试'), findsOneWidget);
            expect(state.bookmarksFor(book.id), isEmpty);
            expect(find.textContaining('已添加'), findsNothing);
          } else {
            expect(state.bookmarksFor(book.id), hasLength(1));
            expect(find.text(pdf ? '已添加第 1 页书签' : '已添加书签'), findsOneWidget);
            await tester.tap(_control('添加书签'));
            await _settle(tester);
            expect(find.text(pdf ? '此页已有书签' : '此位置已有书签'), findsOneWidget);
            expect(state.bookmarksFor(book.id), hasLength(1));
            final reloaded = await LibraryState.load();
            addTearDown(reloaded.dispose);
            expect(
              reloaded.bookmarksFor(book.id).single.id,
              state.bookmarksFor(book.id).single.id,
            );
            if (pdf) {
              await tester.tap(
                find.byKey(const ValueKey('reader-catalogue-entry')),
              );
              await _settle(tester);
              expect(
                find.byKey(const ValueKey('pdf-navigation-sheet')),
                findsOneWidget,
              );
              expect(find.widgetWithText(ListTile, '第 1 页'), findsOneWidget);
            } else {
              ScaffoldMessenger.maybeOf(
                tester.element(find.byType(Scaffold).first),
              )?.clearSnackBars();
              await _settle(tester);
              await tester.tap(_control('阅读设置'));
              await _settle(tester);
              await tester.tap(find.text('书签'));
              await _settle(tester);
              expect(find.textContaining('本书 1 个书签'), findsOneWidget);
            }
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
