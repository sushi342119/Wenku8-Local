import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/legacy_wenku_repository.dart';
import 'package:wenku8_flutter/library_state.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android history visibility and resume position persist independently',
    (tester) async {
      // Integration builds have their own render_probe application ID.
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      final repository = LegacyWenkuRepository();
      final preview = (await repository.list()).first;
      final detail = await repository.detail(preview);
      final chapters = await repository.chapters(preview.id);
      expect(chapters, isNotEmpty);
      final novel = detail.withChapters(chapters);
      final state = LibraryState(prefs);
      await state.toggleShelf(novel.id, novel: novel);
      await state.savePosition(
        novel: novel,
        chapter: 0,
        offset: 300,
        maximum: 3000,
        width: 411,
      );
      final saved = state.positionFor(novel.id)!.toJson();
      expect(state.readingHistoryIds, [novel.id]);
      await state.clearReadingHistory();
      await prefs.reload();
      final hidden = LibraryState(prefs);
      expect(hidden.readingHistoryIds, isEmpty);
      expect(hidden.shelf, {novel.id});
      expect(hidden.positionFor(novel.id)!.toJson(), saved);
      expect(hidden.cachedNovel(novel.id)!.title, novel.title);
      await hidden.restoreReadingHistory(novel.id);
      await prefs.reload();
      final restored = LibraryState(prefs);
      expect(restored.readingHistoryIds, [novel.id]);
      expect(restored.positionFor(novel.id)!.chapterId, chapters.first.id);
      expect(restored.positionFor(novel.id)!.offset, 300);
      // ignore: avoid_print
      print(
        'READING_HISTORY_ANDROID ${jsonEncode({'aid': novel.id, 'cid': chapters.first.id, 'directory_chapters': chapters.length, 'visible_after_reload': true, 'hidden_after_clear_reload': true, 'shelf_retained': true, 'position_retained': true, 'offset': restored.positionFor(novel.id)!.offset})}',
      );
      restored.dispose();
      hidden.dispose();
      state.dispose();
      await prefs.clear();
    },
  );
}
