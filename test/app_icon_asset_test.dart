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
  test('adaptive and themed launcher resources use the current fox assets', () async {
    for (final version in [26, 33]) {
      final document = XmlDocument.parse(await File(
        'android/app/src/main/res/mipmap-anydpi-v$version/ic_launcher.xml',
      ).readAsString());
      final foreground = document.findAllElements('foreground').single;
      expect(foreground.getAttribute('drawable', namespaceUri:
        'http://schemas.android.com/apk/res/android'), '@drawable/ic_fox_foreground');
      if (version == 33) {
        expect(document.findAllElements('monochrome').single.getAttribute(
          'drawable', namespaceUri: 'http://schemas.android.com/apk/res/android'),
          '@drawable/ic_fox_monochrome');
      }
    }
    for (final (name, colorType) in [('foreground', 2), ('monochrome', 6)]) {
      final bytes = await File(
        'android/app/src/main/res/drawable-nodpi/ic_fox_$name.png',
      ).readAsBytes();
      expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final header = ByteData.sublistView(bytes);
      expect(header.getUint32(16), 432);
      expect(header.getUint32(20), 432);
      expect(bytes[25], colorType);
    }
  });
}
