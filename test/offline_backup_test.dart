import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  test(
    'Android backup rules exclude caches and device-bound sessions, not reading preferences',
    () async {
      const base = 'android/app/src/main';
      final manifest = XmlDocument.parse(
        await File('$base/AndroidManifest.xml').readAsString(),
      );
      final app = manifest.findAllElements('application').single;
      expect(
        app.getAttribute('android:fullBackupContent'),
        '@xml/backup_rules',
      );
      expect(
        app.getAttribute('android:dataExtractionRules'),
        '@xml/data_extraction_rules',
      );
      for (final file in ['backup_rules', 'data_extraction_rules']) {
        final rules = XmlDocument.parse(
          await File('$base/res/xml/$file.xml').readAsString(),
        );
        expect(rules.findAllElements('include'), isEmpty);
        final groups = file == 'backup_rules'
            ? [rules.rootElement]
            : rules.rootElement.childElements;
        for (final group in groups) {
          expect(
            group
                .findElements('exclude')
                .map(
                  (exclude) => (
                    exclude.getAttribute('domain'),
                    exclude.getAttribute('path'),
                  ),
                )
                .toSet(),
            {
              ('file', 'wenku8-offline-v1'),
              ('file', 'wenku8-illustrations-v1'),
              ('sharedpref', 'wenku_account_session.xml'),
            },
          );
        }
      }
    },
  );
}
