import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/main.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_chrome.dart';

class _Reader extends DemoNovelRepository {
  int calls = 0;
  bool empty = false;
  final book = Novel(
    id: 81234,
    title: '阅读细节样本',
    author: '样本',
    genre: 'QA',
    summary: '本地',
    colors: const [Colors.black, Colors.grey],
    chapters: const [
      NovelChapter('第一章', '', id: 8123401),
      NovelChapter('第二章', '', id: 8123402),
    ],
  );
  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    calls++;
    if (empty) return '  \n ';
    return List.generate(
      220,
      (index) => '段落 $index：${'阅读位置应保留在同一段落，控件与正文独立更新。' * (1 + index % 5)}',
    ).join('\n\n');
  }
}

class _Routes extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

Finder _control(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is GlassIconButton && widget.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;

ScrollableState _scroll(WidgetTester tester) => tester.state<ScrollableState>(
  find
      .descendant(
        of: find.byKey(const ValueKey('reader-scroll')),
        matching: find.byType(Scrollable),
      )
      .first,
);

ParagraphPosition _anchor(WidgetTester tester) {
  final registry = tester
      .widget<ReaderParagraph>(find.byType(ReaderParagraph).first)
      .registry;
  final context = tester.element(find.byType(ReaderPage));
  return registry.capture(
    _scroll(tester).position.pixels +
        MediaQuery.paddingOf(context).top +
        FrostedHeader.toolbarHeight +
        12,
  )!;
}

Future<void> _settle(WidgetTester tester) async {
  for (var step = 0; step < 14; step++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 12)),
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
  late _Reader repository;
  late GlobalKey boundary;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    state = await LibraryState.load();
    repository = _Reader();
    boundary = GlobalKey();
  });
  tearDown(() => state.dispose());

  Future<void> reader(
    WidgetTester tester, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
            novel: repository.book,
            state: state,
            repository: repository,
            initialChapter: 0,
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  testWidgets(
    'font and line spacing changes preserve the visible paragraph anchor',
    (tester) async {
      await reader(tester);
      _scroll(tester).position.jumpTo(5200);
      await _settle(tester);
      final before = _anchor(tester);
      await tester.tap(_control('阅读设置'));
      await tester.pumpAndSettle();
      final font = tester.widget<CupertinoSlider>(
        find.byKey(const ValueKey('reader-font-slider')),
      );
      font.onChangeEnd!(27);
      await _settle(tester);
      final afterFont = _anchor(tester);
      expect(afterFont.index, before.index);
      expect(afterFont.fraction, closeTo(before.fraction, .015));
      final spacing = tester.widget<CupertinoSlider>(
        find.byKey(const ValueKey('reader-line-height-slider')),
      );
      spacing.onChangeEnd!(2.2);
      await _settle(tester);
      final afterSpacing = _anchor(tester);
      expect(afterSpacing.index, before.index);
      expect(afterSpacing.fraction, closeTo(before.fraction, .015));
      expect(repository.calls, 1);
      await tester.tap(_control('关闭阅读设置'));
      await _settle(tester);
      expect(
        state.positionFor(repository.book.id)!.paragraphIndex,
        before.index,
      );
      if (capture != null) {
        await capture(tester, boundary, 'reader-anchored-layout');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(
        state.positionFor(repository.book.id)!.paragraphIndex,
        before.index,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rotation preserves the reading paragraph without refetching the body',
    (tester) async {
      await reader(tester);
      _scroll(tester).position.jumpTo(7100);
      await _settle(tester);
      final before = _anchor(tester);
      tester.view.physicalSize = const Size(800, 420);
      await _settle(tester);
      final after = _anchor(tester);
      expect(after.index, before.index);
      expect(after.fraction, closeTo(before.fraction, .025));
      expect(repository.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'focus reading hides controls but retains live edge blur without shifting paragraphs',
    (tester) async {
      await reader(tester, brightness: Brightness.dark);
      _scroll(tester).position.jumpTo(900);
      await _settle(tester);
      final paragraph = find.byType(ReaderParagraph).first;
      final original = tester.widget(paragraph);
      final offset = _scroll(tester).position.pixels;
      final header = tester.element(find.byType(FrostedHeader));
      final underlay = tester.element(find.byType(ReaderEdgeBlur));
      await tester.tapAt(const Offset(210, 310));
      await tester.pumpAndSettle();
      expect(find.byType(GlassIconButton), findsNothing);
      expect(tester.element(find.byType(FrostedHeader)), same(header));
      expect(tester.element(find.byType(ReaderEdgeBlur)), same(underlay));
      expect(tester.widget(paragraph), same(original));
      expect(_scroll(tester).position.pixels, offset);
      if (capture != null) await capture(tester, boundary, 'reader-focus-dark');
      await tester.tapAt(const Offset(210, 310));
      await tester.pumpAndSettle();
      expect(find.byType(GlassIconButton), findsNWidgets(3));
      expect(
        find.byKey(const ValueKey('reader-bookmarks-entry')),
        findsOneWidget,
      );
      expect(tester.widget(paragraph), same(original));
      expect(repository.calls, 1);
    },
  );

  testWidgets(
    'keyboard paging uses the existing viewport and keeps chapter boundaries',
    (tester) async {
      await reader(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await _settle(tester);
      expect(_scroll(tester).position.pixels, greaterThan(400));
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await _settle(tester);
      expect(_scroll(tester).position.pixels, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await _settle(tester);
      expect(_scroll(tester).position.extentAfter, lessThan(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await _settle(tester);
      expect(_scroll(tester).position.pixels, 0);
      final paragraph = find.byType(ReaderParagraph).first;
      final original = tester.widget(paragraph);
      await tester.tap(_control('阅读设置'));
      await tester.pumpAndSettle();
      expect(tester.widget(paragraph), same(original));
      await tester.tap(_control('关闭阅读设置'));
      await tester.pumpAndSettle();
      expect(tester.widget(paragraph), same(original));
      expect(repository.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty chapter bodies are retryable and do not overwrite resume data',
    (tester) async {
      repository.empty = true;
      await reader(tester);
      expect(find.text('章节加载失败'), findsOneWidget);
      expect(state.positionFor(repository.book.id), isNull);
      repository.empty = false;
      await tester.tap(find.text('重试'));
      await _settle(tester);
      expect(find.text('章节加载失败'), findsNothing);
      expect(find.byType(ReaderParagraph), findsWidgets);
      expect(repository.calls, 2);
    },
  );

  testWidgets(
    'long glass actions remain readable at large text scale on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const Scaffold(
              body: Center(
                child: GlassPillButton(
                  icon: CupertinoIcons.book,
                  label: '正在加载目录',
                  onPressed: null,
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(GlassPillButton)).height,
        greaterThan(54),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repeated detail activation opens one route and releases its guard on return',
    (tester) async {
      final observer = _Routes();
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          navigatorObservers: [observer],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openDetail(
                  context,
                  demoNovels.first,
                  state,
                  const DemoNovelRepository(),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      final action = tester
          .widget<TextButton>(find.byType(TextButton))
          .onPressed!;
      action();
      action();
      await _settle(tester);
      expect(observer.pushes, 2);
      await tester.tap(_control('返回'));
      await _settle(tester);
      action();
      await _settle(tester);
      expect(observer.pushes, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '120 glass previews retain MaterialApp and the solid home subtree',
    (tester) async {
      await tester.pumpWidget(
        NovelApp(state: state, repository: const DemoNovelRepository()),
      );
      await tester.pumpAndSettle();
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      final home = tester.widget<HomeShell>(find.byType(HomeShell));
      for (var index = 0; index < 120; index++) {
        await state.setGlassBlur((index % 25).toDouble(), persist: false);
        await state.setGlassOpacity((index % 101) / 100, persist: false);
        await tester.pump();
        expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(app));
        expect(tester.widget<HomeShell>(find.byType(HomeShell)), same(home));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'IME composition delays searching and input edits retain the result widget',
    (tester) async {
      // Use one IME source; a native keyboard must not commit a simultaneously
      // injected composing envelope during the device regression.
      final hadKeyboardStub = tester.testTextInput.isRegistered;
      if (!hadKeyboardStub) {
        tester.testTextInput.register();
        addTearDown(tester.testTextInput.unregister);
      }
      final queries = <String>[];
      final search = _ImmediateSearch(queries);
      await tester.pumpWidget(NovelApp(state: state, repository: search));
      await tester.pumpAndSettle();
      await tester.tap(_control('搜索'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('expanded-search-input'));
      final results = tester.widget(find.byType(InlineSearchResults));
      await tester.enterText(input, '草稿');
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '玻璃',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(queries, ['']);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '玻璃',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(queries, ['', '玻璃']);
      expect(tester.widget(find.byType(InlineSearchResults)), same(results));
      await tester.enterText(input, '不要请求');
      await tester.tap(find.byKey(const ValueKey('inline-search-close')));
      await tester.pumpAndSettle();
      expect(queries, ['', '玻璃']);
      expect(tester.takeException(), isNull);
    },
  );
}

class _ImmediateSearch extends DemoNovelRepository {
  _ImmediateSearch(this.queries);
  final List<String> queries;
  @override
  Future<List<Novel>> search(String query) async {
    queries.add(query);
    return const [];
  }
}
