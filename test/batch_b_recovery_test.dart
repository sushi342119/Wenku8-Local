import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/book_tags.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/local_library.dart';
import 'package:wenku8_flutter/listening/models.dart';
import 'package:wenku8_flutter/listening/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('automatic scans respect explicit shelf removal and explicit add restores it', () async {
    final state = LibraryState(await SharedPreferences.getInstance());
    addTearDown(state.dispose);
    const book = Novel(id: localNovelIdBase + 1, title: '本地', author: '',
      genre: '', summary: '', colors: [Colors.black, Colors.white], chapters: []);
    await state.addShelfBooks([book]);
    await state.setShelfMembership(book.id, false);
    await state.addShelfBooks([book]);
    expect(state.contains(book.id), isFalse);
    await state.addShelfIds([book.id], novels: {book.id: book});
    expect(state.contains(book.id), isTrue);
  });

  test('malformed reading anchor is isolated and complete clear removes all consumers', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('chapter_42', 1);
    await prefs.setString('reading_anchor_42', '{broken');
    await prefs.setString('listening.cursor.v1.42', '{}');
    await prefs.setString('reader_bookmarks_42', '[]');
    final state = LibraryState(prefs);
    addTearDown(state.dispose);
    expect(state.positionFor(42), isNull);
    await state.clearBookProgress(42);
    for (final key in ['chapter_42', 'reading_anchor_42', 'listening.cursor.v1.42', 'reader_bookmarks_42']) {
      expect(prefs.containsKey(key), isFalse, reason: key);
    }
  });

  test('tag definitions recover per item and preserve damaged original', () async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode([
      {'id': 'ok', 'name': '保留', 'colorIndex': 1},
      {'id': 9, 'name': ['bad'], 'colorIndex': 'bad'},
    ]);
    await prefs.setString('book_tags', raw);
    await prefs.setString('book_tag_map', jsonEncode({'42': ['ok']}));
    await TagStore.load();
    expect(TagStore.shared.tagNamesForBook(42), ['保留']);
    expect(prefs.getStringList('book_tags_quarantine_v1'), isNotEmpty);
  });

  test('damaged cursor fields are archived before replacement', () async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode({'novelId': 42, 'chapter': 3, 'revision': [], 'textOffset': 'bad'});
    await prefs.setString('listening.cursor.v1.42', raw);
    final store = ListeningStore(prefs);
    expect(store.cursor(42)?.chapter, 3);
    await store.saveCursor(const ListeningCursor(novelId: 42, chapterId: 3,
      chapter: 3, paragraph: 0, start: 0, positionMs: 0, segmentHash: ''));
    final archive = prefs.getStringList('listening.cursor.quarantine.v1')!;
    expect(jsonDecode(archive.single)['raw'], raw);
  });

  test('UTF8 filename limit preserves extension and valid codepoints', () {
    final name = LocalLibraryStore.safeFileNameForTitle('旧.txt', '中文😀' * 100)!;
    expect(utf8.encode(name).length, lessThanOrEqualTo(255));
    expect(name, endsWith('.txt'));
    expect(utf8.decode(utf8.encode(name)), name);
  });

  test('merge saves an exportable snapshot of the pre-restore records', () async {
    final prefs = await SharedPreferences.getInstance();
    await TagStore.load();
    final state = LibraryState(prefs);
    addTearDown(state.dispose);
    await state.addShelfIds([42]);
    final backup = await LibraryBackup.fromRecords({'shelf': ['43']});
    await state.restoreBackup(backup);
    expect(state.shelf, containsAll([42, 43]));
    final previous = await LibraryBackup.parse(state.preRestoreBackup!);
    expect(previous.records['shelf'], ['42']);
  });
}
