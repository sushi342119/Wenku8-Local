import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/native_effects.dart';

import '../test/feature_unification_ui_test.dart' as features;
import '../test/support/offline_fixture.dart';
import 'polish_regression_test.dart' as regression;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android local backup merge, reload and interrupted-restore recovery',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs
          .clear(); // Only the separate owned-emulator render_probe package.
      final original = LibraryState(prefs);
      addTearDown(original.dispose);
      try {
        final novel = offlineFixtureBook(71);
        await original.setShelfMembership(
          71,
          true,
          novel: novel,
          restoredAddedAt: 123,
        );
        await original.savePosition(
          novel: novel,
          chapter: 1,
          offset: 760,
          maximum: 3000,
          width: 411,
          paragraphIndex: 12,
          paragraphFraction: .37,
          textScale: 1.3,
        );
        await original.addBookmark(
          novel: novel,
          position: original.positionFor(71)!,
        );
        await original.recordSearch('本地备份');
        await original.setKeepScreenOn(true);
        final backup = await LibraryBackup.parse(
          await (await original.createBackup()).encode(),
        );
        final position = original.positionFor(71)!.toJson();
        await prefs.clear();
        final restored = LibraryState(prefs);
        addTearDown(restored.dispose);
        await restored.restoreBackup(backup, importPreferences: true);
        await prefs.reload();
        final reloaded = LibraryState(prefs);
        addTearDown(reloaded.dispose);
        expect(reloaded.shelf, {71});
        expect(reloaded.addedAt(71), 123);
        expect(reloaded.positionFor(71)!.toJson(), position);
        expect(reloaded.bookmarksFor(71).single.position.toJson(), position);
        expect(reloaded.recentSearches, ['本地备份']);
        expect(reloaded.keepScreenOn, isTrue);
        await prefs.setString(
          restoreJournalKey,
          jsonEncode({
            'shelf': ['71'],
            'chapter_99': null,
          }),
        );
        await prefs.setStringList('shelf', ['71', '99']);
        await prefs.setInt('chapter_99', 2);
        await recoverLibraryRestore(prefs);
        await prefs.reload();
        final recovered = LibraryState(prefs);
        addTearDown(recovered.dispose);
        expect(recovered.shelf, {71});
        expect(recovered.hasRead(99), isFalse);
        expect(prefs.containsKey(restoreJournalKey), isFalse);
        // ignore: avoid_print
        print(
          'LOCAL_BACKUP_ANDROID=${jsonEncode({'merge_reloaded': true, 'journal_recovered': true, 'paragraph_anchor': reloaded.positionFor(71)!.paragraphIndex, 'bookmarks': reloaded.bookmarksFor(71).length})}',
        );
      } finally {
        await prefs.clear();
      }
    },
  );
  group('feature unification', () {
    setUp(() async => NativeEffects.prepare());
    features.main(
      nativePlatform: true,
      capture: (tester, key, name) async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: tester.view.devicePixelRatio);
        final directory = Directory(
          '${Directory.systemTemp.path}/ui-refinement',
        );
        await directory.create(recursive: true);
        final file = File('${directory.path}/feature-$name.png');
        await file.writeAsBytes(
          (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List(),
        );
        image.dispose();
        // ignore: avoid_print
        print('UI_REFINEMENT_CAPTURE=${file.path}');
      },
    );
  });
  group('existing visual and interaction regression', regression.main);
}
