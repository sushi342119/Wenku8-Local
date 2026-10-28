import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/local_library.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/novel_feed_controller.dart';

const _queueKey = 'local_library_pending_chapter_remaps_v1';
const _tree = 'content://test/tree/books';
const _body = '开场文字\n第一章 起点\n甲😀乙。\n第二章 终点\n丙丁。\n';

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();
  final writes = <String>[];
  String? failOnce;
  void Function(String)? beforeWrite;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes.add(key);
    beforeWrite?.call(key);
    if (key == failOnce) {
      failOnce = null;
      return false;
    }
    return super.setValue(type, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    writes.add(key);
    if (key == failOnce) {
      failOnce = null;
      return false;
    }
    return super.remove(key);
  }
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getExternalStoragePath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  late _Preferences storage;
  late SharedPreferences prefs;
  final entries = <Map<String, Object?>>[];
  final bodies = <String, String>{};
  final stores = <LocalLibraryStore>[];
  var prepares = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local-performance-');
    storage = _Preferences();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = storage;
    prefs = await SharedPreferences.getInstance();
    await prefs.setString('local_library_folder', _tree);
    entries.clear();
    bodies.clear();
    prepares = 0;
    messenger.setMockMethodCallHandler(paths, (call) async => root.path);
    messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
      if (call.method == 'scanLocalFolder') {
        return {'complete': true, 'entries': entries};
      }
      if (call.method == 'prepareLocalText') {
        prepares++;
        final uri = (call.arguments as Map)['docUri'];
        final text = bodies[uri];
        if (text == null) throw PlatformException(code: 'unreadable');
        final file = File('${root.path}/prepared-$prepares.txt');
        await file.writeAsString(text);
        return file.path;
      }
      throw MissingPluginException();
    });
  });

  tearDown(() async {
    for (final store in stores) {
      store.dispose();
    }
    stores.clear();
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(LocalPlatform.channel, null);
    await root.delete(recursive: true);
  });

  Future<LocalLibraryStore> load() async {
    final store = await LocalLibraryStore.load();
    stores.add(store);
    return store;
  }

  void source(int i, {String text = _body, int modified = 1}) {
    final uri = '$_tree/document/$i';
    entries.add({
      'uri': uri,
      'name': '$i.txt',
      'size': 1000,
      'modified': modified,
    });
    bodies[uri] = text;
  }

  Future<void> seed(int count, {int version = 0, bool words = false}) async {
    final books = <LocalBook>[];
    final directory = Directory('${root.path}/local_books');
    await directory.create();
    for (var i = 0; i < count; i++) {
      source(i);
      final id = localNovelIdBase + i;
      books.add(
        LocalBook(
          id: id,
          title: '$i',
          author: '',
          fileUri: '$_tree/document/$i',
          fileName: '$i.txt',
          kind: LocalBookKind.txt,
          size: 1000,
          modified: 1,
          chapters: version == 0
              ? [LocalChapterIndex('正文', 0, _body.length)]
              : LocalLibraryStore.splitChaptersForTest(_body),
          pageCount: 0,
          wordCount: words ? 20 : null,
          chapterSplitVersion: version,
          sourceId: 'saf:$_tree',
          sourceKey: '$_tree/document/$i',
        ),
      );
      await File('${directory.path}/book_$id.txt').writeAsString(_body);
    }
    await File('${directory.path}/index.json').writeAsString(
      jsonEncode({'books': books.map((book) => book.toJson()).toList()}),
    );
  }

  test(
    'direct imports stream UTF-8 and failed decoding preserves the old book',
    () async {
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPaths(root.path);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() {
        PathProviderPlatform.instance = oldPaths;
        debugDefaultTargetPlatformOverride = null;
      });
      final directory = await Directory('${root.path}/novels').create();
      final file = File('${directory.path}/direct.txt');
      await file.writeAsString('\uFEFF第一章 甲\r\n正文甲\r第二章 乙\r\n正文乙');
      final store = await load();
      expect((await store.scanAppFolder()).added, 1);
      final book = store.books.single;
      expect(book.chapters, hasLength(2));
      expect(book.wordCount, 14);
      expect(book.chapterSplitVersion, 2);
      final text = await store.chapterContent(
        book.id,
        (await store.chapters(book.id)).first,
      );
      expect(text, '正文甲');
      await file.writeAsBytes([0xff, 0xfe, 0xff]);
      expect((await store.scanAppFolder()).skipped, 1);
      expect(store.books.single, same(book));
      await file.delete();
      expect((await store.scanAppFolder()).removed, 1);
      expect(store.bookFor(book.id), isNull);
    },
  );

  test(
    'batched removals and refreshed book order keep the ID index in sync',
    () async {
      await seed(6, version: 2, words: true);
      final store = await load();
      entries.removeWhere(
        (entry) =>
            entry['uri'] == '$_tree/document/1' ||
            entry['uri'] == '$_tree/document/4',
      );
      entries.first['modified'] = 2;
      await store.scan();
      expect(
        store.books.map((b) => b.id),
        [2, 3, 5, 0].map((i) => localNovelIdBase + i),
      );
      for (final book in store.books) {
        expect(store.bookFor(book.id), same(book));
      }
      expect(store.bookFor(localNovelIdBase + 1), isNull);
      expect(store.bookFor(localNovelIdBase + 4), isNull);
    },
  );

  test(
    'SAF import counts words, reserves IDs once, then skips unchanged index writes',
    () async {
      for (var i = 0; i < 24; i++) {
        source(i);
      }
      await prefs.setInt('local_library_next', 50);
      final store = await load();
      storage.writes.clear();
      final result = await store.scan();
      expect(result.added, 24);
      expect(store.books.first.id, localNovelIdBase + 50);
      expect(
        store.books.every(
          (b) => b.wordCount != null && b.chapterSplitVersion == 2,
        ),
        isTrue,
      );
      expect(
        storage.writes.where((key) => key == 'flutter.local_library_next'),
        hasLength(1),
      );
      final index = File('${root.path}/local_books/index.json');
      final stamp = DateTime.utc(2000);
      await index.setLastModified(stamp);
      storage.writes.clear();
      final second = await store.scan();
      expect(second.backfilled, 0);
      expect(second.refreshed, 0);
      expect(prepares, 24);
      expect((await index.lastModified()).toUtc(), stamp);
      expect(storage.writes, isEmpty);
      expect(
        (await store.browse(page: 2)).items.map((b) => b.id),
        store.books.skip(20).map((b) => b.id),
      );
      expect((await store.browse(page: 9)).items, isEmpty);
      await expectLater(store.browse(page: 0), throwsArgumentError);
    },
  );

  test(
    'one journal write precedes all candidate tables; confirmation is one write',
    () async {
      await seed(12);
      final store = await load();
      storage.writes.clear();
      storage.beforeWrite = (key) {
        if (key == 'flutter.$_queueKey') {
          expect(
            store.books.every((book) => book.chapters.length == 1),
            isTrue,
          );
        }
      };
      final result = await store.scan();
      storage.beforeWrite = null;
      expect(result.chapterRemaps, hasLength(12));
      expect(result.backfilled, 12);
      expect(
        storage.writes.where((key) => key == 'flutter.$_queueKey'),
        hasLength(1),
      );
      expect(store.books.every((book) => book.chapters.length == 2), isTrue);
      storage.writes.clear();
      await store.commitChapterRemapResults(
        confirmed: result.chapterRemaps.map(
          (r) => (bookId: r.bookId, migrationId: r.migrationId),
        ),
        failures: const [],
      );
      expect(storage.writes, ['flutter.$_queueKey']);
      expect(store.pendingChapterRemaps, isEmpty);
    },
  );

  test(
    'failed journal leaves old chapter tables and retry stages all migrations',
    () async {
      await seed(3);
      final store = await load();
      storage.failOnce = 'flutter.$_queueKey';
      await expectLater(store.scan(), throwsStateError);
      expect(
        store.books.every(
          (b) => b.chapterSplitVersion == 0 && b.chapters.length == 1,
        ),
        isTrue,
      );
      expect(prefs.getString(_queueKey), isNull);
      final retry = await store.scan();
      expect(retry.chapterRemaps, hasLength(3));
      expect(store.books.every((b) => b.chapterSplitVersion == 2), isTrue);
    },
  );

  test(
    'index failure retains dirty state and hides journal until save succeeds',
    () async {
      await seed(2);
      final store = await load();
      final blocker = Directory('${root.path}/local_books/index.json.tmp');
      await blocker.create();
      await expectLater(store.scan(), throwsA(isA<FileSystemException>()));
      expect(store.pendingChapterRemaps, isEmpty);
      expect(prefs.getString(_queueKey), isNotNull);
      await blocker.delete();
      final retry = await store.scan();
      expect(retry.chapterRemaps, hasLength(2));
      final reloaded = await load();
      expect(reloaded.pendingChapterRemaps, hasLength(2));
    },
  );

  test(
    'a failed book does not make successful books read or split again',
    () async {
      await seed(2);
      await File(
        '${root.path}/local_books/book_${localNovelIdBase + 1}.txt',
      ).delete();
      bodies.remove('$_tree/document/1');
      final store = await load();
      final result = await store.scan();
      expect(result.backfilled, 1);
      expect(store.bookFor(localNovelIdBase)!.chapterSplitVersion, 2);
      expect(store.bookFor(localNovelIdBase + 1)!.chapterSplitVersion, 0);
      // If the already successful book is read again, it now fails too.
      await File(
        '${root.path}/local_books/book_$localNovelIdBase.txt',
      ).delete();
      bodies.remove('$_tree/document/0');
      prepares = 0;
      await store.scan();
      expect(prepares, 1);
      expect(store.bookFor(localNovelIdBase)!.chapterSplitVersion, 2);
    },
  );

  test(
    'shared chapter reads reuse body and refresh/removal invalidates it',
    () async {
      source(0);
      final store = await load();
      await store.scan();
      final id = store.books.single.id;
      final chapters = await store.chapters(id);
      final textFile = File('${root.path}/local_books/book_$id.txt');
      await textFile.delete();
      final texts = await Future.wait(
        List.generate(10, (_) => store.chapterContent(id, chapters.first)),
      );
      expect(texts.toSet(), {'甲😀乙。'});
      expect(prepares, 2);
      await textFile.delete();
      expect(await store.chapterContent(id, chapters.last), '丙丁。');
      expect(prepares, 2);
      entries.single['modified'] = 2;
      bodies['$_tree/document/0'] = _body.replaceAll('甲😀乙。', '新的正文。');
      await store.scan();
      expect(await store.chapterContent(id, chapters.first), '新的正文。');
      await store.removeBook(id);
      expect(store.bookFor(id), isNull);
      expect(await store.chapterContent(id, chapters.first), '');
    },
  );

  test(
    'recovered BOM preserves first-return and subsequent file-read semantics',
    () async {
      source(0);
      final store = await load();
      await store.scan();
      final book = store.books.single;
      final chapter = (await store.chapters(book.id)).first;
      final body = '\uFEFF$_body';
      bodies[book.fileUri] = body;
      await File('${root.path}/local_books/book_${book.id}.txt').delete();
      final range = book.chapters.first;
      expect(
        await store.chapterContent(book.id, chapter),
        body.substring(range.offset, range.offset + range.length).trim(),
      );
      expect(await store.chapterContent(book.id, chapter), '甲😀乙。');
    },
  );

  test(
    'combined backfill and split preserve the old restored-copy BOM view',
    () async {
      await seed(1);
      bodies['$_tree/document/0'] = '\uFEFF$_body';
      await File(
        '${root.path}/local_books/book_$localNovelIdBase.txt',
      ).delete();
      final store = await load();
      final result = await store.scan();
      expect(result.backfilled, 1);
      expect(prepares, 1);
      expect(
        store.books.single.chapters.map((c) => c.toJson()),
        LocalLibraryStore.splitChaptersForTest(_body).map((c) => c.toJson()),
      );
      expect(
        store.books.single.wordCount,
        _body.runes
                .where(
                  (r) => !RegExp(
                    r'\s',
                    unicode: true,
                  ).hasMatch(String.fromCharCode(r)),
                )
                .length +
            1,
      );
    },
  );

  test(
    'streamed normalization and splitting keep offsets on large lines and unicode',
    () async {
      final raw = '\uFEFF${'x' * 65534}\r\n第一章 起点\r\n甲😀乙\r第二章 终点\n丙丁\n';
      source(0, text: raw);
      final store = await load();
      await store.scan();
      final book = store.books.single;
      final normalized = raw
          .substring(1)
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n');
      expect(
        await File(
          '${root.path}/local_books/book_${book.id}.txt',
        ).readAsString(),
        normalized,
      );
      expect(
        book.chapters.map((c) => c.toJson()),
        LocalLibraryStore.splitChaptersForTest(
          normalized,
        ).map((c) => c.toJson()),
      );
      expect(
        book.wordCount,
        normalized.runes
            .where(
              (r) => !RegExp(
                r'\s',
                unicode: true,
              ).hasMatch(String.fromCharCode(r)),
            )
            .length,
      );
    },
  );

  test(
    'unusual line separators and BOM handling retain legacy chapter semantics',
    () async {
      final texts = [
        '\uFEFF\uFEFF第一章 甲\n正文\n第二章 乙\n正文',
        '\uFEFF',
        '第一章 甲\u2028第二章 乙\n正文\n第三章 丙\n末尾',
        '${'长行' * 300}\u2029第一章 甲\n正文\n第二章 乙\n末尾',
        '第一章 甲\r第二章 乙\r正文',
        '第一章 甲\n${'x' * 100000}\n第二章 乙\n',
      ];
      for (var i = 0; i < texts.length; i++) {
        source(i, text: texts[i]);
      }
      final store = await load();
      await store.scan();
      expect(store.books, hasLength(texts.length));
      for (var i = 0; i < texts.length; i++) {
        var normalized = texts[i];
        if (normalized.startsWith('\uFEFF')) {
          normalized = normalized.substring(1);
        }
        normalized = normalized.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
        expect(
          store.books[i].chapters.map((c) => c.toJson()),
          LocalLibraryStore.splitChaptersForTest(
            normalized,
          ).map((c) => c.toJson()),
          reason: 'case $i',
        );
      }
    },
  );

  test(
    'batch confirmation rejects a skipped predecessor and preserves composite IDs',
    () async {
      await seed(1);
      final store = await load();
      final a = LocalChapterRemap(
        migrationId: 'a',
        bookId: localNovelIdBase,
        oldChapters: const [(offset: 0, length: 20)],
        newChapters: const [(offset: 0, length: 10)],
      );
      final b = LocalChapterRemap(
        migrationId: 'b',
        bookId: localNovelIdBase,
        oldChapters: a.newChapters,
        newChapters: const [(offset: 0, length: 5)],
      );
      final other = LocalChapterRemap(
        migrationId: 'a',
        bookId: localNovelIdBase + 1,
        oldChapters: a.oldChapters,
        newChapters: a.newChapters,
      );
      await prefs.setString(
        _queueKey,
        jsonEncode([a.toJson(), b.toJson(), other.toJson()]),
      );
      await expectLater(
        store.confirmChapterRemap('b', bookId: localNovelIdBase),
        throwsStateError,
      );
      await store.commitChapterRemapResults(
        confirmed: [
          (bookId: a.bookId, migrationId: a.migrationId),
          (bookId: b.bookId, migrationId: b.migrationId),
        ],
        failures: [(remap: other, error: StateError('retry'))],
      );
      final remaining = jsonDecode(prefs.getString(_queueKey)!) as List;
      expect(remaining, hasLength(1));
      expect(remaining.single['bookId'], other.bookId);
      expect(remaining.single['attempts'], 1);
    },
  );

  test(
    'batch shelf updates publish once and preserve existing progress and metadata',
    () async {
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await state.setChapter(1, 8);
      var notifications = 0;
      state.addListener(() => notifications++);
      storage.writes.clear();
      await state.addShelfBooks(demoNovels);
      expect(notifications, 1);
      expect(state.chapterFor(1), 8);
      expect(state.cachedNovel(1)!.title, demoNovels.first.title);
      expect(
        storage.writes.where((k) => k == 'flutter.$restoreJournalKey'),
        hasLength(2),
      );
      expect(storage.writes.where((k) => k == 'flutter.shelf'), hasLength(1));
      storage.writes.clear();
      await state.addShelfBooks(demoNovels);
      expect(notifications, 1);
      expect(storage.writes, isEmpty);
    },
  );

  test(
    'native shelf batch submits metadata once and reloads the prefs cache',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var batches = 0;
      messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
        expect(call.method, 'writeLibraryPreferences');
        batches++;
        final changes = (call.arguments as Map)['changes'] as Map;
        for (final entry in changes.entries) {
          final value = entry.value;
          final type = value is List
              ? 'StringList'
              : value is int
              ? 'Int'
              : 'String';
          await storage.setValue(
            type,
            'flutter.${entry.key}',
            value is List ? List<String>.from(value) : value,
          );
        }
        return true;
      });
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await state.addShelfBooks(demoNovels);
      expect(batches, 1);
      expect(
        prefs.getStringList('shelf'),
        demoNovels.map((n) => '${n.id}').toList(),
      );
      expect(prefs.getString('novel_meta_1'), isNotNull);
      expect(prefs.get(restoreJournalKey), isNull);
    },
  );

  test(
    'failed shelf batch rolls back and retry publishes all additions once',
    () async {
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      storage.failOnce = 'flutter.novel_meta_1';
      await expectLater(state.addShelfBooks(demoNovels), throwsStateError);
      expect(state.shelf, isEmpty);
      expect(prefs.getStringList('shelf'), isNull);
      await state.addShelfBooks(demoNovels);
      expect(state.shelf, demoNovels.map((n) => n.id).toSet());
      expect(state.cachedNovel(1), isNotNull);
    },
  );

  test('local loadAll uses one list conversion batch', () async {
    for (var i = 0; i < 44; i++) {
      source(i);
    }
    final store = await load();
    await store.scan();
    var lists = 0;
    final feed = NovelFeedController(
      store,
      loadAll: true,
      loadAllItems: () {
        lists++;
        return store.list();
      },
    );
    addTearDown(feed.dispose);
    await feed.loadInitial();
    expect(lists, 1);
    expect(feed.items.length, 44);
    expect(feed.hasMore, isFalse);
    await feed.refresh();
    expect(lists, 2);
    expect(feed.items.map((n) => n.id), store.books.map((b) => b.id));
  });
}
