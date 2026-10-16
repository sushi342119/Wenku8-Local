import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wenku8_flutter/library_backup.dart';
import 'package:wenku8_flutter/local_platform.dart';

/// Executed only with tools/run_android_documents_qa.py on an owned emulator.
/// The host selects the marked fixture document through observed system UI.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android document picker cancel, UTF-8 roundtrip, busy and size validation',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('本地文件备份回归'))),
        ),
      );
      await tester.pumpAndSettle();
      final cancelled = LocalPlatform.importBackup();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await expectLater(
        LocalPlatform.importBackup(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'busy',
          ),
        ),
      );
      // ignore: avoid_print
      print('DOCUMENT_QA_CANCEL_IMPORT');
      expect(await cancelled, isNull);
      final name = 'wenku8-QA-${DateTime.now().millisecondsSinceEpoch}.json';
      final text = await (await LibraryBackup.fromRecords({
        'shelf': ['71'],
        'recentSearches': ['中文与 Unicode 😀'],
      })).encode();
      final exported = LocalPlatform.exportBackup(text, name);
      // ignore: avoid_print
      print('DOCUMENT_QA_EXPORT=$name');
      expect(await exported, isTrue);
      final imported = LocalPlatform.importBackup();
      // ignore: avoid_print
      print('DOCUMENT_QA_IMPORT=$name');
      expect(await imported, text);
      for (final kind in ['INVALID', 'OVERSIZE']) {
        final failed = LocalPlatform.importBackup();
        // Attach expected-error listener before the host resumes the app.
        final assertion = expectLater(
          failed,
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'document',
            ),
          ),
        );
        // ignore: avoid_print
        print('DOCUMENT_QA_$kind=wenku8-QA-$kind.json');
        await assertion;
      }
      // ignore: avoid_print
      print(
        'DOCUMENT_QA_VERIFIED=cancel,busy,utf8-roundtrip,invalid-utf8,oversize',
      );
    },
  );
}
