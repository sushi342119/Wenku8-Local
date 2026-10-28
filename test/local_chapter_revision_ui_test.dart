import 'dart:io';

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
      if (call.method == 'prepareLocalText') {
        final file = File('${root.path}/decoded-${serial++}.txt');
        await file.writeAsString(text);
        return file.path;
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
      await tester.runAsync(() => store.scan());
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
      await tester.runAsync(() => store.scan());
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
