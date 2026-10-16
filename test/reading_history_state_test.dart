import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/library_state.dart';

import 'support/offline_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final book = offlineFixtureBook(71);

  Future<void> save(LibraryState state, {double offset = 600}) =>
      state.savePosition(
        novel: book,
        chapter: 1,
        offset: offset,
        maximum: 3000,
        width: 390,
      );

  test(
    'legacy and position-only history is independent of the shelf and sorted by time',
    () async {
      SharedPreferences.setMockInitialValues({
        'shelf': ['999'],
        'chapter_71': 2,
        'chapter_72': 1,
        'chapter_0': 1,
        'chapter_-1': 1,
        'chapter_73': 'broken',
        'reading_position_72': jsonEncode({
          'chapter': 1,
          'chapterId': 72002,
          'updatedAt': 100,
        }),
        'reading_position_74': jsonEncode({
          'chapter': 2,
          'chapterId': 74003,
          'updatedAt': 200,
        }),
      });
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      expect(state.readingHistoryIds, [74, 72, 71]);
      expect(state.shelf, {999});
      expect(state.hasRead(74), isTrue);
      expect(state.chapterFor(74), 2);
      await state.hideReadingHistory(74);
      expect((await LibraryState.load()).readingHistoryIds, [72, 71]);
    },
  );

  test(
    'saving an unshelved book records one latest history item and updates its position',
    () async {
      SharedPreferences.setMockInitialValues({'chapter_72': 0});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await save(state);
      await save(state, offset: 900);
      expect(state.readingHistoryIds, [71, 72]);
      expect(state.shelf, isEmpty);
      final reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.readingHistoryIds, [71, 72]);
      expect(reloaded.positionFor(71)!.chapterId, 71002);
      expect(reloaded.positionFor(71)!.offset, 900);
      expect(reloaded.cachedNovel(71)!.title, book.title);
    },
  );

  test(
    'hide and undo retain metadata, stable chapter, shelf and timestamp',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await state.toggleShelf(71, novel: book);
      await save(state);
      final position = state.positionFor(71)!;
      await state.hideReadingHistory(71);
      expect(state.readingHistoryIds, isEmpty);
      var reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.shelf, {71});
      expect(reloaded.positionFor(71)!.toJson(), position.toJson());
      expect(reloaded.cachedNovel(71)!.title, book.title);
      await reloaded.restoreReadingHistory(71);
      reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.readingHistoryIds, [71]);
      expect(reloaded.positionFor(71)!.updatedAt, position.updatedAt);
    },
  );

  test(
    'clear changes only the history visibility key and keeps all resume preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'readerFontSize': 25.0,
        'glassBlur': 12.0,
        'theme': 'dark',
      });
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await state.toggleShelf(71, novel: book);
      await save(state);
      await state.setChapter(72, 2);
      final prefs = await SharedPreferences.getInstance();
      final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
      await state.clearReadingHistory();
      for (final key in before.keys) {
        expect(prefs.get(key), before[key], reason: key);
      }
      final reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.readingHistoryIds, isEmpty);
      expect(reloaded.shelf, {71});
      expect(reloaded.chapterFor(72), 2);
      expect(reloaded.fontSize, 25);
      expect(reloaded.glassBlur, 12);
      expect(reloaded.positionFor(71)!.offset, 600);
    },
  );

  test(
    'reading a hidden book again makes it visible after another reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await save(state);
      await state.clearReadingHistory();
      final restarted = await LibraryState.load();
      addTearDown(restarted.dispose);
      expect(restarted.readingHistoryIds, isEmpty);
      await save(restarted, offset: 500);
      final reopened = await LibraryState.load();
      addTearDown(reopened.dispose);
      expect(reopened.readingHistoryIds, [71]);
      expect(reopened.positionFor(71)!.offset, 500);
    },
  );

  test(
    'queued saves, hide, clear and undo preserve their invocation order',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final operations = [
        save(state),
        state.hideReadingHistory(71),
        save(state, offset: 300),
        state.clearReadingHistory(),
        state.restoreReadingHistory(71),
      ];
      await Future.wait(operations);
      final reloaded = await LibraryState.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.readingHistoryIds, [71]);
      expect(reloaded.positionFor(71)!.offset, 300);
      expect(reloaded.positionFor(71)!.chapterId, 71002);
    },
  );

  test(
    'quiet progress and history changes do not notify appearance or reader settings',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      var history = 0;
      var global = 0;
      var appearance = 0;
      var reader = 0;
      var settings = 0;
      state.historyChanges.addListener(() => history++);
      state.addListener(() => global++);
      state.appearanceChanges.addListener(() => appearance++);
      state.readerSettingsChanges.addListener(() => reader++);
      state.settingsChanges.addListener(() => settings++);
      await state.savePosition(
        novel: book,
        chapter: 0,
        offset: 0,
        maximum: 100,
        width: 390,
        notify: false,
      );
      await state.hideReadingHistory(71);
      expect(history, 2);
      expect([global, appearance, reader, settings], [0, 0, 0, 0]);
    },
  );

  test(
    'invalid new reads and damaged visibility data do not invent history',
    () async {
      SharedPreferences.setMockInitialValues({
        'reading_history_hidden': 'broken',
      });
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      await state.setChapter(0, 1);
      await state.setChapter(71, -1);
      await state.savePosition(
        novel: book,
        chapter: 3,
        offset: 0,
        maximum: 100,
        width: 390,
      );
      await state.savePosition(
        novel: book,
        chapter: 0,
        offset: double.nan,
        maximum: 100,
        width: 390,
      );
      await state.hideReadingHistory(999);
      await state.restoreReadingHistory(999);
      expect(state.readingHistoryIds, isEmpty);
      expect(state.hasRead(71), isFalse);
    },
  );
}
