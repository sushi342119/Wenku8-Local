import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_interactions.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/backup_page.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/pages.dart';
import 'package:wenku8_flutter/reader_find.dart';
import 'package:wenku8_flutter/reader_content.dart';

import 'support/offline_fixture.dart';

Finder _button(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is GlassIconButton && widget.label == label,
      ),
      matching: find.byType(InkWell),
    )
    .first;
Finder _tapKey(String key) => find
    .descendant(of: find.byKey(ValueKey(key)), matching: find.byType(InkWell))
    .first;

void main({
  Future<void> Function(WidgetTester tester, GlobalKey key, String name)?
  capture,
  bool nativePlatform = false,
}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibraryState state;
  late GlobalKey boundary;
  late OfflineFixtureRepository repository;
  setUp(() async {
    if (!nativePlatform) {
      Map<String, dynamic>? clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = Map<String, dynamic>.from(call.arguments);
            }
            if (call.method == 'Clipboard.getData') return clipboard;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
    }
    SharedPreferences.setMockInitialValues({'reduceMotion': true});
    state = await LibraryState.load();
    repository = OfflineFixtureRepository();
    boundary = GlobalKey();
  });
  tearDown(() => state.dispose());

  Future<void> mount(
    WidgetTester tester,
    Widget page, {
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
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> io(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 320));
    for (var frame = 0; frame < 12; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (capture != null) await capture(tester, boundary, name);
  }

  Future<void> findPanel(WidgetTester tester) async {
    await tester.tap(_button('阅读设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('reader-open-find')));
    await tester.tap(find.text('章内查找'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'chapter find closes settings first, jumps to lazy occurrence and never refetches',
    (tester) async {
      final paragraphs = List.generate(
        120,
        (index) => index == 95
            ? '${'前文' * 80} 唯一查找词 ${'后文' * 30}'
            : '第 $index 段 ${'正文内容' * (index % 5 + 1)}',
      );
      final novel = offlineFixtureBook(71).withChapters([
        NovelChapter('章内查找样本', paragraphs.join('\n\n'), id: 71001),
      ]);
      repository.books[71] = novel;
      await mount(
        tester,
        ReaderPage(
          novel: novel,
          state: state,
          repository: repository,
          initialChapter: 0,
        ),
      );
      final requests = repository.calls.length;
      await findPanel(tester);
      expect(find.byType(ReaderFindPanel), findsOneWidget);
      expect(find.byType(GlassOverlaySurface), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('reader-find-field')),
        '唯一查找词',
      );
      await io(tester);
      expect(find.text('1 处匹配'), findsOneWidget);
      await shot(tester, 'chapter-find-results');
      await tester.tap(_tapKey('reader-find-result-0'));
      await tester.pumpAndSettle();
      expect(find.byType(GlassOverlaySurface), findsNothing);
      final paragraph = find.byKey(const ValueKey('paragraph-95'));
      expect(paragraph, findsOneWidget);
      final selected = tester.widget<Text>(paragraph);
      expect(selected.textSpan, isNotNull);
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('reader-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final position = scroll.position.pixels;
      expect(position, greaterThan(1000));
      expect(repository.calls.length, requests);
      await shot(tester, 'chapter-find-highlight');
      await tester.pump(const Duration(seconds: 9));
      expect(tester.widget<Text>(paragraph).data, paragraphs[95]);
      expect(scroll.position.pixels, closeTo(position, 1));
      expect(state.positionFor(71)!.paragraphIndex, 95);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'chapter find keyboard shortcut and composition cancel stale work',
    (tester) async {
      await mount(
        tester,
        ReaderPage(
          novel: repository.books[71]!,
          state: state,
          repository: repository,
          initialChapter: 0,
        ),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderFindPanel), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('reader-find-field')),
        '绝无此词',
      );
      await io(tester);
      expect(find.text('本章没有匹配文字'), findsOneWidget);
      await tester.tap(_button('关闭章内查找'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderFindPanel), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      'find panel is scrollable at 2x text in compact ${brightness.name} viewport',
      (tester) async {
        tester.view.physicalSize = const Size(390, 500);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetViewInsets();
        });
        tester.view.viewInsets = const FakeViewPadding(bottom: 180);
        final content = await tester.runAsync(
          () => ReaderContent.parse('查找词\n\n查找词\n\n查找词'),
        );
        await mount(
          tester,
          Scaffold(
            body: Builder(
              builder: (context) => GlassTextButton(
                onPressed: () => showJellySheet<ReaderMatch>(
                  context: context,
                  reduceMotion: true,
                  builder: (_) => ReaderFindPanel(content: content!),
                ),
                child: const Text('打开查找'),
              ),
            ),
          ),
          scale: 2,
          brightness: brightness,
        );
        await tester.tap(find.text('打开查找'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('reader-find-field')),
          '查找词',
        );
        await io(tester);
        await tester.drag(
          find.byKey(const ValueKey('reader-find-scroll')),
          const Offset(0, -170),
        );
        await tester.pumpAndSettle();
        await shot(tester, 'find-large-${brightness.name}');
        expect(tester.takeException(), isNull);
        Navigator.pop(tester.element(find.byType(ReaderFindPanel)));
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'shelf filters local title author ID and persisted reading status without requests',
    (tester) async {
      await tester.runAsync(() async {
        for (final id in [71, 72, 73]) {
          await state.setShelfMembership(
            id,
            true,
            novel: offlineFixtureBook(id),
          );
        }
        await state.savePosition(
          novel: offlineFixtureBook(71),
          chapter: 0,
          offset: 12,
          maximum: 3000,
          width: 390,
        );
        await state.savePosition(
          novel: offlineFixtureBook(72),
          chapter: 2,
          offset: 3000,
          maximum: 3000,
          width: 390,
        );
      });
      await mount(
        tester,
        Scaffold(
          body: ShelfPage(
            books: const [],
            state: state,
            repository: repository,
          ),
        ),
      );
      await tester.enterText(find.byKey(const ValueKey('shelf-search')), '73');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shelf-book-73')), findsOneWidget);
      expect(find.byKey(const ValueKey('shelf-book-71')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('shelf-search')),
        '离线作者',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shelf-book-71')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('shelf-search')), '');
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(GlassMenuItem),
          matching: find.text('已读完'),
        ),
      );
      await io(tester);
      expect(find.byKey(const ValueKey('shelf-book-72')), findsOneWidget);
      expect(find.byKey(const ValueKey('shelf-book-71')), findsNothing);
      expect((await LibraryState.load()).shelfFilter, 'finished');
      expect(repository.calls, isEmpty);
      await shot(tester, 'shelf-finished-filter');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shelf undo is usable after removed anchor is disposed and preserves original added time',
    (tester) async {
      final novel = repository.books[71]!;
      await tester.runAsync(
        () => state.setShelfMembership(
          71,
          true,
          novel: novel,
          restoredAddedAt: 123,
        ),
      );
      await mount(
        tester,
        Scaffold(
          body: ShelfPage(
            books: const [],
            state: state,
            repository: repository,
          ),
        ),
      );
      await tester.tap(_button('${novel.title}书架操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移出书架'));
      await io(tester);
      expect(find.text('已移出书架'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await io(tester);
      expect(state.contains(71), isTrue);
      expect(state.addedAt(71), 123);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recent successful search can be recalled and cleared with confirmation',
    (tester) async {
      await mount(
        tester,
        HomeShell(state: state, repository: const DemoNovelRepository()),
      );
      await tester.tap(_button('搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('expanded-search-input')),
        '星尘',
      );
      await io(tester);
      expect(state.recentSearches, ['星尘']);
      await tester.enterText(
        find.byKey(const ValueKey('expanded-search-input')),
        '',
      );
      await io(tester);
      expect(find.byKey(const ValueKey('recent-search-星尘')), findsOneWidget);
      await shot(tester, 'recent-searches');
      await tester.tap(_tapKey('recent-search-星尘'));
      await io(tester);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('expanded-search-input')),
            )
            .controller!
            .text,
        '星尘',
      );
      expect(find.text('找到 1 个结果'), findsOneWidget);
      // Use the real clear control after recall: re-focusing a live Android
      // IME with tester.enterText can replay its older editing snapshot.
      await tester.tap(find.byTooltip('清空搜索'));
      await io(tester);
      final results = find.descendant(
        of: find.byType(InlineSearchResults),
        matching: find.byType(Scrollable),
      );
      if (results.evaluate().isNotEmpty) {
        tester.state<ScrollableState>(results.first).position.jumpTo(0);
        await tester.pumpAndSettle();
      }
      await shot(tester, 'recent-cleared-before-menu');
      await tester.tap(_button('清空最近搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(state.recentSearches, ['星尘']);
      await tester.tap(_button('清空最近搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空搜索记录'));
      await io(tester);
      expect(state.recentSearches, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'backup clipboard preview makes no changes until explicit merge and supports cancellation',
    (tester) async {
      final backup = await tester.runAsync(
        () => LibraryBackup.fromRecords({
          'shelf': ['71'],
          'novel_meta_71': jsonEncode(repository.books[71]!.toSnapshot()),
        }),
      );
      final text = await tester.runAsync(() => backup!.encode());
      await tester.runAsync(
        () => Clipboard.setData(ClipboardData(text: text!)),
      );
      await mount(tester, LibraryBackupPage(state: state));
      await tester.tap(find.text('从剪贴板读取备份'));
      await io(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('backup-preview')),
        160,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('backup-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.byKey(const ValueKey('backup-preview')), findsOneWidget);
      expect(state.shelf, isEmpty);
      await shot(tester, 'backup-preview');
      await tester.ensureVisible(find.text('取消恢复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消恢复'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('backup-preview')), findsNothing);
      expect(state.shelf, isEmpty);
      await tester.ensureVisible(find.text('从剪贴板读取备份'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从剪贴板读取备份'));
      await io(tester);
      await tester.ensureVisible(find.text('确认合并恢复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认合并恢复'));
      await io(tester);
      expect(state.shelf, {71});
      expect(find.byKey(const ValueKey('backup-preview')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid backup shows inline retry state and leaves the library intact',
    (tester) async {
      await tester.runAsync(() => state.setShelfMembership(71, true));
      await tester.runAsync(
        () => Clipboard.setData(const ClipboardData(text: '{}')),
      );
      await mount(tester, LibraryBackupPage(state: state));
      await tester.tap(find.text('从剪贴板读取备份'));
      await io(tester);
      expect(find.byKey(const ValueKey('backup-error')), findsOneWidget);
      expect(state.shelf, {71});
      expect(find.byKey(const ValueKey('backup-preview')), findsNothing);
      await shot(tester, 'backup-invalid');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shared navigation coalesces repeated activation and releases slots after dismissal',
    (tester) async {
      var opened = 0;
      await mount(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => GlassTextButton(
              onPressed: () {
                for (var index = 0; index < 20; index++) {
                  unawaited(
                    pushNovelPage<void>(
                      context,
                      Scaffold(body: Text('子页面 ${++opened}')),
                      reduceMotion: true,
                      slot: 'test-page',
                    ),
                  );
                }
              },
              child: const Text('打开页面'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开页面'));
      await tester.pumpAndSettle();
      expect(find.text('子页面 1'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开页面'));
      await tester.pumpAndSettle();
      expect(find.text('子页面 21'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'duplicate unanchored drawers open one surface and menu height follows large labels',
    (tester) async {
      await mount(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => GlassTextButton(
              onPressed: () {
                for (var index = 0; index < 20; index++) {
                  unawaited(
                    showJellySheet<void>(
                      context: context,
                      reduceMotion: true,
                      builder: (_) => GlassMenuItem(
                        label: '这是完整显示的较长菜单选项，适应无障碍大字号',
                        onPressed: () {},
                      ),
                    ),
                  );
                }
              },
              child: const Text('打开抽屉'),
            ),
          ),
        ),
        scale: 2,
      );
      await tester.tap(find.text('打开抽屉'));
      await tester.pumpAndSettle();
      expect(find.byType(GlassOverlaySurface), findsOneWidget);
      expect(
        tester.getSize(find.byType(GlassMenuItem)).height,
        greaterThan(52),
      );
      await shot(tester, 'large-menu-row');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keep-screen binding releases on covered route background and disposal without article reflow',
    (tester) async {
      final calls = <bool>[];
      Future<bool?> awake() async => nativePlatform
          ? await LocalPlatform.channel.invokeMethod<bool>('getKeepScreenOn')
          : calls.isNotEmpty && calls.last;
      if (!nativePlatform) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalPlatform.channel, (call) async {
              if (call.method == 'keepScreenOn') {
                calls.add(call.arguments as bool);
              }
              if (call.method == 'getKeepScreenOn') {
                return calls.isNotEmpty && calls.last;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(LocalPlatform.channel, null),
        );
      }
      await mount(
        tester,
        ReaderPage(
          novel: repository.books[71]!,
          state: state,
          repository: repository,
          initialChapter: 0,
        ),
      );
      final article = tester.widget(find.byKey(const ValueKey('paragraph-0')));
      final saved = state.setKeepScreenOn(true);
      await io(tester);
      await saved;
      expect(await awake(), isTrue);
      await tester.tap(_button('阅读设置'));
      await tester.pumpAndSettle();
      expect(await awake(), isFalse);
      expect(
        tester.widget(find.byKey(const ValueKey('paragraph-0'))),
        same(article),
      );
      await tester.tap(_button('关闭阅读设置'));
      await tester.pumpAndSettle();
      expect(await awake(), isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(await awake(), isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(await awake(), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(await awake(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
