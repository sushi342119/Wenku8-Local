import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/legacy_import.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_platform.dart';

/// Real Storage Access Framework fixtures, selected by the owned-emulator runner.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android legacy tree cancel, bounded import and local merge', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('旧版目录原生回归'))),
      ),
    );
    await tester.pumpAndSettle();
    final cancelled = LocalPlatform.importLegacyData();
    await expectLater(
      LocalPlatform.importLegacyData(),
      throwsA(
        isA<PlatformException>().having((error) => error.code, 'code', 'busy'),
      ),
    );
    // ignore: avoid_print
    print('LEGACY_TREE_QA_CANCEL');
    expect(await cancelled, isNull);
    for (final selection in ['ROOT', 'SAVES']) {
      final selected = LocalPlatform.importLegacyData();
      // ignore: avoid_print
      print('LEGACY_TREE_QA_$selection');
      final bundle = await selected;
      expect(bundle, isNotNull);
      final documents = bundle!['documents'] as Map;
      expect(documents.keys.toSet(), {
        'bookshelf_local.wk8',
        'read_saves.wk8',
        'read_saves_v1.wk8',
        'search_history.wk8',
        '73-volume.xml',
      });
      expect(bundle['skippedFiles'], 2);
      final preview = await LegacyImportPreview.parse(bundle);
      expect(preview.backup.shelfCount, 2);
      expect(preview.backup.positionCount, 2);
      expect(preview.damagedRecords, 1);
      final state = await LibraryState.load();
      await state.addShelfIds([70]);
      await state.restoreBackup(preview.backup);
      expect(state.shelf, containsAll([70, 71, 72]));
      expect(state.positionFor(71)!.chapterId, 71002);
      expect(state.positionFor(73)!.chapterId, 73001);
      expect(state.positionFor(73)!.fraction, .5);
      expect(state.recentSearches, ['中文', '作者']);
      state.dispose();
    }
    final oversized = LocalPlatform.importLegacyData();
    final error = expectLater(
      oversized,
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'document',
        ),
      ),
    );
    // ignore: avoid_print
    print('LEGACY_TREE_QA_OVERSIZE');
    await error;
    // ignore: avoid_print
    print(
      'LEGACY_TREE_QA_VERIFIED=cancel,busy,root,saves,credentials-excluded,utf8,size,merge',
    );
  });
}
