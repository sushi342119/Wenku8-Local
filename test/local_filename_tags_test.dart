import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wenku8_flutter/book_tags.dart';
import 'package:wenku8_flutter/local_library.dart';
import 'package:wenku8_flutter/local_platform.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getExternalStoragePath() async => root;
}

class _Prefs extends InMemorySharedPreferencesStore {
  _Prefs() : super.empty();
  String? failOnce;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == failOnce) {
      failOnce = null;
      return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const tree = 'content://test/tree/books';
  late Directory root;
  late PathProviderPlatform previousPaths;
  late _Prefs storage;
  final stores = <LocalLibraryStore>[];
  final entries = <Map<String, Object?>>[];
  final renameCalls = <(String, String)>[];
  String? deniedName;
  var nextUri = 0;
  var denyDelete = false;

  Future<LocalLibraryStore> load() async {
    final store = await LocalLibraryStore.load();
    stores.add(store);
    return store;
  }

  Future<File> source(String name) async {
    final file = File('${root.path}/novels/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(utf8.encode('\uFEFF第一章 开场\r\n原始内容 #【】()\r\n'));
    return file;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filename-tags-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    storage = _Prefs();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = storage;
    await TagStore.load();
    entries.clear();
    renameCalls.clear();
    deniedName = null;
    nextUri = 0;
    denyDelete = false;
    messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
      final args = call.arguments as Map;
      switch (call.method) {
        case 'scanLocalFolder':
          return {'complete': true, 'entries': entries};
        case 'pdfPageCount':
          return 3;
        case 'clearPdfCache':
          return true;
        case 'renameLocalDocument':
          final uri = args['docUri'] as String;
          final name = args['newFileName'] as String;
          renameCalls.add((uri, name));
          if (name == deniedName) {
            throw PlatformException(code: 'permission', message: '没有写权限');
          }
          final entry = entries.singleWhere((entry) => entry['uri'] == uri);
          entry['uri'] = '$tree/document/renamed-${nextUri++}';
          entry['name'] = name;
          return {'renamed': true, 'fileUri': entry['uri'], 'fileName': name};
        case 'deleteLocalDocument':
          if (denyDelete) return {'deleted': false, 'code': 'permission'};
          entries.removeWhere((entry) => entry['uri'] == args['docUri']);
          return {'deleted': true, 'outcome': 'deleted'};
      }
      throw MissingPluginException();
    });
  });

  tearDown(() async {
    for (final store in stores) {
      store.dispose();
    }
    stores.clear();
    messenger.setMockMethodCallHandler(LocalPlatform.channel, null);
    PathProviderPlatform.instance = previousPaths;
    debugDefaultTargetPlatformOverride = null;
    await root.delete(recursive: true);
  });

  test(
    'imports filename tags/definitions and retains ordinary download markers',
    () async {
      final file = await source('《仙绿》星河渐晓 #网站【精校】(完结) ✦古风 ✦已读.txt');
      final bytes = await file.readAsBytes();
      final store = await load();
      expect((await store.scanAppFolder()).failures, isEmpty);
      final book = store.books.single;
      expect(book.displayTitle, '《仙绿》星河渐晓 #网站【精校】(完结)');
      expect(
        (await store.detail(store.toNovel(book))).title,
        book.displayTitle,
      );
      expect(TagStore.shared.tagNamesForBook(book.id), ['古风', '已读']);
      expect(TagStore.shared.tags.map((tag) => tag.name), ['古风', '已读']);
      expect(await file.readAsBytes(), bytes);
      expect((await store.scanAppFolder()).added, 0);
      expect(store.books.single.id, book.id);
    },
  );

  test('new tags reject whitespace and marker at the store boundary', () async {
    for (final name in [
      '',
      '古 风',
      ' 古风',
      '古风 ',
      '古\u3000风',
      '古\u0085风',
      '古✦风',
    ]) {
      await expectLater(TagStore.shared.createTag(name), throwsArgumentError);
    }
    expect(TagStore.shared.tags, isEmpty);
  });

  test(
    'tag add/change/remove directly renames source and preserves bytes/ID',
    () async {
      final file = await source('书 #下载【精校】(全本).TXT');
      final bytes = await file.readAsBytes();
      final store = await load();
      await store.scanAppFolder();
      final before = store.books.single;
      final old = await TagStore.shared.createTag('古风');
      final next = await TagStore.shared.createTag('已读');
      var book = await store.setTagsForBook(before.id, [old, next, old]);
      expect(book.fileName, '书 #下载【精校】(全本) ✦古风 ✦已读.TXT');
      expect(await file.exists(), isFalse);
      expect(await File(book.sourceKey).readAsBytes(), bytes);
      expect(book.id, before.id);
      expect(book.revision, before.revision);
      book = await store.setTagsForBook(book.id, [next]);
      expect(book.fileName, '书 #下载【精校】(全本) ✦已读.TXT');
      book = await store.setTagsForBook(book.id, []);
      expect(book.fileName, '书 #下载【精校】(全本).TXT');
      expect(TagStore.shared.tagsForBook(book.id), isEmpty);
      await store.scanAppFolder();
      expect(TagStore.shared.tagsForBook(book.id), isEmpty);
      expect(await File(book.sourceKey).readAsBytes(), bytes);
    },
  );

  test('cleared tags cannot return from a stale folder-switch stash', () async {
    await source('书 ✦古风 ✦已读.txt');
    final store = await load();
    await store.scanAppFolder();
    final book = store.books.single;
    final ids = TagStore.shared
        .tagsForBook(book.id)
        .map((tag) => tag.id)
        .toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'local_library_tag_stash',
      jsonEncode({
        jsonEncode([book.sourceId, '书.txt']): ids,
        jsonEncode([book.sourceId, '书 ✦已读.txt']): ids,
      }),
    );
    await store.setTagsForBook(book.id, [ids.last]);
    await store.scanAppFolder();
    expect(store.books.single.fileName, '书 ✦已读.txt');
    expect(TagStore.shared.tagNamesForBook(book.id), ['已读']);
    expect(jsonDecode(prefs.getString('local_library_tag_stash')!), isEmpty);
    await store.setTagsForBook(book.id, []);
    await store.scanAppFolder();
    expect(store.books.single.fileName, '书.txt');
    expect(TagStore.shared.tagsForBook(book.id), isEmpty);
  });

  test(
    'failed rename retains old filename, tags and colliding file bytes',
    () async {
      await source('书 ✦古风.txt');
      final store = await load();
      await store.scanAppFolder();
      final book = store.books.single;
      final tag = await TagStore.shared.createTag('已读');
      final conflict = await source('书 ✦已读.txt');
      final bytes = await conflict.readAsBytes();
      await expectLater(store.setTagsForBook(book.id, [tag]), throwsStateError);
      expect(store.bookFor(book.id)!.fileName, book.fileName);
      expect(TagStore.shared.tagNamesForBook(book.id), ['古风']);
      expect(await File(book.sourceKey).exists(), isTrue);
      expect(await conflict.readAsBytes(), bytes);
    },
  );

  test(
    'prefs failure rolls filename and tags back and survives reload',
    () async {
      await source('书 ✦古风.txt');
      final store = await load();
      await store.scanAppFolder();
      final book = store.books.single;
      final tag = await TagStore.shared.createTag('已读');
      storage.failOnce = 'flutter.book_tag_map';
      await expectLater(store.setTagsForBook(book.id, [tag]), throwsStateError);
      expect(store.bookFor(book.id)!.fileName, book.fileName);
      expect(await File(book.sourceKey).exists(), isTrue);
      await TagStore.load();
      expect(TagStore.shared.tagNamesForBook(book.id), ['古风']);
      expect((await load()).bookFor(book.id)!.fileName, book.fileName);
    },
  );

  test('index write failure rolls back source without changing tags', () async {
    await source('书.txt');
    final store = await load();
    await store.scanAppFolder();
    final book = store.books.single;
    final tag = await TagStore.shared.createTag('已读');
    final blocker = await Directory(
      '${root.path}/local_books/index.json.tmp',
    ).create();
    await expectLater(store.setTagsForBook(book.id, [tag]), throwsA(anything));
    expect(await File(book.sourceKey).exists(), isTrue);
    expect(store.bookFor(book.id)!.fileName, book.fileName);
    expect(TagStore.shared.tagsForBook(book.id), isEmpty);
    await blocker.delete();
    await store.scanAppFolder();
    expect(store.books.single.fileName, '书.txt');
  });

  test(
    'scan migration merges old tags and reports one failure without stopping batch',
    () async {
      await source('甲 ✦文件标签.txt');
      await source('乙.txt');
      await source('丙.txt');
      final store = await load();
      await store.scanAppFolder();
      final tag = await TagStore.shared.createTag('内部标签');
      for (final book in store.books) {
        await TagStore.shared.setTagsForBook(book.id, [tag]);
      }
      final blocker = await Directory(
        '${root.path}/novels/乙 ✦内部标签.txt',
      ).create();
      final scan = await store.scanAppFolder();
      expect(scan.failures, hasLength(1));
      expect(scan.failures.keys.single, contains('乙'));
      expect(
        store.books.singleWhere((b) => b.title == '甲').fileName,
        '甲 ✦文件标签 ✦内部标签.txt',
      );
      expect(
        store.books.singleWhere((b) => b.title == '丙').fileName,
        '丙 ✦内部标签.txt',
      );
      expect(store.books.singleWhere((b) => b.title == '乙').fileName, '乙.txt');
      expect(
        TagStore.shared.tagNamesForBook(
          store.books.singleWhere((b) => b.title == '甲').id,
        ),
        unorderedEquals(['内部标签', '文件标签']),
      );
      await blocker.delete();
      expect((await store.scanAppFolder()).failures, isEmpty);
      expect(
        store.books.singleWhere((b) => b.title == '乙').fileName,
        '乙 ✦内部标签.txt',
      );
      final unchanged = await store.scanAppFolder();
      expect(unchanged.added, 0);
      expect(unchanged.removed, 0);
    },
  );

  test(
    'load migrates old internal tags and imports suffix definitions without scan',
    () async {
      await source('书.txt');
      final store = await load();
      await store.scanAppFolder();
      final id = store.books.single.id;
      final tag = await TagStore.shared.createTag('已读');
      await TagStore.shared.setTagsForBook(id, [tag]);
      final reloaded = await load();
      expect(reloaded.bookFor(id)!.fileName, '书 ✦已读.txt');
      expect(reloaded.tagMigrationFailures, isEmpty);
      await TagStore.shared.setTagsForBook(id, []);
      await load();
      expect(TagStore.shared.tagNamesForBook(id), ['已读']);
    },
  );

  test(
    'legacy invalid tags are retained and reported; other books still migrate',
    () async {
      await source('甲.txt');
      await source('乙.txt');
      final store = await load();
      await store.scanAppFolder();
      final books = store.books;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'book_tags',
        jsonEncode([
          {'id': 'bad', 'name': '旧 标签', 'color': 0},
          {'id': 'ok', 'name': '古风', 'color': 1},
        ]),
      );
      await prefs.setString(
        'book_tag_map',
        jsonEncode({
          '${books[0].id}': ['bad'],
          '${books[1].id}': ['ok'],
        }),
      );
      await TagStore.load();
      final reload = await load();
      expect(reload.tagMigrationFailures, hasLength(1));
      expect(reload.bookFor(books[0].id)!.fileName, books[0].fileName);
      expect(TagStore.shared.tagNamesForBook(books[0].id), ['旧 标签']);
      expect(reload.bookFor(books[1].id)!.fileName, contains(' ✦古风.txt'));
    },
  );

  test(
    'explicit deletion clears internal and stashed tags before same-name new import',
    () async {
      await source('书 ✦已读.txt');
      final store = await load();
      await store.scanAppFolder();
      final book = store.books.single;
      final tag = TagStore.shared.tagsForBook(book.id).single.id;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'local_library_tag_stash',
        jsonEncode({
          jsonEncode([book.sourceId, '书.txt']): [tag],
          jsonEncode([book.sourceId, book.fileName]): [tag],
        }),
      );
      await store.deleteBookFile(book.id);
      expect(TagStore.shared.tagsForBook(book.id), isEmpty);
      expect(jsonDecode(prefs.getString('local_library_tag_stash')!), isEmpty);
      await source('书.txt');
      await store.scanAppFolder();
      expect(store.books.single.id, isNot(book.id));
      expect(TagStore.shared.tagsForBook(store.books.single.id), isEmpty);
      expect(store.books.single.fileName, '书.txt');
    },
  );

  test(
    'record-only removal preserves source, clears tags and stays ignored',
    () async {
      await source('书 ✦已读.txt');
      final store = await load();
      await store.scanAppFolder();
      final book = store.books.single;
      await store.removeBookRecordOnly(book.id);
      expect(await File(book.sourceKey).exists(), isTrue);
      expect(TagStore.shared.tagsForBook(book.id), isEmpty);
      await store.scanAppFolder();
      expect(store.books, isEmpty);
      expect(TagStore.shared.tagsForBook(book.id), isEmpty);
    },
  );

  test(
    'tag management renames/deletes suffixes and keeps definitions after failure',
    () async {
      await source('甲 ✦旧.txt');
      await source('乙 ✦旧.txt');
      final store = await load();
      await store.scanAppFolder();
      final original = store.books;
      final id = TagStore.shared.tags.single.id;
      final last = original.last;
      final blocker = await Directory(
        '${root.path}/novels/${last.title} ✦新.txt',
      ).create();
      await expectLater(store.renameTag(id, '新'), throwsA(anything));
      expect(TagStore.shared.tagById(id)!.name, '旧');
      for (final book in original) {
        expect(await File(book.sourceKey).exists(), isTrue);
      }
      await blocker.delete();
      await store.renameTag(id, '新');
      expect(store.books.every((b) => b.fileName.endsWith(' ✦新.txt')), isTrue);
      storage.failOnce = 'flutter.book_tag_map';
      await expectLater(store.deleteTag(id), throwsStateError);
      expect(TagStore.shared.tagById(id)!.name, '新');
      expect(store.books.every((b) => b.fileName.endsWith(' ✦新.txt')), isTrue);
      await store.deleteTag(id);
      await store.scanAppFolder();
      expect(TagStore.shared.tags, isEmpty);
      expect(store.books.every((b) => b.fileName == '${b.title}.txt'), isTrue);
    },
  );

  test('title edits retain suffix, custom author and content', () async {
    await source('书 ✦古风.txt');
    final store = await load();
    await store.scanAppFolder();
    var book = store.books.single;
    book = await store.editBookFile(book.id, title: '新书', author: '作者');
    expect(book.fileName, '新书 ✦古风.txt');
    final tag = await TagStore.shared.createTag('已读');
    book = await store.setTagsForBook(book.id, [tag]);
    expect(book.displayTitle, '新书');
    expect(book.displayAuthor, '作者');
    expect(book.fileName, '新书 ✦已读.txt');
  });

  // Both per-book selection and tag-definition management must replace the
  // suffix, remove just one segment, then restore the original filename.
  for (final saf in [false, true]) {
    for (final definitions in [false, true]) {
      test(
        '${saf ? 'SAF' : 'app folder'} ${definitions ? 'definitions' : 'selection'} '
        'replace tag, delete one, clear all leave no stale suffix after reload',
        () async {
          final extension = saf ? '.pdf' : '.TXT';
          final baseName = '书 #下载【精校】(全本)$extension';
          final initialName = '书 #下载【精校】(全本) ✦古风 ✦已读$extension';
          List<int>? bytes;
          if (saf) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('local_library_folder', tree);
            entries.add({
              'uri': '$tree/document/matrix',
              'name': initialName,
              'size': 50,
              'modified': 1,
            });
          } else {
            bytes = await (await source(initialName)).readAsBytes();
          }
          var store = await load();
          Future<void> scan() async {
            final result = saf
                ? await store.scan()
                : await store.scanAppFolder();
            expect(result.failures, isEmpty);
          }

          await scan();
          final id = store.books.single.id;
          final oldId = TagStore.shared.tags
              .singleWhere((t) => t.name == '古风')
              .id;
          final keepId = TagStore.shared.tags
              .singleWhere((t) => t.name == '已读')
              .id;
          final newId = definitions
              ? oldId
              : await TagStore.shared.createTag('现代');
          Future<void> check(String filename, List<String> names) async {
            expect(store.books.single.fileName, filename);
            expect(store.books.single.id, id);
            expect(store.books.single.displayTitle, '书 #下载【精校】(全本)');
            expect(TagStore.shared.tagNamesForBook(id), names);
            if (saf) {
              expect(entries.single['name'], filename);
              expect(entries.single['uri'], store.books.single.fileUri);
            } else {
              final sourceFiles = await Directory(
                '${root.path}/novels',
              ).list().toList();
              expect(sourceFiles.map((f) => f.path.split('/').last), [
                filename,
              ]);
              expect(
                await File(store.books.single.sourceKey).readAsBytes(),
                bytes,
              );
            }
            await scan();
            await TagStore.load();
            store = await load();
            expect(store.books.single.fileName, filename);
            expect(store.books.single.id, id);
            expect(TagStore.shared.tagNamesForBook(id), names);
          }

          if (definitions) {
            await store.renameTag(oldId, '现代');
          } else {
            await store.setTagsForBook(id, [newId, keepId]);
          }
          await check('书 #下载【精校】(全本) ✦现代 ✦已读$extension', ['现代', '已读']);
          if (definitions) {
            await store.deleteTag(newId);
          } else {
            await store.setTagsForBook(id, [keepId]);
          }
          await check('书 #下载【精校】(全本) ✦已读$extension', ['已读']);
          if (definitions) {
            await store.deleteTag(keepId);
          } else {
            await store.setTagsForBook(id, []);
          }
          await check(baseName, []);
        },
      );
    }
  }

  group('SAF', () {
    setUp(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('local_library_folder', tree);
      entries.add({
        'uri': '$tree/document/1',
        'name': '书 #【】() ✦古风.pdf',
        'size': 50,
        'modified': 1,
      });
    });

    test(
      'import, rename with changed URI, rescan and reload preserve ID/tags',
      () async {
        final store = await load();
        await store.scan();
        final book = store.books.single;
        final tag = await TagStore.shared.createTag('已读');
        final updated = await store.setTagsForBook(book.id, [tag]);
        expect(updated.fileName, '书 #【】() ✦已读.pdf');
        expect(updated.fileUri, isNot(book.fileUri));
        expect(updated.sourceKey, updated.fileUri);
        final scan = await store.scan();
        expect(scan.added, 0);
        expect(scan.removed, 0);
        final loaded = await load();
        expect(loaded.books.single.id, book.id);
        expect(loaded.books.single.fileUri, updated.fileUri);
      },
    );

    test(
      'permission failure retains old tags/name; delete failure also retains tags',
      () async {
        final store = await load();
        await store.scan();
        final book = store.books.single;
        final tag = await TagStore.shared.createTag('已读');
        deniedName = '书 #【】() ✦已读.pdf';
        await expectLater(
          store.setTagsForBook(book.id, [tag]),
          throwsA(isA<LocalRenameException>()),
        );
        expect(store.bookFor(book.id)!.fileName, book.fileName);
        expect(TagStore.shared.tagNamesForBook(book.id), ['古风']);
        denyDelete = true;
        await expectLater(
          store.deleteBookFile(book.id),
          throwsA(isA<LocalDeleteException>()),
        );
        expect(TagStore.shared.tagNamesForBook(book.id), ['古风']);
      },
    );

    test(
      'unchanged PDF fast path imports changed filename tags and merges internal tags',
      () async {
        final store = await load();
        await store.scan();
        final id = store.books.single.id;
        entries.single['name'] = '书 #【】() ✦已读.pdf';
        expect((await store.scan()).failures, isEmpty);
        expect(store.books.single.id, id);
        expect(store.books.single.displayTitle, '书 #【】()');
        expect(
          TagStore.shared.tagNamesForBook(id),
          unorderedEquals(['古风', '已读']),
        );
        expect(store.books.single.fileName, '书 #【】() ✦已读 ✦古风.pdf');
        expect((await store.scan()).removed, 0);
      },
    );

    test('null/unconfirmed/wrong name replies are explicit failures', () async {
      for (final result in [
        null,
        {'fileUri': '$tree/document/1', 'fileName': '新.pdf'},
        {'renamed': true, 'fileUri': '$tree/document/1', 'fileName': '调整.pdf'},
      ]) {
        messenger.setMockMethodCallHandler(
          LocalPlatform.channel,
          (_) async => result,
        );
        await expectLater(
          LocalPlatform.renameLocalDocument('$tree/document/1', '新.pdf'),
          throwsA(isA<LocalRenameException>()),
        );
      }
    });
  });
}
