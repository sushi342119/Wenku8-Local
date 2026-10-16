import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/library_state.dart';

import '../test/support/offline_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android bookmarks, typography and resume persist independently',
    (tester) async {
      // Only the owned emulator's separate render_probe application stores data.
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      final novel = offlineFixtureBook(71);
      final state = LibraryState(prefs);
      addTearDown(state.dispose);
      try {
        await state.setFontSize(22);
        await state.setLineHeight(1.9);
        await state.savePosition(
          novel: novel,
          chapter: 1,
          offset: 760,
          maximum: 3000,
          width: 411,
          paragraphIndex: 12,
          paragraphFraction: .37,
          textScale: 1.3,
        );
        final saved = state.positionFor(71)!;
        final mark = (await state.addBookmark(novel: novel, position: saved))!;
        await prefs.reload();
        final restarted = LibraryState(prefs);
        addTearDown(restarted.dispose);
        expect(restarted.fontSize, 22);
        expect(restarted.lineHeight, 1.9);
        expect(restarted.positionFor(71)!.paragraphIndex, 12);
        expect(
          restarted.bookmarksFor(71).single.position.paragraphFraction,
          .37,
        );
        expect(restarted.positionFor(71)!.textScale, 1.3);
        expect(restarted.positionFor(71)!.toJson(), saved.toJson());
        expect(
          restarted.bookmarksFor(71).single.position.toJson(),
          saved.toJson(),
        );
        await restarted.removeBookmark(71, mark.id);
        await prefs.reload();
        final deleted = LibraryState(prefs);
        addTearDown(deleted.dispose);
        expect(deleted.bookmarksFor(71), isEmpty);
        expect(deleted.positionFor(71)!.toJson(), saved.toJson());
        expect(deleted.readingHistoryIds, [71]);
        // ignore: avoid_print
        print(
          'READER_STORAGE_ANDROID ${jsonEncode({'bookmark_reloaded': true, 'removal_reloaded': true, 'resume_retained': true, 'font_size': deleted.fontSize, 'line_height': deleted.lineHeight, 'chapter_id': saved.chapterId, 'offset': saved.offset, 'paragraph_index': saved.paragraphIndex, 'paragraph_fraction': saved.paragraphFraction, 'text_scale': saved.textScale})}',
        );
      } finally {
        await prefs.clear();
      }
    },
  );
}
