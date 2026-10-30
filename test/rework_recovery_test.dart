import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:wenku8_flutter/book_tags.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_library.dart';
import 'package:wenku8_flutter/local_platform.dart';
import 'package:wenku8_flutter/local_record_removal.dart';
import 'package:wenku8_flutter/recovery_archive.dart';
import 'package:wenku8_flutter/wenku_errors.dart';

import 'support/offline_fixture.dart';

class _Storage extends InMemorySharedPreferencesStore {
  _Storage() : super.empty();
  String? failKey;
  Completer<void>? archiveGate;
  int reads = 0;

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) {
    reads++;
    return super.getAllWithParameters(parameters);
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == failKey) {
      await archiveGate?.future;
      return false;
    }
    return super.setValue(type, key, value);
  }
}

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
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Storage storage;
  late SharedPreferences prefs;
  late Directory root;
  late PathProviderPlatform previousPaths;
  final stores = <LocalLibraryStore>[];
  const queueKey = 'local_library_pending_chapter_remaps_v1';
  const cleanupKey = 'local_book_data_cleanup_v1';
  const failedCopiesKey = 'local_library_failed_copy_cleanups_v1';
  const removalKey = 'local.pending_record_removal.v1';

  setUp(() async {
    storage = _Storage();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = storage;
    prefs = await SharedPreferences.getInstance();
    root = await Directory.systemTemp.createTemp('wenku8-rework-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
      throw MissingPluginException();
    });
  });

  tearDown(() async {
    for (final store in stores) {
      store.dispose();
    }
    stores.clear();
    PathProviderPlatform.instance = previousPaths;
    messenger.setMockMethodCallHandler(LocalPlatform.channel, null);
    await root.delete(recursive: true);
  });

  LocalBook book({LocalBookKind kind = LocalBookKind.txt}) => LocalBook(
    id: localNovelIdBase,
    title: '保留',
    author: '原作者',
    fileUri: 'content://test/tree/books/document/book',
    fileName: kind == LocalBookKind.txt ? 'book.txt' : 'book.pdf',
    kind: kind,
    size: 100,
    modified: 1,
    chapters: const [
      LocalChapterIndex('第一章', 0, 50),
      LocalChapterIndex('第二章', 50, 50),
    ],
    pageCount: kind == LocalBookKind.pdf ? 2 : 0,
    wordCount: 100,
    chapterSplitVersion: 3,
    sourceId: 'saf:content://test/tree/books',
    sourceKey: 'content://test/tree/books/document/book',
  );

  Future<void> seed(List<Object?> books) async {
    final directory = Directory('${root.path}/local_books');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/index.json',
    ).writeAsString(jsonEncode({'books': books}));
  }

  Future<LocalLibraryStore> load() async {
    final store = await LocalLibraryStore.load();
    stores.add(store);
    return store;
  }

  test(
    'unloaded tags reject backup and pre-restore snapshot with a specific message',
    () async {
      expect(TagStore.maybeShared, isNull);
      await prefs.setString('book_tags', '{broken');
      storage.failKey = 'flutter.book_tags_quarantine_v1';
      await expectLater(TagStore.load(), throwsStateError);
      final state = LibraryState(prefs);
      addTearDown(state.dispose);
      await state.addShelfIds([71]);
      final incoming = await LibraryBackup.fromRecords({
        'shelf': ['72'],
      });
      final rejected = throwsA(
        isA<LibraryBackupUnavailable>()
            .having((error) => error.message, 'reason', contains('标签未加载'))
            .having((error) => error.message, 'outcome', contains('拒绝')),
      );
      await expectLater(state.createBackup(), rejected);
      await expectLater(state.restoreBackup(incoming), rejected);
      expect(state.shelf, {71});
      expect(state.preRestoreBackup, isNull);
      expect(prefs.get(restoreJournalKey), isNull);
      storage.failKey = null;
      await TagStore.load();
      expect(
        (await state.createBackup()).records.keys,
        containsAll(['tag_defs', 'tag_map']),
      );
    },
  );

  test(
    'preserved invalid index entries still refresh bak and corrupt copies stay bounded',
    () async {
      final damaged = {
        'id': localNovelIdBase + 1,
        'title': ['unreadable'],
      };
      await seed([book().toJson(), damaged]);
      final store = await load();
      expect(store.unreadableIndexRecordCount, 1);
      for (var revision = 1; revision <= 3; revision++) {
        await store.editBookFile(
          book().id,
          title: book().title,
          author: '作者$revision',
        );
      }
      final index = File('${root.path}/local_books/index.json');
      final backup =
          jsonDecode(await File('${index.path}.bak').readAsString()) as Map;
      expect(backup['books'][0]['customAuthor'], '作者2');
      expect(backup['books'][1], damaged);
      expect(
        await Directory(
          '${root.path}/local_books',
        ).list().where((entry) => entry.path.contains('.corrupt')).length,
        0,
      );
      for (var revision = 4; revision <= 7; revision++) {
        await index.writeAsString('{corrupt-$revision');
        await store.editBookFile(
          book().id,
          title: book().title,
          author: '作者$revision',
        );
      }
      expect(
        await Directory(
          '${root.path}/local_books',
        ).list().where((entry) => entry.path.contains('.corrupt')).length,
        1,
      );
      await index.writeAsString('{crashed');
      final recovered = await load();
      expect(recovered.books.single.customAuthor, '作者2');
      expect(recovered.unreadableIndexRecordCount, 1);
    },
  );

  test(
    'stale r0 cannot archive executable r1 and progress actually migrates',
    () async {
      final current = book();
      await seed([current.toJson()]);
      final stale = LocalChapterRemap.create(
        bookId: current.id,
        oldChapters: const [(offset: 0, length: 10)],
        newChapters: const [(offset: 0, length: 20)],
      );
      final valid = LocalChapterRemap.create(
        bookId: current.id,
        oldChapters: const [(offset: 0, length: 100)],
        newChapters: const [(offset: 0, length: 50), (offset: 50, length: 50)],
      );
      await prefs.setString(
        queueKey,
        jsonEncode([stale.toJson(), valid.toJson()]),
      );
      await prefs.setString(
        'reading_position_${current.id}',
        jsonEncode(
          const ReadingPosition(
            chapter: 0,
            chapterId: 0,
            offset: 75,
            fraction: .75,
            fontSize: 19,
            width: 390,
            updatedAt: 100,
          ).toJson(),
        ),
      );
      final state = LibraryState(prefs);
      addTearDown(state.dispose);
      final store = await load();
      expect(store.pendingChapterRemaps.map((task) => task.migrationId), [
        valid.migrationId,
      ]);
      final archived = jsonDecode(
        prefs
            .getStringList('local_library_quarantined_chapter_remaps_v1')!
            .single,
      );
      final abandoned = archived['details']['abandoned'] as List;
      expect(abandoned.map((task) => task['migrationId']), [stale.migrationId]);
      expect(abandoned.single['terminalReason'], 'unreachable');
      store.migrateProgress = (task) => state.remapChapterProgress(
        task.bookId,
        oldChapters: task.oldChapters,
        newChapters: task.newChapters,
        migrationId: task.migrationId,
      );
      await store.ensureReady(current.id);
      expect(state.positionFor(current.id)!.chapter, 1);
      expect(state.positionFor(current.id)!.fraction, .5);
      expect(store.pendingChapterRemaps, isEmpty);
    },
  );

  test(
    'local exports omit invalid covers while external imports remain strict',
    () async {
      await TagStore.load();
      for (final entry in {
        71: 'http://img.wenku8.com/old.jpg',
        72: 'https://outside.invalid/cover.jpg',
      }.entries) {
        final snapshot = {
          ...offlineFixtureBook(entry.key).toSnapshot(),
          'coverUrl': entry.value,
        };
        await prefs.setString('novel_meta_${entry.key}', jsonEncode(snapshot));
        final external = jsonEncode({
          'format': 'wenku8-local-backup',
          'version': 1,
          'createdAt': 1,
          'records': {'novel_meta_${entry.key}': jsonEncode(snapshot)},
        });
        await expectLater(LibraryBackup.parse(external), throwsFormatException);
      }
      final state = LibraryState(prefs);
      addTearDown(state.dispose);
      await state.addShelfIds([71, 72]);
      final exported = await state.createBackup();
      expect(
        exported.omittedCoverKeys,
        containsAll(['novel_meta_71', 'novel_meta_72']),
      );
      final imported = await LibraryBackup.parse(await exported.encode());
      for (final id in [71, 72]) {
        expect(
          jsonDecode(imported.records['novel_meta_$id'] as String)['coverUrl'],
          isNull,
        );
        expect(state.cachedNovel(id)!.coverUrl, isNotNull);
        expect(
          jsonDecode(prefs.getString('novel_meta_$id')!)['coverUrl'],
          isNotNull,
        );
      }
      await state.restoreBackup(
        await LibraryBackup.fromRecords({
          'shelf': ['73'],
        }),
      );
      expect(state.shelf, containsAll([71, 72, 73]));
      final snapshot = await LibraryBackup.parse(state.preRestoreBackup!);
      expect(snapshot.records['shelf'], ['71', '72']);
      expect(
        jsonDecode(snapshot.records['novel_meta_72'] as String)['coverUrl'],
        isNull,
      );
    },
  );

  test(
    'shelf repair requires durable quarantine before unblocking writes',
    () async {
      await TagStore.load();
      final raw = ['71', 'broken', '0', '-1'];
      await prefs.setStringList('shelf', raw);
      final state = LibraryState(prefs);
      addTearDown(state.dispose);
      expect(state.shelfLoadFailed, isTrue);
      await expectLater(state.addShelfIds([72]), throwsStateError);
      await expectLater(state.createBackup(), throwsStateError);
      storage.failKey = 'flutter.library_shelf_quarantine_v1';
      await expectLater(state.repairShelf(), throwsStateError);
      expect(state.shelfLoadFailed, isTrue);
      expect(prefs.getStringList('shelf'), raw);
      storage.failKey = 'flutter.shelf';
      await expectLater(state.repairShelf(), throwsStateError);
      expect(state.shelfLoadFailed, isTrue);
      expect(prefs.getStringList('shelf'), raw);
      storage.failKey = null;
      await state.repairShelf();
      expect(state.shelfLoadFailed, isFalse);
      expect(state.shelf, {71});
      expect(
        prefs
            .getStringList('library_shelf_quarantine_v1')!
            .map((record) => jsonDecode(record)['raw']),
        contains(equals(raw)),
      );
      await state.addShelfIds([72]);
      expect((await state.createBackup()).records['shelf'], ['71', '72']);
    },
  );

  test(
    'successful shelf reread clears guard without replacing repaired storage',
    () async {
      await prefs.setString('shelf', 'unreadable');
      final state = LibraryState(prefs);
      addTearDown(state.dispose);
      await prefs.setStringList('shelf', ['72']);
      await state.repairShelf();
      expect(state.shelfLoadFailed, isFalse);
      expect(state.shelf, {72});
      expect(prefs.get('library_shelf_quarantine_v1'), isNull);
    },
  );

  test(
    'restore archive failure permits load, preserves journal and prevents overwrite',
    () async {
      await prefs.setString(restoreJournalKey, '{broken');
      storage.failKey = 'flutter.$restoreJournalQuarantineKey';
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      expect(prefs.getString(restoreJournalKey), '{broken');
      expect(recoveryFailures, contains(restoreJournalKey));
      await expectLater(state.addShelfIds([71]), throwsStateError);
      expect(prefs.getString(restoreJournalKey), '{broken');
      storage.failKey = null;
      expect(await recoverLibraryRestore(prefs), isTrue);
      expect(prefs.get(restoreJournalKey), isNull);
      await state.addShelfIds([71]);
      expect(state.shelf, {71});
    },
  );

  test(
    'restore retries failed records and recognizes local_shelf_removed',
    () async {
      final journal = jsonEncode({
        'local_shelf_removed': ['$localNovelIdBase'],
        'chapter_71': 1,
        'unknown': 'preserve',
      });
      await prefs.setString(restoreJournalKey, journal);
      storage.failKey = 'flutter.chapter_71';
      expect(await recoverLibraryRestore(prefs), isFalse);
      expect(prefs.getString(restoreJournalKey), journal);
      expect(prefs.getStringList('local_shelf_removed'), ['$localNovelIdBase']);
      storage.failKey = null;
      expect(await recoverLibraryRestore(prefs), isTrue);
      expect(prefs.getInt('chapter_71'), 1);
      expect(prefs.get('unknown'), isNull);
      expect(isLibraryRecordKey('local_shelf_removed'), isTrue);
    },
  );

  test(
    'corrupt removal archive failure is nonblocking and cannot be overwritten',
    () async {
      Object? raw = '{bad';
      var rejectArchive = true;
      final archived = <Object>[];
      final journal = RecordRemovalJournal(
        readIntent: () => raw,
        writeIntent: (value) async => raw = value,
        archiveIntent: (value) async {
          if (rejectArchive) throw StateError('storage failure');
          archived.add(value);
        },
        readIgnored: () => {},
        writeIgnored: (_) async {},
        finishRemoval: (_) async => fail('unexpected deletion'),
      );
      await journal.recover();
      expect(raw, '{bad');
      expect(recoveryFailures, contains('record_removal_archive'));
      await expectLater(
        journal.remove(bookId: localNovelIdBase, ignoreKey: null),
        throwsStateError,
      );
      expect(raw, '{bad');
      rejectArchive = false;
      await journal.recover();
      expect(archived, ['{bad']);
      expect(raw, isNull);
    },
  );

  test(
    'corrupt removal archive failure does not stop library load or scan',
    () async {
      await prefs.setString(removalKey, '{bad');
      storage.failKey = 'flutter.local_library_quarantined_record_removals_v1';
      final store = await load();
      final result = await store.scanAppFolder();
      expect(result.total, 0);
      expect(prefs.getString(removalKey), '{bad');
      storage.failKey = null;
      await store.scanAppFolder();
      expect(prefs.get(removalKey), isNull);
    },
  );

  test(
    'failed copy deletion survives failed archive and retries after restart',
    () async {
      await TagStore.load();
      final current = book(kind: LocalBookKind.pdf);
      await seed([current.toJson()]);
      var attempts = 0;
      var rejectDelete = true;
      messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
        if (call.method == 'clearPdfCache') {
          attempts++;
          if (rejectDelete) throw PlatformException(code: 'busy');
          return null;
        }
        throw MissingPluginException();
      });
      final store = await load();
      storage.failKey = 'flutter.$failedCopiesKey';
      await store.removeBookRecordOnly(current.id);
      expect(attempts, 3);
      expect(store.books, isEmpty);
      expect(jsonDecode(prefs.getString(cleanupKey)!), isNotEmpty);
      expect(recoveryFailures, contains('copy_cleanup_archive:${current.id}'));
      await prefs.reload();
      expect(prefs.get(failedCopiesKey), isNull);
      storage.failKey = null;
      rejectDelete = false;
      await load();
      expect(attempts, 4);
      expect(prefs.get(cleanupKey), isNull);
    },
  );

  test(
    'cleanup keeps false results and never deletes a book still in the index',
    () async {
      await TagStore.load();
      final current = book(kind: LocalBookKind.pdf);
      await seed([current.toJson()]);
      final record = {'book': current.toJson(), 'clearStash': true};
      await prefs.setString(cleanupKey, jsonEncode([record]));
      await prefs.setStringList('local_library_associated_cleanup', [
        '${current.id}',
      ]);
      var attempts = 0;
      messenger.setMockMethodCallHandler(LocalPlatform.channel, (call) async {
        if (call.method == 'clearPdfCache') {
          attempts++;
          throw PlatformException(code: 'busy');
        }
        throw MissingPluginException();
      });
      final store = await load();
      expect(attempts, 0);
      expect(await store.peekAssociatedCleanupIds(), isEmpty);
      expect(jsonDecode(prefs.getString(cleanupKey)!), [record]);
      await seed([]);
      await load();
      expect(attempts, 3);
      expect(jsonDecode(prefs.getString(cleanupKey)!), [record]);
    },
  );

  test(
    'legacy failed-copy archives have an automatic retry entrance',
    () async {
      await TagStore.load();
      final current = book();
      await seed([]);
      final copy = File('${root.path}/local_books/book_${current.id}.txt');
      await copy.writeAsString('residual');
      await archiveRecoveryRecord(
        prefs,
        failedCopiesKey,
        jsonEncode(current.toJson()),
        reason: 'copy_cleanup_failed',
      );
      await load();
      expect(await copy.exists(), isFalse);
      expect(prefs.get(failedCopiesKey), isNull);
    },
  );

  test(
    'archive encoding failures are recorded and failed writes never reload unrelated data',
    () async {
      const key = 'synthetic_archive';
      await expectLater(
        archiveRecoveryRecord(prefs, key, Object(), reason: 'test'),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(recoveryFailures, contains(key));
      final readsBefore = storage.reads;
      storage.failKey = 'flutter.$key';
      storage.archiveGate = Completer<void>();
      final archived = archiveRecoveryRecord(
        prefs,
        key,
        'original',
        reason: 'test',
      );
      final rejected = expectLater(archived, throwsStateError);
      await prefs.setInt('chapter_71', 5);
      storage.archiveGate!.complete();
      await rejected;
      expect(storage.reads, readsBefore);
      expect(prefs.getInt('chapter_71'), 5);
    },
  );

  test(
    'unconfirmed native rename accepts null locations and keeps source identity',
    () async {
      messenger.setMockMethodCallHandler(
        LocalPlatform.channel,
        (call) async => {
          'renamed': false,
          'code': 'unconfirmed',
          'fileUri': null,
          'fileName': null,
        },
      );
      await expectLater(
        LocalPlatform.renameLocalDocument(book().fileUri, 'new.txt'),
        throwsA(
          isA<LocalRenameException>()
              .having((error) => error.code, 'code', 'unconfirmed')
              .having((error) => error.fileUri, 'fileUri', isNull),
        ),
      );
      await seed([book().toJson()]);
      final store = await load();
      await expectLater(
        store.editBookFile(book().id, title: 'new', author: ''),
        throwsA(isA<LocalRenameException>()),
      );
      expect(store.books.single.fileUri, book().fileUri);
      expect(store.books.single.fileName, book().fileName);
    },
  );

  test(
    'only local scan diagnostics retain details; general summaries stay redacted',
    () {
      const error = FormatException('TXT 解码失败 /local/private.txt');
      expect(describeLocalScanError(error), contains('解码失败'));
      expect(describeSafeError(error), isNot(contains('/local/private.txt')));
    },
  );
}
