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
import 'package:wenku8_flutter/chapter_splitter.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/local_library.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/novel_feed_controller.dart';
import 'package:wenku8_flutter/listening/models.dart';
import 'package:wenku8_flutter/listening/controller.dart';
import 'support/listening_fixture.dart';
import 'package:wenku8_flutter/listening/store.dart';

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
      expect(book.chapterSplitVersion, 3);
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
        [0, 2, 3, 5].map((i) => localNovelIdBase + i),
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
          (b) => b.wordCount != null && b.chapterSplitVersion == 3,
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
      expect(prepares, 48);
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
      expect(store.books.every((book) => book.chapters.length == 3), isTrue);
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
      expect(store.books.every((b) => b.chapterSplitVersion == 3), isTrue);
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
      expect(store.bookFor(localNovelIdBase)!.chapterSplitVersion, 3);
      expect(store.bookFor(localNovelIdBase + 1)!.chapterSplitVersion, 0);
      // If the already successful book is read again, it now fails too.
      await File(
        '${root.path}/local_books/book_$localNovelIdBase.txt',
      ).delete();
      bodies.remove('$_tree/document/0');
      prepares = 0;
      await store.scan();
      expect(prepares, 2);
      expect(store.bookFor(localNovelIdBase)!.chapterSplitVersion, 3);
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
      final textFile = File(store.textPathFor(store.books.single));
      await textFile.delete();
      final texts = await Future.wait(
        List.generate(10, (_) => store.chapterContent(id, chapters[1])),
      );
      expect(texts.toSet(), {'甲😀乙。'});
      expect(prepares, 2);
      await textFile.delete();
      expect(await store.chapterContent(id, chapters.last), '丙丁。');
      expect(prepares, 2);
      entries.single['modified'] = 2;
      bodies['$_tree/document/0'] = _body.replaceAll('甲😀乙。', '新的正文。');
      await store.scan();
      await expectLater(
        store.chapterContent(id, chapters[1]),
        throwsA(isA<StaleLocalChapterException>()),
      );
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      state.bindLocalChapters(store);
      final current = await store.chapters(id);
      expect(await store.chapterContent(id, current[1]), '新的正文。');
      await store.removeBook(id);
      expect(store.bookFor(id), isNull);
      expect(await store.chapterContent(id, chapters.first), '');
    },
  );

  test(
    'recovered BOM and CRLF use the same normalized coordinates on every read',
    () async {
      source(0);
      final store = await load();
      await store.scan();
      final book = store.books.single;
      final chapter = (await store.chapters(book.id))[1];
      final body = '\uFEFF${_body.replaceAll('\n', '\r\n')}';
      bodies[book.fileUri] = body;
      await File(store.textPathFor(book)).delete();
      final range = book.chapters[1];
      expect(
        await store.chapterContent(book.id, chapter),
        _body.substring(range.offset, range.offset + range.length).trim(),
      );
      expect(await store.chapterContent(book.id, chapter), '甲😀乙。');
    },
  );

  test('combined backfill and split normalize a restored BOM copy', () async {
    await seed(1);
    bodies['$_tree/document/0'] = '\uFEFF$_body';
    await File('${root.path}/local_books/book_$localNovelIdBase.txt').delete();
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
            (r) =>
                !RegExp(r'\s', unicode: true).hasMatch(String.fromCharCode(r)),
          )
          .length,
    );
  });

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
      expect(await File(store.textPathFor(book)).readAsString(), normalized);
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
    'unusual line separators and BOM handling share normalized coordinates',
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
        normalized = normalizeLocalText(texts[i]);
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
    'same-length same-mtime source overwrite publishes a new snapshot and rejects old identifiers',
    () async {
      source(0, text: '第一章 甲\n甲甲正文\n第二章 乙\n乙乙正文\n');
      final store = await load();
      await store.scan();
      final old = store.books.single;
      final chapters = await store.chapters(old.id);
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      state.bindLocalChapters(store);
      bodies[old.fileUri] = bodies[old.fileUri]!.replaceAll('甲甲正文', '丙丙正文');
      final result = await store.scan();
      expect(result.refreshed, 1);
      expect(result.chapterRemaps, hasLength(1));
      expect(store.books.single.textFingerprint, isNot(old.textFingerprint));
      expect(
        await File(store.textPathFor(old)).readAsString(),
        contains('甲甲正文'),
      );
      await expectLater(
        store.chapterContent(old.id, chapters.first),
        throwsA(isA<StaleLocalChapterException>()),
      );
      final current = await store.chapters(old.id);
      expect(await store.chapterContent(old.id, current.first), '丙丙正文');
      await expectLater(
        store.chapterContent(
          old.id,
          NovelChapter('bad', '', id: 999, revision: current.first.revision),
        ),
        throwsA(isA<StaleLocalChapterException>()),
      );
    },
  );

  test('uncommitted same-shape content revision never exposes a migration after restart', () async {
    source(0, text: '第一章 甲\n甲正文\n第二章 乙\n乙正文');
    final store = await load();
    await store.scan();
    final old = store.books.single;
    final chapters = await store.chapters(old.id);
    final blocker = Directory('${root.path}/local_books/index.json.tmp');
    await blocker.create();
    bodies[old.fileUri] = bodies[old.fileUri]!.replaceAll('甲正文', '丙正文');
    await expectLater(store.scan(), throwsA(isA<FileSystemException>()));
    expect(store.pendingChapterRemaps, isEmpty);
    final reloaded = await load();
    expect(reloaded.books.single.revision, old.revision);
    expect(reloaded.pendingChapterRemaps, isEmpty);
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    state.bindLocalChapters(reloaded);
    final restored = await reloaded.chapters(old.id);
    expect(await reloaded.chapterContent(old.id, restored.first), '甲正文');
    expect(restored.first.revision, chapters.first.revision);
    await blocker.delete();
    await reloaded.scan();
    final current = await reloaded.chapters(old.id);
    expect(await reloaded.chapterContent(old.id, current.first), '丙正文');
  });

  test(
    'reading, bookmarks and listening anchors survive inserts, deletes, process restart and failed migration writes',
    () async {
      const oldText = '第一章 开始\n甲头\n\n甲第二段目标。\n第二章 结束\n乙头\n\n乙目标段，游标和书签都在这里。\n';
      source(0, text: oldText);
      final store = await load();
      await store.scan();
      final id = store.books.single.id;
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      state.bindLocalChapters(store);
      final novel = store
          .toNovel(store.books.single)
          .withChapters(await store.chapters(id));
      final body = await store.chapterContent(id, novel.chapters[1]);
      final anchor = body.indexOf('乙目标');
      await state.savePosition(
        novel: novel,
        chapter: 1,
        offset: 1,
        maximum: 1000,
        width: 400,
        paragraphIndex: 1,
        textOffset: anchor,
      );
      await state.addBookmark(novel: novel, position: state.positionFor(id)!);
      await ListeningStore(prefs).saveCursor(
        ListeningCursor(
          novelId: id,
          chapterId: 1,
          chapter: 1,
          paragraph: 1,
          start: 2,
          positionMs: 900,
          segmentHash: 'old',
          revision: novel.chapters.first.revision,
          textOffset: anchor + 2,
        ),
      );
      bodies[store.books.single.fileUri] =
          '序章 引言\n新正文。\n第一章 开始\n甲头\n第二章 新增\n新增正文。\n第三章 结束\n乙头\n\n乙目标段，游标和书签都在这里。\n';
      final scan = await store.scan();
      expect(scan.chapterRemaps, hasLength(1));
      final task = scan.chapterRemaps.single;
      final previous = state.positionFor(id)!;
      await state.savePosition(
        novel: novel,
        chapter: 0,
        offset: 100,
        maximum: 100,
        width: 400,
      );
      expect(state.positionFor(id), same(previous));
      storage.failOnce = 'flutter.reader_bookmarks_$id';
      await expectLater(state.migrateLocalChapterTask(task), throwsStateError);
      expect(store.isMigrationPending(id), isTrue);
      final restarted = await LibraryState.load();
      addTearDown(restarted.dispose);
      restarted.bindLocalChapters(store);
      final chapters = await store.chapters(id);
      expect(store.isMigrationPending(id), isFalse);
      final position = restarted.positionFor(id)!;
      final bookmark = restarted.bookmarksFor(id).single;
      final cursor = ListeningStore(prefs).cursor(id)!;
      expect(position.chapter, 3);
      expect(position.paragraphIndex, 1);
      expect(position.fraction, greaterThan(.05));
      expect(position.revision, chapters.first.revision);
      expect(bookmark.position.chapter, 3);
      expect(bookmark.chapterTitle, '第三章 结束');
      expect(cursor.chapter, 3);
      expect(cursor.paragraph, 1);
      expect(cursor.start, 2);
      expect(cursor.positionMs, 0);
      expect(cursor.revision, chapters.first.revision);
      await restarted.migrateLocalChapterTask(task);
      expect(restarted.positionFor(id)!.chapter, 3);
      bodies[store.books.single.fileUri] = oldText;
      await store.scan();
      await store.chapters(id);
      expect(restarted.positionFor(id)!.chapter, 1);
      expect(restarted.bookmarksFor(id).single.position.chapter, 1);
      expect(ListeningStore(prefs).cursor(id)!.chapter, 1);
    },
  );

  test(
    'v2 length-only corruption is rebuilt before open without folder authorization',
    () async {
      await seed(1, version: 2, words: true);
      final index = File('${root.path}/local_books/index.json');
      final json =
          jsonDecode(await index.readAsString()) as Map<String, dynamic>;
      final book = (json['books'] as List).single as Map<String, dynamic>;
      (book['chapters'] as List)[1]['l'] = 1;
      await index.writeAsString(jsonEncode(json));
      await prefs.remove('local_library_folder');
      await prefs.setInt('chapter_$localNovelIdBase', 2);
      final store = await load();
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      state.bindLocalChapters(store);
      final chapters = await store.chapters(localNovelIdBase);
      expect(store.books.single.chapterSplitVersion, 3);
      expect(
        await store.chapterContent(localNovelIdBase, chapters[1]),
        '甲😀乙。',
      );
      expect(state.positionFor(localNovelIdBase), isNotNull);
      expect(state.positionFor(localNovelIdBase)!.paragraphIndex, 0);
    },
  );

  test('active listening pauses old revision and resumes the migrated text anchor', () async {
    source(0, text: '第一章 起点\n甲正文。\n第二章 终点\n乙目标正文。');
    final local = await load();
    await local.scan();
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    state.bindLocalChapters(local);
    final output = FakeListeningOutput();
    final audio = FakeSpeechAudio();
    final controller = ListeningController(repository: local, audio: audio,
      store: ListeningStore(prefs), outputFactory: (_) async => output);
    addTearDown(controller.dispose);
    final book = local.books.single;
    final novel = local.toNovel(book).withChapters(await local.chapters(book.id));
    await controller.start(novel, chapter: 1);
    await controller.saveCursor();
    expect(controller.snapshot.value.current!.text, '乙目标正文。');
    bodies[book.fileUri] = '序章 开场\n新增正文。\n${bodies[book.fileUri]}';
    await local.scan();
    for (var i = 0; i < 200 && (controller.snapshot.value.chapter != 2 ||
        controller.snapshot.value.phase != ListeningPhase.playing); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(controller.snapshot.value.phase, ListeningPhase.playing);
    expect(controller.snapshot.value.chapter, 2);
    expect(controller.snapshot.value.current!.text, '乙目标正文。');
    expect(controller.snapshot.value.novel!.chapters.first.revision, local.books.single.revision);
    expect(controller.savedCursor(book.id)!.chapter, 2);
  });

  test('pending legacy range-only tasks also migrate bookmarks and listening', () async {
    source(0, text: '第一章 起点\n甲正文。\n第二章 终点\n乙正文目标。');
    final store = await load();
    await store.scan();
    final book = store.books.single;
    final whole = bodies[book.fileUri]!;
    final anchor = whole.indexOf('乙正文');
    final position = ReadingPosition(chapter: 0, chapterId: 0, offset: 0,
      fraction: .2, fontSize: 19, width: 0, updatedAt: 42, textOffset: anchor);
    await prefs.setString('reading_position_${book.id}', jsonEncode(position.toJson()));
    await prefs.setString('reader_bookmarks_${book.id}', jsonEncode([
      ReaderBookmark(id: 'old', chapterTitle: '正文', position: position).toJson()]));
    await ListeningStore(prefs).saveCursor(ListeningCursor(novelId: book.id,
      chapterId: 0, chapter: 0, paragraph: 0, start: 0, positionMs: 0,
      segmentHash: '', textOffset: anchor));
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    state.bindLocalChapters(store);
    await state.migrateLocalChapterTask(LocalChapterRemap.create(bookId: book.id,
      oldChapters: [(offset: 0, length: whole.length)],
      newChapters: [for(final c in book.chapters) (offset:c.offset,length:c.length)]));
    expect(state.positionFor(book.id)!.chapter, 1);
    expect(state.bookmarksFor(book.id).single.position.chapter, 1);
    expect(ListeningStore(prefs).cursor(book.id)!.chapter, 1);
    expect(state.positionFor(book.id)!.revision, book.revision);
  });

  test('scan reports each unreadable source rather than no changes', () async {
    source(0);
    final store = await load();
    await store.scan();
    bodies.clear();
    final result = await store.scan();
    expect(result.failures.keys.single, startsWith('0.txt ('));
    expect(result.skipped, 1);
    expect(result.refreshed, 0);
    expect(store.books, hasLength(1));
  });

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
