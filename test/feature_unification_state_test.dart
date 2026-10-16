import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/reader_content.dart';
import 'package:wenku8_flutter/reader_find.dart';

import 'support/offline_fixture.dart';

class _Storage extends InMemorySharedPreferencesStore {
  _Storage() : super.empty();
  int calls = 0;
  int? failAt;
  Completer<void>? journalGate;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    calls++;
    if (calls == failAt) return false;
    if (key == 'flutter.$restoreJournalKey' && journalGate != null) {
      await journalGate!.future;
    }
    return super.setValue(type, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    calls++;
    if (calls == failAt) return false;
    return super.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibraryState state;
  late _Storage storage;
  final novel = offlineFixtureBook(71);
  setUp(() async {
    SharedPreferences.resetStatic();
    storage = _Storage();
    SharedPreferencesStorePlatform.instance = storage;
    state = await LibraryState.load();
  });
  tearDown(() => state.dispose());

  ReadingPosition position({int updated = 100, double offset = 720}) =>
      ReadingPosition(
        chapter: 1,
        chapterId: novel.chapters[1].id,
        offset: offset,
        fraction: offset / 3000,
        fontSize: 19,
        width: 390,
        updatedAt: updated,
        paragraphIndex: 4,
        paragraphFraction: .3,
      );
  Future<LibraryBackup> incoming({int updated = 100, double offset = 720}) =>
      LibraryBackup.fromRecords({
        'shelf': ['71', '72'],
        'shelf_added_71': 100,
        'novel_meta_71': jsonEncode(novel.toSnapshot()),
        'reading_position_71': jsonEncode(
          position(updated: updated, offset: offset).toJson(),
        ),
        'chapter_71': 1,
        'reader_bookmarks_71': jsonEncode([
          ReaderBookmark(
            id: 'mark',
            chapterTitle: '第二章',
            position: position(),
          ).toJson(),
        ]),
        'reading_history_hidden': ['71'],
        'recentSearches': ['星尘', 'Glass'],
        'theme': 'dark',
        'readerFontSize': 24.0,
        'readerKeepScreenOn': true,
      });

  test(
    'backup roundtrip excludes body files, sessions and unknown preferences',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('TOKEN', 'not-exported');
      await prefs.setString('offline_body_71', 'not-exported-body');
      await state.toggleShelf(71, novel: novel);
      await state.savePosition(
        novel: novel,
        chapter: 1,
        offset: 800,
        maximum: 3000,
        width: 390,
        paragraphIndex: 4,
      );
      await state.addBookmark(novel: novel, position: position());
      await state.recordSearch('星尘');
      final text = await (await state.createBackup()).encode();
      expect(text, isNot(contains('not-exported')));
      expect(text, isNot(contains(novel.chapters.first.content)));
      final backup = await LibraryBackup.parse(text);
      expect(
        [
          backup.shelfCount,
          backup.positionCount,
          backup.bookmarkCount,
          backup.historyCount,
        ],
        [1, 1, 1, 1],
      );
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = _Storage();
      final restored = await LibraryState.load();
      addTearDown(restored.dispose);
      await restored.restoreBackup(backup);
      final reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.shelf, {71});
      expect(reloaded.positionFor(71)!.paragraphIndex, 4);
      expect(reloaded.bookmarksFor(71), hasLength(1));
      expect(reloaded.recentSearches, ['星尘']);
      expect(reloaded.cachedNovel(71)!.title, novel.title);
      expect(
        (await SharedPreferences.getInstance()).containsKey(restoreJournalKey),
        isFalse,
      );
    },
  );

  test(
    'merge preserves newer current progress, existing metadata, history visibility and search order',
    () async {
      await state.savePosition(
        novel: novel,
        chapter: 2,
        offset: 900,
        maximum: 3000,
        width: 390,
      );
      await state.recordSearch('glass');
      await state.recordSearch('当前');
      await state.restoreBackup(await incoming());
      expect(state.positionFor(71)!.chapter, 2);
      expect(state.cachedNovel(71), same(novel));
      expect(state.readingHistoryIds, contains(71));
      expect(state.recentSearches, ['当前', 'glass', '星尘']);
      expect(state.theme, ThemeMode.system);
      expect(state.fontSize, 19);
      expect(state.keepScreenOn, isFalse);
    },
  );

  test(
    'incoming progress updates legacy chapter and stable chapter ID, preferences are opt-in',
    () async {
      await state.restoreBackup(await incoming(), importPreferences: true);
      expect(state.chapterFor(71), 1);
      expect(state.positionFor(71)!.chapterId, novel.chapters[1].id);
      expect(state.readingHistoryIds, isEmpty);
      expect(state.theme, ThemeMode.dark);
      expect(state.fontSize, 24);
      expect(state.keepScreenOn, isTrue);
      final inserted = novel.withChapters([
        const NovelChapter('新增', '', id: 71999),
        ...novel.chapters,
      ]);
      expect(state.chapterForNovel(inserted), 2);
    },
  );

  test(
    'repeated restore is idempotent and colliding bookmark IDs preserve both positions',
    () async {
      final backup = await incoming();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'reader_bookmarks_71',
        jsonEncode([
          ReaderBookmark(
            id: 'mark',
            chapterTitle: '已有',
            position: position(offset: 200),
          ).toJson(),
        ]),
      );
      final current = LibraryState(prefs);
      addTearDown(current.dispose);
      await current.restoreBackup(backup);
      await current.restoreBackup(backup);
      expect(
        current.bookmarksFor(71).map((mark) => mark.id).toSet(),
        hasLength(2),
      );
      expect(
        current.bookmarksFor(71).map((mark) => mark.position.offset).toSet(),
        {200, 720},
      );
      expect(current.addedAt(72), backup.createdAt);
    },
  );

  test(
    'operations arriving during restore resume after commit in invocation order',
    () async {
      final backup = await incoming();
      storage.journalGate = Completer<void>();
      final restore = state.restoreBackup(backup);
      final remove = state.setShelfMembership(71, false);
      final save = state.savePosition(
        novel: novel,
        chapter: 0,
        offset: 12,
        maximum: 3000,
        width: 390,
      );
      final search = state.recordSearch('恢复之后');
      expect(state.shelf, isEmpty);
      storage.journalGate!.complete();
      await Future.wait([restore, remove, save, search]);
      expect(state.shelf, {72});
      expect(state.positionFor(71)!.chapter, 0);
      expect(state.readingHistoryIds, [71]);
      expect(state.recentSearches.first, '恢复之后');
    },
  );

  for (var phase = 1; phase <= 11; phase++) {
    test(
      'failed restore phase $phase rolls back disk and does not publish partial memory',
      () async {
        final backup = await incoming();
        await state.setShelfMembership(99, true);
        storage.failAt = storage.calls + phase;
        await expectLater(state.restoreBackup(backup), throwsStateError);
        expect(state.shelf, {99});
        expect(state.positionFor(71), isNull);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList('shelf'), ['99']);
        expect(prefs.containsKey('reading_position_71'), isFalse);
        expect(prefs.containsKey(restoreJournalKey), isFalse);
        await state.restoreBackup(backup);
        expect(state.shelf, {99, 71, 72});
      },
    );
  }

  test(
    'startup recovers an interrupted merge without touching account data',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('TOKEN', 'preserved');
      await prefs.setStringList('shelf', ['71', '72']);
      await prefs.setInt('chapter_71', 4);
      await prefs.setString(
        restoreJournalKey,
        jsonEncode({
          'shelf': ['99'],
          'chapter_71': null,
        }),
      );
      final recovered = await LibraryState.load();
      addTearDown(recovered.dispose);
      expect(recovered.shelf, {99});
      expect(recovered.hasRead(71), isFalse);
      expect(prefs.getString('TOKEN'), 'preserved');
      expect(prefs.containsKey(restoreJournalKey), isFalse);
    },
  );

  test(
    'unrecognized restore journal never writes arbitrary preferences',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('TOKEN', 'preserved');
      await prefs.setString(
        restoreJournalKey,
        jsonEncode({'TOKEN': 'overwrite'}),
      );
      await expectLater(recoverLibraryRestore(prefs), throwsFormatException);
      expect(prefs.getString('TOKEN'), 'preserved');
    },
  );

  for (final bad in [
    {'TOKEN': 'value'},
    {
      'shelf': ['-1'],
    },
    {
      'shelf': [71],
    },
    {'theme': 'unknown'},
    {'readerFontSize': 999},
    {'reading_position_71': '{}'},
    {'novel_meta_72': jsonEncode(novel.toSnapshot())},
    {
      'recentSearches': ['\u0000'],
    },
  ]) {
    test(
      'backup validates malformed record ${bad.keys.first}: ${bad.values.first}',
      () async {
        await expectLater(
          LibraryBackup.fromRecords(Map<String, Object>.from(bad)),
          throwsFormatException,
        );
        expect(state.shelf, isEmpty);
      },
    );
  }

  test('backup rejects future format and oversize input', () async {
    await expectLater(
      LibraryBackup.parse(
        jsonEncode({
          'format': 'wenku8-local-backup',
          'version': 2,
          'createdAt': 0,
          'records': {},
        }),
      ),
      throwsFormatException,
    );
    await expectLater(
      LibraryBackup.parse('a' * (LibraryBackup.maxBytes + 1)),
      throwsFormatException,
    );
  });

  test(
    'search history is bounded, deduplicated and does not rebuild article or global state',
    () async {
      var search = 0;
      var reader = 0;
      var global = 0;
      state.searchChanges.addListener(() => search++);
      state.readerSettingsChanges.addListener(() => reader++);
      state.addListener(() => global++);
      for (var index = 0; index < 15; index++) {
        await state.recordSearch('q-$index');
      }
      await state.recordSearch('Q-14');
      await state.recordSearch('  Q-14  ');
      expect(state.recentSearches, hasLength(12));
      expect(state.recentSearches.first, 'Q-14');
      expect([search, reader, global], [16, 0, 0]);
      await state.clearRecentSearches();
      expect((await LibraryState.load()).recentSearches, isEmpty);
    },
  );

  test(
    'failed shelf removal and failed history hiding leave memory and disk unchanged',
    () async {
      await state.setShelfMembership(71, true, novel: novel);
      await state.setChapter(71, 1);
      storage.failAt = storage.calls + 2; // Membership write after journal.
      await expectLater(state.setShelfMembership(71, false), throwsStateError);
      expect(state.contains(71), isTrue);
      storage.failAt = storage.calls + 1;
      await expectLater(state.hideReadingHistory(71), throwsStateError);
      expect(state.readingHistoryIds, [71]);
      await state.hideReadingHistory(71);
      expect(state.readingHistoryIds, isEmpty);
    },
  );

  test(
    'shelf sort/filter persist and restored added time is retained by undo',
    () async {
      await state.setShelfView(sort: 'title', filter: 'reading');
      await state.setShelfMembership(71, true, restoredAddedAt: 123);
      final revision = state.shelfRevision(71);
      await state.setShelfMembership(71, false);
      await state.setShelfMembership(71, true, restoredAddedAt: 123);
      expect(state.shelfRevision(71), revision + 2);
      final reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      expect(
        [reloaded.shelfSort, reloaded.shelfFilter, reloaded.addedAt(71)],
        ['title', 'reading', 123],
      );
    },
  );

  test(
    'keep-awake uses only behavior notifier, never typography reflow',
    () async {
      var behavior = 0;
      var reader = 0;
      state.readerBehaviorChanges.addListener(() => behavior++);
      state.readerSettingsChanges.addListener(() => reader++);
      await state.setKeepScreenOn(true);
      expect([behavior, reader], [1, 0]);
      expect((await LibraryState.load()).keepScreenOn, isTrue);
    },
  );

  test(
    'find treats regex characters literally and retains exact UTF-16 indices',
    () async {
      final content = await ReaderContent.parse('😀 Glass.* 与 glass.*\n\n没有匹配');
      final result = await findInReader(content, 'gLaSs.*');
      expect(result.matches.map((match) => match.start), [3, 13]);
      expect(
        result.matches.every(
          (match) =>
              content.paragraphs[match.paragraph]
                  .substring(match.start, match.end)
                  .toLowerCase() ==
              'glass.*',
        ),
        isTrue,
      );
      expect((await findInReader(content, ' ')).matches, isEmpty);
      expect((await findInReader(content, 'a' * 121)).matches, isEmpty);
    },
  );

  test(
    'find bounds lazy result count and searches a large chapter asynchronously',
    () async {
      final content = await ReaderContent.parse(
        List.generate(
          1500,
          (index) => '第 $index 段 ${'正文文字' * 20} 匹配',
        ).join('\n\n'),
      );
      final result = await findInReader(content, '匹配');
      expect(result.matches, hasLength(500));
      expect(result.truncated, isTrue);
      expect(result.matches.last.paragraph, 499);
    },
  );
}
