import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  test(
    'all launcher and iOS icon slots have matching opaque RGB images',
    () async {
      Future<void> check(String path, int side) async {
        final bytes = await File(path).readAsBytes();
        expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
        final header = ByteData.sublistView(bytes);
        expect(header.getUint32(16), side);
        expect(header.getUint32(20), side);
        expect(bytes[25], 2);
      }

      for (final entry in {
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
      }.entries) {
        await check(
          'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
          entry.value,
        );
      }
      const ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
      final contents =
          jsonDecode(await File('$ios/Contents.json').readAsString()) as Map;
      for (final item in contents['images'] as List) {
        final size = double.parse((item['size'] as String).split('x').first);
        final scale = double.parse(
          (item['scale'] as String).replaceAll('x', ''),
        );
        await check('$ios/${item['filename']}', (size * scale).round());
      }
    },
  );
  test(
    'adaptive and themed launcher resources preserve the source geometry',
    () async {
      final source = XmlDocument.parse(
        await File('assets/branding/app-icon.svg').readAsString(),
      );
      final foreground = XmlDocument.parse(
        await File(
          'android/app/src/main/res/drawable/ic_archive_foreground.xml',
        ).readAsString(),
      );
      expect(
        foreground
            .findAllElements('path')
            .map(
              (p) => p.getAttribute(
                'pathData',
                namespaceUri: 'http://schemas.android.com/apk/res/android',
              ),
            ),
        source.findAllElements('path').map((p) => p.getAttribute('d')),
      );
      final themed = await File(
        'android/app/src/main/res/mipmap-anydpi-v33/ic_launcher.xml',
      ).readAsString();
      expect(themed, contains('<monochrome'));
      expect(themed, contains('@drawable/ic_archive_monochrome'));
    },
  );
}
