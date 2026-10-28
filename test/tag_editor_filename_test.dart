import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/book_tags.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_library.dart';
import 'package:wenku8_flutter/tag_pages.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getExternalStoragePath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalLibraryStore local;
  late LibraryState state;
  late PathProviderPlatform oldPaths;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tag-editor-');
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    await TagStore.load();
    state = await LibraryState.load();
    final dir = await Directory('${root.path}/novels').create();
    await File('${dir.path}/书 ✦古风.txt').writeAsString('第一章 开场\n内容');
    local = await LocalLibraryStore.load();
    await local.scanAppFolder();
    await TagStore.shared.createTag('已读');
    debugDefaultTargetPlatformOverride = null;
  });
  tearDown(() async {
    local.dispose();
    state.dispose();
    PathProviderPlatform.instance = oldPaths;
    debugDefaultTargetPlatformOverride = null;
    await root.delete(recursive: true);
  });

  Future<void> openEditor(
    WidgetTester tester, {
    LocalLibraryStore? store,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showTagEditor(
                context,
                state,
                local.books.single.id,
                local: store,
              ),
              child: const Text('编辑标签'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑标签'));
    await tester.pumpAndSettle();
  }

  testWidgets('invalid name is blocked inline and never creates a definition', (
    tester,
  ) async {
    await openEditor(tester, store: local);
    await tester.enterText(find.byType(TextField), '有 空格');
    await tester.runAsync(() async {
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('新建失败'), findsOneWidget);
    expect(TagStore.shared.tags.any((t) => t.name == '有 空格'), isFalse);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'missing local repository is an error instead of internal-only success',
    (tester) async {
      await openEditor(tester);
      await tester.tap(find.text('已读'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(find.text('标签已保存'), findsNothing);
      expect(TagStore.shared.tagNamesForBook(local.books.single.id), ['古风']);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'saving editor replaces, removes one, then clears all filename tags',
    (tester) async {
      final book = local.books.single;
      final ancient = TagStore.shared.tags
          .singleWhere((tag) => tag.name == '古风')
          .id;
      final read = TagStore.shared.tags
          .singleWhere((tag) => tag.name == '已读')
          .id;
      await tester.runAsync(() async {
        await TagStore.shared.createTag('现代');
        await local.setTagsForBook(book.id, [ancient, read]);
      });
      Future<void> saveAndCheck(String filename, List<String> names) async {
        await tester.runAsync(() async {
          await tester.tap(find.text('保存'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(local.books.single.fileName, filename);
        expect(TagStore.shared.tagNamesForBook(book.id), names);
        final files = await tester.runAsync(
          () => Directory('${root.path}/novels').list().toList(),
        );
        expect(files!.map((file) => file.path.split('/').last), [filename]);
      }

      await openEditor(tester, store: local);
      await tester.tap(find.text('古风'));
      await tester.tap(find.text('现代'));
      await saveAndCheck('书 ✦已读 ✦现代.txt', ['已读', '现代']);
      await tester.tap(find.text('编辑标签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('现代'));
      await saveAndCheck('书 ✦已读.txt', ['已读']);
      await tester.tap(find.text('编辑标签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已读'));
      await saveAndCheck('书.txt', []);
    },
  );

  testWidgets('rename failure keeps dialog open, old tags and original file', (
    tester,
  ) async {
    final book = local.books.single;
    await tester.runAsync(
      () => File('${root.path}/novels/书 ✦古风 ✦已读.txt').writeAsString('冲突文件'),
    );
    await openEditor(tester, store: local);
    await tester.tap(find.text('已读'));
    await tester.runAsync(() async {
      await tester.tap(find.text('保存'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.text('标签已保存'), findsNothing);
    expect(TagStore.shared.tagNamesForBook(book.id), ['古风']);
    expect(await tester.runAsync(() => File(book.sourceKey).exists()), isTrue);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
}
