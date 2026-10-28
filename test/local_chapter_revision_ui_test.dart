import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:wenku8_flutter/catalog.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/app_ui.dart';
import 'package:wenku8_flutter/book_tags.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_library.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/pages.dart';

// The persistent isolate's callbacks can belong to the widget clock while a
// subsequent scan starts in runAsync. Drive both clocks until that scan ends.
Future<void> _scanWithFrames(WidgetTester tester, LocalLibraryStore store, {bool force = false}) async {
  var done = false;
  Object? error;
  await tester.runAsync(() async {
    store.scan(force: force).then((_) { done = true; }, onError: (Object failure) {
      error = failure;
      done = true;
    });
  });
  for (var i = 0; i < 200 && !done; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done, isTrue, reason: 'background scan must finish');
  if (error != null) throw error!;
}

class _RetryLocalDetail extends CompositeNovelRepository {
  _RetryLocalDetail(LocalLibraryStore store)
      : super(local: store, remote: const DemoNovelRepository());
  final first = Completer<Novel>();
  var detailCalls = 0;
  var chapterCalls = 0;
  @override
  Future<Novel> detail(Novel novel) =>
      ++detailCalls == 1 ? first.future : super.detail(novel);
  @override
  Future<List<NovelChapter>> chapters(int id) {
    chapterCalls++;
    return super.chapters(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalLibraryStore store;
  late LibraryState state;
  var text = '';
  var serial = 0;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('chapter-revision-ui-');
    SharedPreferences.setMockInitialValues({
      'local_library_folder': 'content://test/tree',
      'reduceMotion': true,
    });
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
      if (call.method == 'scanLocalFolder') {
        return {
          'complete': true,
          'entries': [
            {
              'uri': 'content://test/one',
              'name': 'one.txt',
              'size': 1000,
              'modified': 1,
            },
          ],
        };
      }
      if (call.method == 'fingerprintLocalText') {
        return sha256.convert(utf8.encode(text)).toString();
      }
      if (call.method == 'prepareLocalText') {
        final file = File('${root.path}/decoded-${serial++}.txt');
        await file.writeAsString(text);
        return (call.arguments as Map)['withFingerprint'] == true
            ? {'path': file.path, 'fingerprint': sha256.convert(utf8.encode(text)).toString()}
            : file.path;
      }
      throw MissingPluginException();
    });
    text = '第一章 起点\n甲独立正文段落。\n第二章 终点\n乙唯一目标段落。\n';
    store = await LocalLibraryStore.load();
    state = await LibraryState.load();
    await TagStore.load();
    state.bindLocalChapters(store);
    await store.scan();
  });
  tearDown(() async {
    state.dispose();
    store.dispose();
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(LocalPlatform.channel, null);
    await root.delete(recursive: true);
  });

  group('detail while a scan owns the mutation lock', () {
    late Completer<Object?> blocked;
    late Future<void> scanResult;
    setUp(() async {
      blocked = Completer<Object?>();
      final entered = Completer<void>();
      messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) {
        if (!entered.isCompleted) entered.complete();
        return blocked.future;
      });
      scanResult = expectLater(store.scan(), throwsA(isA<IncompleteScanException>()));
      await entered.future;
    });
    tearDown(() async {
      if (!blocked.isCompleted) blocked.complete({'complete': false});
      await scanResult;
    });
    testWidgets('committed detail and body open while startup scan holds the lock', (tester) async {
      final book = store.books.single;
      await tester.pumpWidget(MaterialApp(theme: novelTheme(Brightness.light),
        home: DetailLoaderPage(novel: store.toNovel(book), state: state,
          repository: CompositeNovelRepository(local: store, remote: const DemoNovelRepository()),
          loadTimeout: const Duration(milliseconds: 100))));
      expect(tester.widget<DetailPage>(find.byType(DetailPage)).isLoading, isTrue);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      final ready = tester.widget<DetailPage>(find.byType(DetailPage));
      expect(ready.loadError, isNull);
      expect(ready.isLoading, isFalse);
      expect(ready.novel.chapters, hasLength(2));
      expect(blocked.isCompleted, isFalse);
      String? content;
      await tester.runAsync(() async {
        store.chapterContent(book.id, ready.novel.chapters.first).then((value) => content = value);
      });
      for (var attempt = 0; attempt < 200 && content == null; attempt++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(content, '甲独立正文段落。');
      await tester.runAsync(() async {
        blocked.complete({'complete': false});
        await scanResult;
      });
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('timeout survives unchanged scan notifications and retries exactly once', (tester) async {
    final book = store.books.single;
    final repository = _RetryLocalDetail(store);
    await tester.pumpWidget(MaterialApp(theme: novelTheme(Brightness.light),
      home: DetailLoaderPage(novel: store.toNovel(book), state: state,
        repository: repository, loadTimeout: const Duration(milliseconds: 100))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    for (var notification = 0; notification < 3; notification++) {
      await _scanWithFrames(tester, store, force: true);
      expect(repository.detailCalls, 1);
      expect(find.byType(DetailSkeleton), findsNothing);
      expect(find.text('重试'), findsOneWidget);
    }
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    final ready = tester.widget<DetailPage>(find.byType(DetailPage));
    expect(ready.loadError, isNull);
    expect(ready.novel.chapters, hasLength(2));
    expect(repository.detailCalls, 2);
    repository.first.complete(store.toNovel(book));
    await tester.pumpAndSettle();
    expect(repository.chapterCalls, 1);
    for (var attempt = 0; attempt < 6; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('missing imported record is an explicit retriable error', (tester) async {
    final novel = store.toNovel(store.books.single);
    await tester.runAsync(() => store.removeBookRecordOnly(novel.id));
    await tester.pumpWidget(MaterialApp(theme: novelTheme(Brightness.light),
      home: DetailLoaderPage(novel: novel, state: state, repository: store)));
    await tester.pumpAndSettle();
    final failed = tester.widget<DetailPage>(find.byType(DetailPage));
    expect(failed.isLoading, isFalse);
    expect(failed.loadError.toString(), contains('没有这本书的记录'));
    expect(find.text('重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('stale directory times out behind scan then retries after release', (tester) async {
    final book = store.books.single;
    await tester.runAsync(() async {
      store.dispose();
      await File('${root.path}/local_books/index.json').writeAsString(jsonEncode({
        'books': [{...book.toJson(), 'chapterSplitVersion': 0}],
      }));
      store = await LocalLibraryStore.load(operationTimeout: const Duration(milliseconds: 80));
    });
    late Completer<Object?> blocked;
    late Future<void> scan;
    await tester.runAsync(() async {
      blocked = Completer<Object?>();
      final entered = Completer<void>();
      messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) {
        if (!entered.isCompleted) entered.complete();
        return blocked.future;
      });
      scan = expectLater(store.scan(), throwsA(isA<IncompleteScanException>()));
      await entered.future;
    });
    await tester.pumpWidget(MaterialApp(theme: novelTheme(Brightness.light),
      home: DetailLoaderPage(novel: store.toNovel(book), state: state,
        repository: store, loadTimeout: const Duration(milliseconds: 100))));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(DetailSkeleton), findsNothing);
    await tester.runAsync(() async {
      blocked.complete({'complete': false});
      await scan;
    });
    await tester.tap(find.text('重试'));
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (!tester.widget<DetailPage>(find.byType(DetailPage)).isLoading) break;
    }
    final ready = tester.widget<DetailPage>(find.byType(DetailPage));
    expect(ready.loadError, isNull);
    expect(ready.novel.chapters, hasLength(2));
    for (var attempt = 0; attempt < 6; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('composite remote detail does not require a local record', (tester) async {
    const remote = DemoNovelRepository();
    final novel = (await remote.list()).first;
    await tester.pumpWidget(MaterialApp(theme: novelTheme(Brightness.light),
      home: DetailLoaderPage(novel: novel, state: state,
        repository: CompositeNovelRepository(local: store, remote: remote))));
    await tester.pumpAndSettle();
    final ready = tester.widget<DetailPage>(find.byType(DetailPage));
    expect(ready.isLoading, isFalse);
    expect(ready.loadError, isNull);
    expect(ready.novel.chapters, isNotEmpty);
    for (var attempt = 0; attempt < 6; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'active reader reloads its directory and body after a background split',
    (tester) async {
      tester.view.physicalSize = const Size(412, 892);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final book = store.books.single;
      final chapters = await tester.runAsync(() => store.chapters(book.id));
      final novel = store.toNovel(book).withChapters(chapters!);
      await tester.runAsync(
        () => state.savePosition(
          novel: novel,
          chapter: 1,
          offset: 0,
          maximum: 0,
          width: 0,
          paragraphIndex: 0,
          textOffset: 0,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: ReaderPage(
            novel: novel,
            state: state,
            repository: store,
            initialChapter: 1,
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('乙唯一目标段落'), findsOneWidget);
      text = '序章 新开场\n新正文。\n第一章 起点\n甲独立正文段落。\n第二章 终点\n乙唯一目标段落。\n';
      await _scanWithFrames(tester, store);
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(state.positionFor(book.id)!.chapter, 2);
      expect(find.textContaining('乙唯一目标段落'), findsOneWidget);
      expect(find.textContaining('甲独立正文段落'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(state.positionFor(book.id)!.chapter, 2);
    },
  );

  testWidgets('fresh catalogue selection keeps the requested chapter instead of saved progress', (tester) async {
    final book = store.books.single;
    final chapters = await tester.runAsync(() => store.chapters(book.id));
    final novel = store.toNovel(book).withChapters(chapters!);
    await tester.runAsync(() => state.savePosition(novel: novel, chapter: 1,
      offset: 0, maximum: 0, width: 0));
    await tester.pumpWidget(MaterialApp(theme: novelTheme(Brightness.light),
      home: ReaderPage(novel: novel, state: state, repository: store, initialChapter: 0)));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('甲独立正文段落'), findsOneWidget);
    expect(find.textContaining('乙唯一目标段落'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'active detail replaces the stale directory after a background scan',
    (tester) async {
      final book = store.books.single;
      await tester.pumpWidget(
        MaterialApp(
          theme: novelTheme(Brightness.light),
          home: DetailLoaderPage(
            novel: store.toNovel(book),
            state: state,
            repository: store,
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      DetailPage detail() => tester.widget<DetailPage>(find.byType(DetailPage));
      expect(detail().novel.chapters, hasLength(2));
      text = '序章 新开场\n新正文。\n第一章 起点\n甲独立正文段落。\n第二章 终点\n乙唯一目标段落。\n';
      await _scanWithFrames(tester, store);
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(detail().novel.chapters, hasLength(3));
      expect(detail().novel.chapters.first.title, '序章 新开场');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
