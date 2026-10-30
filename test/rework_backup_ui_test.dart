import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/backup_page.dart';
import 'package:wenku8_flutter/book_tags.dart';
import 'package:wenku8_flutter/library_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> finishAction(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'degraded tag startup explains refusal without writing clipboard',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reduceMotion': true});
      expect(TagStore.maybeShared, isNull);
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      var copies = 0;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copies++;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        MaterialApp(home: LibraryBackupPage(state: state)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('backup-copy')));
      await tester.tap(find.byKey(const ValueKey('backup-copy')));
      await finishAction(tester);
      expect(find.textContaining('标签未加载，已拒绝'), findsOneWidget);
      expect(copies, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('damaged shelf has a working repair action in the backup page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'reduceMotion': true,
      'shelf': ['71', 'broken'],
    });
    final state = await LibraryState.load();
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(home: LibraryBackupPage(state: state)));
    await tester.pumpAndSettle();
    final repair = find.byKey(const ValueKey('backup-repair-shelf'));
    expect(repair, findsOneWidget);
    await tester.tap(repair);
    await finishAction(tester);
    expect(state.shelfLoadFailed, isFalse);
    expect(state.shelf, {71});
    expect(repair, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
